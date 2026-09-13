import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { gameWireFixtures } from '../../../scripts/game-wire-fixtures.mjs';
import { diffView } from '../dist/game-delta.js';
test('cross-language deltas exactly match regenerated engine views',()=>assert.deepEqual(gameWireFixtures(),JSON.parse(readFileSync('packages/protocol/fixtures/game-deltas.json','utf8'))));
test('delta keys reject unsafe paths and ignore JSON property order',()=>{
  assert.deepEqual(diffView({a:{x:1,y:2}},{a:{y:2,x:1}}),[]);
  assert.throws(()=>diffView({},JSON.parse('{"__proto__": 1}')),/Unsafe/);
});

import { Games } from '../dist/games.js';

import { commonView } from '../dist/game-delta.js';
import { createApp } from '../dist/app.js';
test('shared envelopes reject any viewer-dependent public activity or state',()=>{
  assert.deepEqual(commonView([{publicState:{turn:1},privateState:{secret:'A'}},{publicState:{turn:1},privateState:{secret:'B'}}],'privateState'),{publicState:{turn:1}});
  assert.throws(()=>commonView([{activity:['public'],privatePatch:[]},{activity:['secret'],privatePatch:[]}],'privatePatch'),/Recipient-dependent/);
});
test('fault hooks have no public mutable property and cannot be installed for a hosted database',async()=>{
  assert.equal(Object.hasOwn(new Games(null,null),'faults'),false);
  await assert.rejects(createApp({databaseUrl:'postgresql://test@host.invalid/test'},{gameFaults:{beforeCommit(){}}}),/local non-production/);
});
