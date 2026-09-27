import test from 'node:test';
import assert from 'node:assert/strict';
import { chooseCommand, projectPlayer, emptyResources, bankRate, assertInvariants, isDiscard } from '../dist/index.js';
import { setup, asAction, resources, giveCard, act, roll } from './helpers.mjs';

const view = (state, actor=state.publicState.activePlayerId) => ({publicState:state.publicState,hand:projectPlayer(state,actor)});
const hints = state => ({bankStock:state.serverState.bank,developmentCardsRemaining:state.serverState.developmentDeck.length,pendingSetupVertexId:state.serverState.setup?.pendingVertexId});
const choose = (s,d='HARD',actor=s.publicState.activePlayerId) => chooseCommand(view(s,actor),hints(s),d,42);
function apply(s,move,actor=s.publicState.activePlayerId) { const next=act(s,move.type,move.payload,actor).state;assertInvariants(next);return next; }

test('Medium uses a resource port when a 2:1 trade unlocks a city', () => {
  const s=asAction(setup()), me=s.publicState.activePlayerId;
  // Preserve topology; put an existing settlement at the ore port for this scenario.
  const port=Object.values(s.publicState.board.ports).find(p=>p.resourceType==='ore');
  const own=Object.keys(s.publicState.buildings).find(v=>s.publicState.buildings[v].ownerPlayerId===me);
  delete s.publicState.buildings[own];s.publicState.buildings[port.vertexIds[0]]={ownerPlayerId:me,type:'SETTLEMENT'};
  resources(s,{[me]:{ore:5,grain:1}});
  assert.equal(bankRate(s.publicState,me,'ore'),2);
  const move=choose(s,'MEDIUM');
  assert.equal(move.type,'BANK_TRADE');assert.deepEqual(move.payload,{giveType:'ore',receiveType:'grain',receiveCount:1});
  assert.equal(choose(apply(s,move),'MEDIUM').type,'BUILD_CITY');
});

test('Medium declines a one-for-two offer instead of losing cards', () => {
  let s=asAction(setup());const proposer=s.publicState.activePlayerId, me=Object.keys(s.privateState).find(id=>id!==proposer);
  resources(s,{[proposer]:{ore:1},[me]:{grain:2}});
  s=act(s,'PROPOSE_TRADE',{targetPlayerId:me,give:{...emptyResources(),ore:1},receive:{...emptyResources(),grain:2}}).state;
  assert.equal(choose(s,'MEDIUM',me).type,'DECLINE_TRADE');
});

test('Hard chooses Year of Plenty to finish a city and respects bank shortages', () => {
  let s=asAction(setup());const me=s.publicState.activePlayerId;
  resources(s,{[me]:{ore:2,grain:1}});giveCard(s,me,'YEAR_OF_PLENTY');
  const move=choose(s);assert.equal(move.type,'PLAY_DEVELOPMENT_CARD');
  assert.deepEqual(move.payload.choice.resources,{...emptyResources(),ore:1,grain:1});
  s=apply(s,move);assert.equal(choose(s).type,'BUILD_CITY');
  const other=asAction(setup());giveCard(other,other.publicState.activePlayerId,'YEAR_OF_PLENTY');
  const unavailable={...hints(other),bankStock:{brick:0,lumber:0,wool:0,grain:0,ore:2}};
  const only=chooseCommand(view(other),unavailable,'HARD',1);
  assert.equal(only.type,'PLAY_DEVELOPMENT_CARD');assert.deepEqual(only.payload.choice.resources,{...emptyResources(),ore:2});
});

test('Hard moves a robber blocking its own production before rolling', () => {
  const s=setup(),me=s.publicState.activePlayerId;
  const vertex=Object.keys(s.publicState.buildings).find(v=>s.publicState.buildings[v].ownerPlayerId===me);
  s.publicState.robberHexId=s.publicState.board.vertices[vertex].hexIds[0];giveCard(s,me,'KNIGHT');
  const move=choose(s);assert.equal(move.type,'PLAY_DEVELOPMENT_CARD');
  assert.equal(choose(s,'MEDIUM').type,'ROLL_DICE');apply(s,move);
});

test('Hard discards surplus and keeps a complete city', () => {
  let s=setup();const me=s.publicState.activePlayerId;
  resources(s,{[me]:{ore:3,grain:2,brick:5}});s=roll(s,3,4).state;
  const move=choose(s);assert.equal(move.type,'DISCARD_RESOURCES');assert.ok(isDiscard(projectPlayer(s,me),move.payload.resources));
  assert.equal(move.payload.resources.ore,0);assert.equal(move.payload.resources.grain,0);apply(s,move);
});

test('Hard decisions do not mutate input or depend on rival private card composition', () => {
  const s=asAction(setup()), me=s.publicState.activePlayerId, other=Object.keys(s.privateState).find(id=>id!==me);
  resources(s,{[me]:{grain:1,wool:1,ore:1},[other]:{brick:2}});
  const v=view(s),before=structuredClone(v),legalHints=hints(s),first=chooseCommand(v,legalHints,'HARD',71);
  resources(s,{[other]:{ore:2}});
  assert.deepEqual(chooseCommand(view(s),legalHints,'HARD',71),first);
  assert.deepEqual(v,before);
});

test('Hard plans a two-trade conversion to a city', () => {
  let s=asAction(setup());const me=s.publicState.activePlayerId;
  resources(s,{[me]:{ore:3,lumber:bankRate(s.publicState,me,'lumber')*2}});
  for(let i=0;i<2;i++) {
    const move=choose(s);assert.equal(move.type,'BANK_TRADE');
    assert.equal(move.payload.giveType,'lumber');assert.equal(move.payload.receiveType,'grain');s=apply(s,move);
  }
  assert.equal(choose(s).type,'BUILD_CITY');
});


test('Hard follows a two-road route to a settlement instead of scattering roads', () => {
  let s=asAction(setup());const me=s.publicState.activePlayerId;
  resources(s,{[me]:{brick:4,lumber:4,wool:1,grain:1}});
  for (const expected of ['BUILD_ROAD','BUILD_ROAD','BUILD_SETTLEMENT']) {
    const move=choose(s);assert.equal(move.type,expected);s=apply(s,move);
  }
});
