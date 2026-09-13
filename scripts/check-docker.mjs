import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { Client } from 'pg';
import { io } from 'socket.io-client';

const config = parseEnv(readFileSync('.env', 'utf8'));
const database = new URL(config.DATABASE_URL);
assert.ok(['localhost', '127.0.0.1'].includes(database.hostname));
database.hostname = 'host.docker.internal'; config.DATABASE_URL = database.toString();
config.SUPABASE_JWKS_URL = config.SUPABASE_JWKS_URL.replace('127.0.0.1', 'host.docker.internal');
// Production image, local development-mode Auth. Production TLS/JWKS are tested separately.
writeFileSync('.local/docker.env', Object.entries(config).map(([key,value]) => `${key}=${value}`).join('\n') + '\n', { mode: 0o600 });
const local=JSON.parse(readFileSync('.local/test-env.json','utf8'));
assert.ok(['localhost','127.0.0.1'].includes(new URL(local.adminDatabaseUrl).hostname));
const admin=new Client({connectionString:local.adminDatabaseUrl});await admin.connect();
try { assert.equal((await admin.query('SELECT count(*)::int n FROM app.rooms WHERE active_slot=1')).rows[0].n,0,'Close local tables before the container runtime claims ownership'); }
finally { await admin.end(); }
const name = `island-table-smoke-${randomUUID().slice(0,8)}`;
execFileSync('docker', ['run', '--rm', '-d', '--name', name, '-p', '127.0.0.1:3300:3000', '--env-file', '.local/docker.env', process.env.ISLAND_API_IMAGE ?? 'island-table-api:phase7'], { stdio: 'pipe' });
let socket;
try {
  let ready = false;
  for (let attempt = 0; attempt < 30; attempt++) {
    try { ready = (await fetch('http://127.0.0.1:3300/health/ready')).ok; } catch {}
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  assert.ok(ready, 'container readiness');
  assert.equal(execFileSync('docker', ['exec', name, 'id', '-u'], { encoding: 'utf8' }).trim(), '1000');
  const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(response.status, 200);
  const guest = await response.json();
  socket = io('http://127.0.0.1:3300/game', { transports: ['websocket'], forceNew: true, reconnection: false, autoConnect: false, auth: { accessToken: guest.access_token, protocolVersion: 1, clientInstanceId: randomUUID() } });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Container handshake timed out')), 5000);
    socket.once('server.hello', value => { clearTimeout(timer); assert.equal(value.protocolVersion, 1); resolve(); });
    socket.once('connect_error', () => { clearTimeout(timer); reject(new Error('Container handshake rejected')); });
    socket.connect();
  });
  console.log('Single authenticated client container memory:',execFileSync('docker',['stats','--no-stream','--format','{{.MemUsage}}',name],{encoding:'utf8'}).trim());
  console.log('API image: non-root runtime, database readiness and authenticated Socket.IO passed.');
} finally {
  socket?.disconnect();
  execFileSync('docker', ['stop', name], { stdio: 'pipe' });
}
