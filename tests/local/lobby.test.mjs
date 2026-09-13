import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { io } from 'socket.io-client';
import { createApp } from '../../apps/server/dist/app.js';
import { loadConfig } from '../../apps/server/dist/config.js';
import { Rooms } from '../../apps/server/dist/rooms.js';
import { retain } from '../../scripts/retention.mjs';
import { isValid } from '../../packages/protocol/dist/index.js';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
if (!['127.0.0.1', 'localhost'].includes(new URL(local.adminDatabaseUrl).hostname)) throw new Error('Local database only');
const settings = { maxPlayers: 4, turnLimitSeconds: null, boardMode: 'STANDARD_RANDOM', rulesVersion: 'base-2020-v1' };
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, timeout = 5000) { const end = Date.now() + timeout; while (Date.now() < end) { if (await check()) return; await wait(30); } assert.fail('Condition did not become true'); }
function intent(type, payload, room) { return { protocolVersion: 1, commandId: randomUUID(), roomId: room?.roomId ?? null, expectedVersion: room?.revision ?? null, expectedPhaseId: null, type, payload }; }

test('private lobby lifecycle with independent authenticated guests', { timeout: 70000 }, async t => {
  const admin = new Client({ connectionString: local.adminDatabaseUrl }); await admin.connect();
  let app, base, roomId, invite, createCommand, host, second, third, fourth, rejected;
  const guests = [], sockets = [], createdRooms = [];
  async function connect(guest) {
    const socket = io(`${base}/game`, { transports: ['websocket'], forceNew: true, reconnection: false, autoConnect: false,
      auth: { accessToken: guest.access_token, protocolVersion: 1, clientInstanceId: randomUUID() } });
    sockets.push(socket);
    const client = { socket, guest, snapshots: [], presence: new Set(), membership: null, errors: [] };
    socket.on('room.snapshot', value => { assert.equal(isValid('roomSnapshot', value), true); client.room = value; client.snapshots.push(value); });
    socket.on('session.membership', value => { assert.equal(isValid('membership', value), true); client.membership = value; });
    socket.on('presence.update', value => { client.presence = new Set(value.onlinePlayerIds); });
    socket.on('session.error', value => client.errors.push(value));
    const hello = new Promise((resolve, reject) => { socket.once('server.hello', resolve); socket.once('connect_error', reject); });
    socket.connect(); await hello;
    return client;
  }
  async function send(client, command) { const ack = await client.socket.timeout(6000).emitWithAck('room.command', command); assert.equal(isValid('ack', ack), true); return ack; }
  async function update(client, type, payload = {}) {
    const revision = (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision;
    return send(client, intent(type, payload, { roomId, revision }));
  }
  try {
    assert.equal((await admin.query('SELECT count(*)::int AS n FROM app.rooms WHERE active_slot=1')).rows[0].n, 0, 'Close your local preview lobby before running isolated lobby tests; no existing rooms are deleted');
    app = await createApp({ ...loadConfig(), port: 0 }); await app.listen(0, '127.0.0.1'); base = await app.getUrl();
    for (let i = 0; i < 5; i++) {
      const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
      assert.equal(response.status, 200); guests.push(await response.json());
    }
    [host, second, third, fourth, rejected] = await Promise.all(guests.map(connect));
    await t.test('concurrent duplicate create returns the same private receipt and one host/room/outbox', async () => {
      const command = createCommand = intent('CREATE_ROOM', { nickname: 'Host', settings });
      const [a, b] = await Promise.all([send(host, command), send(host, command)]);
      assert.equal(a.status, 'ACCEPTED'); assert.deepEqual(a, b);
      roomId = a.roomId; invite = a.result.invitationCode; createdRooms.push(roomId);
      assert.equal((await admin.query('SELECT count(*)::int n FROM app.players WHERE room_id=$1', [roomId])).rows[0].n, 1);
      assert.equal((await send(host, { ...command, payload: { nickname: 'Different', settings } })).error.code, 'COMMAND_ID_REUSED');
      assert.equal((await send(second, intent('CREATE_ROOM', { nickname: 'Other', settings }))).error.code, 'ROOM_UNAVAILABLE');
    });
    await t.test('normalized names collide; duplicate join is one membership; strangers cannot subscribe', async () => {
      assert.equal((await send(second, intent('JOIN_ROOM', { nickname: 'ＨＯＳＴ', invitationCode: invite }))).error.code, 'NAME_TAKEN');
      const join = intent('JOIN_ROOM', { nickname: 'Second', invitationCode: invite.toLowerCase().slice(0, 5) + '-' + invite.toLowerCase().slice(5) });
      const [a, b] = await Promise.all([send(second, join), send(second, join)]); assert.equal(a.status, 'ACCEPTED'); assert.deepEqual(a, b);
      rejected.socket.emit('session.subscribe', { requestId: randomUUID(), roomId, lastRoomRevision: null, lastGameVersion: null });
      await until(() => rejected.errors.some(e => e.code === 'FORBIDDEN')); assert.equal(rejected.room, undefined);
    });
    await t.test('fourth and fifth joins race safely with atomic seat and colour allocation', async () => {
      assert.equal((await send(third, intent('JOIN_ROOM', { nickname: 'Third', invitationCode: invite }))).status, 'ACCEPTED');
      const results = await Promise.all([fourth, rejected].map((c, i) => send(c, intent('JOIN_ROOM', { nickname: `Candidate ${i}`, invitationCode: invite }))));
      assert.equal(results.filter(r => r.status === 'ACCEPTED').length, 1); assert.equal(results.find(r => r.status === 'REJECTED').error.code, 'ROOM_FULL');
      if (results[1].status === 'ACCEPTED') [fourth, rejected] = [rejected, fourth];
      await until(() => host.room?.players.length === 4 && host.presence.size === 4);
      assert.equal(new Set(host.room.players.map(p => p.colour)).size, 4);
      const publicWire = JSON.stringify(host.snapshots);
      for (const guest of guests) { assert.equal(publicWire.includes(guest.user.id), false); assert.equal(publicWire.includes(guest.access_token), false); }
      assert.equal(publicWire.includes(invite), false); assert.equal(publicWire.includes('invitation_hash'), false);
    });
    await t.test('host permissions, readiness reset, profile uniqueness and start preconditions', async () => {
      assert.equal((await update(second, 'UPDATE_SETTINGS', { turnLimitSeconds: 60, boardMode: 'STANDARD_RANDOM' })).error.code, 'FORBIDDEN');
      assert.equal((await update(host, 'START_GAME')).error.code, 'PLAYERS_NOT_READY');
      assert.equal((await update(second, 'SET_PROFILE', { nickname: 'Changed', colour: host.room.players[0].colour })).error.code, 'COLOUR_TAKEN');
      for (const c of [host, second, third, fourth]) assert.equal((await update(c, 'SET_READY', { ready: true })).status, 'ACCEPTED');
      assert.equal((await update(second, 'START_GAME')).error.code, 'FORBIDDEN');
      assert.equal((await admin.query('SELECT count(*)::int n FROM app.game_states WHERE room_id=$1', [roomId])).rows[0].n, 0, 'A non-host cannot create a game');
      assert.equal((await update(host, 'UPDATE_SETTINGS', { turnLimitSeconds: 120, boardMode: 'STANDARD_RANDOM' })).status, 'ACCEPTED');
      await until(() => host.room.players.every(p => !p.ready));
    });
    await t.test('an outbox write failure rolls back the command; the original ID remains retryable', async () => {
      const revision = (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision;
      const command = intent('SET_READY', { ready: true }, { roomId, revision });
      const suffix = randomUUID().replaceAll('-', '');
      const functionName = `app.test_fail_${suffix}`;
      const triggerName = `test_fail_${suffix}`;
      await admin.query(`CREATE FUNCTION ${functionName}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.room_id='${roomId}'::uuid THEN RAISE EXCEPTION 'synthetic failure'; END IF; RETURN NEW; END $$`);
      try {
        await admin.query(`CREATE TRIGGER ${triggerName} BEFORE INSERT ON app.outbox_events FOR EACH ROW EXECUTE FUNCTION ${functionName}()`);
        assert.equal((await send(host, command)).error.code, 'SERVICE_UNAVAILABLE');
        assert.equal((await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision, revision);
        assert.equal((await admin.query('SELECT 1 FROM app.command_receipts WHERE command_id=$1', [command.commandId])).rowCount, 0);
      } finally {
        await admin.query(`DROP TRIGGER IF EXISTS ${triggerName} ON app.outbox_events`);
        await admin.query(`DROP FUNCTION ${functionName}()`);
      }
      assert.equal((await send(host, command)).status, 'ACCEPTED');
    });
    await t.test('leave/rejoin preserves identity, revokes duplicate sockets and rotations invalidate the previous code', async () => {
      const original = second.membership.playerId, duplicate = await connect(second.guest);
      await until(() => duplicate.membership?.playerId === original);
      assert.equal((await update(second, 'LEAVE_LOBBY')).status, 'ACCEPTED');
      await until(() => duplicate.errors.some(e => e.code === 'MEMBERSHIP_ENDED'));
      const rotate = await update(host, 'ROTATE_INVITATION'); assert.equal(rotate.status, 'ACCEPTED');
      assert.equal((await send(second, intent('JOIN_ROOM', { nickname: 'Second', invitationCode: invite }))).error.code, 'ROOM_UNAVAILABLE');
      invite = rotate.result.invitationCode;
      const joined = await send(second, intent('JOIN_ROOM', { nickname: 'Second again', invitationCode: invite }));
      assert.equal(joined.result.playerId, original);
      duplicate.socket.disconnect();
    });
    await t.test('a remaining tab keeps host online; transfer follows ten seconds with no host sockets', async () => {
      const twin = await connect(host.guest); await until(() => twin.membership != null);
      host.socket.disconnect(); await wait(1100);
      assert.equal((await admin.query('SELECT host_player_id FROM app.rooms WHERE id=$1', [roomId])).rows[0].host_player_id, twin.membership.playerId);
      twin.socket.disconnect();
      await until(async () => (await admin.query('SELECT host_player_id FROM app.rooms WHERE id=$1', [roomId])).rows[0].host_player_id !== twin.membership.playerId, 13000);
      const restored = await connect(host.guest); await until(() => restored.membership?.playerId === twin.membership.playerId); host = restored;
    });
    await t.test('restart restores seats without a code, fences the old process and drains unpublished revisions', async () => {
      const previous = app.get(Rooms);
      const retiring = new Promise(resolve => host.socket.once('server.restarting', resolve));
      const disconnected = new Promise(resolve => host.socket.once('disconnect', resolve));
      const replacement = await createApp({ ...loadConfig(), port: 0 });
      const denied = await previous.command(host.guest.user.id, intent('SET_READY', { ready: true }, host.room));
      assert.equal(denied.error.code, 'SERVICE_UNAVAILABLE');
      assert.deepEqual(await retiring, { retryAfterMs: 1000 }); await disconnected;
      assert.equal(host.socket.connected, false);
      await app.close(); app = replacement; await app.listen(0, '127.0.0.1'); base = await app.getUrl();
      host = await connect(host.guest); await until(() => host.membership != null && host.room != null);
      assert.equal(host.room.roomId, roomId);
      const rows = (await admin.query('SELECT nickname,auth_user_id,id FROM app.players WHERE room_id=$1 AND left_at IS NULL', [roomId])).rows;
      assert.equal(host.membership.playerId, rows.find(r => r.auth_user_id === host.guest.user.id).id);
      assert.equal((await admin.query('SELECT count(*)::int n FROM app.outbox_events WHERE room_id=$1 AND published_at IS NULL', [roomId])).rows[0].n, 0);
    });
    await t.test('unchanged subscriptions repair requester presence without snapshots or a broadcast', async () => {
      await until(() => host.room != null);
      const observer = await connect(host.guest);
      await until(() => observer.room != null);
      await wait(100);
      let requesterPresence = 0, observerPresence = 0;
      const onRequest = value => { assert.ok(value.onlinePlayerIds.includes(host.membership.playerId)); requesterPresence++; };
      const onObserver = () => { observerPresence++; };
      host.socket.on('presence.update', onRequest); observer.socket.on('presence.update', onObserver);
      const before = host.snapshots.length;
      host.socket.emit('session.subscribe', { requestId: randomUUID(), roomId, lastRoomRevision: host.room.revision, lastGameVersion: null });
      await wait(250); assert.equal(host.snapshots.length, before);
      assert.equal(requesterPresence, 1); assert.equal(observerPresence, 0);
      host.socket.off('presence.update', onRequest); observer.socket.off('presence.update', onObserver); observer.socket.disconnect();
    });
    await t.test('expiry on subscribe frees the single slot and preserves old receipts', async () => {
      await admin.query("UPDATE app.rooms SET updated_at=clock_timestamp()-interval '25 hours' WHERE id=$1", [roomId]);
      host.socket.emit('session.subscribe', { requestId: randomUUID(), roomId, lastRoomRevision: null, lastGameVersion: null });
      await until(() => host.room?.status === 'EXPIRED');
      const next = await send(host, intent('CREATE_ROOM', { nickname: 'New Host', settings }));
      assert.equal(next.status, 'ACCEPTED'); roomId = next.roomId; createdRooms.push(roomId);
      assert.equal((await update(host, 'LEAVE_LOBBY')).status, 'ACCEPTED');
      assert.equal((await admin.query('SELECT count(*)::int n FROM app.rooms WHERE active_slot=1')).rows[0].n, 0);
    });
    await t.test('operator retention preserves tombstones and an old create cannot recreate a room', async () => {
      const oldRoom = createdRooms[0];
      await admin.query("UPDATE app.rooms SET ended_at=clock_timestamp()-interval '31 days' WHERE id=$1", [oldRoom]);
      await admin.query("UPDATE app.command_receipts SET created_at=clock_timestamp()-interval '31 days' WHERE room_id=$1", [oldRoom]);
      const scope = { roomIds: [oldRoom], actorKeys: guests.map(g => `user:${g.user.id}`) };
      const preview = await retain(admin, scope); assert.equal(preview.terminalRooms, 1); assert.equal(preview.applied, false);
      assert.equal((await admin.query('SELECT 1 FROM app.rooms WHERE id=$1', [oldRoom])).rowCount, 1);
      await retain(admin, { ...scope, apply: true });
      assert.equal((await send(host, createCommand)).error.code, 'RECEIPT_EXPIRED');
      assert.equal((await admin.query('SELECT 1 FROM app.rooms WHERE id=$1', [oldRoom])).rowCount, 0);
    });
  } finally {
    for (const socket of sockets) socket.disconnect();
    await app?.close();
    // Delete only this test's synthetic rows. Never clear unrelated local data.
    for (const room of createdRooms) {
      await admin.query('BEGIN');
      await admin.query('DELETE FROM app.outbox_events WHERE room_id=$1', [room]);
      await admin.query('DELETE FROM app.command_receipts WHERE room_id=$1', [room]);
      await admin.query('DELETE FROM app.players WHERE room_id=$1', [room]);
      await admin.query('DELETE FROM app.rooms WHERE id=$1', [room]);
      await admin.query('COMMIT');
    }
    for (const guest of guests) await admin.query('DELETE FROM app.command_receipts WHERE actor_key=$1', [`user:${guest.user.id}`]);
    await admin.end();
  }
});
