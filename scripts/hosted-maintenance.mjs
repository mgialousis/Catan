import { pathToFileURL } from 'node:url';
import { Client } from 'pg';
import { retain } from './retention.mjs';

export function operatorConfig(env) {
  const url=new URL(env.OPERATOR_DATABASE_URL);
  if(!['postgres:','postgresql:'].includes(url.protocol)||!url.password||['localhost','127.0.0.1','::1','[::1]'].includes(url.hostname))throw Error('A hosted operator connection is required; use local:retention locally');
  for(const key of ['sslmode','sslcert','sslkey','sslrootcert'])url.searchParams.delete(key);
  return {connectionString:url.toString(),ssl:{rejectUnauthorized:true},connectionTimeoutMillis:5000,statement_timeout:15000,query_timeout:20000};
}
export async function inventory(db) {
  const result={};
  for(const table of ['rooms','players','game_states','move_logs','outbox_events','command_receipts'])result[table]=(await db.query(`SELECT count(*)::int n FROM app.${table}`)).rows[0].n;
  result.databaseBytes=Number((await db.query('SELECT pg_database_size(current_database()) n')).rows[0].n);
  return result;
}
export async function maintain(env,args) {
  if(args.some(a=>!['--apply'].includes(a)))throw Error('Usage: hosted-maintenance.mjs [--apply]');
  const config=operatorConfig(env),host=new URL(config.connectionString).hostname;
  const apply=args.includes('--apply');
  if(apply&&env.OPERATOR_CONFIRM_HOST!==host)throw Error('Apply requires OPERATOR_CONFIRM_HOST to match the reviewed database host');
  const db=new Client(config);
  try {
    await db.connect();
    const role=(await db.query("SELECT current_user AS name, pg_has_role(current_user,'island_owner','MEMBER') AS owner")).rows[0];
    if(!role.owner||role.name==='island_runtime')throw Error('Use an operator with island_owner membership');
    const before=await inventory(db),result=await retain(db,{apply}),after=await inventory(db);
    return {host,before,result,after};
  }finally{await db.end();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  try{console.log(JSON.stringify(await maintain(process.env,process.argv.slice(2)),null,2));}
  catch{console.error('Maintenance did not complete. Check operator credentials, verified TLS, host confirmation and database availability.');process.exitCode=1;}
}
