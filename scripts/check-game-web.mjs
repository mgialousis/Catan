import { chromium, expect } from '@playwright/test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Client } from 'pg';

const timed=process.argv.includes('--timed');
const local=JSON.parse(readFileSync('.local/test-env.json','utf8'));
assert.ok(['127.0.0.1','localhost'].includes(new URL(local.adminDatabaseUrl).hostname));
const db=new Client({connectionString:local.adminDatabaseUrl});await db.connect();
assert.equal((await db.query('SELECT count(*)::int n FROM app.rooms WHERE active_slot=1')).rows[0].n,0,'Close your local table first. This check never deletes unrelated data.');
const browser=await chromium.launch({channel:'chrome',headless:true});
const guests=[];let roomId;
async function semantics(page) {await page.waitForLoadState('networkidle');const button=page.getByRole('button',{name:'Enable accessibility',exact:true});if(await button.count())await button.dispatchEvent('click');}
async function seek(page,name) {
  const button=page.getByRole('button',{name,exact:true});
  if(!await button.count()) {await page.mouse.move(425,600);await page.mouse.wheel(0,-5000);await page.waitForTimeout(100);}
  for(let i=0;i<15&&!await button.count();i++){await page.mouse.wheel(0,350);await page.waitForTimeout(100);}
  await expect(button).toBeEnabled();return button;
}
async function open(name,url='http://127.0.0.1:8080') {
  assert.equal(new URL(url).origin,'http://127.0.0.1:8080');
  const context=await browser.newContext({viewport:{width:430,height:932},permissions:['clipboard-read','clipboard-write']});
  const page=await context.newPage(),guest={context,page,name,signups:0,errors:[],dropAcks:false,commands:[]};guests.push(guest);
  page.on('pageerror',e=>guest.errors.push(e.message));page.on('request',r=>{if(new URL(r.url()).pathname==='/auth/v1/signup')guest.signups++;});
  await page.routeWebSocket(/\/socket.io\//,ws=>{
    const server=ws.connectToServer();
    server.onMessage(message=>{if(typeof message==='string'&&message.startsWith('42/game,')){const [event,value]=JSON.parse(message.slice(message.indexOf('[')));if(event==='room.snapshot')guest.room=value;}if(guest.dropAcks&&typeof message==='string'&&message.startsWith('43/game,')&&message.includes('"scope":"GAME"'))return;ws.send(message);});
    ws.onMessage(message=>{if(typeof message==='string'&&message.includes('"game.command"'))guest.commands.push(message);server.send(message);});
  });
  await page.goto(url);await semantics(page);
  const input=page.getByRole('textbox',{name:'Nickname',exact:true});await input.click();await page.waitForTimeout(150);await input.press('ControlOrMeta+A');await input.press('Backspace');await input.pressSequentially(name,{delay:80});await expect(input).toHaveValue(name);
  await page.getByRole('button',{name:'Connect as guest',exact:true}).click();
  await expect(page.getByRole('button',{name:'Create private table',exact:true})).toBeVisible({timeout:15000});return guest;
}
async function game(){return (await db.query('SELECT version,public_state FROM app.game_states WHERE room_id=$1',[roomId])).rows[0];}
async function place(g,phase) {
  const page=g.page;
  await (await seek(page,phase==='SETUP_SETTLEMENT'?'Choose settlement':'Choose road')).click();
  await page.mouse.move(425,500);await page.mouse.wheel(0,-5000);await page.waitForTimeout(200);
  const target=page.getByRole('button',{name:phase==='SETUP_SETTLEMENT'?/^Select Junction /:/^Select Road /}).first();
  await expect(target).toBeAttached();await target.dispatchEvent('click');
  await (await seek(page,'Confirm placement')).click();
}
try {
  const host=await open('Mira');await host.page.getByRole('button',{name:'Create private table',exact:true}).click();
  await (await seek(host.page,'Copy invitation link')).click();const invitation=await host.page.evaluate(()=>navigator.clipboard.readText());
  const code=new URL(invitation).searchParams.get('invite');assert.match(code,/^[0-9A-HJKMNP-TV-Z]{10}$/);
  roomId=(await db.query("SELECT id FROM app.rooms WHERE active_slot=1 AND created_by_user_id IN (SELECT auth_user_id FROM app.players WHERE nickname='Mira')")).rows[0].id;
  if(timed) {
    await (await seek(host.page,/^Table settings Time per turn/)).dispatchEvent('click');
    await host.page.getByRole('menuitem').nth(1).click();
    await expect.poll(async()=>(await db.query('SELECT settings FROM app.rooms WHERE id=$1',[roomId])).rows[0].settings.turnLimitSeconds).toBe(60);
  }
  for(const name of ['Theo','Noor','Leo']) {const guest=await open(name,invitation);await guest.page.getByRole('button',{name:'Join table',exact:true}).click();await expect.poll(()=>guest.page.locator('body').ariaSnapshot()).toContain(`${name} (you)`);}
  for(const g of guests) {
    const revision=(await db.query('SELECT revision FROM app.rooms WHERE id=$1',[roomId])).rows[0].revision;
    await expect.poll(()=>g.room?.revision).toBe(revision);
    await (await seek(g.page,"I'm ready")).click();
    await expect.poll(async()=>(await db.query('SELECT ready FROM app.players WHERE room_id=$1 AND nickname=$2',[roomId,g.name])).rows[0].ready).toBe(true);
  }
  await (await seek(host.page,'Start game')).click();
  await expect.poll(async()=>!!await game()).toBe(true);
  let current=await game();
  for(let i=0;i<16;i++) {
    const name=current.public_state.players[current.public_state.activePlayerId].nickname,g=guests.find(v=>v.name===name);
    if(i===15)g.dropAcks=true;
    await place(g,current.public_state.phase);
    await expect.poll(async()=>(await game()).version).toBe(current.version+1);current=await game();
    if(i===15) {
      assert.equal(await g.page.evaluate(()=>Object.keys(sessionStorage).filter(k=>k.startsWith('island-intent-v1-')).length),1);
      const last=g.commands.at(-1),before=current.version;g.dropAcks=false;
      await g.page.reload();await semantics(g.page);
      await expect.poll(()=>g.page.evaluate(()=>Object.keys(sessionStorage).filter(k=>k.startsWith('island-intent-v1-')).length),{timeout:15000}).toBe(0);
      await expect.poll(()=>g.commands.length).toBeGreaterThan(1);
      // Socket.IO ack numbers differ on reconnect; the command envelope does not.
      const payload=m=>JSON.parse(m.slice(m.indexOf('[')))[1];assert.deepEqual(payload(g.commands.at(-1)),payload(last));
      // Presence pause/resume can advance versions during reload; the gameplay intent still commits once.
      assert.equal((await db.query('SELECT count(*)::int n FROM app.move_logs WHERE room_id=$1 AND command_id=$2',[roomId,payload(last).commandId])).rows[0].n,1);
      await expect.poll(async()=>(await game()).public_state.pauseReasons).toEqual([]);
      current=await game();assert.ok(current.version>=before);assert.equal(g.signups,1);
    }
  }
  assert.equal(current.public_state.phase,'AWAIT_ROLL');
  if(timed) {
    const deadline=current.public_state.turnDeadline;assert.ok(deadline);
    await (await seek(host.page,'Pause game')).click();
    await expect.poll(async()=>(await game()).public_state.pauseReasons).toContain('MANUAL');
    const remaining=(await db.query('SELECT clock_state FROM app.game_states WHERE room_id=$1',[roomId])).rows[0].clock_state.remainingTurnMs;
    assert.ok(remaining>0&&remaining<60000);await host.page.waitForTimeout(1000);
    await (await seek(host.page,'Resume game')).click();
    await expect.poll(async()=>(await game()).public_state.pauseReasons).toEqual([]);
    assert.equal((await db.query('SELECT clock_state FROM app.game_states WHERE room_id=$1',[roomId])).rows[0].clock_state.remainingTurnMs,remaining);
    current=await game();
    await host.page.mouse.move(425,500);await host.page.mouse.wheel(0,-5000);await host.page.waitForTimeout(300);
    await host.page.screenshot({path:'docs/screenshots/phase-6-host-controls.png'});
    await expect.poll(()=>host.page.locator('body').ariaSnapshot()).toContain('Turn time');
  }
  const actor=guests.find(v=>v.name===current.public_state.players[current.public_state.activePlayerId].nickname);
  await (await seek(actor.page,'Roll dice')).click();await expect.poll(async()=>(await game()).version).toBe(current.version+1);
  await actor.page.mouse.move(425,500);await actor.page.mouse.wheel(0,-5000);await actor.page.waitForTimeout(200);
  await actor.page.screenshot({path:`docs/screenshots/phase-${timed?6:5}-live-portrait.png`});
  await actor.page.setViewportSize({width:812,height:375});await actor.page.waitForTimeout(300);await actor.page.screenshot({path:`docs/screenshots/phase-${timed?6:5}-live-landscape.png`});
  for(const g of guests){assert.deepEqual(g.errors,[]);assert.equal(g.signups,1);}
  if(timed) {
    await (await seek(host.page,'Abandon game')).click();
    await host.page.getByRole('button',{name:'End game for everyone',exact:true}).click();
    await expect.poll(async()=>(await db.query('SELECT status FROM app.rooms WHERE id=$1',[roomId])).rows[0].status).toBe('ABANDONED');
  }
  console.log(timed?'PASS: timed Flutter Web game, saved pause/resume budget, countdown and confirmed abandonment.':'PASS: four authenticated Flutter Web guests, invitation/start, 16 actual setup moves, roll, private seat restoration and lost-ack reload with the original command ID; portrait/landscape screenshots.');
} finally {
  await browser.close();
  if(roomId){await db.query('BEGIN');for(const table of ['outbox_events','move_logs','game_states','command_receipts','players','rooms'])await db.query(`DELETE FROM app.${table} WHERE ${table==='rooms'?'id':'room_id'}=$1`,[roomId]);await db.query('COMMIT');}
  await db.end();
}
