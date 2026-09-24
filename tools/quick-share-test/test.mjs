import {spawn,execFileSync} from 'node:child_process';
import {mkdtempSync,rmSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import https from 'node:https';
const root=mkdtempSync(join(tmpdir(),'finderflow-quick-'));
const env={...process.env,FF_SHARE_TEST_MODE:'1',FF_SHARE_DIR:root};
const binary=resolve('build/quick-test/Contents/MacOS/QuickTest');
const command=(...args)=>execFileSync(binary,args,{env,encoding:'utf8'}).trim();
const publicTest=process.argv.includes('--public');
let proc,log='';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
try {
 const share=JSON.parse(command('seed'));
 proc=spawn(binary,[publicTest?'runtime':'serve'],{env,stdio:['ignore','pipe','pipe']});
 proc.stdout.on('data',x=>log+=x);proc.stderr.on('data',x=>process.stderr.write(x));
 let origin;
 for(let i=0;i<100;i++){
  if(publicTest){try{origin=JSON.parse(readFileSync(join(root,'quick-status.json'))).origin;}catch{}}
  else origin=log.trim();
  if(origin)break;await sleep(1000);
 }
 assert.ok(origin,'Server/tunnel did not become ready');
 console.log(publicTest?'Public Cloudflare tunnel allocated':'Local service started');
 let resolvedAddress;
 const request=async(path,options={})=>{
  if(!resolvedAddress){
   try{return await fetch(origin+path,{...options,signal:AbortSignal.timeout(10000)});}
   catch(error){
    if(!publicTest || !['ENOTFOUND','EAI_AGAIN'].includes(error.cause?.code))throw error;
    const host=new URL(origin).hostname;
    const dns=await (await fetch('https://cloudflare-dns.com/dns-query?name='+host+'&type=A',{headers:{Accept:'application/dns-json'}})).json();
    resolvedAddress=dns.Answer?.find(x=>x.type===1)?.data;assert.ok(resolvedAddress);
    console.log('System DNS missed new hostname; using public DNS answer with normal HTTPS certificate verification');
   }
  }
  return new Promise((resolve,reject)=>{
   const req=https.request(origin+path,{method:options.method||'GET',headers:options.headers,
    lookup:(_host,opts,cb)=>opts.all?cb(null,[{address:resolvedAddress,family:4}]):cb(null,resolvedAddress,4)},response=>{
    const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.on('error',reject);
    response.on('end',()=>{const headers=new Headers();for(const [k,v] of Object.entries(response.headers)){for(const value of Array.isArray(v)?v:[v])if(value!==undefined)headers.append(k,value);}
     resolve(new Response(options.method==='HEAD'?null:Buffer.concat(chunks),{status:response.statusCode,headers}));});
   });req.setTimeout(30000,()=>req.destroy(new Error('HTTPS timeout')));req.on('error',reject);req.end(options.body);
  });
 };
 let page;
  for(let i=0;i<20;i++){try{page=await request('/s');if(page.status===200)break;}catch{}await sleep(1500);}
  assert.equal(page?.status,200,'Public recipient page');assert.match(await page.text(),/aiFlow/);

 assert.equal((await request('/v1/shares')).status,404,'No public owner/admin API');
 const session=async(password,originHeader=origin)=>request('/v1/share-session',{method:'POST',headers:{'Content-Type':'application/json',Origin:originHeader},body:JSON.stringify({token:share.token,password})});
 assert.equal((await session(undefined,'https://evil.example')).status,403);
 assert.equal((await session()).status,401);
 assert.equal((await session('wrong-password')).status,401);
 let res=await session('test-password');assert.equal(res.status,200);
 const cookie=res.headers.get('set-cookie').split(';')[0],data=await res.json();
 assert.equal(data.id,share.id);assert.equal(data.filename,'Synthetic.txt');
 const path=`/r/${data.sessionId}/content?mode=download`;
 assert.equal((await request(path)).status,401);
 res=await request(path,{method:'HEAD',headers:{Cookie:cookie}});assert.equal(res.status,200);assert.equal(Number(res.headers.get('content-length')),share.size);
 res=await request(path,{headers:{Cookie:cookie,Range:'bytes=2-18'}});assert.equal(res.status,206);assert.equal((await res.arrayBuffer()).byteLength,17);
 res=await request(path,{headers:{Cookie:cookie,Range:'bytes=-4'}});assert.equal(res.status,206);assert.equal((await res.arrayBuffer()).byteLength,4);
 res=await request(path,{headers:{Cookie:cookie,Range:'bytes=99999999-'}});assert.equal(res.status,416);
 res=await request(path,{headers:{Cookie:cookie}});assert.equal(res.status,200);
 assert.equal(createHash('sha256').update(Buffer.from(await res.arrayBuffer())).digest('hex'),share.hash);
 console.log('Password, session, HEAD, Range, 3.7 MB streaming/hash checks passed');
 const second=await session('test-password'),secondData=await second.json(),secondCookie=second.headers.get('set-cookie').split(';')[0];
 assert.equal((await request(`/r/${secondData.sessionId}/content?mode=download`,{headers:{Cookie:secondCookie}})).status,403);
 assert.equal((await request(`/r/${secondData.sessionId}/content?mode=preview`,{headers:{Cookie:secondCookie,Range:'bytes=0-8'}})).status,206);
 if(publicTest){
  const oldOrigin=origin, oldPID=proc.pid;
  const processes=execFileSync('ps',['-axo','pid,ppid,command'],{encoding:'utf8'}).split('\n');
  const supervisor=processes.map(line=>line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/)).find(row=>row&&Number(row[2])===oldPID&&row[3].includes('--quick-tunnel'));
  assert.ok(supervisor,'Expected tunnel supervisor');
  const child=processes.map(line=>line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/)).find(row=>row&&Number(row[2])===Number(supervisor[1]));
  proc.kill('SIGKILL');await sleep(3500);
  if(child)assert.throws(()=>process.kill(Number(child[1]),0),'Cloudflare child must stop when owner crashes');
  proc=spawn(binary,['runtime'],{env,stdio:['ignore','pipe','pipe']});
  for(let i=0;i<100;i++){
   const status=JSON.parse(readFileSync(join(root,'quick-status.json')));
   if(status.pid===proc.pid&&status.origin&&status.origin!==oldOrigin){origin=status.origin;break;}
   await sleep(1000);
  }
  assert.notEqual(origin,oldOrigin,'Restart assigns a fresh hostname');resolvedAddress=undefined;
  let reopened;
  for(let i=0;i<20;i++){try{reopened=await session('test-password');if(reopened.status===200)break;}catch{}await sleep(1500);}
  assert.equal(reopened?.status,200);const reopenedData=await reopened.json();
  assert.equal(reopenedData.downloadCount,1,'Quota survives tunnel restart');
  console.log('Owner crash stops child, automatic restart changes hostname and preserves quota');
 }
 command('revoke',share.id);
 assert.equal((await session('test-password')).status,410);
 if(!publicTest)assert.equal((await request(path,{headers:{Cookie:cookie}})).status,410);
 console.log('Download limit, preview permissions and immediate revoke passed');
 if(publicTest){
  // Last revoked share must stop the runtime; public origin must be cleared.
  await sleep(2500);
  assert.equal(JSON.parse(readFileSync(join(root,'quick-status.json'))).origin,'');
  console.log('Automatic tunnel shutdown after last share revoked passed');
 } else {
  const another=JSON.parse(command('seed'));command('expire',another.id);
  res=await request('/v1/share-session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:another.token,password:'test-password'})});assert.equal(res.status,410);
  command('enabled','false');await sleep(500);
  await assert.rejects(request('/s'));
  console.log('Expiry and opt-out shutdown passed');
 }
} finally {proc?.kill('SIGKILL');await sleep(3000);rmSync(root,{recursive:true,force:true});}
