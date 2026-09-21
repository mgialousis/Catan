import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { botPace, botReadyAt, botReadyFromHistory, BOT_BASE_PACE_MS } from '../dist/bot-runner.js';

// Animation lengths as apps/mobile/lib/game/table_stage.dart defines them, and
// the slack the pacing is required to keep on top of each.
const MARGIN = 700;
const rollAnimationMs = cards =>
  cards === 0 ? 2800 : 2800 + 600 + cards * 1000 + (cards - 1) * 160 + 200 + 600;
const pieceAnimationMs = 2 * 600 + 1300;
import { projectEffects, projectPlayer, legalCommands } from '../../../packages/game-engine/dist/index.js';
import { newGame, act } from '../../../packages/game-engine/test/helpers.mjs';

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

test('opening placement commands wait for the blink, including the final road', () => {
  let { state } = newGame();
  let placements = 0;
  while (state.serverState.setup) {
    const actor = state.publicState.activePlayerId;
    const [move] = legalCommands(
      { publicState: state.publicState, hand: projectPlayer(state, actor) },
      { pendingSetupVertexId: state.serverState.setup.pendingVertexId, developmentCardsRemaining: state.serverState.developmentDeck.length },
    );
    assert.ok(move, 'engine offers a setup placement');
    state = act(state, move.type, move.payload).state;
    assert.equal(botPace(move.type), 1300 + MARGIN, `${move.type} entering ${state.publicState.phase}`);
    assert.ok(++placements <= 16);
  }
  assert.equal(placements, 16);
  assert.equal(state.publicState.phase, 'AWAIT_ROLL');
  assert.equal(botPace('BUILD_CITY'), pieceAnimationMs + MARGIN);
});

test('server release matches the timing scenarios exercised by Flutter', () => {
  const scenarios = JSON.parse(readFileSync(new URL('../../../packages/protocol/fixtures/presentation-timing.json', import.meta.url)));
  for (const { cards, durationMs, serverMarginMs } of scenarios) {
    assert.equal(botPace('ROLL_DICE', payout(cards)), durationMs + serverMarginMs);
  }
});

test('rapid non-visual moves cannot evict an unfinished payout', async () => {
  const rolledAt = 100_000;
  const moves = [
    { sequence: 1, commandType: 'ROLL_DICE', activity: payout(8), atMs: rolledAt },
    ...Array.from({ length: 40 }, (_, i) => ({
      sequence: i + 2, commandType: i % 2 ? 'WITHDRAW_TRADE' : 'PROPOSE_TRADE',
      activity: [], atMs: rolledAt + 100 + i * 100,
    })),
    { sequence: 42, commandType: 'END_TURN', activity: [], atMs: rolledAt + 4200 },
  ].reverse();
  const cursors = [];
  const ready = await botReadyFromHistory(async before => {
    cursors.push(before);
    return moves.filter(move => move.sequence < before).slice(0, 32);
  }, 42, rolledAt + 4200, rolledAt + 5100);
  assert.equal(ready, rolledAt + botPace('ROLL_DICE', payout(8)));
  assert.ok(cursors.length >= 2, 'reads beyond the first page');
});

test('history scanning stops once even the longest payout has expired', async () => {
  let reads = 0;
  const ready = await botReadyFromHistory(async () => {
    reads++;
    return Array.from({ length: 32 }, (_, i) => ({ sequence: 99 - i, commandType: 'ROLL_DICE', activity: payout(95), atMs: 0 }));
  }, 99, 0, 120_000);
  assert.equal(reads, 1);
  assert.ok(ready < 120_000);
});
