import { RESOURCE_TYPES, type EdgeId, type HexId, type PublicState, type Resources, type ResourceType, type VertexId } from '@island/protocol/contracts';
import { TERRAIN_RESOURCE } from './board.js';
import { robberVictims, type LegalCommand, type LegalHints, type PlayerView } from './legal.js';
import { bankRate, canSettle, COSTS, emptyResources, longestRoad, total } from './rules.js';

const pips = (n: number | null) => n === null ? 0 : 6 - Math.abs(7 - n);
type Plan = { cost: Resources; value: number; firstRoad?: EdgeId };

/** Expected production in dice pips; uses buildings and tokens, never rival hands. */
function production(p: PublicState, player: string): Record<ResourceType, number> {
  const result = emptyResources();
  for (const [v, building] of Object.entries(p.buildings)) if (building.ownerPlayerId === player) {
    for (const id of p.board.vertices[v as VertexId]!.hexIds) {
      const hex = p.board.hexes[id]!, type = TERRAIN_RESOURCE[hex.terrain];
      if (type) result[type] += pips(hex.number) * (building.type === 'CITY' ? 2 : 1);
    }
  }
  return result;
}

function siteValue(p: PublicState, vertex: VertexId, income: Resources): number {
  let value = 0;
  for (const id of p.board.vertices[vertex]!.hexIds) {
    const hex = p.board.hexes[id]!, type = TERRAIN_RESOURCE[hex.terrain];
    if (type) value += pips(hex.number) * (1 + 3 / (1 + income[type]));
  }
  for (const port of Object.values(p.board.ports)) if (port.vertexIds.includes(vertex)) {
    value += port.resourceType ? Math.min(6, income[port.resourceType]) : 3;
  }
  return value;
}

/** Multi-source shortest routes, at most three new roads, respecting occupied edges and rival settlements. */
function routes(p: PublicState, me: string): Map<VertexId, { distance: number; firstRoad?: EdgeId }> {
  const result = new Map<VertexId, { distance: number; firstRoad?: EdgeId }>();
  for (const [v, point] of Object.entries(p.board.vertices)) {
    const vertex = v as VertexId, building = p.buildings[vertex];
    if (building && building.ownerPlayerId !== me) continue;
    if (building?.ownerPlayerId === me || point.edgeIds.some(e => p.roads[e]?.ownerPlayerId === me)) result.set(vertex, { distance: 0 });
  }
  const visited = new Set<VertexId>();
  while (true) {
    const next = [...result.entries()].filter(([v]) => !visited.has(v)).sort((a, b) => a[1].distance - b[1].distance)[0];
    if (!next) break;
    const [vertex, path] = next; visited.add(vertex);
    const building = p.buildings[vertex];
    if (building && building.ownerPlayerId !== me) continue;
    for (const edge of p.board.vertices[vertex]!.edgeIds) {
      if (p.roads[edge] && p.roads[edge]!.ownerPlayerId !== me) continue;
      const destination = p.board.edges[edge]!.vertexIds.find(v => v !== vertex)!;
      const distance = path.distance + (p.roads[edge] ? 0 : 1);
      if (distance > Math.min(3, p.players[me]!.remainingPieces.roads) || distance >= (result.get(destination)?.distance ?? Infinity)) continue;
      result.set(destination, { distance, firstRoad: path.firstRoad ?? (p.roads[edge] ? undefined : edge) });
    }
  }
  return result;
}

function plans(view: PlayerView, hints: LegalHints, income: Resources): Plan[] {
  const p = view.publicState, me = view.hand.playerId, result: Plan[] = [];
  for (const [vertex, route] of routes(p, me)) if (canSettle(p, me, vertex, true)) {
    result.push({ cost: { ...COSTS.SETTLEMENT, brick: 1 + route.distance, lumber: 1 + route.distance },
      value: 1100 + siteValue(p, vertex, income) * 12, firstRoad: route.firstRoad });
  }
  if (p.players[me]!.remainingPieces.cities > 0) for (const [v, b] of Object.entries(p.buildings)) {
    if (b.ownerPlayerId === me && b.type === 'SETTLEMENT') result.push({ cost: COSTS.CITY, value: 1250 + siteValue(p, v as VertexId, income) * 10 });
  }
  if ((hints.developmentCardsRemaining ?? 1) > 0) result.push({ cost: COSTS.DEVELOPMENT, value: 500 });
  return result;
}

const deficit = (hand: Resources, cost: Resources, income: Resources) => RESOURCE_TYPES.reduce((n, type) => n + Math.max(0, cost[type] - hand[type]) * (1 + 2 / (1 + income[type])), 0);
const potential = (hand: Resources, targets: Plan[], income: Resources) => Math.max(0, ...targets.map(t => t.value / (1 + deficit(hand, t.cost, income))));
function tradeHand(hand: Resources, move: LegalCommand, p: PublicState, me: string): Resources {
  const after = { ...hand }, give = move.payload.giveType as ResourceType, receive = move.payload.receiveType as ResourceType;
  const count = move.payload.receiveCount as number;
  after[give] -= bankRate(p, me, give) * count; after[receive] += count;
  return after;
}

/** Evaluate one further bank trade (maximum 20): allows two-step conversions without an unbounded search. */
function tradePotential(after: Resources, first: LegalCommand, view: PlayerView, hints: LegalHints, targets: Plan[], income: Resources): number {
  let best = potential(after, targets, income);
  for (const give of RESOURCE_TYPES) {
    const rate = bankRate(view.publicState, view.hand.playerId, give);
    if (after[give] < rate) continue;
    for (const receive of RESOURCE_TYPES) {
      const stock = (hints.bankStock?.[receive] ?? Infinity) - (first.payload.receiveType === receive ? 1 : 0) + (first.payload.giveType === receive ? bankRate(view.publicState, view.hand.playerId, receive) : 0);
      if (give === receive || stock < 1) continue;
      const hand = { ...after, [give]: after[give] - rate, [receive]: after[receive] + 1 };
      best = Math.max(best, potential(hand, targets, income) * 0.9);
    }
  }
  return best;
}

/** All 15 two-card bundles, filtered by availability; no development deck identities are inspected. */
function cardChoices(moves: LegalCommand[], view: PlayerView, hints: LegalHints): LegalCommand[] {
  return moves.flatMap(move => {
    if (move.type !== 'PLAY_DEVELOPMENT_CARD' || view.hand.developmentCards.find(c => c.id === move.payload.cardId)?.type !== 'YEAR_OF_PLENTY') return [move];
    const choices: LegalCommand[] = [];
    for (let i = 0; i < RESOURCE_TYPES.length; i++) for (let j = i; j < RESOURCE_TYPES.length; j++) {
      const resources = emptyResources(); resources[RESOURCE_TYPES[i]!]++; resources[RESOURCE_TYPES[j]!]++;
      if (RESOURCE_TYPES.every(t => resources[t] <= (hints.bankStock?.[t] ?? Infinity))) choices.push({ ...move, payload: { ...move.payload, choice: { resources } } });
    }
    return choices;
  });
}

/** Hard is a bounded public-information planner, with no simulation of hidden cards or future dice. */
export function chooseHard(view: PlayerView, hints: LegalHints, legal: LegalCommand[], next: () => number): LegalCommand {
  const p = view.publicState, me = view.hand.playerId, hand = view.hand.resources;
  const income = production(p, me), targets = plans(view, hints, income), before = potential(hand, targets, income);
  const moves = cardChoices(legal, view, hints);
  if (p.phase === 'DISCARD_REQUIRED') {
    const target = [...targets].sort((a, b) => b.value / (1 + deficit(hand, b.cost, income)) - a.value / (1 + deficit(hand, a.cost, income)))[0];
    const kept = { ...hand }, discarded = emptyResources();
    for (let i = 0; i < view.hand.discardRequired; i++) {
      const type = RESOURCE_TYPES.filter(t => kept[t] > 0).sort((a, b) => {
        const value = (t: ResourceType) => (kept[t] <= (target?.cost[t] ?? 0) ? 100 : 0) + 2 / (1 + income[t]) - kept[t] * 0.01;
        return value(a) - value(b);
      })[0]!;
      kept[type]--; discarded[type]++;
    }
    return { type: 'DISCARD_RESOURCES', payload: { resources: discarded } };
  }
  const roadLength = moves.some(m => ['BUILD_ROAD', 'PLACE_FREE_ROAD'].includes(m.type)) ? longestRoad(p, me) : 0;
  function score(move: LegalCommand): number {
    switch (move.type) {
      case 'PLACE_SETUP_SETTLEMENT': return 1000 + siteValue(p, move.payload.vertexId as VertexId, income) * 12;
      case 'BUILD_SETTLEMENT': return (view.hand.totalPoints >= 9 ? 10000 : 1100) + siteValue(p, move.payload.vertexId as VertexId, income) * 12;
      case 'BUILD_CITY': return (view.hand.totalPoints >= 9 ? 10000 : 1250) + siteValue(p, move.payload.vertexId as VertexId, income) * 10;
      case 'PLACE_SETUP_ROAD':
      case 'PLACE_FREE_ROAD':
      case 'BUILD_ROAD': {
        const edge = move.payload.edgeId as EdgeId;
        let value = Math.max(0, ...targets.filter(t => t.firstRoad === edge).map(t => 300 + t.value / (1 + deficit(hand, t.cost, income)) * 0.4));
        const after = { ...p, roads: { ...p.roads, [edge]: { ownerPlayerId: me } } };
        const length = longestRoad(after, me), threshold = Math.max(5, p.longestRoad.size + 1);
        if (p.longestRoad.holderPlayerId !== me && length >= threshold) value = Math.max(value, view.hand.totalPoints >= 8 ? 10000 : 1000);
        else if (length > roadLength && length >= threshold - 2) value = Math.max(value, 230 + length);
        return value;
      }
      case 'BANK_TRADE': {
        const after = tradeHand(hand, move, p, me);
        const gain = tradePotential(after, move, view, hints, targets, income) - before;
        return gain > 1 ? 500 + gain * 0.5 : 0;
      }
      case 'BUY_DEVELOPMENT_CARD': {
        // Keep cards for a city/settlement when buying would move that goal further away.
        const after = { ...hand }; for (const t of RESOURCE_TYPES) after[t] -= COSTS.DEVELOPMENT[t];
        const buildings = targets.filter(t => t.cost !== COSTS.DEVELOPMENT);
        return potential(hand, buildings, income) - potential(after, buildings, income) > 350 ? 100 : 550;
      }
      case 'PLAY_DEVELOPMENT_CARD': {
        const card = view.hand.developmentCards.find(c => c.id === move.payload.cardId)!;
        if (card.type === 'KNIGHT') {
          const winsArmy = p.largestArmy.holderPlayerId !== me && p.players[me]!.playedKnights + 1 >= Math.max(3, p.largestArmy.size + 1);
          if (winsArmy) return view.hand.totalPoints >= 8 ? 11000 : 1700;
          const blocked = p.board.hexes[p.robberHexId]!.vertexIds.some(v => p.buildings[v]?.ownerPlayerId === me);
          return blocked ? 2200 : p.phase === 'AWAIT_ROLL' ? 0 : 700;
        }
        if (card.type === 'YEAR_OF_PLENTY') {
          const resources = (move.payload.choice as { resources: Resources }).resources;
          const after = { ...hand }; for (const t of RESOURCE_TYPES) after[t] += resources[t];
          const gain = potential(after, targets, income) - before;
          return gain > 10 ? 700 + gain : 0;
        }
        if (card.type === 'MONOPOLY') {
          const type = (move.payload.choice as { resourceType: ResourceType }).resourceType;
          let expected = 0;
          for (const rival of Object.values(p.players)) if (rival.id !== me) {
            const supply = production(p, rival.id), sum = total(supply);
            expected += rival.resourceCardCount * (sum ? supply[type] / sum : 0.2);
          }
          const after = { ...hand, [type]: hand[type] + Math.floor(expected) };
          return expected >= 2 ? 650 + expected * 20 + Math.max(0, potential(after, targets, income) - before) : 0;
        }
        return 700;
      }
      case 'ROLL_DICE': return 2000;
      case 'MOVE_ROBBER': {
        const hexId = move.payload.hexId as HexId, hex = p.board.hexes[hexId]!;
        let value = robberVictims(p, hexId, me).length ? 20 : 0;
        for (const v of hex.vertexIds) {
          const b = p.buildings[v]; if (!b) continue;
          const weight = b.ownerPlayerId === me ? -5 : 1 + p.players[b.ownerPlayerId]!.publicPoints / 4;
          value += pips(hex.number) * (b.type === 'CITY' ? 2 : 1) * weight;
        }
        return value;
      }
      case 'CHOOSE_ROBBER_VICTIM': {
        const rival = p.players[move.payload.victimPlayerId as string]!;
        return rival.publicPoints * 10 + rival.resourceCardCount;
      }
      case 'ACCEPT_TRADE': {
        const offer = p.trades[move.payload.offerId as string]!, after = { ...hand };
        for (const t of RESOURCE_TYPES) after[t] += offer.give[t] - offer.receive[t];
        const gain = potential(after, targets, income) - before;
        // Do not feed an almost-winning rival; evaluate our needs as well as card counts.
        if (p.players[offer.proposerPlayerId]!.publicPoints >= 9) return 0;
        return gain > 20 || (gain >= 0 && total(offer.give) > total(offer.receive)) ? 600 + Math.max(0, gain) : 0;
      }
      case 'DECLINE_TRADE': return 180;
      case 'END_TURN': return 150;
      case 'FINISH_FREE_ROADS': return 400;
      default: return 0;
    }
  }
  let best = moves[0]!, bestScore = -Infinity;
  for (const move of moves) {
    const value = score(move) + next() * 0.001;
    if (value > bestScore) { best = move; bestScore = value; }
  }
  return best;
}
