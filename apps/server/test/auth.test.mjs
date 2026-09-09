import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPair, exportJWK, createLocalJWKSet, SignJWT } from 'jose';
import { TokenVerifier } from '../dist/auth.js';
import { loadConfig } from '../dist/config.js';
import { WindowLimiter } from '../dist/gateway.js';

const pair = await generateKeyPair('ES256');
const jwk = { ...await exportJWK(pair.publicKey), kid: 'test-key', alg: 'ES256' };
const issuer = 'https://project.test/auth/v1';
const verifier = new TokenVerifier({ issuer, jwksUrl: `${issuer}/.well-known/jwks.json` }, createLocalJWKSet({ keys: [jwk] }));
const subject = '11111111-1111-4111-8111-111111111111';
async function token(changes = {}, signingKey = pair.privateKey) {
  return new SignJWT({ sub: subject, iss: issuer, aud: 'authenticated', role: 'authenticated', is_anonymous: true, iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 600, ...changes })
    .setProtectedHeader({ alg: 'ES256', kid: 'test-key' }).sign(signingKey);
}
test('valid anonymous JWT derives identity only from verified subject', async () => {
  assert.equal((await verifier.verify(await token())).userId, subject);
});
for (const [name, claims] of Object.entries({ expired: { exp: 1 }, wrongIssuer: { iss: 'https://evil.test/auth/v1' }, wrongAudience: { aud: 'anon' }, wrongRole: { role: 'service_role' }, malformedSubject: { sub: 'nickname' }, missingExpiry: { exp: undefined } })) {
  test(`reject ${name}`, async () => assert.rejects(verifier.verify(await token(claims))));
}
test('reject forged signature and unsupported algorithm', async () => {
  const other = await generateKeyPair('ES256');
  await assert.rejects(verifier.verify(await token({}, other.privateKey)));
  const hs = await new SignJWT({ sub: subject }).setProtectedHeader({ alg: 'HS256' }).sign(new TextEncoder().encode('a'.repeat(40)));
  await assert.rejects(verifier.verify(hs));
  await assert.rejects(verifier.verify('not-a-token'));
});
test('production configuration refuses local secret and unverified database TLS', () => {
  const env = { NODE_ENV: 'production', DATABASE_URL: 'postgresql://runtime:secret@database.test/postgres', DATABASE_TLS: 'true', SUPABASE_JWT_ISSUER: issuer, WEB_ORIGINS: 'https://app.test' };
  assert.doesNotThrow(() => loadConfig(env));
  assert.equal(loadConfig({ ...env, DATABASE_URL: env.DATABASE_URL + '?sslmode=disable' }).databaseUrl.includes('sslmode'), false);
  assert.throws(() => loadConfig({ ...env, LOCAL_JWT_SECRET: 'secret' }));
  assert.throws(() => loadConfig({ ...env, DATABASE_TLS: 'false' }));
});
test('rate limiter permits NAT traffic and resets elapsed windows', () => {
  const limiter = new WindowLimiter(2, 100);
  assert.equal(limiter.allow('user', 0), true);
  assert.equal(limiter.allow('user', 1), true);
  assert.equal(limiter.allow('user', 2), false);
  assert.equal(limiter.allow('other-user', 2), true);
  assert.equal(limiter.allow('user', 101), true);
});
