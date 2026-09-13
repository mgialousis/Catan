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
import { scenario } from '../../scripts/preview/table.mjs';

process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
if (!['127.0.0.1', 'localhost'].includes(new URL(local.adminDatabaseUrl).hostname)) throw new Error('Local only');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(check, ms = 7000) { for (const end = Date.now() + ms; Date.now() < end;) { if (await check()) return; await sleep(25); } assert.fail('Expected state did not arrive'); }
function patch(target, operations) { for (const p of operations) { const keys = p.path.slice(1).split('/'); let parent = target; for (const key of keys.slice(0, -1)) parent = parent[key]; if (p.op === 'remove') delete parent[keys.at(-1)]; else parent[keys.at(-1)] = structuredClone(p.value); } }

test('durable authenticated four-player gameplay', { timeout: 100000 }, async t => {
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
    assertInvariants(next);
    await games.flush();
    await admin.query(`UPDATE app.game_states SET version=$2,phase=$3,phase_id=$4,turn_number=$5,active_player_id=$6,public_state=$7,private_state=$8,server_state=$9,clock_state=$10,next_deadline_at=$11 WHERE room_id=$1`,
      [roomId,next.version,next.publicState.phase,next.publicState.phaseId,next.publicState.turnNumber,next.publicState.activePlayerId,next.publicState,next.privateState,next.serverState,next.clockState,next.clockState.deadline]);
    for (const c of clients) await sync(c);
    await sleep(80); state = next;
  }
  try {
    assert.equal((await admin.query('SELECT count(*)::int n FROM app.rooms WHERE active_slot=1')).rows[0].n, 0, 'Close local preview rooms first; unrelated data is never removed');
    app = await createApp({ ...loadConfig(), port: 0 }, { gameFaults: faults }); await app.listen(0, '127.0.0.1'); base = await app.getUrl(); games = app.get(Games);
    for (let i = 0; i < 5; i++) {
      const response = await fetch(`${local.apiUrl}/auth/v1/signup`, { method: 'POST', headers: { apikey: local.anonKey, 'Content-Type': 'application/json' }, body: '{}' });
      assert.equal(response.status, 200); guests.push(await response.json());
    }
    clients = await Promise.all(guests.slice(0, 4).map(connect));
    const stranger = await connect(guests[4]);
    const created = await roomCommand(clients[0], 'CREATE_ROOM', { nickname: 'Game host', settings: { maxPlayers: 4, turnLimitSeconds: null, boardMode: 'STANDARD_RANDOM', rulesVersion: 'base-2020-v1' } }, true);
    assert.equal(created.status, 'ACCEPTED'); roomId = created.roomId; invite = created.result.invitationCode; rooms.push(roomId);
    for (const [i,c] of clients.slice(1).entries()) assert.equal((await roomCommand(c,'JOIN_ROOM',{nickname:`Game guest ${i}`,invitationCode:invite},true)).status,'ACCEPTED');
    for (const c of clients) assert.equal((await roomCommand(c,'SET_READY',{ready:true})).status,'ACCEPTED');
    await t.test('start rollback and concurrent starts create exactly one canonical game', async () => {
      faults.beforeCommit = () => { throw Error('Synthetic before commit'); };
      assert.equal((await roomCommand(clients[0], 'START_GAME')).error.code, 'SERVICE_UNAVAILABLE');
      assert.equal((await admin.query('SELECT 1 FROM app.game_states WHERE room_id=$1',[roomId])).rowCount,0);
      delete faults.beforeCommit;
      const results = await Promise.all([roomCommand(clients[0],'START_GAME'),roomCommand(clients[0],'START_GAME')]);
      assert.equal(results.filter(a=>a.status==='ACCEPTED').length,1);
      await converge(); assert.equal(state.version,0);
      assert.equal((await admin.query('SELECT count(*)::int n FROM app.move_logs WHERE room_id=$1',[roomId])).rows[0].n,1);
      assert.equal((await roomCommand(stranger,'JOIN_ROOM',{nickname:'Late guest',invitationCode:invite},true)).error.code,'GAME_ALREADY_STARTED');
    });
    await t.test('membership checked on commands, sync and paginated HTTP activity', async () => {
      assert.equal((await send(stranger,command(state,'PLACE_SETUP_SETTLEMENT',{vertexId:Object.keys(state.publicState.board.vertices)[0]}))).error.code,'FORBIDDEN');
      await sync(stranger); await until(()=>stranger.errors.some(e=>e.code==='FORBIDDEN')); assert.equal(stranger.view,undefined);
      const url = `${base}/api/v1/rooms/${roomId}/activity`;
      assert.equal((await fetch(url)).status,401);
      assert.equal((await fetch(url,{headers:{Authorization:`Bearer ${stranger.guest.access_token}`}})).status,403);
      assert.equal((await fetch(`${url}?limit=1000`,{headers:{Authorization:`Bearer ${clients[0].guest.access_token}`}})).status,400);
    });
    await t.test('duplicate action IDs, last-version builds and precommit rollback', async () => {
      const c=active(state), vertex=Object.keys(state.publicState.board.vertices).find(v=>canSettle(state.publicState,c.playerId,v,true));
      const cmd=command(state,'PLACE_SETUP_SETTLEMENT',{vertexId:vertex});
      faults.beforeCommit=()=>{throw Error('Crash');};
      assert.equal((await send(c,cmd)).error.code,'SERVICE_UNAVAILABLE');
      assert.equal((await readState()).version,0);
      assert.equal((await admin.query('SELECT 1 FROM app.command_receipts WHERE command_id=$1',[cmd.commandId])).rowCount,0);
      assert.equal((await admin.query('SELECT 1 FROM app.move_logs WHERE room_id=$1 AND sequence=1',[roomId])).rowCount,0);
      delete faults.beforeCommit;
      const [a,b]=await Promise.all([send(c,cmd),send(c,cmd)]); assert.equal(a.status,'ACCEPTED'); assert.deepEqual(a,b);
      assert.equal((await send(c,{...cmd,payload:{vertexId:'v_999'}})).error.code,'COMMAND_ID_REUSED');
      await converge(); assert.equal(state.version,1);
    });
    await t.test('lost postcommit acknowledgement returns the original receipt on retry', async () => {
      const c=active(state), vertex=state.serverState.setup.pendingVertexId;
      const cmd=command(state,'PLACE_SETUP_ROAD',{edgeId:state.publicState.board.vertices[vertex].edgeIds.find(e=>canRoad(state.publicState,c.playerId,e))});
      faults.afterCommit=()=>{throw Error('Lost acknowledgement');};
      assert.equal((await send(c,cmd)).error.code,'SERVICE_UNAVAILABLE');
      assert.equal((await readState()).version,2);
      delete faults.afterCommit;
      const a=await send(c,cmd),b=await send(c,cmd);assert.equal(a.status,'ACCEPTED');assert.deepEqual(a,b);await converge();
    });
    await t.test('outbox survives send/marker rollback and duplicate tabs retain the same owner', async () => {
      const twin=await connect(active(state).guest); await until(()=>twin.view!=null);
      assert.equal(twin.view.privateState.playerId,active(state).playerId);
      const c=active(state), vertex=Object.keys(state.publicState.board.vertices).find(v=>canSettle(state.publicState,c.playerId,v,true));
      faults.afterSend=()=>{throw Error('Crash before delivery marker');};
      assert.equal((await send(c,command(state,'PLACE_SETUP_SETTLEMENT',{vertexId:vertex}))).status,'ACCEPTED');
      await until(async()=>(await admin.query("SELECT 1 FROM app.outbox_events WHERE room_id=$1 AND scope='GAME' AND published_at IS NULL",[roomId])).rowCount>0);
      delete faults.afterSend;await games.flush();await converge();await until(()=>twin.view.version===state.version);twin.socket.disconnect();
    });
    await t.test('four clients finish both setup rounds and persisted entropy replays exactly', async () => {
      while (state.serverState.setup) {
        const c=active(state), p=state.publicState;
        const settlement=p.phase==='SETUP_SETTLEMENT';
        const payload=settlement?{vertexId:Object.keys(p.board.vertices).find(v=>canSettle(p,c.playerId,v,true))}:{edgeId:p.board.vertices[state.serverState.setup.pendingVertexId].edgeIds.find(e=>canRoad(p,c.playerId,e))};
        assert.equal((await send(c,command(state,settlement?'PLACE_SETUP_SETTLEMENT':'PLACE_SETUP_ROAD',payload))).status,'ACCEPTED');await converge();
      }
      const logs=(await admin.query('SELECT * FROM app.move_logs WHERE room_id=$1 ORDER BY sequence',[roomId])).rows;
      let replay=logs[0].effects.find(e=>e.type==='INITIAL_SNAPSHOT').state;
      for (const log of logs.slice(1)) {
        const ctx=log.effects.find(e=>e.type==='REPLAY_CONTEXT'),random=replayRandom(ctx.randomDraws);
        replay=applyCommand(replay,log.actor_player_id,ctx.command,{now:ctx.occurredAt,random}).state;random.assertConsumed();
      }
      assert.deepEqual(replay,state);
      const c=clients[1];let before='',count=0;
      do {
        const response=await fetch(`${base}/api/v1/rooms/${roomId}/activity?limit=5${before}`,{headers:{Authorization:`Bearer ${c.guest.access_token}`}});
        assert.equal(response.status,200);const page=await response.json();assert.ok(page.entries.length<=5);count+=page.entries.length;
        const wire=JSON.stringify(page);assert.ok(!wire.includes('REPLAY_CONTEXT')&&!wire.includes('serverState')&&!wire.includes('randomDraws'));
        before=page.nextBefore==null?'':`&before=${page.nextBefore}`;
      } while(before);
      assert.equal(count,logs.length);
    });
    await t.test('concurrent paid builds and acceptances consume resources once', async () => {
      const actor=state.publicState.activePlayerId,other=clients.find(c=>c.playerId!==actor);
      state=resources(asAction(state),{[actor]:{brick:1,lumber:1,wool:2,grain:2,ore:2},[other.playerId]:{ore:1}});await seed(state);
      const c=active(state),edge=Object.keys(state.publicState.board.edges).find(e=>canRoad(state.publicState,actor,e));
      const results=await Promise.all([send(c,command(state,'BUILD_ROAD',{edgeId:edge})),send(c,command(state,'BUILD_ROAD',{edgeId:edge}))]);
      assert.equal(results.filter(a=>a.status==='ACCEPTED').length,1);await converge();assert.equal(state.privateState[actor].resources.brick,0);
      const give={brick:0,lumber:0,wool:1,grain:0,ore:0},receive={brick:0,lumber:0,wool:0,grain:0,ore:1};
      assert.equal((await send(c,command(state,'PROPOSE_TRADE',{targetPlayerId:other.playerId,give,receive}))).status,'ACCEPTED');await converge();
      const offer=Object.values(state.publicState.trades).find(o=>o.status==='OPEN');
      const accepts=await Promise.all([send(other,command(state,'ACCEPT_TRADE',{offerId:offer.offerId,offerRevision:offer.revision})),send(other,command(state,'ACCEPT_TRADE',{offerId:offer.offerId,offerRevision:offer.revision}))]);
      assert.equal(accepts.filter(a=>a.status==='ACCEPTED').length,1);await converge();assert.equal(state.privateState[other.playerId].resources.ore,0);
    });
    await t.test('last deck item is atomic and its identity reaches only the buyer', async () => {
      const c=active(state),other=clients.find(v=>v!==c);
      state=resources(state,{[c.playerId]:{wool:3,grain:3,ore:3}});
      while(state.serverState.developmentDeck.length>1) giveCard(state,other.playerId,state.serverState.developmentDeck[0].type);
      await seed(state);const canary=state.serverState.developmentDeck[0].id;
      for(const v of clients) v.wire=[];
      const results=await Promise.all([send(c,command(state,'BUY_DEVELOPMENT_CARD')),send(c,command(state,'BUY_DEVELOPMENT_CARD'))]);
      assert.equal(results.filter(a=>a.status==='ACCEPTED').length,1);await converge();assert.equal(state.serverState.developmentDeck.length,0);
      assert.ok(JSON.stringify(c.wire).includes(canary));
      for(const v of clients.filter(v=>v!==c)) assert.ok(!JSON.stringify(v.wire).includes(canary));
      for(const v of clients) assert.ok(!JSON.stringify(v.wire).includes('developmentDeck'));
    });
    await t.test('the final bank resource is consumed by only one competing trade', async () => {
      const c=active(state), other=clients.find(v=>v!==c);
      state=resources(state,Object.fromEntries(clients.map(v=>[v.playerId,{}])));
      const rate=bankRate(state.publicState,c.playerId,'grain');
      state=resources(state,{[c.playerId]:{grain:rate*2},[other.playerId]:{brick:18}});await seed(state);
      const payload={giveType:'grain',receiveType:'brick',receiveCount:1};
      const results=await Promise.all([send(c,command(state,'BANK_TRADE',payload)),send(c,command(state,'BANK_TRADE',payload))]);
      assert.equal(results.filter(a=>a.status==='ACCEPTED').length,1);await converge();assert.equal(state.serverState.bank.brick,0);
    });
    await t.test('a dropped final frame is detected by version probe and corrected by snapshot', async () => {
      const victim=clients[2];victim.drop=true;
      assert.equal((await send(active(state),command(state,'END_TURN'))).status,'ACCEPTED');
      state=await readState();await sleep(70);victim.drop=false;assert.notEqual(victim.view.version,state.version);
      const version=new Promise(r=>victim.socket.once('game.version',r));victim.socket.emit('game.version.request',{roomId});assert.equal((await version).version,state.version);
      await sync(victim);await converge();
    });
    await t.test('restart restores persisted hands, rejects the fenced writer and drains pending updates', async () => {
      const previous=app.get(Rooms),saved=structuredClone(state);
      await admin.query("UPDATE app.outbox_events SET published_at=NULL WHERE room_id=$1 AND scope='GAME' AND to_version=$2",[roomId,state.version]);
      const replacement=await createApp({...loadConfig(),port:0}, {gameFaults:faults});
      assert.equal((await previous.command(clients[0].guest.user.id,{protocolVersion:1,commandId:randomUUID(),roomId,expectedVersion:0,expectedPhaseId:null,type:'START_GAME',payload:{}})).error.code,'SERVICE_UNAVAILABLE');
      await app.close();app=replacement;await app.listen(0,'127.0.0.1');base=await app.getUrl();games=app.get(Games);
      clients=await Promise.all(guests.slice(0,4).map(connect));await converge();assert.deepEqual(state.privateState,saved.privateState);assert.deepEqual(state.publicState.board,saved.publicState.board);assert.ok(state.publicState.pauseReasons.includes('RECOVERY'));
      assert.equal((await send(clients[0],command(state,'RESUME_GAME'))).status,'ACCEPTED');await converge();
      await games.flush();assert.equal((await admin.query("SELECT 1 FROM app.outbox_events WHERE room_id=$1 AND scope='GAME' AND published_at IS NULL",[roomId])).rowCount,0);
      const twin=await connect(clients[0].guest);await until(()=>twin.view!=null);
      const refreshed=await fetch(`${local.apiUrl}/auth/v1/token?grant_type=refresh_token`,{method:'POST',headers:{apikey:local.anonKey,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:clients[0].guest.refresh_token})});
      assert.equal(refreshed.status,200);const token=await refreshed.json();
      assert.equal((await twin.socket.timeout(6000).emitWithAck('auth.refresh',{accessToken:token.access_token})).status,'ACCEPTED');
      const denied=await twin.socket.timeout(6000).emitWithAck('auth.refresh',{accessToken:clients[1].guest.access_token}).catch(()=>null);
      assert.ok(denied==null||denied.status==='REJECTED');await until(()=>!twin.socket.connected);
    });
    await t.test('a real winning move finishes the room and rematch creates one new invitation', async () => {
      // Seeding is privileged test setup; this route is never exposed by the API.
      const preview=scenario('victory').state,oldIds=Object.keys(preview.privateState),ids=clients.map(c=>c.playerId);
      let raw=JSON.stringify(preview);for(let i=0;i<oldIds.length;i++)raw=raw.replaceAll(oldIds[i],ids[i]);raw=raw.replaceAll(preview.roomId,roomId);
      const winning=JSON.parse(raw);winning.version=state.version;await seed(winning);
      assert.equal((await send(active(state),command(state,'BUY_DEVELOPMENT_CARD'))).status,'ACCEPTED');await converge();assert.equal(state.publicState.phase,'COMPLETE');
      assert.equal((await admin.query('SELECT active_slot FROM app.rooms WHERE id=$1',[roomId])).rows[0].active_slot,null);
      assert.equal((await roomCommand(clients[1],'CREATE_REMATCH')).error.code,'FORBIDDEN');
      const revision=(await admin.query('SELECT revision FROM app.rooms WHERE id=$1',[roomId])).rows[0].revision;
      const cmd={protocolVersion:1,commandId:randomUUID(),roomId,expectedVersion:revision,expectedPhaseId:null,type:'CREATE_REMATCH',payload:{}};
      const [a,b]=await Promise.all([clients[0].socket.timeout(6000).emitWithAck('room.command',cmd),clients[0].socket.timeout(6000).emitWithAck('room.command',cmd)]);
      assert.equal(a.status,'ACCEPTED');assert.deepEqual(a,b);assert.notEqual(a.roomId,roomId);rooms.push(a.roomId);assert.notEqual(a.result.invitationCode,invite);roomId=a.roomId;invite=a.result.invitationCode;
    });
    await t.test('a fourth join racing a three-player start has one legal outcome', async () => {
      for(const [i,c] of clients.slice(1,3).entries()) assert.equal((await roomCommand(c,'JOIN_ROOM',{nickname:`Race ${i}`,invitationCode:invite},true)).status,'ACCEPTED');
      for(const c of clients.slice(0,3)) assert.equal((await roomCommand(c,'SET_READY',{ready:true})).status,'ACCEPTED');
      const [start,join]=await Promise.all([roomCommand(clients[0],'START_GAME'),roomCommand(clients[3],'JOIN_ROOM',{nickname:'Racing fourth',invitationCode:invite},true)]);
      if(start.status==='ACCEPTED') {
        assert.equal(join.error.code,'GAME_ALREADY_STARTED');
        assert.equal(Object.keys((await readState()).privateState).length,3);
      } else {
        assert.equal(join.status,'ACCEPTED');assert.ok(['STALE_VERSION','PLAYERS_NOT_READY'].includes(start.error.code));
        assert.equal((await admin.query('SELECT 1 FROM app.game_states WHERE room_id=$1',[roomId])).rowCount,0);
        const players=(await admin.query('SELECT ready FROM app.players WHERE room_id=$1',[roomId])).rows;assert.equal(players.length,4);assert.ok(players.every(p=>!p.ready));
      }
    });
  } finally {
    for(const socket of sockets) socket.disconnect();await app?.close();
    for(const id of rooms){await admin.query('BEGIN');for(const table of ['outbox_events','move_logs','game_states','command_receipts','players','rooms']) await admin.query(`DELETE FROM app.${table} WHERE ${table==='rooms'?'id':'room_id'}=$1`,[id]);await admin.query('COMMIT');}
    for(const guest of guests)await admin.query('DELETE FROM app.command_receipts WHERE actor_key=$1',[`user:${guest.user.id}`]);await admin.end();
  }
});
