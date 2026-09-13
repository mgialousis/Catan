import { RESOURCE_TYPES, type Resources, type ResourceType, type PublicState, type EdgeId, type VertexId } from '@island/protocol/contracts';
import type { CanonicalState } from './index.js';

export type Mutable<T> = T extends object ? { -readonly [K in keyof T]: Mutable<T[K]> } : T;
export type WorkingState = Mutable<CanonicalState>;
export class RuleError extends Error { constructor(readonly code: string) { super(code); } }
export function requireRule(condition: unknown, code: string): asserts condition { if (!condition) throw new RuleError(code); }
export const emptyResources = (): Mutable<Resources> => ({ brick: 0, lumber: 0, wool: 0, grain: 0, ore: 0 });
export const total = (resources: Resources): number => RESOURCE_TYPES.reduce((sum, type) => sum + resources[type], 0);
export const has = (available: Resources, requested: Resources): boolean => RESOURCE_TYPES.every(type => available[type] >= requested[type]);
export function bundle(value: unknown): Resources {
  requireRule(value !== null && typeof value === 'object' && !Array.isArray(value), 'INVALID_PAYLOAD');
  const object = value as Record<string, unknown>;
  requireRule(Object.keys(object).length === 5 && RESOURCE_TYPES.every(type => Number.isInteger(object[type]) && (object[type] as number) >= 0 && (object[type] as number) <= 19), 'INVALID_PAYLOAD');
  return { brick: object.brick as number, lumber: object.lumber as number, wool: object.wool as number, grain: object.grain as number, ore: object.ore as number };
}
export const COSTS: Readonly<Record<'ROAD' | 'SETTLEMENT' | 'CITY' | 'DEVELOPMENT', Resources>> = {
  ROAD: { brick: 1, lumber: 1, wool: 0, grain: 0, ore: 0 },
  SETTLEMENT: { brick: 1, lumber: 1, wool: 1, grain: 1, ore: 0 },
  CITY: { brick: 0, lumber: 0, wool: 0, grain: 2, ore: 3 },
  DEVELOPMENT: { brick: 0, lumber: 0, wool: 1, grain: 1, ore: 1 },
};
export function transfer(from: Mutable<Resources>, to: Mutable<Resources>, resources: Resources, code = 'INSUFFICIENT_RESOURCES'): void {
  requireRule(has(from, resources), code);
  for (const type of RESOURCE_TYPES) { from[type] -= resources[type]; to[type] += resources[type]; }
}
export function adjacentVertices(state: Pick<PublicState, 'board'>, vertex: VertexId): VertexId[] {
  return state.board.vertices[vertex]?.edgeIds.flatMap(edge => state.board.edges[edge]!.vertexIds.filter(v => v !== vertex)) ?? [];
}
export function canSettle(state: PublicState, playerId: string, vertex: VertexId, setup = false): boolean {
  const point = state.board.vertices[vertex];
  return !!point && !state.buildings[vertex] && !adjacentVertices(state, vertex).some(v => state.buildings[v]) &&
    !!state.players[playerId]?.remainingPieces.settlements && (setup || point.edgeIds.some(edge => state.roads[edge]?.ownerPlayerId === playerId));
}
export function canRoad(state: PublicState, playerId: string, edgeId: EdgeId): boolean {
  const edge = state.board.edges[edgeId];
  return !!edge && !state.roads[edgeId] && !!state.players[playerId]?.remainingPieces.roads && edge.vertexIds.some(vertex => {
    const building = state.buildings[vertex];
    if (building) return building.ownerPlayerId === playerId;
    return state.board.vertices[vertex]!.edgeIds.some(edge => state.roads[edge]?.ownerPlayerId === playerId);
  });
}
export function legalRoads(state: PublicState, playerId: string): EdgeId[] { return (Object.keys(state.board.edges) as EdgeId[]).filter(edge => canRoad(state, playerId, edge)); }
export function bankRate(state: PublicState, playerId: string, resource: ResourceType): number {
  let best = 4;
  for (const port of Object.values(state.board.ports)) if (port.vertexIds.some(v => state.buildings[v]?.ownerPlayerId === playerId)) {
    if (port.resourceType === resource) best = Math.min(best, 2);
    else if (port.resourceType === null) best = Math.min(best, 3);
  }
  return best;
}

/** Exact longest edge trail. Revisiting a vertex is legal; reusing an edge is not. */
export function longestRoad(state: Pick<PublicState, 'board' | 'roads' | 'buildings'>, playerId: string): number {
  const edges = (Object.keys(state.roads) as EdgeId[]).filter(id => state.roads[id]!.ownerPlayerId === playerId);
  if (edges.length > 15) throw new Error('Road supply exceeded');
  const adjacency = new Map<VertexId, { next: VertexId; bit: number }[]>();
  edges.forEach((id, i) => {
    const [a, b] = state.board.edges[id]!.vertexIds;
    adjacency.set(a, [...adjacency.get(a) ?? [], { next: b, bit: 1 << i }]);
    adjacency.set(b, [...adjacency.get(b) ?? [], { next: a, bit: 1 << i }]);
  });
  const cache = new Map<string, number>();
  function search(vertex: VertexId, used: number): number {
    if (used && state.buildings[vertex] && state.buildings[vertex]!.ownerPlayerId !== playerId) return 0;
    const key = `${vertex}:${used}`, saved = cache.get(key); if (saved !== undefined) return saved;
    let best = 0;
    for (const edge of adjacency.get(vertex) ?? []) if (!(used & edge.bit)) best = Math.max(best, 1 + search(edge.next, used | edge.bit));
    cache.set(key, best); return best;
  }
  return Math.max(0, ...[...adjacency.keys()].map(vertex => search(vertex, 0)));
}
export function award(values: Readonly<Record<string, number>>, previous: string | null, minimum: number): { holderPlayerId: string | null; size: number } {
  const max = Math.max(0, ...Object.values(values));
  const leaders = Object.keys(values).filter(player => values[player] === max && max >= minimum);
  const holderPlayerId = previous && leaders.includes(previous) ? previous : leaders.length === 1 ? leaders[0]! : null;
  return { holderPlayerId, size: holderPlayerId ? values[holderPlayerId]! : 0 };
}
export function refreshDerived(state: WorkingState): void {
  const publicState = state.publicState;
  const lengths: Record<string, number> = {}, armies: Record<string, number> = {};
  for (const [id, player] of Object.entries(publicState.players)) {
    const privateState = state.privateState[id]!;
    player.resourceCardCount = total(privateState.resources);
    player.developmentCardCount = privateState.developmentCards.length;
    player.playedKnights = state.serverState.playedCards.filter(card => card.ownerPlayerId === id && card.type === 'KNIGHT').length;
    lengths[id] = longestRoad(publicState, id); armies[id] = player.playedKnights;
  }
  publicState.longestRoad = award(lengths, publicState.longestRoad.holderPlayerId, 5);
  publicState.largestArmy = award(armies, publicState.largestArmy.holderPlayerId, 3);
  for (const [id, player] of Object.entries(publicState.players)) {
    player.publicPoints = Object.values(publicState.buildings).filter(building => building.ownerPlayerId === id).reduce((sum, b) => sum + (b.type === 'CITY' ? 2 : 1), 0) +
      (publicState.longestRoad.holderPlayerId === id ? 2 : 0) + (publicState.largestArmy.holderPlayerId === id ? 2 : 0);
    state.privateState[id]!.totalPoints = player.publicPoints + state.privateState[id]!.developmentCards.filter(card => card.type === 'VICTORY_POINT').length;
  }
}
