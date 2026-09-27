import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isValid, schema } from '../dist/index.js';
const fixtures = JSON.parse(readFileSync(new URL('../fixtures/contracts.json', import.meta.url)));
for (const fixture of fixtures) {
  test(fixture.name, () => assert.equal(isValid(fixture.schema, fixture.value), fixture.valid));
}
test('every schema compiles independently', () => {
  for (const name of Object.keys(schema.definitions)) isValid(name, null);
});


test('settings accept every shipped difficulty and reject unknown tiers', () => {
  const settings = {maxPlayers:4,turnLimitSeconds:null,boardMode:'STANDARD_RANDOM',rulesVersion:'base-2020-v1'};
  for(const botDifficulty of ['EASY','MEDIUM','HARD']) assert.ok(isValid('settings',{...settings,botDifficulty}));
  assert.equal(isValid('settings',{...settings,botDifficulty:'IMPOSSIBLE'}),false);
});
