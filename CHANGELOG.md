# FinderFlow — Feature History & Changelog

A complete record of what FinderFlow does and how it was built. Dates are
relative to the 1.0 release.

---

## 2.0.0 — aiFlow (2026-09-24)

First release under the aiFlow name, published from
[nnikolaandric-sudo/FinderFlow](https://github.com/nnikolaandric-sudo/FinderFlow).
Built on FinderFlow 1.5.2 by Gobinda Tarafdar (MIT). Settings, AI keys, the
E-Sign seal key and macOS permissions carry over (bundle ID unchanged).

### Release fixes

- **In-app updates install again.** The installer script carried a `//`
  comment line; bash ran it as a command ("//: is a directory") and `set -e`
  aborted every update right after the app quit. Checked end to end on a test
  image: old version replaced, image detached, wrong hash refused.
- **The updater reads this fork's releases** (`nnikolaandric-sudo/FinderFlow`),
  never upstream FinderFlow, whose builds are a different app.
- **Xcode project was missing 18 source files** (Folder Rules, Workspace,
  Git, native list, Settings panes…) — `release.sh` could not have built.
- **`release.sh` ships aiFlow:** `aiFlow-<version>.dmg` + `.sha256`, aiFlow.app
  inside, rebranded install notes and Gatekeeper helper; `--prebuilt` packages
  a `build-local.sh` build without Xcode (Apple Silicon only, no Finder
  extension), `--no-layout` skips the Finder window styling; the bundle ID and
  signature are checked before packaging.
- Version 2.0.0 (build 9) in the Xcode project and `build-local.sh`; Xcode
  product renamed to aiFlow with `PRODUCT_MODULE_NAME = FinderFlow`.

### Workspace Mode: files know what needs to happen next

- **Enable Workspace on any folder** (preview panel, right-click, or the
  `...` menu). The left side stays a plain file browser; the right panel
  shows the work around the selected folder or file — never a separate
  project-management screen.
- **Workspace overview** (Overview | Tasks | Activity): custom statuses
  (add your own, e.g. "Waiting on client"), remembered owner, deadline,
  quick actions (+ Task, + Reminder, Request File, Share), Needs Attention
  (overdue, expiring, pending reviews, missing requests), Next up, pending
  file requests (auto-marked received when the file lands on disk), active
  share links, recently changed documents, activity log.
- **Tasks** — workspace-level or attached to one file (visible in both
  places), due dates, assignees, priorities, To Do / In Progress / Waiting /
  Done, unified Tasks view with All / Mine / Due Soon / Waiting / Completed
  filters grouped Today / Upcoming. Right-click any file → Add Task… /
  Add Reminder… opens a composer with the file already linked (the parent
  folder becomes a workspace first if needed).
- **Reminders** — exact date + time with a macOS notification even when the
  app sits in the background, workspace-level or pinned to a document
  (bell badge on the file, Reminders card + Needs Attention + Next in the
  overview, own section in the file Tasks tab).
- **Per-file work tabs** (Details | Tasks | Review | Share | Relations):
  Draft → Review → Approved → Signed → Archived lifecycle (Request Review
  also creates a task for the reviewer), expiry/renewal dates with macOS
  notifications, safe replace-with-new-version (old copy kept as
  `Name (previous).ext`), read integration with Secure Share links
  (create / copy / disable / extend / manage), connected documents (click
  jumps the left browser to the file), plain-text notes.
- **Badges in every file list** — `●2` open tasks, `✓` reviewed, `⚠7d`
  expiring, `🔗` shared (list, icons, columns, search results and the flat
  native table) — plus macOS reminders for due tasks, expiries, reviews,
  expected files and deadlines. All data stays local in
  `Application Support/FinderFlow/Workspaces` (`FF_WORKSPACE_DIR` keeps
  tests out); files themselves are never touched.
- Tests/harness: `FF_WORKSPACE_DIR` isolates the store,
  `FF_WORKSPACE_DISABLE_NOTIF=1` keeps notification prompts out of tests.

### Default file manager works on macOS 26

- **The "Open folders in aiFlow" toggle never took effect on macOS 26:**
  every public API that sets the folder handler answers paramErr (-50) —
  `NSWorkspace.setDefaultApplication(at:toOpen: .folder)` and
  `LSSetDefaultRoleHandlerForContentType`, even when asked to set Finder.
  It now also writes the per-user LaunchServices entry for `public.folder`
  plus `NSFileViewer` (the ForkLift / Path Finder route). "Show in Finder"
  from other apps lands in aiFlow at once; folders opened by other apps
  switch after the next login. Settings shows which of the two applies;
  turning it off removes both.
- **"Show in Finder" from other apps selects the file in aiFlow.** macOS
  delivers it as a plain "open this file" (verified with a probe viewer —
  no reveal flag), so when aiFlow is the file viewer an incoming file is
  shown selected in its folder instead of opening in the editor.
- **aiFlow's own "Show in Finder" buttons open Finder** again (they went
  through NSFileViewer, i.e. back into aiFlow): Finder is asked directly
  (Automation prompt once), else the enclosing folder opens in Finder.
- Dev builds with the same bundle ID are unregistered from LaunchServices
  (`build-local.sh --no-run`, and when enabling from /Applications) so a
  stale copy can't take folders over.

### Rebrand: aiFlow

- **The app is called aiFlow** — menu bar, Dock, Finder, Spotlight, Activity
  Monitor, window titles, Settings, dialogs, Finder Services ("Sign with
  aiFlow"), the site and README. Wordmark: "ai" in the icon gradient + "Flow".
- **New icon** (`tools/brand/make_icon.swift`): indigo → violet → cyan
  squircle, three white flow ribbons and an AI spark; 16 px gets a simpler
  two-ribbon drawing so it stays legible.
- Unchanged on purpose: bundle ID `com.finderflow.app`, the Swift module,
  Application Support folders, Keychain items, GitHub repo and release file
  names — settings, AI keys, E-Sign seal key and macOS permissions carry over.
  Seals made before still verify (the app name isn't part of the signed data).
- Local builds: `build/local/aiFlow.app`, executable `aiFlow`
  (`-module-name FinderFlow` pinned so archived class names don't move).

### Calmer window: search in the title bar, simpler toolbar

- **Search sits top right in the title bar** (Finder layout), one field:
  the scope is a small menu inside it (magnifier + chevron, accent-colored
  when it isn't "this folder"), the placeholder says where it looks
  ("Search Downloads"), the match count and clear button sit at its end.
  It used to be a "Scope" picker plus field squeezed to "Fu…" in the path
  row. The window title is the current folder's name; the path bar gets
  its whole row.
- **Toolbar: 30 buttons → about 15.** With a selection: count · Quick Look ·
  Get Info · Extract (only for an archive) · Share · ⋯. Open, Open With,
  Cut, Copy, Duplicate, Rename, Compress, links, Mail and Discord are in ⋯,
  the Share menu, the right-click menu and their shortcuts. Go to Folder,
  Redo and Copy Path moved into the ⋯ More menu.
- **Column filter bar is opt-in** (⌥⌘F or Display ▸ Column Filter Bar) — a
  second search field right under the real one; it stays visible while a
  filter is active.
- **List columns:** Name takes the free width and never drops below 200 pt
  (narrow lists scroll the right-hand columns instead); Extension is hidden
  by default (Kind already says "PDF File"); right-click the header to show
  or hide columns.
- **Preview panel never takes more than half the window** — a width dragged
  on a big screen squeezed the list to a third on a smaller one.

### Native file list: folder switches ~2× faster

- **The plain list view is a real NSTableView now** (`NativeFileTable.swift`).
  SwiftUI's `Table` diffed and visited every row and measured row heights
  through a hosting view per cell on each folder change. Measured with the
  real ContentView and the user's settings (list, no grouping, Date Created,
  preview on), longest main-thread block per switch: Downloads (7.9k)
  ~250 → ~125 ms, Desktop (80) ~255 → ~150 ms (tearing down the old 8k rows
  was the cost), Documents (2.8k) ~160 → ~115 ms. What remains is SwiftUI
  updating and laying out the rest of the window.
- Same behaviour: sortable headers, multi-select, double-click open, Return
  renames (name selected without the extension, Esc cancels), Space = Quick
  Look, the full context menu, drag-out, drop onto folders (spring-open) or
  the list, cut fade, tag dots, Drive badges; column widths are remembered.

### Mail Inbox AI + mail sources, Folder Rules read documents

- **Mail Inbox ▸ Improve with AI / Organize.** The AI upgrade, batch
  enrichment and reorganization that were written but unwired now have
  buttons: *Improve with AI* on one mail, *Organize ▸ Improve All with AI*
  (batches of 40 attachments) and *Reorganize* / *Reorganize All* (Finance /
  Invoices / Inbound–Outbound, Contracts, Legal, HR - Candidates, Offers…
  with names built from the facts). AI asks first and says what leaves the
  Mac (attachment names + text, never mail bodies or addresses); it needs
  the OpenRouter key from AI Organizer. *Undo Reorganize* moves every file
  back and sends files it wrote to the Trash.
- **Mail sources.** *Import ▸ Selected Messages in Mail* saves what is
  selected in Mail.app (up to 200) into Email/Inbox and syncs — works with
  every account Mail has. Settings ▸ Mail Inbox can **install the Mail rule
  script** (FinderFlowSave, Email folder baked in, UTF-8 source) and
  **sync automatically** while FinderFlow runs (watches Email/Inbox; off by
  default, turned on by installing the script).
- **Folder Rules read documents.** New condition *From (issuer)*:
  „PDF račune od Telekoma stavi u Documents/Računi po godinama" matches the
  company inside the document (case, diacritics and case endings ignored).
  Destinations take `{year}` / `{month}` — from the date printed in the
  document, else the arrival date; „po godinama" / „po mjesecima" / „by
  year" add them. Scanned PDFs (first 2 pages) and photos of receipts are
  read with on-device Vision OCR, and a document titled „RAČUN br. …"
  counts as an invoice even when the file is called scan001.pdf.
- Fixes: *Improve with AI* always ends (the old path never called back
  when there was nothing to send or the request failed); AI batch passes
  update the inbox on the main thread; the suggestion pane no longer shows
  the category twice („Finance / Finance / Acme").
- Tests/harness: `FF_MAIL_DIR` keeps the Mail store out of Application
  Support.

### Keyboard shortcuts reference

- **Help ▸ Keyboard Shortcuts (⇧⌘/).** Every shortcut in one window —
  files & editing, navigation, preview, tabs, view modes, dialogs, the code
  editor, Markdown/E-Sign and this reference itself — grouped with keycaps.
  (⌘H stays the system Hide, so the reference uses the platform-standard ⌘?.)
- **Settings ▸ Shortcuts**: the same reference, grouped and collapsible, plus
  a button that opens the window. One shared model feeds both, so they can't
  drift apart.

### Secure internet sharing

- Automatic account-free Cloudflare Quick Tunnels are now the default: bundled,
  checksum-verified cloudflared, native loopback recipient API, local access
  control and one-click Create Link with no server configuration.
- Temporary hostnames refresh after a tunnel restart; the helper supervises
  tunnel lifetime and stops it on opt-out or when no active shares remain.
- Synthetic public HTTPS transfer verified (public DNS fallback required on
  this Mac); Quick Tunnels do not provide an uptime SLA.

- Added Create Secure Link in file/selection Share menus, Shared Files in the
  sidebar/File menu, expiry, optional passwords, permissions, download-session
  limits, activity, renewal and revoke.
- Local read-only snapshots and SQLite registry; Keychain-backed device keys
  and link secrets; an embedded opt-in SMAppService agent and app fallback.
- Added a single-server Node/PostgreSQL relay, recipient page and Docker/Caddy
  deployment. Outbound WSS, 256 KiB credit-controlled streams, HEAD/Range,
  reconnection and cancellation; no cloud file storage.
- Added isolated integration coverage with the actual Swift agent. Managed public
  hosting, signed helper approval and independent-network verification remain
  deployment steps. See [secure-sharing.md](docs/secure-sharing.md).

### Mail Inbox (file email attachments like Hazel files folders)

- **File ▸ Mail Inbox… (⌥⌘M).** The Mail DMS pipeline that already lived in
  the codebase is now reachable: a reusable inbox window with Sync, Import
  .eml, plain-language automation rules and Accept/Change review. Drop `.eml`
  files (or a Mail.app rule) into the Email folder's Inbox and Sync — the
  local pipeline classifies by company, project and document type (invoice,
  proforma, receipt, statement, contract, offer, CV, NDA), files attachments
  under the Email root and keeps the `.eml` as evidence. Suggestions at ≥98%
  confidence file themselves on ingest; everything else waits for review, and
  nothing is ever deleted.
- **Settings ▸ Mail Inbox**: the Email folder path (Change / Reveal / reset to
  the default `Documents/FinderFlow/Email`), automation rule count, and filed
  mail counts — plus a button that opens the inbox. The `ffMailRoot` and
  `ffMailRules` keys now live in `UserPreferences` instead of raw strings.
- Local-only by default: the offline heuristic path runs with no API key
  (Mail.app / Gmail / IMAP connectors remain a later step — ingestion today is
  the local `Email/Inbox` dropzone). AI upgrade, batch enrichment and folder
  reorganization services exist but stay unwired until a follow-up adds their
  buttons to the detail pane.

### Sidebar switching responds at once

- **The sidebar highlight moves when you click.** Clicking Downloads,
  Desktop or Documents changed the highlight and the folder in one update, so
  the highlight only moved once the new list was built — 229–383 ms after the
  click, which read as a missed click. The highlight now draws first and the
  folder loads on the next run-loop turn: 21–43 ms.
- **No fade on every folder change.** The 120 ms opacity dip over the file
  list cost two extra view updates plus animation frames while the list was
  being swapped — about 115 ms of main-thread time per switch, and a visible
  flicker. It's gone.
- **Big folders sort off the main thread.** A cached snapshot over 1,000
  items is now re-sorted in the background for every sort field (date sorts
  included — FileItem is a large struct, 10–25 ms for 8k items), and the
  "did the folder change on disk?" comparison runs there too.
- Measured with the real ContentView, the user's view settings and the real
  folders (Downloads 7,894 / Documents 2,797 / Desktop 72 items), Release,
  two runs of four rounds each — longest main-thread block per switch:
  Downloads 369–379 → 238–239 ms, Documents 267–291 → 162–165 ms, Desktop
  285–286 → 260–267 ms; main-thread CPU per switch down 25–30%. What remains
  is SwiftUI's Table swapping thousands of rows (diff, row views, row heights)
  — checked and not worth hacking around: a fresh Table per folder was ~100 ms
  slower, fixed row heights saved 0–35 ms.

### Folder Rules (auto-sorting, like Hazel)

- **Right-click a folder ▸ Auto-Sort This Folder** (or right-click the empty
  area inside it) and write rules the way you'd say them: "screenshotove
  premjesti u Screenshots", "PDF račune stavi u Documents/Računi",
  "instalacije starije od 14 dana baci u smeće", "Move images to
  ~/Pictures/Inbox". Rules are read offline in Bosnian/Croatian/Serbian or
  English; there is also a step-by-step editor and four one-click starters.
  Conditions: kind (images, PDFs, documents, archives, audio, video,
  installers, screenshots — found via Spotlight in any language), extension,
  name contains, text inside contains (PDF text layer / text files, read
  locally), document type (invoice, proforma, receipt, statement, contract,
  offer, CV, NDA — the same local classifier as mail filing), older than,
  larger than. Actions: move to a folder, move to Trash, add a tag.
- **Safe by default.** Only files that arrive after a folder is marked are
  sorted automatically; what was already there waits for Preview ▸ Sort N
  Files. Nothing is ever deleted permanently (Trash only), every move is in
  the folder's activity list with Undo, files still being downloaded wait
  until they stop changing, only the folder's first level is touched, a file
  FinderFlow just moved is left alone for 10 minutes (two watched folders
  can't bounce it back and forth), and system folders can't be marked. First
  matching rule wins; rules can be reordered and switched off one by one.
- **Settings ▸ Folder Rules**: one switch pauses all auto-sorting; the AI
  switch is **off by default** — then nothing is sent anywhere and no AI
  credits are used (rules that need AI are skipped and marked "AI off"). With
  AI on, it reads free-form rules the offline reader can't (the result opens
  in the editor for review, never applied blindly) and answers "AI thinks it
  is …" conditions from the file name — plus up to 1,500 characters of local
  text only if you allow it. A daily limit (default 30) caps it, the AI
  Organizer's monthly spend cap applies too, and each file's verdict is
  remembered so the same file is never paid for twice. The status bar shows
  "Auto-sort · N today" in a watched folder.

### Browser tabs + floating selection bar

- **Browser tabs (Tab menu, ⌘T / ⇧⌘W / ^Tab).** One window, multiple folders:
  a tab bar above the path row, each tab with its own path, persisted across
  relaunches (`ffOpenTabs`). Right-click a folder → *Open in New Tab*,
  tab context menu → Duplicate / Close Others / Copy Path / Reveal in Finder.
  Search is cleared on tab switch so results never leak into the new folder.
  Known v1 limit: Back/Forward history is still global (per-tab history next).
- **Selection actions float, they no longer push the list.** The selection bar
  was a sticky full-bleed header under the toolbar — every select/deselect
  shifted the whole file list. It is now a floating pill overlaid at the
  bottom (same actions, compact overflow on narrow windows), so the layout
  never jumps. The non-floating style is kept via `floating: false`.

### Snappier clicking and folder loading

- **A click no longer rebuilds the whole folder.** The grouped list kept its
  rows inside the view that owns the selection binding, and SwiftUI invalidates
  every view that *holds* a binding the moment its value changes — even when
  the body never reads it. So each click ran the row builder over the entire
  listing. The rows now live in their own view, fed only by values SwiftUI can
  compare; the state a click writes (Shift anchor, double-click dedupe, row
  callbacks) moved into stable references, and the row reads
  `backgroundProminence` instead of an `isSelected` input, so the List keeps
  drawing the highlight on its own. Measured end to end on ~/Downloads (8,105
  items, grouped by date, preview panel on, Release build):
  - one click: 147-349 ms → 61-99 ms of blocked main thread (8,105 row builds → 0)
  - 20 quick clicks: 4.1-4.5 s → 1.3-2.0 s of main-thread CPU
  - holding ↓ across 30 rows: 5.5-5.7 s → 1.7-1.8 s, worst hitch 277-692 ms → 59-91 ms
  - scrolling: worst hitch 90 ms → 44 ms
- **Column view: a click no longer rebuilds the column.** Same cause as the
  list: the pane owned both the rows and the highlight, so every click rebuilt
  every row of the folder behind it. The rows moved into their own view with no
  closure that captures the pane (callbacks live in a reference), and the
  highlight became a tiny observed object the row reads itself — the accent
  styling is unchanged, but only the rows actually drawn repaint. Measured in
  an 8,105-item folder: one click 723-1,598 ms → 75-182 ms of blocked main
  thread, 834-1,742 ms → 127-535 ms of main-thread CPU.
- **Checked and left alone:** the ungrouped table (SwiftUI `Table`) rebuilds
  only its visible cells (29 per click), and the icon grid only 1-2 cells, so
  neither had the rebuild problem. Freezing the whole toolbar / status bar /
  selection bar saves at most 12% of a click, and an adaptive preview delay
  measured no difference at all — neither is worth its complexity.
- **Back into a big folder paints from the cache first.** Folders over 2,000
  items waited for a complete fresh disk listing before showing anything, even
  with a cached snapshot in hand. The snapshot is now sorted off the main
  thread and shown immediately, while the disk check runs behind it and
  publishes a second time only if the folder really changed: Back into an
   8k-item folder 486-701 ms → 358-537 ms, leaving it for a small folder
   506-554 ms → 190-468 ms.
- **Thumbnails no longer flood QuickLook.** Every visible image/PDF/movie row
  fired its own QL generation with no limit, so scrolling a media-heavy folder
  queued hundreds of concurrent generations that competed with the folder load.
  At most 4 now run at once (same width as the icon queue); rows cancel their
  fetch when reused or scrolled away, so stale generations never jump ahead of
  visible rows — and a fast scroll can't paint a wrong thumbnail for a frame.
- **Row strings are rendered once, not per click.** Date and file-size text ran
  `DateFormatter`/`ByteCountFormatter` on every row on every render; they are
  now computed once when the item loads (off the main thread) and read from
  then on. Same pixels, no per-click formatter time.

---

### Interface cleanup

- **The preview panel showed an empty bubble.** Its "nothing selected" icon was
  `doc.magnifyingglass`, which isn't an SF Symbol, so macOS drew nothing inside
  the circle. An audit of every symbol name in the app found one more dead
  icon (`harddrive.fill`, in the Google Drive storage row); both are fixed, and
  the three hand-rolled "no preview" blocks (preview panel, column hint, column
  preview) are now one component with one icon, one wording and a keyboard
  hint (`Space` — Quick Look).
- **The list no longer paints empty rows.** Below the last file the table kept
  drawing its alternating stripes, so a half-full folder ended in a ladder of
  blank bars. Stripes are off, which also makes the table match the grouped
  list, which never had them.
- **The table's filter bar reads like the search field.** It was a bare text
  field with no border — invisible on the toolbar background — and it never
  said how much it had hidden. It now has a framed field that tints when a
  filter is active, a clear button (and Esc), and an "n of m" badge. The
  filtered list is also computed once per render instead of twice.
- **Search results say where a hit lives.** Rows showed either nothing (list
  view) or the full absolute path of the parent folder — the same 100-character
  string on every row (column view). Results now carry the location relative to
  the folder being searched ("Mix/Screenshots", or `~/…` outside it), and only
  when the hit isn't in that folder itself.
- **Icon names break less.** Icon labels lost their extra inner padding and
  gained middle truncation, so short names like `interview.mp3` fit on one line
  instead of dropping the extension onto a second.
- **The preview panel's divider resizes again — and remembers.** The line left
  of the preview showed a resize cursor but didn't move: the drag gesture hung
  on a transparent 8 pt strip that didn't reliably take the click, and when it
  did, it measured the pointer in the handle's own coordinates, which travel
  with the panel, so the panel lagged and jittered. The handle is now an AppKit
  view that measures in window coordinates. The width is saved when you let go
  and restored at launch; it can grow as far as the window allows (the file
  list always keeps 320 pt), shrinks temporarily with a narrow window without
  forgetting your choice, and a double-click restores the default. The same
  handle drives the column view: its preview column also remembers its width,
  and a double-click on a column divider resets that column. The width is
  held by the preview itself while you drag, so the rest of the window is not
  rebuilt on every mouse move.
- **Previews sit in a card.** QuickLook content (images, PDFs, text) is inset
  and rounded like the info card under it, instead of running into the panel
  edges and the divider.
- **The Size row says more.** Next to the file size the preview card now shows
  image dimensions, PDF page count, or audio/video duration
  ("13 KB · 1600 × 1000", "209 KB · 3 pages", "266 KB · 0:06") — read from the
  file header off the main thread, and never for online-only files.

---

### E-Sign (sign PDFs and scans)

- **Sign…** in the right-click menu for PDFs and images, **File ▸ Sign
  Document…** (⌥⌘E) and Finder ▸ Services ▸ **Sign with FinderFlow** open a
  signing window: PDF on the right, saved signatures and quick fields (Date,
  Name, Text, ✓) on the left. Placements are dragged, resized from the corner
  handle, nudged with the arrow keys, removed with ⌫ / the red ×, and can be
  repeated on every page (initials). Rotated pages keep the art upright.
- **Signatures** are drawn on a native port of the open-source
  **signature_pad** 5.1.4 (Szymon Nowak, MIT — velocity-based stroke width,
  Bézier smoothing; `FinderFlow/SignaturePad.swift`), typed in one of the
  script faces bundled with macOS, or imported from a photo/scan with the paper
  keyed out. They're stored locally in
  `~/Library/Application Support/FinderFlow/Signatures/`.
- **Save Signed Copy** writes `Name (signed).pdf` next to the original (never
  modified): every page is redrawn with its annotations (filled forms become
  page content) and the signatures burned in as vectors; links, bookmarks,
  metadata, CropBox and /Rotate are carried over. JPEGs are embedded without
  recompression; images become a one-page PDF; locked PDFs ask for the password.
- **Tamper-evident seal** (on by default): Ed25519 over the SHA-256 of the
  finished file, appended as a PDF comment with the signer's name and time.
  **Verify Signature** (right-click, or the Finder service) reports *signed and
  unchanged*, *changed after signing* or *seal can't be trusted*. The key is a
  0600 file on this Mac (no Keychain prompts on ad-hoc rebuilds). It's an
  integrity check, not a qualified / certificate-based signature.
- **Sign is offered everywhere a file action is** — also for multi-selections
  ("Sign 3 Documents…", "Verify 3 Signatures" with one summary), in the
  selection bar (signature button) and in the preview panel (Sign… plus the
  seal status of a sealed PDF). Icons view now targets the right-clicked icon
  instead of an older selection (Finder behaviour), which also hid Sign….
- **Word / RTF / ODT** (`.docx .doc .rtf .rtfd .odt`) can be signed: laid out
  with the document's own paper size and margins (tables and styles kept),
  printed to PDF and shown with a "check the layout" note before signing.

---

### PDFInspector (local PDF reading for AI agents)

- **PDFInspector** — local PDF classification + text extraction + Markdown
  (`FinderFlow/PDFInspector.swift`), inspired by `firecrawl/pdf-inspector`
  (MIT), ported to Swift/PDFKit so the app stays self-contained (no
  Rust/Python/Node runtime). Detects text-based / scanned / image-based /
  mixed PDFs by sampling, reports `pages_needing_ocr` with confidence, and
  converts to clean Markdown (lists, headings, dehyphenation, dot-leader
  cleanup) with selective on-device Vision OCR only for pages without a text
  layer — nothing is uploaded.
- **Jev + AI Organizer read more** — `AIContentReader` now uses PDFInspector,
  so excerpts cover the first pages (not just 2) with the PDF type in details.
- **CLI for every agent** — `./tools/pdf-inspect/run.sh dokument.pdf --json`
  (`--excerpt N`, `--detect`, `--select-pages`, `--no-ocr`, `--pretty`) gives
  Claude Code, Codex, Cursor and future agents the same reader; see
  `docs/pdf-inspector.md` and root `AGENTS.md`.

---

### Native Google Drive

- **Google Drive without the Drive app** — connect one or more Google accounts
  (OAuth 2.0 loopback + PKCE with your own client ID; refresh tokens live in the
  login Keychain). Each account gets a local mirror under
  `~/Library/Application Support/FinderFlow/GoogleDrive/<account>/My Drive`,
  which FinderFlow browses as ordinary files — editor, Quick Look, search, tags
  and archives all work.
- **Conservative two-way sync** — downloads new/changed files, uploads new and
  locally edited ones, creates missing Drive folders on the fly, and never
  deletes anything by itself; files that vanished from Drive are counted as
  *orphaned* for review in Settings. Auto-sync every 10 minutes (optional).
- **Google Docs** export to `.docx` / `.xlsx` / `.pptx` (`.pdf` for Drawings).
  Double-click opens the live document in the browser, ⌥-double-click the local
  export. `.gdoc`/`.gsheet` shortcuts from Drive for Desktop open in the browser
  too, instead of showing raw JSON.
- **Drive badges** in list, table and icon views — synced · Google doc export ·
  shortcut · waiting to upload — plus a Drive status row with an *Open in Drive*
  link in the preview panel. The badge index is built off the main thread and
  cached per folder, so mirror browsing stays as fast as any other folder.
- **Sidebar section** for Google Drive: connected accounts with live sync
  status, Sync Now / Open in Browser / Show Mirror, and any Drive for Desktop
  folders found on the Mac.
- **Hidden metadata sidecars** — per-file Drive metadata is stored as
  `.<name>.gdrive.json`, so synced folders no longer show a visible twin file
  next to every document (older visible sidecars are read and migrated).
- **Sync runs off the main actor** — reconcile, hashing and directory walks no
  longer execute on the UI thread; progress is reported back through a callback.
- **Offline test harness** — `./tools/gdrive-test/run.sh` mocks the Drive API
  over `URLProtocol` and verifies download/export, idempotency, upload, badge
  classification, sidecar naming and orphan counting without touching a real
  account (30 checks).

---

### Fallback OpenRouter keys

- **Fallback API keys** — Settings → AI Organizer now holds Key 1 (primary)
  plus any number of fallback keys. When a key is rate-limited (429), out of
  credits (402) or rejected (401), the next saved key takes over
  automatically, in order; the organizer shows "Key 1 … — trying Key 2 of 3…".
- **Keychain migration** — existing installs keep their saved key as Key 1,
  no re-pasting needed. Keys display masked (••••abcd), duplicates are
  ignored, and error messages say when every saved key failed.

---

## 1.5.2 — Faster folder & file open

- **Snappier navigation** — clear the stale listing immediately on folder
  change so double-click doesn't look frozen while the directory loads.
- **Faster directory loads** — browse metadata skips expensive Kind/tag
  lookups on every entry; Kind falls back to a cheap extension label.
- **Faster open path** — List/Icons/Columns use the already-loaded
  `FileItem` (no extra package stat); known text extensions skip the 8KB sniff.
- **Faster date groups** — single-pass bucketing instead of six full filters.
- **Faster Markdown read** — preview reuses the in-memory buffer (one disk read).

---

## 1.5.1 — Install migration fix for newest-first defaults

- **Broader one-time prefs migration** when upgrading from 1.2–1.5: Name A→Z
  (and missing / None / date-modified grouping) becomes **Date Modified,
  newest first, with date groups** — so Applications upgrades no longer keep
  the old flat Name list.
- Settings **Reset to Finder defaults** uses the same factory helper.

---

## 1.5 — Reliability, Markdown toolkit, clearer install

- **Markdown double-click fixed** — file identity is path-stable, so create →
  edit → double-click opens the reader again (no right-click required). Columns
  view opens `.md` / text the same way as List and Icons.
- **Error sheet** — long errors scroll in a compact dialog with **Copy** and
  **Contact Support** (opens GitHub Issues; diagnostics stay on your clipboard).
- **Newest-first defaults** — list + date-modified groups sorted newest first
  (folders on top). One-time migration for installs still on the old name A→Z
  factory combo; customized prefs are untouched.
- **Markdown writing toolkit** — Edit mode format bar with real Undo/Redo
  (AppKit undo stack), bold/italic/strike/code/headings/lists/quote/fences/link/HR.
  Split live preview while editing. Paste-friendly plain-text source editing.
- **Safer preview** — JavaScript disabled in the Markdown WebView; `javascript:` /
  unsafe link schemes blocked.
- **Install clarity** — styled drag-to-Applications DMG, **Install & First Open**
  instructions, **Fix Gatekeeper.command** helper, and a one-time first-run sheet
  explaining the safe Open Anyway step for unsigned builds.

---

## 1.4 — Finder-like defaults + in-app updates

- **Finder-like defaults on first launch** — list view, name sort, **date-modified
  groups** (Today, Yesterday, 7/30/90 days, Earlier), and folders on top. All
  browse preferences are **remembered** across launches; change anything via the
  toolbar and it sticks.
- **Reset to Finder defaults** in Settings restores those factory browse settings.
- **In-app updates** — FinderFlow checks GitHub Releases (about twice a day) and
  shows a banner when a newer version is available. **Update Now** downloads the
  DMG, **verifies SHA-256** against the published checksum, replaces the running
  app, and relaunches — no hunting the repo. **Check for Updates** is also in
  the FinderFlow menu and Settings.

---

## 1.3 — Launch apps + faster folder browsing

- **Double-click `.app` bundles now launch the app** instead of opening the
  package folder (Finder behaviour). Other opaque packages (.pages, .key, …)
  open with their default app too. **Show Package Contents** still works from
  the right-click menu when you need to browse inside.
- **Faster folder navigation** — directory listings use prefetched metadata,
  stale reloads are cancelled when you click through folders quickly, and the
  icon cache is larger so scrolling back feels snappier.

---

## 1.2 — Drag files out + Finder-style grouping

- **Drag files out of FinderFlow** — grab any file or folder from List, Icons, or
  Column view and drop it on the Desktop, another Finder window, an upload dialog,
  a browser, Slack, Mail, etc. Multi-select drags the whole selection (Finder
  behaviour). Cut / Copy / Paste still work as before.
- **Finder-style date groups** — Group by Date Modified / Date Created now uses
  Today, Yesterday, Previous 7 Days, Previous 30 Days, **Previous 90 Days**, and
  Earlier — matching modern Finder.
- **Richer Group By menu** — None, Date Modified, Date Created, Kind, Extension,
  Size, or Name (A–Z). Works in **List, Icons, and Columns**.
- **Folders first / Files first / Mixed** — independent of the sort field, so you
  can keep Name sort while floating folders above (or below) files, or mix them.
- Sort-by picker and ascending/descending are unchanged; grouping sits on top.

---

## 1.1 — Markdown reader in its own window

- **Draggable & resizable Markdown reader** — the Markdown reader/editor now
  opens in a real macOS window (drag by the titlebar, resize, zoom, minimise)
  instead of a fixed modal sheet, matching the built-in code editor. The window
  is reused for subsequent Markdown files and remembers its size/position.
- **"Open in editor" now uses FinderFlow's own editor** — the reader's toolbar
  link button previously launched an external app (Obsidian / TextEdit / etc.);
  it now opens the file in FinderFlow's built-in code editor. Unsaved Markdown
  edits are auto-saved first so the editor shows the latest content.
- **Consistent Markdown handling** — opening a `.md` file *with* FinderFlow
  (from Finder or the command line) now shows the rendered reader, matching what
  double-clicking a `.md` inside the app already did.

---

## 1.0 — First public release

The first shippable build: a fast, native macOS file manager and Finder
alternative, distributed free as a Universal app (Apple Silicon + Intel).

### Core file browsing
- **Three view modes**
  - **List view** — sortable columns (Name, Date Modified, Date Created, Size,
    Kind, Extension), inline rename, optional **Group by Date** sections
    (Today / Yesterday / Previous 7 Days / Previous 30 Days / Earlier).
  - **Icon view** — resizable icon grid (32–128 pt slider).
  - **Column view** — macOS-style miller columns with an inline preview pane,
    optional full ancestor "tree" mode, and resizable column dividers.
- **Sidebar** — system locations (Home, Desktop, Documents, Downloads),
  user-pinned folders, recent folders, and a Tags section.
- **Path bar** — clickable breadcrumbs, double-click to edit the path directly,
  and a one-click **Copy Path** button.
- **Status bar** — item count, selection size, and free disk space.
- **Native Quick Look** (Space bar) and a built-in **preview panel**
  (QLPreviewView, the same engine Finder uses).

### Search
- **Scopes**: This Folder, This Folder & Subfolders (recursive), Desktop,
  Documents, Downloads, Home, and **Entire Mac** (Spotlight-powered).
- Name search and **extension search** (e.g. type `.pdf`).
- Live result count, background execution (never blocks the UI).

### Finder-compatible color tags
- Add/remove the 7 standard macOS colors (Red, Orange, Yellow, Green, Blue,
  Purple, Gray) from any view's right-click **Tags** menu — toggles exactly like
  Finder, multiple colors per file preserved.
- Tags written in macOS's real format so they appear in Finder too.
- Tag dots render in list/icon/column/preview, and tapping a tag in the sidebar
  filters **Mac-wide** via Spotlight (unioned with local color-label matches).

### File operations (with Undo/Redo)
- Copy / Cut / Paste, Duplicate, inline Rename, Make Alias (symlink).
- Move to Trash and **Delete Permanently** (with confirmation).
- **Compress** to `.zip`; **Extract** `.zip / .tar / .gz / .tgz / .bz2 / .xz`
  (uses The Unarchiver if installed, else macOS's built-in tools).
- Share / AirDrop, Show in Finder, Get Info, Copy Path.
- Multi-select aware; partial-failure-safe paste/move with correct undo.

### Built-in code editor (Ace, bundled & offline)
- Double-click a text/code file to open it in FinderFlow's editor.
- Syntax highlighting for dozens of languages; **multiple files as tabs**.
- **Fuzzy command palette** (⌘⇧P), Ace settings menu, Sublime keybindings.
- **Open** (⌘O) / **Close tab** (⌘W).
- **Sublime-style minimap** (theme-aware, click/drag to scroll).
- Runs in a **real, standalone macOS window** — drag, minimize, resize,
  fit — and does **not** block the main browser window.
- Setting to open unknown file types in the editor when they look like text.

### Markdown reader / editor
- Rendered preview (GitHub/Obsidian-style, dark + light) with internal `.md`
  link navigation, plus an **Edit** mode with ⌘S save and auto-save on close.

### Developer integrations (shown only if installed)
- One-click **Open in Terminal**, **VS Code**, **Cursor**, **Claude Code**,
  **Codex** for the current/selected folder. Detection is cached for speed.

### System integration
- **Finder Sync extension** — right-click menu in Finder: New Folder Here,
  Copy Path, Open in Terminal, **Open in FinderFlow**.
- **Set FinderFlow as the default folder handler** (Settings) — routes the
  `open` command, "Open With", and other apps' folder-opens to FinderFlow.
  (Finder itself can't be fully replaced by macOS design — clearly explained
  in-app.)
- `finderflow://` URL scheme and "Open With" handling for folders & text files.
- **Launch at Login** toggle.
- In-app toast notifications for actions (copied, moved, tagged, etc.).

---

## Development history (how 1.0 came together)

1. **Foundation** — list/icon/column views, sidebar, search, file operations,
   path/status bars, Quick Look, Markdown reader, Finder Sync extension, and the
   developer-tool toolbar.
2. **Cursor polish** — fixed the resize/I-beam cursor "sticking" after using the
   sidebar divider, search field, table column dividers, and column handles
   (geometry-based `NSTrackingArea` enter/exit resets + a rewritten resize
   handle).
3. **Tags overhaul** — rewrote tagging to use macOS's real color-tag encoding so
   tags show correctly across all views and are searchable via Spotlight;
   fixed the crash and the "empty results" bug.
4. **Copy-path toast** — wired the path-bar copy button into the toast system.
5. **Default folder handler** — added the Settings option to route folder opens
   to FinderFlow (via LaunchServices), with honest in-app caveats.
6. **Code editor, Phase 1** — extended the text viewer into a full Ace editor;
   double-click to edit.
7. **Code editor, Phase 2** — tabs, command palette (⌘⇧P), settings menu,
   Open/Close shortcuts, unknown-file-type sniffing toggle.
8. **Code editor, Phase 3** — moved the editor into a real, draggable,
   resizable, non-blocking macOS window.
9. **Minimap** — added a theme-aware, Sublime-style minimap.
10. **Senior-QA & security pass** — fixed an **AppleScript-injection**
    vulnerability via crafted filenames (Get Info / Open-in-Terminal), wired up
    the dead **Toggle Hidden Files** (⌘⇧.) command, fixed **unsaved-Markdown
    data loss** on close, and made **paste/move partial failures** undo-safe.
11. **Release engineering** — Universal (Intel + Apple Silicon) build, a
    one-command DMG packager (`release.sh`), README + in-DMG install/permission
    guide, a modern flat app icon, and removal of a deprecated API call.

---

## Known limitations (by design)

- **Not notarized** (free distribution, no paid Apple Developer account) — a
  one-time Gatekeeper "Open Anyway" is required on first launch. See the README.
- **Finder cannot be fully replaced** — the Desktop, drive mounting, Open/Save
  dialogs, and the Dock's Finder icon always remain Finder (a macOS limitation).
- **Requires macOS 14 (Sonoma) or newer.**
