import test from 'node:test';
import assert from 'node:assert/strict';
import { createGame, applyCommand, replayRandom, canSettle, canRoad, emptyResources, COSTS, has, bankRate, projectGame, assertInvariants, PHASE_TRANSITIONS } from '../dist/index.js';
import { validator } from '@island/protocol';
import { newGame, command, now } from './helpers.mjs';
const types = Object.keys(emptyResources());
const bundle = values => ({ ...emptyResources(), ...values });
// PostgreSQL JSONB may reorder object keys on persistence. Arrays retain their order.
const reorder = value => Array.isArray(value) ? value.map(reorder) : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => b.localeCompare(a)).map(([k, v]) => [k, reorder(v)])) : value;

// Test-only cooperative actors; every mutation uses the same validated commands as a client.
// Opponents trade at 1:1 and wait. This is a reproducible rule traversal, not a game AI.
for (const [count, seed] of [[3, 11], [3, 83], [4, 42], [4, 129]]) test(`complete ${count}-player seeded match ${seed} and exact entropy replay`, t => {
  const game = newGame(count, seed), winner = game.state.serverState.turnOrder[0], records = [];
  let state = game.state;
  const validateCommand = validator('gameCommand'), validateSnapshot = validator('gameSnapshot');
  function send(type, payload = {}, actor = state.publicState.activePlayerId) {
    const cmd = command(state, type, payload); assert.ok(validateCommand(cmd), JSON.stringify(validateCommand.errors));
    // Seeded malformed variants ensure rejection never consumes authoritative state.
    const before = JSON.stringify(state);
    assert.throws(() => applyCommand(state, actor, { ...cmd, expectedVersion: state.version + 1 }, { now, random: game.random }), e => e.code === 'STALE_VERSION');
    assert.equal(JSON.stringify(state), before);
    const result = applyCommand(state, actor, cmd, { now, random: game.random });
    if (state.publicState.phase !== result.state.publicState.phase) assert.ok(PHASE_TRANSITIONS[state.publicState.phase].includes(result.state.publicState.phase));
    records.push({ actor, cmd, draws: result.randomDraws, effects: result.effects }); state = result.state;
    assertInvariants(state);
    if (state.version % 50 === 0 || state.publicState.phase === 'COMPLETE') for (const id of Object.keys(state.privateState)) assert.ok(validateSnapshot(projectGame(state, id, now)), JSON.stringify(validateSnapshot.errors));
  }
  function settleScore(vertex) {
    return state.publicState.board.vertices[vertex].hexIds.reduce((score, h) => {
      const hex = state.publicState.board.hexes[h]; return score + (hex.number ? 6 - Math.abs(7 - hex.number) : 0) * (['MOUNTAINS', 'FIELDS', 'PASTURE'].includes(hex.terrain) ? 2 : 1);
    }, 0);
  }
  function acquire(cost) {
    for (let tries = 0; tries < 20; tries++) {
      const hand = state.privateState[winner].resources;
      if (has(hand, cost)) return true;
      const need = types.find(r => hand[r] < cost[r]), surplus = types.filter(r => hand[r] > cost[r]);
      if (!surplus.length) return false;
      const partner = Object.keys(state.privateState).find(id => id !== winner && state.privateState[id].resources[need] > 0);
      if (partner) {
        send('PROPOSE_TRADE', { targetPlayerId: partner, give: bundle({ [surplus[0]]: 1 }), receive: bundle({ [need]: 1 }) });
        const offer = Object.values(state.publicState.trades).find(o => o.status === 'OPEN' && o.proposerPlayerId === winner);
        send('ACCEPT_TRADE', { offerId: offer.offerId, offerRevision: offer.revision }, partner);
      } else {
        const give = surplus.find(r => hand[r] - cost[r] >= bankRate(state.publicState, winner, r));
        if (!give || !state.serverState.bank[need]) return false;
        send('BANK_TRADE', { giveType: give, receiveType: need, receiveCount: 1 });
      }
    }
    return false;
  }
  while (state.publicState.phase !== 'COMPLETE' && state.publicState.turnNumber < 1600) {
    const p = state.publicState, actor = p.activePlayerId;
    switch (p.phase) {
      case 'SETUP_SETTLEMENT': send('PLACE_SETUP_SETTLEMENT', { vertexId: Object.keys(p.board.vertices).filter(v => canSettle(p, actor, v, true)).sort((a, b) => settleScore(b) - settleScore(a))[0] }); break;
      case 'SETUP_ROAD': send('PLACE_SETUP_ROAD', { edgeId: p.board.vertices[state.serverState.setup.pendingVertexId].edgeIds.find(e => canRoad(p, actor, e)) }); break;
      case 'AWAIT_ROLL': {
        const knight = actor === winner && !p.developmentCardPlayedThisTurn && state.privateState[actor].developmentCards.find(c => c.type === 'KNIGHT' && c.purchasedOnTurn < p.turnNumber);
        if (knight && p.players[actor].playedKnights < 3) send('PLAY_DEVELOPMENT_CARD', { cardId: knight.id, choice: {} }); else send('ROLL_DICE'); break;
      }
      case 'DISCARD_REQUIRED': {
        const id = p.requiredPlayerIds[0], chosen = emptyResources(); let remaining = state.privateState[id].discardRequired;
        for (const r of types) { chosen[r] = Math.min(remaining, state.privateState[id].resources[r]); remaining -= chosen[r]; }
        send('DISCARD_RESOURCES', { resources: chosen }, id); break;
      }
      case 'ROBBER_MOVE': send('MOVE_ROBBER', { hexId: Object.keys(p.board.hexes).find(h => h !== p.robberHexId && !p.board.hexes[h].vertexIds.some(v => p.buildings[v]?.ownerPlayerId === winner)) }); break;
      case 'ROBBER_VICTIM': send('CHOOSE_ROBBER_VICTIM', { victimPlayerId: state.serverState.effect.eligiblePlayerIds[0] }); break;
      case 'ACTION': {
        if (actor === winner) {
          if (!Object.values(p.buildings).some(b => b.ownerPlayerId === actor && b.type === 'CITY') && acquire(COSTS.CITY)) send('BUILD_CITY', { vertexId: Object.keys(p.buildings).find(v => p.buildings[v].ownerPlayerId === actor) });
          let limit = 0;
          while (state.publicState.phase === 'ACTION' && state.serverState.developmentDeck.length && limit++ < 25 && acquire(COSTS.DEVELOPMENT)) send('BUY_DEVELOPMENT_CARD');
        }
        if (state.publicState.phase === 'ACTION') send('END_TURN'); break;
      }
      default: assert.fail(`Unexpected phase ${p.phase}`);
    }
  }
  assert.equal(state.publicState.phase, 'COMPLETE', `did not finish: ${JSON.stringify(state.privateState[winner])}`);
  assert.equal(state.publicState.winnerPlayerId, winner); assert.ok(state.privateState[winner].totalPoints >= 10);
  assert.ok(state.publicState.winnerVictoryPointCardIds.length > 0);
  assert.throws(() => applyCommand(state, winner, command(state, 'END_TURN'), { now, random: game.random }), e => e.code === 'GAME_FINISHED');
  const entropy = replayRandom(game.initial.randomDraws); let replay = createGame(game.input, { now, random: entropy }); entropy.assertConsumed();
  for (const record of records) {
    const random = replayRandom(record.draws); replay = applyCommand(reorder(replay.state), record.actor, record.cmd, { now, random }); random.assertConsumed();
    assert.deepEqual(replay.effects, record.effects); assert.deepEqual(replay.randomDraws, record.draws);
  }
  assert.deepEqual(replay.state, state);
  t.diagnostic(`${records.length} accepted commands, ${state.publicState.turnNumber} turns; score ${state.privateState[winner].totalPoints}; all commands replayed exactly`);
});
