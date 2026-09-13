import { readFileSync, readdirSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { Client } from 'pg';

// Run only against the configured local database, and detect fixture leakage.
const local=JSON.parse(readFileSync('.local/test-env.json','utf8'));
if(!['127.0.0.1','localhost'].includes(new URL(local.adminDatabaseUrl).hostname)) throw Error('Local tests require a local database');
const tables=['rooms','players','game_states','move_logs','outbox_events','command_receipts'];
async function counts() {
  const db=new Client({connectionString:local.adminDatabaseUrl});await db.connect();
  try {return Object.fromEntries(await Promise.all(tables.map(async table=>[table,(await db.query(`SELECT count(*)::int n FROM app.${table}`)).rows[0].n])));}
  finally {await db.end();}
}
const before=await counts();
const files=readdirSync('tests/local').filter(name=>name.endsWith('.test.mjs')).sort().map(name=>`tests/local/${name}`);
const child=spawn(process.execPath,['--test','--test-concurrency=1',...files],{stdio:'inherit'});
const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',code=>resolve(code??1));});
const after=await counts(),changed=tables.filter(table=>before[table]!==after[table]);
if(changed.length) {console.error('Local test residue:',JSON.stringify(Object.fromEntries(changed.map(table=>[table,{before:before[table],after:after[table]}]))));process.exitCode=1;}
else {console.log('Local fixture cleanup verified: all six application table counts unchanged.');process.exitCode=code;}
// Synthetic Supabase Auth users are intentionally outside this application-table check.
