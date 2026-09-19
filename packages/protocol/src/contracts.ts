export const PROTOCOL_VERSION = 1 as const;
export const STATE_SCHEMA_VERSION = 1 as const;
export const RULES_VERSION = 'base-2020-v1' as const;
export const MAX_COMMAND_BYTES = 16 * 1024;
export const MAX_SNAPSHOT_BYTES = 128 * 1024;
export const RESOURCE_TYPES = ['brick', 'lumber', 'wool', 'grain', 'ore'] as const;
export type ResourceType = typeof RESOURCE_TYPES[number];
export type Resources = Readonly<Record<ResourceType, number>>;
export const PHASES = ['SETUP_SETTLEMENT', 'SETUP_ROAD', 'AWAIT_ROLL', 'DISCARD_REQUIRED', 'ROBBER_MOVE', 'ROBBER_VICTIM', 'ACTION', 'ROAD_BUILDING', 'COMPLETE'] as const;
export type Phase = typeof PHASES[number];
export type RoomStatus = 'LOBBY' | 'ACTIVE' | 'PAUSED' | 'FINISHED' | 'ABANDONED' | 'EXPIRED';
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export interface Command {
  protocolVersion: 1; commandId: string; roomId: string | null;
  expectedVersion: number | null; expectedPhaseId: string | null;
  type: string; payload: Record<string, Json>;
}
export interface SafeError { code: string; message: string; retryable: boolean; requestId?: string }
export interface ServerHello { protocolVersion: 1; serverTime: string; heartbeatIntervalMs: number; maxCommandBytes: number }

export type VertexId = `v-${string}`;
export type EdgeId = `e-${string}`;
export type HexId = `h-${string}`;
export type Colour = 'RED' | 'BLUE' | 'WHITE' | 'ORANGE' | 'PURPLE' | 'BLACK';
export interface Board {
  readonly topologyVersion: 1;
  readonly hexes: Readonly<Record<HexId, { readonly q: number; readonly r: number; readonly terrain: 'HILLS' | 'FOREST' | 'PASTURE' | 'FIELDS' | 'MOUNTAINS' | 'DESERT'; readonly number: number | null; readonly vertexIds: readonly VertexId[] }>>;
  readonly vertices: Readonly<Record<VertexId, { readonly x: number; readonly y: number; readonly hexIds: readonly HexId[]; readonly edgeIds: readonly EdgeId[] }>>;
  readonly edges: Readonly<Record<EdgeId, { readonly vertexIds: readonly [VertexId, VertexId]; readonly hexIds: readonly HexId[] }>>;
  readonly ports: Readonly<Record<string, { readonly vertexIds: readonly [VertexId, VertexId]; readonly resourceType: ResourceType | null; readonly ratio: 2 | 3 }>>;
}
export interface PublicPlayer {
  readonly id: string; readonly nickname: string; readonly seatIndex: number; readonly colour: Colour;
  /**
   * Present only on an automated seat. Omitted for people, so a game without
   * bots serialises exactly as it did before the field existed and a client
   * built against the older schema is unaffected by it.
   */
  readonly kind?: 'HUMAN' | 'BOT' | 'VACANT';
  readonly resourceCardCount: number; readonly developmentCardCount: number; readonly playedKnights: number;
  readonly remainingPieces: { readonly roads: number; readonly settlements: number; readonly cities: number };
  readonly publicPoints: number;
}
export interface Trade {
  readonly offerId: string; readonly proposerPlayerId: string; readonly targetPlayerId: string | null;
  readonly give: Resources; readonly receive: Resources; readonly revision: number;
  readonly turnNumber: number; readonly phaseId: string;
  readonly status: 'OPEN' | 'ACCEPTED' | 'CANCELLED' | 'EXPIRED'; readonly declinedBy: readonly string[];
}
export interface PublicState {
  readonly board: Board;
  readonly roads: Readonly<Record<EdgeId, { readonly ownerPlayerId: string }>>;
  readonly buildings: Readonly<Record<VertexId, { readonly ownerPlayerId: string; readonly type: 'SETTLEMENT' | 'CITY' }>>;
  readonly robberHexId: HexId; readonly players: Readonly<Record<string, PublicPlayer>>;
  readonly phase: Phase; readonly phaseId: string; readonly turnNumber: number; readonly activePlayerId: string;
  readonly requiredPlayerIds: readonly string[]; readonly hasRolled: boolean; readonly developmentCardPlayedThisTurn: boolean;
  readonly dice: readonly [number, number] | null; readonly trades: Readonly<Record<string, Trade>>;
  readonly longestRoad: { readonly holderPlayerId: string | null; readonly size: number };
  readonly largestArmy: { readonly holderPlayerId: string | null; readonly size: number };
  readonly pauseReasons: readonly ('MANUAL' | 'DISCONNECTED' | 'RECOVERY' | 'DATABASE_UNAVAILABLE' | 'SEAT_VACANT')[];
  readonly turnDeadline: string | null; readonly discardDeadlines: Readonly<Record<string, string>>;
  readonly winnerPlayerId: string | null; readonly winnerVictoryPointCardIds: readonly string[]; readonly finalPoints: Readonly<Record<string, number>>;
}
