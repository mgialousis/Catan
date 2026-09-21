import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { io } from 'socket.io-client';
import { createApp } from '../../apps/server/dist/app.js';
import { loadConfig } from '../../apps/server/dist/config.js';
import { isValid } from '../../packages/protocol/dist/index.js';
import { assertInvariants, chooseCommand, projectPlayer, seedFrom } from '../../packages/game-engine/dist/index.js';
import { botPace } from '../../apps/server/dist/bot-runner.js';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(check, ms = 30000) {
  for (const end = Date.now() + ms; Date.now() < end;) { if (await check()) return true; await sleep(100); }
  return false;
}

test('a solo practice game seats bots and they play it themselves', async t => {
  const admin = new Client({ connectionString: local.adminDatabaseUrl });
  await admin.connect();
  let app, base, socket, roomId;
  const settings = { maxPlayers: 4, turnLimitSeconds: null, boardMode: 'STANDARD_RANDOM', rulesVersion: 'base-2020-v1', botDifficulty: 'MEDIUM' };
  t.after(async () => {
    // Stop the runtime before removing anything. The runner keeps playing an
    // active game, so deleting first leaves rows written after the delete.
    try { socket?.disconnect(); } catch { /* already closed */ }
    await sleep(100);
    await app?.close(); app = undefined;
    // Never remove unrelated data: only the room this test created.
    if (roomId) {
      await admin.query('BEGIN');
      await admin.query('SET CONSTRAINTS ALL DEFERRED');
      await admin.query('UPDATE app.rooms SET host_player_id=null WHERE id=$1', [roomId]);
      for (const table of ['outbox_events', 'move_logs', 'command_receipts', 'game_states', 'players']) {
        await admin.query(`DELETE FROM app.${table} WHERE room_id=$1`, [roomId]);
      }
      await admin.query('DELETE FROM app.rooms WHERE id=$1', [roomId]);
      await admin.query('COMMIT');
    }
    await admin.end();
  });

  app = await createApp({ ...loadConfig(), port: 0 }); await app.listen(0, '127.0.0.1'); base = await app.getUrl();
  const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(response.status, 200);
  const guest = await response.json();

  socket = io(`${base}/game`, { transports: ['websocket'], reconnection: false, autoConnect: false, forceNew: true,
    auth: { accessToken: guest.access_token, protocolVersion: 1, clientInstanceId: randomUUID() } });
  let view;
  socket.on('game.snapshot', v => { assert.ok(isValid('gameSnapshot', v)); view = v; });
  socket.on('game.delta', v => { assert.ok(isValid('gameDelta', v)); });
  const hello = new Promise((resolve, reject) => { socket.once('server.hello', resolve); socket.once('connect_error', reject); });
  socket.connect(); await hello;

  // Subscribe the way a real client does. Presence is what keeps a game
  // running, and the person is the only presence a practice room has.
  const subscribed = async id => {
    socket.emit('session.subscribe', { requestId: randomUUID(), roomId: id, lastRoomRevision: null, lastGameVersion: null });
    socket.emit('game.sync', { requestId: randomUUID(), roomId: id, lastGameVersion: null });
    await sleep(250);
  };
  const created = await socket.timeout(6000).emitWithAck('room.command', {
    protocolVersion: 1, commandId: randomUUID(), roomId: null, expectedVersion: null, expectedPhaseId: null,
    type: 'CREATE_ROOM', payload: { nickname: 'Practice host', settings, bots: 3 },
  });
  assert.equal(created.status, 'ACCEPTED', JSON.stringify(created));
  roomId = created.roomId;
  await subscribed(roomId);

  await t.test('the room takes no live slot and seats three automated players', async () => {
    const room = (await admin.query('SELECT mode, active_slot FROM app.rooms WHERE id=$1', [roomId])).rows[0];
    assert.equal(room.mode, 'PRACTICE');
    assert.equal(room.active_slot, null, 'a practice room never competes for the live game');
    const seats = (await admin.query('SELECT kind, auth_user_id, ready FROM app.players WHERE room_id=$1 ORDER BY seat_index', [roomId])).rows;
    assert.equal(seats.length, 4);
    assert.equal(seats[0].kind, 'HUMAN');
    assert.ok(seats[0].auth_user_id, 'the person keeps their identity');
    for (const bot of seats.slice(1)) {
      assert.equal(bot.kind, 'BOT');
      assert.equal(bot.auth_user_id, null, 'an automated seat holds no identity');
      assert.equal(bot.ready, true, 'nothing waits on an automated seat');
    }
  });

  await t.test('it starts with only one person present', async () => {
    // Only the person has to declare themselves ready; the bots arrived ready.
    const first = (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision;
    const ready = await socket.timeout(6000).emitWithAck('room.command', {
      protocolVersion: 1, commandId: randomUUID(), roomId, expectedVersion: first, expectedPhaseId: null,
      type: 'SET_READY', payload: { ready: true },
    });
    assert.equal(ready.status, 'ACCEPTED', JSON.stringify(ready));
    const revision = (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision;
    const started = await socket.timeout(6000).emitWithAck('room.command', {
      protocolVersion: 1, commandId: randomUUID(), roomId, expectedVersion: revision, expectedPhaseId: null,
      type: 'START_GAME', payload: {},
    });
    assert.equal(started.status, 'ACCEPTED', JSON.stringify(started));
    await subscribed(roomId);
    assert.ok(await until(async () => view?.version >= 0), 'the person received the opening snapshot');
  });

  await t.test('the automated seats take their own turns unattended', async () => {
    const saved = (await admin.query('SELECT public_state FROM app.game_states WHERE room_id=$1', [roomId])).rows[0].public_state;
    const kinds = Object.values(saved.players).map(p => p.kind ?? 'HUMAN').sort();
    assert.deepEqual(kinds, ['BOT', 'BOT', 'BOT', 'HUMAN'], 'the saved game knows which seats are automated');
    const botIds = (await admin.query("SELECT id FROM app.players WHERE room_id=$1 AND kind='BOT'", [roomId])).rows.map(r => r.id);
    const before = (await admin.query('SELECT version FROM app.game_states WHERE room_id=$1', [roomId])).rows[0].version;
    const playerId = (await admin.query("SELECT id FROM app.players WHERE room_id=$1 AND kind='HUMAN'", [roomId])).rows[0].id;
    // The person still plays their own turns; nothing here touches the bots'.
    const moved = await until(async () => {
      const row = (await admin.query('SELECT * FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
      const moves = (await admin.query('SELECT count(*)::int n FROM app.move_logs WHERE room_id=$1 AND actor_player_id = ANY($2)', [roomId, botIds])).rows[0].n;
      if (moves >= 3) return true;
      if (!row.public_state.requiredPlayerIds.includes(playerId)) return false;
      const state = { roomId, version: row.version, rulesVersion: row.rules_version, stateSchemaVersion: 1, protocolVersion: 1,
        publicState: row.public_state, privateState: row.private_state, serverState: row.server_state, clockState: row.clock_state };
      const move = chooseCommand(
        { publicState: state.publicState, hand: projectPlayer(state, playerId) },
        { developmentCardsRemaining: state.serverState.developmentDeck.length,
          pendingSetupVertexId: state.serverState.setup?.pendingVertexId ?? null,
          eligibleVictimIds: state.serverState.effect?.eligiblePlayerIds,
          bankStock: state.serverState.bank },
        'MEDIUM', seedFrom(roomId, state.version, state.publicState.phaseId, playerId));
      if (!move) return false;
      await socket.timeout(6000).emitWithAck('game.command', {
        protocolVersion: 1, commandId: randomUUID(), roomId,
        expectedVersion: state.version, expectedPhaseId: state.publicState.phaseId,
        type: move.type, payload: move.payload,
      });
      return false;
    }, 60000);
    const counts = (await admin.query(`SELECT p.kind, count(*)::int n FROM app.move_logs m
      JOIN app.players p ON p.id=m.actor_player_id WHERE m.room_id=$1 GROUP BY p.kind`, [roomId])).rows;
    const phase = (await admin.query('SELECT phase, version FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
    assert.ok(moved, `automated seats took their turns without being driven (moves by kind: ${JSON.stringify(counts)}, ${JSON.stringify(phase)})`);
    const after = (await admin.query('SELECT version, public_state FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
    assert.ok(after.version > before, 'the saved game advanced');
    assert.deepEqual(after.public_state.pauseReasons, [], 'a room of one person never pauses itself');
    assertInvariants({
      roomId, version: after.version, rulesVersion: 'base-2020-v1', stateSchemaVersion: 1, protocolVersion: 1,
      publicState: after.public_state,
      ...(await admin.query('SELECT private_state, server_state, clock_state FROM app.game_states WHERE room_id=$1', [roomId]))
        .rows.map(r => ({ privateState: r.private_state, serverState: r.server_state, clockState: r.clock_state }))[0],
    });
  });

  await t.test('every automated move is recorded against its own seat', async () => {
    const rows = (await admin.query(`SELECT m.actor_player_id, p.kind FROM app.move_logs m
      JOIN app.players p ON p.id = m.actor_player_id WHERE m.room_id=$1`, [roomId])).rows;
    assert.ok(rows.some(r => r.kind === 'BOT'), 'bot moves are attributed, not anonymous');
    const receipts = (await admin.query("SELECT count(*)::int n FROM app.command_receipts WHERE room_id=$1 AND actor_key='system:bot'", [roomId])).rows[0].n;
    assert.ok(receipts > 0, 'each automated move leaves a durable receipt, so a retry cannot repeat it');
  });

  await t.test('the database-backed runner waits for opening presentations', async () => {
    const moves = (await admin.query(`SELECT m.command_type, m.public_activity, m.created_at, p.kind
      FROM app.move_logs m LEFT JOIN app.players p ON p.id=m.actor_player_id
      WHERE m.room_id=$1 ORDER BY m.sequence`, [roomId])).rows;
    let checked = 0;
    for (let i = 1; i < moves.length; i++) {
      const previous = moves[i - 1], next = moves[i];
      if (next.kind !== 'BOT' || !previous.command_type.startsWith('PLACE_SETUP_')) continue;
      const elapsed = next.created_at.getTime() - previous.created_at.getTime();
      assert.ok(elapsed >= botPace(previous.command_type) - 30,
        `${previous.command_type} only waited ${elapsed}ms before the next bot`);
      checked++;
    }
    assert.ok(checked >= 2, 'observed consecutive opening moves through the real runner');
  });
});
