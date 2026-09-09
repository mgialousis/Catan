import test from 'node:test';
import assert from 'node:assert/strict';
import { projectPlayer, PHASE_TRANSITIONS } from '../dist/index.js';
test('private projection includes only the owner and creates independent resource/card objects', () => {
  const hand = { playerId: 'a', resources: { brick: 1, lumber: 2, wool: 0, grain: 0, ore: 1 }, developmentCards: [{ id: 'c', type: 'KNIGHT', purchasedOnTurn: 3, secret: true }], totalPoints: 2, discardRequired: 0, secret: true };
  const state = { privateState: { a: hand, b: { secret: 'opponent hand' } }, serverState: { secret: 'deck' } };
  const projected = projectPlayer(state, 'a');
  assert.equal(JSON.stringify(projected).includes('secret'), false);
  assert.equal(JSON.stringify(projected).includes('opponent'), false);
  projected.resources.brick = 9;
  assert.equal(hand.resources.brick, 1);
  assert.throws(() => projectPlayer(state, 'outsider'), /FORBIDDEN/);
});
test('pre-roll development effects can return before dice; terminal phase has no exit', () => {
  assert.ok(PHASE_TRANSITIONS.ROBBER_VICTIM.includes('AWAIT_ROLL'));
  assert.ok(PHASE_TRANSITIONS.ROAD_BUILDING.includes('AWAIT_ROLL'));
  assert.deepEqual(PHASE_TRANSITIONS.COMPLETE, []);
});
