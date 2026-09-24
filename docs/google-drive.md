# Google Drive in aiFlow (native, no Drive app)

aiFlow talks to Google Drive directly over the Drive API v3. You do **not**
need "Google Drive for Desktop" installed: aiFlow keeps a local **mirror**
folder per account and browses it like any other folder — double-click, Quick
Look, editor, search, tags and archives all work, because these are real files
on your disk.

If you *do* have Drive for Desktop installed, those folders still show up in the
sidebar (under the same "Google Drive" section) and `.gdoc`/`.gsheet` shortcuts
open in the browser instead of showing raw JSON.

---

## One-time setup: your own OAuth client ID

aiFlow ships without an embedded Google client secret — you connect with a
client ID you create yourself, so your Drive access is tied to your own Google
Cloud project and nobody else's.

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create (or
   pick) a project.
2. **APIs & Services → Enable APIs and Services → Google Drive API → Enable.**
3. **APIs & Services → OAuth consent screen** → External → fill in the app name
   and your email → add yourself under **Test users**.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID →
   Application type: Desktop app.**
5. Copy the **Client ID** (`…apps.googleusercontent.com`) into
   **aiFlow → Settings → Google Drive → Google Client ID** and press *Save*.
   One client ID covers every account you connect.

Then press **Connect Account**. Your browser opens Google's consent page;
aiFlow listens on a temporary `127.0.0.1` port for the callback (OAuth 2.0
loopback + PKCE, no client secret). Connect as many accounts as you like.

**Scopes requested:** `drive` (read/write — needed to mirror and to upload),
plus `userinfo.email` / `userinfo.profile` so the sidebar can label the account.
The refresh token is stored in your **login Keychain**, never on disk in clear
text; access tokens are cached in memory and refreshed automatically.

---

## Where files live

```
~/Library/Application Support/FinderFlow/GoogleDrive/<account>/My Drive/
```

That mirror root is what the sidebar entry opens. It is a normal folder — you
can move files in, rename them, edit them in any app.

Each synced item carries a hidden metadata **sidecar** next to it:

| item | sidecar |
|------|---------|
| `Report.docx` | `.Report.docx.gdrive.json` |
| `Projects/`   | `Projects/.gdrive.json` |

The sidecar holds the Drive file id, its modified time, md5/size and (for Google
Docs) the `webViewLink`. It's how aiFlow knows what's already synced, what
changed, and what a file's original on Drive is. Sidecars are dot-prefixed, so
they stay out of listings in both Finder and aiFlow. (Mirrors created by
earlier builds used visible `Report.docx.gdrive.json` names; those are still
read, and rewritten to the hidden form on the next sync.)

---

## What sync does

**Download (Drive → Mac)**

- Builds the tree from `parents` links, creates missing folders, downloads new
  and changed files (modified time, then md5/size as a fallback).
- Google Docs/Sheets/Slides are **exported** to `.docx` / `.xlsx` / `.pptx`
  (Drawings to `.pdf`) so they open locally. The original still lives on the
  web — double-click opens it in the browser; **⌥-double-click** opens the local
  export instead.
- Name collisions get a ` (2)` suffix; `/` in a Drive name becomes `:`.

**Upload (Mac → Drive)**

- New local files (no sidecar) are uploaded into the matching Drive folder;
  local folders that don't exist on Drive are created on the fly.
- Locally modified files (mtime newer than the sidecar's `lastSynced`) update
  the Drive file's content.
- Exported Google Docs are **not** uploaded back — a binary `.docx` would
  overwrite the live Google document. Edit those on the web.

**Deletions are never automatic.** A file that disappears from Drive stays on
your disk and is counted as *orphaned* (Settings shows the count) — nothing is
trashed behind your back, in either direction.

**Auto-sync** runs every 10 minutes when enabled (Settings → Google Drive), and
only for accounts idle for at least that long. Manual **Sync Now** lives in the
sidebar context menu; **Sync All** in Settings.

---

## Badges

In list, table and icon views, mirrored items get a small badge:

| badge | meaning |
|-------|---------|
| ✅ cloud | synced with Drive |
| 📄 blue doc | local export of a Google document — original is on the web |
| ↗️ blue | `.gdoc`/`.gsheet` shortcut from Drive for Desktop |
| ⬆️ orange | local file not on Drive yet (goes up in the next sync) |

The preview panel shows the same status as a line of text, with an **Open in
Drive** link for web-hosted originals.

Badges come from a per-folder index that is built off the main thread (one
directory listing plus the sidecars) and cached until that folder is refreshed,
so browsing a mirror stays as fast as browsing anything else.

---

## Limits (current build)

- Local deletions are not propagated to Drive (by design, for now).
- Shared Drives / "Shared with me" are not mirrored — My Drive only.
- One sync pass lists the whole account (fine up to ~10k files); very large
  accounts will feel the first pass.
- Two-way conflict resolution is conservative: if both sides changed, the local
  file is kept and uploaded.

---

## Troubleshooting

| symptom | fix |
|---------|-----|
| "Nalog nije povezan" / re-auth loop | Client ID missing or the consent screen no longer lists you as a test user. Re-enter the ID, press Connect again. |
| HTTP 403 right after connecting | Google Drive API isn't enabled in that Cloud project. |
| HTTP 429 | Google throttling — wait a minute and sync again. |
| Nothing downloads | Check the account row in Settings: the status line carries the exact error. |
| Sidecars visible in Finder | Mirror predates hidden sidecars — run one sync, they get renamed. |

---

## Offline test harness

The sync engine has a dependency-free harness (no network, no Keychain, no
Google account) that mocks the Drive API with `URLProtocol` and runs a full
reconcile into a temp mirror:

```bash
./tools/gdrive-test/run.sh
```

It covers sidecar naming and the legacy fallback, stub detection, download +
Google Docs export, idempotency of a second pass, badge classification, upload
of a new local file, and orphan counting.
