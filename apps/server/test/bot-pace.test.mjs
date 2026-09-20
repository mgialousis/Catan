import { test } from 'node:test';
import assert from 'node:assert/strict';
import { botPace, BOT_BASE_PACE_MS } from '../dist/bot-runner.js';
import { projectEffects } from '../../../packages/game-engine/dist/index.js';

// Built through the same projection the server persists with, so this cannot
// drift back to the engine's own field names: `action` becomes `type` there,
// and reading the wrong one silently counts no cards at all.
const collected = (...amounts) =>
  projectEffects(
    amounts.map((resources, i) => ({
      type: 'PUBLIC_ACTIVITY', action: 'RESOURCES_COLLECTED',
      actorPlayerId: `player-${i}`, message: 'Collected resources from the roll.', resources,
    })),
    'player-0',
  ).activity;
const payout = cards => collected({ lumber: cards });

test('a roll is left alone until its payout has finished flying', () => {
  // One icon flies per card, so more cards means a longer wait, and the next
  // roll cannot start in the middle of the previous one's delivery.
  const one = botPace('ROLL_DICE', payout(1));
  const three = botPace('ROLL_DICE', payout(3));
  assert.ok(one > 2800, `expected the dice hold plus a flight, got ${one}`);
  assert.ok(three > one, 'three cards must take longer than one');
  assert.equal(three - one, 2 * (1000 + 160));
});

test('a roll that pays nobody waits only for the dice', () => {
  assert.equal(botPace('ROLL_DICE', []), 2800);
  assert.equal(
    botPace('ROLL_DICE', projectEffects([{ type: 'PUBLIC_ACTIVITY', action: 'DICE_ROLLED', actorPlayerId: 'player-0', message: 'Rolled 7.' }], 'player-0').activity),
    2800,
  );
});

test('payouts to several seats are counted together', () => {
  const split = collected({ lumber: 1 }, { brick: 1, ore: 1 });
  assert.equal(botPace('ROLL_DICE', split), botPace('ROLL_DICE', payout(3)));
});

test('placing a piece is held long enough to be seen', () => {
  for (const type of ['BUILD_ROAD', 'BUILD_SETTLEMENT', 'BUILD_CITY']) {
    assert.ok(botPace(type) > BOT_BASE_PACE_MS, `${type} should pause for the close-up`);
  }
});

test('anything without a presentation keeps the ordinary pace', () => {
  for (const type of [null, 'END_TURN', 'BUY_DEVELOPMENT_CARD', 'BANK_TRADE']) {
    assert.equal(botPace(type), BOT_BASE_PACE_MS);
  }
});
