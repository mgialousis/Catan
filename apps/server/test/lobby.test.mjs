import test from 'node:test';
import assert from 'node:assert/strict';
import { canonical, hash, invitation, nickname, normalizeCode, startEligibility } from '../dist/lobby-policy.js';

test('nicknames normalize Unicode/spacing and count graphemes; invisible controls rejected', () => {
  assert.deepEqual(nickname('  Ａlice   Smith  '), { name: 'Alice Smith', key: 'alice smith' });
  assert.equal(nickname('e\u0301é').key, 'éé');
  for (const value of ['a', ' '.repeat(10), 'a'.repeat(21), 'Alice\u202e', 'Alice\n', 'Al\u200bice']) assert.throws(() => nickname(value));
});
test('invitation codes use 50 bits, normalize human formatting and reject ambiguous characters', () => {
  const values = new Set(Array.from({ length: 1000 }, invitation));
  assert.equal(values.size, 1000);
  for (const code of values) assert.match(code, /^[0-9A-HJKMNP-TV-Z]{10}$/);
  assert.equal(normalizeCode(' abcde-fghjk '), 'ABCDEFGHJK');
  assert.throws(() => normalizeCode('ABCDEFGHIJ'));
});
test('request hash ignores object key order but binds expected revision and intent', () => {
  assert.equal(hash(canonical({ a: 1, b: { z: 2, x: 3 } })), hash(canonical({ b: { x: 3, z: 2 }, a: 1 })));
  assert.notEqual(hash(canonical({ version: 1 })), hash(canonical({ version: 2 })));
});
test('start requires three or four ready, connected players with distinct colours', () => {
  const players = ['RED', 'BLUE', 'WHITE', 'ORANGE'].map((colour, index) => ({ id: `${index}`, colour, ready: true }));
  const online = new Set(players.map(p => p.id));
  assert.doesNotThrow(() => startEligibility(players, online));
  assert.doesNotThrow(() => startEligibility(players.slice(0, 3), online));
  assert.throws(() => startEligibility(players.slice(0, 2), online));
  assert.throws(() => startEligibility(players, new Set(['0', '1', '2'])));
  assert.throws(() => startEligibility(players.map(p => ({ ...p, colour: 'RED' })), online));
  assert.throws(() => startEligibility(players.map(p => ({ ...p, ready: false })), online));
});

import { clientAddress } from '../dist/client-address.js';
test('forwarding headers require explicit trusted hops; forged left-hand values are ignored', () => {
  assert.equal(clientAddress('10.0.0.1', '203.0.113.8'), '10.0.0.1');
  assert.equal(clientAddress('10.0.0.1', 'forged, 203.0.113.8', 1), '203.0.113.8');
  assert.equal(clientAddress('10.0.0.1', 'invalid', 1), '10.0.0.1');
});
