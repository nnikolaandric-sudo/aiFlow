# Secure Share verification — 2026-09-23

Verified in this checkout with Node 22.21.1 and Swift 6.3.3 on Apple Silicon.

## Automatic Cloudflare mode

- `./tools/quick-share-test/run.sh`: native loopback HTTP service passed password/session protection, hostile Origin refusal, absent owner API, HEAD, byte/suffix/invalid ranges, full 3.7 MB transfer with matching SHA-256, persisted download quota, preview permission, revoke, expiry and opt-out shutdown.
- `./tools/quick-share-test/run.sh --public`: real account-free `trycloudflare.com` HTTPS tunnel passed recipient-page, password/session, HEAD/Range/full-transfer hash, quota, preview and revoke checks using synthetic data only.
- Public lifecycle test killed the serving process, checked that its supervised cloudflared child stopped, restarted the runtime, confirmed a different hostname, reopened the same share and verified that the consumed quota survived. Revoking the final share cleared the origin and shut down the tunnel.
- macOS system DNS intermittently returned ENOTFOUND for freshly allocated hostnames. The HTTP harness then used Cloudflare public DNS answers with normal TLS hostname/certificate verification. No DNS settings or TLS protections were changed. This is not a test from a separate physical network.
- Native `SecureShareView` was launched against an isolated registry/secret store. **Create Link** automatically returned a public HTTPS link without server/account inputs. That exact link opened successfully in the in-app browser, showed the filename/size/expiry and rendered the synthetic text through Preview. GUI Revoke blocked the share and the public URL subsequently returned Cloudflare's tunnel-offline page.
- A UTF-8 response-header correction was added after the text-preview check; native HTTP tests subsequently passed. No PDF/video rendering or large-file/RSS performance claim is made.
- No user documents, real share registry or login-Keychain secrets were used. Temporary public test shares were revoked/stopped and test processes/directories cleaned up.
- Cloudflare 2026.9.1 arm64 archive SHA-256 verified during packaging; executable and license/notice files included in app. Intel/universal builds and production notarization were not exercised.

## Managed-server regression and packaging

- `./build-local.sh --no-run`: passed. Main application and embedded Share Agent compiled, packaged and ad-hoc signed.
- `codesign --verify --deep --strict build/local/FinderFlow.app`: passed.
- `./tools/share-test/run.sh`: **11 tests passed, zero failures or skipped tests**. Includes the actual Swift agent, temporary snapshots and isolated test signing keys.
- Covered: device signature/replay checks, cross-device ownership, token/session secrecy, passwords, permissions, full/HEAD/Range/If-Range, concurrent quota reservation, expiry, revoke during transfer, bounded credit, malformed data rejection, missing/changed files, zero-length files, snapshot integrity/symlink refusal, snapshot cleanup, agent reconnect and opt-out, and renewal.
- SQL ran on the PostgreSQL engine through PGlite. Docker Compose configuration parsed successfully with synthetic settings, but Docker daemon was unavailable, so a networked PostgreSQL/container deployment was not run.
- Production dependency audit: zero known vulnerabilities at verification time (`npm audit --omit=dev`).
- Recipient page: a real locally served share displayed the synthetic file, its byte size, availability, expiration, Preview and Download actions. No warning/error console entries were observed. The in-app browser blocked direct content navigation, so browser-native document rendering/download UI is not asserted; HTTP preview/download and byte integrity were verified by the integration suite.
- Native SecureShareView: opened in an isolated preview application with synthetic data; controls, live server metadata and activity display were inspected. No user's existing share registry, Keychain secrets or documents were used for the integration/browser preview tests. Automatic-mode GUI creation is covered above using the isolated secret store. Production Keychain prompts still need a signed-build user acceptance check.
- Project/plist validation, Compose configuration validation and `git diff --check` passed. Existing unrelated changes remain in the worktree; nothing was committed or pushed.

Not established by these checks: managed-server public deployment, reachability from a separate physical network, signed/notarized Keychain sharing, macOS approval/persistence of the login agent, Xcode universal distribution builds, multi-gigabyte memory/throughput benchmarks, or a clustered deployment. Deployment instructions and operational limits are in [secure-sharing.md](secure-sharing.md).
