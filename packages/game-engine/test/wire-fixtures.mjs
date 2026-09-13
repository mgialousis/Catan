import { projectGame, refreshDerived } from '../dist/index.js';
import { newGame, setup, asAction, giveCard, resources, act, now } from './helpers.mjs';

/** Synthetic canonical snapshots for the shared TypeScript/Dart conformance suite. */
export function engineWireFixtures() {
  const initial = newGame(3, 777).state;
  const state = asAction(setup(4, 888)), actor = state.publicState.activePlayerId;
  // Nine points: two cities, Largest Army and three hidden VPs.
  for (const b of Object.values(state.publicState.buildings)) if (b.ownerPlayerId === actor) { b.type = 'CITY'; state.publicState.players[actor].remainingPieces.settlements++; state.publicState.players[actor].remainingPieces.cities--; }
  for (let i = 0; i < 3; i++) {
    const cardId = giveCard(state, actor, 'KNIGHT'); const hand = state.privateState[actor].developmentCards;
    state.serverState.playedCards.push({ ...hand.splice(hand.findIndex(c => c.id === cardId), 1)[0], ownerPlayerId: actor }); refreshDerived(state);
  }
  for (let i = 0; i < 3; i++) giveCard(state, actor, 'VICTORY_POINT');
  const deck = state.serverState.developmentDeck; deck.unshift(...deck.splice(deck.findIndex(c => c.type === 'VICTORY_POINT'), 1));
  resources(state, { [actor]: { ore: 1, grain: 1, wool: 1 } });
  const complete = act(state, 'BUY_DEVELOPMENT_CARD').state;
  return [
    { name: 'engine initial 3-player canonical board snapshot', schema: 'gameSnapshot', valid: true, value: projectGame(initial, initial.publicState.activePlayerId, now) },
    { name: 'engine completed 4-player winner reveal snapshot', schema: 'gameSnapshot', valid: true, value: projectGame(complete, actor, now) },
  ];
}
