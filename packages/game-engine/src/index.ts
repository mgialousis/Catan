import { PHASES, RULES_VERSION, type PublicState, type Phase, type Resources } from '@island/protocol/contracts';
export { RULES_VERSION };

export interface DevelopmentCard {
  readonly id: string;
  readonly type: 'KNIGHT' | 'VICTORY_POINT' | 'ROAD_BUILDING' | 'MONOPOLY' | 'YEAR_OF_PLENTY';
  readonly purchasedOnTurn: number;
}
export interface PlayerPrivateState {
  readonly playerId: string; readonly resources: Resources;
  readonly developmentCards: readonly DevelopmentCard[];
  readonly totalPoints: number; readonly discardRequired: number;
}
export interface ClockState {
  readonly turnLimitSeconds: null | 60 | 120 | 180;
  readonly turnExpired: boolean; readonly remainingTurnMs: number | null;
  readonly deadline: string | null; readonly generation: string;
  readonly discards: Readonly<Record<string, { readonly deadline: string | null; readonly remainingMs: number; readonly generation: string }>>;
}
export interface CanonicalState {
  readonly roomId: string; readonly version: number; readonly rulesVersion: typeof RULES_VERSION;
  readonly stateSchemaVersion: 1; readonly protocolVersion: 1;
  readonly publicState: PublicState;
  readonly privateState: Readonly<Record<string, PlayerPrivateState>>;
  readonly serverState: {
    readonly bank: Resources; readonly developmentDeck: readonly DevelopmentCard[];
    readonly playedCards: readonly (DevelopmentCard & { readonly ownerPlayerId: string })[];
    readonly turnOrder: readonly string[];
    readonly setup: { readonly snakeOrder: readonly string[]; readonly position: number; readonly pendingVertexId: string | null; readonly grantedTo: readonly string[] } | null;
    readonly effect: { readonly kind: 'ROBBER' | 'ROAD_BUILDING' | 'DISCARD'; readonly continuation: 'AWAIT_ROLL' | 'ACTION'; readonly eligiblePlayerIds: readonly string[]; readonly remainingRoads: number } | null;
  };
  readonly clockState: ClockState;
}

/** Contract only: membership in this graph is NOT proof that a move is legal. */
export const PHASE_TRANSITIONS: Readonly<Record<Phase, readonly Phase[]>> = {
  SETUP_SETTLEMENT: ['SETUP_ROAD'],
  SETUP_ROAD: ['SETUP_SETTLEMENT', 'AWAIT_ROLL'],
  AWAIT_ROLL: ['ACTION', 'DISCARD_REQUIRED', 'ROBBER_MOVE', 'ROAD_BUILDING', 'COMPLETE'],
  DISCARD_REQUIRED: ['ROBBER_MOVE'],
  ROBBER_MOVE: ['ROBBER_VICTIM', 'AWAIT_ROLL', 'ACTION', 'COMPLETE'],
  ROBBER_VICTIM: ['AWAIT_ROLL', 'ACTION', 'COMPLETE'],
  ACTION: ['AWAIT_ROLL', 'ROBBER_MOVE', 'ROAD_BUILDING', 'COMPLETE'],
  ROAD_BUILDING: ['AWAIT_ROLL', 'ACTION', 'COMPLETE'],
  COMPLETE: [],
};
export const DURABLE_PHASES = PHASES;
export const TRANSIENT_STEPS = ['PRODUCTION', 'END_TURN'] as const;
export const BASE_INVENTORY = Object.freeze({ hexes: 19, vertices: 54, edges: 72, ports: 9, resourceCardsPerType: 19, developmentCards: 25, roadsPerPlayer: 15, settlementsPerPlayer: 5, citiesPerPlayer: 4 });

/** Explicit owner projection: never serialize the canonical private-state map. */
export function projectPlayer(state: CanonicalState, playerId: string): PlayerPrivateState {
  const hand = state.privateState[playerId];
  if (!hand || hand.playerId !== playerId) throw new Error('FORBIDDEN');
  return {
    playerId: hand.playerId,
    resources: { brick: hand.resources.brick, lumber: hand.resources.lumber, wool: hand.resources.wool, grain: hand.resources.grain, ore: hand.resources.ore },
    developmentCards: hand.developmentCards.map(({ id, type, purchasedOnTurn }) => ({ id, type, purchasedOnTurn })),
    totalPoints: hand.totalPoints, discardRequired: hand.discardRequired,
  };
}

export * from './random.js';
export * from './board.js';
export * from './rules.js';
export * from './invariants.js';
export * from './engine.js';
export * from './projection.js';
