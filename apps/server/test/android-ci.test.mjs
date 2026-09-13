import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, existsSync, writeFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../../../scripts/configure-android-ci.mjs', import.meta.url));
test('CI signing setup preserves local files and exports only public client configuration', t => {
  const cwd = mkdtempSync(join(tmpdir(), 'island-android-ci-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  mkdirSync(join(cwd, 'apps/mobile/android'), { recursive: true });
  mkdirSync(join(cwd, 'apps/mobile/config'), { recursive: true });
  const env = {
    ...process.env, GITHUB_ACTIONS: 'true', RUNNER_TEMP: cwd,
    API_URL: 'https://api.example.test', WEB_URL: 'https://web.example.test',
    SUPABASE_URL: 'https://project.supabase.co', SUPABASE_ANON_KEY: 'sb_publishable_example',
    ANDROID_KEYSTORE_BASE64: Buffer.from('synthetic signing fixture').toString('base64'),
    ANDROID_STORE_PASSWORD: 'synthetic store password', ANDROID_KEY_PASSWORD: 'synthetic-key', ANDROID_KEY_ALIAS: 'test',
    DATABASE_URL: 'must never enter client config',
  };
  const run = patch => spawnSync(process.execPath, [script], { cwd, env: { ...env, ...patch }, encoding: 'utf8' });
  const properties = join(cwd, 'apps/mobile/android/key.properties');
  const keystore = join(cwd, 'island-release.jks');
  assert.notEqual(run({ GITHUB_ACTIONS: 'false' }).status, 0);
  assert.notEqual(run({ SUPABASE_ANON_KEY: 'sb_secret_forbidden' }).status, 0);
  assert.notEqual(run({ ANDROID_KEY_PASSWORD: '' }).status, 0);
  assert.equal(existsSync(keystore), false);
  writeFileSync(properties, 'existing developer configuration');
  assert.notEqual(run({}).status, 0);
  assert.equal(readFileSync(properties, 'utf8'), 'existing developer configuration');
  rmSync(properties);
  const result = run({});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(keystore, 'utf8'), 'synthetic signing fixture');
  assert.equal(statSync(properties).mode & 0o777, 0o600);
  assert.equal(statSync(keystore).mode & 0o777, 0o600);
  const config = JSON.parse(readFileSync(join(cwd, 'apps/mobile/config/ci.json'), 'utf8'));
  assert.deepEqual(Object.keys(config).sort(), ['API_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_URL', 'WEB_URL']);
  assert.equal(config.API_URL, env.API_URL);
  assert.match(readFileSync(properties, 'utf8'), /storePassword=synthetic\\ store\\ password/);
  assert.equal(result.stdout.includes(env.ANDROID_STORE_PASSWORD), false);
});
