import test from 'node:test';
import assert from 'node:assert/strict';
import { advanceClock, pauseState, timerJobs, matchesJob, fallback, assertClock, dueFor } from '../dist/game-clock.js';
import { applyCommand, assertInvariants, canRoad } from '../../../packages/game-engine/dist/index.js';
import { setup, seeded, command, resources, giveCard, asAction } from '../../../packages/game-engine/test/helpers.mjs';
const base='2026-09-11T12:00:00.000Z',at=n=>new Date(Date.parse(base)+n).toISOString();
function timed() {
  const state=setup();state.clockState.turnLimitSeconds=60;state.clockState.remainingTurnMs=60000;
  const previous=structuredClone(state);previous.publicState.turnNumber=0;
  return advanceClock(previous,state,base,seeded(990));
}
const movesRandom=seeded(501);
function move(state,type,payload={},time=0,actor=state.publicState.activePlayerId,random=movesRandom) {
  const result=applyCommand(state,actor,command(state,type,payload),{now:at(time),random});
  return advanceClock(state,result.state,at(time),random);
}
function dice(a,b) {const rng=seeded(877);let i=0;return {id:()=>rng.id(),int:max=>max===6?[a-1,b-1][i++]:rng.int(max)};}
test('a turn starts once, ordinary phase/action moves retain its deadline',()=>{
  let state=timed();assertClock(state);assert.equal(state.clockState.deadline,at(60000));
  state=move(state,'ROLL_DICE',{},12000,undefined,dice(2,3));assert.equal(state.clockState.deadline,at(60000));
  state=move(state,'END_TURN',{},20000);assert.equal(state.clockState.deadline,at(80000));assertClock(state);
});
test('pause/reconnect cannot reset budgets; checkpoints are bounded by the clock start',()=>{
  const state=timed(),random=seeded(9),paused=pauseState(state,['DISCONNECTED'],at(17000),random);
  assert.equal(paused.clockState.remainingTurnMs,43000);assert.equal(paused.publicState.turnDeadline,null);
  const manual=pauseState(paused,['MANUAL','DISCONNECTED'],at(90000),random);
  const resumed=pauseState(manual,[],at(120000),random);assert.equal(resumed.clockState.deadline,at(163000));assertClock(resumed);
  const recovered=pauseState(state,['RECOVERY'],at(-90000),random);assert.equal(recovered.clockState.remainingTurnMs,60000);
  assert.equal(matchesJob(resumed,timerJobs(state)[0]),false);
});
test('the seven barrier suspends budget and keeps independent stable discard jobs',()=>{
  let state=timed();const ids=Object.keys(state.privateState);
  state=resources(state,{[ids[0]]:{brick:8},[ids[1]]:{lumber:8}});
  state=move(state,'ROLL_DICE',{},10000,undefined,dice(3,4));assertClock(state);
  assert.equal(state.clockState.remainingTurnMs,50000);assert.equal(state.clockState.deadline,null);
  const jobs=timerJobs(state);assert.equal(jobs.length,2);assert.equal(jobs[0].deadline,at(40000));
  const actor=jobs[0].playerId,bundle={brick:0,lumber:0,wool:0,grain:0,ore:0};bundle[actor===ids[0]?'brick':'lumber']=4;
  state=move(state,'DISCARD_RESOURCES',{resources:bundle},20000,actor);assert.equal(matchesJob(state,jobs[1]),true);
  const last=fallback(state,jobs[1].commandId,0,at(40000),seeded(14),jobs[1].playerId);
  state=last.result.state;assert.equal(state.clockState.turnExpired,false);assert.equal(state.clockState.deadline,at(90000));assertClock(state);
});
test('automatic seven grants discard windows and preserves an expired turn through the barrier',()=>{
  let state=timed();const ids=Object.keys(state.privateState);state=resources(state,{[ids[1]]:{ore:9}});
  const job=timerJobs(state)[0],rolled=fallback(state,job.commandId,0,at(60000),dice(3,4));state=rolled.result.state;
  assert.equal(state.publicState.phase,'DISCARD_REQUIRED');assert.equal(state.clockState.turnExpired,true);
  assert.equal(state.clockState.remainingTurnMs,0);assert.equal(timerJobs(state)[0].deadline,at(90000));
  const discard=fallback(state,job.commandId,1,at(90000),seeded(18),ids[1]);state=discard.result.state;
  assert.equal(state.publicState.phase,'ROBBER_MOVE');assert.equal(state.clockState.turnExpired,true);assert.equal(state.clockState.deadline,at(90000));
  for(let step=2;state.clockState.turnExpired;step++){assert.ok(step<8);state=fallback(state,job.commandId,step,at(90000),seeded(100+step)).result.state;assertInvariants(state);}
  assert.equal(state.publicState.turnNumber,2);assert.equal(state.clockState.deadline,at(150000));
});
for(const phase of ['AWAIT_ROLL','ACTION','ROBBER_MOVE','ROBBER_VICTIM','ROAD_BUILDING']) test(`timeout continues legally from ${phase}`,()=>{
  let state=timed();const actor=state.publicState.activePlayerId;
  if(phase==='ACTION')state=move(state,'ROLL_DICE',{},0,undefined,dice(1,1));
  if(phase.startsWith('ROBBER')){const card=giveCard(state,actor,'KNIGHT');state=move(state,'PLAY_DEVELOPMENT_CARD',{cardId:card,choice:{}});if(phase==='ROBBER_VICTIM'){
    const other=Object.keys(state.privateState).find(id=>id!==actor);state=resources(state,{[other]:{brick:1}});
    const building=Object.entries(state.publicState.buildings).find(([,v])=>v.ownerPlayerId===other)[0];
    const hex=state.publicState.board.vertices[building].hexIds.find(id=>id!==state.publicState.robberHexId);state=move(state,'MOVE_ROBBER',{hexId:hex});
  }}
  if(phase==='ROAD_BUILDING'){
    const card=giveCard(state,actor,'ROAD_BUILDING');state=move(state,'PLAY_DEVELOPMENT_CARD',{cardId:card,choice:{}});
    const edge=Object.keys(state.publicState.board.edges).find(e=>canRoad(state.publicState,actor,e));state=move(state,'PLACE_FREE_ROAD',{edgeId:edge});
  }
  assert.equal(state.publicState.phase,phase);const roads=Object.keys(state.publicState.roads).length,job=timerJobs(state)[0];
  for(let step=0;step<10;step++){state=fallback(state,job.commandId,step,at(60000),seeded(704+step)).result.state;assertClock(state);if(!state.clockState.turnExpired||state.publicState.phase==='DISCARD_REQUIRED')break;}
  assert.equal(Object.keys(state.publicState.roads).length,roads);assert.equal(state.publicState.turnNumber,2);
});
test('no timeout for setup, paused, or timer-off games, and malformed clocks fail closed',()=>{
  const off=setup();assert.deepEqual(timerJobs(off),[]);
  let state=timed();assert.equal(dueFor(state,state.publicState.activePlayerId,at(59999)),false);assert.equal(dueFor(state,state.publicState.activePlayerId,at(60000)),true);
  state=pauseState(state,['MANUAL'],at(1000),seeded(7));assert.deepEqual(timerJobs(state),[]);
  state.clockState.remainingTurnMs=90000;assert.throws(()=>assertClock(state),/persisted clock/);
});
