import test from 'node:test';
import assert from 'node:assert/strict';
import { assertInvariants, legalRoads, longestRoad, refreshDerived, roadSearchCount } from '../dist/index.js';
import { act, asAction, clearHands, resources, setup } from './helpers.mjs';

// Longest Road is remembered by the network's own shape, so a move searches
// again only for the players whose network it touched. These count the
// searches that actually run around real engine moves.
const searchesDuring = work => { const before = roadSearchCount(); const result = work(); return { result, searched: roadSearchCount() - before }; };

function table() {
  const state = asAction(clearHands(setup()));
  const actor = state.publicState.activePlayerId;
  resources(state, { [actor]: { brick: 5, lumber: 1, ore: 3, grain: 2 } });
  assertInvariants(state); // every network is now known
  return { state, actor };
}

test('re-deriving or re-validating an unchanged table searches nothing', () => {
  const { state } = table();
  assert.equal(searchesDuring(() => refreshDerived(structuredClone(state))).searched, 0);
  assert.equal(searchesDuring(() => assertInvariants(state)).searched, 0);
});

test('a move that touches no road searches nothing, through every check it passes', () => {
  const { state } = table();
  const { result, searched } = searchesDuring(() => act(state, 'BANK_TRADE', { giveType: 'brick', receiveType: 'wool', receiveCount: 1 }));
  assert.equal(result.state.version, state.version + 1);
  assert.equal(searched, 0, 'a bank trade changes nobody\'s roads');
});

test('a road is searched again for its builder alone', () => {
  const { state, actor } = table();
  const edge = legalRoads(state.publicState, actor)[0];
  const others = Object.keys(state.publicState.players).filter(id => id !== actor);
  const before = others.map(id => longestRoad(state.publicState, id));
  const { result, searched } = searchesDuring(() => act(state, 'BUILD_ROAD', { edgeId: edge }));
  assert.equal(searched, 1, 'one new network, searched once despite every validation pass');
  assert.deepEqual(others.map(id => longestRoad(result.state.publicState, id)), before);
});

test('upgrading to a city searches nothing: your own building never cuts your road', () => {
  const { state, actor } = table();
  const vertex = Object.keys(state.publicState.buildings).find(v => state.publicState.buildings[v].ownerPlayerId === actor);
  assert.equal(searchesDuring(() => act(state, 'BUILD_CITY', { vertexId: vertex })).searched, 0);
});

// A minimal board: A owns a line through v-2, C owns a road elsewhere.
function line(withSettlementAt) {
  const board = { edges: {} }, roads = {}, buildings = {};
  [[0, 1], [1, 2], [2, 3], [3, 4], [4, 5]].forEach(([a, b], i) => { board.edges[`e-${i}`] = { vertexIds: [`v-${a}`, `v-${b}`] }; roads[`e-${i}`] = { ownerPlayerId: 'A' }; });
  board.edges['e-9'] = { vertexIds: ['v-8', 'v-9'] }; roads['e-9'] = { ownerPlayerId: 'C' };
  if (withSettlementAt !== undefined) buildings[`v-${withSettlementAt}`] = { ownerPlayerId: 'B' };
  return { board, roads, buildings };
}

test('a settlement cutting a road is searched again only for the player it cut', () => {
  const players = ['A', 'B', 'C'];
  for (const id of players) longestRoad(line(), id); // warm
  const { result, searched } = searchesDuring(() => players.map(id => longestRoad(line(2), id)));
  assert.deepEqual(result, [3, 0, 1], 'A is cut to three; B has no roads; C is unaffected');
  assert.equal(searched, 1, 'only the cut network is searched');
});

test('the same road ids on a different board never reuse a length', () => {
  // Keys hold each road's endpoints, not its id: ids are only names.
  const straight = line(), bent = line();
  bent.board.edges['e-3'] = { vertexIds: ['v-2', 'v-4'] }; // now a branch, not a line
  assert.equal(longestRoad(straight, 'A'), 5);
  assert.equal(longestRoad(bent, 'A'), 4);
});
