import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { io } from 'socket.io-client';
import { createApp } from '../../apps/server/dist/app.js';
import { loadConfig } from '../../apps/server/dist/config.js';
import { Games } from '../../apps/server/dist/games.js';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(check, ms = 60000) {
  for (const end = Date.now() + ms; Date.now() < end;) { if (await check()) return true; await sleep(100); }
  return false;
}
const settings = { maxPlayers: 4, turnLimitSeconds: null, boardMode: 'STANDARD_RANDOM', rulesVersion: 'base-2020-v1', botDifficulty: 'MEDIUM' };
const command = (roomId, type, payload = {}, expectedVersion = null, expectedPhaseId = null) =>
  ({ protocolVersion: 1, commandId: randomUUID(), roomId, expectedVersion, expectedPhaseId, type, payload });

async function signup() {
  const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(response.status, 200);
  return response.json();
}
function connect(base, guest) {
  const socket = io(`${base}/game`, { transports: ['websocket'], reconnection: false, autoConnect: false, forceNew: true,
    auth: { accessToken: guest.access_token, protocolVersion: 1, clientInstanceId: randomUUID() } });
  return new Promise((resolve, reject) => {
    socket.once('server.hello', () => resolve(socket));
    socket.once('connect_error', error => { socket.close(); reject(error); });
    socket.connect();
  });
}
async function subscribe(socket, roomId) {
  socket.emit('session.subscribe', { requestId: randomUUID(), roomId, lastRoomRevision: null, lastGameVersion: null });
  socket.emit('game.sync', { requestId: randomUUID(), roomId, lastGameVersion: null });
  await sleep(250);
}

test('the tick visits only games whose presence can change, one at a time', { timeout: 240000 }, async t => {
  const admin = new Client({ connectionString: local.adminDatabaseUrl });
  await admin.connect();
  const validations = new Map();
  const faults = { validated: roomId => validations.set(roomId, (validations.get(roomId) ?? 0) + 1) };
  const guests = [await signup(), await signup()], rooms = [], sockets = [];
  const app = await createApp({ ...loadConfig(), port: 0 }, { gameFaults: faults });
  await app.listen(0, '127.0.0.1');
  const base = await app.getUrl(), games = app.get(Games);
  t.after(async () => {
    for (const socket of sockets) try { socket.disconnect(); } catch { /* already closed */ }
    await sleep(100); await app.close();
    for (const roomId of rooms) {
      await admin.query('BEGIN'); await admin.query('SET CONSTRAINTS ALL DEFERRED');
      await admin.query('UPDATE app.rooms SET host_player_id=null WHERE id=$1', [roomId]);
      for (const table of ['outbox_events', 'move_logs', 'command_receipts', 'game_states', 'players']) await admin.query(`DELETE FROM app.${table} WHERE room_id=$1`, [roomId]);
      await admin.query('DELETE FROM app.rooms WHERE id=$1', [roomId]);
      await admin.query('COMMIT');
    }
    for (const guest of guests) await admin.query('DELETE FROM app.command_receipts WHERE actor_key=$1', [`user:${guest.user.id}`]);
    await admin.end();
  });
  const row = async roomId => (await admin.query('SELECT * FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
  const human = async roomId => (await admin.query("SELECT id FROM app.players WHERE room_id=$1 AND kind='HUMAN'", [roomId])).rows[0].id;
  // Idle means the bots are waiting on the person, so nothing writes the game.
  const idle = async roomId => { const person = await human(roomId); return until(async () => (await row(roomId)).public_state.requiredPlayerIds.includes(person)); };
  // One whole pass, never overlapping the runtime's own scheduled one.
  async function pass() {
    assert.ok(await until(() => !games.ticking, 10000));
    clearTimeout(games.runtimeTimer);
    await games.tick();
  }
  const host = async (socket, roomId, type) => {
    const saved = await row(roomId);
    return socket.timeout(8000).emitWithAck('game.command', command(roomId, type, {}, saved.version, saved.phase_id));
  };

  for (const guest of guests) {
    const socket = await connect(base, guest); sockets.push(socket);
    const created = await socket.timeout(6000).emitWithAck('room.command', command(null, 'CREATE_ROOM', { nickname: 'Tick host', settings, bots: 3 }));
    assert.equal(created.status, 'ACCEPTED', JSON.stringify(created));
    rooms.push(created.roomId);
    await subscribe(socket, created.roomId);
    const revision = async () => (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [created.roomId])).rows[0].revision;
    assert.equal((await socket.timeout(6000).emitWithAck('room.command', command(created.roomId, 'SET_READY', { ready: true }, await revision()))).status, 'ACCEPTED');
    assert.equal((await socket.timeout(6000).emitWithAck('room.command', command(created.roomId, 'START_GAME', {}, await revision()))).status, 'ACCEPTED');
    await subscribe(socket, created.roomId);
  }
  const [a, b] = rooms;
  assert.ok(await idle(a) && await idle(b), 'both games settled on their person');

  await t.test('an unchanged game is validated once, not on every pass', async () => {
    await pass();
    const before = { a: validations.get(a) ?? 0, b: validations.get(b) ?? 0 };
    for (let i = 0; i < 5; i++) await pass();
    assert.equal(validations.get(a) ?? 0, before.a, 'no row changed, so nothing was re-validated');
    assert.equal(validations.get(b) ?? 0, before.b);
    // Any write to the row counts as a change -- even one that leaves the game
    // version alone, like a manual repair would -- so the cache never hides one.
    await admin.query("UPDATE app.game_states SET updated_at=updated_at+interval '1 millisecond' WHERE room_id=$1", [b]);
    await pass();
    assert.equal(validations.get(b), before.b + 1, 'the rewritten row was validated again, exactly once');
    for (let i = 0; i < 3; i++) await pass();
    assert.equal(validations.get(b), before.b + 1);
  });

  await t.test('a game paused for the host is never locked or parsed by the tick', async () => {
    assert.equal((await host(sockets[0], a, 'PAUSE_GAME')).status, 'ACCEPTED');
    assert.ok(await until(async () => (await admin.query('SELECT status FROM app.rooms WHERE id=$1', [a])).rows[0].status === 'PAUSED'));
    await pass();
    // Damage it. Reading it now would isolate it on the spot, so staying
    // unisolated through several passes shows none of them read it.
    await admin.query('UPDATE app.game_states SET turn_number=turn_number+1000 WHERE room_id=$1', [a]);
    const before = validations.get(a) ?? 0;
    for (let i = 0; i < 5; i++) await pass();
    assert.ok(!games.isIsolated(a), 'the tick never read the host-paused game');
    assert.equal(validations.get(a) ?? 0, before);
    await admin.query('UPDATE app.game_states SET turn_number=turn_number-1000 WHERE room_id=$1', [a]);
    assert.equal((await host(sockets[0], a, 'RESUME_GAME')).status, 'ACCEPTED');
  });

  await t.test('a move in one game never waits on the tick holding another', async () => {
    assert.ok(await idle(a) && await idle(b), 'both games settled again');
    const [lower, higher] = [a, b].sort();
    const socket = sockets[rooms.indexOf(lower)];
    // Stand in for a slow command in the higher game by holding its room row.
    // The old pass locked every room in id order, so it would hold the lower
    // game while waiting here, and a move in the lower game would wait too.
    const holder = new Client({ connectionString: local.adminDatabaseUrl }); await holder.connect();
    await holder.query('BEGIN');
    await holder.query('SELECT id FROM app.rooms WHERE id=$1 FOR UPDATE', [higher]);
    assert.ok(await until(() => !games.ticking, 10000)); clearTimeout(games.runtimeTimer);
    const ticking = games.tick();
    await sleep(300);
    const release = setTimeout(() => void holder.query('ROLLBACK').catch(() => undefined), 3000);
    const started = Date.now();
    const ack = await host(socket, lower, 'PAUSE_GAME');
    const waited = Date.now() - started;
    clearTimeout(release);
    await holder.query('ROLLBACK').catch(() => undefined); await holder.end();
    await ticking;
    assert.equal(ack.status, 'ACCEPTED', JSON.stringify(ack));
    t.diagnostic(`the move was acknowledged in ${waited}ms while another game's room was held`);
    assert.ok(waited < 1500, `the move waited ${waited}ms behind another game`);
  });
});
