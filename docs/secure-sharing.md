# aiFlow secure internet sharing

## Automatic Cloudflare links (default)

Users need **no Cloudflare account, server, domain, enrollment code, Node.js, Docker, Homebrew or separate cloudflared installation**. aiFlow bundles the official pinned Cloudflare client and serves the recipient page and file access API natively.

1. Open `build/local/aiFlow.app` after building with `./build-local.sh --no-run`.
2. Right-click one or more files/folders → **Share → Create Secure Link…** (or **Quick Link** for a 24h link with no dialog). Multiple items and folders are packed into a single `.zip` (download-only) — capped at 10 items, 1000 files inside and 500 MB total so the temporary tunnel isn't overloaded; larger selections get a clear error instead of a silent failure.
3. Choose expiry, preview/download permissions, an optional password and download limit.
4. Click **Create Link**, then **Copy Link**. A private snapshot is created and an HTTPS address under `trycloudflare.com` is assigned automatically.
5. Use **Shared Files** in the sidebar or File menu to copy current links, see activity, extend expiry or revoke access.

Only explicitly shared snapshots are reachable. Opening the share window alone makes no Cloudflare connection. No owner/administration API is exposed through the tunnel. Originals are unchanged. Files pass through Cloudflare during transfers; this is transport encryption, **not end-to-end encryption** or an independent encrypted cloud backup.

**Temporary means temporary:** quitting the serving app/helper, restarting the tunnel, or disabling sharing invalidates the old hostname. On restart, active shares receive links using the new hostname; copy and send the new links from Shared Files. Expiry is an upper bound and does not keep a tunnel alive. A new hostname can also need time to become visible through the recipient's DNS provider.

Keep the Mac awake and online. Closing the main window leaves aiFlow running. Optional **Keep sharing after quitting aiFlow** registers the bundled login helper; macOS may require approval in Login Items. Switching between app and helper can restart the tunnel and change its address. A transfer prevents idle sleep only while bytes are being sent; lid-close/intentional sleep is not prevented.

Cloudflare describes [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) as testing/development functionality without an uptime SLA, with a 200 in-flight-request limit. This option fulfills account-free temporary sharing; permanent links and guaranteed availability require a managed deployment. [Try Cloudflare](https://try.cloudflare.com/).

### Implementation and packaging

- `QuickShareServer.swift`: HTTP listener bound only to `127.0.0.1` on a random port, exact Host/Origin checks, bounded parsing, no incoming LAN listener, fixed route allowlist, at most 32 connections and four file streams. Chunks are 256 KiB with send backpressure.
- `QuickShareRuntime.swift`: opt-in lifecycle, private process lock, fresh status heartbeat, retries, pinned hostname parsing and readiness after Cloudflare confirms a registered tunnel connection. The app and helper cannot host the same registry concurrently.
- `FinderFlowShareAgent --quick-tunnel`: child supervisor tied to the owner's control pipe/parent lifetime. It terminates cloudflared when the owner exits, including a crash. Disabling sharing, revoking the final share or final expiry closes the listener/tunnel automatically.
- Secrets: 32-byte random token in the URL fragment, SHA-256 token digest in SQLite, original link secret in Keychain. Optional passwords use salted PBKDF2-HMAC-SHA256 with 600,000 rounds in native quick mode. The separate managed Node backend uses Argon2id.
- SQLite stores share records, atomic download-session counters and the latest 100 audit events per share. Browser sessions exist only in memory, expire after 15 minutes and are lost on restart. Neither filenames nor passwords appear in tunnel status/log output.
- `tools/cloudflare/manifest.json` pins cloudflared 2026.9.1 with official release archive SHA-256 hashes for arm64/x86_64. `bundle.py` downloads at **build time**, verifies archives, bundles binaries/assets/license notices and signs nested executables. The first build needs internet; cache is under `build/cloudflared`. Users install nothing separately.
- Quick Tunnel config is isolated from personal cloudflared configuration; metrics bind to loopback. The app uses outbound HTTP/2 over TLS to Cloudflare with standard certificate verification.
- An existing managed-server configuration is retained for its existing links; its behavior is documented below. New registries default to automatic mode.

### Verification commands

```sh
./tools/quick-share-test/run.sh           # native HTTP, passwords, session quota, ranges, revoke, expiry, opt-out
./tools/quick-share-test/run.sh --public  # real Cloudflare tunnel, synthetic data only
./tools/quick-share-test/ui.sh            # isolated native share window, test-only secret store
./tools/share-test/run.sh                # legacy managed-backend regression suite
./build-local.sh --no-run
codesign --verify --deep --strict build/local/aiFlow.app
```

Tests require both `FF_SHARE_TEST_MODE=1` and an isolated `FF_SHARE_DIR` to redirect secrets away from login Keychain. These flags must not be set for normal use. The public harness can use an independently resolved public DNS answer when macOS returns ENOTFOUND; it keeps normal hostname/certificate verification enabled and reports that fallback. This fallback belongs only to the test harness and does not alter the Mac's DNS settings.

## Optional managed server deployment

Use a dedicated origin, for example `https://share.your-domain.example`. The repository does not claim or configure `share.finderflow.app`.

Requirements: a Linux server with Docker Compose; DNS pointing the chosen hostname to that server; inbound 80/443 on the **server**. No incoming ports or router changes on the Mac.

```sh
cd share-server
cp .env.example .env
# Edit .env: SHARE_DOMAIN, POSTGRES_PASSWORD, ENROLLMENT_CODE.
# Generate each secret separately, for example:
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
docker compose up -d --build
```

The deployment supplies PostgreSQL 17, one relay/API service, and Caddy with automatic public TLS certificates. Only the proxy exposes host ports. PostgreSQL stores devices, share metadata, hashed tokens/passwords, expiring sessions, and minimal events; it never receives file bytes or bookmarks. Keep `.env` private and outside source control. Use URL-safe database password characters, as the password is interpolated into the database URL.

Health: `GET /health` queries the database. Check it through the public HTTPS origin, then register a Mac and verify a synthetic download from a different internet connection. Caddy has access logging disabled. Do not enable body/header/session logging or CDN document caching. Apply per-client abuse limits/WAF at your edge if the service is exposed to untrusted recipients; application limits deliberately do not trust arbitrary forwarded-IP headers. A shared reverse proxy therefore receives a shared application IP budget.

**One process / one relay replica only.** Device presence, authentication challenges, short-lived device grants, and stream routing live in that process. PostgreSQL share/session records survive a restart; devices reconnect and reauthenticate. This is an operationally usable single-server release, not the proposed multi-node Redis architecture. Do not scale replicas until shared auth state, Redis presence/routing, session serialization and cross-node cancellation are implemented.

Provisioning is server-admin enrollment with device-scoped ownership. It is not a SaaS user-account/billing/tenant system. Distribute the enrollment code only to trusted device owners and rotate it through the server configuration if disclosed. Rotation stops new enrollments with the old code; existing device keys continue working. Administrative device revocation currently uses the database `devices.revoked_at` field and a relay restart to terminate existing connections; there is no admin UI.

## Local storage and access

- `~/Library/Application Support/FinderFlow/SecureShares/shares.sqlite`: local SQLite registry and server configuration, with private directory/file permissions.
- `Snapshots/<UUID>`: read-only copied snapshots, local only. Copying may benefit from filesystem optimizations, but no space-saving or APFS clone guarantee is made.
- Local bookmark data maps a known share ID to its own snapshot. Network messages never supply a filesystem path.
- The main app and helper are currently **unsandboxed**. They use local persistent bookmarks; migrating to a sandboxed release requires an App Group, security-scoped access strategy and corresponding entitlements. Do not simply switch the sandbox entitlement on.
- Managed-mode device private keys and reusable link secrets live in login Keychain. The app and embedded helper must be signed consistently for distribution; test Keychain access on a signed/notarized build.
- Expired/revoked snapshots are cleaned by the running agent or revocation workflow. Renewal retains the local copy before contacting the server; an ambiguous failure can retain it longer without extending server access. Once removed, snapshots cannot be renewed; create a new link from the original. Original documents are never deleted by share cleanup.
- Snapshot/credential failures leave a blocked record. In automatic mode, a connection timeout retains the ready snapshot so Copy Link can retry without recopying. Managed-mode publication failures leave a blocked local record; retry Revoke to deny it at the server as well.

## Managed-server protocol and limits

1. Device enrollment uploads an Ed25519 SPKI public key using the admin enrollment code.
2. A one-use 60-second challenge is signed over `finderflow-share-v1:<challengeId>:<nonce>`. The server issues an opaque five-minute device bearer for owner APIs and the WebSocket handshake. A connected socket remains valid until disconnect; a fresh handshake needs fresh authentication.
3. One outbound `wss://<origin>/device` socket carries all transfers. Server `fetch` contains UUIDs, offset, length, mode and HEAD intent only.
4. Agent resolves a registered snapshot, opens it with `O_NOFOLLOW`, verifies regular-file type, size and SHA-256 on the **open descriptor**, then responds with `headers`. Hashing runs away from the UI; preparation status keeps the request alive, capped at ten minutes.
5. Relay sends `pull` credit for at most 256 KiB. The binary reply is the 36-byte ASCII request UUID followed by exactly that many bytes. The next credit is sent only after the previous HTTP write flushes. Compression is off. At most four streams/device and 64 streams/server are accepted; actual RSS is not benchmarked.
6. Cancellation, recipient disconnect, expiry, revoke and device disconnect close file handles and stop new credits. In-flight bytes already received cannot be recalled. Revoke aborts current HTTP streams; local revoke is checked on every pull.
7. `HEAD`, single byte ranges, suffix/open ranges, `206`, `416`, ETag and If-Range are supported. Multipart ranges are rejected.

In both modes, the recipient exchanges the fragment token via POST for a random HttpOnly/SameSite=Strict/Secure cookie scoped to `/r/<sessionId>/`. The URL fragment is removed from the visible history entry. Sessions last 15 minutes. Reopening the original link obtains a new session; a bare `/s` reload deliberately does not retain the long-lived token. Different share sessions use distinct cookie paths. Secrets are not stored in browser storage or query strings.

A download limit counts **download sessions granted**, not byte ranges or completed files. A session permits resumed/repeated requests for 15 minutes. HEAD/preview do not consume download slots. Concurrent new sessions reserve quota with an atomic conditional update (SQLite in automatic mode, PostgreSQL in managed mode). Failed starts can consume a slot, deliberately favoring the limit over accidental extra access. Preview permission necessarily allows receiving/copying the previewed bytes and is not DRM.

Preview covers PDF, raster images (PNG/JPEG/GIF/WebP/AVIF/BMP/ICO), text formats (plain, Markdown, CSV/TSV, JSON, XML, YAML, TOML, served as UTF-8 text), and common audio/video (MP3/M4A/Ogg/WAV/WebM/FLAC/AAC/Opus, MP4/M4V/WebM/Ogg/MOV). HTML/SVG/JS are never rendered inline on the share origin. DOCX and other unsupported formats are download-only. No document conversion, cloud payload storage, live-file mode, persistent encrypted sharing, E2EE or multi-relay clustering is included in v1.

## Build and verification

```sh
npm ci --prefix share-server
./tools/share-test/run.sh
./build-local.sh --no-run
```

The integration suite runs PostgreSQL SQL through PGlite (the PostgreSQL engine compiled to WASM), a real HTTP/WebSocket relay, and the actual Swift agent against synthetic temporary files. It never uses the user's real Keychain or share registry. `npm test --prefix share-server` runs backend tests alone and marks the Swift integration test skipped unless `FF_SWIFT_SHARE_TEST=1` is set and the harness has been built. A standalone Docker/PostgreSQL network deployment still requires a deployment smoke test.

The Xcode project and local build script both compile/embed/sign `FinderFlowShareAgent` and copy the SMAppService plist into `Contents/Library/LaunchAgents`. Xcode's embed build phase supports `ARCHS` for universal builds and bundles the corresponding Cloudflare executables. The Command Line Tools build is arm64. Login-item registration, production signing/notarization, managed deployment public DNS/TLS, independent-network reachability and multi-gigabyte load/RSS measurements must be validated on the deployment host and signed distribution. See the verification record for the synthetic public Cloudflare test and its system-DNS limitation.

For local browser QA after compiling the harness:

```sh
node share-server/test/preview-fixture.js
```

This prints a local synthetic share URL, runs an in-memory test database and the real Swift agent, and cleans up on Ctrl-C. It only listens on 127.0.0.1 and must never be deployed. `FF_SHARE_DIR` isolates local data in harnesses; the private-key file override requires both `FF_SHARE_TEST_MODE=1` and `FF_SHARE_DIR` and is only for synthetic tests.

## Source references

- [Apple: SMAppService agent registration and bundle location](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:))
- [ws: protocol and WebSocket API](https://github.com/websockets/ws/blob/master/doc/ws.md)
- [PostgreSQL: conditional UPDATE and RETURNING](https://www.postgresql.org/docs/current/sql-update.html)
