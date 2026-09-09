import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { Client } from 'pg';

// Capture status; never print service credentials or signing secrets.
const status = JSON.parse(execFileSync('node_modules/.bin/supabase', ['status', '-o', 'json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
const api = status.API_URL;
const db = new URL(status.DB_URL);
if (!['127.0.0.1', 'localhost'].includes(db.hostname) || !['127.0.0.1', 'localhost'].includes(new URL(api).hostname)) throw new Error('This helper only configures local Supabase.');
const password = randomBytes(24).toString('hex');
const client = new Client({ connectionString: db.toString() });
await client.connect();
try {
  // Identifier is fixed; password is generated hex, never user-supplied SQL.
  await client.query(`ALTER ROLE island_runtime LOGIN PASSWORD '${password}'`);
} finally { await client.end(); }
db.username = 'island_runtime'; db.password = password;
const jwksResponse = await fetch(`${api}/auth/v1/.well-known/jwks.json`);
if (!jwksResponse.ok) throw new Error('Local Auth JWKS endpoint is unavailable');
const jwks = await jwksResponse.json();
const legacy = jwks.keys.length === 0;
if (legacy && !status.JWT_SECRET) throw new Error('Local signing configuration unavailable');
const env = [
  'NODE_ENV=development', 'PORT=3000', `DATABASE_URL=${db}`, 'DATABASE_TLS=false',
  `SUPABASE_JWT_ISSUER=${api}/auth/v1`, `SUPABASE_JWKS_URL=${api}/auth/v1/.well-known/jwks.json`,
  'WEB_ORIGINS=http://localhost:8080,http://127.0.0.1:8080',
  ...(legacy ? [`LOCAL_JWT_SECRET=${status.JWT_SECRET}`] : []),
].join('\n') + '\n';
await writeFile('.env', env, { mode: 0o600 });
await mkdir('.local', { recursive: true });
await writeFile('.local/test-env.json', JSON.stringify({ apiUrl: api, anonKey: status.ANON_KEY, adminDatabaseUrl: status.DB_URL }), { mode: 0o600 });
await mkdir('apps/mobile/config', { recursive: true });
const publicConfig = { API_URL: 'http://127.0.0.1:3000', SUPABASE_URL: api, SUPABASE_ANON_KEY: status.ANON_KEY };
await writeFile('apps/mobile/config/local.json', JSON.stringify(publicConfig, null, 2) + '\n');
await writeFile('apps/mobile/config/android.json', JSON.stringify({ ...publicConfig, API_URL: 'http://10.0.2.2:3000', SUPABASE_URL: api.replace('127.0.0.1', '10.0.2.2') }, null, 2) + '\n');
console.log('Local runtime credential and public Flutter configurations written to ignored files.');
