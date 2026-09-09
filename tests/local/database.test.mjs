import test, { before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
process.loadEnvFile('.env');
const local = JSON.parse(readFileSync('.local/test-env.json', 'utf8'));
if (!['127.0.0.1', 'localhost'].includes(new URL(local.adminDatabaseUrl).hostname)) throw new Error('Tests require a local database');
const db = new Client({ connectionString: local.adminDatabaseUrl });
const settings = { maxPlayers: 4, turnLimitSeconds: null, boardMode: 'STANDARD_RANDOM', rulesVersion: 'base-2020-v1' };
before(() => db.connect()); after(() => db.end());
beforeEach(() => db.query('BEGIN')); afterEach(() => db.query('ROLLBACK'));
async function denied(query, params, code = '42501', connection = db) {
  await connection.query('SAVEPOINT expected_failure');
  await assert.rejects(connection.query(query, params), error => error.code === code);
  await connection.query('ROLLBACK TO SAVEPOINT expected_failure');
}
async function fixture() {
  const user = randomUUID(), room = randomUUID(), player = randomUUID();
  await db.query('INSERT INTO auth.users(id) VALUES ($1)', [user]);
  await db.query('INSERT INTO app.rooms(id,created_by_user_id,active_slot,settings,invitation_hash) VALUES ($1,$2,1,$3,$4)', [room,user,settings,room.replaceAll('-', '').repeat(2)]);
  await db.query("INSERT INTO app.players(id,room_id,auth_user_id,nickname,nickname_key,seat_index) VALUES ($1,$2,$3,'Tester','tester',0)", [player,room,user]);
  await db.query('UPDATE app.rooms SET host_player_id=$1 WHERE id=$2', [player,room]);
  return { user, room, player };
}
test('all application tables have RLS; runtime role is restricted and separate from owner', async () => {
  const result = await db.query("SELECT relrowsecurity, pg_get_userbyid(relowner) AS owner FROM pg_class JOIN pg_namespace ON pg_namespace.oid=relnamespace WHERE nspname='app' AND relkind='r'");
  assert.equal(result.rowCount, 8);
  for (const row of result.rows) { assert.equal(row.relrowsecurity, true); assert.equal(row.owner, 'island_owner'); }
  const role = (await db.query("SELECT rolsuper,rolcreatedb,rolcreaterole,rolbypassrls FROM pg_roles WHERE rolname='island_runtime'")).rows[0];
  assert.ok(Object.values(role).every(value => value === false));
});
test('client roles have no application schema access; runtime cannot create tables or edit audit records', async () => {
  for (const role of ['anon','authenticated']) {
    await db.query(`SET LOCAL ROLE ${role}`);
    await denied('SELECT * FROM app.rooms');
    await denied('UPDATE app.rooms SET revision=1');
    await db.query('RESET ROLE');
  }
  const runtime = new Client({ connectionString: process.env.DATABASE_URL });
  await runtime.connect();
  try {
    await runtime.query('BEGIN');
    await runtime.query('SELECT * FROM app.runtime_control');
    for (const query of ['CREATE TABLE app.forbidden(id integer)', "UPDATE app.move_logs SET command_type='forged'", 'DELETE FROM app.command_receipts', "UPDATE app.outbox_events SET private_payloads='{}'"]) await denied(query, undefined, '42501', runtime);
  } finally { await runtime.query('ROLLBACK'); await runtime.end(); }
});
test('host creation cycle validates at commit and one ongoing slot is enforced', async () => {
  const { room, user } = await fixture();
  await db.query('SET CONSTRAINTS ALL IMMEDIATE');
  await denied('INSERT INTO app.rooms(created_by_user_id,active_slot,settings,invitation_hash) VALUES ($1,1,$2,$3)', [user,settings,'f'.repeat(64)], '23505');
  await denied('UPDATE app.rooms SET host_player_id=null WHERE id=$1', [room], '23514');
  await denied("UPDATE app.rooms SET status='PAUSED', active_slot=null WHERE id=$1", [room], '23514');
});
test('seat count, duplicate nickname and same-room host constraints hold', async () => {
  const { room, player } = await fixture();
  const user = randomUUID(); await db.query('INSERT INTO auth.users(id) VALUES ($1)', [user]);
  await denied("INSERT INTO app.players(room_id,auth_user_id,nickname,nickname_key,seat_index) VALUES ($1,$2,'Other','other',4)", [room,user], '23514');
  await denied("INSERT INTO app.players(room_id,auth_user_id,nickname,nickname_key,seat_index) VALUES ($1,$2,'TESTER','tester',1)", [room,user], '23505');
  await db.query('SET CONSTRAINTS ALL IMMEDIATE');
  await denied('UPDATE app.rooms SET host_player_id=$1 WHERE id=$2', [randomUUID(),room], '23503');
  await db.query('UPDATE app.rooms SET host_player_id=$1 WHERE id=$2', [player,room]);
});
test('receipt uniqueness and final-only statuses prevent pending or duplicate durable records', async () => {
  const command = randomUUID();
  const args = ['user:'+randomUUID(), command, 'a'.repeat(64)];
  await db.query("INSERT INTO app.command_receipts(actor_key,command_id,request_hash,status) VALUES ($1,$2,$3,'ACCEPTED')", args);
  await denied("INSERT INTO app.command_receipts(actor_key,command_id,request_hash,status) VALUES ($1,$2,$3,'ACCEPTED')", args, '23505');
  await denied("INSERT INTO app.command_receipts(actor_key,command_id,request_hash,status) VALUES ($1,$2,$3,'PENDING')", ['user:'+randomUUID(), randomUUID(), 'b'.repeat(64)], '23514');
});
