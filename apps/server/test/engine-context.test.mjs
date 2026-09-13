import test from 'node:test';
import assert from 'node:assert/strict';
import { engineContext } from '../dist/engine-context.js';
import { createGame, assertInvariants } from '@island/game-engine';

test('backend entropy adapter supplies bounded crypto draws, UUIDs and explicit server time', () => {
  const context = engineContext(); assert.equal(new Date(context.now).toISOString(), context.now);
  for (const bound of [1, 2, 6, 19, 25]) for (let i = 0; i < 30; i++) { const n = context.random.int(bound); assert.ok(Number.isInteger(n) && n >= 0 && n < bound); }
  assert.throws(() => context.random.int(0));
  const players = ['RED', 'BLUE', 'WHITE'].map((colour, seatIndex) => ({ id: context.random.id(), colour, seatIndex, nickname: `Guest ${seatIndex}` }));
  const result = createGame({ roomId: context.random.id(), players }, context); assertInvariants(result.state);
  assert.equal(result.occurredAt, context.now); assert.ok(result.randomDraws.length > 0);
});
