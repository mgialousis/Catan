import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { io } from 'socket.io-client';
import { createApp } from '../../apps/server/dist/app.js';
import { loadConfig } from '../../apps/server/dist/config.js';
import { Games } from '../../apps/server/dist/games.js';
import { chooseCommand, projectPlayer, seedFrom } from '../../packages/game-engine/dist/index.js';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(check, ms = 30000) {
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
  const errors = [];
  socket.on('session.error', e => errors.push(e.code));
  return new Promise((resolve, reject) => {
    socket.once('server.hello', () => resolve({ socket, errors }));
    socket.once('connect_error', error => { socket.close(); reject(error); });
    socket.connect();
  });
}
async function subscribe(socket, roomId) {
  socket.emit('session.subscribe', { requestId: randomUUID(), roomId, lastRoomRevision: null, lastGameVersion: null });
  socket.emit('game.sync', { requestId: randomUUID(), roomId, lastGameVersion: null });
  await sleep(250);
}

test('one broken game is isolated while every other game carries on', { timeout: 180000 }, async t => {
  const admin = new Client({ connectionString: local.adminDatabaseUrl });
  await admin.connect();
  const guests = [await signup(), await signup()], rooms = [], sockets = [];
  let app, base;
  const start = async () => {
    app = await createApp({ ...loadConfig(), port: 0 }); await app.listen(0, '127.0.0.1'); base = await app.getUrl();
  };
  t.after(async () => {
    // Stop the runtime before removing anything: bots keep playing an active game.
    for (const socket of sockets) try { socket.disconnect(); } catch { /* already closed */ }
    await sleep(100); await app?.close();
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
  // Plays the person's own seat once, when it is their turn, the way they would.
  async function humanMove(socket, roomId) {
    const saved = await row(roomId), playerId = await human(roomId);
    const state = { roomId, version: saved.version, rulesVersion: saved.rules_version, stateSchemaVersion: 1, protocolVersion: 1,
      publicState: saved.public_state, privateState: saved.private_state, serverState: saved.server_state, clockState: saved.clock_state };
    const move = chooseCommand({ publicState: state.publicState, hand: projectPlayer(state, playerId) },
      { developmentCardsRemaining: state.serverState.developmentDeck.length, pendingSetupVertexId: state.serverState.setup?.pendingVertexId ?? null,
        eligibleVictimIds: state.serverState.effect?.eligiblePlayerIds, bankStock: state.serverState.bank },
      'MEDIUM', seedFrom(roomId, state.version, state.publicState.phaseId, playerId));
    return socket.timeout(6000).emitWithAck('game.command',
      command(roomId, move.type, move.payload, state.version, state.publicState.phaseId));
  }

  await start();
  const players = await Promise.all(guests.map(guest => connect(base, guest)));
  sockets.push(...players.map(p => p.socket));
  for (const { socket } of players) {
    const created = await socket.timeout(6000).emitWithAck('room.command', command(null, 'CREATE_ROOM', { nickname: 'Isolation host', settings, bots: 3 }));
    assert.equal(created.status, 'ACCEPTED', JSON.stringify(created));
    rooms.push(created.roomId);
    await subscribe(socket, created.roomId);
    const revision = async () => (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [created.roomId])).rows[0].revision;
    assert.equal((await socket.timeout(6000).emitWithAck('room.command', command(created.roomId, 'SET_READY', { ready: true }, await revision()))).status, 'ACCEPTED');
    assert.equal((await socket.timeout(6000).emitWithAck('room.command', command(created.roomId, 'START_GAME', {}, await revision()))).status, 'ACCEPTED');
    await subscribe(socket, created.roomId);
  }
  const [broken, healthy] = rooms, [brokenPlayer, healthyPlayer] = players;
  const games = () => app.get(Games);

  await t.test('damaging one saved game isolates only that game', async () => {
    // Wait until its bots are waiting on the person, so no automated move is in
    // flight to write the whole row back over the damage.
    const person = await human(broken);
    assert.ok(await until(async () => (await row(broken)).public_state.requiredPlayerIds.includes(person)), 'the broken game settled on its person');
    const before = await row(broken);
    await admin.query('UPDATE app.game_states SET turn_number=turn_number+1000 WHERE room_id=$1', [broken]);
    // With both games waiting on their people the runtime only ticks on its
    // 15-second heartbeat, so ask for the next pass rather than wait for it.
    games().wake();
    assert.ok(await until(() => games().isIsolated(broken), 10000), 'the damaged game was isolated');
    assert.ok(!games().isIsolated(healthy));
    assert.equal(games().storageReady, true, 'the service stays ready for everybody else');
    assert.equal((await fetch(`${base}/health/ready`)).status, 200);
    const refused = await brokenPlayer.socket.timeout(6000).emitWithAck('game.command',
      command(broken, 'ROLL_DICE', {}, before.version, before.phase_id));
    assert.equal(refused.error.code, 'SERVICE_UNAVAILABLE');
    assert.ok(await until(() => brokenPlayer.errors.includes('SERVICE_UNAVAILABLE'), 5000), 'its player is told the game is unavailable');
    const after = await row(broken);
    assert.equal(after.version, before.version, 'nothing is written to a state the runtime cannot trust');
    assert.deepEqual(after.private_state, before.private_state);
  });

  await t.test('the healthy game keeps playing, bots included', async () => {
    const before = (await row(healthy)).version, person = await human(healthy);
    const bots = (await admin.query("SELECT id FROM app.players WHERE room_id=$1 AND kind='BOT'", [healthy])).rows.map(r => r.id);
    const botMoves = async () => (await admin.query('SELECT count(*)::int n FROM app.move_logs WHERE room_id=$1 AND sequence>$2 AND actor_player_id = ANY($3)', [healthy, before, bots])).rows[0].n;
    let accepted = 0;
    // Whoever the turn order put first, the person plays when asked and the bots answer.
    const played = await until(async () => {
      if (accepted && await botMoves() >= 2) return true;
      if (!(await row(healthy)).public_state.requiredPlayerIds.includes(person)) return false;
      const ack = await humanMove(healthyPlayer.socket, healthy);
      if (ack.status === 'ACCEPTED') accepted++;
      return false;
    }, 60000);
    assert.ok(played, `the person played (${accepted}) and automated seats answered (${await botMoves()})`);
  });

  await t.test('a restart with the damage still there boots and recovers everything else', async () => {
    const damaged = await row(broken);
    for (const socket of sockets) socket.disconnect();
    await app.close(); await start();
    assert.equal((await fetch(`${base}/health/ready`)).status, 200, 'this used to crash-loop on startup');
    assert.ok(games().isIsolated(broken));
    const kept = await row(broken);
    assert.equal(kept.version, damaged.version); assert.deepEqual(kept.private_state, damaged.private_state);
    // The healthy game was paused by recovery like any other, and resumes normally.
    assert.ok((await row(healthy)).public_state.pauseReasons.includes('RECOVERY'));
    const again = await connect(base, guests[1]); sockets.push(again.socket);
    await subscribe(again.socket, healthy);
    const paused = await row(healthy);
    const resumed = await again.socket.timeout(6000).emitWithAck('game.command', command(healthy, 'RESUME_GAME', {}, paused.version, paused.phase_id));
    assert.equal(resumed.status, 'ACCEPTED', JSON.stringify(resumed));
  });

  await t.test('one person reconnecting in a loop is throttled without locking anyone else out', async () => {
    // 30 per minute per person. Before this limit existed the only one was
    // keyed on the address, which behind the hosting proxy every player shares.
    let refused = null;
    for (let attempt = 0; attempt < 31 && !refused; attempt++) {
      try { const c = await connect(base, guests[0]); c.socket.disconnect(); }
      catch (error) { refused = error; }
    }
    assert.ok(refused, 'the looping client was stopped');
    assert.equal(refused.data?.code, 'RATE_LIMITED');
    const other = await connect(base, guests[1]); sockets.push(other.socket);
    assert.ok(other.socket.connected, 'a different person still connects');
  });
});
