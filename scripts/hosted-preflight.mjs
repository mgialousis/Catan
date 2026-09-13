import { performance } from 'node:perf_hooks';
import { randomUUID } from 'node:crypto';
import { io } from 'socket.io-client';
import { publicConfig } from './public-config.mjs';
const config=publicConfig(process.env);
const samples=[];
try {
  let ready=false;
  // A normal visit can wake a Free instance. This finite probe is not a keep-awake loop.
  for(let attempt=0;attempt<18&&!ready;attempt++){
    try{ready=(await fetch(`${config.API_URL}/health/ready`,{signal:AbortSignal.timeout(5000)})).ok;}catch{}
    if(!ready)await new Promise(resolve=>setTimeout(resolve,1000));
  }
  if(!ready)throw Error('Readiness unavailable');
  for(let n=0;n<10;n++){const start=performance.now();const r=await fetch(`${config.API_URL}/api/v1/version`,{signal:AbortSignal.timeout(5000)});const v=await r.json();if(!r.ok||v.protocolVersion!==1||v.rulesVersion!=='base-2020-v1')throw Error('Incompatible release');samples.push(performance.now()-start);}
  const web=await fetch(config.WEB_URL,{signal:AbortSignal.timeout(10000)});if(!web.ok||!web.headers.get('cache-control')?.includes('no-cache'))throw Error('Static entry point or cache policy unavailable');
  const denied=io(`${config.API_URL}/game`,{extraHeaders:{Origin:config.WEB_URL},transports:['websocket'],autoConnect:false,reconnection:false,auth:{accessToken:'invalid-preflight-token',protocolVersion:1,clientInstanceId:randomUUID()}});
  try{await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Auth probe timed out')),8000);denied.once('connect_error',error=>{clearTimeout(timer);if(error.data?.code==='UNAUTHENTICATED')resolve();else reject(Error('No explicit authentication rejection'));});denied.once('server.hello',()=>{clearTimeout(timer);reject(Error('Unauthenticated connection accepted'));});denied.connect();});}finally{denied.disconnect();}
  samples.sort((a,b)=>a-b);
  console.log(JSON.stringify({api:config.API_URL,web:config.WEB_URL,readiness:true,unauthenticatedConnectionDenied:true,versionRequestMs:{median:Math.round(samples[5]),p95:Math.round(samples[9])},note:'No guest or game created; authenticated four-client gameplay and ingress trust still require acceptance.'},null,2));
}catch{console.error('Hosted preflight failed. Check configured URLs, readiness, compatibility, TLS, auth and static cache policy.');process.exitCode=1;}
