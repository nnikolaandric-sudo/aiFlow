import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer as netServer } from 'node:net';
import { generateKeyPairSync, sign, randomUUID, randomBytes } from 'node:crypto';
import { mkdtemp,writeFile,rm,readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn,execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { WebSocket } from 'ws';
import { EventEmitter } from 'node:events';
import { Relay,CHUNK } from '../src/relay.js';
import { PGlite } from '@electric-sql/pglite';
import { Store } from '../src/store.js';
import { createServer } from '../src/server.js';
import { hash,secret,range } from '../src/security.js';
const exec=promisify(execFile), enrollment=secret();
let app,db,store,origin,owner,other,ws; const files=new Map(), requests=new Map();
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function api(route,{token,body,method=body?'POST':'GET',cookie,headers={}}={}) {
  const res=await fetch(origin+route,{method,headers:{...(body?{'Content-Type':'application/json'}:{}),...(token?{Authorization:`Bearer ${token}`} :{}),...(cookie?{Cookie:cookie}:{}),...headers},...(body?{body:JSON.stringify(body)}:{})});
  const text=await res.text();let data=text;if((res.headers.get('content-type')||'').startsWith('application/json')){try{data=JSON.parse(text);}catch{}}return {res,data};
}
async function device() {
  const keys=generateKeyPairSync('ed25519');
  const registered=await api('/v1/devices/register',{body:{enrollmentCode:enrollment,publicKey:keys.publicKey.export({format:'der',type:'spki'}).toString('base64'),name:'Synthetic test device'}});assert.equal(registered.res.status,200);
  const id=registered.data.deviceId, c=await api('/v1/devices/challenge',{body:{deviceId:id}});
  const signature=sign(null,Buffer.from(`finderflow-share-v1:${c.data.challengeId}:${c.data.nonce}`),keys.privateKey).toString('base64');
  const result=await api('/v1/devices/auth',{body:{challengeId:c.data.challengeId,signature}});assert.equal(result.res.status,200);
  assert.equal((await api('/v1/devices/auth',{body:{challengeId:c.data.challengeId,signature}})).res.status,401,'challenge cannot be replayed');
  return {id,token:result.data.accessToken,keys};
}
async function share(options={}) {
  const bytes=options.bytes||Buffer.from('synthetic share content 0123456789');const token=secret(),id=randomUUID();
  const payload={id,tokenHash:hash(token),filename:'test.txt',mimeType:'text/plain',size:bytes.length,fileHash:hash(bytes),allowPreview:true,allowDownload:true,expiresAt:Date.now()+3600000,maxDownloads:null,...options};delete payload.bytes;
  const r=await api('/v1/shares',{token:owner.token,body:payload});assert.equal(r.res.status,201,JSON.stringify(r.data));files.set(id,{bytes,hash:payload.fileHash});return {...payload,rawToken:token};
}
async function session(s,password) {
  const r=await api('/v1/share-session',{body:{token:s.rawToken,...(password?{password}:{})}});assert.equal(r.res.status,200,JSON.stringify(r.data));
  return {id:r.data.sessionId,cookie:r.res.headers.get('set-cookie').split(';')[0],data:r.data};
}
async function content(s,headers={},method='GET',mode='download') {return api(`/r/${s.id}/content?mode=${mode}`,{cookie:s.cookie,headers,method});}
before(async()=>{
  const tmp=netServer();await new Promise(r=>tmp.listen(0,'127.0.0.1',r));const port=tmp.address().port;await new Promise(r=>tmp.close(r));origin=`http://127.0.0.1:${port}`;
  db=new PGlite();store=new Store(db);await store.init();app=await createServer({store,origin,enrollmentCode:enrollment,allowHTTP:true});await new Promise(r=>app.server.listen(port,'127.0.0.1',r));
  owner=await device();other=await device();
  ws=new WebSocket(origin.replace('http','ws')+'/device',{headers:{Authorization:`Bearer ${owner.token}`}});await new Promise(r=>ws.once('open',r));
  ws.on('message',raw=>{
    const m=JSON.parse(raw);if(m.type==='fetch'){
      const file=files.get(m.shareId);if(!file){ws.send(JSON.stringify({type:'error',requestId:m.requestId,code:'FILE_MISSING'}));return;}
      requests.set(m.requestId,{file,offset:m.offset});ws.send(JSON.stringify({type:'headers',requestId:m.requestId,size:file.bytes.length,hash:file.hash}));
    }else if(m.type==='pull'){
      const r=requests.get(m.requestId);if(!r)return;const chunk=r.file.bytes.subarray(r.offset,r.offset+m.length);r.offset+=chunk.length;ws.send(Buffer.concat([Buffer.from(m.requestId),chunk]));
    }else if(m.type==='cancel')requests.delete(m.requestId);
  });
});
after(async()=>{ws?.terminate();await app?.close();await db?.close();});

test('range validation rejects multi-range, empty and overflow requests',()=>{
  assert.deepEqual(range('bytes=-3',10),{offset:7,length:3,partial:true});
  for(const r of ['bytes=0-1,3-4','bytes=-0','bytes=10-','bytes=4-2','bytes=99999999999999999999-','bytes=-'])assert.throws(()=>range(r,10));
  assert.throws(()=>range('bytes=0-',0));
});
test('registration requires enrollment and device proof; cross-device access denied',async()=>{
  assert.equal((await api('/v1/devices/register',{body:{enrollmentCode:'bad'}})).res.status,401);
  const s=await share();assert.equal((await api(`/v1/shares/${s.id}/revoke`,{token:other.token,method:'POST'})).res.status,404);
  assert.equal((await api('/v1/shares')).res.status,401);
  assert.equal((await api('/v1/shares',{token:owner.token,headers:{Origin:'https://attacker.invalid'}})).res.status,403);
});
test('fragment frontend has no external assets, analytics or persistent token storage',async()=>{
  const page=await api('/s');assert.equal(page.res.status,200);assert.match(page.res.headers.get('content-security-policy'),/default-src 'none'/);assert.equal(page.res.headers.get('cache-control'),'private, no-store');
  const js=(await api('/app.js')).data;assert.match(js,/history.replaceState/);assert.doesNotMatch(js,/localStorage|sessionStorage|https:\/\//);
});
test('full, HEAD, open and suffix Range transfers preserve bytes and count once per session',async()=>{
  const s=await share(), access=await session(s);
  const head=await content(access,{},'HEAD');assert.equal(head.res.status,200);assert.equal(head.data,'');assert.equal((await store.share(s.id)).download_count,0);
  const full=await content(access);assert.equal(full.res.status,200);assert.equal(full.data,files.get(s.id).bytes.toString());
  const partial=await content(access,{Range:'bytes=3-8'});assert.equal(partial.res.status,206);assert.equal(partial.data,files.get(s.id).bytes.subarray(3,9).toString());assert.match(partial.res.headers.get('content-range'),/^bytes 3-8\//);
  assert.equal((await content(access,{Range:'bytes=-4'})).data,'6789');
  assert.equal((await content(access,{Range:'bytes=20-'})).res.status,206);
  const bad=await content(access,{Range:'bytes=999999-'});assert.equal(bad.res.status,416);assert.match(bad.res.headers.get('content-range'),/^bytes \*\//);
  const matching=await content(access,{Range:'bytes=0-2','If-Range':`"${s.fileHash}"`});assert.equal(matching.res.status,206);
  const mismatched=await content(access,{Range:'bytes=0-2','If-Range':'"different-version"'});assert.equal(mismatched.res.status,200);assert.equal(mismatched.data,files.get(s.id).bytes.toString());
  assert.equal((await store.share(s.id)).download_count,1);
  assert.equal((await api(`/r/${access.id}/metadata`)).res.status,401);
});
test('download quota is atomic across concurrent sessions, including range requests',async()=>{
  const s=await share({maxDownloads:1});const a=await session(s),b=await session(s);
  const results=await Promise.all([content(a,{Range:'bytes=0-2'}),content(b,{Range:'bytes=0-2'})]);assert.deepEqual(results.map(r=>r.res.status).sort(),[206,403]);
  assert.equal((await store.share(s.id)).download_count,1);
});
test('password is Argon2id hashed; permissions and existing sessions obey revoke/expiry',async()=>{
  const s=await share({password:'synthetic-password',allowDownload:false});
  assert.equal((await api('/v1/share-session',{body:{token:s.rawToken}})).data.error,'PASSWORD_REQUIRED');
  assert.equal((await api('/v1/share-session',{body:{token:s.rawToken,password:'incorrect'}})).res.status,401);
  const a=await session(s,'synthetic-password');assert.equal((await content(a)).res.status,403);assert.equal((await content(a,{},'GET','preview')).res.status,200);
  const row=await store.share(s.id);assert.match(row.password_hash,/^\$argon2id\$/);assert.equal(row.token_hash,hash(s.rawToken));assert.ok(!JSON.stringify(row).includes(s.rawToken));
  await api(`/v1/shares/${s.id}/revoke`,{token:owner.token,method:'POST'});assert.equal((await content(a,{},'GET','preview')).res.status,410);
  const expired=await share();const e=await session(expired);await store.db.query('UPDATE shares SET expires_at=$2 WHERE id=$1',[expired.id,Date.now()-1]);assert.equal((await content(e)).data.error,'EXPIRED');
});
test('missing/changed files fail closed; empty files work; offline link is distinct',async()=>{
  const missing=await share();files.delete(missing.id);assert.equal((await content(await session(missing))).data.error,'FILE_MISSING');
  const changed=await share();files.get(changed.id).hash='0'.repeat(64);assert.equal((await content(await session(changed))).data.error,'FILE_CHANGED');
  const empty=await share({bytes:Buffer.alloc(0)});assert.equal((await content(await session(empty))).res.status,200);
  const s=await share();const a=await session(s);const peer=app.relay.devices.get(owner.id);app.relay.devices.delete(owner.id);assert.equal((await content(a)).data.error,'OFFLINE');app.relay.devices.set(owner.id,peer);
});
test('large concurrent streams stay chunk bounded and revoke interrupts an active response',async()=>{
  const s=await share({bytes:randomBytes(2*1024*1024)}), a=await session(s), b=await session(s);
  const results=await Promise.all([a,b].map(async access=>{const r=await fetch(`${origin}/r/${access.id}/content?mode=download`,{headers:{Cookie:access.cookie}});return Buffer.from(await r.arrayBuffer());}));
  for(const bytes of results)assert.equal(hash(bytes),s.fileHash);
  const large=await share({bytes:randomBytes(16*1024*1024)}), c=await session(large);
  const res=await fetch(`${origin}/r/${c.id}/content?mode=download`,{headers:{Cookie:c.cookie}});const reader=res.body.getReader();await reader.read();
  await api(`/v1/shares/${large.id}/revoke`,{method:'POST',token:owner.token});
  assert.equal([...app.relay.streams.values()].filter(s=>s.share.id===large.id).length,0);
  let total=0;try{while(true){const chunk=await reader.read();if(chunk.done)break;total+=chunk.value.length;}}catch{}
  assert.ok(total<large.size,'revoked transfer did not finish');
});
test('real Swift agent authenticates, resolves snapshots and streams through the relay', {skip:process.env.FF_SWIFT_SHARE_TEST!=='1',timeout:60000}, async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'ff-share-test-'));let child;
  try{
    const dev=await device();await writeFile(path.join(dir,'key'),dev.keys.privateKey.export({format:'der',type:'pkcs8'}).subarray(-32),{mode:0o600});
    const env={...process.env,FF_SHARE_TEST_MODE:'1',FF_SHARE_DIR:path.join(dir,'registry'),FF_SHARE_TEST_KEY:path.join(dir,'key')};
    const seed=fileURLToPath(new URL('../../build/local/share-test/seed',import.meta.url)),agent=fileURLToPath(new URL('../../build/local/share-test/agent',import.meta.url));
    const check=await exec(seed,['snapshot-check'],{env});assert.match(check.stdout,/passed/);
    const data=randomBytes(3*1024*1024+31),source=path.join(dir,'synthetic.bin');await writeFile(source,data);
    const created=JSON.parse((await exec(seed,['seed',origin,dev.id,source],{env})).stdout);const rawToken=secret();
    const r=await api('/v1/shares',{token:dev.token,body:{...created,tokenHash:hash(rawToken)}});assert.equal(r.res.status,201,JSON.stringify(r.data));
    await writeFile(source,Buffer.from('original changed after sharing'));
    child=spawn(agent,[],{env,stdio:['ignore','pipe','pipe']});let stderr='';child.stderr.on('data',b=>stderr+=b.toString());
    for(let i=0;i<100&&!app.relay.online(dev.id);i++){assert.equal(child.exitCode,null,stderr);await delay(100);}
    assert.equal(app.relay.online(dev.id),true,stderr);
    const access=await session({...created,rawToken});
    const response=await fetch(`${origin}/r/${access.id}/content?mode=download`,{headers:{Cookie:access.cookie}});assert.equal(response.status,200);assert.equal(hash(Buffer.from(await response.arrayBuffer())),hash(data));
    const slice=await fetch(`${origin}/r/${access.id}/content?mode=download`,{headers:{Cookie:access.cookie,Range:'bytes=262144-524287'}});assert.equal(slice.status,206);assert.deepEqual(Buffer.from(await slice.arrayBuffer()),data.subarray(262144,524288));
    const previous=app.relay.devices.get(dev.id);previous.terminate();
    for(let i=0;i<100;i++){if(app.relay.online(dev.id)&&app.relay.devices.get(dev.id)!==previous)break;await delay(100);}
    assert.ok(app.relay.online(dev.id)&&app.relay.devices.get(dev.id)!==previous,'agent reconnects');
    await exec(seed,['enabled','false'],{env});
    for(let i=0;i<50&&app.relay.online(dev.id);i++)await delay(100);
    assert.equal(app.relay.online(dev.id),false,'opt-out closes the connection');
    await exec(seed,['enabled','true'],{env});
    for(let i=0;i<100&&!app.relay.online(dev.id);i++)await delay(100);
    assert.equal(app.relay.online(dev.id),true,'opt-in reconnects');
    await exec(seed,['revoke',created.id],{env});assert.equal((await content(access)).data.error,'REVOKED');
  }finally{child?.kill('SIGTERM');if(child)await new Promise(r=>child.exitCode!==null?r():child.once('exit',r));await rm(dir,{recursive:true,force:true});}
});


test('relay withholds credit until recipient flush and rejects unsolicited data',()=>{
  const local=new Relay(new EventEmitter(),async()=>'',{event:async()=>{}});
  const sent=[],fakeWS={readyState:1,send:text=>sent.push(JSON.parse(text)),terminate(){}};
  local.devices.set('device',fakeWS);
  const res=new EventEmitter();res.headersSent=false;let flush;
  res.writeHead=()=>{res.headersSent=true;};res.write=(bytes,callback)=>{assert.equal(bytes.length,CHUNK);flush=callback;};res.end=()=>{};res.destroy=()=>{};
  const share={id:randomUUID(),device_id:'device',file_size:2*CHUNK,file_hash:'f'.repeat(64)};
  local.start(share,res,{offset:0,length:2*CHUNK,partial:false},'download',false,{});
  const id=sent[0].requestId;
  local.message(fakeWS,Buffer.from(JSON.stringify({type:'headers',requestId:id,size:2*CHUNK,hash:share.file_hash})),false);
  assert.equal(sent.at(-1).type,'pull');assert.equal(sent.at(-1).length,CHUNK);
  local.message(fakeWS,Buffer.concat([Buffer.from(id),Buffer.alloc(CHUNK)]),true);
  assert.equal(sent.filter(m=>m.type==='pull').length,1,'no new credit while HTTP is blocked');
  flush();assert.equal(sent.filter(m=>m.type==='pull').length,2);
  local.message(fakeWS,Buffer.concat([Buffer.from(id),Buffer.alloc(CHUNK+1)]),true);
  assert.equal(local.streams.size,0,'excess payload aborts stream');
  local.close();
});


test('renewal restores an expired retained share but cannot revive revoked shares',async()=>{
  const s=await share(),a=await session(s);
  await store.db.query('UPDATE shares SET expires_at=$2 WHERE id=$1',[s.id,Date.now()-1]);
  assert.equal((await content(a)).res.status,410);
  assert.equal((await api(`/v1/shares/${s.id}/renew`,{token:other.token,body:{expiresAt:Date.now()+60000}})).res.status,404);
  const renewed=await api(`/v1/shares/${s.id}/renew`,{token:owner.token,body:{expiresAt:Date.now()+60000}});
  assert.equal(renewed.res.status,200);assert.equal((await content(a)).res.status,200);
  await api(`/v1/shares/${s.id}/revoke`,{token:owner.token,method:'POST'});
  assert.equal((await api(`/v1/shares/${s.id}/renew`,{token:owner.token,body:{expiresAt:Date.now()+60000}})).res.status,410);
});
