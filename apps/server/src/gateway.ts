import { Inject } from '@nestjs/common';
import { WebSocketGateway, SubscribeMessage, ConnectedSocket, MessageBody } from '@nestjs/websockets';
import type { Namespace, Socket } from 'socket.io';
import { isValid, isClientPayload, events, MAX_COMMAND_BYTES, PROTOCOL_VERSION, type Command, type SafeError } from '@island/protocol';
import { clientAddress } from './client-address.js';
import type { AppConfig } from './config.js';
import { Games } from './games.js';
import { Rooms } from './rooms.js';
import { LobbyError } from './lobby-policy.js';
import { safeError } from './errors.js';
export { safeError } from './errors.js';
import { TokenVerifier, AuthFailure, type Identity } from './auth.js';

export class WindowLimiter {
  private readonly windows = new Map<string, { count: number; until: number }>();
  constructor(private readonly maximum: number, private readonly duration = 60000) {}
  allow(key: string, now = Date.now()): boolean {
    if (this.windows.size > 10000) {
      for (const [id, value] of this.windows) if (value.until <= now) this.windows.delete(id);
      if (this.windows.size > 10000 && !this.windows.has(key)) return false;
    }
    let window = this.windows.get(key);
    if (!window || window.until <= now) { window = { count: 0, until: now + this.duration }; this.windows.set(key, window); }
    return ++window.count <= this.maximum;
  }
}

@WebSocketGateway({ namespace: '/game' })
export class GameGateway {
  private readonly commands = new WindowLimiter(120);
  private readonly invitations = new WindowLimiter(20);
  private readonly invitationIps = new WindowLimiter(100);
  constructor(@Inject(TokenVerifier) private readonly auth: TokenVerifier, @Inject(Rooms) private readonly rooms: Rooms, @Inject(Games) private readonly games: Games, @Inject('APP_CONFIG') private readonly config: AppConfig) {}

  afterInit(namespace: Namespace): void {
    namespace.use(async (socket, next) => {
      try {
        if (!isValid('handshake', socket.handshake.auth)) {
          const code = socket.handshake.auth?.protocolVersion !== PROTOCOL_VERSION ? 'PROTOCOL_UNSUPPORTED' : 'INVALID_PAYLOAD';
          throw Object.assign(new Error('Connection rejected'), { data: safeError(code) });
        }
        const identity = await this.auth.verify(socket.handshake.auth.accessToken);
        await this.rooms.ready();
        socket.data.identity = identity;
        socket.data.accessToken = socket.handshake.auth.accessToken;
        next();
      } catch (error) {
        next(Object.assign(new Error('Connection rejected'), { data: error instanceof AuthFailure || error instanceof LobbyError ? safeError(error.code) : (error as { data?: SafeError }).data ?? safeError('UNAUTHENTICATED') }));
      }
    });
  }
  handleConnection(socket: Socket): void {
    this.rooms.attach(socket);
    this.expireAt(socket, socket.data.identity as Identity);
    socket.use(async ([event, payload], next) => {
      try {
        const identity = socket.data.identity as Identity;
        if (!this.commands.allow(identity.userId)) throw safeError('RATE_LIMITED');
        if (!Object.hasOwn(events.client, event) || !isClientPayload(event, payload)) throw safeError('INVALID_PAYLOAD');
        // Refresh verifies the new token in its handler. Every other request re-verifies the current token.
        if (event !== 'auth.refresh') await this.auth.verify(socket.data.accessToken);
        next();
      } catch (error) {
        const result = error instanceof AuthFailure ? safeError(error.code) : isValid('error', error) ? error as SafeError : safeError('SERVICE_UNAVAILABLE');
        socket.emit('session.error', result);
        next(new Error(result.code));
      }
    });
    socket.on('error', () => undefined); // Never log Socket.IO payloads, tokens or private state.
    void this.rooms.subscribe(socket).catch(() => socket.emit('session.error', safeError('SERVICE_UNAVAILABLE')));
    socket.emit('server.hello', { protocolVersion: PROTOCOL_VERSION, serverTime: new Date().toISOString(), heartbeatIntervalMs: 25000, maxCommandBytes: MAX_COMMAND_BYTES });
  }
  handleDisconnect(socket: Socket): void { clearTimeout(socket.data.expiryTimer); this.rooms.disconnect(socket); }
  private expireAt(socket: Socket, identity: Identity): void {
    clearTimeout(socket.data.expiryTimer);
    socket.data.expiryTimer = setTimeout(() => {
      socket.emit('session.error', safeError('TOKEN_EXPIRED'));
      socket.disconnect(true);
    }, Math.max(0, Math.min(identity.expiresAt - Date.now(), 2147483647)));
    socket.data.expiryTimer.unref();
  }
  @SubscribeMessage('auth.refresh')
  async refresh(@ConnectedSocket() socket: Socket, @MessageBody() payload: { accessToken: string }) {
    try {
      const identity = await this.auth.verify(payload.accessToken);
      if (identity.userId !== (socket.data.identity as Identity).userId) throw new AuthFailure();
      socket.data.identity = identity;
      socket.data.accessToken = payload.accessToken;
      this.expireAt(socket, identity);
      await this.rooms.subscribe(socket);
      return { status: 'ACCEPTED', serverTime: new Date().toISOString() };
    } catch (error) {
      socket.emit('session.error', safeError(error instanceof AuthFailure ? error.code : 'UNAUTHENTICATED'));
      socket.disconnect(true);
      return { status: 'REJECTED' };
    }
  }
  @SubscribeMessage('room.command')
  async roomCommand(@ConnectedSocket() socket: Socket, @MessageBody() command: Command) {
    if (['CREATE_ROOM', 'CREATE_REMATCH', 'JOIN_ROOM', 'ROTATE_INVITATION'].includes(command.type) && (!this.invitations.allow(socket.data.identity.userId) || !this.invitationIps.allow(clientAddress(socket.handshake.address, socket.handshake.headers['x-forwarded-for'], this.config.trustedProxyHops)))) {
      return { commandId: command.commandId, status: 'REJECTED', scope: 'ROOM', roomId: command.roomId, version: null, error: safeError('RATE_LIMITED'), serverTime: new Date().toISOString() };
    }
    const ack = await this.rooms.command(socket.data.identity.userId, command);
    if (ack.status === 'ACCEPTED' && ack.roomId && command.type !== 'LEAVE_LOBBY') {
      // A failed post-commit subscription must never replace a durable acknowledgement.
      await this.rooms.subscribe(socket, ack.roomId).catch(() => socket.emit('session.error', safeError('SERVICE_UNAVAILABLE')));
    }
    return ack;
  }
  @SubscribeMessage('game.command')
  gameCommand(@ConnectedSocket() socket: Socket, @MessageBody() command: Command) { return this.games.command(socket.data.identity.userId, command); }
  @SubscribeMessage('session.subscribe')
  async subscribe(@ConnectedSocket() socket: Socket, @MessageBody() payload: { requestId: string; roomId: string; lastRoomRevision: number | null }) {
    try { await this.rooms.subscribe(socket, payload.roomId, payload.lastRoomRevision); }
    catch (error) { socket.emit('session.error', safeError(error instanceof LobbyError ? error.code : 'SERVICE_UNAVAILABLE', payload.requestId)); }
  }
  @SubscribeMessage('game.sync')
  async sync(@ConnectedSocket() socket: Socket, @MessageBody() payload: { requestId: string; roomId: string }) {
    try { await this.games.subscribe(socket, payload.roomId, true); }
    catch (error) { socket.emit('session.error', safeError(error instanceof LobbyError ? error.code : 'SERVICE_UNAVAILABLE', payload.requestId)); }
  }
  @SubscribeMessage('game.version.request')
  async version(@ConnectedSocket() socket: Socket, @MessageBody() payload: { roomId: string }) {
    try { await this.games.version(socket, payload.roomId); }
    catch (error) { socket.emit('session.error', safeError(error instanceof LobbyError ? error.code : 'SERVICE_UNAVAILABLE')); }
  }
}
