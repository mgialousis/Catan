import { test } from 'node:test';
import assert from 'node:assert/strict';
import { botPace, botReadyAt, BOT_BASE_PACE_MS } from '../dist/bot-runner.js';

// Animation lengths as apps/mobile/lib/game/table_stage.dart defines them, and
// the slack the pacing is required to keep on top of each.
const MARGIN = 700;
const rollAnimationMs = cards =>
  cards === 0 ? 2800 : 2800 + 600 + cards * 1000 + (cards - 1) * 160 + 200 + 600;
const pieceAnimationMs = 2 * 600 + 1300;
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
  assert.equal(botPace('ROLL_DICE', []), 2800 + MARGIN);
  assert.equal(
    botPace('ROLL_DICE', projectEffects([{ type: 'PUBLIC_ACTIVITY', action: 'DICE_ROLLED', actorPlayerId: 'player-0', message: 'Rolled 7.' }], 'player-0').activity),
    2800 + MARGIN,
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

// The next seat must not start rolling or building while the table is still
// showing the last move: pacing has to clear the animation, not merely match it.
test('every paced move outlasts the animation it is waiting for', () => {
  for (const type of ['BUILD_ROAD', 'BUILD_SETTLEMENT', 'BUILD_CITY']) {
    assert.equal(botPace(type), pieceAnimationMs + MARGIN);
    assert.ok(botPace(type) > pieceAnimationMs, `${type} must clear its blink`);
  }
  for (const cards of [0, 1, 2, 3, 5, 8]) {
    const pace = botPace('ROLL_DICE', cards ? payout(cards) : []);
    assert.equal(pace, rollAnimationMs(cards) + MARGIN);
    assert.ok(pace > rollAnimationMs(cards), `${cards} cards must clear the payout`);
  }
});

test('anything without a presentation keeps the ordinary pace', () => {
  for (const type of [null, 'END_TURN', 'BUY_DEVELOPMENT_CARD', 'BANK_TRADE']) {
    assert.equal(botPace(type), BOT_BASE_PACE_MS);
  }
});

test('a quick human turn does not let the next seat roll over the payout', () => {
  // A roll that pays five cards, then the person ends their own turn a second
  // later. The bot must still wait out the payout the table is showing.
  const rolledAt = 10_000;
  const endedAt = 11_000;
  const recent = [
    { commandType: 'END_TURN', activity: [], atMs: endedAt },
    { commandType: 'ROLL_DICE', activity: payout(5), atMs: rolledAt },
  ];
  const ready = botReadyAt(recent, endedAt);
  assert.equal(ready, rolledAt + botPace('ROLL_DICE', payout(5)));
  assert.ok(
    ready > endedAt + BOT_BASE_PACE_MS,
    'ending a turn early must not shorten the payout already in flight',
  );
});

test('a close-up of a piece is waited out the same way', () => {
  const builtAt = 50_000;
  const recent = [
    { commandType: 'END_TURN', activity: [], atMs: builtAt + 300 },
    { commandType: 'BUILD_CITY', activity: [], atMs: builtAt },
  ];
  assert.equal(botReadyAt(recent, builtAt + 300), builtAt + botPace('BUILD_CITY'));
});

test('an old move no longer holds the table', () => {
  const recent = [{ commandType: 'END_TURN', activity: [], atMs: 90_000 }];
  assert.equal(botReadyAt(recent, 90_000), 90_000 + BOT_BASE_PACE_MS);
  assert.equal(botReadyAt([], 90_000), 90_000 + BOT_BASE_PACE_MS);
});

test('opening placements wait only for the blink, not a close-up', () => {
  for (const phase of ['SETUP_SETTLEMENT', 'SETUP_ROAD']) {
    for (const type of ['BUILD_ROAD', 'BUILD_SETTLEMENT']) {
      assert.equal(botPace(type, [], phase), 1300 + MARGIN);
      assert.ok(
        botPace(type, [], phase) < botPace(type),
        `${type} in ${phase} should not wait out a camera move`,
      );
    }
  }
  // Once the opening is over the close-up is back.
  assert.equal(botPace('BUILD_CITY', [], 'ACTION'), pieceAnimationMs + MARGIN);
  assert.equal(botPace('BUILD_CITY', []), pieceAnimationMs + MARGIN);
});

test('a payout is unaffected by the phase', () => {
  assert.equal(
    botPace('ROLL_DICE', payout(3), 'SETUP_ROAD'),
    botPace('ROLL_DICE', payout(3)),
  );
});
