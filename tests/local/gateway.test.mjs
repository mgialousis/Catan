import test, { before, after } from 'node:test';
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
let app, base, guest;
const sockets = [];
async function signIn() {
  const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(response.status, 200, 'local anonymous sign-in must succeed');
  return response.json();
}
function socket(auth, origin = 'http://localhost:8080') {
  const client = io(`${base}/game`, { transports: ['websocket'], path: '/socket.io', autoConnect: false, forceNew: true, reconnection: false, timeout: 3000, auth, extraHeaders: origin ? { Origin: origin } : {} });
  sockets.push(client);
  return client;
}
function once(client, event) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { client.off(event, handler); reject(new Error(`Timed out waiting for ${event}`)); }, 5000);
    function handler(value) { clearTimeout(timer); resolve(value); }
    client.once(event, handler);
  });
}
function auth(token = guest.access_token) { return { accessToken: token, protocolVersion: 1, clientInstanceId: randomUUID() }; }
before(async () => {
  app = await createApp({ ...loadConfig(), port: 0 });
  await app.listen(0, '127.0.0.1'); base = await app.getUrl();
  guest = await signIn();
});
after(async () => {
  for (const client of sockets) client.disconnect(); await app?.close();
  // Valid denied gameplay now creates a durable receipt, even without a room.
  if (guest) {
    assert.ok(['127.0.0.1','localhost'].includes(new URL(local.adminDatabaseUrl).hostname));
    const admin=new Client({connectionString:local.adminDatabaseUrl});await admin.connect();
    try { await admin.query('DELETE FROM app.command_receipts WHERE actor_key=$1',[`user:${guest.user.id}`]); }
    finally { await admin.end(); }
  }
});

test('local anonymous guest connects, receives validated hello and sanitized health', async () => {
  assert.equal(guest.user.is_anonymous, true);
  const client = socket(auth()); const hello = once(client, 'server.hello'); client.connect();
  assert.equal(isValid('serverHello', await hello), true);
  const ready = await fetch(`${base}/health/ready`);
  assert.equal(ready.status, 200); assert.deepEqual(await ready.json(), { status: 'ready' });
});
test('missing, forged and incompatible authentication cannot connect', async () => {
  for (const handshake of [{}, auth('forged'), { ...auth(), protocolVersion: 2 }]) {
    const client = socket(handshake); const failed = once(client, 'connect_error'); client.connect();
    const error = await failed;
    assert.equal(client.connected, false);
    assert.ok(error.data?.code);
    assert.equal(JSON.stringify(error.data).includes(guest.access_token), false);
  }
});
test('unexpected browser origin rejected, native without Origin accepted', async () => {
  const rejected = socket(auth(), 'https://evil.test'); const failed = once(rejected, 'connect_error'); rejected.connect(); await failed;
  assert.equal(rejected.connected, false);
  const native = socket(auth(), null); const hello = once(native, 'server.hello'); native.connect(); await hello;
});
test('malformed commands rejected; valid unauthorized commands cannot mutate state', async () => {
  const client = socket(auth()); const hello = once(client, 'server.hello'); client.connect(); await hello;
  const error = once(client, 'session.error');
  client.emit('game.command', { type: 'ROLL_DICE', dice: [6, 6] });
  assert.equal((await error).code, 'INVALID_PAYLOAD');
  const command = { protocolVersion: 1, commandId: randomUUID(), roomId: randomUUID(), expectedVersion: 0, expectedPhaseId: randomUUID(), type: 'ROLL_DICE', payload: {} };
  const ack = await client.timeout(3000).emitWithAck('game.command', command);
  assert.equal(isValid('ack', ack), true); assert.equal(ack.status, 'REJECTED'); assert.equal(ack.error.code, 'FORBIDDEN');
});
test('guests cannot subscribe to arbitrary room IDs or read private tables through the Data API', async () => {
  const client = socket(auth()); const hello = once(client, 'server.hello'); client.connect(); await hello;
  const requestId = randomUUID(); const error = once(client, 'session.error');
  client.emit('session.subscribe', { requestId, roomId: randomUUID(), lastRoomRevision: null, lastGameVersion: null });
  assert.deepEqual(await error, { code: 'FORBIDDEN', message: 'This room is unavailable.', retryable: false, requestId });
  for (const token of [null, guest.access_token]) {
    const response = await fetch(`${local.apiUrl}/rest/v1/rooms?select=id`, { headers: { apikey: local.anonKey, 'Accept-Profile': 'app', ...(token ? { Authorization: `Bearer ${token}` } : {}) } });
    assert.ok([401, 403, 406].includes(response.status));
  }
});
test('refresh keeps the same subject; another subject disconnects the socket', async () => {
  const client = socket(auth()); const hello = once(client, 'server.hello'); client.connect(); await hello;
  const response = await fetch(`${local.apiUrl}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: guest.refresh_token }) });
  assert.equal(response.status, 200); const refreshed = await response.json();
  assert.equal(refreshed.user.id, guest.user.id);
  const ack = await client.timeout(3000).emitWithAck('auth.refresh', { accessToken: refreshed.access_token });
  assert.equal(ack.status, 'ACCEPTED');
  const other = await signIn(); const disconnected = once(client, 'disconnect');
  client.emit('auth.refresh', { accessToken: other.access_token }); await disconnected;
  assert.equal(client.connected, false);
});
