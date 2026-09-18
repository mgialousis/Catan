import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyCommand, assertInvariants, chooseCommand, legalCommands, projectPlayer, seedFrom } from '../dist/index.js';
import { newGame, now, seeded, uuid } from './helpers.mjs';

/** Exactly what the server would hand a bot seat: public state plus its own hand. */
function viewFor(state, playerId) {
  return { publicState: state.publicState, hand: projectPlayer(state, playerId) };
}

function hintsFor(state) {
  return {
    developmentCardsRemaining: state.serverState.developmentDeck.length,
    pendingSetupVertexId: state.serverState.setup?.pendingVertexId ?? null,
    eligibleVictimIds: state.serverState.effect?.eligiblePlayerIds,
    bankStock: state.serverState.bank,
  };
}

let sequence = 500000;

/** Drives every seat with the policy until the game ends or the cap is hit. */
function playOut(difficulty, seed, limit = 6000) {
  let { state } = newGame(4, seed);
  const commands = [];
  for (let step = 0; step < limit && state.publicState.phase !== 'COMPLETE'; step++) {
    const actor = state.publicState.requiredPlayerIds[0] ?? state.publicState.activePlayerId;
    const view = viewFor(state, actor);
    const hints = hintsFor(state);
    const move = chooseCommand(view, hints, difficulty, seedFrom(seed, state.version, state.publicState.phaseId, actor));
    if (!move) break;
    const command = {
      protocolVersion: 1,
      commandId: uuid(++sequence),
      roomId: state.roomId,
      expectedVersion: state.version,
      expectedPhaseId: state.publicState.phaseId,
      type: move.type,
      payload: move.payload,
    };
    const result = applyCommand(state, actor, command, { now, random: seeded(seed + step) });
    assertInvariants(result.state);
    commands.push(`${actor.slice(-2)}:${move.type}`);
    state = result.state;
  }
  return { state, commands };
}

test('a bot-only game runs to completion without an illegal move', () => {
  const { state, commands } = playOut('MEDIUM', 7);
  assert.equal(state.publicState.phase, 'COMPLETE', `stalled after ${commands.length} commands`);
  assert.ok(state.publicState.winnerPlayerId, 'a completed game names a winner');
  assert.ok(commands.length > 60, `suspiciously short game: ${commands.length} commands`);
  assert.equal(state.publicState.finalPoints[state.publicState.winnerPlayerId] >= 10, true);
});

test('several seeds all terminate, so no board stalls the policy', () => {
  for (const seed of [11, 23, 42, 99]) {
    const { state, commands } = playOut('MEDIUM', seed);
    assert.equal(state.publicState.phase, 'COMPLETE', `seed ${seed} stalled after ${commands.length}`);
  }
});

test('the random tier never proposes a move the engine rejects', () => {
  // It need not finish; what matters is that every move it offers is accepted.
  const { state, commands } = playOut('EASY', 5, 1500);
  assert.ok(commands.length > 100, `expected sustained play, got ${commands.length}`);
  assert.ok(['COMPLETE', 'ACTION', 'AWAIT_ROLL', 'DISCARD_REQUIRED', 'ROBBER_MOVE', 'ROBBER_VICTIM', 'SETUP_SETTLEMENT', 'SETUP_ROAD', 'ROAD_BUILDING'].includes(state.publicState.phase));
});

test('the same seed and state always choose the same move', () => {
  const first = playOut('MEDIUM', 31, 400).commands;
  const second = playOut('MEDIUM', 31, 400).commands;
  assert.deepEqual(first, second, 'a replay after a crash must repeat the recorded move');
});

test('a bot decides from its own view alone', () => {
  const { state } = newGame(4, 3);
  const [me, rival] = state.serverState.turnOrder;
  const view = viewFor(state, me);
  // The view carries one hand and no server state, so no policy built on it can
  // consult an opponent's cards, the bank or the development deck.
  assert.equal(view.hand.playerId, me);
  assert.equal(Object.keys(view).sort().join(), 'hand,publicState');
  assert.equal(JSON.stringify(view).includes(rival), true, 'rivals are visible publicly');
  assert.equal('privateState' in view, false);
  assert.equal('serverState' in view, false);
  const serialised = JSON.stringify(view);
  for (const field of ['developmentDeck', 'turnOrder', 'bank']) {
    assert.equal(serialised.includes(field), false, `${field} must not reach a bot`);
  }
});

test('move generation offers nothing once the game is over or paused', () => {
  const { state } = newGame(4, 8);
  const paused = { ...state, publicState: { ...state.publicState, pauseReasons: ['MANUAL'] } };
  assert.deepEqual(legalCommands(viewFor(paused, state.serverState.turnOrder[0]), {}), []);
  const done = { ...state, publicState: { ...state.publicState, phase: 'COMPLETE' } };
  assert.deepEqual(legalCommands(viewFor(done, state.serverState.turnOrder[0]), {}), []);
});
