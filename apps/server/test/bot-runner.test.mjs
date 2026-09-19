import test from 'node:test';
import assert from 'node:assert/strict';
import { botJobs, botMove, matchesBotJob, botDifficulty } from '../dist/bot-runner.js';
import { assertInvariants } from '../../../packages/game-engine/dist/index.js';
import { newGame, seeded, now } from '../../../packages/game-engine/test/helpers.mjs';
import { chooseCommand, projectPlayer, seedFrom, applyCommand } from '../../../packages/game-engine/dist/index.js';

/** A game whose non-host seats are automated, as a practice room creates them. */
function practice(seed = 17, bots = 3) {
  const { state } = newGame(4, seed);
  const ids = Object.keys(state.publicState.players).sort(
    (a, b) => state.publicState.players[a].seatIndex - state.publicState.players[b].seatIndex,
  );
  for (const id of ids.slice(1, 1 + bots)) state.publicState.players[id].kind = 'BOT';
  return { state, human: ids[0], bots: ids.slice(1, 1 + bots) };
}

test('only automated seats that owe a move are woken', () => {
  const { state, human } = practice();
  const active = state.publicState.activePlayerId;
  const jobs = botJobs(state);
  if (active === human) {
    assert.deepEqual(jobs, [], 'nothing is owed while the person is to move');
  } else {
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].playerId, active);
    assert.notEqual(jobs[0].playerId, human, 'a person is never driven by the runner');
  }
});

test('a paused or finished game wakes nobody', () => {
  const { state } = practice();
  const paused = { ...state, publicState: { ...state.publicState, pauseReasons: ['MANUAL'] } };
  assert.deepEqual(botJobs(paused), []);
  const done = { ...state, publicState: { ...state.publicState, phase: 'COMPLETE' } };
  assert.deepEqual(botJobs(done), []);
});

test('a job identifies one saved state, so a retry is a no-op', () => {
  const { state } = practice(4);
  const [job] = botJobs(state);
  if (!job) return;
  assert.deepEqual(botJobs(state)[0].commandId, job.commandId, 'the same state yields the same id');
  assert.ok(matchesBotJob(state, job));
  // Any later state must not accept the earlier job.
  const moved = botMove(state, job, 'MEDIUM', now, seeded(3));
  assert.ok(moved, 'a woken seat has something to play');
  assert.equal(matchesBotJob(moved.result.state, job), false, 'a spent job never applies twice');
  assert.equal(moved.command.commandId, job.commandId);
  assert.equal(moved.command.expectedVersion, state.version);
  assertInvariants(moved.result.state);
});

test('the same saved state always produces the same move', () => {
  const { state } = practice(9);
  const [job] = botJobs(state);
  if (!job) return;
  const first = botMove(state, job, 'MEDIUM', now, seeded(1));
  const second = botMove(state, job, 'MEDIUM', now, seeded(2));
  assert.equal(first.command.type, second.command.type);
  assert.deepEqual(first.command.payload, second.command.payload);
});

test('a practice game plays itself forward through the runner', () => {
  let { state, human } = practice(21);
  let moves = 0;
  for (let step = 0; step < 4000 && state.publicState.phase !== 'COMPLETE'; step++) {
    const [job] = botJobs(state);
    if (!job) {
      // The person is to move. Stand in for them so the bots keep their turns.
      const view = { publicState: state.publicState, hand: projectPlayer(state, human) };
      const hints = {
        developmentCardsRemaining: state.serverState.developmentDeck.length,
        pendingSetupVertexId: state.serverState.setup?.pendingVertexId ?? null,
        eligibleVictimIds: state.serverState.effect?.eligiblePlayerIds,
        bankStock: state.serverState.bank,
      };
      const move = chooseCommand(view, hints, 'MEDIUM', seedFrom(state.roomId, state.version, state.publicState.phaseId, human));
      if (!move) break;
      state = applyCommand(state, human, {
        protocolVersion: 1, commandId: `00000000-0000-4000-8000-${step.toString(16).padStart(12, '0')}`,
        roomId: state.roomId, expectedVersion: state.version, expectedPhaseId: state.publicState.phaseId,
        type: move.type, payload: move.payload,
      }, { now, random: seeded(700 + step) }).state;
      continue;
    }
    const applied = botMove(state, job, 'MEDIUM', now, seeded(900 + step));
    assert.ok(applied, 'a woken seat always has a legal move');
    assertInvariants(applied.result.state);
    state = applied.result.state;
    moves++;
  }
  assert.equal(state.publicState.phase, 'COMPLETE', 'the practice game finished');
  assert.ok(moves > 40, `automated seats did the work: ${moves} moves`);
});

test('difficulty comes from room settings, with a sane default', () => {
  assert.equal(botDifficulty({ botDifficulty: 'EASY' }), 'EASY');
  assert.equal(botDifficulty({ botDifficulty: 'MEDIUM' }), 'MEDIUM');
  assert.equal(botDifficulty({ botDifficulty: 'IMPOSSIBLE' }), 'MEDIUM');
  assert.equal(botDifficulty({}), 'MEDIUM');
  assert.equal(botDifficulty(null), 'MEDIUM');
});
