import { readFile } from 'node:fs/promises';

export class Store {
  constructor(db) { this.db = db; }
  async init() { for (const sql of (await readFile(new URL('./schema.sql', import.meta.url), 'utf8')).split(';').filter(s=>s.trim())) await this.db.query(sql); }
  async one(sql, args = []) { return (await this.db.query(sql, args)).rows[0]; }
  async device(id) { return this.one('SELECT * FROM devices WHERE id=$1 AND revoked_at IS NULL', [id]); }
  async register(id, key, name, now) {
    return this.one('INSERT INTO devices(id,public_key,name,created_at) VALUES($1,$2,$3,$4) ON CONFLICT(public_key) DO UPDATE SET name=EXCLUDED.name RETURNING *', [id,key,name,now]);
  }
  async create(s) {
    const columns = ['id','device_id','token_hash','filename','mime_type','file_size','file_hash','allow_preview','allow_download','password_hash','created_at','expires_at','max_downloads','require_signature'];
    if (s.require_signature === undefined) s.require_signature = false;
    await this.db.query(`INSERT INTO shares(${columns.join(',')}) VALUES(${columns.map((_,i)=>`$${i+1}`).join(',')}) ON CONFLICT(id) DO NOTHING`, columns.map(k=>s[k]));
    return this.share(s.id);
  }
  async share(id) { return this.one('SELECT * FROM shares WHERE id=$1', [id]); }
  async byToken(hash) { return this.one('SELECT * FROM shares WHERE token_hash=$1', [hash]); }
  async list(device) { return (await this.db.query('SELECT * FROM shares WHERE device_id=$1 ORDER BY created_at DESC LIMIT 1000', [device])).rows; }
  async event(id, kind) { await this.db.query('INSERT INTO share_events(share_id,kind,created_at) VALUES($1,$2,$3)', [id,kind,Date.now()]); }
  async events(id) { return (await this.db.query('SELECT kind,created_at FROM share_events WHERE share_id=$1 ORDER BY created_at DESC LIMIT 100', [id])).rows; }
  async revoke(id, device) { return this.one('UPDATE shares SET revoked_at=$3 WHERE id=$1 AND device_id=$2 RETURNING *', [id,device,Date.now()]); }
  async renew(id, device, expiry) { return this.one('UPDATE shares SET expires_at=$3 WHERE id=$1 AND device_id=$2 AND revoked_at IS NULL RETURNING *', [id,device,expiry]); }
  // Potpis preko linka: samo jednom (approval_name IS NULL), uz rename filename-a
  // u "… (signed by Ime).ext" koji je server već sanitizovao.
  async approve(id, name, filename, signature, now) {
    return this.one(`UPDATE shares SET approval_name=$2, approval_at=$5, filename=$3, approval_signature=$4
      WHERE id=$1 AND revoked_at IS NULL AND approval_name IS NULL RETURNING *`, [id,name,filename,signature,now]);
  }
  // Urezivanje na Mac-u: posle approve-a vlasnikov Mac zapečati PDF (doda
  // stranicu) i gurne novi hash/size. Dozvoljeno samo uz postojeći approval,
  // samo hash/size se menjaju — ništa drugo.
  async seal(id, device, fileHash, fileSize) {
    return this.one(`UPDATE shares SET file_hash=$3, file_size=$4, sealed_at=COALESCE(sealed_at,$5), seal_error=NULL
      WHERE id=$1 AND device_id=$2 AND revoked_at IS NULL AND approval_name IS NOT NULL
      AND (sealed_at IS NULL OR (file_hash=$3 AND file_size=$4)) RETURNING *`, [id,device,fileHash,fileSize,Date.now()]);
  }
  async markSealError(id, device, error) {
    return this.one(`UPDATE shares SET seal_error=$3
      WHERE id=$1 AND device_id=$2 AND revoked_at IS NULL AND approval_name IS NOT NULL AND sealed_at IS NULL RETURNING *`, [id,device,error]);
  }
  async session(s) {
    await this.db.query('INSERT INTO share_sessions(id,secret_hash,share_id,expires_at) VALUES($1,$2,$3,$4)', [s.id,s.secret_hash,s.share_id,s.expires_at]);
    await this.db.query('UPDATE shares SET view_count=view_count+1 WHERE id=$1', [s.share_id]);
  }
  async getSession(id) { return this.one('SELECT * FROM share_sessions WHERE id=$1', [id]); }
  // One statement locks the share row. Concurrent sessions cannot exceed the quota.
  // The caller serializes attempts for the same session in this single-relay deployment.
  async reserve(session, now) {
    const s = await this.one(`UPDATE shares SET download_count=download_count+1
      WHERE id=$1 AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>$2)
      AND allow_download=true AND (max_downloads IS NULL OR download_count<max_downloads) RETURNING id`, [session.share_id,now]);
    if (!s) return false;
    await this.db.query('UPDATE share_sessions SET download_granted=true WHERE id=$1', [session.id]);
    return true;
  }
  async cleanup() {
    await this.db.query('DELETE FROM share_sessions WHERE expires_at<$1', [Date.now()]);
    await this.db.query('DELETE FROM share_events WHERE created_at<$1', [Date.now()-30*86400000]);
  }
}
