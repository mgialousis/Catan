import test from 'node:test';
import assert from 'node:assert/strict';
import { publicConfig } from '../../../scripts/public-config.mjs';
import { operatorConfig } from '../../../scripts/hosted-maintenance.mjs';
test('release public configuration rejects privileged keys and credential-bearing URLs',()=>{
  const env={WEB_URL:'https://web.example.invalid',API_URL:'https://api.example.invalid',SUPABASE_URL:'https://project.supabase.co',SUPABASE_ANON_KEY:'sb_publishable_example'};
  assert.deepEqual(publicConfig(env),env);
  for(const patch of [{SUPABASE_ANON_KEY:'sb_secret_example'},{API_URL:'https://user:password@example.invalid'},{API_URL:'http://example.invalid'},{SUPABASE_URL:'https://project.supabase.co/?key=private'}])assert.throws(()=>publicConfig({...env,...patch}));
  const token=role=>`header.${Buffer.from(JSON.stringify({role})).toString('base64url')}.signature`;
  assert.doesNotThrow(()=>publicConfig({...env,SUPABASE_ANON_KEY:token('anon')}));
  assert.throws(()=>publicConfig({...env,SUPABASE_ANON_KEY:token('service_role')}));
});
test('hosted operator configuration cannot silently disable verified TLS',()=>{
  const config=operatorConfig({OPERATOR_DATABASE_URL:'postgresql://postgres:example@db.example.invalid:5432/postgres?sslmode=disable'});
  assert.equal(config.ssl.rejectUnauthorized,true);assert.equal(new URL(config.connectionString).searchParams.has('sslmode'),false);
  assert.throws(()=>operatorConfig({OPERATOR_DATABASE_URL:'postgresql://postgres:example@127.0.0.1/postgres'}));
});
