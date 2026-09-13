import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { scenario } from './preview/table.mjs';
import { applyCommand, projectGame, canSettle, canRoad } from '../packages/game-engine/dist/index.js';
import { command, seeded, now } from '../packages/game-engine/test/helpers.mjs';
import { pauseState } from '../apps/server/dist/game-clock.js';
import { gameDelta } from '../apps/server/dist/game-delta.js';
export function gameWireFixtures() {
  const fixtures=[];
  for(const name of ['setup','action','victory']) {
    let {state}=scenario(name);
    const random=seeded(131);
    const actions=name==='setup'?['PLACE_SETUP_SETTLEMENT','PLACE_SETUP_ROAD']:name==='victory'?['BUY_DEVELOPMENT_CARD']:['BUILD_ROAD','BUILD_CITY','BUY_DEVELOPMENT_CARD','END_TURN','ROLL_DICE'];
    for(const type of actions) {
      const p=state.publicState,actor=p.activePlayerId;
      const payload=type==='PLACE_SETUP_SETTLEMENT'?{vertexId:Object.keys(p.board.vertices).find(v=>canSettle(p,actor,v,true))}:type==='PLACE_SETUP_ROAD'?{edgeId:p.board.vertices[state.serverState.setup.pendingVertexId].edgeIds.find(e=>canRoad(p,actor,e))}:type==='BUILD_ROAD'?{edgeId:Object.keys(p.board.edges).find(e=>canRoad(p,actor,e))}:type==='BUILD_CITY'?{vertexId:Object.keys(p.buildings).find(v=>p.buildings[v].ownerPlayerId===actor)}:{};
      const result=applyCommand(state,actor,command(state,type,payload),{now,random});
      for(const viewer of Object.keys(state.privateState)) fixtures.push({name:`${name}/${type}/${viewer}`,before:projectGame(state,viewer,now),delta:gameDelta(state,result.state,viewer,result.effects,now),after:projectGame(result.state,viewer,now)});
      state=result.state;
    }
  }
  // Clock/pause fields pass through the same production owner projection and Dart patcher.
  for (const phase of ['action','discard']) {
    let {state}=scenario(phase);const random=seeded(551);
    state.clockState.turnLimitSeconds=60;state.clockState.remainingTurnMs=60000;
    if(phase==='action'){state.clockState.deadline='2026-09-10T12:01:00.000Z';state.publicState.turnDeadline=state.clockState.deadline;}
    else {
      state.clockState.discards=Object.fromEntries(state.publicState.requiredPlayerIds.map(id=>[id,{deadline:'2026-09-10T12:00:30.000Z',remainingMs:30000,generation:random.id()}]));
      state.publicState.discardDeadlines=Object.fromEntries(Object.entries(state.clockState.discards).map(([id,d])=>[id,d.deadline]));
    }
    for(const [label,reasons,time] of [['pause',['DISCONNECTED'],'2026-09-10T12:00:07.000Z'],['resume',[],'2026-09-10T12:02:00.000Z']]) {
      const next=pauseState(state,reasons,time,random);
      for(const viewer of Object.keys(state.privateState))fixtures.push({name:`clock/${phase}/${label}/${viewer}`,before:projectGame(state,viewer,now),delta:gameDelta(state,next,viewer,[],time),after:projectGame(next,viewer,time)});
      state=next;
    }
  }
  return fixtures;
}
if(process.argv[1]===fileURLToPath(import.meta.url)) writeFileSync('packages/protocol/fixtures/game-deltas.json','[\n'+gameWireFixtures().map(v=>JSON.stringify(v)).join(',\n')+'\n]\n');
