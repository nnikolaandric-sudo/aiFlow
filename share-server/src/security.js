import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
export const hash = value => createHash('sha256').update(value).digest('hex');
export const secret = () => randomBytes(32).toString('base64url');
export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const equal = (a,b) => typeof a==='string' && typeof b==='string' && timingSafeEqual(Buffer.from(hash(a)),Buffer.from(hash(b)));
export function fault(status, code) { return Object.assign(new Error(code),{status,code}); }
export function state(share, online, now=Date.now()) {
  if (share.revoked_at) return 'REVOKED';
  if (share.expires_at && Number(share.expires_at)<=now) return 'EXPIRED';
  if (!online) return 'OFFLINE';
  return 'ONLINE';
}
export function range(header, size) {
  if (!header) return {offset:0,length:size,partial:false};
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2]) || size===0) throw fault(416,'INVALID_RANGE');
  let start, end;
  if (!match[1]) { const suffix=Number(match[2]); if (!Number.isSafeInteger(suffix)||suffix<=0) throw fault(416,'INVALID_RANGE'); start=Math.max(0,size-suffix); end=size-1; }
  else { start=Number(match[1]); end=match[2]?Math.min(Number(match[2]),size-1):size-1; }
  if (!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>=size||start>end) throw fault(416,'INVALID_RANGE');
  return {offset:start,length:end-start+1,partial:true};
}
// Inline preview only for types browsers render natively without script
// execution. HTML/SVG/JS stay download-only: opened directly in a new tab
// they would run in the share origin and could abuse the session.
const previewTypes = new Set(['application/pdf',
  'image/png','image/jpeg','image/gif','image/webp','image/avif','image/bmp','image/x-icon','image/vnd.microsoft.icon',
  'text/plain','text/markdown','text/csv','text/tab-separated-values',
  'application/json','text/xml','application/xml','text/yaml','application/yaml','application/x-yaml','application/toml',
  'audio/mpeg','audio/mp4','audio/x-m4a','audio/ogg','audio/wav','audio/x-wav','audio/vnd.wave','audio/webm','audio/flac','audio/x-flac','audio/aac','audio/opus',
  'video/mp4','video/x-m4v','video/webm','video/ogg','video/quicktime']);
export function safePreview(mime) { return previewTypes.has(mime); }
// Text-like types are served with an explicit charset so browsers render
// UTF-8 correctly instead of sniffing or downloading.
export function previewContentType(mime) {
  if (mime.startsWith('text/') || ['application/json','application/xml','application/yaml','application/x-yaml','application/toml'].includes(mime)) return mime + '; charset=utf-8';
  return mime;
}
