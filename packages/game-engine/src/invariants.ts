import { RESOURCE_TYPES, type Board, type VertexId, type EdgeId, type HexId } from '@island/protocol/contracts';
import type { CanonicalState } from './index.js';
import { TERRAINS, TOKENS, validRedNumbers } from './board.js';
import { adjacentVertices, refreshDerived, total, type WorkingState } from './rules.js';

const invariant = (condition: unknown, name: string): void => { if (!condition) throw new Error(`Game invariant: ${name}`); };
const integers = (n: number): boolean => Number.isInteger(n) && n >= 0;
const canonical = (value: unknown): string => Array.isArray(value) ? `[${value.map(canonical).join(',')}]` : value !== null && typeof value === 'object' ? `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, v]) => `${JSON.stringify(key)}:${canonical(v)}`).join(',')}}` : JSON.stringify(value);
const same = (a: unknown, b: unknown) => canonical(a) === canonical(b);
export function assertBoard(board: Board): void {
  invariant(Object.keys(board.hexes).length === 19 && Object.keys(board.vertices).length === 54 && Object.keys(board.edges).length === 72 && Object.keys(board.ports).length === 9, 'board inventory');
  invariant(same(Object.values(board.hexes).map(h => h.terrain).sort(), [...TERRAINS].sort()), 'terrain multiset');
  invariant(same(Object.values(board.hexes).flatMap(h => h.number === null ? [] : [h.number]).sort((a, b) => a - b), [...TOKENS]), 'token multiset');
  invariant(validRedNumbers(board), 'red number adjacency');
  const edgePairs = new Set<string>(), coordinates = new Set<string>();
  for (const [id, hex] of Object.entries(board.hexes)) {
    invariant((hex.terrain === 'DESERT') === (hex.number === null), 'desert token');
    invariant(new Set(hex.vertexIds).size === 6, 'six hex corners');
    for (const v of hex.vertexIds) invariant(board.vertices[v]?.hexIds.includes(id as HexId), 'hex/vertex adjacency');
  }
  for (const [id, vertex] of Object.entries(board.vertices)) {
    const coordinate = `${vertex.x},${vertex.y}`; invariant(!coordinates.has(coordinate), 'unique vertex coordinates'); coordinates.add(coordinate);
    invariant(Number.isInteger(vertex.x) && Number.isInteger(vertex.y), 'integer coordinates');
    for (const edge of vertex.edgeIds) invariant(board.edges[edge]?.vertexIds.includes(id as VertexId), 'vertex/edge adjacency');
    for (const hex of vertex.hexIds) invariant(board.hexes[hex]?.vertexIds.includes(id as VertexId), 'vertex/hex adjacency');
  }
  for (const [id, edge] of Object.entries(board.edges)) {
    const pair = [...edge.vertexIds].sort().join(':'); invariant(!edgePairs.has(pair) && new Set(edge.vertexIds).size === 2, 'unique edges'); edgePairs.add(pair);
    invariant(edge.hexIds.length >= 1 && edge.hexIds.length <= 2, 'edge hex count');
    for (const v of edge.vertexIds) invariant(board.vertices[v]?.edgeIds.includes(id as EdgeId), 'edge/vertex adjacency');
    for (const hex of edge.hexIds) invariant(edge.vertexIds.every(v => board.hexes[hex]?.vertexIds.includes(v)), 'edge/hex adjacency');
  }
  const portVertices = new Set<string>(), resources = Object.values(board.ports).map(p => p.resourceType);
  invariant(resources.filter(r => r === null).length === 4 && RESOURCE_TYPES.every(r => resources.filter(x => x === r).length === 1), 'port inventory');
  for (const port of Object.values(board.ports)) {
    invariant(port.ratio === (port.resourceType === null ? 3 : 2), 'port ratio');
    invariant(Object.values(board.edges).some(e => e.hexIds.length === 1 && port.vertexIds.every(v => e.vertexIds.includes(v))), 'coastal port');
    for (const v of port.vertexIds) { invariant(!portVertices.has(v), 'nonoverlapping ports'); portVertices.add(v); }
  }
}
export function assertInvariants(state: CanonicalState): void {
  const p = state.publicState, ids = Object.keys(p.players);
  invariant(ids.length >= 3 && ids.length <= 4 && ids.length === Object.keys(state.privateState).length, 'player count');
  invariant(ids.includes(p.activePlayerId), 'active player');
  invariant(new Set(state.serverState.turnOrder).size === ids.length && state.serverState.turnOrder.every(id => ids.includes(id)), 'turn order');
  invariant(integers(state.version) && integers(p.turnNumber), 'versions');
  const setup = state.serverState.setup, effect = state.serverState.effect;
  if (p.phase === 'SETUP_SETTLEMENT' || p.phase === 'SETUP_ROAD') {
    invariant(setup && p.turnNumber === 0 && setup.snakeOrder[setup.position] === p.activePlayerId, 'setup actor');
    invariant(setup && same(setup.snakeOrder, [...state.serverState.turnOrder, ...state.serverState.turnOrder.toReversed()]), 'setup snake');
    invariant(setup && new Set(setup.grantedTo).size === setup.grantedTo.length && setup.grantedTo.every(id => ids.includes(id)), 'initial grants');
    invariant(setup && (p.phase === 'SETUP_ROAD' ? p.buildings[setup.pendingVertexId as VertexId]?.ownerPlayerId === p.activePlayerId : setup.pendingVertexId === null), 'pending setup placement');
  } else invariant(setup === null && p.turnNumber > 0, 'setup completed');
  if (p.phase === 'ROBBER_MOVE' || p.phase === 'ROBBER_VICTIM') invariant(effect?.kind === 'ROBBER', 'robber effect');
  else if (p.phase === 'DISCARD_REQUIRED') invariant(effect?.kind === 'DISCARD' && p.requiredPlayerIds.length > 0, 'discard effect');
  else if (p.phase === 'ROAD_BUILDING') invariant(effect?.kind === 'ROAD_BUILDING' && effect.remainingRoads >= 1 && effect.remainingRoads <= 2, 'road continuation');
  else invariant(effect === null, 'no lingering effect');
  if (effect) invariant(['ACTION', 'AWAIT_ROLL'].includes(effect.continuation) && new Set(effect.eligiblePlayerIds).size === effect.eligiblePlayerIds.length && effect.eligiblePlayerIds.every(id => ids.includes(id)), 'effect continuation/actors');
  if (p.phase === 'AWAIT_ROLL') invariant(!p.hasRolled && p.dice === null, 'before roll');
  if (p.phase === 'ACTION' || p.phase === 'DISCARD_REQUIRED') invariant(p.hasRolled && p.dice !== null, 'after roll');
  for (const resource of RESOURCE_TYPES) {
    const counts = [state.serverState.bank[resource], ...ids.map(id => state.privateState[id]!.resources[resource])];
    invariant(counts.every(integers) && counts.reduce((a, b) => a + b, 0) === 19, `resource conservation ${resource}`);
  }
  for (const [edge, road] of Object.entries(p.roads)) invariant(p.board.edges[edge as EdgeId] && ids.includes(road.ownerPlayerId), 'road owner/location');
  for (const [vertex, building] of Object.entries(p.buildings)) {
    invariant(p.board.vertices[vertex as VertexId] && ids.includes(building.ownerPlayerId) && ['SETTLEMENT', 'CITY'].includes(building.type), 'building owner/location');
    invariant(!adjacentVertices(p, vertex as VertexId).some(v => p.buildings[v]), 'settlement distance');
  }
  for (const id of ids) {
    const player = p.players[id]!, hand = state.privateState[id]!;
    invariant(hand.playerId === id, 'private owner');
    const buildings = Object.values(p.buildings).filter(b => b.ownerPlayerId === id);
    const piece = player.remainingPieces;
    invariant(Object.values(piece).every(integers), 'nonnegative pieces');
    invariant(piece.roads + Object.values(p.roads).filter(r => r.ownerPlayerId === id).length === 15, 'road conservation');
    invariant(piece.settlements + buildings.filter(b => b.type === 'SETTLEMENT').length === 5, 'settlement conservation');
    invariant(piece.cities + buildings.filter(b => b.type === 'CITY').length === 4, 'city conservation');
    invariant(player.resourceCardCount === total(hand.resources) && player.developmentCardCount === hand.developmentCards.length, 'public card counts');
    invariant(integers(hand.discardRequired) && hand.discardRequired <= total(hand.resources), 'discard obligations');
    invariant(hand.developmentCards.every(c => integers(c.purchasedOnTurn) && c.purchasedOnTurn <= p.turnNumber), 'card purchase turn');
  }
  const cards = [...state.serverState.developmentDeck, ...state.serverState.playedCards, ...Object.values(state.privateState).flatMap(p => p.developmentCards)];
  invariant(cards.length === 25 && new Set(cards.map(c => c.id)).size === 25, 'development conservation/identity');
  for (const [type, count] of Object.entries({ KNIGHT: 14, VICTORY_POINT: 5, ROAD_BUILDING: 2, MONOPOLY: 2, YEAR_OF_PLENTY: 2 })) invariant(cards.filter(c => c.type === type).length === count, `development multiset ${type}`);
  invariant(state.serverState.playedCards.every(c => c.type !== 'VICTORY_POINT' && ids.includes(c.ownerPlayerId)), 'played card owners');
  invariant(!!p.board.hexes[p.robberHexId], 'robber location');
  const derived = structuredClone(state) as WorkingState; refreshDerived(derived);
  invariant(same(derived.publicState.players, p.players), 'derived player points/counts');
  invariant(same(derived.publicState.longestRoad, p.longestRoad) && same(derived.publicState.largestArmy, p.largestArmy), 'derived awards');
  for (const id of ids) invariant(derived.privateState[id]!.totalPoints === state.privateState[id]!.totalPoints, 'total score');
  invariant(new Set(p.requiredPlayerIds).size === p.requiredPlayerIds.length && p.requiredPlayerIds.every(id => ids.includes(id)), 'required actors');
  if (!['DISCARD_REQUIRED', 'COMPLETE'].includes(p.phase)) invariant(same(p.requiredPlayerIds, [p.activePlayerId]), 'active obligation');
  if (p.phase === 'DISCARD_REQUIRED') invariant(same([...p.requiredPlayerIds].sort(), ids.filter(id => state.privateState[id]!.discardRequired > 0).sort()), 'discard barrier');
  else invariant(ids.every(id => state.privateState[id]!.discardRequired === 0), 'no lingering discards');
  if (p.phase === 'COMPLETE') {
    invariant(p.winnerPlayerId === p.activePlayerId && state.privateState[p.activePlayerId]!.totalPoints >= 10, 'own-turn winner');
    invariant(state.serverState.effect === null && p.requiredPlayerIds.length === 0 && state.clockState.deadline === null, 'terminal obligations');
    invariant(same([...p.winnerVictoryPointCardIds].sort(), state.privateState[p.activePlayerId]!.developmentCards.filter(c => c.type === 'VICTORY_POINT').map(c => c.id).sort()), 'winner reveal');
    invariant(same(p.finalPoints, Object.fromEntries(ids.map(id => [id, state.privateState[id]!.totalPoints]))), 'final scores');
  } else invariant(p.winnerPlayerId === null && p.winnerVictoryPointCardIds.length === 0 && Object.keys(p.finalPoints).length === 0, 'hidden endgame');
  invariant(Object.values(p.trades).filter(t => t.status === 'OPEN').length <= ids.length, 'bounded offers');
}
