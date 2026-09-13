import { createGame, applyCommand, canSettle, canRoad, refreshDerived, assertInvariants, emptyResources } from '../dist/index.js';
export const uuid = n => `00000000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
export const now = '2026-09-10T12:00:00.000Z';
export function seeded(seed = 1) {
  let x = seed >>> 0, ids = seed * 10000;
  return { int(max) { x ^= x << 13; x ^= x >>> 17; x ^= x << 5; return (x >>> 0) % max; }, id() { return uuid(++ids); } };
}
export function newGame(count = 4, seed = 42) {
  const random = seeded(seed);
  const input = { roomId: uuid(1), players: Array.from({ length: count }, (_, i) => ({ id: uuid(i + 10), nickname: `Player ${i}`, seatIndex: i, colour: ['RED', 'BLUE', 'WHITE', 'ORANGE'][i] })) };
  const initial = createGame(input, { now, random });
  return { input, initial, state: initial.state, random };
}
let nextCommand = 900000000;
export function command(state, type, payload = {}) { return { protocolVersion: 1, commandId: uuid(++nextCommand), roomId: state.roomId, expectedVersion: state.version, expectedPhaseId: state.publicState.phaseId, type, payload }; }
export function act(state, type, payload = {}, actor = state.publicState.activePlayerId, random = seeded(nextCommand)) { return applyCommand(state, actor, command(state, type, payload), { now, random }); }
export function roll(state, a, b) { let i = 0; const random = seeded(nextCommand); return act(state, 'ROLL_DICE', {}, state.publicState.activePlayerId, { id: () => random.id(), int(max) { if (max !== 6) throw new Error('Unexpected die request'); return [a - 1, b - 1][i++]; } }); }
export function setup(count = 4, seed = 42) {
  let { state } = newGame(count, seed);
  while (state.serverState.setup) {
    const p = state.publicState, actor = p.activePlayerId;
    if (p.phase === 'SETUP_SETTLEMENT') {
      const vertex = Object.keys(p.board.vertices).find(v => canSettle(p, actor, v, true));
      state = act(state, 'PLACE_SETUP_SETTLEMENT', { vertexId: vertex }).state;
    } else {
      const edge = p.board.vertices[state.serverState.setup.pendingVertexId].edgeIds.find(e => canRoad(p, actor, e));
      state = act(state, 'PLACE_SETUP_ROAD', { edgeId: edge }).state;
    }
  }
  return state;
}
/** Hand-authored scenario setup moves cards from/to the real finite inventory. */
export function resources(state, allocations) {
  for (const [id, values] of Object.entries(allocations)) {
    const hand = state.privateState[id].resources;
    for (const type of Object.keys(hand)) { state.serverState.bank[type] += hand[type]; hand[type] = 0; }
    for (const [type, count] of Object.entries(values)) { hand[type] = count; state.serverState.bank[type] -= count; }
  }
  refreshDerived(state); assertInvariants(state); return state;
}
export function giveCard(state, playerId, type, purchasedOnTurn = 0) {
  const index = state.serverState.developmentDeck.findIndex(c => c.type === type);
  if (index < 0) throw new Error('Fixture exhausted card type');
  const [card] = state.serverState.developmentDeck.splice(index, 1); card.purchasedOnTurn = purchasedOnTurn;
  state.privateState[playerId].developmentCards.push(card); refreshDerived(state); assertInvariants(state); return card.id;
}
export function asAction(state) { state.publicState.phase = 'ACTION'; state.publicState.hasRolled = true; state.publicState.dice = [1, 1]; return state; }
export function clearHands(state) { return resources(state, Object.fromEntries(Object.keys(state.privateState).map(id => [id, emptyResources()]))); }
