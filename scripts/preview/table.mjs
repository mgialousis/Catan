// Development/test harness only. Never imported by apps/server or the shipped Flutter entry point.
import { randomUUID } from 'node:crypto';
import { applyCommand, canSettle, canRoad, legalRoads, projectGame, projectEffects, assertInvariants, refreshDerived, PHASE_TRANSITIONS, emptyResources } from '@island/game-engine';
import { isValid } from '@island/protocol';
import { newGame, setup, asAction, clearHands, resources, giveCard, roll, act, command, seeded, now } from '../../packages/game-engine/test/helpers.mjs';
export const scenarios = ['setup', 'action', 'discard', 'robber', 'free-roads', 'waiting', 'paused', 'results', 'victory'];
export function scenario(name, seed = 42) {
  if (!scenarios.includes(name)) throw new Error('Unknown practice scenario');
  let state = name === 'setup' ? newGame(4, seed).state : clearHands(setup(4, seed));
  const viewer = state.publicState.activePlayerId;
  for (const [i, p] of Object.values(state.publicState.players).entries()) p.nickname = ['Mira', 'Theo', 'Noor', 'Leo'][i];
  if (name !== 'setup') {
    const ids = state.serverState.turnOrder;
    resources(state, Object.fromEntries(ids.map(id => [id, id === viewer ? { brick: 4, lumber: 4, wool: 4, grain: 4, ore: 4 } : { brick: 1, lumber: 1, wool: 1, grain: 1, ore: 1 }])));
    if (['action', 'waiting', 'paused', 'victory', 'results'].includes(name)) asAction(state);
    if (['action', 'waiting', 'paused'].includes(name)) for (const type of ['KNIGHT', 'ROAD_BUILDING', 'MONOPOLY', 'YEAR_OF_PLENTY', 'VICTORY_POINT']) giveCard(state, viewer, type);
    if (name === 'waiting') {
      state.publicState.activePlayerId = ids[1]; state.publicState.requiredPlayerIds = [ids[1]];
      state = act(state, 'PROPOSE_TRADE', { targetPlayerId: viewer, give: { ...emptyResources(), ore: 1 }, receive: { ...emptyResources(), brick: 1 } }).state;
    }
    if (name === 'discard') state = roll(state, 3, 4).state;
    if (name === 'robber') { resources(state, { [viewer]: {} }); state = roll(state, 3, 4).state; }
    if (name === 'free-roads') { const cardId = giveCard(state, viewer, 'ROAD_BUILDING'); state = act(state, 'PLAY_DEVELOPMENT_CARD', { cardId, choice: {} }).state; }
    if (name === 'paused') state.publicState.pauseReasons = ['MANUAL'];
    if (name === 'victory' || name === 'results') {
      for (const b of Object.values(state.publicState.buildings)) if (b.ownerPlayerId === viewer) { b.type = 'CITY'; state.publicState.players[viewer].remainingPieces.cities--; state.publicState.players[viewer].remainingPieces.settlements++; }
      refreshDerived(state);
      for (let i = 0; i < 3; i++) {
        const cardId = giveCard(state, viewer, 'KNIGHT'); const hand = state.privateState[viewer].developmentCards;
        state.serverState.playedCards.push({ ...hand.splice(hand.findIndex(c => c.id === cardId), 1)[0], ownerPlayerId: viewer }); refreshDerived(state);
      }
      for (let i = 0; i < 3; i++) giveCard(state, viewer, 'VICTORY_POINT');
      const deck = state.serverState.developmentDeck; deck.unshift(...deck.splice(deck.findIndex(c => c.type === 'VICTORY_POINT'), 1));
      if (name === 'results') state = act(state, 'BUY_DEVELOPMENT_CARD').state;
    }
  }
  assertInvariants(state); return { state, viewer };
}
export class PracticeTable {
  constructor(name = 'setup', seed = 42) {
    Object.assign(this, scenario(name, seed)); this.random = seeded(seed + 5000); this.receipts = new Map(); this.history = [];
  }
  snapshot() { return projectGame(this.state, this.viewer, new Date().toISOString()); }
  transition(actor, cmd) {
    const before = this.state.publicState.phase;
    const result = applyCommand(this.state, actor, cmd, { random: this.random, now: new Date().toISOString() });
    const after = result.state.publicState.phase;
    if (before !== after && !PHASE_TRANSITIONS[before].includes(after)) throw new Error('Invalid phase graph');
    this.state = result.state;
    const effects = projectEffects(result.effects, this.viewer);
    const activity = effects.activity.map(e => `${e.actorPlayerId ? this.state.publicState.players[e.actorPlayerId].nickname + ': ' : ''}${e.message}`);
    this.history.push(...activity); this.history = this.history.slice(-100);
    return { activity, draws: effects.drawnCards.map(c => c.type) };
  }
  submit(cmd) {
    if (!isValid('gameCommand', cmd)) return { commandId: cmd?.commandId ?? randomUUID(), status: 'REJECTED', error: { code: 'INVALID_PAYLOAD', retryable: false } };
    const saved = this.receipts.get(cmd.commandId);
    if (saved) return saved.input === JSON.stringify(cmd) ? { ...saved.reply, activity: [], draws: [] } : { commandId: cmd.commandId, status: 'REJECTED', error: { code: 'COMMAND_ID_REUSED', retryable: false } };
    let reply;
    const previous = this.state, history = [...this.history];
    try {
      const effects = this.transition(this.viewer, cmd);
      const auto = this.autoplay();
      reply = { commandId: cmd.commandId, status: 'ACCEPTED', version: this.state.version, activity: [...effects.activity, ...auto.activity], draws: [...effects.draws, ...auto.draws] };
    } catch (e) { this.state = previous; this.history = history; if (!e.code) throw e; reply = { commandId: cmd.commandId, status: 'REJECTED', error: { code: e.code, retryable: false } }; }
    this.receipts.set(cmd.commandId, { input: JSON.stringify(cmd), reply });
    return reply;
  }
  autoplay() {
    const result = { activity: [], draws: [] };
    for (let moves = 0; moves < 100; moves++) {
      const p = this.state.publicState;
      if (p.phase === 'COMPLETE' || p.pauseReasons.length) break;
      let actor = p.activePlayerId, type, payload = {};
      if (p.phase === 'DISCARD_REQUIRED') {
        actor = p.requiredPlayerIds.find(id => id !== this.viewer);
        if (!actor) break;
        let n = this.state.privateState[actor].discardRequired; const chosen = emptyResources();
        for (const r of Object.keys(chosen)) { chosen[r] = Math.min(n, this.state.privateState[actor].resources[r]); n -= chosen[r]; }
        type = 'DISCARD_RESOURCES'; payload = { resources: chosen };
      } else if (actor === this.viewer) break;
      else if (p.phase === 'SETUP_SETTLEMENT') { type = 'PLACE_SETUP_SETTLEMENT'; payload = { vertexId: Object.keys(p.board.vertices).find(v => canSettle(p, actor, v, true)) }; }
      else if (p.phase === 'SETUP_ROAD') { type = 'PLACE_SETUP_ROAD'; payload = { edgeId: p.board.vertices[this.state.serverState.setup.pendingVertexId].edgeIds.find(e => canRoad(p, actor, e)) }; }
      else if (p.phase === 'AWAIT_ROLL') type = 'ROLL_DICE';
      else if (p.phase === 'ROBBER_MOVE') { type = 'MOVE_ROBBER'; payload = { hexId: Object.keys(p.board.hexes).find(h => h !== p.robberHexId) }; }
      else if (p.phase === 'ROBBER_VICTIM') { type = 'CHOOSE_ROBBER_VICTIM'; payload = { victimPlayerId: this.state.serverState.effect.eligiblePlayerIds[0] }; }
      else if (p.phase === 'ACTION') {
        const offer = Object.values(p.trades).find(o => o.status === 'OPEN' && o.proposerPlayerId === this.viewer && (o.targetPlayerId === null || o.targetPlayerId === actor) && Object.keys(o.receive).every(r => this.state.privateState[actor].resources[r] >= o.receive[r]));
        if (offer) { type = 'ACCEPT_TRADE'; payload = { offerId: offer.offerId, offerRevision: offer.revision }; } else type = 'END_TURN';
      } else throw new Error('Unhandled practice obligation');
      const next = this.transition(actor, command(this.state, type, payload)); result.activity.push(...next.activity); result.draws.push(...next.draws);
    }
    return result;
  }
}
