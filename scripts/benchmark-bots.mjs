/** Finite, deterministic strength/CPU sample. Run after npm run build. No network or database. */
import { performance } from 'node:perf_hooks';
import { applyCommand, assertInvariants, chooseCommand, projectPlayer, seedFrom } from '../packages/game-engine/dist/index.js';
import { newGame, now, seeded, uuid } from '../packages/game-engine/test/helpers.mjs';
const seeds = [7, 11, 23, 42, 99, 137];
const durations = [], games = [];
for (const seed of seeds) for (let seat = 0; seat < 4; seat++) {
  let {state} = newGame(4, seed);
  const hardPlayer = state.serverState.turnOrder[seat];
  let steps = 0;
  for (; steps < 6000 && state.publicState.phase !== 'COMPLETE'; steps++) {
    const actor = state.publicState.requiredPlayerIds[0] ?? state.publicState.activePlayerId;
    const difficulty = actor === hardPlayer ? 'HARD' : 'MEDIUM';
    const start = performance.now();
    const move = chooseCommand({publicState:state.publicState,hand:projectPlayer(state,actor)}, {
      developmentCardsRemaining:state.serverState.developmentDeck.length,
      pendingSetupVertexId:state.serverState.setup?.pendingVertexId,
      eligibleVictimIds:state.serverState.effect?.eligiblePlayerIds,
      bankStock:state.serverState.bank,
    }, difficulty, seedFrom(seed,state.version,state.publicState.phaseId,actor));
    if (difficulty === 'HARD') durations.push(performance.now()-start);
    if (!move) throw Error(`No move: seed ${seed}, seat ${seat}, ${state.publicState.phase}`);
    state = applyCommand(state,actor,{protocolVersion:1,commandId:uuid(100000000+steps),roomId:state.roomId,expectedVersion:state.version,expectedPhaseId:state.publicState.phaseId,type:move.type,payload:move.payload},{now,random:seeded(seed+steps)}).state;
    assertInvariants(state);
  }
  games.push({seed,hardSeat:seat,steps,finished:state.publicState.phase==='COMPLETE',hardWon:state.publicState.winnerPlayerId===hardPlayer});
}
durations.sort((a,b)=>a-b);
console.log(JSON.stringify({scope:'One Hard vs three Medium; six fixed boards, all four seats. Diagnostic sample, not a general win-rate guarantee.',games:games.length,completed:games.filter(g=>g.finished).length,hardWins:games.filter(g=>g.hardWon).length,hardDecisionMs:{count:durations.length,median:durations[Math.floor(durations.length/2)],p95:durations[Math.ceil(durations.length*.95)-1],max:durations.at(-1)},results:games},null,2));
if (games.some(g=>!g.finished)) process.exitCode=1;
