import { RESOURCE_TYPES, type EdgeId, type HexId, type PublicState, type ResourceType, type VertexId } from '@island/protocol/contracts';
import type { PlayerPrivateState } from './index.js';
import { bankRate, canRoad, canSettle, COSTS, emptyResources, has, total } from './rules.js';

/**
 * Exactly what one seat is entitled to see: the public state plus its own hand.
 *
 * Move generation is deliberately written against this and nothing else, so an
 * automated seat provably cannot consult another player's cards, the bank deck
 * or any other server-only state. A bot driven from this view is not trusted to
 * behave — it is unable to cheat.
 */
export interface PlayerView {
  readonly publicState: PublicState;
  readonly hand: PlayerPrivateState;
}

/**
 * Facts a seat legitimately knows that `PublicState` does not carry. The server
 * supplies them; a caller that omits them gets a conservative answer rather than
 * a wrong one, so a client may use the same generator with what it has.
 */
export interface LegalHints {
  /** Undefined means "assume cards remain"; the engine rejects an empty deck. */
  readonly developmentCardsRemaining?: number;
  /** The settlement awaiting its road during setup. */
  readonly pendingSetupVertexId?: string | null;
  /** Robber victims the engine has already ruled eligible. */
  readonly eligibleVictimIds?: readonly string[];
  /**
   * What the bank can still pay out. Not derivable publicly: card counts are
   * public per player but their composition is not, so a seat cannot work out
   * the remaining stock of any one resource on its own.
   */
  readonly bankStock?: Readonly<Record<ResourceType, number>>;
}

export interface LegalCommand {
  readonly type: string;
  readonly payload: Record<string, unknown>;
}

const bundleOf = (type: ResourceType, count: number) => ({ ...emptyResources(), [type]: count });

/** Victims the robber could take from, derived from public information alone. */
export function robberVictims(publicState: PublicState, hexId: HexId, actorId: string): string[] {
  const hex = publicState.board.hexes[hexId];
  if (!hex) return [];
  return [...new Set(hex.vertexIds.flatMap(v => (publicState.buildings[v] ? [publicState.buildings[v]!.ownerPlayerId] : [])))]
    .filter(id => id !== actorId && (publicState.players[id]?.resourceCardCount ?? 0) > 0);
}

/**
 * Discarding half a hand is combinatorial, so this returns one canonical bundle
 * — largest stacks first — rather than the whole space. A policy that cares
 * which cards it keeps builds its own bundle and validates it with [isDiscard].
 */
export function canonicalDiscard(hand: PlayerPrivateState): Record<ResourceType, number> {
  const remaining = emptyResources();
  let owed = hand.discardRequired;
  const order = [...RESOURCE_TYPES].sort((a, b) => hand.resources[b] - hand.resources[a]);
  for (const type of order) {
    const take = Math.min(owed, hand.resources[type]);
    remaining[type] = take;
    owed -= take;
  }
  return remaining;
}

export function isDiscard(hand: PlayerPrivateState, resources: Record<ResourceType, number>): boolean {
  return total(resources) === hand.discardRequired && has(hand.resources, resources);
}

/**
 * Every discrete move the seat could make right now.
 *
 * Two families are represented by a single canonical entry rather than being
 * enumerated, because their spaces are combinatorial: discarding, and the
 * Year of Plenty choice. Proposing a trade is omitted entirely — the space is
 * unbounded and a proposal is never forced. A policy is free to construct any
 * of those itself; this is the menu, not the ceiling.
 */
export function legalCommands(view: PlayerView, hints: LegalHints = {}): LegalCommand[] {
  const p = view.publicState, hand = view.hand, me = hand.playerId;
  const moves: LegalCommand[] = [];
  const mine = p.activePlayerId === me;
  const afford = (cost: typeof COSTS.ROAD) => has(hand.resources, cost);
  if (p.pauseReasons.length || p.phase === 'COMPLETE') return moves;

  switch (p.phase) {
    case 'SETUP_SETTLEMENT':
      if (!mine) break;
      for (const vertex of Object.keys(p.board.vertices) as VertexId[]) {
        if (canSettle(p, me, vertex, true)) moves.push({ type: 'PLACE_SETUP_SETTLEMENT', payload: { vertexId: vertex } });
      }
      break;

    case 'SETUP_ROAD': {
      if (!mine) break;
      const pending = hints.pendingSetupVertexId ?? null;
      const edges = pending ? (p.board.vertices[pending as VertexId]?.edgeIds ?? []) : (Object.keys(p.board.edges) as EdgeId[]);
      for (const edge of edges) if (canRoad(p, me, edge)) moves.push({ type: 'PLACE_SETUP_ROAD', payload: { edgeId: edge } });
      break;
    }

    case 'AWAIT_ROLL':
      if (!mine) break;
      if (!p.hasRolled) moves.push({ type: 'ROLL_DICE', payload: {} });
      moves.push(...playableCards(view, hints));
      break;

    case 'DISCARD_REQUIRED':
      if (hand.discardRequired > 0) moves.push({ type: 'DISCARD_RESOURCES', payload: { resources: canonicalDiscard(hand) } });
      break;

    case 'ROBBER_MOVE':
      if (!mine) break;
      for (const hexId of Object.keys(p.board.hexes) as HexId[]) {
        if (hexId !== p.robberHexId) moves.push({ type: 'MOVE_ROBBER', payload: { hexId } });
      }
      break;

    case 'ROBBER_VICTIM': {
      if (!mine) break;
      const eligible = hints.eligibleVictimIds ?? robberVictims(p, p.robberHexId, me);
      for (const victimPlayerId of eligible) moves.push({ type: 'CHOOSE_ROBBER_VICTIM', payload: { victimPlayerId } });
      break;
    }

    case 'ROAD_BUILDING': {
      if (!mine) break;
      const roads = (Object.keys(p.board.edges) as EdgeId[]).filter(edge => canRoad(p, me, edge));
      for (const edgeId of roads) moves.push({ type: 'PLACE_FREE_ROAD', payload: { edgeId } });
      if (!roads.length) moves.push({ type: 'FINISH_FREE_ROADS', payload: {} });
      break;
    }

    case 'ACTION': {
      moves.push(...tradeResponses(view));
      if (!mine) break;
      if (afford(COSTS.ROAD)) {
        for (const edge of Object.keys(p.board.edges) as EdgeId[]) {
          if (canRoad(p, me, edge)) moves.push({ type: 'BUILD_ROAD', payload: { edgeId: edge } });
        }
      }
      if (afford(COSTS.SETTLEMENT)) {
        for (const vertex of Object.keys(p.board.vertices) as VertexId[]) {
          if (canSettle(p, me, vertex, false)) moves.push({ type: 'BUILD_SETTLEMENT', payload: { vertexId: vertex } });
        }
      }
      if (afford(COSTS.CITY) && p.players[me]!.remainingPieces.cities > 0) {
        for (const [vertex, building] of Object.entries(p.buildings)) {
          if (building.ownerPlayerId === me && building.type === 'SETTLEMENT') moves.push({ type: 'BUILD_CITY', payload: { vertexId: vertex } });
        }
      }
      if (afford(COSTS.DEVELOPMENT) && (hints.developmentCardsRemaining ?? 1) > 0) {
        moves.push({ type: 'BUY_DEVELOPMENT_CARD', payload: {} });
      }
      for (const give of RESOURCE_TYPES) {
        const rate = bankRate(p, me, give);
        if (hand.resources[give] < rate) continue;
        for (const receive of RESOURCE_TYPES) {
          if (receive === give || !stocked(hints, receive, 1)) continue;
          moves.push({ type: 'BANK_TRADE', payload: { giveType: give, receiveType: receive, receiveCount: 1 } });
        }
      }
      moves.push(...playableCards(view, hints));
      for (const offer of Object.values(p.trades)) {
        if (offer.status === 'OPEN' && offer.proposerPlayerId === me) moves.push({ type: 'CANCEL_TRADE', payload: { offerId: offer.offerId, offerRevision: offer.revision } });
      }
      moves.push({ type: 'END_TURN', payload: {} });
      break;
    }
  }
  return moves;
}

/** Offers this seat may answer, whether or not it is the active player. */
function tradeResponses(view: PlayerView): LegalCommand[] {
  const p = view.publicState, me = view.hand.playerId, moves: LegalCommand[] = [];
  for (const offer of Object.values(p.trades)) {
    if (offer.status !== 'OPEN' || offer.proposerPlayerId === me) continue;
    if (offer.targetPlayerId !== null && offer.targetPlayerId !== me) continue;
    if (![offer.proposerPlayerId, me].includes(p.activePlayerId)) continue;
    if (offer.declinedBy.includes(me)) continue;
    const key = { offerId: offer.offerId, offerRevision: offer.revision };
    if (has(view.hand.resources, offer.receive)) moves.push({ type: 'ACCEPT_TRADE', payload: key });
    moves.push({ type: 'DECLINE_TRADE', payload: key });
  }
  return moves;
}

function playableCards(view: PlayerView, hints: LegalHints): LegalCommand[] {
  const p = view.publicState, me = view.hand.playerId, moves: LegalCommand[] = [];
  if (p.activePlayerId !== me || p.developmentCardPlayedThisTurn) return moves;
  const seen = new Set<string>();
  for (const card of view.hand.developmentCards) {
    if (card.type === 'VICTORY_POINT' || card.purchasedOnTurn >= p.turnNumber || seen.has(card.type)) continue;
    seen.add(card.type);
    if (card.type === 'ROAD_BUILDING' && !(Object.keys(p.board.edges) as EdgeId[]).some(edge => canRoad(p, me, edge))) continue;
    if (card.type === 'MONOPOLY') {
      for (const resourceType of RESOURCE_TYPES) moves.push({ type: 'PLAY_DEVELOPMENT_CARD', payload: { cardId: card.id, choice: { resourceType } } });
    } else if (card.type === 'YEAR_OF_PLENTY') {
      // One canonical pair the bank can actually pay; a policy that wants a
      // different two builds its own.
      const pair = affordablePair(view, hints);
      if (pair) moves.push({ type: 'PLAY_DEVELOPMENT_CARD', payload: { cardId: card.id, choice: { resources: pair } } });
    } else {
      moves.push({ type: 'PLAY_DEVELOPMENT_CARD', payload: { cardId: card.id, choice: {} } });
    }
  }
  void hints;
  return moves;
}

/** True when the bank is known to hold [count], or when stock is unknown. */
function stocked(hints: LegalHints, type: ResourceType, count: number): boolean {
  return (hints.bankStock?.[type] ?? Number.POSITIVE_INFINITY) >= count;
}

/** Two cards, scarcest in hand first, that the bank can actually pay out. */
function affordablePair(view: PlayerView, hints: LegalHints): Record<ResourceType, number> | null {
  const wanted = [...RESOURCE_TYPES].sort((a, b) => view.hand.resources[a] - view.hand.resources[b]);
  for (const type of wanted) if (stocked(hints, type, 2)) return bundleOf(type, 2);
  const singles = wanted.filter(type => stocked(hints, type, 1));
  if (singles.length < 2) return null;
  const pair = emptyResources();
  pair[singles[0]!] = 1; pair[singles[1]!] = 1;
  return pair;
}
