import { RESOURCE_TYPES, RULES_VERSION, type Command, type Colour, type Resources, type ResourceType, type VertexId, type EdgeId, type HexId, type Phase } from '@island/protocol/contracts';
import { PHASE_TRANSITIONS, type CanonicalState, type DevelopmentCard } from './index.js';
import { generateBoard, TERRAIN_RESOURCE } from './board.js';
import { RecordedRandom, UUID, type RandomSource, type RandomDraw } from './random.js';
import { assertBoard, assertInvariants } from './invariants.js';
import { RuleError, requireRule, emptyResources, total, has, bundle, transfer, COSTS, canRoad, canSettle, legalRoads, bankRate, refreshDerived, type WorkingState } from './rules.js';

export interface EngineContext { random: RandomSource; now: string }
export type EngineEffect =
  | { type: 'PUBLIC_ACTIVITY'; actorPlayerId: string | null; action: string; message: string; subjectPlayerId?: string | null; resources?: Resources; give?: Resources; receive?: Resources }
  | { type: 'RESOURCE_TRANSFER'; fromPlayerId: string | null; toPlayerId: string | null; resources: Resources; reason: string; visibleTo: 'PUBLIC' | readonly string[] }
  | { type: 'DEVELOPMENT_DRAW'; playerId: string; card: DevelopmentCard }
  | { type: 'DEVELOPMENT_PLAY'; playerId: string; card: DevelopmentCard }
  | { type: 'DICE'; dice: readonly [number, number] }
  | { type: 'AWARD_CHANGED'; award: 'longestRoad' | 'largestArmy'; holderPlayerId: string | null; size: number };
export interface Transition { state: CanonicalState; effects: readonly EngineEffect[]; randomDraws: readonly RandomDraw[]; occurredAt: string }
export interface InitialPlayer { id: string; nickname: string; seatIndex: number; colour: Colour; kind?: 'HUMAN' | 'BOT' }
export interface NewGame { roomId: string; players: readonly InitialPlayer[]; turnLimitSeconds?: null | 60 | 120 | 180 }

function validateContext(context: EngineContext): void { if (!Number.isFinite(Date.parse(context.now))) throw new Error('Explicit server time required'); }
export function createGame(input: NewGame, context: EngineContext): Transition {
  validateContext(context);
  requireRule(UUID.test(input.roomId) && [3, 4].includes(input.players.length), 'INVALID_PAYLOAD');
  requireRule(input.turnLimitSeconds === undefined || [null, 60, 120, 180].includes(input.turnLimitSeconds), 'INVALID_PAYLOAD');
  const players = [...input.players].sort((a, b) => a.seatIndex - b.seatIndex);
  requireRule(new Set(players.map(p => p.id)).size === players.length && new Set(players.map(p => p.seatIndex)).size === players.length && new Set(players.map(p => p.colour)).size === players.length, 'INVALID_PAYLOAD');
  requireRule(players.every(p => UUID.test(p.id) && Number.isInteger(p.seatIndex) && p.seatIndex >= 0 && p.seatIndex < 4 && ['RED', 'BLUE', 'WHITE', 'ORANGE', 'PURPLE', 'BLACK'].includes(p.colour)), 'INVALID_PAYLOAD');
  requireRule(players.every(p => typeof p.nickname === 'string' && [...p.nickname].length >= 2 && [...p.nickname].length <= 160 && !/[\u0000-\u001f\u007f]/u.test(p.nickname)), 'INVALID_PAYLOAD');
  requireRule(players.every(p => p.kind === undefined || p.kind === 'HUMAN' || p.kind === 'BOT'), 'INVALID_PAYLOAD');
  // A practice game must keep at least one person in it; an entirely automated
  // table has nobody to play it and nobody to end it.
  requireRule(players.some(p => (p.kind ?? 'HUMAN') === 'HUMAN'), 'INVALID_PAYLOAD');
  const random = new RecordedRandom(context.random), board = generateBoard(random);
  const first = random.int(players.length, 'first-seat'), order = [...players.slice(first), ...players.slice(0, first)].map(p => p.id);
  const deck: DevelopmentCard[] = [];
  for (const [type, count] of Object.entries({ KNIGHT: 14, VICTORY_POINT: 5, ROAD_BUILDING: 2, MONOPOLY: 2, YEAR_OF_PLENTY: 2 })) {
    for (let i = 0; i < count; i++) deck.push({ id: random.id('development-card'), type: type as DevelopmentCard['type'], purchasedOnTurn: 0 });
  }
  const state: WorkingState = {
    roomId: input.roomId, version: 0, rulesVersion: RULES_VERSION, stateSchemaVersion: 1, protocolVersion: 1,
    publicState: {
      board: structuredClone(board) as WorkingState['publicState']['board'], roads: {}, buildings: {}, robberHexId: (Object.keys(board.hexes) as HexId[]).find(id => board.hexes[id]!.terrain === 'DESERT')!,
      // Destructured so a human seat carries no kind key at all, rather than one
      // set to undefined: a game without bots must serialise byte for byte as before.
      players: Object.fromEntries(players.map(({ kind, ...p }) => [p.id, { ...p, ...(kind === 'BOT' ? { kind } : {}), resourceCardCount: 0, developmentCardCount: 0, playedKnights: 0, remainingPieces: { roads: 15, settlements: 5, cities: 4 }, publicPoints: 0 }])),
      phase: 'SETUP_SETTLEMENT', phaseId: random.id('phase'), turnNumber: 0, activePlayerId: order[0]!, requiredPlayerIds: [order[0]!], hasRolled: false, developmentCardPlayedThisTurn: false,
      dice: null, trades: {}, longestRoad: { holderPlayerId: null, size: 0 }, largestArmy: { holderPlayerId: null, size: 0 }, pauseReasons: [], turnDeadline: null, discardDeadlines: {}, winnerPlayerId: null, winnerVictoryPointCardIds: [], finalPoints: {},
    },
    privateState: Object.fromEntries(players.map(p => [p.id, { playerId: p.id, resources: emptyResources(), developmentCards: [], totalPoints: 0, discardRequired: 0 }])),
    serverState: { bank: { brick: 19, lumber: 19, wool: 19, grain: 19, ore: 19 }, developmentDeck: random.shuffle(deck, 'development-deck'), playedCards: [], turnOrder: order,
      setup: { snakeOrder: [...order, ...[...order].reverse()], position: 0, pendingVertexId: null, grantedTo: [] }, effect: null },
    clockState: { turnLimitSeconds: input.turnLimitSeconds ?? null, turnExpired: false, remainingTurnMs: input.turnLimitSeconds ? input.turnLimitSeconds * 1000 : null, deadline: null, generation: random.id('clock-generation'), discards: {} },
  };
  assertBoard(state.publicState.board); refreshDerived(state); assertInvariants(state);
  return { state, effects: [{ type: 'PUBLIC_ACTIVITY', actorPlayerId: null, action: 'GAME_CREATED', message: 'The island is ready for initial placement.' }], randomDraws: random.draws, occurredAt: context.now };
}

const PAYLOADS: Readonly<Record<string, readonly string[]>> = {
  PLACE_SETUP_SETTLEMENT: ['vertexId'], PLACE_SETUP_ROAD: ['edgeId'], ROLL_DICE: [], DISCARD_RESOURCES: ['resources'], MOVE_ROBBER: ['hexId'], CHOOSE_ROBBER_VICTIM: ['victimPlayerId'],
  BUILD_ROAD: ['edgeId'], BUILD_SETTLEMENT: ['vertexId'], BUILD_CITY: ['vertexId'], BANK_TRADE: ['giveType', 'receiveType', 'receiveCount'],
  PROPOSE_TRADE: ['targetPlayerId', 'give', 'receive'], ACCEPT_TRADE: ['offerId', 'offerRevision'], DECLINE_TRADE: ['offerId', 'offerRevision'], CANCEL_TRADE: ['offerId', 'offerRevision'],
  BUY_DEVELOPMENT_CARD: [], PLAY_DEVELOPMENT_CARD: ['cardId', 'choice'], PLACE_FREE_ROAD: ['edgeId'], FINISH_FREE_ROADS: [], END_TURN: [],
};
function validateCommand(command: Command): void {
  requireRule(command && Object.keys(command).length === 7 && command.protocolVersion === 1 && UUID.test(command.commandId), 'INVALID_PAYLOAD');
  requireRule(Object.hasOwn(PAYLOADS, command.type), 'INVALID_PAYLOAD');
  const fields = PAYLOADS[command.type]!;
  requireRule(command.payload && typeof command.payload === 'object' && !Array.isArray(command.payload) && Object.keys(command.payload).length === fields.length && fields.every(key => Object.hasOwn(command.payload, key)), 'INVALID_PAYLOAD');
  for (const key of fields.filter(k => k.endsWith('Id') && k !== 'targetPlayerId')) requireRule(typeof command.payload[key] === 'string', 'INVALID_PAYLOAD');
}

export function applyCommand(previous: CanonicalState, actorPlayerId: string, command: Command, context: EngineContext): Transition {
  validateContext(context); validateCommand(command); assertInvariants(previous);
  requireRule(Object.hasOwn(previous.privateState, actorPlayerId), 'FORBIDDEN');
  requireRule(command.roomId === previous.roomId, 'FORBIDDEN');
  requireRule(command.expectedVersion === previous.version, 'STALE_VERSION');
  requireRule(command.expectedPhaseId === previous.publicState.phaseId, 'WRONG_PHASE');
  requireRule(previous.publicState.phase !== 'COMPLETE', 'GAME_FINISHED');
  requireRule(previous.publicState.pauseReasons.length === 0, 'GAME_PAUSED');
  const state = structuredClone(previous) as WorkingState, p = state.publicState, privateState = state.privateState, bank = state.serverState.bank;
  const random = new RecordedRandom(context.random), effects: EngineEffect[] = [], payload = command.payload, actor = actorPlayerId;
  const hand = privateState[actor]!, player = p.players[actor]!;
  const active = () => requireRule(actor === p.activePlayerId, 'NOT_YOUR_TURN');
  const phase = (...allowed: Phase[]) => requireRule(allowed.includes(p.phase), 'WRONG_PHASE');
  const activity = (action: string, message: string, detail?: { subjectPlayerId?: string | null; resources?: Resources; give?: Resources; receive?: Resources }) => effects.push({ type: 'PUBLIC_ACTIVITY', actorPlayerId: actor, action, message, ...detail });
  function move(from: string | null, to: string | null, resources: Resources, reason: string, visibleTo: 'PUBLIC' | string[] = 'PUBLIC') {
    transfer(from ? privateState[from]!.resources : bank, to ? privateState[to]!.resources : bank, resources, from ? 'INSUFFICIENT_RESOURCES' : 'BANK_UNAVAILABLE');
    if (total(resources)) effects.push({ type: 'RESOURCE_TRANSFER', fromPlayerId: from, toPlayerId: to, resources: { ...resources }, reason, visibleTo });
  }
  function enter(next: Phase) {
    if (!PHASE_TRANSITIONS[p.phase].includes(next)) throw new Error(`Undeclared phase transition: ${p.phase} -> ${next}`);
    const id = random.id('phase'); requireRule(id !== p.phaseId, 'INVALID_PAYLOAD');
    p.phase = next; p.phaseId = id;
    p.requiredPlayerIds = next === 'DISCARD_REQUIRED' ? state.serverState.turnOrder.filter(id => privateState[id]!.discardRequired > 0) : next === 'COMPLETE' ? [] : [p.activePlayerId];
  }
  function cancelOffers() { for (const offer of Object.values(p.trades)) if (offer.status === 'OPEN') offer.status = 'EXPIRED'; }
  function continueEffect() { const next = state.serverState.effect!.continuation; state.serverState.effect = null; enter(next); }
  function robber(continuation: 'AWAIT_ROLL' | 'ACTION') {
    cancelOffers(); state.serverState.effect = { kind: 'ROBBER', continuation, eligiblePlayerIds: [], remainingRoads: 0 }; enter('ROBBER_MOVE');
  }
  function settle(vertex: VertexId, setup: boolean) {
    requireRule(canSettle(p, actor, vertex, setup), 'ILLEGAL_PLACEMENT');
    if (!setup) move(actor, null, COSTS.SETTLEMENT, 'BUILD_SETTLEMENT');
    p.buildings[vertex] = { ownerPlayerId: actor, type: 'SETTLEMENT' }; player.remainingPieces.settlements--;
    activity('SETTLEMENT_BUILT', 'Built a settlement.');
  }
  function road(edge: EdgeId, free: boolean) {
    requireRule(canRoad(p, actor, edge), 'ILLEGAL_PLACEMENT');
    if (!free) move(actor, null, COSTS.ROAD, 'BUILD_ROAD');
    p.roads[edge] = { ownerPlayerId: actor }; player.remainingPieces.roads--; activity('ROAD_BUILT', 'Built a road.');
  }
  function victimIds(hexId: HexId): string[] {
    return [...new Set(p.board.hexes[hexId]!.vertexIds.flatMap(v => p.buildings[v] ? [p.buildings[v]!.ownerPlayerId] : []))].filter(id => id !== actor && total(privateState[id]!.resources) > 0);
  }
  function checkedOffer() {
    const offer = p.trades[payload.offerId as string];
    requireRule(offer && offer.status === 'OPEN' && offer.revision === payload.offerRevision && offer.turnNumber === p.turnNumber && offer.phaseId === p.phaseId, 'TRADE_UNAVAILABLE');
    return offer;
  }
  switch (command.type) {
    case 'PLACE_SETUP_SETTLEMENT': {
      phase('SETUP_SETTLEMENT'); active(); const setup = state.serverState.setup!;
      settle(payload.vertexId as VertexId, true); setup.pendingVertexId = payload.vertexId as string;
      if (setup.position >= state.serverState.turnOrder.length) {
        requireRule(!setup.grantedTo.includes(actor), 'WRONG_PHASE');
        const resources = emptyResources();
        for (const id of p.board.vertices[payload.vertexId as VertexId]!.hexIds) { const type = TERRAIN_RESOURCE[p.board.hexes[id]!.terrain]; if (type) resources[type]++; }
        move(null, actor, resources, 'INITIAL_RESOURCES'); setup.grantedTo.push(actor);
      }
      enter('SETUP_ROAD'); break;
    }
    case 'PLACE_SETUP_ROAD': {
      phase('SETUP_ROAD'); active(); const setup = state.serverState.setup!, edge = payload.edgeId as EdgeId;
      requireRule(p.board.edges[edge]?.vertexIds.includes(setup.pendingVertexId as VertexId), 'ILLEGAL_PLACEMENT');
      road(edge, true); setup.position++; setup.pendingVertexId = null;
      if (setup.position < setup.snakeOrder.length) { p.activePlayerId = setup.snakeOrder[setup.position]!; enter('SETUP_SETTLEMENT'); }
      else { state.serverState.setup = null; p.activePlayerId = state.serverState.turnOrder[0]!; p.turnNumber = 1; enter('AWAIT_ROLL'); }
      break;
    }
    case 'ROLL_DICE': {
      phase('AWAIT_ROLL'); active(); requireRule(!p.hasRolled, 'WRONG_PHASE');
      p.dice = [random.int(6, 'die-one') + 1, random.int(6, 'die-two') + 1]; p.hasRolled = true;
      effects.push({ type: 'DICE', dice: [...p.dice] }); activity('DICE_ROLLED', `Rolled ${p.dice[0] + p.dice[1]}.`);
      const sum = p.dice[0] + p.dice[1];
      if (sum === 7) {
        for (const privatePlayer of Object.values(privateState)) { const count = total(privatePlayer.resources); privatePlayer.discardRequired = count > 7 ? Math.floor(count / 2) : 0; }
        if (Object.values(privateState).some(hand => hand.discardRequired > 0)) {
          state.serverState.effect = { kind: 'DISCARD', continuation: 'ACTION', eligiblePlayerIds: [], remainingRoads: 0 }; enter('DISCARD_REQUIRED');
        } else robber('ACTION');
      } else {
        const demand: Record<ResourceType, Record<string, number>> = { brick: {}, lumber: {}, wool: {}, grain: {}, ore: {} };
        for (const [id, hex] of Object.entries(p.board.hexes)) {
          const type = TERRAIN_RESOURCE[hex.terrain]; if (id === p.robberHexId || !type || hex.number !== sum) continue;
          for (const vertex of hex.vertexIds) { const b = p.buildings[vertex]; if (b) demand[type][b.ownerPlayerId] = (demand[type][b.ownerPlayerId] ?? 0) + (b.type === 'CITY' ? 2 : 1); }
        }
        const collected: Record<string, ReturnType<typeof emptyResources>> = {};
        for (const type of RESOURCE_TYPES) {
          const entries = state.serverState.turnOrder.filter(id => demand[type][id]).map(id => [id, demand[type][id]!] as const), required = entries.reduce((sum, [, n]) => sum + n, 0);
          if (bank[type] < required && entries.length > 1) continue;
          for (const [id, count] of entries) {
            const resources = emptyResources(); resources[type] = Math.min(count, bank[type]); move(null, id, resources, 'PRODUCTION');
            if (resources[type]) { collected[id] ??= emptyResources(); collected[id]![type] += resources[type]; }
          }
        }
        // Production is public. Publish actual payouts, after shortage rules,
        // so clients can animate collection without guessing at private hands.
        for (const id of state.serverState.turnOrder) if (collected[id]) {
          effects.push({ type: 'PUBLIC_ACTIVITY', actorPlayerId: id, action: 'RESOURCES_COLLECTED', message: 'Collected resources from the roll.', resources: collected[id] });
        }
        enter('ACTION');
      }
      break;
    }
    case 'DISCARD_RESOURCES': {
      phase('DISCARD_REQUIRED'); requireRule(hand.discardRequired > 0, 'WRONG_PHASE'); const resources = bundle(payload.resources);
      requireRule(total(resources) === hand.discardRequired, 'INVALID_PAYLOAD'); move(actor, null, resources, 'DISCARD', [actor]); hand.discardRequired = 0;
      activity('RESOURCES_DISCARDED', 'Discarded the required resource cards.', { resources: { ...resources } });
      p.requiredPlayerIds = state.serverState.turnOrder.filter(id => privateState[id]!.discardRequired > 0);
      if (!p.requiredPlayerIds.length) robber('ACTION'); break;
    }
    case 'MOVE_ROBBER': {
      phase('ROBBER_MOVE'); active(); const hex = payload.hexId as HexId; requireRule(p.board.hexes[hex] && hex !== p.robberHexId, 'ILLEGAL_PLACEMENT');
      p.robberHexId = hex; state.serverState.effect!.eligiblePlayerIds = victimIds(hex); activity('ROBBER_MOVED', 'Moved the robber.');
      if (state.serverState.effect!.eligiblePlayerIds.length) enter('ROBBER_VICTIM'); else continueEffect(); break;
    }
    case 'CHOOSE_ROBBER_VICTIM': {
      phase('ROBBER_VICTIM'); active(); const victim = payload.victimPlayerId as string;
      requireRule(state.serverState.effect!.eligiblePlayerIds.includes(victim) && victimIds(p.robberHexId).includes(victim), 'FORBIDDEN');
      let index = random.int(total(privateState[victim]!.resources), 'stolen-card');
      const resources = emptyResources();
      for (const type of RESOURCE_TYPES) { const count = privateState[victim]!.resources[type]; if (index < count) { resources[type] = 1; break; } index -= count; }
      move(victim, actor, resources, 'STEAL', [victim, actor]); activity('RESOURCE_STOLEN', 'Stole one resource card.', { subjectPlayerId: victim }); continueEffect(); break;
    }
    case 'BUILD_ROAD': phase('ACTION'); active(); road(payload.edgeId as EdgeId, false); break;
    case 'BUILD_SETTLEMENT': phase('ACTION'); active(); settle(payload.vertexId as VertexId, false); break;
    case 'BUILD_CITY': {
      phase('ACTION'); active(); const vertex = payload.vertexId as VertexId;
      requireRule(p.buildings[vertex]?.ownerPlayerId === actor && p.buildings[vertex]?.type === 'SETTLEMENT' && player.remainingPieces.cities > 0, 'ILLEGAL_PLACEMENT');
      move(actor, null, COSTS.CITY, 'BUILD_CITY'); p.buildings[vertex]!.type = 'CITY'; player.remainingPieces.settlements++; player.remainingPieces.cities--; activity('CITY_BUILT', 'Upgraded a settlement to a city.'); break;
    }
    case 'BANK_TRADE': {
      phase('ACTION'); active(); const give = payload.giveType as ResourceType, receive = payload.receiveType as ResourceType, count = payload.receiveCount as number;
      requireRule(RESOURCE_TYPES.includes(give) && RESOURCE_TYPES.includes(receive) && give !== receive && Number.isInteger(count) && count >= 1 && count <= 19, 'INVALID_PAYLOAD');
      const cost = emptyResources(), gain = emptyResources(); cost[give] = bankRate(p, actor, give) * count; gain[receive] = count;
      requireRule(bank[receive] >= count, 'BANK_UNAVAILABLE'); move(actor, null, cost, 'BANK_TRADE'); move(null, actor, gain, 'BANK_TRADE'); activity('BANK_TRADE', 'Completed a bank trade.', { give: { ...cost }, receive: { ...gain } }); break;
    }
    case 'PROPOSE_TRADE': {
      phase('ACTION'); const target = payload.targetPlayerId as string | null, give = bundle(payload.give), receive = bundle(payload.receive);
      requireRule(target === null || (target !== actor && Object.hasOwn(privateState, target)), 'FORBIDDEN');
      requireRule(actor === p.activePlayerId || target === p.activePlayerId, 'NOT_YOUR_TURN');
      requireRule(total(give) > 0 && total(receive) > 0 && RESOURCE_TYPES.every(type => !give[type] || !receive[type]), 'INVALID_PAYLOAD');
      requireRule(has(hand.resources, give), 'INSUFFICIENT_RESOURCES');
      for (const offer of Object.values(p.trades)) if (offer.proposerPlayerId === actor && offer.status === 'OPEN') offer.status = 'CANCELLED';
      // Keep only current open offers: public activity is the durable history, not this bounded map.
      p.trades = Object.fromEntries(Object.entries(p.trades).filter(([, t]) => t.status === 'OPEN'));
      const id = random.id('trade-offer'); requireRule(!p.trades[id], 'INVALID_PAYLOAD');
      p.trades[id] = { offerId: id, proposerPlayerId: actor, targetPlayerId: target, give: { ...give }, receive: { ...receive }, revision: 0, turnNumber: p.turnNumber, phaseId: p.phaseId, status: 'OPEN', declinedBy: [] };
      activity('TRADE_PROPOSED', 'Proposed a resource trade.', { subjectPlayerId: target, give: { ...give }, receive: { ...receive } }); break;
    }
    case 'ACCEPT_TRADE': {
      phase('ACTION'); const offer = checkedOffer();
      requireRule(offer.proposerPlayerId !== actor && (offer.targetPlayerId === null || offer.targetPlayerId === actor) && [offer.proposerPlayerId, actor].includes(p.activePlayerId), 'FORBIDDEN');
      requireRule(has(hand.resources, offer.receive) && has(privateState[offer.proposerPlayerId]!.resources, offer.give), 'TRADE_UNAVAILABLE');
      move(offer.proposerPlayerId, actor, offer.give, 'PLAYER_TRADE'); move(actor, offer.proposerPlayerId, offer.receive, 'PLAYER_TRADE'); offer.status = 'ACCEPTED'; activity('TRADE_ACCEPTED', 'Completed a player trade.', { subjectPlayerId: offer.proposerPlayerId, give: { ...offer.receive }, receive: { ...offer.give } }); break;
    }
    case 'DECLINE_TRADE': {
      phase('ACTION'); const offer = checkedOffer();
      requireRule(actor !== offer.proposerPlayerId && (offer.targetPlayerId === null || offer.targetPlayerId === actor) && [offer.proposerPlayerId, actor].includes(p.activePlayerId), 'FORBIDDEN');
      requireRule(!offer.declinedBy.includes(actor), 'TRADE_UNAVAILABLE'); offer.declinedBy.push(actor); offer.revision++; activity('TRADE_DECLINED', 'Declined a trade offer.', { subjectPlayerId: offer.proposerPlayerId }); break;
    }
    case 'CANCEL_TRADE': { phase('ACTION'); const offer = checkedOffer(); requireRule(offer.proposerPlayerId === actor, 'FORBIDDEN'); offer.status = 'CANCELLED'; activity('TRADE_CANCELLED', 'Cancelled a trade offer.'); break; }
    case 'BUY_DEVELOPMENT_CARD': {
      phase('ACTION'); active(); requireRule(state.serverState.developmentDeck.length, 'CARD_NOT_PLAYABLE'); move(actor, null, COSTS.DEVELOPMENT, 'BUY_DEVELOPMENT_CARD');
      const card = state.serverState.developmentDeck.shift()!; card.purchasedOnTurn = p.turnNumber; hand.developmentCards.push(card);
      effects.push({ type: 'DEVELOPMENT_DRAW', playerId: actor, card: { ...card } }); activity('DEVELOPMENT_BOUGHT', 'Bought a development card.'); break;
    }
    case 'PLAY_DEVELOPMENT_CARD': {
      phase('AWAIT_ROLL', 'ACTION'); active(); requireRule(!p.developmentCardPlayedThisTurn, 'CARD_NOT_PLAYABLE');
      const index = hand.developmentCards.findIndex(c => c.id === payload.cardId), card = hand.developmentCards[index];
      requireRule(card && card.type !== 'VICTORY_POINT' && card.purchasedOnTurn < p.turnNumber, 'CARD_NOT_PLAYABLE');
      const choice = payload.choice; requireRule(choice && typeof choice === 'object' && !Array.isArray(choice), 'INVALID_PAYLOAD');
      if (card.type === 'MONOPOLY') {
        requireRule(Object.keys(choice).length === 1 && RESOURCE_TYPES.includes(choice.resourceType as ResourceType), 'INVALID_PAYLOAD');
        const resource = choice.resourceType as ResourceType;
        for (const id of state.serverState.turnOrder) if (id !== actor) { const resources = emptyResources(); resources[resource] = privateState[id]!.resources[resource]; move(id, actor, resources, 'MONOPOLY'); }
      } else if (card.type === 'YEAR_OF_PLENTY') {
        requireRule(Object.keys(choice).length === 1 && Object.hasOwn(choice, 'resources'), 'INVALID_PAYLOAD'); const resources = bundle(choice.resources);
        // v1 resolves the complete two-card choice atomically; no unavailable choice consumes the card.
        requireRule(total(resources) === 2, 'INVALID_PAYLOAD'); move(null, actor, resources, 'YEAR_OF_PLENTY');
      } else requireRule(Object.keys(choice).length === 0, 'INVALID_PAYLOAD');
      if (card.type === 'ROAD_BUILDING') requireRule(legalRoads(p, actor).length > 0, 'CARD_NOT_PLAYABLE');
      hand.developmentCards.splice(index, 1); state.serverState.playedCards.push({ ...card, ownerPlayerId: actor }); p.developmentCardPlayedThisTurn = true;
      effects.push({ type: 'DEVELOPMENT_PLAY', playerId: actor, card: { ...card } }); activity('DEVELOPMENT_PLAYED', `Played ${card.type.toLowerCase().replaceAll('_', ' ')}.`);
      if (card.type === 'KNIGHT') robber(p.phase as 'AWAIT_ROLL' | 'ACTION');
      else if (card.type === 'ROAD_BUILDING') {
        cancelOffers(); state.serverState.effect = { kind: 'ROAD_BUILDING', continuation: p.phase as 'AWAIT_ROLL' | 'ACTION', eligiblePlayerIds: [actor], remainingRoads: Math.min(2, player.remainingPieces.roads) }; enter('ROAD_BUILDING');
      }
      break;
    }
    case 'PLACE_FREE_ROAD': {
      phase('ROAD_BUILDING'); active(); requireRule(state.serverState.effect!.remainingRoads > 0, 'WRONG_PHASE');
      road(payload.edgeId as EdgeId, true); state.serverState.effect!.remainingRoads--;
      if (!state.serverState.effect!.remainingRoads || !legalRoads(p, actor).length) continueEffect(); break;
    }
    case 'FINISH_FREE_ROADS': {
      phase('ROAD_BUILDING'); active(); requireRule(!legalRoads(p, actor).length || state.clockState.turnExpired, 'CARD_NOT_PLAYABLE'); continueEffect(); break;
    }
    case 'END_TURN': {
      phase('ACTION'); active(); cancelOffers(); p.trades = {};
      p.activePlayerId = state.serverState.turnOrder[(state.serverState.turnOrder.indexOf(actor) + 1) % state.serverState.turnOrder.length]!;
      p.turnNumber++; p.hasRolled = false; p.developmentCardPlayedThisTurn = false; p.dice = null; state.clockState.turnExpired = false; enter('AWAIT_ROLL'); activity('TURN_ENDED', 'Ended the turn.'); break;
    }
    default: throw new RuleError('INVALID_PAYLOAD');
  }
  // Nonbinding offers cannot survive loss of stock, phase or active-player participation.
  for (const offer of Object.values(p.trades)) if (offer.status === 'OPEN' && (p.phase !== 'ACTION' || offer.phaseId !== p.phaseId || !has(privateState[offer.proposerPlayerId]!.resources, offer.give))) offer.status = 'EXPIRED';
  refreshDerived(state);
  for (const key of ['longestRoad', 'largestArmy'] as const) if (previous.publicState[key].holderPlayerId !== p[key].holderPlayerId) effects.push({ type: 'AWARD_CHANGED', award: key, ...p[key] });
  if (p.turnNumber > 0 && privateState[p.activePlayerId]!.totalPoints >= 10) {
    p.winnerPlayerId = p.activePlayerId; p.winnerVictoryPointCardIds = privateState[p.activePlayerId]!.developmentCards.filter(c => c.type === 'VICTORY_POINT').map(c => c.id);
    p.finalPoints = Object.fromEntries(Object.values(privateState).map(hand => [hand.playerId, hand.totalPoints]));
    state.serverState.effect = null; for (const hand of Object.values(privateState)) hand.discardRequired = 0;
    state.clockState.deadline = null; state.clockState.discards = {}; p.turnDeadline = null; p.discardDeadlines = {}; cancelOffers(); enter('COMPLETE');
    effects.push({ type: 'PUBLIC_ACTIVITY', actorPlayerId: p.activePlayerId, action: 'GAME_FINISHED', message: 'Reached ten victory points and won the game.' });
  }
  state.version++; assertInvariants(state);
  return { state, effects, randomDraws: random.draws, occurredAt: context.now };
}
