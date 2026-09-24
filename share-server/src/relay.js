import { WebSocketServer, WebSocket } from 'ws';
import { randomUUID } from 'node:crypto';
import { fault } from './security.js';
export const CHUNK = 256*1024;
export class Relay {
  constructor(server, authenticate, store) {
    this.devices=new Map(); this.streams=new Map(); this.fileStates=new Map(); this.revoked=new Map(); this.store=store;
    this.wss=new WebSocketServer({noServer:true,maxPayload:CHUNK+36,perMessageDeflate:false});
    server.on('upgrade', async (req,socket,head)=>{
      socket.on('error',()=>{});
      try {
        if(req.url!=='/device') throw fault(404,'NOT_FOUND');
        const device=await authenticate(req);
        this.wss.handleUpgrade(req,socket,head,ws=>this.attach(device,ws));
      } catch { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); }
    });
    this.heartbeat=setInterval(()=>{
      for(const ws of this.devices.values()) { if(!ws.alive) ws.terminate(); else {ws.alive=false;ws.ping();} }
    },15000); this.heartbeat.unref();
  }
  online(device) { return this.devices.get(device)?.readyState===WebSocket.OPEN; }
  attach(device,ws) {
    this.devices.get(device)?.terminate(); this.devices.set(device,ws); ws.alive=true;
    ws.on('pong',()=>{ws.alive=true;}); ws.on('error',()=>{});
    ws.on('message',(data,binary)=>this.message(ws,data,binary));
    ws.on('close',()=>{
      if(this.devices.get(device)===ws) this.devices.delete(device);
      for(const s of this.streams.values()) if(s.ws===ws) this.fail(s,503,'OFFLINE');
    });
  }
  send(ws,message) { if(ws.readyState===WebSocket.OPEN) ws.send(JSON.stringify(message)); }
  message(ws,data,binary) {
    let id,message;
    try {
      if(binary) id=data.subarray(0,36).toString();
      else { if(data.length>4096) return ws.close(1008); message=JSON.parse(data.toString()); id=message.requestId; }
      const s=this.streams.get(id);
      if(!s||s.ws!==ws) return;
      if(binary) {
        const chunk=data.subarray(36);
        if(!s.headers||!s.credit||chunk.length!==s.credit) return this.fail(s,502,'INVALID_CHUNK');
        s.credit=0; s.remaining-=chunk.length;
        // Credit is issued only when the previous HTTP write has flushed.
        s.res.write(chunk,err=>{if(err) this.fail(s,502,'TRANSFER_FAILED');else this.pull(s);});
      } else if(message.type==='preparing') {
        if(s.headers||Date.now()-s.started>600000)return this.fail(s,504,'TRANSFER_TIMEOUT');
        clearTimeout(s.timer);s.timer=setTimeout(()=>this.fail(s,504,'TRANSFER_TIMEOUT'),60000);
      } else if(message.type==='headers') {
        if(s.headers||Number(message.size)!==Number(s.share.file_size)||message.hash!==s.share.file_hash) return this.fail(s,409,'FILE_CHANGED');
        s.headers=true;
        s.res.writeHead(s.range.partial?206:200,s.responseHeaders);
        if(s.head) {s.res.end();this.finish(s);}
        else this.pull(s);
      } else if(message.type==='error') {
        if(['FILE_MISSING','FILE_CHANGED'].includes(message.code))this.fileStates.set(s.share.id,message.code);
        this.fail(s,409,['FILE_MISSING','FILE_CHANGED','REVOKED','EXPIRED'].includes(message.code)?message.code:'FILE_UNAVAILABLE');
      } else this.fail(s,502,'INVALID_FRAME');
    } catch { ws.close(1008,'Invalid protocol'); }
  }
  pull(s) {
    if(!this.streams.has(s.id)) return;
    if(s.remaining===0) {
      s.res.end(); this.finish(s);
      this.store.event(s.share.id,s.range.partial?'range_completed':(s.mode==='download'?'download_completed':'preview_completed')).catch(()=>{});
      return;
    }
    s.credit=Math.min(CHUNK,s.remaining);
    clearTimeout(s.timer); s.timer=setTimeout(()=>this.fail(s,504,'TRANSFER_TIMEOUT'),60000);
    this.send(s.ws,{type:'pull',requestId:s.id,length:s.credit});
  }
  start(share,res,range,mode,head,responseHeaders) {
    if(this.revoked.has(share.id))throw fault(410,'REVOKED');
    if(share.expires_at&&Number(share.expires_at)<=Date.now())throw fault(410,'EXPIRED');
    const ws=this.devices.get(share.device_id);
    if(!ws||ws.readyState!==WebSocket.OPEN) throw fault(503,'OFFLINE');
    if(this.streams.size>=64||[...this.streams.values()].filter(s=>s.ws===ws).length>=4) throw fault(429,'BUSY');
    const id=randomUUID();
    const s={id,ws,share,res,range,mode,head,responseHeaders,headers:false,remaining:range.length,credit:0,started:Date.now()};
    s.timer=setTimeout(()=>this.fail(s,504,'TRANSFER_TIMEOUT'),60000);
    this.streams.set(id,s);
    res.on('close',()=>this.finish(s));
    this.send(ws,{type:'fetch',requestId:id,shareId:share.id,offset:range.offset,length:range.length,mode,head});
  }
  finish(s) { if(!this.streams.delete(s.id))return; clearTimeout(s.timer);this.send(s.ws,{type:'cancel',requestId:s.id}); }
  fail(s,status,code) {
    this.finish(s);
    if(s.res.headersSent)s.res.destroy();else {s.res.writeHead(status,{'Content-Type':'application/json'});s.res.end(JSON.stringify({error:code}));}
  }
  revoke(id) { this.revoked.set(id,Date.now()); for(const s of this.streams.values())if(s.share.id===id)this.fail(s,410,'REVOKED'); }
  renew(id,expiry) { for(const s of this.streams.values())if(s.share.id===id)s.share.expires_at=expiry; }
  expire() { for(const [id,at] of this.revoked)if(Date.now()-at>600000)this.revoked.delete(id); for(const s of this.streams.values())if(s.share.expires_at&&Number(s.share.expires_at)<=Date.now())this.fail(s,410,'EXPIRED'); }
  close() { clearInterval(this.heartbeat); for(const s of this.streams.values())this.fail(s,503,'OFFLINE'); for(const ws of this.devices.values())ws.terminate();this.wss.close(); }
}
