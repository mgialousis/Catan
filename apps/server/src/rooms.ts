import { randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import type { Socket } from 'socket.io';
import { isValid, type Command } from '@island/protocol';
import type { Games } from './games.js';
import { Database } from './database.js';
import { LobbyError, canonical, hash, invitation, nickname, normalizeCode, startEligibility } from './lobby-policy.js';
import { safeError } from './errors.js';

type Row = Record<string, any>;
type Ack = { commandId: string; status: 'ACCEPTED' | 'REJECTED'; scope: 'ROOM'; roomId: string | null; version: number | null; serverTime: string; result?: { playerId?: string; invitationCode?: string }; error?: ReturnType<typeof safeError> };
const colours = ['RED', 'BLUE', 'WHITE', 'ORANGE'];

/** Single-process lobby coordinator. Database locks/receipts remain authoritative. */
export class Rooms {
  readonly epoch = randomUUID();
  games?: Games;
  private readonly sockets = new Map<string, Socket>();
  private readonly subscriptions = new Map<string, { socket: Socket; roomId: string; playerId: string; userId: string }>();
  private readonly absentHosts = new Map<string, { playerId: string; since: number }>();
  private timer?: NodeJS.Timeout;
  private ticking = false;
  private stopped = false;
  constructor(readonly database: Database) {}

  async initialize(): Promise<void> {
    await this.database.transaction(async db => {
      await db.query('SELECT id FROM app.runtime_control WHERE id=1 FOR UPDATE');
      await db.query('UPDATE app.runtime_control SET active_epoch=$1, claimed_at=clock_timestamp() WHERE id=1', [this.epoch]);
      await this.games?.recover(db, 'RECOVERY');
    });
    await this.maintenance();
  }
  async onApplicationShutdown(): Promise<void> {
    this.retire();
    this.subscriptions.clear();
  }
  attach(socket: Socket): void { this.sockets.set(socket.id, socket); }
  private retire(): void {
    if (this.stopped) return;
    this.stopped = true; clearTimeout(this.timer); this.games?.stop();
    for (const socket of this.sockets.values()) {
      socket.emit('server.restarting', { retryAfterMs: 1000 });
      socket.disconnect(true);
    }
    this.sockets.clear();
    this.subscriptions.clear();
  }
  private schedule(delay = 0): void {
    clearTimeout(this.timer);
    if (this.stopped || !this.subscriptions.size) return;
    this.timer = setTimeout(() => { void this.maintenance().catch(() => undefined); }, delay);
    this.timer.unref();
  }
  async ready(): Promise<void> { await this.database.transaction(db => this.fence(db)); }
  async fence(db: PoolClient, allowRecovery = false): Promise<void> {
    const row = (await db.query('SELECT active_epoch FROM app.runtime_control WHERE id=1 FOR SHARE')).rows[0];
    if (this.stopped || row?.active_epoch !== this.epoch) { this.retire(); throw new LobbyError('SERVICE_UNAVAILABLE'); }
    if (!allowRecovery && this.games && !this.games.storageReady) throw new LobbyError('SERVICE_UNAVAILABLE');
  }
  private async players(db: PoolClient, roomId: string): Promise<Row[]> {
    return (await db.query('SELECT * FROM app.players WHERE room_id=$1 AND left_at IS NULL ORDER BY seat_index', [roomId])).rows;
  }
  private snapshot(room: Row, players: Row[]) {
    const value = { roomId: room.id, revision: room.revision, hostPlayerId: room.host_player_id, status: room.status, settings: room.settings,
      players: players.map(p => ({ id: p.id, nickname: p.nickname, seatIndex: p.seat_index, colour: p.colour, ready: p.ready })) };
    if (!isValid('roomSnapshot', value)) throw new Error('Invalid stored room projection');
    return value;
  }
  online(roomId: string): Set<string> {
    return new Set([...this.subscriptions.values()].filter(s => s.roomId === roomId && s.socket.connected).map(s => s.playerId));
  }
  private async outbox(db: PoolClient, room: Row, previous: number | null): Promise<void> {
    await db.query(`INSERT INTO app.outbox_events(room_id,scope,from_version,to_version,public_payload,private_payloads)
      VALUES ($1,'ROOM',$2,$3,$4,'{}')`, [room.id, previous, room.revision, this.snapshot(room, await this.players(db, room.id))]);
  }
  async changed(db: PoolClient, room: Row, resetReady = false, activity = true): Promise<Row> {
    if (resetReady) await db.query('UPDATE app.players SET ready=false WHERE room_id=$1 AND left_at IS NULL', [room.id]);
    const next = (await db.query(`UPDATE app.rooms SET revision=revision+1,
      updated_at=CASE WHEN $2 THEN clock_timestamp() ELSE updated_at END, runtime_epoch=$3 WHERE id=$1 RETURNING *`, [room.id, activity, this.epoch])).rows[0];
    await this.outbox(db, next, room.revision);
    return next;
  }
  private async expire(db: PoolClient, room: Row): Promise<Row> {
    const expired = (await db.query(`SELECT $1::timestamptz <= clock_timestamp() - interval '24 hours' AS expired`, [room.updated_at])).rows[0].expired;
    if (room.status === 'LOBBY' && expired) {
      await db.query("UPDATE app.rooms SET status='EXPIRED',active_slot=null,ended_at=clock_timestamp() WHERE id=$1", [room.id]);
      return this.changed(db, room, true, false);
    }
    return room;
  }
  private ack(command: Command, code?: string, room?: Row, result?: Ack['result']): Ack {
    return { commandId: command.commandId, status: code ? 'REJECTED' : 'ACCEPTED', scope: 'ROOM', roomId: room?.id ?? command.roomId,
      version: room?.revision ?? null, serverTime: new Date().toISOString(), ...(code ? { error: safeError(code) } : result ? { result } : {}) };
  }
  async command(userId: string, command: Command): Promise<Ack> {
    const actor = `user:${userId}`, requestHash = hash(canonical(command));
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await this.database.transaction(async db => {
          await this.fence(db);
          await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`${actor}:${command.commandId}`]);
          const receipt = (await db.query('SELECT request_hash,response FROM app.command_receipts WHERE actor_key=$1 AND command_id=$2', [actor, command.commandId])).rows[0];
          if (receipt) return receipt.request_hash !== requestHash ? this.ack(command, 'COMMAND_ID_REUSED') : receipt.response ?? this.ack(command, 'RECEIPT_EXPIRED');
          // Serialize creation against other creations, including when no active row exists yet.
          if (['CREATE_ROOM', 'CREATE_REMATCH'].includes(command.type)) await db.query("SELECT pg_advisory_xact_lock(hashtextextended('island:active-slot',0))");
          let room: Row | undefined;
          if (command.type === 'CREATE_ROOM') {
            room = (await db.query('SELECT * FROM app.rooms WHERE active_slot=1 FOR UPDATE')).rows[0];
          } else if (command.type === 'JOIN_ROOM') {
            try { room = (await db.query('SELECT * FROM app.rooms WHERE invitation_hash=$1 FOR UPDATE', [hash(normalizeCode(command.payload.invitationCode as string))])).rows[0]; } catch (error) { if (!(error instanceof LobbyError)) throw error; }
          } else {
            room = (await db.query('SELECT * FROM app.rooms WHERE id=$1 FOR UPDATE', [command.roomId])).rows[0];
          }
          if (room) room = await this.expire(db, room);
          // Domain rejections roll back the attempted mutation, but retain expiry and the final receipt.
          await db.query('SAVEPOINT command_work');
          let ack: Ack;
          try { ack = await this.apply(db, userId, command, room); }
          catch (error) {
            await db.query('ROLLBACK TO SAVEPOINT command_work');
            if (!(error instanceof LobbyError)) throw error;
            ack = this.ack(command, error.code);
          }
          await db.query('INSERT INTO app.command_receipts(actor_key,command_id,room_id,request_hash,status,response) VALUES ($1,$2,$3,$4,$5,$6)',
            [actor, command.commandId, ack.status === 'ACCEPTED' ? ack.roomId : room?.id ?? null, requestHash, ack.status, ack]);
          return ack;
        });
        void this.flush().catch(() => undefined);
        this.games?.wake();
        void this.games?.flush().catch(() => undefined);
        return response;
      } catch (error) {
        const code = (error as { code?: string }).code;
        if (['23505', '40001', '40P01'].includes(code ?? '') && attempt < 2) continue;
        return this.ack(command, 'SERVICE_UNAVAILABLE');
      }
    }
    return this.ack(command, 'SERVICE_UNAVAILABLE');
  }
  private async uniqueInvitation(db: PoolClient): Promise<{ code: string; digest: string }> {
    for (let i = 0; i < 8; i++) {
      const code = invitation(), digest = hash(code);
      if (!(await db.query('SELECT 1 FROM app.rooms WHERE invitation_hash=$1', [digest])).rowCount) return { code, digest };
    }
    throw new LobbyError('SERVICE_UNAVAILABLE');
  }
  private async apply(db: PoolClient, userId: string, command: Command, room?: Row): Promise<Ack> {
    const payload = command.payload;
    if (command.type === 'CREATE_ROOM') {
      if (room && ['LOBBY', 'ACTIVE', 'PAUSED'].includes(room.status)) throw new LobbyError('ROOM_UNAVAILABLE');
      const name = nickname(payload.nickname as string), invite = await this.uniqueInvitation(db);
      room = (await db.query(`INSERT INTO app.rooms(created_by_user_id,active_slot,settings,invitation_hash,invitation_expires_at,runtime_epoch)
        VALUES ($1,1,$2,$3,clock_timestamp()+interval '24 hours',$4) RETURNING *`, [userId, payload.settings, invite.digest, this.epoch])).rows[0] as Row;
      const playerId = randomUUID();
      await db.query(`INSERT INTO app.players(id,room_id,auth_user_id,nickname,nickname_key,seat_index,colour) VALUES ($1,$2,$3,$4,$5,0,'RED')`, [playerId, room.id, userId, name.name, name.key]);
      room = (await db.query('UPDATE app.rooms SET host_player_id=$1 WHERE id=$2 RETURNING *', [playerId, room.id])).rows[0] as Row;
      await this.outbox(db, room, null);
      return this.ack(command, undefined, room, { playerId, invitationCode: invite.code });
    }
    if (!room) throw new LobbyError(command.type === 'JOIN_ROOM' ? 'ROOM_UNAVAILABLE' : 'FORBIDDEN');
    let roster = await this.players(db, room.id);
    const own = roster.find(p => p.auth_user_id === userId);
    if (command.type === 'JOIN_ROOM') {
      if (own && ['LOBBY', 'ACTIVE', 'PAUSED'].includes(room.status)) return this.ack(command, undefined, room, { playerId: own.id });
      if (['ACTIVE', 'PAUSED'].includes(room.status)) throw new LobbyError('GAME_ALREADY_STARTED');
      if (room.status !== 'LOBBY' || (room.invitation_expires_at && (await db.query('SELECT $1::timestamptz <= clock_timestamp() AS expired', [room.invitation_expires_at])).rows[0].expired)) throw new LobbyError('ROOM_UNAVAILABLE');
      if (roster.length >= 4) throw new LobbyError('ROOM_FULL');
      const name = nickname(payload.nickname as string);
      if (roster.some(p => p.nickname_key === name.key)) throw new LobbyError('NAME_TAKEN');
      const seat = [0, 1, 2, 3].find(s => !roster.some(p => p.seat_index === s))!;
      const colour = colours.find(c => !roster.some(p => p.colour === c))!;
      const player = (await db.query(`INSERT INTO app.players(room_id,auth_user_id,nickname,nickname_key,seat_index,colour)
        VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (room_id,auth_user_id) DO UPDATE SET nickname=$3,nickname_key=$4,seat_index=$5,colour=$6,left_at=null,ready=false RETURNING id`, [room.id, userId, name.name, name.key, seat, colour])).rows[0];
      room = await this.changed(db, room, true);
      return this.ack(command, undefined, room, { playerId: player.id });
    }
    if (!own) throw new LobbyError('FORBIDDEN');
    if (command.type === 'CREATE_REMATCH') {
      if (room.host_player_id !== own.id) throw new LobbyError('FORBIDDEN');
      if (room.status !== 'FINISHED') throw new LobbyError('GAME_NOT_AVAILABLE');
      if (command.expectedVersion !== room.revision) throw new LobbyError('STALE_VERSION');
      const active = (await db.query('SELECT * FROM app.rooms WHERE active_slot=1 FOR UPDATE')).rows[0];
      return this.apply(db, userId, { ...command, type: 'CREATE_ROOM', payload: { nickname: own.nickname, settings: room.settings } }, active);
    }
    if (room.status !== 'LOBBY') throw new LobbyError('GAME_ALREADY_STARTED');
    if (command.expectedVersion !== room.revision) throw new LobbyError('STALE_VERSION');
    if (['UPDATE_SETTINGS', 'ROTATE_INVITATION', 'START_GAME', 'CREATE_REMATCH'].includes(command.type) && room.host_player_id !== own.id) throw new LobbyError('FORBIDDEN');
    let reset = false;
    let result: Ack['result'];
    switch (command.type) {
      case 'SET_PROFILE': {
        const name = nickname(payload.nickname as string);
        if (roster.some(p => p.id !== own.id && p.nickname_key === name.key)) throw new LobbyError('NAME_TAKEN');
        if (roster.some(p => p.id !== own.id && p.colour === payload.colour)) throw new LobbyError('COLOUR_TAKEN');
        await db.query('UPDATE app.players SET nickname=$1,nickname_key=$2,colour=$3 WHERE id=$4', [name.name, name.key, payload.colour, own.id]);
        reset = true; break;
      }
      case 'SET_READY':
        await db.query('UPDATE app.players SET ready=$1 WHERE id=$2', [payload.ready, own.id]); break;
      case 'UPDATE_SETTINGS':
        await db.query('UPDATE app.rooms SET settings=$1 WHERE id=$2', [{ ...room.settings, ...payload }, room.id]); reset = true; break;
      case 'ROTATE_INVITATION': {
        const invite = await this.uniqueInvitation(db);
        await db.query("UPDATE app.rooms SET invitation_hash=$1,invitation_expires_at=clock_timestamp()+interval '24 hours' WHERE id=$2", [invite.digest, room.id]);
        result = { invitationCode: invite.code }; break;
      }
      case 'LEAVE_LOBBY': {
        await db.query('UPDATE app.players SET left_at=clock_timestamp(),ready=false,seat_index=null,colour=null WHERE id=$1', [own.id]);
        roster = roster.filter(p => p.id !== own.id);
        if (!roster.length) await db.query("UPDATE app.rooms SET status='ABANDONED',active_slot=null,ended_at=clock_timestamp() WHERE id=$1", [room.id]);
        else if (own.id === room.host_player_id) {
          const next = roster.find(p => this.online(room!.id).has(p.id)) ?? roster[0]!;
          await db.query('UPDATE app.rooms SET host_player_id=$1 WHERE id=$2', [next.id, room.id]);
        }
        reset = true; break;
      }
      case 'START_GAME':
        startEligibility(roster.map(p => ({ id: p.id as string, ready: p.ready as boolean, colour: p.colour as string | null })), this.online(room.id));
        if (!this.games) throw new LobbyError('GAME_NOT_AVAILABLE');
        await this.games.start(db, room, roster, command, own.id);
        await db.query("UPDATE app.rooms SET status='ACTIVE' WHERE id=$1", [room.id]);
        break;
      default: throw new LobbyError('NOT_IMPLEMENTED');
    }
    room = await this.changed(db, room, reset);
    return this.ack(command, undefined, room, result);
  }

  async subscribe(socket: Socket, roomId?: string, lastRevision?: number | null): Promise<void> {
    const userId = socket.data.identity.userId as string;
    // Commit expiry before any snapshot is emitted, including on a sleeping server's first read.
    await this.database.transaction(async db => {
      await this.fence(db);
      const rows = (await db.query("SELECT * FROM app.rooms WHERE status='LOBBY' AND updated_at <= clock_timestamp() - interval '24 hours' ORDER BY id FOR UPDATE")).rows;
      for (const row of rows) await this.expire(db, row);
    });
    await this.database.transaction(async db => {
      await this.fence(db);
      let room: Row | undefined;
      if (roomId) room = (await db.query('SELECT * FROM app.rooms WHERE id=$1 FOR UPDATE', [roomId])).rows[0];
      else room = (await db.query(`SELECT r.* FROM app.rooms r JOIN app.players p ON p.room_id=r.id
        WHERE p.auth_user_id=$1 AND p.left_at IS NULL AND r.active_slot=1 FOR UPDATE OF r`, [userId])).rows[0];
      if (!room) { if (roomId) throw new LobbyError('FORBIDDEN'); return; }
      // Expiry mutations are handled before subscribing, by maintenance/commands.
      const players = await this.players(db, room.id), own = players.find(p => p.auth_user_id === userId);
      if (!own) throw new LobbyError('FORBIDDEN');
      if (!socket.connected) return;
      const previous = this.subscriptions.get(socket.id);
      const newMembership = previous?.roomId !== room.id || previous?.playerId !== own.id;
      this.subscriptions.set(socket.id, { socket, roomId: room.id, playerId: own.id, userId });
      if (newMembership) socket.emit('session.membership', { roomId: room.id, playerId: own.id });
      if (newMembership || lastRevision !== room.revision) socket.emit('room.snapshot', this.snapshot(room, players));
      if (newMembership) { this.emitPresence(room.id); this.schedule(); this.games?.wake(); }
      else this.emitPresence(room.id, socket);
    });
    const sub = this.subscriptions.get(socket.id);
    if (sub) await this.games?.subscribe(socket, sub.roomId);
  }
  disconnect(socket: Socket): void {
    this.games?.disconnect(socket);
    const subscription = this.subscriptions.get(socket.id);
    this.subscriptions.delete(socket.id);
    this.sockets.delete(socket.id);
    if (subscription) { this.emitPresence(subscription.roomId); this.schedule(); this.games?.wake(); }
  }
  private emitPresence(roomId: string, requester?: Socket): void {
    const value = { roomId, onlinePlayerIds: [...this.online(roomId)], observedAt: new Date().toISOString() };
    if (requester) { requester.emit('presence.update', value); return; }
    for (const s of this.subscriptions.values()) if (s.roomId === roomId && s.socket.connected) s.socket.emit('presence.update', value);
  }
  async flush(): Promise<void> {
    const changedRooms = new Set<string>();
    await this.database.transaction(async db => {
      await this.fence(db);
      // Room snapshots are complete, so coalesce queued revisions to the current authorized view.
      const rooms = (await db.query("SELECT * FROM app.rooms WHERE id IN (SELECT room_id FROM app.outbox_events WHERE scope='ROOM' AND published_at IS NULL) ORDER BY id FOR UPDATE")).rows;
      for (const room of rooms) {
        changedRooms.add(room.id);
        const players = await this.players(db, room.id), snapshot = this.snapshot(room, players);
        for (const s of this.subscriptions.values()) {
          if (s.roomId !== room.id || !s.socket.connected) continue;
          if (players.some(p => p.id === s.playerId && p.auth_user_id === s.userId)) s.socket.emit('room.snapshot', snapshot);
          else { this.subscriptions.delete(s.socket.id); s.socket.emit('session.error', safeError('MEMBERSHIP_ENDED')); }
        }
        this.emitPresence(room.id);
        await db.query("UPDATE app.outbox_events SET attempts=attempts+1,published_at=clock_timestamp() WHERE room_id=$1 AND scope='ROOM' AND published_at IS NULL", [room.id]);
      }
    });
    for (const sub of this.subscriptions.values()) if (changedRooms.has(sub.roomId)) await this.games?.subscribe(sub.socket, sub.roomId);
  }
  async maintenance(): Promise<void> {
    if (this.ticking || this.stopped) return;
    this.ticking = true;
    try {
      await this.database.transaction(async db => {
        await this.fence(db);
        const active = (await db.query("SELECT * FROM app.rooms WHERE status IN ('LOBBY','ACTIVE','PAUSED') ORDER BY id FOR UPDATE")).rows;
        const lobbyIds = new Set(active.map(room => room.id));
        for (const id of this.absentHosts.keys()) if (!lobbyIds.has(id)) this.absentHosts.delete(id);
        for (let room of active) {
          room = await this.expire(db, room);
          if (!['LOBBY','ACTIVE','PAUSED'].includes(room.status)) { this.absentHosts.delete(room.id); continue; }
          const online = this.online(room.id);
          if (online.has(room.host_player_id)) { this.absentHosts.delete(room.id); continue; }
          let absence = this.absentHosts.get(room.id);
          if (absence?.playerId !== room.host_player_id) { absence = { playerId: room.host_player_id, since: Date.now() }; this.absentHosts.set(room.id, absence); }
          if (Date.now() - absence!.since < 10000) continue;
          const next = (await this.players(db, room.id)).find(p => online.has(p.id));
          if (next) {
            await db.query('UPDATE app.rooms SET host_player_id=$1 WHERE id=$2', [next.id, room.id]);
            await this.changed(db, room, room.status === 'LOBBY', false);
            this.absentHosts.delete(room.id);
          }
        }
      });
      await this.flush();
    } finally { this.ticking = false; this.schedule(this.absentHosts.size ? 1000 : 60000); }
  }
}
