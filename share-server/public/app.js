'use strict';
const $=id=>document.getElementById(id);
let token=location.hash.slice(1), sessionId=null, password='', sealPollTimer=null;
history.replaceState(null,'','/s'); // Remove the long-lived secret from the visible address/history entry.
const messages={OFFLINE:'The device sharing this file is offline.',EXPIRED:'This share link has expired.',REVOKED:'The owner has revoked this share.',NOT_FOUND:'This link is invalid or incomplete.',PASSWORD_REQUIRED:'This file is protected by a password.',INVALID_PASSWORD:'That password is incorrect.',SESSION_EXPIRED:'Your access session expired. Reopen the original link.',DOWNLOAD_LIMIT_REACHED:'The download limit has been reached.',RATE_LIMITED:'Too many attempts. Please try again later.',FILE_MISSING:'The shared file is no longer available on the Mac.',FILE_CHANGED:'The shared copy has changed. Ask the owner for a new link.',BUSY:'The sharing device is busy. Try again shortly.',ALREADY_SIGNED:'This file was already signed — showing the current state.',INVALID_NAME:'Type your full name (up to 100 characters).',INVALID_SIGNATURE:'Draw your signature first, then sign.'};
function show(data) {
  $('filename').textContent=data.filename;
  const units=['bytes','KB','MB','GB','TB'];let amount=data.size,unit=0;while(amount>=1024&&unit<units.length-1){amount/=1024;unit++;}
  $('details').textContent=`${data.mimeType} · ${new Intl.NumberFormat(undefined,{maximumFractionDigits:1}).format(amount)} ${units[unit]}`;
  const online=data.status==='ONLINE';
  $('status').textContent=online?'Available now':(messages[data.status]||data.status);
  $('status').classList.toggle('online',online);
  $('preview').hidden=!online||!data.allowPreview;
  $('download').hidden=!online||!data.allowDownload||(!data.downloadGranted&&data.maxDownloads!==null&&data.downloadCount>=data.maxDownloads);
  if(online&&!data.downloadGranted&&data.maxDownloads!==null&&data.downloadCount>=data.maxDownloads)$('status').textContent=messages.DOWNLOAD_LIMIT_REACHED;
  $('preview').href=`/r/${sessionId}/content?mode=preview`;
  $('download').href=`/r/${sessionId}/content?mode=download`;
  $('expiry').textContent=data.expiresAt?`Available until ${new Date(data.expiresAt).toLocaleString()}`:'No scheduled expiration';
  $('unlock').hidden=true;$('retry').hidden=false;
  // Potpis preko linka: vlasnik ga uključuje per-link (default OFF).
  // PDF se urezuje (potpis postaje poslednja stranica), ime ostaje u imenu
  // fajla "… (signed by Ime)" + activity log.
  const approved=data.approvalName;
  const wantsSign=!!data.requireSignature;
  const sealStatus=data.sealStatus || (approved ? (data.mimeType === 'application/pdf' ? 'unknown' : 'signature_saved') : null);
  $('signbox').hidden=!online||(!wantsSign&&!approved);
  $('signform').hidden=!!approved;
  $('approved').hidden=!approved;
  if(approved){
    const when=data.approvalAt?new Date(data.approvalAt).toLocaleString():'';
    $('approved').innerHTML='';
    const check=document.createElement('span');check.className='check';check.setAttribute('aria-hidden','true');check.textContent='✓';$('approved').append(check,document.createTextNode(` Signed by ${data.approvalName}${when?' · '+when:''}`));
    if(data.mimeType==='application/pdf'){
      $('signinfo').textContent=sealStatus==='sealed'
        ?'Done — your signature was sealed into the PDF as its last page. The owner sees it in the file name and activity log.'
        :sealStatus==='signature_failed'
          ?(data.sealError || 'Your signature was saved, but the PDF could not be sealed. Ask the owner to retry.')
          :sealStatus==='unknown'
            ?'Signature received. The owner is finishing the PDF; reopen this link to check the final state.'
            :'Signature received. The owner’s Mac is sealing the PDF now; this page will update when it is ready.';
    } else {
      $('signinfo').textContent='Done — your signature was saved. The owner sees it in the file name and activity log.';
    }
  } else if(wantsSign){
    $('signinfo').textContent=data.mimeType==='application/pdf'
      ?'The owner asked for a signature. Draw below, type your full name, then sign — it becomes the last page of the PDF and the file is renamed to “(signed by Your Name)”.'
      :'The owner asked for a signature. Draw below, type your full name, then sign — the file is renamed to “(signed by Your Name)”.';
  }
  if(sealPollTimer)clearTimeout(sealPollTimer);
  if(online&&approved&&data.mimeType==='application/pdf'&&sealStatus==='sealing'){
    const poll=async()=>{
      try{
        const response=await fetch(`/r/${sessionId}/metadata`);
        const data=await response.json();
        if(!response.ok){
          if(data.error==='SESSION_EXPIRED'){
            sessionId=null;$('status').textContent=messages.SESSION_EXPIRED;$('preview').hidden=true;$('download').hidden=true;$('retry').hidden=false;return;
          }
          throw new Error(data.error||'Unable to refresh the sealing status');
        }
        show(data);
      }catch(error){
        $('signstatus').textContent='Still waiting for the sealed PDF. Retrying…';
        sealPollTimer=setTimeout(poll,3000);
      }
    };
    sealPollTimer=setTimeout(poll,1500);
  }
}
async function refreshState(){
  const response=await fetch(`/r/${sessionId}/metadata`);
  const data=await response.json();
  if(!response.ok)throw new Error(data.error);
  show(data);
}
async function connect() {
  $('status').textContent='Checking availability…';$('retry').disabled=true;
  try {
    const response=sessionId?await fetch(`/r/${sessionId}/metadata`):await fetch('/v1/share-session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token,...(password?{password}:{})})});
    const data=await response.json();
    if(!response.ok)throw new Error(data.error);
    sessionId=data.sessionId||sessionId;password='';$('password').value='';show(data);
  }catch(error){$('status').textContent=messages[error.message]||'Unable to connect. Please try again.';$('preview').hidden=true;$('download').hidden=true;$('retry').hidden=false;
    if(['PASSWORD_REQUIRED','INVALID_PASSWORD'].includes(error.message)){$('unlock').hidden=false;$('password').focus();}
    if(error.message==='SESSION_EXPIRED')sessionId=null;
  }finally{$('retry').disabled=false;}
}
// Pad bez eksternih biblioteka (CSP: script-src 'self'): Pointer Events za
// miš + touch, HiDPI skala, zaglađene kvadratne krive.
const pad=$('pad'), ctx=pad.getContext('2d');
let drawing=false, hasInk=false, last=null, mid=null;
function fitPad(){
  const dpr=Math.min(window.devicePixelRatio||1,3);
  const rect=pad.getBoundingClientRect();
  const w=Math.max(280,Math.round(rect.width*dpr)), h=Math.round(160*dpr);
  if(pad.width!==w||pad.height!==h){
    const old=hasInk?pad.toDataURL():null;
    pad.width=w;pad.height=h;
    if(old){const img=new Image();img.onload=()=>ctx.drawImage(img,0,0,w,h);img.src=old;}
  }
}
function padPos(e){
  const r=pad.getBoundingClientRect();
  return {x:(e.clientX-r.left)*(pad.width/r.width),y:(e.clientY-r.top)*(pad.height/r.height)};
}
function strokeTo(p){
  ctx.lineWidth=Math.max(2,pad.width/220);ctx.lineCap='round';ctx.lineJoin='round';
  ctx.strokeStyle=getComputedStyle(document.documentElement).color||'#18241f';
  ctx.beginPath();ctx.moveTo(last.x,last.y);ctx.quadraticCurveTo(last.x,last.y,mid.x,mid.y);ctx.lineTo(p.x,p.y);ctx.stroke();
}
function padStart(e){e.preventDefault();fitPad();drawing=true;hasInk=true;last=padPos(e);mid=last;$('padhint').hidden=true;$('signstatus').textContent='';syncBtn();try{pad.setPointerCapture(e.pointerId);}catch{}}
function padMove(e){if(!drawing)return;e.preventDefault();const p=padPos(e);mid={x:(last.x+p.x)/2,y:(last.y+p.y)/2};strokeTo(p);last=p;}
function padEnd(e){if(e)e.preventDefault();drawing=false;last=null;mid=null;syncBtn();}
function padClear(){ctx.clearRect(0,0,pad.width,pad.height);hasInk=false;$('padhint').hidden=false;$('signstatus').textContent='';syncBtn();}
function syncBtn(){
  const n=$('signname').value.trim().replace(/\s+/g,' ');
  $('signbtn').disabled=!n||!hasInk||n.length>100;
}
pad.addEventListener('pointerdown',padStart);
pad.addEventListener('pointermove',padMove);
pad.addEventListener('pointerup',padEnd);
pad.addEventListener('pointercancel',padEnd);
window.addEventListener('resize',()=>{if(!drawing)fitPad();});
fitPad();
$('clearpad').addEventListener('click',padClear);
$('signname').addEventListener('input',()=>{
  const n=$('signname').value.trim().replace(/\s+/g,' ');
  $('namecount').textContent=`${n.length}/100`;
  syncBtn();
});
$('signform').addEventListener('submit',async event=>{
  event.preventDefault();
  const name=$('signname').value.trim().replace(/\s+/g,' ');
  if(!name||name.length>100){$('signstatus').textContent=messages.INVALID_NAME;$('signname').focus();return;}
  if(!hasInk){$('signstatus').textContent=messages.INVALID_SIGNATURE;return;}
  $('signbtn').disabled=true;$('clearpad').disabled=true;$('signstatus').textContent='Sealing your signature…';
  try{
    const signature=pad.toDataURL('image/png');
    const response=await fetch(`/r/${sessionId}/approve`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,signature})});
    const data=await response.json();
    if(!response.ok)throw new Error(data.error);
    padClear();show({...data,sessionId});
    $('signstatus').textContent='';
  }catch(error){
    if(error.message==='ALREADY_SIGNED'){try{await refreshState();}catch{}$('signstatus').textContent=messages.ALREADY_SIGNED;}
    else $('signstatus').textContent=messages[error.message]||'Unable to sign. Please try again.';
  }
  finally{$('signbtn').disabled=false;$('clearpad').disabled=false;}
});
$('unlock').addEventListener('submit',event=>{event.preventDefault();password=$('password').value;connect();});
$('retry').addEventListener('click',connect);
if(token)connect();

if(location.protocol==='http:')document.querySelector('footer').textContent='Local development test. This loopback connection is not encrypted. Public sharing requires HTTPS.';

window.addEventListener('hashchange',()=>{if(location.hash)location.reload();});
