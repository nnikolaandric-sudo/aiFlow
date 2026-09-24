import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { createPublicKey, verify, randomUUID } from 'node:crypto';
import argon2 from 'argon2';
import { Relay } from './relay.js';
import { hash,secret,equal,uuidPattern,fault,state,range,safePreview,previewContentType } from './security.js';

export async function createServer({store,origin,enrollmentCode,allowHTTP=false}) {
  const base=new URL(origin);
  if(base.origin!==origin||(!allowHTTP&&base.protocol!=='https:')||!enrollmentCode||enrollmentCode.length<24) throw new Error('A canonical HTTPS origin and enrollment code (24+ characters) are required');
  if(allowHTTP&&!['127.0.0.1','localhost','[::1]'].includes(base.hostname))throw new Error('Development HTTP is loopback only');
  const challenges=new Map(),access=new Map(),limits=new Map(),locks=new Map(); let argonJobs=0;
  const staticFiles=new Map();
  for(const [path,file,type] of [['/s','index.html','text/html'],['/app.js','app.js','text/javascript'],['/style.css','style.css','text/css']])staticFiles.set(path,{data:await readFile(new URL(`../public/${file}`,import.meta.url)),type});
  function rate(key,max,period=60000) {
    const now=Date.now();let item=limits.get(key);
    if(!item||item.until<now){if(limits.size>10000)throw fault(429,'BUSY');item={count:0,until:now+period};limits.set(key,item);}
    if(++item.count>max)throw fault(429,'RATE_LIMITED');
  }
  async function expensive(fn) {if(argonJobs>=4)throw fault(429,'BUSY');argonJobs++;try{return await fn();}finally{argonJobs--;}}
  async function auth(req) {
    const token=req.headers.authorization?.replace(/^Bearer /,'');const grant=access.get(hash(token||''));
    if(!grant||grant.expires<Date.now()||!await store.device(grant.device))throw fault(401,'UNAUTHORIZED');return grant.device;
  }
  const server=http.createServer((req,res)=>{route(req,res).catch(error=>{
    if(res.headersSent){res.destroy();return;}
    json(res,error.status||500,{error:error.code||'SERVER_ERROR'});
  });});
  server.requestTimeout=15000;server.headersTimeout=10000;server.maxHeadersCount=40;
  const relay=new Relay(server,auth,store);
  const timer=setInterval(()=>{
    relay.expire();const now=Date.now();
    for(const [k,v]of challenges)if(v.expires<now)challenges.delete(k);
    for(const [k,v]of access)if(v.expires<now)access.delete(k);
    for(const [k,v]of limits)if(v.until<now)limits.delete(k);
  },1000);timer.unref();
  const cleanup=setInterval(()=>store.cleanup().catch(()=>{}),60000);cleanup.unref();
  function json(res,status,data,headers={}) {res.writeHead(status,{'Content-Type':'application/json; charset=utf-8',...headers});res.end(JSON.stringify(data));}
  function publicShare(s) {
    return {id:s.id,filename:s.filename,mimeType:s.mime_type,size:Number(s.file_size),allowPreview:s.allow_preview&&safePreview(s.mime_type),allowDownload:s.allow_download,expiresAt:s.expires_at?Number(s.expires_at):null,status:state(s,relay.online(s.device_id))==='ONLINE'?(relay.fileStates.get(s.id)||'ONLINE'):state(s,relay.online(s.device_id)),downloadCount:s.download_count,viewCount:s.view_count,maxDownloads:s.max_downloads,requireSignature:!!s.require_signature,approvalName:s.approval_name||null,approvalAt:s.approval_at?Number(s.approval_at):null};
  }
  // "Ugovor.pdf" + "Marko" → "Ugovor (signed by Marko).pdf". Ime fajla je
  // jedino mesto koje vlasnik sigurno vidi — zato se approval čuva u njemu.
  function approvedFilename(original, signer) {
    const clean = String(signer).replace(/[\x00-\x1f\x7f\/\\:*?"<>|]+/g, ' ').trim().slice(0, 60).trim() || 'signed';
    const display = clean === 'signed' ? 'signed' : `signed by ${clean}`;
    const dot = original.lastIndexOf('.');
    let base = dot > 0 ? original.slice(0, dot) : original;
    const ext = dot > 0 ? original.slice(dot + 1) : '';
    base = base.replace(/ \(signed( by .*)?\)$/, '').slice(0, 180) || 'file';
    return ext ? `${base} (${display}).${ext}` : `${base} (${display})`;
  }
  function validSignature(dataUrl) {
    if (typeof dataUrl !== 'string' || !dataUrl.startsWith('data:image/png;base64,')) return null;
    const b64 = dataUrl.slice(22);
    if (b64.length < 100 || b64.length > 700000) return null;
    let buf; try { buf = Buffer.from(b64, 'base64'); } catch { return null; }
    // PNG magic + minimalna veličina (prazan canvas otpada), max 500KB dekodirano.
    if (buf.length < 200 || buf.length > 500000) return null;
    if (buf[0] !== 0x89 || buf[1] !== 0x50 || buf[2] !== 0x4E || buf[3] !== 0x47) return null;
    return dataUrl;
  }
  function usable(s) {const status=state(s,relay.online(s.device_id));if(status==='EXPIRED'||status==='REVOKED')throw fault(410,status);}
  async function body(req) {
    if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']||''))throw fault(415,'JSON_REQUIRED');
    const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>16384)throw fault(413,'TOO_LARGE');chunks.push(chunk);}
    try {const b=JSON.parse(Buffer.concat(chunks));if(!b||Array.isArray(b)||typeof b!=='object')throw 0;return b;}catch{throw fault(400,'INVALID_JSON');}
  }
  // Approve nosi PNG potpisa (~do 500KB) pa ima veći limit od običnog body-ja.
  async function approvalBody(req) {
    if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']||''))throw fault(415,'JSON_REQUIRED');
    const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;if(size>1024*1024)throw fault(413,'TOO_LARGE');chunks.push(chunk);}
    try {const b=JSON.parse(Buffer.concat(chunks));if(!b||Array.isArray(b)||typeof b!=='object')throw 0;return b;}catch{throw fault(400,'INVALID_JSON');}
  }
  async function session(req,id) {
    const value=(req.headers.cookie||'').split(';').map(x=>x.trim()).find(x=>x.startsWith('ff_access='))?.slice(10);
    const s=await store.getSession(id);
    if(!s||Number(s.expires_at)<=Date.now()||!equal(s.secret_hash,hash(value||'')))throw fault(401,'SESSION_EXPIRED');return s;
  }
  async function serial(id,fn) {const prev=locks.get(id)||Promise.resolve();const next=prev.catch(()=>{}).then(fn);locks.set(id,next);try{return await next;}finally{if(locks.get(id)===next)locks.delete(id);}}
  async function route(req,res) {
    res.setHeader('Cache-Control','private, no-store');res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('X-Frame-Options','SAMEORIGIN');
    res.setHeader('Content-Security-Policy',"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-src 'self'; media-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'");
    if(!allowHTTP)res.setHeader('Strict-Transport-Security','max-age=31536000; includeSubDomains');
    if(req.headers.host!==base.host)throw fault(400,'INVALID_HOST');
    if(req.headers.origin&&req.headers.origin!==origin)throw fault(403,'INVALID_ORIGIN');
    if(req.headers['sec-fetch-site']==='cross-site'&&req.method!=='GET'&&req.method!=='HEAD')throw fault(403,'INVALID_ORIGIN');
    // Do not trust X-Forwarded-For. Reverse-proxy per-client limits supplement this budget.
    rate(`all:${req.socket.remoteAddress}`,3000);
    const url=new URL(req.url,origin),path=url.pathname,method=req.method;
    if(method==='GET'&&path==='/health'){await store.one('SELECT 1');return json(res,200,{ok:true});}
    if(method==='GET'&&staticFiles.has(path)){const f=staticFiles.get(path);res.writeHead(200,{'Content-Type':`${f.type}; charset=utf-8`});return res.end(f.data);}
    if(method==='POST'&&path==='/v1/devices/register'){
      rate(`register:${req.socket.remoteAddress}`,10);const b=await body(req);
      if(!equal(b.enrollmentCode,enrollmentCode))throw fault(401,'INVALID_ENROLLMENT');
      if(typeof b.publicKey!=='string'||!/^MCowBQYDK2VwAyEA[A-Za-z0-9+/]{43}=$/.test(b.publicKey)||typeof b.name!=='string'||b.name.length>100)throw fault(400,'INVALID_DEVICE');
      try{if(createPublicKey({key:Buffer.from(b.publicKey,'base64'),format:'der',type:'spki'}).asymmetricKeyType!=='ed25519')throw 0;}catch{throw fault(400,'INVALID_KEY');}
      const d=await store.register(randomUUID(),b.publicKey,b.name,Date.now());if(d.revoked_at)throw fault(403,'DEVICE_REVOKED');return json(res,200,{deviceId:d.id});
    }
    if(method==='POST'&&path==='/v1/devices/challenge'){
      rate(`auth:${req.socket.remoteAddress}`,120);const b=await body(req);if(!uuidPattern.test(b.deviceId)||!await store.device(b.deviceId))throw fault(401,'UNAUTHORIZED');
      if(challenges.size>10000)throw fault(429,'BUSY');const id=randomUUID(),nonce=secret();
      challenges.set(id,{device:b.deviceId,nonce,expires:Date.now()+60000});return json(res,200,{challengeId:id,nonce});
    }
    if(method==='POST'&&path==='/v1/devices/auth'){
      rate(`auth:${req.socket.remoteAddress}`,120);const b=await body(req),c=challenges.get(b.challengeId);challenges.delete(b.challengeId);
      if(!c||c.expires<Date.now()||typeof b.signature!=='string')throw fault(401,'UNAUTHORIZED');const d=await store.device(c.device);
      if(!d||!verify(null,Buffer.from(`finderflow-share-v1:${b.challengeId}:${c.nonce}`),createPublicKey({key:Buffer.from(d.public_key,'base64'),format:'der',type:'spki'}),Buffer.from(b.signature,'base64')))throw fault(401,'UNAUTHORIZED');
      if(access.size>10000)throw fault(429,'BUSY');const token=secret();access.set(hash(token),{device:c.device,expires:Date.now()+300000});return json(res,200,{accessToken:token});
    }
    if(path==='/v1/shares'&&method==='GET'){const device=await auth(req);return json(res,200,{shares:(await store.list(device)).map(publicShare)});}
    if(path==='/v1/shares'&&method==='POST'){
      const device=await auth(req);rate(`create:${device}`,30);const b=await body(req);
      if(!uuidPattern.test(b.id)||!/^([a-f0-9]{64})$/.test(b.tokenHash)||!/^([a-f0-9]{64})$/.test(b.fileHash)||typeof b.filename!=='string'||b.filename.length<1||b.filename.length>255||/[\x00-\x1f\x7f/\\]/.test(b.filename)||!Number.isSafeInteger(b.size)||b.size<0||typeof b.mimeType!=='string'||!/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/.test(b.mimeType)||typeof b.allowDownload!=='boolean'||typeof b.allowPreview!=='boolean'||(!b.allowPreview&&!b.allowDownload))throw fault(400,'INVALID_SHARE');
      if(b.allowPreview&&!safePreview(b.mimeType))throw fault(400,'PREVIEW_UNSUPPORTED');
      if(b.expiresAt!==null&&(!Number.isSafeInteger(b.expiresAt)||b.expiresAt<=Date.now()))throw fault(400,'INVALID_EXPIRY');
      if(b.maxDownloads!==null&&(!Number.isSafeInteger(b.maxDownloads)||b.maxDownloads<1||b.maxDownloads>1000000))throw fault(400,'INVALID_LIMIT');
      if(b.password!==undefined&&(typeof b.password!=='string'||b.password.length<8||b.password.length>256))throw fault(400,'INVALID_PASSWORD');
      if(b.requireSignature!==undefined&&typeof b.requireSignature!=='boolean')throw fault(400,'INVALID_SHARE');
      const existing=await store.share(b.id);
      if(existing){if(existing.device_id!==device||existing.token_hash!==b.tokenHash)throw fault(409,'CONFLICT');return json(res,200,publicShare(existing));}
      const passwordHash=b.password?await expensive(()=>argon2.hash(b.password,{type:argon2.argon2id,memoryCost:65536,timeCost:3,parallelism:1})):null;
      const s=await store.create({id:b.id,device_id:device,token_hash:b.tokenHash,filename:b.filename,mime_type:b.mimeType,file_size:b.size,file_hash:b.fileHash,allow_preview:b.allowPreview,allow_download:b.allowDownload,password_hash:passwordHash,created_at:Date.now(),expires_at:b.expiresAt,max_downloads:b.maxDownloads,require_signature:!!b.requireSignature});
      if(s.device_id!==device||s.token_hash!==b.tokenHash)throw fault(409,'CONFLICT');
      await store.event(s.id,'created');return json(res,201,publicShare(s));
    }
    const owned=/^\/v1\/shares\/([0-9a-f-]{36})(?:\/(revoke|renew|events|approval|sealed))?$/.exec(path);
    if(owned&&uuidPattern.test(owned[1])){
      const device=await auth(req),s=await store.share(owned[1]);if(!s||s.device_id!==device)throw fault(404,'NOT_FOUND');
      if((method==='DELETE'&&!owned[2])||(method==='POST'&&owned[2]==='revoke')){await store.revoke(s.id,device);relay.revoke(s.id);await store.event(s.id,'revoked');return json(res,200,{ok:true});}
      if(method==='POST'&&owned[2]==='renew'){const b=await body(req);if(b.expiresAt!==null&&(!Number.isSafeInteger(b.expiresAt)||b.expiresAt<=Date.now()))throw fault(400,'INVALID_EXPIRY');if(s.revoked_at)throw fault(410,'REVOKED');const updated=await store.renew(s.id,device,b.expiresAt);relay.renew(s.id,b.expiresAt);return json(res,200,publicShare(updated));}
      if(method==='GET'&&owned[2]==='events')return json(res,200,{events:await store.events(s.id)});
      if(method==='GET'&&owned[2]==='approval')return json(res,200,{approvalName:s.approval_name||null,approvalAt:s.approval_at?Number(s.approval_at):null,approvalSignature:s.approval_signature||null,filename:s.filename});
      if(method==='POST'&&owned[2]==='sealed'){
        const b=await body(req);
        if(!/^([a-f0-9]{64})$/.test(b.fileHash)||!Number.isSafeInteger(b.size)||b.size<=0||b.size>500*1024*1024)throw fault(400,'INVALID_SEAL');
        if(!s.approval_name)throw fault(409,'NOT_APPROVED');
        const updated=await store.seal(s.id,device,b.fileHash,b.size);
        if(!updated)throw fault(409,'NOT_APPROVED');
        await store.event(s.id,'sealed');return json(res,200,publicShare(updated));
      }
      if(method==='GET'&&!owned[2])return json(res,200,publicShare(s));
    }
    if(method==='POST'&&path==='/v1/share-session'){
      rate(`session:${req.socket.remoteAddress}`,60);const b=await body(req);
      if(typeof b.token!=='string'||! /^[A-Za-z0-9_-]{43}$/.test(b.token))throw fault(404,'NOT_FOUND');
      const s=await store.byToken(hash(b.token));if(!s)throw fault(404,'NOT_FOUND');usable(s);rate(`password:${s.id}`,20);
      if(s.password_hash){if(!b.password)throw fault(401,'PASSWORD_REQUIRED');if(typeof b.password!=='string'||b.password.length>256||!await expensive(()=>argon2.verify(s.password_hash,b.password)))throw fault(401,'INVALID_PASSWORD');}
      const id=randomUUID(),token=secret();await store.session({id,secret_hash:hash(token),share_id:s.id,expires_at:Date.now()+900000});await store.event(s.id,'opened');
      return json(res,200,{sessionId:id,...publicShare(s)},{'Set-Cookie':`ff_access=${token}; HttpOnly; SameSite=Strict; Path=/r/${id}/; Max-Age=900${allowHTTP?'':'; Secure'}`});
    }
    const recipient=/^\/r\/([0-9a-f-]{36})\/(metadata|content|approve)$/.exec(path);
    if(recipient&&uuidPattern.test(recipient[1])&&((method==='GET'||method==='HEAD')||(recipient[2]==='approve'&&method==='POST'))){
      const sessionId=recipient[1];const sess=await session(req,sessionId),s=await store.share(sess.share_id);usable(s);
      if(recipient[2]==='metadata'&&(method==='GET'||method==='HEAD'))return json(res,200,{...publicShare(s),downloadGranted:sess.download_granted});
      if(recipient[2]==='approve'&&method==='POST'){
        rate(`approve:${s.id}`,20);
        if(s.approval_name)throw fault(409,'ALREADY_SIGNED');
        const b=await approvalBody(req);
        const name = typeof b.name === 'string' ? b.name.trim().replace(/\s+/g, ' ') : '';
        if(!name||name.length>100||/[\x00-\x1f\x7f]/.test(name))throw fault(400,'INVALID_NAME');
        const sig = validSignature(b.signature);
        if(!sig)throw fault(400,'INVALID_SIGNATURE');
        const now = Date.now();
        const renamed = approvedFilename(s.filename, name);
        const updated = await serial(s.id, async () => store.approve(s.id, name, renamed, sig, now));
        if(!updated)throw fault(409,'ALREADY_SIGNED');
        await store.event(s.id,'approved');
        return json(res,200,publicShare(updated));
      }
      const mode=url.searchParams.get('mode');if(!['preview','download'].includes(mode))throw fault(400,'INVALID_MODE');
      if(mode==='preview'&&(!s.allow_preview||!safePreview(s.mime_type))||mode==='download'&&!s.allow_download)throw fault(403,'NOT_ALLOWED');
      if(!relay.online(s.device_id))throw fault(503,'OFFLINE');
      let r;try{r=range(req.headers['if-range']&&req.headers['if-range']!==`"${s.file_hash}"`?undefined:req.headers.range,Number(s.file_size));}catch(e){res.setHeader('Content-Range',`bytes */${s.file_size}`);throw e;}
      if(mode==='download'&&method!=='HEAD')await serial(sessionId,async()=>{
        const fresh=await store.getSession(sessionId);if(!fresh.download_granted){if(!await store.reserve(fresh,Date.now()))throw fault(403,'DOWNLOAD_LIMIT_REACHED');await store.event(s.id,'download_started');}
      });
      const headers={'ETag':`"${s.file_hash}"`,'Content-Type':previewContentType(s.mime_type),'Content-Length':r.length,'Accept-Ranges':'bytes','Content-Disposition':`${mode==='preview'?'inline':'attachment'}; filename="download"; filename*=UTF-8''${encodeURIComponent(s.filename).replace(/['()*]/g,c=>'%'+c.charCodeAt(0).toString(16))}`};
      if(r.partial)headers['Content-Range']=`bytes ${r.offset}-${r.offset+r.length-1}/${s.file_size}`;
      const current=await store.share(s.id);usable(current);
      relay.start(current,res,r,mode,method==='HEAD',headers);return;
    }
    throw fault(404,'NOT_FOUND');
  }
  return {server,relay,close:async()=>{clearInterval(timer);clearInterval(cleanup);relay.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}};
}
