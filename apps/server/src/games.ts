import { assertClock, advanceClock, pauseState, nextDeadline, timerJobs, dueFor, matchesJob, fallback, systemId, type TimerJob, type PauseReason } from './game-clock.js';
import type { PoolClient } from 'pg';
import type { Socket } from 'socket.io';
import { isValid, type Command } from '@island/protocol';
import { applyCommand, createGame, assertInvariants, projectGame, projectEffects, RuleError, type CanonicalState, type Transition, type InitialPlayer } from '@island/game-engine';
import { Database } from './database.js';
import type { Rooms } from './rooms.js';
import { canonical, hash, LobbyError } from './lobby-policy.js';
import { safeError } from './errors.js';
import { engineContext } from './engine-context.js';
import { commonView, gameDelta } from './game-delta.js';

class RepairRequired extends Error {}
type Row = Record<string, any>;
type Ack = { commandId: string; status: 'ACCEPTED' | 'REJECTED'; scope: 'GAME'; roomId: string | null; version: number | null; serverTime: string; error?: ReturnType<typeof safeError> };
type Subscription = { socket: Socket; roomId: string; playerId: string; userId: string; version: number };
/** Test hooks inject crashes at real transaction/delivery boundaries; unset in the application. */
export interface GameFaults { beforeCommit?: () => void; afterCommit?: () => void; afterSend?: () => void }
export class Games {
  private readonly subscriptions = new Map<string, Subscription>();
  private readonly queues = new Map<string, Promise<void>>();
  private timer?: NodeJS.Timeout;
  private stopped = false;
  private runtimeTimer?: NodeJS.Timeout;
  private ticking = false;
  private clocksRunning = false;
  private wakeRequested = false;
  private unavailable = false;
  private repairRequired = false;
  private closing = false;
  get storageReady(): boolean { return !this.unavailable && !this.repairRequired && !this.closing; }
  readonly #faults: Readonly<GameFaults>;
  constructor(private readonly database: Database, private readonly rooms: Rooms, faults: Readonly<GameFaults> = Object.freeze({})) { this.#faults = faults; if (database) database.onUnavailable = () => this.storageLost(); }
  private async serial<T>(roomId: string, work: () => Promise<T>): Promise<T> {
    const previous = this.queues.get(roomId) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const queued = previous.catch(() => undefined).then(() => gate); this.queues.set(roomId, queued);
    await previous.catch(() => undefined);
    try { return await work(); } finally { release(); if (this.queues.get(roomId) === queued) this.queues.delete(roomId); }
  }
  private state(row: Row): CanonicalState {
    const state: CanonicalState = { roomId: row.room_id, version: row.version, rulesVersion: row.rules_version,
      stateSchemaVersion: row.schema_version, protocolVersion: 1, publicState: row.public_state, privateState: row.private_state, serverState: row.server_state, clockState: row.clock_state };
    try { assertInvariants(state); assertClock(state); } catch { throw new RepairRequired('Invalid saved game'); }
    if (state.publicState.phase !== row.phase || state.publicState.phaseId !== row.phase_id || state.publicState.turnNumber !== row.turn_number || state.publicState.activePlayerId !== row.active_player_id) throw new RepairRequired('Game index mismatch');
    if ((row.next_deadline_at?.toISOString() ?? null) !== nextDeadline(state)) throw new RepairRequired('Clock index mismatch');
    return state;
  }
  private values(state: CanonicalState) {
    const p = state.publicState;
    return [state.roomId, state.version, state.rulesVersion, state.stateSchemaVersion, p.phase, p.phaseId, p.turnNumber, p.activePlayerId,
      state.publicState, state.privateState, state.serverState, state.clockState, nextDeadline(state)];
  }
  async start(db: PoolClient, room: Row, roster: Row[], command: Command, hostId: string): Promise<void> {
    const result = createGame({ roomId: room.id, players: roster.map(p => ({ id: p.id, nickname: p.nickname, seatIndex: p.seat_index, colour: p.colour })) as InitialPlayer[], turnLimitSeconds: room.settings.turnLimitSeconds }, { ...engineContext(), now: await this.now(db) });
    await db.query(`INSERT INTO app.game_states(room_id,version,rules_version,schema_version,phase,phase_id,turn_number,active_player_id,public_state,private_state,server_state,clock_state,next_deadline_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`, this.values(result.state));
    await this.record(db, null, result, hostId, command);
    this.#faults.beforeCommit?.();
  }
  private async record(db: PoolClient, previous: CanonicalState | null, result: Transition, actor: string | null, command: Command, metadata: Record<string, unknown> = {}): Promise<void> {
    const next = result.state, ids = Object.keys(next.privateState), serverTime = result.occurredAt;
    const activity = projectEffects(result.effects, actor ?? ids[0]!).activity;
    const internal = [...result.effects, { type: 'REPLAY_CONTEXT', command, occurredAt: serverTime, randomDraws: result.randomDraws, clockState: next.clockState, ...(['PAUSE_GAME','RESUME_GAME','ABANDON_GAME'].includes(command.type) ? { sessionState: { pauseReasons: next.publicState.pauseReasons, clockState: next.clockState } } : {}), ...metadata }, ...(previous ? [] : [{ type: 'INITIAL_SNAPSHOT', state: next }])];
    await db.query(`INSERT INTO app.move_logs(room_id,sequence,command_id,actor_player_id,actor_kind,command_type,validated_payload,effects,public_activity,rules_version,created_at)
      VALUES ($1,$2,$3,$4,$11,$5,$6,$7,$8,$9,$10)`, [next.roomId, next.version, command.commandId, actor, command.type, command.payload, JSON.stringify(internal), JSON.stringify(activity), next.rulesVersion, serverTime, actor ? 'PLAYER' : 'SYSTEM']);
    let publicPayload: Record<string, unknown>, privatePayloads: Record<string, unknown>;
    if (!previous) {
      const snapshots = ids.map(id => projectGame(next, id, serverTime));
      const publicSnapshot = commonView(snapshots, 'privateState');
      publicPayload = { kind: 'snapshot', value: publicSnapshot };
      privatePayloads = Object.fromEntries(ids.map(id => [id, projectGame(next, id, serverTime).privateState]));
    } else {
      const deltas = Object.fromEntries(ids.map(id => [id, gameDelta(previous, next, id, result.effects, serverTime)]));
      const common = commonView(Object.values(deltas), 'privatePatch');
      publicPayload = { kind: 'delta', value: common };
      privatePayloads = Object.fromEntries(ids.map(id => [id, deltas[id]!.privatePatch]));
    }
    await db.query(`INSERT INTO app.outbox_events(room_id,scope,from_version,to_version,public_payload,private_payloads) VALUES ($1,'GAME',$2,$3,$4,$5)`,
      [next.roomId, previous?.version ?? null, next.version, publicPayload, privatePayloads]);
  }
  private ack(cmd: Command, code?: string, version: number | null = null): Ack {
    return { commandId: cmd.commandId, status: code ? 'REJECTED' : 'ACCEPTED', scope: 'GAME', roomId: cmd.roomId, version,
      serverTime: new Date().toISOString(), ...(code ? { error: safeError(code) } : {}) };
  }
  async command(userId: string, cmd: Command): Promise<Ack> {
    const actorKey = `user:${userId}`, requestHash = hash(canonical(cmd));
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const ack = await this.database.transaction(async db => {
          await this.rooms.fence(db);
          await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`${actorKey}:${cmd.commandId}`]);
          const receipt = (await db.query('SELECT request_hash,response FROM app.command_receipts WHERE actor_key=$1 AND command_id=$2', [actorKey, cmd.commandId])).rows[0];
          if (receipt) return receipt.request_hash !== requestHash ? this.ack(cmd, 'COMMAND_ID_REUSED') : receipt.response ?? this.ack(cmd, 'RECEIPT_EXPIRED');
          const room = (await db.query('SELECT * FROM app.rooms WHERE id=$1 FOR UPDATE', [cmd.roomId])).rows[0];
          let response: Ack;
          await db.query('SAVEPOINT game_work');
          try {
            const player = room && (await db.query('SELECT id FROM app.players WHERE room_id=$1 AND auth_user_id=$2 AND left_at IS NULL', [room.id, userId])).rows[0];
            if (!player) throw new RuleError('FORBIDDEN');
            const row = (await db.query('SELECT * FROM app.game_states WHERE room_id=$1 FOR UPDATE', [room.id])).rows[0];
            if (!row) throw new RuleError('GAME_NOT_AVAILABLE');
            if (room.status === 'FINISHED' || room.status === 'ABANDONED') throw new RuleError('GAME_FINISHED');
            if (!['ACTIVE', 'PAUSED'].includes(room.status)) throw new RuleError('GAME_NOT_AVAILABLE');
            const previous = this.state(row), now = await this.now(db), context = { ...engineContext(), now };
            this.rooms.assertOwnership(room.runtime_epoch);
            if (cmd.expectedVersion !== previous.version) throw new RuleError('STALE_VERSION');
            if (cmd.expectedPhaseId !== previous.publicState.phaseId) throw new RuleError('WRONG_PHASE');
            const sessionCommand = ['PAUSE_GAME', 'RESUME_GAME', 'ABANDON_GAME'].includes(cmd.type);
            if (sessionCommand && room.host_player_id !== player.id) throw new RuleError('FORBIDDEN');
            if (cmd.type !== 'ABANDON_GAME' && (sessionCommand ? timerJobs(previous).some(job => Date.parse(job.deadline) <= Date.parse(now)) : dueFor(previous, player.id, now))) throw new RuleError('DEADLINE_EXCEEDED');
            let result: Transition;
            if (sessionCommand) {
              if (cmd.type === 'RESUME_GAME' && !this.requiredOnline(previous)) throw new RuleError('PLAYERS_NOT_READY');
              const reasons: PauseReason[] = cmd.type === 'RESUME_GAME' ? [] : [...new Set<PauseReason>([...previous.publicState.pauseReasons, 'MANUAL'])];
              result = this.sessionResult(previous, reasons, now, cmd.type, player.id);
              await this.persist(db, room, previous, result, player.id, cmd, cmd.type === 'ABANDON_GAME' ? 'ABANDONED' : undefined);
            } else {
              if (room.status === 'PAUSED') throw new RuleError('GAME_PAUSED');
              // Required absence is checked under the same lock even before its queued pause runs.
              if (!this.requiredOnline(previous)) throw new RuleError('GAME_PAUSED');
              const move = applyCommand(previous, player.id, cmd, context);
              result = { ...move, state: advanceClock(previous, move.state, now, context.random) };
              await this.persist(db, room, previous, result, player.id, cmd);
              if (result.state.clockState.turnExpired && result.state.publicState.phase !== 'DISCARD_REQUIRED' && result.state.publicState.phase !== 'COMPLETE') {
                result.state = await this.continueTimeout(db, room, result.state, systemId(`continuation:${cmd.commandId}`), now);
              }
            }
            response = this.ack(cmd, undefined, result.state.version);
          } catch (error) {
            await db.query('ROLLBACK TO SAVEPOINT game_work');
            if (!(error instanceof RuleError)) throw error;
            response = this.ack(cmd, error.code);
          }
          await db.query('INSERT INTO app.command_receipts(actor_key,command_id,room_id,request_hash,status,response) VALUES ($1,$2,$3,$4,$5,$6)', [actorKey, cmd.commandId, room?.id ?? null, requestHash, response.status, response]);
          this.#faults.beforeCommit?.();
          return response;
        });
        this.#faults.afterCommit?.();
        this.wake(); void this.flush().catch(() => undefined); void this.rooms.flush().catch(() => undefined);
        return ack;
      } catch (error) {
        if (['40001', '40P01', '23505'].includes((error as { code?: string }).code ?? '') && attempt < 2) continue;
        return this.ack(cmd, 'SERVICE_UNAVAILABLE');
      }
    }
    return this.ack(cmd, 'SERVICE_UNAVAILABLE');
  }
  private async member(db: PoolClient, userId: string, roomId: string) {
    const room = (await db.query('SELECT * FROM app.rooms WHERE id=$1 FOR UPDATE', [roomId])).rows[0];
    const own = room && (await db.query('SELECT id FROM app.players WHERE room_id=$1 AND auth_user_id=$2 AND left_at IS NULL', [roomId, userId])).rows[0];
    if (!own) throw new LobbyError('FORBIDDEN');
    const row = (await db.query('SELECT * FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
    return { room, own, row };
  }
  async subscribe(socket: Socket, roomId: string, force = false): Promise<void> {
    await this.serial(roomId, async () => {
      const result = await this.database.transaction(async db => {
        await this.rooms.fence(db); const member = await this.member(db, socket.data.identity.userId, roomId);
        return member.row ? { snapshot: projectGame(this.state(member.row), member.own.id, await this.now(db)), playerId: member.own.id } : null;
      });
      if (!result || !socket.connected) { this.disconnect(socket); return; }
      const old = this.subscriptions.get(socket.id);
      if (force || !old || old.roomId !== roomId || old.version !== result.snapshot.version) {
        if (!isValid('gameSnapshot', result.snapshot)) throw new Error('Invalid stored game projection');
        socket.emit('game.snapshot', result.snapshot);
      }
      this.subscriptions.set(socket.id, { socket, roomId, playerId: result.playerId, userId: socket.data.identity.userId, version: result.snapshot.version });
      this.schedule();
    });
  }
  disconnect(socket: Socket): void { this.wake(); this.subscriptions.delete(socket.id); if (!this.subscriptions.size) { clearTimeout(this.timer); this.timer = undefined; } }
  private schedule(): void {
    if (this.stopped || this.timer || !this.subscriptions.size) return;
    this.timer = setTimeout(() => { this.timer = undefined; void this.flush().catch(() => undefined).finally(() => this.schedule()); }, 2000); this.timer.unref();
  }
  async flush(): Promise<void> {
    if (this.stopped) return;
    const rooms = (await this.database.pool.query("SELECT DISTINCT room_id FROM app.outbox_events WHERE scope='GAME' AND published_at IS NULL ORDER BY room_id")).rows;
    for (const { room_id: roomId } of rooms) await this.serial(roomId, () => this.database.transaction(async db => {
      await this.rooms.fence(db, this.closing);
      await db.query('SELECT id FROM app.rooms WHERE id=$1 FOR UPDATE', [roomId]);
      const members = (await db.query('SELECT id,auth_user_id FROM app.players WHERE room_id=$1 AND left_at IS NULL', [roomId])).rows;
      const rows = (await db.query("SELECT * FROM app.outbox_events WHERE room_id=$1 AND scope='GAME' AND published_at IS NULL ORDER BY to_version FOR UPDATE", [roomId])).rows;
      for (const row of rows) {
        for (const sub of this.subscriptions.values()) {
          if (sub.roomId !== roomId || !sub.socket.connected) continue;
          if (!members.some(p => p.id === sub.playerId && p.auth_user_id === sub.userId) || !Object.hasOwn(row.private_payloads, sub.playerId)) { this.subscriptions.delete(sub.socket.id); sub.socket.emit('session.error', safeError('FORBIDDEN')); continue; }
          if (row.to_version <= sub.version) continue;
          const value = { ...row.public_payload.value, ...(row.public_payload.kind === 'snapshot' ? { privateState: row.private_payloads[sub.playerId] } : { privatePatch: row.private_payloads[sub.playerId] }) };
          const event = row.public_payload.kind === 'snapshot' ? 'game.snapshot' : 'game.delta';
          if (!isValid(event === 'game.snapshot' ? 'gameSnapshot' : 'gameDelta', value)) throw new RepairRequired('Invalid outbox projection');
          // Only payloads committed by the command transaction are emitted. A
          // delivery-marker rollback may repeat them; the client ignores duplicates.
          sub.socket.emit(event, value); sub.version = row.to_version;
          this.#faults.afterSend?.();
        }
        await db.query('UPDATE app.outbox_events SET attempts=attempts+1,published_at=clock_timestamp() WHERE id=$1', [row.id]);
      }
    }));
  }
  async version(socket: Socket, roomId: string): Promise<void> {
    const result = await this.database.transaction(async db => { await this.rooms.fence(db); return { ...await this.member(db, socket.data.identity.userId, roomId), serverTime: await this.now(db) }; });
    if (!result.row) throw new LobbyError('FORBIDDEN');
    socket.emit('game.version', { roomId, version: result.row.version, roomRevision: result.room.revision, serverTime: result.serverTime });
  }
  async activity(userId: string, roomId: string, before: number, limit: number) {
    return this.database.transaction(async db => {
      await this.rooms.fence(db); await this.member(db, userId, roomId);
      const rows = (await db.query('SELECT sequence,public_activity FROM app.move_logs WHERE room_id=$1 AND sequence < $2 ORDER BY sequence DESC LIMIT $3', [roomId, before, limit])).rows;
      return { entries: rows.map(row => ({ sequence: row.sequence, activity: row.public_activity })), nextBefore: rows.length === limit ? rows.at(-1)!.sequence : null };
    });
  }
  private async now(db: PoolClient): Promise<string> { return (await db.query('SELECT clock_timestamp() AS time')).rows[0].time.toISOString(); }
  private requiredOnline(state: CanonicalState): boolean {
    const online = this.rooms.online(state.roomId);
    return online.size > 0 && state.publicState.requiredPlayerIds.every(id => online.has(id));
  }
  private sessionResult(previous: CanonicalState, reasons: PauseReason[], now: string, type: string, actor: string | null = null, freezeAt = now): Transition {
    const state = pauseState(previous, reasons, freezeAt, engineContext().random);
    const message = type === 'ABANDON_GAME' ? 'The host abandoned this game.' : reasons.length ? `Game paused: ${reasons.map(r => r.toLowerCase().replaceAll('_', ' ')).join(', ')}.` : 'Game resumed with its saved time remaining.';
    return { state, effects: [{ type: 'PUBLIC_ACTIVITY', actorPlayerId: actor, action: type, message }], occurredAt: now, randomDraws: [] };
  }
  private async persist(db: PoolClient, room: Row, previous: CanonicalState, result: Transition, actor: string | null, command: Command, status?: string, metadata: Record<string, unknown> = {}): Promise<void> {
    assertInvariants(result.state); assertClock(result.state);
    await db.query(`UPDATE app.game_states SET version=$2,rules_version=$3,schema_version=$4,phase=$5,phase_id=$6,turn_number=$7,active_player_id=$8,
      public_state=$9,private_state=$10,server_state=$11,clock_state=$12,next_deadline_at=$13,updated_at=clock_timestamp() WHERE room_id=$1`, this.values(result.state));
    await this.record(db, previous, result, actor, command, metadata);
    const nextStatus = status ?? (result.state.publicState.phase === 'COMPLETE' ? 'FINISHED' : result.state.publicState.pauseReasons.length ? 'PAUSED' : 'ACTIVE');
    if (nextStatus !== room.status) {
      await db.query("UPDATE app.rooms SET status=$2,active_slot=CASE WHEN $2 IN ('FINISHED','ABANDONED') THEN NULL ELSE 1 END,ended_at=CASE WHEN $2 IN ('FINISHED','ABANDONED') THEN clock_timestamp() ELSE NULL END WHERE id=$1", [room.id,nextStatus]);
      Object.assign(room, await this.rooms.changed(db, room));
    }
  }
  private internal(state: CanonicalState, type: string, key: string): Command {
    return { protocolVersion: 1, commandId: systemId(key), roomId: state.roomId, expectedVersion: state.version, expectedPhaseId: state.publicState.phaseId, type, payload: {} };
  }
  private async changePause(db: PoolClient, room: Row, previous: CanonicalState, reasons: PauseReason[], now: string, type: string, freezeAt = now): Promise<CanonicalState> {
    if ([...new Set(reasons)].sort().join() === [...previous.publicState.pauseReasons].sort().join()) return previous;
    const command = this.internal(previous, type, `${this.rooms.epoch}:${room.id}:${previous.version}:${type}`);
    const result = this.sessionResult(previous, reasons, now, type, null, freezeAt);
    await this.persist(db, room, previous, result, null, command, undefined, { freezeAt, sessionState: { pauseReasons: result.state.publicState.pauseReasons, clockState: result.state.clockState } });
    await db.query("INSERT INTO app.command_receipts(actor_key,command_id,room_id,request_hash,status,response) VALUES ('system:session',$1,$2,$3,'ACCEPTED',$4)", [command.commandId,room.id,hash(canonical(command)),this.ack(command,undefined,result.state.version)]);
    return result.state;
  }
  private async continueTimeout(db: PoolClient, room: Row, initial: CanonicalState, rootId: string, now: string, discarder?: string): Promise<CanonicalState> {
    let state = initial;
    const random = engineContext().random;
    // Knight before rolling may require robber, victim, roll, robber and end turn.
    for (let step = 0; step < 12; step++) {
      const move = fallback(state, rootId, step, now, random, step === 0 ? discarder : undefined);
      await this.persist(db, room, state, move.result, null, move.command, undefined, { actingPlayerId: move.actor, selectionDraws: move.selectionDraws, timeoutRoot: rootId });
      state = move.result.state;
      if (!state.clockState.turnExpired || state.publicState.phase === 'DISCARD_REQUIRED' || state.publicState.phase === 'COMPLETE') return state;
    }
    throw new Error('Unbounded mandatory timeout continuation');
  }
  /** Internal entry point only: current DB phase/generation/deadline, not caller version, grants authority. */
  async runTimer(job: TimerJob): Promise<'APPLIED' | 'STALE' | 'EARLY'> {
    const result = await this.database.transaction(async db => {
      await this.rooms.fence(db);
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [`system:timer:${job.commandId}`]);
      const receipt = (await db.query("SELECT 1 FROM app.command_receipts WHERE actor_key='system:timer' AND command_id=$1", [job.commandId])).rowCount;
      if (receipt) return 'STALE' as const;
      const room = (await db.query('SELECT * FROM app.rooms WHERE id=$1 FOR UPDATE',[job.roomId])).rows[0];
      if (!room || room.status !== 'ACTIVE') return 'STALE' as const;
      this.rooms.assertOwnership(room.runtime_epoch);
      const row = (await db.query('SELECT * FROM app.game_states WHERE room_id=$1 FOR UPDATE',[job.roomId])).rows[0];
      const state = this.state(row), now = await this.now(db);
      if (!matchesJob(state,job)) return 'STALE' as const;
      if (Date.parse(job.deadline) > Date.parse(now)) return 'EARLY' as const;
      const next = await this.continueTimeout(db, room, state, job.commandId, now, job.playerId ?? undefined);
      await db.query("INSERT INTO app.command_receipts(actor_key,command_id,room_id,request_hash,status,response) VALUES ('system:timer',$1,$2,$3,'ACCEPTED',$4)", [job.commandId,room.id,hash(canonical(job)),{commandId:job.commandId,status:'ACCEPTED',scope:'GAME',roomId:room.id,version:next.version,serverTime:now}]);
      return 'APPLIED' as const;
    });
    this.wake(); void this.flush().catch(() => undefined); void this.rooms.flush().catch(() => undefined);
    return result;
  }
  /** Boot holds the exclusive global fence; outage/shutdown recovery holds its shared fence. */
  async recover(db: PoolClient, reason: 'RECOVERY' | 'DATABASE_UNAVAILABLE', exact = false): Promise<void> {
    const rooms = (await db.query('SELECT * FROM app.rooms WHERE active_slot=1 ORDER BY id FOR UPDATE')).rows;
    for (const room of rooms) {
      await db.query('UPDATE app.rooms SET runtime_epoch=$2 WHERE id=$1',[room.id,this.rooms.epoch]); room.runtime_epoch = this.rooms.epoch;
      if (room.status === 'LOBBY') continue;
      const row = (await db.query('SELECT * FROM app.game_states WHERE room_id=$1 FOR UPDATE',[room.id])).rows[0];
      if (!row) throw new RepairRequired('Missing saved game; repair required');
      const previous = this.state(row), now = await this.now(db);
      const checkpoint = Math.min(Date.parse(now), Math.max(row.updated_at.getTime(), room.runtime_heartbeat_at?.getTime() ?? row.updated_at.getTime()));
      await this.changePause(db, room, previous, [...new Set<PauseReason>([...previous.publicState.pauseReasons, reason])], now, 'RECOVER_GAME', exact ? now : new Date(checkpoint).toISOString());
    }
  }
  private storageLost(): void {
    if (this.stopped || this.closing) return;
    this.unavailable = true;
    for (const sub of this.subscriptions.values()) sub.socket.emit('session.error', safeError('SERVICE_UNAVAILABLE'));
    this.wake(1000);
  }
  wake(delay = 0): void {
    if (this.stopped || this.closing || this.repairRequired) return;
    if (this.ticking) { this.wakeRequested = true; return; }
    clearTimeout(this.runtimeTimer);
    this.runtimeTimer = setTimeout(() => { this.runtimeTimer = undefined; void this.tick(); }, delay); this.runtimeTimer.unref();
  }
  async tick(): Promise<void> {
    if (this.ticking || this.stopped || this.closing || this.repairRequired) return;
    this.ticking = true;
    let delay: number | null = null;
    try {
      if (this.unavailable) {
        await this.database.transaction(async db => { await this.rooms.fence(db, true); await this.recover(db, 'DATABASE_UNAVAILABLE'); });
        this.unavailable = false;
      }
      // Capture jobs without holding the room lock while acquiring the timer advisory lock.
      const jobs = this.clocksRunning ? await this.database.transaction(async db => {
        await this.rooms.fence(db);
        const rows = (await db.query("SELECT g.* FROM app.game_states g JOIN app.rooms r ON r.id=g.room_id WHERE r.status='ACTIVE' AND r.runtime_epoch=$1 AND g.next_deadline_at <= clock_timestamp() ORDER BY g.room_id",[this.rooms.epoch])).rows;
        return rows.flatMap(row => timerJobs(this.state(row)));
      }) : [];
      for (const job of jobs) await this.runTimer(job);
      let clocksRunning = false;
      await this.database.transaction(async db => {
        await this.rooms.fence(db);
        const rooms = (await db.query("SELECT * FROM app.rooms WHERE status IN ('ACTIVE','PAUSED') ORDER BY id FOR UPDATE")).rows;
        for (const room of rooms) {
          this.rooms.assertOwnership(room.runtime_epoch);
          const row = (await db.query('SELECT * FROM app.game_states WHERE room_id=$1 FOR UPDATE',[room.id])).rows[0];
          if (!row) throw new RepairRequired('Missing saved game; repair required');
          let state = this.state(row); const now = await this.now(db);
          // Manual/recovery pauses require an explicit host resume regardless of
          // presence. Reconnecting phones must not toggle DISCONNECTED here:
          // each toggle otherwise writes state, a log, a receipt and an outbox
          // event forever while the saved game itself has not changed. Presence
          // is delivered separately; RESUME_GAME checks requiredOnline under
          // the room lock. Keep legacy combined reasons intact until that resume.
          if (state.publicState.pauseReasons.some(reason => reason !== 'DISCONNECTED')) continue;
          // A deadline crossed since job collection. Resolve it on the next tick before pausing.
          if (timerJobs(state).some(job => Date.parse(job.deadline) <= Date.parse(now))) { clocksRunning = true; delay = 0; continue; }
          const reasons = new Set<PauseReason>(state.publicState.pauseReasons);
          if (this.requiredOnline(state)) reasons.delete('DISCONNECTED'); else reasons.add('DISCONNECTED');
          state = await this.changePause(db,room,state,[...reasons],now,'PRESENCE_PAUSE');
          if (room.status === 'ACTIVE') {
            clocksRunning ||= nextDeadline(state) !== null;
            await db.query("UPDATE app.rooms SET runtime_heartbeat_at=clock_timestamp() WHERE id=$1 AND runtime_epoch=$2 AND (runtime_heartbeat_at IS NULL OR runtime_heartbeat_at < clock_timestamp()-interval '15 seconds')",[room.id,this.rooms.epoch]);
            delay = Math.min(delay ?? 15000, nextDeadline(state) ? 250 : 15000);
          }
        }
      });
      this.clocksRunning = clocksRunning;
      await this.flush(); await this.rooms.flush();
    } catch (error) {
      if (this.unavailable) delay = 1000;
      else if ((error as {code?:string}).code === 'SERVICE_UNAVAILABLE') delay = null; // Lost epoch: retired by fence.
      else if (error instanceof RepairRequired) {
        // Never create a replacement state after a corrupt/incompatible persisted row.
        this.repairRequired = true;
        for (const sub of this.subscriptions.values()) sub.socket.emit('session.error', safeError('SERVICE_UNAVAILABLE'));
        console.error('Game recovery requires inspection; saved state was not replaced.');
      } else delay = 1000;
    } finally { this.ticking = false; if (this.wakeRequested) { this.wakeRequested = false; this.wake(); } else if (delay !== null) this.wake(delay); }
  }
  async beforeApplicationShutdown(): Promise<void> {
    if (this.stopped) return;
    this.closing = true; clearTimeout(this.runtimeTimer);
    try {
      await this.database.transaction(async db => { await this.rooms.fence(db,true); await this.recover(db,'RECOVERY',true); });
      await this.flush();
    } catch { /* A replacement epoch or an outage recovers from the last checkpoint on next boot. */ }
  }
  stop(): void { this.stopped = true; clearTimeout(this.timer); clearTimeout(this.runtimeTimer); }
  onApplicationShutdown(): void { this.stop(); this.subscriptions.clear(); }

}
