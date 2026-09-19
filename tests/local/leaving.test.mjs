import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { io } from 'socket.io-client';
import { createApp } from '../../apps/server/dist/app.js';
import { loadConfig } from '../../apps/server/dist/config.js';
import { isValid } from '../../packages/protocol/dist/index.js';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(check, ms = 20000) {
  for (const end = Date.now() + ms; Date.now() < end;) { if (await check()) return true; await sleep(100); }
  return false;
}

test('a player can walk out and the table carries on with a bot', async t => {
  const admin = new Client({ connectionString: local.adminDatabaseUrl });
  await admin.connect();
  let app, base, roomId;
  const clients = [];
  const settings = { maxPlayers: 4, turnLimitSeconds: null, boardMode: 'STANDARD_RANDOM', rulesVersion: 'base-2020-v1' };
  t.after(async () => {
    for (const c of clients) { try { c.socket.disconnect(); } catch { /* closed */ } }
    await sleep(100);
    await app?.close(); app = undefined;
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
  for (let i = 0; i < 3; i++) {
    const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
    assert.equal(response.status, 200);
    const guest = await response.json();
    const socket = io(`${base}/game`, { transports: ['websocket'], reconnection: false, autoConnect: false, forceNew: true,
      auth: { accessToken: guest.access_token, protocolVersion: 1, clientInstanceId: randomUUID() } });
    const client = { socket, guest };
    socket.on('session.membership', v => { client.playerId = v.playerId; });
    socket.on('game.snapshot', v => { assert.ok(isValid('gameSnapshot', v)); client.view = v; });
    const hello = new Promise((resolve, reject) => { socket.once('server.hello', resolve); socket.once('connect_error', reject); });
    socket.connect(); await hello;
    clients.push(client);
  }
  const revision = async () => (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision;
  const room = async (c, type, payload = {}, initial = false) => c.socket.timeout(6000).emitWithAck('room.command', {
    protocolVersion: 1, commandId: randomUUID(), roomId: initial ? null : roomId,
    expectedVersion: initial ? null : await revision(), expectedPhaseId: null, type, payload });
  const subscribe = async c => {
    c.socket.emit('session.subscribe', { requestId: randomUUID(), roomId, lastRoomRevision: null, lastGameVersion: null });
    c.socket.emit('game.sync', { requestId: randomUUID(), roomId, lastGameVersion: null });
    await sleep(200);
  };
  const saved = async () => (await admin.query('SELECT * FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
  const game = async (c, type, payload = {}) => {
    const row = await saved();
    return c.socket.timeout(6000).emitWithAck('game.command', {
      protocolVersion: 1, commandId: randomUUID(), roomId,
      expectedVersion: row.version, expectedPhaseId: row.public_state.phaseId, type, payload });
  };

  const created = await room(clients[0], 'CREATE_ROOM', { nickname: 'Host', settings }, true);
  assert.equal(created.status, 'ACCEPTED', JSON.stringify(created));
  roomId = created.roomId;
  const invitationCode = created.result.invitationCode;
  for (const [i, c] of clients.slice(1).entries()) {
    assert.equal((await room(c, 'JOIN_ROOM', { nickname: `Guest ${i}`, invitationCode }, true)).status, 'ACCEPTED');
  }
  for (const c of clients) { await subscribe(c); assert.equal((await room(c, 'SET_READY', { ready: true })).status, 'ACCEPTED'); }
  assert.equal((await room(clients[0], 'START_GAME')).status, 'ACCEPTED');
  assert.ok(await until(async () => (await saved()) !== undefined));

  const leaver = clients[2];
  await t.test('leaving empties the seat and pauses the table for a decision', async () => {
    const ack = await game(leaver, 'LEAVE_GAME');
    assert.equal(ack.status, 'ACCEPTED', JSON.stringify(ack));
    const row = await saved();
    assert.equal(row.public_state.players[leaver.playerId].kind, 'VACANT');
    // Its own reason, not DISCONNECTED: waiting will not bring them back.
    assert.ok(row.public_state.pauseReasons.includes('SEAT_VACANT'));
    assert.equal((await admin.query('SELECT status FROM app.rooms WHERE id=$1', [roomId])).rows[0].status, 'PAUSED');
    const seat = (await admin.query('SELECT left_at, kind FROM app.players WHERE id=$1', [leaver.playerId])).rows[0];
    assert.ok(seat.left_at, 'the seat is no longer a membership');
    // The cards and position stay with the seat for whoever takes it over.
    assert.ok(row.private_state[leaver.playerId], 'the hand is kept');
  });

  await t.test('a player who stayed hands the seat to a bot and play resumes', async () => {
    const ack = await game(clients[1], 'REPLACE_WITH_BOT', { playerId: leaver.playerId });
    assert.equal(ack.status, 'ACCEPTED', JSON.stringify(ack));
    const row = await saved();
    assert.equal(row.public_state.players[leaver.playerId].kind, 'BOT');
    assert.equal(row.public_state.pauseReasons.includes('SEAT_VACANT'), false);
    const seat = (await admin.query('SELECT left_at, kind, auth_user_id FROM app.players WHERE id=$1', [leaver.playerId])).rows[0];
    assert.equal(seat.kind, 'BOT');
    assert.equal(seat.left_at, null, 'the seat is occupied again');
    assert.equal(seat.auth_user_id, null, 'and holds no identity to rejoin through');
  });

  await t.test('the bot then takes the seat’s turns by itself', async () => {
    const before = (await saved()).version;
    const played = await until(async () => {
      const n = (await admin.query('SELECT count(*)::int n FROM app.move_logs WHERE room_id=$1 AND actor_player_id=$2', [roomId, leaver.playerId])).rows[0].n;
      if (n > 0) return true;
      // Keep the humans' own turns moving so the order reaches the bot.
      const row = await saved();
      for (const c of clients.slice(0, 2)) {
        if (!row.public_state.requiredPlayerIds.includes(c.playerId)) continue;
        const { chooseCommand, projectPlayer, seedFrom } = await import('../../packages/game-engine/dist/index.js');
        const state = { roomId, version: row.version, rulesVersion: row.rules_version, stateSchemaVersion: 1, protocolVersion: 1,
          publicState: row.public_state, privateState: row.private_state, serverState: row.server_state, clockState: row.clock_state };
        const move = chooseCommand({ publicState: state.publicState, hand: projectPlayer(state, c.playerId) },
          { developmentCardsRemaining: state.serverState.developmentDeck.length,
            pendingSetupVertexId: state.serverState.setup?.pendingVertexId ?? null,
            eligibleVictimIds: state.serverState.effect?.eligiblePlayerIds,
            bankStock: state.serverState.bank },
          'MEDIUM', seedFrom(roomId, state.version, state.publicState.phaseId, c.playerId));
        if (move) await game(c, move.type, move.payload);
      }
      return false;
    }, 45000);
    const moves = (await admin.query('SELECT count(*)::int n FROM app.move_logs WHERE room_id=$1 AND actor_player_id=$2', [roomId, leaver.playerId])).rows[0].n;
    assert.ok(played, `the bot played the vacated seat (moves: ${moves}, from version ${before})`);
  });
});
