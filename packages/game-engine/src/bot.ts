import { RESOURCE_TYPES, type EdgeId, type HexId, type PublicState, type ResourceType, type VertexId } from '@island/protocol/contracts';
import { legalCommands, robberVictims, type LegalCommand, type LegalHints, type PlayerView } from './legal.js';
import { canSettle, COSTS, has, total } from './rules.js';

/**
 * HARD is deliberately absent. A tier that is secretly a copy of another is
 * worse than a missing one, so it is added when it plays differently.
 */
export type BotDifficulty = 'EASY' | 'MEDIUM';

/**
 * Deterministic per decision. The runner seeds this from the game id, version
 * and phase id, so a retry after a crash replays the same choice the durable
 * receipt recorded rather than inventing a new move.
 */
export function seedFrom(...parts: (string | number)[]): number {
  let hash = 0x811c9dc5;
  for (const part of parts.join(':')) hash = ((hash ^ part.charCodeAt(0)) * 0x01000193) & 0x7fffffff;
  return hash || 1;
}

function rng(seed: number): () => number {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x ^= x >>> 17; x ^= x << 5; return (x >>> 0) / 0x100000000; };
}

/** Dice pips behind a number token: how often the hex actually pays out. */
const pips = (n: number | null): number => (n === null ? 0 : 6 - Math.abs(7 - n));

function vertexValue(p: PublicState, vertex: VertexId): number {
  const point = p.board.vertices[vertex];
  if (!point) return 0;
  const kinds = new Set<string>();
  let score = 0;
  for (const hexId of point.hexIds) {
    const hex = p.board.hexes[hexId]!;
    if (hex.terrain === 'DESERT') continue;
    score += pips(hex.number ?? null);
    kinds.add(hex.terrain);
  }
  // Variety is worth real points: a spot paying three resources beats a richer
  // one paying two, because it needs fewer trades to convert into buildings.
  return score + kinds.size * 2;
}

function leaderId(p: PublicState, me: string): string | null {
  const rivals = Object.values(p.players).filter(player => player.id !== me);
  if (!rivals.length) return null;
  return rivals.reduce((best, player) => (player.publicPoints > best.publicPoints ? player : best)).id;
}

/** Score a move. Higher wins; ties are broken by the seeded generator. */
function score(move: LegalCommand, view: PlayerView, hints: LegalHints): number {
  const p = view.publicState, me = view.hand.playerId;
  switch (move.type) {
    case 'PLACE_SETUP_SETTLEMENT':
    case 'BUILD_SETTLEMENT':
      return 1000 + vertexValue(p, move.payload.vertexId as VertexId);
    case 'BUILD_CITY':
      // A city doubles an existing payout, so it is worth more than a new
      // settlement on an equivalent spot and costs no new road.
      return 1400 + vertexValue(p, move.payload.vertexId as VertexId);
    case 'PLACE_SETUP_ROAD':
    case 'PLACE_FREE_ROAD':
      return 900;
    case 'BUILD_ROAD': {
      const edge = p.board.edges[move.payload.edgeId as EdgeId]!;
      // Only worth paying for if it opens somewhere to settle.
      const opens = edge.vertexIds.some(v => canSettle({ ...p, roads: { ...p.roads, [move.payload.edgeId as EdgeId]: { ownerPlayerId: me } } }, me, v, false));
      return opens ? 700 + Math.max(...edge.vertexIds.map(v => vertexValue(p, v))) : 200;
    }
    case 'BUY_DEVELOPMENT_CARD':
      return 600;
    case 'PLAY_DEVELOPMENT_CARD':
      return 650;
    case 'ROLL_DICE':
      return 2000;
    case 'DISCARD_RESOURCES':
      return 2000;
    case 'MOVE_ROBBER': {
      const hex = p.board.hexes[move.payload.hexId as HexId]!;
      const mineHere = hex.vertexIds.some(v => p.buildings[v]?.ownerPlayerId === me);
      if (mineHere) return 0;
      const leader = leaderId(p, me);
      const hitsLeader = leader !== null && hex.vertexIds.some(v => p.buildings[v]?.ownerPlayerId === leader);
      return 500 + pips(hex.number ?? null) + (hitsLeader ? 20 : 0) + robberVictims(p, move.payload.hexId as HexId, me).length * 5;
    }
    case 'CHOOSE_ROBBER_VICTIM':
      return 500 + (p.players[move.payload.victimPlayerId as string]?.resourceCardCount ?? 0);
    case 'ACCEPT_TRADE': {
      const offer = p.trades[move.payload.offerId as string]!;
      // Take it only when more cards come in than go out.
      return 400 + (total(offer.give) - total(offer.receive)) * 50;
    }
    case 'DECLINE_TRADE':
      return 300;
    case 'BANK_TRADE': {
      // Four-for-one is a bad deal unless it completes something buildable.
      const after = { ...view.hand.resources };
      const give = move.payload.giveType as ResourceType, receive = move.payload.receiveType as ResourceType;
      after[give] -= 4; after[receive] += 1;
      const unlocks = [COSTS.CITY, COSTS.SETTLEMENT, COSTS.ROAD].some(cost => !has(view.hand.resources, cost) && has(after, cost));
      return unlocks ? 800 : 50;
    }
    case 'CANCEL_TRADE':
      return 100;
    case 'FINISH_FREE_ROADS':
      return 400;
    case 'END_TURN':
      return 150;
    default:
      void hints;
      return 100;
  }
}

/**
 * Picks this seat's next move, or null when it has nothing to do.
 *
 * Reads only [view], which carries the public state and this seat's own hand,
 * so the choice cannot depend on an opponent's cards however the tiers grow.
 */
export function chooseCommand(
  view: PlayerView,
  hints: LegalHints,
  difficulty: BotDifficulty,
  seed: number,
): LegalCommand | null {
  const moves = legalCommands(view, hints);
  if (!moves.length) return null;
  const next = rng(seed);
  if (difficulty === 'EASY') {
    // Uniform among legal moves, except that ending the turn while something
    // else is available would stall the game into a very long draw.
    const rest = moves.filter(move => move.type !== 'END_TURN');
    const pool = rest.length && next() < 0.8 ? rest : moves;
    return pool[Math.floor(next() * pool.length)] ?? null;
  }
  let best = moves[0]!, bestScore = -Infinity;
  for (const move of moves) {
    // The jitter only separates equal scores; it never reorders real ones.
    const value = score(move, view, hints) + next();
    if (value > bestScore) { best = move; bestScore = value; }
  }
  return best;
}

export { legalCommands, robberVictims, type LegalCommand, type LegalHints, type PlayerView } from './legal.js';
export const BOT_RESOURCE_TYPES = RESOURCE_TYPES;
