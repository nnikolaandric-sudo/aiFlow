<div align="center">

<img src="docs/assets/icon.png" alt="aiFlow" width="120" height="120" />

# aiFlow

<sub>Built on <a href="https://github.com/Gtarafdar/FinderFlow">FinderFlow</a> by Gobinda Tarafdar (MIT). The bundle ID and folders on disk keep the FinderFlow name, so settings carry over.</sub>

**The Mac file manager Finder should have shipped.**

A fast, native macOS file browser with a built-in code editor, a Markdown
reader, real Finder-compatible color tags, Spotlight search, archive tools, and
one-click "open in Terminal / VS Code / Cursor / Claude Code / Codex" — in one
self-contained app that runs entirely on your Mac.

[![Latest release](https://img.shields.io/github/v/release/nnikolaandric-sudo/FinderFlow?label=release&color=2D52E0)](../../releases)
[![Downloads](https://img.shields.io/github/downloads/nnikolaandric-sudo/FinderFlow/total?color=2D52E0)](../../releases)
![Platform](https://img.shields.io/badge/macOS-14%2B-2D52E0)
![Apple Silicon](https://img.shields.io/badge/Mac-Apple%20Silicon-444)
[![License](https://img.shields.io/badge/License-MIT-444)](LICENSE)
[![Stars](https://img.shields.io/github/stars/nnikolaandric-sudo/FinderFlow?style=flat&color=FF6B5C)](../../stargazers)

**[⬇ Download the latest release](../../releases/latest)** ·
**[🌐 Landing page](https://nnikolaandric-sudo.github.io/FinderFlow/)** ·
**[⭐ Star](../../stargazers)** ·
**[❤️ Donate](https://gtarafdar.com/donate)**

`macOS 14+` · `Apple Silicon` · `≈ 27 MB` · `Free & open source (MIT)`

</div>

---

## What it is

aiFlow is a **drop-in alternative to the macOS Finder** for people who live
in their files all day — developers, writers, designers, and anyone who has ever
wished Finder did *more*. It keeps everything you like about Finder (column /
list / icon views, Quick Look, tags, the sidebar) and adds the things you
normally reach for three other apps to get.

It's **one download, fully self-contained** — no Homebrew, no Node, no runtimes,
no plugins. Everything runs locally on your Mac by default. There is **no telemetry and no required cloud account**. Networking happens only
when you explicitly enable or use a connected feature: AI Organizer (OpenRouter), Send to
Discord, Check for Updates (GitHub Releases), or configured Secure Share (including its optional background agent).

|  Browse, tag & search  |  Edit code — built in  |
| :---: | :---: |
| ![List view with color tags](docs/assets/shot-list.png) | ![Built-in code editor with minimap](docs/assets/shot-editor.png) |
| Color tags, Spotlight search, sortable columns, copy-path | Tabs, syntax highlighting, command palette, Sublime-style minimap |
|  Column view + preview  |  Icon view + color tags  |
| ![Column view with preview pane](docs/assets/shot-columns.png) | ![Icon view filtered by the Red tag](docs/assets/shot-tags.png) |
| Finder-style miller columns with a live preview & Get Info pane | Resizable icon grid; tap a tag to filter Mac-wide |
|  Markdown — read mode  |  Markdown — edit mode  |
| ![Markdown reader](docs/assets/shot-md-read.png) | ![Markdown editor](docs/assets/shot-md-edit.png) |
| Rendered preview (no Obsidian needed) | Edit & save with ⌘S, auto-save on close |

> 🌐 **[See the interactive showcase on the landing page →](https://nnikolaandric-sudo.github.io/FinderFlow/#showcase)**

---

## Why you'll want it — things macOS Finder can't do

These are the headline reasons people switch. **None of them ship in Finder.**

- **📝 A real code editor, built in.** Double-click any text or code file and it
  opens in a proper editor — tabs, syntax highlighting for dozens of languages, a
  fuzzy **command palette (⌘⇧P)**, Sublime keybindings, and a **Sublime-style
  minimap**. You don't need to install Sublime Text or VS Code just to make a
  quick edit.
- **📖 A Markdown reader *and* editor.** Open `.md` files into a clean rendered
  view (great for AI-generated / README / notes files) — or flip to edit mode and
  save with ⌘S. **No Obsidian or separate Markdown app required.**
- **👀 Real preview for popular file types.** Built on the same Quick Look engine
  Finder uses — images, PDFs, code, video, audio, docs — right inside the column
  preview pane and with the Space bar.
- **🖱️ UI-driven file operations.** Cut, copy, paste, **move**, duplicate,
  rename, make alias, compress, extract — all from buttons and right-click menus,
  with full **undo/redo**. No memorizing Terminal commands.
- **🧑‍💻 One-click IDE & terminal launch.** Open the current folder in **Terminal,
  VS Code, Cursor, Claude Code, or Codex** — buttons appear only for the tools you
  actually have installed.
- **🔎 Search that actually finds things.** This folder, this folder + subfolders,
  or **Spotlight-powered across your whole Mac** — including extension search
  (type `.pdf`) — without leaving the window.
- **🔗 Copy a folder's path in one click.** A dedicated copy-path button with a
  confirmation toast. (Try doing *that* quickly in Finder.)
- **🗜️ Archive tools that just work.** Compress to `.zip`; extract
  `.zip / .tar / .gz / .tgz / .bz2 / .xz` using macOS's built-in tools.

> If you've ever opened Finder, then Sublime, then Obsidian, then Terminal just
> to deal with one folder — aiFlow is that whole stack in a single window.

---

## Everything it does

<details open>
<summary><b>Browsing & navigation</b></summary>

- **Three views** — **Column** (Finder-style miller columns with a live preview
  pane + optional ancestor "tree" mode), **List** (sortable by Name, Date
  Modified, Date Created, Size, Kind, Extension, with optional *Group by Date*),
  and **Icon** (resizable 32–128 pt grid).
- **Sidebar** — system locations, your **pinned** folders, **recent** folders,
  and a **Tags** section.
- **Path bar** — clickable breadcrumbs, double-click to type a path, one-click
  **Copy Path**.
- **Status bar** — item count, selection size, free disk space.
- **Quick Look** (Space) + a built-in preview panel.
</details>

<details>
<summary><b>Google Drive — native, without the Drive app</b></summary>

- **Connect one or more Google accounts** (OAuth 2.0 loopback + PKCE, your own
  client ID, refresh tokens in the login Keychain) — no Google Drive for Desktop
  needed, no embedded secret.
- **Local mirror per account** in `~/Library/Application Support/FinderFlow/`,
  browsed like any other folder: double-click, Quick Look, editor, search, tags
  and archives all work on real files.
- **Two-way sync, conservative by design** — downloads new/changed files,
  uploads new/edited local ones, and **never deletes anything automatically**
  (vanished files are counted as *orphaned* for review).
- **Google Docs/Sheets/Slides export** to `.docx` / `.xlsx` / `.pptx` locally;
  double-click opens the live web original, ⌥-double-click the local copy.
- **Drive badges** in list / table / icon views (synced · Google doc · shortcut ·
  waiting to upload) plus a status line with an *Open in Drive* link in the
  preview panel.
- **Drive for Desktop folders still work** — they appear in the same sidebar
  section, and `.gdoc`/`.gsheet` shortcuts open in the browser instead of
  showing raw JSON.
- Setup and details: [docs/google-drive.md](docs/google-drive.md).
</details>

<details>
<summary><b>Finder-compatible color tags</b></summary>

- Add/remove the 7 standard macOS colors from any view's right-click **Tags**
  menu — toggles exactly like Finder, multiple colors per file preserved.
- Written in macOS's real tag format, so they **also show up in Finder**.
- Tag dots render in list / icon / column / preview; tapping a tag in the sidebar
  filters **Mac-wide** via Spotlight.
</details>

<details>
<summary><b>File operations (with Undo/Redo)</b></summary>

- Copy / Cut / Paste, Duplicate, inline Rename, Make Alias (symlink).
- Move to Trash and **Delete Permanently** (confirmed).
- **Compress** to `.zip`; **Extract** common archive formats.
- Share / AirDrop, Show in Finder, Get Info, Copy Path.
- Multi-select aware; partial-failure-safe paste/move with correct undo.
</details>

<details>
<summary><b>Built-in code editor (bundled & offline)</b></summary>

- Double-click a text/code file to edit it in aiFlow.
- Syntax highlighting for dozens of languages; **multiple files as tabs**.
- **Fuzzy command palette (⌘⇧P)**, settings menu, Sublime keybindings.
- **Sublime-style minimap** (theme-aware, click/drag to scroll).
- Runs in a **real, standalone macOS window** — drag, minimize, resize, fit —
  and never blocks the main browser window.
</details>

<details>
<summary><b>Markdown reader / editor</b></summary>

- Rendered preview (GitHub/Obsidian-style, dark + light) with internal `.md`
  link navigation, plus an **Edit** mode with ⌘S save and auto-save on close.
</details>

<details>
<summary><b>E-Sign — sign PDFs and scans</b></summary>

- **Sign…** everywhere a file action lives: right-click (also with several
  files selected), the selection bar's signature button, the preview panel,
  **File ▸ Sign Document…** (⌥⌘E) and Finder ▸ Services — for PDFs, images and
  Word / RTF / ODT documents. Each document opens in its own signing window.
- **Reusable signatures** — draw with the trackpad or mouse (smooth,
  speed-sensitive ink from a native Swift port of the open-source
  [signature_pad](https://github.com/szimek/signature_pad), MIT), type your
  name in a script face, or import a photo/scan of your handwritten signature
  (the paper is removed automatically).
- **Place anywhere** — drag to move, corner handle to resize, ⌫ or the red ×
  to remove; add **Date**, **Name**, free **Text** and **✓**; right-click ▸
  *Place on Every Page* for initials. Works on rotated pages too.
- **Signed copy, never the original** — saved as `Name (signed).pdf` next to
  it, the signature burned into the page as vector art. Filled-in forms are
  flattened; links, bookmarks, metadata and page rotation are kept. Photos and
  scans become a one-page PDF, Word / RTF / ODT documents are laid out and
  printed to PDF first (check the pages — page breaks and headers aren't carried
  over); password-protected PDFs can be unlocked and signed.
- **Optional tamper-evident seal** — an Ed25519 signature over the finished
  file's SHA-256, made with a key that lives only on this Mac. Right-click ▸
  **Verify Signature** shows who sealed it, when, and whether it changed since.
  A simple integrity check — not a certificate-based (qualified) e-signature.
- **In Finder too** — right-click ▸ Services ▸ **Sign with aiFlow** /
  **Verify E-Signature with aiFlow**.
</details>

<details>
<summary><b>Search</b></summary>

- Scopes: This Folder, This Folder & Subfolders, Desktop, Documents, Downloads,
  Home, and **Entire Mac** (Spotlight).
- Name and **extension** search; live count; runs in the background.
</details>

<details>
<summary><b>System integration</b></summary>

- **Finder Sync extension** — right-click in Finder: New Folder Here, Copy Path,
  Open in Terminal, **Open in aiFlow**.
- **Set aiFlow as your default folder handler** (Settings) — routes folder
  opens to aiFlow via LaunchServices.
- `finderflow://` URL scheme + "Open With" for folders & text files.
- **Launch at Login** toggle, in-app toast notifications.
</details>

---

## Secure internet sharing

Right-click one file → **Share → Create Secure Link…**. aiFlow automatically creates a temporary HTTPS link through Cloudflare while this Mac is awake and online. Includes expiration, optional passwords, preview/download permissions, session download limits, activity and revocation. **Shared Files** is available in the sidebar and File menu. An optional embedded login agent keeps sharing after the app quits.

No account or server setup is needed; the Cloudflare client is bundled. After the tunnel restarts, copy and send the new link. File bytes pass through Cloudflare; this is transport encryption, not E2EE. Quick Tunnels have no uptime guarantee. The included managed server remains an optional alternative. [Setup, deployment, privacy and verification](docs/secure-sharing.md).

## Security & privacy

aiFlow touches your files, so it's built to earn that trust — and it was put
through a **senior-QA and security pass** before release.

- **Local by default. No telemetry, no accounts.** Browsing, editing, search and
  file operations never leave your Mac. Outbound connections happen only for
  opt-in features you trigger: AI Organizer (OpenRouter), Send to Discord, and
  update checks (GitHub Releases), and explicitly enabled Secure Share. Secure Share sends only selected file snapshots through the configured relay. Nothing about your files is sent anywhere
  otherwise.
- **Security-reviewed.** An **AppleScript-injection** path (via crafted
  filenames in *Get Info* / *Open in Terminal*) was found and fixed with strict
  string-literal escaping, and the same hardening was applied to the Finder
  extension. The shell/AppleScript bridges were audited end-to-end.
- **Bug-hardened.** The QA pass also fixed a dead keyboard command, unsaved
  Markdown data-loss on close, and made partial paste/move failures undo-safe —
  so you don't lose work.
- **Sandboxed where it matters.** The Finder extension runs **sandboxed**; the
  main app is not sandboxed because a file manager needs full file-system access
  (the same reason Finder isn't). It only uses the access *you* grant via standard
  macOS prompts.
- **E-Sign stays on your Mac.** Saved signatures and the seal key live in
  `~/Library/Application Support/FinderFlow/Signatures/` (the key file is
  readable only by you); signing and verification never touch the network.
- **Open source.** Read every line. MIT licensed.

## Light on RAM — a file manager, not a memory hog

A file manager should disappear into the background, not sit in Activity Monitor
eating your RAM:

- **≈ 55–60 MB idle** while browsing — measured, not guessed.
- File-type icons are **cached, not duplicated**, so big folders stay lean.
- The code editor and Markdown preview use embedded web tech (WebKit) **only
  while open**, and that memory is **released the moment you close the window**.
- Event-driven — it isn't polling the disk or burning CPU in the background.

---

## Requirements

| **macOS**    | 14.0 Sonoma or later                       |
| ------------ | ------------------------------------------ |
| **Chip**     | Apple Silicon (M1 or newer); Intel needs an Xcode build |
| **Download** | ≈ 27 MB · `.dmg` (bundles the Cloudflare helper for Secure Share) |
| **Extras**   | None — fully self-contained                |
| **Price**    | Free & open source (MIT)                   |

## Install

1. Download the latest **`aiFlow-2.0.0.dmg`** from
   [**Releases**](../../releases/latest) and open it.
2. Drag **aiFlow** into **Applications**.
3. **First launch (one-time Gatekeeper step).** aiFlow is free and isn't
   signed with a paid Apple Developer certificate, so macOS asks once — this is
   expected and safe:
   - Try to open it (it may be blocked), then go to **System Settings → Privacy &
     Security**, scroll to *"aiFlow was blocked"* and click **Open Anyway**.
   - **Or** double-click **Fix Gatekeeper.command** in the DMG (after the app is
     in Applications).
   - **Or** run once in Terminal:
     ```sh
     xattr -dr com.apple.quarantine /Applications/aiFlow.app
     ```
4. *(Optional)* Enable the Finder right-click menu under **System Settings →
   General → Login Items & Extensions → Extensions → aiFlow** (Xcode builds only).

The first time you browse Desktop/Documents/Downloads (or use Get Info / Open in
Terminal), macOS shows its **standard permission prompts** — just click **Allow**.
These are normal for any file manager.

## Build from source

Requires Xcode 16 / Swift 5.9+.

```sh
git clone https://github.com/nnikolaandric-sudo/FinderFlow.git
cd FinderFlow
open FinderFlow.xcodeproj      # build & run (⌘R)
```

Produce a distributable DMG (Universal with Xcode, Apple Silicon with `--prebuilt`):

```sh
./release.sh                    # → build/aiFlow-<version>.dmg (+ .sha256)
./release.sh --prebuilt build/local/aiFlow.app   # no Xcode: package build-local.sh output
```

## Landing page (GitHub Pages)

A full landing page lives in [`docs/`](docs/) and is published with GitHub Pages:

**<https://nnikolaandric-sudo.github.io/FinderFlow/>**

It serves from the `main` branch `/docs` folder (Settings → Pages → Deploy from a
branch → `main` → `/docs`).

> Full capability list & development history: **[CHANGELOG.md](CHANGELOG.md)**.

---

## About the maker

<img src="docs/assets/maker.png" alt="Gobinda Tarafdar" width="120" align="left" hspace="20" />

**Gobinda Tarafdar** — WordPress product marketer by trade, stubborn
problem-solver by habit, lifelong Harry Potter devotee by heart.

By day I'm the Product Marketing Specialist at **WPBakery** — the page builder
that quietly powers a sizeable corner of the WordPress universe. Before that, I
helped a single plugin cross **400,000+ active users** through positioning, user
research, and a relentless focus on what actually moves the needle. When the
day-job owl flies home, I tinker on my own little workshop of spells — FinderFlow
is one of them.

<br clear="left" />

**Also from the workshop:**

- **[WPBakery](https://wpbakery.com/)** — the page builder I do product marketing for.
- **[Docscriber](https://thedocscriber.com/)** — documentation, conjured.
- **[TheRecaller](https://therecaller.com/)** — a memory charm for what you forget online.
- **[TheEditra](https://theeditra.com/)** — a video-editing cauldron of my own brewing.
- **[The Quill Press](https://thequillpress.com/)** — tech news styled after the Daily Prophet.
- **[Costlas](https://costlas.com/)** — cost-of-living for 140 countries & 1,377 cities.

## Support this project

If FinderFlow saves you a few trips to Finder, here's how to help — all optional,
all appreciated:

- ⭐ **[Star it on GitHub](../../stargazers)** — helps others find it.
- ❤️ **[Donate](https://gtarafdar.com/donate)** — keeps the workshop lit.
- 🐦 **[Follow on X / Twitter](https://x.com/Gtarafdarr)**
- 💼 **[Connect on LinkedIn](https://www.linkedin.com/in/gobinda-tarafdar/)**

## Notes on distribution

This app is **ad-hoc signed and not notarized** (no paid Apple Developer
account), which is why the one-time Gatekeeper step is needed. To ship it without
that prompt, sign with a Developer ID certificate and notarize.

## Security & updates

In-app updates are optional and can be turned off in **Settings → Updates**.

**Where updates come from**

- Only from official [**GitHub Releases**](https://github.com/nnikolaandric-sudo/FinderFlow/releases)
  on `nnikolaandric-sudo/FinderFlow` — hardcoded in the app, not user-configurable.
- Downloads use **HTTPS** (GitHub’s TLS).

**Integrity check**

- Every release ships a companion `aiFlow-x.y.dmg.sha256` file (standard
  `shasum` format).
- Before installing, the app **verifies the DMG’s SHA-256 hash** against that file.
- If the checksum is missing or doesn’t match, the update is **blocked**.

**Install helper**

- The DMG’s `Fix Gatekeeper.command` only runs
  `xattr -dr com.apple.quarantine /Applications/aiFlow.app` and opens the app.
  It does not use the network or request admin rights.

**What this means for you**

- Same trust model as downloading the DMG manually from GitHub — you trust the
  maintainer’s releases.
- A public repo does **not** weaken security; the updater uses read-only APIs and
  ships no secrets.
- Auto-update makes a compromised release reach users faster — protect your
  GitHub account with **2FA** and only publish releases you built yourself.

**What we don’t verify (yet)**

- Apple Developer ID signatures or notarization (requires a paid Apple account).
- For maximum assurance, compare the published SHA-256 on the release page with
  a hash you compute locally: `shasum -a 256 aiFlow-x.y.dmg`.

## License

MIT © Gobinda Tarafdar. See [LICENSE](LICENSE).

Third-party: E-Sign's drawing pad is a Swift port of
[signature_pad](https://github.com/szimek/signature_pad) — MIT © 2018 Szymon
Nowak; the full notice is at the end of `FinderFlow/SignaturePad.swift`.

---

*aiFlow is an independent project and is not affiliated with Apple. Finder is
a trademark of Apple Inc.*
