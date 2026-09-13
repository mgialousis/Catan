import type { PublicState, Board, HexId, VertexId, EdgeId } from '@island/protocol/contracts';
import { projectPlayer, type CanonicalState } from './index.js';
import type { EngineEffect } from './engine.js';

/** Recursive field allowlist. Never serialize a canonical object or spread its children. */
export function projectPublic(state: CanonicalState): PublicState {
  const p = state.publicState;
  const board: Board = {
    topologyVersion: p.board.topologyVersion,
    hexes: Object.fromEntries(Object.entries(p.board.hexes).map(([id, h]) => [id as HexId, { q: h.q, r: h.r, terrain: h.terrain, number: h.number, vertexIds: [...h.vertexIds] }])),
    vertices: Object.fromEntries(Object.entries(p.board.vertices).map(([id, v]) => [id as VertexId, { x: v.x, y: v.y, hexIds: [...v.hexIds], edgeIds: [...v.edgeIds] }])),
    edges: Object.fromEntries(Object.entries(p.board.edges).map(([id, e]) => [id as EdgeId, { vertexIds: [e.vertexIds[0], e.vertexIds[1]], hexIds: [...e.hexIds] }])),
    ports: Object.fromEntries(Object.entries(p.board.ports).map(([id, port]) => [id, { vertexIds: [port.vertexIds[0], port.vertexIds[1]], resourceType: port.resourceType, ratio: port.ratio }])),
  };
  return {
    board,
    roads: Object.fromEntries(Object.entries(p.roads).map(([id, r]) => [id, { ownerPlayerId: r.ownerPlayerId }])),
    buildings: Object.fromEntries(Object.entries(p.buildings).map(([id, b]) => [id, { ownerPlayerId: b.ownerPlayerId, type: b.type }])),
    robberHexId: p.robberHexId,
    players: Object.fromEntries(Object.entries(p.players).map(([id, v]) => [id, { id: v.id, nickname: v.nickname, seatIndex: v.seatIndex, colour: v.colour, resourceCardCount: v.resourceCardCount, developmentCardCount: v.developmentCardCount, playedKnights: v.playedKnights, remainingPieces: { roads: v.remainingPieces.roads, settlements: v.remainingPieces.settlements, cities: v.remainingPieces.cities }, publicPoints: v.publicPoints }])),
    phase: p.phase, phaseId: p.phaseId, turnNumber: p.turnNumber, activePlayerId: p.activePlayerId, requiredPlayerIds: [...p.requiredPlayerIds], hasRolled: p.hasRolled, developmentCardPlayedThisTurn: p.developmentCardPlayedThisTurn,
    dice: p.dice ? [p.dice[0], p.dice[1]] : null,
    trades: Object.fromEntries(Object.entries(p.trades).map(([id, t]) => [id, { offerId: t.offerId, proposerPlayerId: t.proposerPlayerId, targetPlayerId: t.targetPlayerId, give: { brick: t.give.brick, lumber: t.give.lumber, wool: t.give.wool, grain: t.give.grain, ore: t.give.ore }, receive: { brick: t.receive.brick, lumber: t.receive.lumber, wool: t.receive.wool, grain: t.receive.grain, ore: t.receive.ore }, revision: t.revision, turnNumber: t.turnNumber, phaseId: t.phaseId, status: t.status, declinedBy: [...t.declinedBy] }])),
    longestRoad: { holderPlayerId: p.longestRoad.holderPlayerId, size: p.longestRoad.size }, largestArmy: { holderPlayerId: p.largestArmy.holderPlayerId, size: p.largestArmy.size },
    pauseReasons: [...p.pauseReasons], turnDeadline: p.turnDeadline, discardDeadlines: Object.fromEntries(Object.entries(p.discardDeadlines)),
    winnerPlayerId: p.winnerPlayerId, winnerVictoryPointCardIds: [...p.winnerVictoryPointCardIds], finalPoints: Object.fromEntries(Object.entries(p.finalPoints)),
  };
}
export function projectGame(state: CanonicalState, playerId: string, serverTime: string) {
  const privateState = projectPlayer(state, playerId);
  return { roomId: state.roomId, version: state.version, rulesVersion: state.rulesVersion, stateSchemaVersion: state.stateSchemaVersion, publicState: projectPublic(state), privateState, serverTime };
}
export function projectEffects(effects: readonly EngineEffect[], viewerPlayerId: string) {
  const activity = effects.filter((e): e is Extract<EngineEffect, { type: 'PUBLIC_ACTIVITY' }> => e.type === 'PUBLIC_ACTIVITY').map(e => ({ type: e.action, actorPlayerId: e.actorPlayerId, message: e.message }));
  const resourceTransfers = effects.filter((e): e is Extract<EngineEffect, { type: 'RESOURCE_TRANSFER' }> => e.type === 'RESOURCE_TRANSFER' && (e.visibleTo === 'PUBLIC' || e.visibleTo.includes(viewerPlayerId))).map(e => ({ fromPlayerId: e.fromPlayerId, toPlayerId: e.toPlayerId, reason: e.reason, resources: { brick: e.resources.brick, lumber: e.resources.lumber, wool: e.resources.wool, grain: e.resources.grain, ore: e.resources.ore } }));
  const drawnCards = effects.filter((e): e is Extract<EngineEffect, { type: 'DEVELOPMENT_DRAW' }> => e.type === 'DEVELOPMENT_DRAW' && e.playerId === viewerPlayerId).map(e => ({ id: e.card.id, type: e.card.type, purchasedOnTurn: e.card.purchasedOnTurn }));
  return { activity, resourceTransfers, drawnCards };
}
