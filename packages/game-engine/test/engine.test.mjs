import test from 'node:test';
import assert from 'node:assert/strict';
import { applyCommand, canSettle, canRoad, legalRoads, bankRate, emptyResources, refreshDerived, assertInvariants, projectGame, projectPublic, projectEffects, TERRAIN_RESOURCE } from '../dist/index.js';
import { validator } from '@island/protocol';
import { newGame, setup, seeded, command, act, roll, resources, clearHands, giveCard, asAction, now, uuid } from './helpers.mjs';
const bundle = values => ({ ...emptyResources(), ...values });
function rejects(state, type, payload, code, actor = state.publicState.activePlayerId) {
  const before = structuredClone(state);
  assert.throws(() => act(state, type, payload, actor), e => e.code === code, `${type}: ${code}`);
  assert.deepEqual(state, before, 'rejected command must not mutate input');
}
for (const count of [3, 4]) test(`${count} player snake order, exactly one second-settlement resource grant and no setup cost`, () => {
  let { state } = newGame(count); const order = [...state.serverState.turnOrder], visited = [], grants = [];
  while (state.serverState.setup) {
    const p = state.publicState, actor = p.activePlayerId;
    if (p.phase === 'SETUP_SETTLEMENT') {
      visited.push(actor); const vertex = Object.keys(p.board.vertices).find(v => canSettle(p, actor, v, true));
      const result = act(state, 'PLACE_SETUP_SETTLEMENT', { vertexId: vertex });
      grants.push(...result.effects.filter(e => e.reason === 'INITIAL_RESOURCES').map(e => e.toPlayerId)); state = result.state;
    } else {
      const pending = state.serverState.setup.pendingVertexId;
      const wrong = Object.keys(p.board.edges).find(e => !p.board.edges[e].vertexIds.includes(pending));
      rejects(state, 'PLACE_SETUP_ROAD', { edgeId: wrong }, 'ILLEGAL_PLACEMENT');
      state = act(state, 'PLACE_SETUP_ROAD', { edgeId: p.board.vertices[pending].edgeIds.find(e => canRoad(p, actor, e)) }).state;
    }
  }
  assert.deepEqual(visited, [...order, ...order.toReversed()]); assert.deepEqual(grants, order.toReversed());
  assert.equal(state.publicState.phase, 'AWAIT_ROLL'); assert.equal(state.publicState.turnNumber, 1);
  for (const player of Object.values(state.publicState.players)) assert.deepEqual(player.remainingPieces, { roads: 13, settlements: 3, cities: 4 });
});

test('authorization, stale versions, phases, malformed commands, pause and immutability', () => {
  const state = setup(), before = structuredClone(state), cmd = command(state, 'ROLL_DICE');
  for (const [change, actor, code] of [
    [{}, uuid(999), 'FORBIDDEN'], [{ roomId: uuid(99) }, state.publicState.activePlayerId, 'FORBIDDEN'],
    [{ expectedVersion: 999 }, state.publicState.activePlayerId, 'STALE_VERSION'], [{ expectedPhaseId: uuid(2) }, state.publicState.activePlayerId, 'WRONG_PHASE'],
    [{ payload: { dice: [6, 6] } }, state.publicState.activePlayerId, 'INVALID_PAYLOAD'], [{ type: '__proto__' }, state.publicState.activePlayerId, 'INVALID_PAYLOAD'],
  ]) assert.throws(() => applyCommand(state, actor, { ...cmd, ...change }, { now, random: seeded() }), e => e.code === code);
  rejects(state, 'ROLL_DICE', {}, 'NOT_YOUR_TURN', state.serverState.turnOrder[1]);
  const next = applyCommand(state, state.publicState.activePlayerId, cmd, { now, random: seeded(100) }).state;
  assert.deepEqual(state, before); assert.equal(next.version, state.version + 1);
  assert.throws(() => applyCommand(next, state.publicState.activePlayerId, cmd, { now, random: seeded() }), e => e.code === 'STALE_VERSION');
  state.publicState.pauseReasons = ['DISCONNECTED']; rejects(state, 'ROLL_DICE', {}, 'GAME_PAUSED');
});

test('all 36 dice pairs produce exactly the independently computed non-robbed settlement/city demand', () => {
  const original = clearHands(setup());
  const [v, b] = Object.entries(original.publicState.buildings)[0]; b.type = 'CITY'; original.publicState.players[b.ownerPlayerId].remainingPieces.cities--; original.publicState.players[b.ownerPlayerId].remainingPieces.settlements++; refreshDerived(original);
  for (let a = 1; a <= 6; a++) for (let b = 1; b <= 6; b++) {
    const expected = Object.fromEntries(Object.keys(original.privateState).map(id => [id, emptyResources()]));
    if (a + b !== 7) for (const [id, h] of Object.entries(original.publicState.board.hexes)) {
      if (h.number !== a + b || id === original.publicState.robberHexId || !TERRAIN_RESOURCE[h.terrain]) continue;
      for (const vertex of h.vertexIds) { const building = original.publicState.buildings[vertex]; if (building) expected[building.ownerPlayerId][TERRAIN_RESOURCE[h.terrain]] += building.type === 'CITY' ? 2 : 1; }
    }
    const result = roll(original, a, b); for (const id of Object.keys(expected)) assert.deepEqual(result.state.privateState[id].resources, expected[id]);
    const payouts = Object.fromEntries(projectEffects(result.effects, original.serverState.turnOrder[0]).activity
      .filter(e => e.type === 'RESOURCES_COLLECTED').map(e => [e.actorPlayerId, e.resources]));
    assert.deepEqual(payouts, Object.fromEntries(Object.entries(expected).filter(([, hand]) => Object.values(hand).some(n => n > 0))));
    for (const viewer of original.serverState.turnOrder) {
      assert.deepEqual(projectEffects(result.effects, viewer).activity, projectEffects(result.effects, original.serverState.turnOrder[0]).activity);
    }
    assert.equal(result.state.publicState.phase, a + b === 7 ? 'ROBBER_MOVE' : 'ACTION');
  }
});

test('bank shortage pays remaining stock to one recipient but none to multiple recipients', () => {
  for (const recipients of [1, 2]) {
    const state = clearHands(setup()); const ids = state.serverState.turnOrder;
    // Inventory-preserving scenario with buildings on independent corners of one fertile hex.
    state.publicState.buildings = {}; state.publicState.roads = {};
    for (const p of Object.values(state.publicState.players)) p.remainingPieces = { roads: 15, settlements: 5, cities: 4 };
    const [hexId, hex] = Object.entries(state.publicState.board.hexes).find(([, h]) => h.number !== null);
    for (let i = 0; i < recipients; i++) { state.publicState.buildings[hex.vertexIds[i * 2]] = { ownerPlayerId: ids[i], type: 'CITY' }; state.publicState.players[ids[i]].remainingPieces.cities--; }
    refreshDerived(state); const type = TERRAIN_RESOURCE[hex.terrain]; resources(state, { [ids[2]]: { [type]: 18 } });
    const sum = hex.number, a = Math.min(6, sum - 1); const result = roll(state, a, sum - a), next = result.state;
    const payouts = projectEffects(result.effects, ids[0]).activity.filter(e => e.type === 'RESOURCES_COLLECTED');
    for (let i = 0; i < recipients; i++) assert.equal(payouts.find(e => e.actorPlayerId === ids[i])?.resources[type] ?? 0, recipients === 1 ? 1 : 0);
    for (let i = 0; i < recipients; i++) assert.equal(next.privateState[ids[i]].resources[type], recipients === 1 ? 1 : 0);
    assert.equal(next.serverState.bank[type], recipients === 1 ? 0 : 1);
    const blocked = structuredClone(state); blocked.publicState.robberHexId = hexId; assert.equal(roll(blocked, a, sum - a).state.privateState[ids[0]].resources[type], 0);
  }
});

test('seven records 7/8/9/10 thresholds excluding development cards and waits for every discard', () => {
  let state = clearHands(setup()); const ids = state.serverState.turnOrder;
  resources(state, { [ids[0]]: { brick: 7 }, [ids[1]]: { lumber: 8 }, [ids[2]]: { wool: 9 }, [ids[3]]: { ore: 10 } });
  giveCard(state, ids[0], 'KNIGHT'); state = roll(state, 3, 4).state;
  assert.deepEqual(ids.map(id => state.privateState[id].discardRequired), [0, 4, 4, 5]);
  rejects(state, 'MOVE_ROBBER', { hexId: 'h-0' }, 'WRONG_PHASE');
  rejects(state, 'DISCARD_RESOURCES', { resources: bundle({ lumber: 3 }) }, 'INVALID_PAYLOAD', ids[1]);
  for (const [index, type, n] of [[3, 'ore', 5], [1, 'lumber', 4], [2, 'wool', 4]]) {
    const result = act(state, 'DISCARD_RESOURCES', { resources: bundle({ [type]: n }) }, ids[index]);
    assert.equal(projectEffects(result.effects, ids[0]).resourceTransfers.length, 0);
    assert.equal(projectEffects(result.effects, ids[index]).resourceTransfers.length, 1);
    // Discards are face up in the physical game: a bystander sees who discarded
    // what, even though the transfer itself stays visible only to the discarder.
    const announced = projectEffects(result.effects, ids[0]).activity.find(a => a.type === 'RESOURCES_DISCARDED');
    assert.equal(announced.actorPlayerId, ids[index]);
    assert.deepEqual(announced.resources, bundle({ [type]: n }));
    state = result.state;
  }
  assert.equal(state.publicState.phase, 'ROBBER_MOVE');
});

test('robber filters victims, samples individual cards and conceals stolen types from bystanders', () => {
  let initial = clearHands(setup()); const actor = initial.publicState.activePlayerId, victim = initial.serverState.turnOrder[1], observer = initial.serverState.turnOrder[2];
  resources(initial, { [victim]: { brick: 1, ore: 3 } }); initial = roll(initial, 3, 4).state;
  const hexId = Object.keys(initial.publicState.board.hexes).find(h => h !== initial.publicState.robberHexId && initial.publicState.board.hexes[h].vertexIds.some(v => initial.publicState.buildings[v]?.ownerPlayerId === victim));
  rejects(initial, 'MOVE_ROBBER', { hexId: initial.publicState.robberHexId }, 'ILLEGAL_PLACEMENT');
  const ready = act(initial, 'MOVE_ROBBER', { hexId }).state;
  assert.deepEqual(ready.serverState.effect.eligiblePlayerIds, [victim]);
  rejects(ready, 'CHOOSE_ROBBER_VICTIM', { victimPlayerId: actor }, 'FORBIDDEN');
  for (let index = 0; index < 4; index++) {
    const random = seeded(202 + index), result = act(ready, 'CHOOSE_ROBBER_VICTIM', { victimPlayerId: victim }, actor, { id: () => random.id(), int: n => { assert.equal(n, 4); return index; } });
    assert.equal(result.state.privateState[actor].resources[index === 0 ? 'brick' : 'ore'], 1);
    assert.equal(projectEffects(result.effects, observer).resourceTransfers.length, 0);
    assert.equal(projectEffects(result.effects, victim).resourceTransfers.length, 1);
    // Who was robbed is public; which card was taken must never become public.
    const theft = projectEffects(result.effects, observer).activity.find(a => a.type === 'RESOURCE_STOLEN');
    assert.equal(theft.actorPlayerId, actor);
    assert.equal(theft.subjectPlayerId, victim);
    assert.equal(theft.resources, undefined);
    assert.ok(!JSON.stringify(theft).includes('brick') && !JSON.stringify(theft).includes('ore'));
    assert.equal(result.state.publicState.phase, 'ACTION');
  }
  const empty = Object.keys(initial.publicState.board.hexes).find(h => h !== initial.publicState.robberHexId && !initial.publicState.board.hexes[h].vertexIds.some(v => initial.publicState.buildings[v]?.ownerPlayerId === victim));
  assert.equal(act(initial, 'MOVE_ROBBER', { hexId: empty }).state.publicState.phase, 'ACTION');
});

test('paid roads and cities debit exact costs, reuse settlements and reject invalid placement atomically', () => {
  let state = asAction(clearHands(setup())); const actor = state.publicState.activePlayerId, edge = legalRoads(state.publicState, actor)[0];
  rejects(state, 'BUILD_ROAD', { edgeId: edge }, 'INSUFFICIENT_RESOURCES');
  resources(state, { [actor]: { brick: 1, lumber: 1, ore: 3, grain: 2 } });
  state = act(state, 'BUILD_ROAD', { edgeId: edge }).state; assert.equal(state.privateState[actor].resources.brick, 0);
  rejects(state, 'BUILD_ROAD', { edgeId: edge }, 'ILLEGAL_PLACEMENT');
  const vertex = Object.keys(state.publicState.buildings).find(v => state.publicState.buildings[v].ownerPlayerId === actor);
  const old = state.publicState.players[actor].remainingPieces.settlements;
  state = act(state, 'BUILD_CITY', { vertexId: vertex }).state;
  assert.equal(state.publicState.players[actor].remainingPieces.settlements, old + 1); assert.equal(state.publicState.players[actor].remainingPieces.cities, 3);
  assert.equal(state.publicState.players[actor].publicPoints, 3); assert.deepEqual(state.privateState[actor].resources, emptyResources());
  rejects(state, 'BUILD_CITY', { vertexId: vertex }, 'ILLEGAL_PLACEMENT');
});

test('harbours use the best owned rate, require a building, and exchange stock atomically', () => {
  const state = asAction(clearHands(setup())), actor = state.publicState.activePlayerId;
  const p = structuredClone(state.publicState); p.buildings = {}; assert.equal(bankRate(p, actor, 'ore'), 4);
  for (const port of Object.values(p.board.ports)) p.buildings[port.vertexIds[0]] = { ownerPlayerId: actor, type: 'CITY' };
  for (const type of Object.keys(emptyResources())) assert.equal(bankRate(p, actor, type), 2);
  p.buildings = {}; const generic = Object.values(p.board.ports).find(p => p.resourceType === null); p.buildings[generic.vertexIds[1]] = { ownerPlayerId: actor, type: 'SETTLEMENT' }; assert.equal(bankRate(p, actor, 'ore'), 3);
  const rate = bankRate(state.publicState, actor, 'brick'); resources(state, { [actor]: { brick: rate * 2 } });
  const bank = act(state, 'BANK_TRADE', { giveType: 'brick', receiveType: 'ore', receiveCount: 2 });
  const traded = projectEffects(bank.effects, state.serverState.turnOrder[1]).activity.find(e => e.type === 'BANK_TRADE');
  assert.deepEqual(traded.receive, bundle({ ore: 2 }));
  assert.equal(traded.give.brick > 0, true);
  const next = bank.state;
  assert.equal(next.privateState[actor].resources.ore, 2); assert.equal(next.privateState[actor].resources.brick, 0);
  resources(state, { [state.serverState.turnOrder[1]]: { ore: 19 } });
  rejects(state, 'BANK_TRADE', { giveType: 'brick', receiveType: 'ore', receiveCount: 1 }, 'BANK_UNAVAILABLE');
});

test('trade offers are nonbinding, active-player constrained, revision checked and atomically accepted', () => {
  let state = asAction(clearHands(setup())); const [a, b, c] = state.serverState.turnOrder;
  resources(state, { [a]: { brick: 2 }, [b]: { ore: 1 }, [c]: { wool: 1 } });
  const payload = { targetPlayerId: null, give: bundle({ brick: 1 }), receive: bundle({ ore: 1 }) };
  rejects(state, 'PROPOSE_TRADE', { ...payload, give: emptyResources() }, 'INVALID_PAYLOAD');
  rejects(state, 'PROPOSE_TRADE', { targetPlayerId: c, give: bundle({ ore: 1 }), receive: bundle({ wool: 1 }) }, 'NOT_YOUR_TURN', b);
  const proposal = act(state, 'PROPOSE_TRADE', payload);
  state = proposal.state; let offer = Object.values(state.publicState.trades)[0];
  assert.equal(state.privateState[a].resources.brick, 2);
  // Terms are public and always stated from the acting player's own side.
  const proposed = projectEffects(proposal.effects, c).activity.find(e => e.type === 'TRADE_PROPOSED');
  assert.equal(proposed.actorPlayerId, a);
  assert.equal(proposed.subjectPlayerId, null);
  assert.deepEqual(proposed.give, bundle({ brick: 1 }));
  assert.deepEqual(proposed.receive, bundle({ ore: 1 }));
  const refusal = act(state, 'DECLINE_TRADE', { offerId: offer.offerId, offerRevision: 0 }, c);
  const declined = projectEffects(refusal.effects, b).activity.find(e => e.type === 'TRADE_DECLINED');
  assert.equal(declined.actorPlayerId, c);
  assert.equal(declined.subjectPlayerId, a);
  state = refusal.state;
  rejects(state, 'ACCEPT_TRADE', { offerId: offer.offerId, offerRevision: 0 }, 'TRADE_UNAVAILABLE', b);
  const acceptance = act(state, 'ACCEPT_TRADE', { offerId: offer.offerId, offerRevision: 1 }, b);
  const accepted = projectEffects(acceptance.effects, c).activity.find(e => e.type === 'TRADE_ACCEPTED');
  assert.equal(accepted.actorPlayerId, b);
  assert.equal(accepted.subjectPlayerId, a);
  assert.deepEqual(accepted.give, bundle({ ore: 1 }));
  assert.deepEqual(accepted.receive, bundle({ brick: 1 }));
  state = acceptance.state;
  assert.equal(state.privateState[a].resources.ore, 1); assert.equal(state.privateState[b].resources.brick, 1);
  rejects(state, 'ACCEPT_TRADE', { offerId: offer.offerId, offerRevision: 1 }, 'TRADE_UNAVAILABLE', b);
  state = act(state, 'PROPOSE_TRADE', payload).state; offer = Object.values(state.publicState.trades)[0];
  rejects(state, 'CANCEL_TRADE', { offerId: offer.offerId, offerRevision: 0 }, 'FORBIDDEN', b);
  state = act(state, 'CANCEL_TRADE', { offerId: offer.offerId, offerRevision: 0 }).state;
  assert.equal(state.publicState.trades[offer.offerId].status, 'CANCELLED');
});

for (const phase of ['AWAIT_ROLL', 'ACTION']) test(`all development effects retain ${phase} continuation and enforce one play per turn`, () => {
  for (const type of ['KNIGHT', 'ROAD_BUILDING', 'MONOPOLY', 'YEAR_OF_PLENTY']) {
    let state = clearHands(setup()); if (phase === 'ACTION') asAction(state);
    const actor = state.publicState.activePlayerId, other = state.serverState.turnOrder[1];
    resources(state, { [actor]: { brick: 8 }, [other]: { ore: 4 } });
    const cardId = giveCard(state, actor, type), second = giveCard(state, actor, 'KNIGHT');
    const choice = type === 'MONOPOLY' ? { resourceType: 'ore' } : type === 'YEAR_OF_PLENTY' ? { resources: bundle({ grain: 2 }) } : {};
    state = act(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice }).state;
    if (type === 'KNIGHT') { assert.equal(state.publicState.phase, 'ROBBER_MOVE'); assert.equal(state.privateState[actor].discardRequired, 0); const hexId = Object.keys(state.publicState.board.hexes).find(h => h !== state.publicState.robberHexId && !state.publicState.board.hexes[h].vertexIds.some(v => state.publicState.buildings[v]?.ownerPlayerId === other)); state = act(state, 'MOVE_ROBBER', { hexId }).state; }
    if (type === 'ROAD_BUILDING') { rejects(state, 'FINISH_FREE_ROADS', {}, 'CARD_NOT_PLAYABLE'); for (let i = 0; i < 2; i++) state = act(state, 'PLACE_FREE_ROAD', { edgeId: legalRoads(state.publicState, actor)[0] }).state; assert.equal(state.privateState[actor].resources.brick, 8); }
    if (type === 'MONOPOLY') { assert.equal(state.privateState[actor].resources.ore, 4); assert.equal(state.privateState[other].resources.ore, 0); }
    if (type === 'YEAR_OF_PLENTY') assert.equal(state.privateState[actor].resources.grain, 2);
    assert.equal(state.publicState.phase, phase); rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId: second, choice: {} }, 'CARD_NOT_PLAYABLE');
  }
});

test('development purchase and private draw, same-turn/VP restrictions, invalid Plenty choice rollback', () => {
  let state = asAction(clearHands(setup())), actor = state.publicState.activePlayerId, other = state.serverState.turnOrder[1];
  resources(state, { [actor]: { wool: 1, grain: 1, ore: 1 } });
  const result = act(state, 'BUY_DEVELOPMENT_CARD'); state = result.state;
  assert.equal(projectEffects(result.effects, actor).drawnCards.length, 1); assert.equal(projectEffects(result.effects, other).drawnCards.length, 0);
  rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId: state.privateState[actor].developmentCards[0].id, choice: {} }, 'CARD_NOT_PLAYABLE');
  const vp = giveCard(state, actor, 'VICTORY_POINT'); rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId: vp, choice: {} }, 'CARD_NOT_PLAYABLE');
  const plenty = giveCard(state, actor, 'YEAR_OF_PLENTY'); resources(state, { [other]: { lumber: 19 } });
  rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId: plenty, choice: { resources: bundle({ lumber: 2 }) } }, 'BANK_UNAVAILABLE');
  rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId: plenty, choice: { resources: bundle({ grain: 1 }) } }, 'INVALID_PAYLOAD');
});

test('Road Building one/zero piece limits and timeout waiver preserve committed roads', () => {
  for (const supply of [0, 1, 2]) {
    let state = setup(), actor = state.publicState.activePlayerId;
    while (state.publicState.players[actor].remainingPieces.roads > supply) { const edge = legalRoads(state.publicState, actor)[0]; assert.ok(edge); state.publicState.roads[edge] = { ownerPlayerId: actor }; state.publicState.players[actor].remainingPieces.roads--; }
    refreshDerived(state); const cardId = giveCard(state, actor, 'ROAD_BUILDING');
    if (!supply) { rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: {} }, 'CARD_NOT_PLAYABLE'); continue; }
    state = act(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: {} }).state;
    state = act(state, 'PLACE_FREE_ROAD', { edgeId: legalRoads(state.publicState, actor)[0] }).state;
    if (supply === 2 && state.publicState.phase === 'ROAD_BUILDING') { state.clockState.turnExpired = true; state = act(state, 'FINISH_FREE_ROADS').state; }
    assert.equal(state.publicState.phase, 'AWAIT_ROLL'); assert.equal(state.publicState.players[actor].remainingPieces.roads, supply - 1);
  }
});

test('recursive public allowlist, owner-only snapshot and schema compatibility with real boards', () => {
  const state = setup(), actor = state.publicState.activePlayerId, other = state.serverState.turnOrder[1];
  const hiddenId = giveCard(state, other, 'VICTORY_POINT');
  state.publicState.secret = 'SENTINEL'; state.publicState.board.secret = 'SENTINEL'; Object.values(state.publicState.players)[0].secret = 'SENTINEL'; Object.values(state.publicState.board.hexes)[0].secret = 'SENTINEL';
  const snapshot = projectGame(state, actor, now), validate = validator('gameSnapshot');
  assert.ok(validate(snapshot), JSON.stringify(validate.errors)); assert.ok(!JSON.stringify(snapshot).includes('SENTINEL')); assert.ok(!JSON.stringify(snapshot).includes(hiddenId));
  assert.throws(() => projectGame(state, uuid(998), now));
  snapshot.privateState.resources.ore = 19; assert.notEqual(state.privateState[actor].resources.ore, 19);
  assert.equal(projectPublic(state).players[other].publicPoints, 2); assert.equal(state.privateState[other].totalPoints, 3);
});

function upgradeFixture(state, id) {
  for (const b of Object.values(state.publicState.buildings)) if (b.ownerPlayerId === id) { b.type = 'CITY'; state.publicState.players[id].remainingPieces.settlements++; state.publicState.players[id].remainingPieces.cities--; }
  refreshDerived(state);
}
function armyFixture(state, id, count) {
  for (let n = 0; n < count; n++) { const cardId = giveCard(state, id, 'KNIGHT'); const hand = state.privateState[id].developmentCards; const index = hand.findIndex(c => c.id === cardId); const [card] = hand.splice(index, 1); state.serverState.playedCards.push({ ...card, ownerPlayerId: id }); refreshDerived(state); }
}
test('a newly purchased hidden VP wins immediately and reveals only the winner card IDs', () => {
  let state = asAction(clearHands(setup())), actor = state.publicState.activePlayerId;
  upgradeFixture(state, actor); armyFixture(state, actor, 3);
  for (let i = 0; i < 3; i++) giveCard(state, actor, 'VICTORY_POINT');
  assert.equal(state.privateState[actor].totalPoints, 9); assert.equal(state.publicState.players[actor].publicPoints, 6);
  const deck = state.serverState.developmentDeck, index = deck.findIndex(c => c.type === 'VICTORY_POINT'); deck.unshift(...deck.splice(index, 1));
  resources(state, { [actor]: { wool: 1, ore: 1, grain: 1 } });
  state = act(state, 'BUY_DEVELOPMENT_CARD').state;
  assert.equal(state.publicState.phase, 'COMPLETE'); assert.equal(state.publicState.winnerVictoryPointCardIds.length, 4);
  assert.equal(state.privateState[actor].developmentCards.at(-1).purchasedOnTurn, state.publicState.turnNumber);
  assert.equal(state.publicState.finalPoints[actor], 10); rejects(state, 'END_TURN', {}, 'GAME_FINISHED');
});
test('third Knight wins before its pending robber decision; off-turn score waits for own turn', () => {
  let state = clearHands(setup()), actor = state.publicState.activePlayerId;
  upgradeFixture(state, actor); armyFixture(state, actor, 2);
  for (let i = 0; i < 4; i++) giveCard(state, actor, 'VICTORY_POINT');
  const cardId = giveCard(state, actor, 'KNIGHT'); state = act(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: {} }).state;
  assert.equal(state.publicState.phase, 'COMPLETE'); assert.equal(state.serverState.effect, null); assert.equal(state.publicState.largestArmy.holderPlayerId, actor);
  state = clearHands(setup()); const next = state.serverState.turnOrder[1];
  upgradeFixture(state, next); armyFixture(state, next, 3); for (let i = 0; i < 4; i++) giveCard(state, next, 'VICTORY_POINT');
  state = roll(state, 1, 1).state; assert.equal(state.publicState.winnerPlayerId, null);
  state = act(state, 'END_TURN').state; assert.equal(state.publicState.winnerPlayerId, next); assert.equal(state.publicState.phase, 'COMPLETE');
});
test('settlement distance, road access, road blockage and all finite building supplies', () => {
  let state = asAction(clearHands(setup())), actor = state.publicState.activePlayerId;
  const disconnected = Object.keys(state.publicState.board.vertices).find(v => canSettle(state.publicState, actor, v, true) && !canSettle(state.publicState, actor, v));
  rejects(state, 'BUILD_SETTLEMENT', { vertexId: disconnected }, 'ILLEGAL_PLACEMENT');
  // Extend legal roads until a new legal settlement is reachable.
  let vertex;
  for (let i = 0; i < 10 && !vertex; i++) {
    resources(state, { [actor]: { brick: 1, lumber: 1 } }); state = act(state, 'BUILD_ROAD', { edgeId: legalRoads(state.publicState, actor)[0] }).state;
    vertex = Object.keys(state.publicState.board.vertices).find(v => canSettle(state.publicState, actor, v));
  }
  assert.ok(vertex); resources(state, { [actor]: { brick: 1, lumber: 1, wool: 1, grain: 1 } });
  state = act(state, 'BUILD_SETTLEMENT', { vertexId: vertex }).state; assert.equal(state.publicState.buildings[vertex].ownerPlayerId, actor);
  for (const edge of state.publicState.board.vertices[vertex].edgeIds) for (const neighbour of state.publicState.board.edges[edge].vertexIds) assert.equal(canSettle(state.publicState, actor, neighbour, true), false);
  const p = structuredClone(state.publicState); p.roads = {}; p.buildings = {};
  const pivot = Object.keys(p.board.vertices).find(v => p.board.vertices[v].edgeIds.length === 3), [first, second] = p.board.vertices[pivot].edgeIds;
  p.roads[first] = { ownerPlayerId: actor }; assert.equal(canRoad(p, actor, second), true);
  p.buildings[pivot] = { ownerPlayerId: state.serverState.turnOrder[1], type: 'SETTLEMENT' }; assert.equal(canRoad(p, actor, second), false);
  p.buildings[pivot].ownerPlayerId = actor; assert.equal(canRoad(p, actor, second), true);
  p.players[actor].remainingPieces.roads = 0; assert.equal(canRoad(p, actor, second), false);
  p.buildings = {}; p.players[actor].remainingPieces.settlements = 0; assert.equal(canSettle(p, actor, pivot, true), false);
});
test('spending offered stock expires proposals; turn end expires all offers; unfunded accept is atomic', () => {
  let state = asAction(clearHands(setup())), [a, b] = state.serverState.turnOrder;
  resources(state, { [a]: { brick: 1, lumber: 1 } });
  const payload = { targetPlayerId: b, give: bundle({ brick: 1 }), receive: bundle({ ore: 1 }) };
  state = act(state, 'PROPOSE_TRADE', payload).state; const offer = Object.values(state.publicState.trades)[0];
  rejects(state, 'ACCEPT_TRADE', { offerId: offer.offerId, offerRevision: 0 }, 'TRADE_UNAVAILABLE', b);
  state = act(state, 'BUILD_ROAD', { edgeId: legalRoads(state.publicState, a)[0] }).state; assert.equal(state.publicState.trades[offer.offerId].status, 'EXPIRED');
  resources(state, { [a]: { brick: 1 } }); state = act(state, 'PROPOSE_TRADE', payload).state;
  state = act(state, 'END_TURN').state; assert.deepEqual(state.publicState.trades, {});
});
test('empty deck cannot charge resources, and empty Monopoly remains a valid card play', () => {
  const state = asAction(clearHands(setup())), actor = state.publicState.activePlayerId, other = state.serverState.turnOrder[1];
  const cardId = giveCard(state, actor, 'MONOPOLY');
  state.privateState[other].developmentCards.push(...state.serverState.developmentDeck.splice(0)); refreshDerived(state);
  resources(state, { [actor]: { ore: 1, grain: 1, wool: 1 } }); rejects(state, 'BUY_DEVELOPMENT_CARD', {}, 'CARD_NOT_PLAYABLE');
  assert.equal(act(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: { resourceType: 'brick' } }).state.publicState.developmentCardPlayedThisTurn, true);
});

test('multiple robber victims are distinct despite repeated buildings; empty hands excluded; desert is legal', () => {
  let state = clearHands(setup()), [a, b, c, d] = state.serverState.turnOrder;
  state.publicState.buildings = {}; state.publicState.roads = {};
  for (const p of Object.values(state.publicState.players)) p.remainingPieces = { roads: 15, settlements: 5, cities: 4 };
  const [hexId, hex] = Object.entries(state.publicState.board.hexes).find(([id]) => id !== state.publicState.robberHexId);
  for (const [i, id] of [[0, b], [2, b], [4, c]]) { state.publicState.buildings[hex.vertexIds[i]] = { ownerPlayerId: id, type: 'SETTLEMENT' }; state.publicState.players[id].remainingPieces.settlements--; }
  refreshDerived(state); resources(state, { [b]: { brick: 1 }, [c]: { ore: 1 } });
  const rolled = roll(state, 3, 4).state; state = act(rolled, 'MOVE_ROBBER', { hexId }).state;
  assert.deepEqual(new Set(state.serverState.effect.eligiblePlayerIds), new Set([b, c])); assert.equal(state.serverState.effect.eligiblePlayerIds.length, 2);
  rejects(state, 'CHOOSE_ROBBER_VICTIM', { victimPlayerId: d }, 'FORBIDDEN');
  const empty = structuredClone(rolled); resources(empty, { [b]: {}, [c]: {} }); assert.equal(act(empty, 'MOVE_ROBBER', { hexId }).state.publicState.phase, 'ACTION');
  const desert = Object.keys(rolled.publicState.board.hexes).find(h => rolled.publicState.board.hexes[h].terrain === 'DESERT'); rolled.publicState.robberHexId = hexId;
  assert.equal(act(rolled, 'MOVE_ROBBER', { hexId: desert }).state.publicState.phase, 'ACTION');
});
test('Road Building cannot start without a location and ends automatically when its last legal location is filled', () => {
  for (const locations of [0, 1]) {
    let state = setup(), actor = state.publicState.activePlayerId; const other = state.serverState.turnOrder[1];
    const legal = legalRoads(state.publicState, actor), allowed = legal[0];
    // Occupy all other edges touching the actor's network, conserving opponent supply.
    for (const edge of legal) if (locations === 0 || edge !== allowed) { state.publicState.roads[edge] = { ownerPlayerId: other }; state.publicState.players[other].remainingPieces.roads--; }
    if (locations) {
      for (const vertex of state.publicState.board.edges[allowed].vertexIds) for (const edge of state.publicState.board.vertices[vertex].edgeIds) if (edge !== allowed && !state.publicState.roads[edge]) { state.publicState.roads[edge] = { ownerPlayerId: other }; state.publicState.players[other].remainingPieces.roads--; }
    }
    refreshDerived(state); const cardId = giveCard(state, actor, 'ROAD_BUILDING');
    if (!locations) rejects(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: {} }, 'CARD_NOT_PLAYABLE');
    else { state = act(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: {} }).state; state = act(state, 'PLACE_FREE_ROAD', { edgeId: allowed }).state; assert.equal(state.publicState.phase, 'AWAIT_ROLL'); }
  }
});
test('Largest Army derives only played knights, retains a tie and transfers at a greater count', () => {
  const state = setup(), [a, b] = state.serverState.turnOrder;
  for (let i = 0; i < 3; i++) giveCard(state, a, 'KNIGHT'); assert.equal(state.publicState.largestArmy.holderPlayerId, null);
  armyFixture(state, a, 3); assert.equal(state.publicState.largestArmy.holderPlayerId, a);
  armyFixture(state, b, 3); assert.equal(state.publicState.largestArmy.holderPlayerId, a);
  armyFixture(state, b, 1); assert.equal(state.publicState.largestArmy.holderPlayerId, b); assert.equal(state.publicState.largestArmy.size, 4);
  assertInvariants(state);
});
