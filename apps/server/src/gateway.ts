import { Inject } from '@nestjs/common';
import { WebSocketGateway, SubscribeMessage, ConnectedSocket, MessageBody } from '@nestjs/websockets';
import type { Namespace, Socket } from 'socket.io';
import { isValid, isClientPayload, events, MAX_COMMAND_BYTES, PROTOCOL_VERSION, type Command, type SafeError } from '@island/protocol';
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
export function safeError(code: string, requestId?: unknown): SafeError {
  const messages: Record<string, string> = {
    UNAUTHENTICATED: 'Please reconnect to authenticate.', TOKEN_EXPIRED: 'Your session needs to refresh.',
    INVALID_PAYLOAD: 'The request format is invalid.', PROTOCOL_UNSUPPORTED: 'Please update the client.',
    FORBIDDEN: 'This room is unavailable.', RATE_LIMITED: 'Please wait before trying again.',
    NOT_IMPLEMENTED: 'Room and game actions arrive in a later phase.', SERVICE_UNAVAILABLE: 'Please try again shortly.',
  };
  return { code, message: messages[code] ?? 'The request could not be completed.',
    retryable: ['TOKEN_EXPIRED', 'RATE_LIMITED', 'SERVICE_UNAVAILABLE'].includes(code),
    ...(isValid('uuid', requestId) ? { requestId: requestId as string } : {}) };
}

@WebSocketGateway({ namespace: '/game' })
export class GameGateway {
  private readonly commands = new WindowLimiter(120);
  constructor(@Inject(TokenVerifier) private readonly auth: TokenVerifier) {}

  afterInit(namespace: Namespace): void {
    namespace.use(async (socket, next) => {
      try {
        if (!isValid('handshake', socket.handshake.auth)) {
          const code = socket.handshake.auth?.protocolVersion !== PROTOCOL_VERSION ? 'PROTOCOL_UNSUPPORTED' : 'INVALID_PAYLOAD';
          throw Object.assign(new Error('Connection rejected'), { data: safeError(code) });
        }
        const identity = await this.auth.verify(socket.handshake.auth.accessToken);
        socket.data.identity = identity;
        socket.data.accessToken = socket.handshake.auth.accessToken;
        next();
      } catch (error) {
        next(Object.assign(new Error('Connection rejected'), { data: error instanceof AuthFailure ? safeError(error.code) : (error as { data?: SafeError }).data ?? safeError('UNAUTHENTICATED') }));
      }
    });
  }
  handleConnection(socket: Socket): void {
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
    socket.emit('server.hello', { protocolVersion: PROTOCOL_VERSION, serverTime: new Date().toISOString(), heartbeatIntervalMs: 25000, maxCommandBytes: MAX_COMMAND_BYTES });
  }
  handleDisconnect(socket: Socket): void { clearTimeout(socket.data.expiryTimer); }
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
      return { status: 'ACCEPTED', serverTime: new Date().toISOString() };
    } catch (error) {
      socket.emit('session.error', safeError(error instanceof AuthFailure ? error.code : 'UNAUTHENTICATED'));
      socket.disconnect(true);
      return { status: 'REJECTED' };
    }
  }
  @SubscribeMessage('room.command')
  roomCommand(@MessageBody() command: Command) { return this.unimplemented(command, 'ROOM'); }
  @SubscribeMessage('game.command')
  gameCommand(@MessageBody() command: Command) { return this.unimplemented(command, 'GAME'); }
  private unimplemented(command: Command, scope: 'ROOM' | 'GAME') {
    // No mutations or durable receipts exist in Phase 1. Never acknowledge a fictitious commit.
    return { commandId: command.commandId, status: 'REJECTED', scope, roomId: command.roomId, version: null, error: safeError('NOT_IMPLEMENTED'), serverTime: new Date().toISOString() };
  }
  @SubscribeMessage('session.subscribe')
  subscribe(@ConnectedSocket() socket: Socket, @MessageBody() payload: { requestId: string }) { this.forbidden(socket, payload.requestId); }
  @SubscribeMessage('game.sync')
  sync(@ConnectedSocket() socket: Socket, @MessageBody() payload: { requestId: string }) { this.forbidden(socket, payload.requestId); }
  @SubscribeMessage('game.version.request')
  version(@ConnectedSocket() socket: Socket) { this.forbidden(socket); }
  private forbidden(socket: Socket, requestId?: string): void {
    // Until Phase 2 introduces membership, no socket may subscribe or read room data.
    socket.emit('session.error', safeError('FORBIDDEN', requestId));
  }
}
