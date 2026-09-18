import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { io } from 'socket.io-client';
import { createApp } from '../../apps/server/dist/app.js';
import { loadConfig } from '../../apps/server/dist/config.js';
import { Games } from '../../apps/server/dist/games.js';
import { Rooms } from '../../apps/server/dist/rooms.js';
import { isValid } from '../../packages/protocol/dist/index.js';
import { applyCommand, canRoad, canSettle, bankRate, replayRandom, assertInvariants, projectGame } from '../../packages/game-engine/dist/index.js';
import { resources, asAction, giveCard } from '../../packages/game-engine/test/helpers.mjs';
import { Database } from '../../apps/server/dist/database.js';
import { timerJobs, nextDeadline, advanceClock, pauseState, assertClock } from '../../apps/server/dist/game-clock.js';
import { seeded, roll } from '../../packages/game-engine/test/helpers.mjs';
import { scenario } from '../../scripts/preview/table.mjs';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
if (!['127.0.0.1', 'localhost'].includes(new URL(local.adminDatabaseUrl).hostname)) throw new Error('Local only');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(check, ms = 7000) { for (const end = Date.now() + ms; Date.now() < end;) { if (await check()) return; await sleep(25); } assert.fail('Expected state did not arrive'); }
function patch(target, operations) { for (const p of operations) { const keys = p.path.slice(1).split('/'); let parent = target; for (const key of keys.slice(0, -1)) parent = parent[key]; if (p.op === 'remove') delete parent[keys.at(-1)]; else parent[keys.at(-1)] = structuredClone(p.value); } }

test('persisted timers and recovery with four authenticated phones', { timeout: 180000 }, async t => {
  const admin = new Client({ connectionString: local.adminDatabaseUrl }); await admin.connect();
  let app, base, roomId, invite, games, clients, state;
  const faults = {};
  const guests = [], sockets = [], rooms = [];
  async function connect(guest) {
    const socket = io(`${base}/game`, { transports: ['websocket'], reconnection: false, autoConnect: false, forceNew: true,
      auth: { accessToken: guest.access_token, protocolVersion: 1, clientInstanceId: randomUUID() } });
    sockets.push(socket);
    const client = { socket, guest, wire: [], deltas: [], errors: [], drop: false };
    socket.on('session.membership', v => { client.playerId = v.playerId; });
    socket.on('room.snapshot', v => { client.room = v; });
    socket.on('session.error', v => client.errors.push(v));
    socket.on('game.snapshot', v => { assert.ok(isValid('gameSnapshot', v)); client.wire.push(v); if (!client.drop) client.view = v; });
    socket.on('game.delta', v => {
      assert.ok(isValid('gameDelta', v)); client.wire.push(v); client.deltas.push(v);
      if (client.drop || !client.view || v.toVersion <= client.view.version) return;
      if (v.fromVersion !== client.view.version) { client.gap = true; return; }
      const next = structuredClone(client.view); patch(next.publicState, v.publicPatch); patch(next.privateState, v.privatePatch);
      next.version = v.toVersion; next.serverTime = v.serverTime; assert.ok(isValid('gameSnapshot', next)); client.view = next;
    });
    const hello = new Promise((resolve, reject) => { socket.once('server.hello', resolve); socket.once('connect_error', reject); });
    socket.connect(); await hello; return client;
  }
  async function readState() {
    const row = (await admin.query('SELECT * FROM app.game_states WHERE room_id=$1', [roomId])).rows[0];
    return { roomId, version: row.version, rulesVersion: row.rules_version, stateSchemaVersion: row.schema_version, protocolVersion: 1,
      publicState: row.public_state, privateState: row.private_state, serverState: row.server_state, clockState: row.clock_state };
  }
  function command(s, type, payload = {}) { return { protocolVersion: 1, commandId: randomUUID(), roomId, expectedVersion: s.version, expectedPhaseId: s.publicState.phaseId, type, payload }; }
  async function roomCommand(c, type, payload = {}, initial = false) {
    const revision = initial ? null : (await admin.query('SELECT revision FROM app.rooms WHERE id=$1', [roomId])).rows[0].revision;
    return c.socket.timeout(6000).emitWithAck('room.command', { protocolVersion: 1, commandId: randomUUID(), roomId: initial ? null : roomId, expectedVersion: revision, expectedPhaseId: null, type, payload });
  }
  async function send(c, cmd) { assert.ok(isValid('gameCommand',cmd),`Invalid test command ${cmd.type}`); const ack = await c.socket.timeout(6000).emitWithAck('game.command', cmd); assert.ok(isValid('ack', ack)); return ack; }
  function active(s) { return clients.find(c => c.playerId === s.publicState.activePlayerId); }
  async function converge() {
    state = await readState();
    await until(async () => { state = await readState(); return clients.every(c => c.view?.version === state.version); });
    for (const c of clients) assert.deepEqual(c.view, projectGame(state, c.playerId, c.view.serverTime));
    assertInvariants(state);
  }
  async function sync(c) { c.socket.emit('game.sync', { requestId: randomUUID(), roomId, lastGameVersion: c.view?.version ?? null }); }
  async function seed(next) {
    assertInvariants(next); assertClock(next);
    await quiesce(); await games.flush();
    await admin.query("UPDATE app.rooms SET status=$2 WHERE id=$1",[roomId,next.publicState.pauseReasons.length?'PAUSED':'ACTIVE']);
    await admin.query(`UPDATE app.game_states SET version=$2,phase=$3,phase_id=$4,turn_number=$5,active_player_id=$6,public_state=$7,private_state=$8,server_state=$9,clock_state=$10,next_deadline_at=$11,updated_at=clock_timestamp() WHERE room_id=$1`,
      [roomId,next.version,next.publicState.phase,next.publicState.phaseId,next.publicState.turnNumber,next.publicState.activePlayerId,next.publicState,next.privateState,next.serverState,next.clockState,nextDeadline(next)]);
    for (const c of clients) await sync(c);
    await sleep(80); state = next;
  }
  async function quiesce() { await until(()=>!games.ticking); clearTimeout(games.runtimeTimer); }
  async function fixture(phase='AWAIT_ROLL', deadline=Date.now()+60000) {
    let s=structuredClone(initial); s.version=(await readState()).version;
    s.clockState.deadline=new Date(deadline).toISOString();s.publicState.turnDeadline=s.clockState.deadline;
    s.clockState.generation=randomUUID();
    if(phase==='ACTION')asAction(s);
    if(phase==='DISCARD_REQUIRED') {
      s=resources(s,{[clients[0].playerId]:{brick:8},[clients[1].playerId]:{lumber:8}});
      const rolled=roll(s,3,4).state;s=advanceClock(s,rolled,new Date().toISOString(),seeded(99));s.version=(await readState()).version;
    }
    if(phase==='ROAD_BUILDING'||phase.startsWith('ROBBER')) {
      const actor=s.publicState.activePlayerId,cardId=giveCard(s,actor,phase==='ROAD_BUILDING'?'ROAD_BUILDING':'KNIGHT');
      s=applyCommand(s,actor,command(s,'PLAY_DEVELOPMENT_CARD',{cardId,choice:{}}),{now:new Date().toISOString(),random:seeded(101)}).state;
      if(phase==='ROBBER_VICTIM') {
        const other=clients.find(c=>c.playerId!==actor).playerId;s=resources(s,{[other]:{ore:1}});
        const vertex=Object.entries(s.publicState.buildings).find(([,b])=>b.ownerPlayerId===other)[0];
        const hexId=s.publicState.board.vertices[vertex].hexIds.find(id=>id!==s.publicState.robberHexId);
        s=applyCommand(s,actor,command(s,'MOVE_ROBBER',{hexId}),{now:new Date().toISOString(),random:seeded(102)}).state;
      }
      s.version=(await readState()).version;
    }
    await seed(s);return s;
  }
  let initial;
  try {
    assert.equal((await admin.query('SELECT count(*)::int n FROM app.rooms WHERE active_slot=1')).rows[0].n,0,'Close local preview rooms first');
    app=await createApp({...loadConfig(),port:0});await app.listen(0,'127.0.0.1');base=await app.getUrl();games=app.get(Games);
    for(let i=0;i<4;i++) {
      const response=await fetch(`${local.apiUrl}/auth/v1/signup`,{method:'POST',headers:{apikey:local.anonKey,'Content-Type':'application/json'},body:'{}'});
      assert.equal(response.status,200);guests.push(await response.json());
    }
    clients=await Promise.all(guests.map(connect));
    const created=await roomCommand(clients[0],'CREATE_ROOM',{nickname:'Timer host',settings:{maxPlayers:4,turnLimitSeconds:60,boardMode:'STANDARD_RANDOM',rulesVersion:'base-2020-v1'}},true);
    assert.equal(created.status,'ACCEPTED');roomId=created.roomId;invite=created.result.invitationCode;rooms.push(roomId);
    for(const [i,c] of clients.slice(1).entries())assert.equal((await roomCommand(c,'JOIN_ROOM',{nickname:`Timer guest ${i}`,invitationCode:invite},true)).status,'ACCEPTED');
    for(const c of clients)assert.equal((await roomCommand(c,'SET_READY',{ready:true})).status,'ACCEPTED');
    await t.test('timed start leaves setup untimed; first turn gets exactly one budget',async()=>{
      assert.equal((await roomCommand(clients[0],'START_GAME')).status,'ACCEPTED');await converge();assert.equal(nextDeadline(state),null);
      const setupIndex=clients.findIndex(c=>c.playerId===state.publicState.activePlayerId);clients[setupIndex].socket.disconnect();
      await until(async()=> (await readState()).publicState.pauseReasons.includes('DISCONNECTED'));assert.equal(nextDeadline(await readState()),null);
      clients[setupIndex]=await connect(guests[setupIndex]);await until(async()=>!(await readState()).publicState.pauseReasons.length);await converge();
      let checkedRoadDisconnect=false;
      while(state.serverState.setup) {
        if(state.publicState.phase==='SETUP_ROAD'&&!checkedRoadDisconnect){
          const i=clients.findIndex(c=>c.playerId===state.publicState.activePlayerId);clients[i].socket.disconnect();
          await until(async()=> (await readState()).publicState.pauseReasons.includes('DISCONNECTED'));clients[i]=await connect(guests[i]);
          await until(async()=>!(await readState()).publicState.pauseReasons.length);await converge();checkedRoadDisconnect=true;
        }
        const p=state.publicState,actor=active(state),settlement=p.phase==='SETUP_SETTLEMENT';
        const payload=settlement?{vertexId:Object.keys(p.board.vertices).find(v=>canSettle(p,actor.playerId,v,true))}:{edgeId:p.board.vertices[state.serverState.setup.pendingVertexId].edgeIds.find(e=>canRoad(p,actor.playerId,e))};
        assert.equal((await send(actor,command(state,settlement?'PLACE_SETUP_SETTLEMENT':'PLACE_SETUP_ROAD',payload))).status,'ACCEPTED');await converge();
      }
      assert.equal((await admin.query('SELECT count(*)::int n FROM app.players WHERE room_id=$1 AND last_seen_at IS NOT NULL',[roomId])).rows[0].n,4);
      assert.equal(state.clockState.remainingTurnMs,60000);assert.equal(timerJobs(state).length,1);initial=structuredClone(state);
    });
    await t.test('early job leaves no receipt; pause/resume invalidates its generation without refilling',async()=>{
      await fixture();const job=timerJobs(state)[0];assert.equal(await games.runTimer(job),'EARLY');
      assert.equal((await admin.query("SELECT 1 FROM app.command_receipts WHERE actor_key='system:timer' AND command_id=$1",[job.commandId])).rowCount,0);
      assert.equal((await send(clients[1],command(state,'PAUSE_GAME'))).error.code,'FORBIDDEN');
      assert.equal((await send(clients[0],command(state,'PAUSE_GAME'))).status,'ACCEPTED');await converge();
      const budget=state.clockState.remainingTurnMs;assert.ok(budget<60000&&budget>55000);assert.equal(nextDeadline(state),null);
      assert.equal((await send(active(state),command(state,'ROLL_DICE'))).error.code,'GAME_PAUSED');
      await sleep(150);assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
      assert.equal(state.clockState.remainingTurnMs,budget);assert.equal(await games.runTimer(job),'STALE');
    });
    await t.test('late player action loses; concurrent duplicate timeout commits exactly once',async()=>{
      await fixture('ACTION',Date.now()-50);const before=state,job=timerJobs(state)[0],late=command(state,'END_TURN');
      const rejected=await send(active(state),late);assert.equal(rejected.error.code,'DEADLINE_EXCEEDED');
      await Promise.all([games.runTimer(job),games.runTimer(job)]);await until(async()=> (await readState()).publicState.turnNumber===before.publicState.turnNumber+1);
      const after=await readState();assert.equal(after.version,before.version+1);assert.equal(await games.runTimer(job),'STALE');
      assert.equal((await admin.query("SELECT count(*)::int n FROM app.command_receipts WHERE actor_key='system:timer' AND command_id=$1",[job.commandId])).rows[0].n,1);
    });
    await t.test('persisted timeout effects replay pre-roll Knight through mandatory actions',async()=>{
      await fixture('ROBBER_MOVE',Date.now()-40);const before=structuredClone(state),job=timerJobs(state)[0];await games.runTimer(job);await converge();
      let replay=structuredClone(before);
      const logs=(await admin.query('SELECT * FROM app.move_logs WHERE room_id=$1 AND sequence>$2 ORDER BY sequence',[roomId,before.version])).rows;
      for(const row of logs) {
        const context=row.effects.find(e=>e.type==='REPLAY_CONTEXT');
        if(context.sessionState){replay.version=row.sequence;replay.publicState.pauseReasons=context.sessionState.pauseReasons;}
        else {
          if(context.timeoutRoot&&context.command.type!=='DISCARD_RESOURCES'){replay.clockState.turnExpired=true;replay.clockState.remainingTurnMs=0;}
          const rng=replayRandom(context.randomDraws);
          replay=applyCommand(replay,context.actingPlayerId??row.actor_player_id,context.command,{now:context.occurredAt,random:rng}).state;
        }
        replay.clockState=context.clockState;replay.publicState.turnDeadline=context.clockState.deadline;
        replay.publicState.discardDeadlines=Object.fromEntries(Object.entries(context.clockState.discards).filter(([,d])=>d.deadline).map(([id,d])=>[id,d.deadline]));
        assertInvariants(replay);assertClock(replay);
      }
      assert.deepEqual(replay,state);assert.ok(logs.length>=3);
    });
    await t.test('already-due deadline wins over a disconnect and then freezes the next required absence',async()=>{
      await fixture('ACTION',Date.now()-40);const before=state;for(const c of clients)c.socket.disconnect();
      await until(async()=>{const s=await readState();return s.publicState.turnNumber===before.publicState.turnNumber+1&&s.publicState.pauseReasons.includes('DISCONNECTED');});
      assert.equal((await readState()).version,before.version+2);
      clients=await Promise.all(guests.map(connect));await until(async()=>!(await readState()).publicState.pauseReasons.length);await converge();
    });
    await t.test('independent discard jobs survive another discard and conserve all cards',async()=>{
      await fixture('DISCARD_REQUIRED');const now=new Date(Date.now()-30).toISOString();
      for(const [id,d] of Object.entries(state.clockState.discards)){d.deadline=now;state.publicState.discardDeadlines[id]=now;}
      await seed(state);const jobs=timerJobs(state);assert.equal(jobs.length,2);
      await Promise.all(jobs.map(j=>games.runTimer(j)));await converge();assert.equal(state.publicState.phase,'ROBBER_MOVE');assert.equal(state.clockState.turnExpired,false);assertClock(state);
      for(const c of clients.slice(0,2))assert.equal(Object.values(state.privateState[c.playerId].resources).reduce((a,b)=>a+b,0),4);
      assertInvariants(state);
    });
    for(const phase of ['AWAIT_ROLL','ACTION','DISCARD_REQUIRED','ROBBER_MOVE','ROBBER_VICTIM','ROAD_BUILDING']) await t.test(`final required socket freezes and restores ${phase}`,async()=>{
      await fixture(phase);const required=state.publicState.requiredPlayerIds[0],index=clients.findIndex(c=>c.playerId===required),before=structuredClone(state);
      const twin=await connect(clients[index].guest);await until(()=>twin.view!=null);clients[index].socket.disconnect();await sleep(100);await games.tick();
      assert.deepEqual((await readState()).publicState.pauseReasons,[],'second tab keeps the seat online');
      twin.socket.disconnect();await until(async()=> (await readState()).publicState.pauseReasons.includes('DISCONNECTED'));
      const paused=await readState();assert.equal(nextDeadline(paused),null);assert.deepEqual(paused.privateState,before.privateState);assert.equal(paused.publicState.phase,phase);
      clients[index]=await connect(guests[index]);await until(async()=>!(await readState()).publicState.pauseReasons.length);await converge();
      assert.equal(state.clockState.remainingTurnMs,paused.clockState.remainingTurnMs);
      for(const [id,d] of Object.entries(paused.clockState.discards))assert.equal(state.clockState.discards[id].remainingMs,d.remainingMs);
    });
    await t.test('manual pause survives reconnection; host controls require the host',async()=>{
      await fixture();assert.equal((await send(clients[0],command(state,'PAUSE_GAME'))).status,'ACCEPTED');await converge();
      const paused=await readState();
      const index=clients.findIndex(c=>c.playerId===state.publicState.activePlayerId);clients[index].socket.disconnect();
      await until(()=>!app.get(Rooms).online(roomId).has(paused.publicState.activePlayerId));await games.tick();
      assert.deepEqual(await readState(),paused,'disconnect cannot rewrite a manually saved game');
      clients[index]=await connect(guests[index]);await until(()=>app.get(Rooms).online(roomId).has(paused.publicState.activePlayerId));await games.tick();await converge();
      assert.deepEqual(state.publicState.pauseReasons,['MANUAL']);assert.equal((await send(clients[1],command(state,'RESUME_GAME'))).error.code,'FORBIDDEN');
      assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
    });
    for(const reasons of [['MANUAL'],['RECOVERY'],['DATABASE_UNAVAILABLE'],['DISCONNECTED','RECOVERY']]) await t.test(`saved pause ${reasons.join('+')} does not write on presence flaps or idle ticks`,async()=>{
      await fixture('DISCARD_REQUIRED');
      const paused=pauseState(state,reasons,new Date().toISOString(),seeded(901));await seed(paused);await games.flush();await app.get(Rooms).flush();
      const required=paused.publicState.requiredPlayerIds.find(id=>id!==clients[0].playerId);
      const index=clients.findIndex(c=>c.playerId===required);
      assert.ok(index>0,'keep the host connected so only required-player presence changes');
      async function persisted() {
        const row=(await admin.query('SELECT version,updated_at,clock_state FROM app.game_states WHERE room_id=$1',[roomId])).rows[0];
        for(const table of ['move_logs','outbox_events','command_receipts'])row[table]=(await admin.query(`SELECT count(*)::int n FROM app.${table} WHERE room_id=$1`,[roomId])).rows[0].n;
        return row;
      }
      const baseline=await persisted();
      for(let cycle=0;cycle<3;cycle++) {
        clients[index].socket.disconnect();await until(()=>!app.get(Rooms).online(roomId).has(required));await quiesce();
        for(let tick=0;tick<3;tick++)await games.tick();
        assert.equal(games.runtimeTimer,undefined,'a host-resume pause must not schedule a polling loop');
        assert.deepEqual(await persisted(),baseline,'offline ticks must not append records or update state');
        clients[index]=await connect(guests[index]);await until(()=>app.get(Rooms).online(roomId).has(required));await quiesce();await games.tick();
        assert.deepEqual(await persisted(),baseline,'reconnection must not append records or update state');
        assert.deepEqual(await readState(),paused,'inventory, version and saved clock budgets stay identical');
      }
      clients[index].socket.disconnect();await until(()=>!app.get(Rooms).online(roomId).has(required));await quiesce();
      assert.equal((await send(clients[0],command(paused,'RESUME_GAME'))).error.code,'PLAYERS_NOT_READY');
      assert.deepEqual(await readState(),paused,'host resume still checks current presence under the room lock');
      clients[index]=await connect(guests[index]);await until(()=>app.get(Rooms).online(roomId).has(required));await quiesce();
      assert.equal((await send(clients[0],command(paused,'RESUME_GAME'))).status,'ACCEPTED');await converge();
      assert.deepEqual(state.publicState.pauseReasons,[]);
      for(const [id,clock] of Object.entries(paused.clockState.discards))assert.equal(state.clockState.discards[id].remainingMs,clock.remainingMs);
    });
    await t.test('terminated runtime DB connection holds actions and recovers the identical hands',async()=>{
      await fixture();await quiesce();const before=state,db=app.get(Database);
      await assert.rejects(db.transaction(async c=>{ const pid=(await c.query('SELECT pg_backend_pid() pid')).rows[0].pid;await admin.query('SELECT pg_terminate_backend($1)',[pid]);await c.query('SELECT 1'); }));
      assert.equal(games.storageReady,false);assert.equal((await send(active(before),command(before,'ROLL_DICE'))).error.code,'SERVICE_UNAVAILABLE');
      await until(async()=>games.storageReady&&(await readState()).publicState.pauseReasons.includes('DATABASE_UNAVAILABLE'));
      await converge();assert.deepEqual(state.privateState,before.privateState);assert.deepEqual(state.publicState.board,before.publicState.board);
      assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
    });
    await t.test('restart fences the previous writer and requires explicit host recovery resume',async()=>{
      await fixture('ACTION',Date.now()+23000);await quiesce();const before=state,oldGames=games;
      const replacement=await createApp({...loadConfig(),port:0});
      assert.equal((await oldGames.command(guests[0].user.id,command(before,'PAUSE_GAME'))).error.code,'SERVICE_UNAVAILABLE');
      await app.close();app=replacement;await app.listen(0,'127.0.0.1');base=await app.getUrl();games=app.get(Games);
      clients=await Promise.all(guests.map(connect));await converge();assert.ok(state.publicState.pauseReasons.includes('RECOVERY'));
      assert.equal(nextDeadline(state),null);assert.deepEqual(state.privateState,before.privateState);assert.equal(state.publicState.turnNumber,before.publicState.turnNumber);
      assert.ok(state.clockState.remainingTurnMs>20000&&state.clockState.remainingTurnMs<=24000);assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
    });
    await t.test('graceful shutdown freezes exact remaining time before a replacement starts',async()=>{
      await fixture('ACTION',Date.now()+19000);await app.close();const paused=await readState();assert.ok(paused.clockState.remainingTurnMs>15000&&paused.clockState.remainingTurnMs<=19000);
      app=await createApp({...loadConfig(),port:0});await app.listen(0,'127.0.0.1');base=await app.getUrl();games=app.get(Games);
      clients=await Promise.all(guests.map(connect));await converge();assert.equal(state.clockState.remainingTurnMs,paused.clockState.remainingTurnMs);
      assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
    });
    await t.test('corrupt persisted state fails readiness without regenerating any inventory',async()=>{
      await fixture();await quiesce();const before=state;
      await admin.query('UPDATE app.game_states SET next_deadline_at=NULL WHERE room_id=$1',[roomId]);
      await games.tick();assert.equal(games.storageReady,false);
      assert.equal((await fetch(`${base}/health/ready`)).status,503);
      assert.equal((await send(active(before),command(before,'ROLL_DICE'))).error.code,'SERVICE_UNAVAILABLE');
      const unchanged=await readState();assert.equal(unchanged.version,before.version);assert.deepEqual(unchanged.privateState,before.privateState);
      // Privileged repair of the deliberately damaged index, followed by a fresh runtime.
      await admin.query('UPDATE app.game_states SET next_deadline_at=$2 WHERE room_id=$1',[roomId,nextDeadline(before)]);
      await app.close();app=await createApp({...loadConfig(),port:0});await app.listen(0,'127.0.0.1');base=await app.getUrl();games=app.get(Games);
      clients=await Promise.all(guests.map(connect));await converge();assert.ok(state.publicState.pauseReasons.includes('RECOVERY'));
      assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
    });
    await t.test('in-game host transfers after ten seconds without changing the current turn',async()=>{
      await fixture();const before=state;clients[0].socket.disconnect();await until(async()=> (await admin.query('SELECT host_player_id FROM app.rooms WHERE id=$1',[roomId])).rows[0].host_player_id!==clients[0].playerId,14000);
      const host=(await admin.query('SELECT host_player_id FROM app.rooms WHERE id=$1',[roomId])).rows[0].host_player_id;
      assert.equal(host,clients[1].playerId);assert.equal((await readState()).publicState.activePlayerId,before.publicState.activePlayerId);
      clients[0]=await connect(guests[0]);await until(async()=>!(await readState()).publicState.pauseReasons.length);await converge();
      assert.equal((await send(clients[0],command(state,'ABANDON_GAME'))).error.code,'FORBIDDEN');
      assert.equal((await send(clients[1],command(state,'ABANDON_GAME'))).status,'ACCEPTED');
      const room=(await admin.query('SELECT status,active_slot FROM app.rooms WHERE id=$1',[roomId])).rows[0];assert.equal(room.status,'ABANDONED');assert.equal(room.active_slot,null);assert.equal((await readState()).publicState.winnerPlayerId,null);
    });
  } finally {
    for(const socket of sockets)socket.disconnect();await app?.close();
    for(const id of rooms){await admin.query('BEGIN');for(const table of ['outbox_events','move_logs','game_states','command_receipts','players','rooms'])await admin.query(`DELETE FROM app.${table} WHERE ${table==='rooms'?'id':'room_id'}=$1`,[id]);await admin.query('COMMIT');}
    for(const guest of guests)await admin.query('DELETE FROM app.command_receipts WHERE actor_key=$1',[`user:${guest.user.id}`]);await admin.end();
  }
});
