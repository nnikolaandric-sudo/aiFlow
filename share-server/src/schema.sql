CREATE TABLE IF NOT EXISTS devices (
 id uuid PRIMARY KEY, public_key text NOT NULL UNIQUE, name text NOT NULL,
 created_at bigint NOT NULL, revoked_at bigint
);
CREATE TABLE IF NOT EXISTS shares (
 id uuid PRIMARY KEY, device_id uuid NOT NULL REFERENCES devices(id), token_hash text NOT NULL UNIQUE,
 filename text NOT NULL, mime_type text NOT NULL, file_size bigint NOT NULL, file_hash text NOT NULL,
 allow_preview boolean NOT NULL, allow_download boolean NOT NULL, password_hash text,
 created_at bigint NOT NULL, expires_at bigint, revoked_at bigint,
 max_downloads integer, download_count integer NOT NULL DEFAULT 0, view_count integer NOT NULL DEFAULT 0,
 require_signature boolean NOT NULL DEFAULT false,
 approval_name text, approval_at bigint, approval_signature text
);
CREATE TABLE IF NOT EXISTS share_sessions (
 id uuid PRIMARY KEY, secret_hash text NOT NULL, share_id uuid NOT NULL REFERENCES shares(id),
 expires_at bigint NOT NULL, download_granted boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS share_events (
 id bigserial PRIMARY KEY, share_id uuid NOT NULL REFERENCES shares(id), kind text NOT NULL, created_at bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS shares_device_idx ON shares(device_id);
CREATE INDEX IF NOT EXISTS events_share_idx ON share_events(share_id, created_at);
CREATE INDEX IF NOT EXISTS sessions_expiry_idx ON share_sessions(expires_at);
-- Migracija postojećih baza: IF NOT EXISTS je idempotentno.
ALTER TABLE shares ADD COLUMN IF NOT EXISTS require_signature boolean NOT NULL DEFAULT false;
ALTER TABLE shares ADD COLUMN IF NOT EXISTS approval_name text;
ALTER TABLE shares ADD COLUMN IF NOT EXISTS approval_at bigint;
ALTER TABLE shares ADD COLUMN IF NOT EXISTS approval_signature text;
