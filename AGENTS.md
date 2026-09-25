# AGENTS.md — uputstvo za AI agente u ovom repo-u

## PDF čitanje (Jev + svi budući agenti)

Ne izmišljaj čitanje PDF-a i ne šalji PDF-ove na spoljne OCR servise.
Koristi lokalni **PDFInspector** (port ideje `firecrawl/pdf-inspector`):

- U app-u (Swift): `aiFlow/PDFInspector.swift`
  `PDFInspector.processPDF(url:)` → `pdf_type | confidence | pages_needing_ocr | markdown`.
  Za prompt izvod: `PDFInspector.describe(url:size:maxChars:)` → `(preview, details)`.
- Iz terminala / drugog agenta: `./tools/pdf-inspect/run.sh dokument.pdf --json`
  (flagovi: `--excerpt N`, `--detect`, `--select-pages 1,3,5-10`, `--no-ocr`, `--pretty`).
- Puni API + JSON šema: `docs/pdf-inspector.md`.

Pravila:

1. Prvo klasifikuj (`--detect` ili `pdf_type`), pa tek onda čitaj tekst.
2. `text_based` + visok confidence → direktno `markdown`, bez OCR-a.
3. `scanned` / `mixed` → `pages_needing_ocr` kaže koje strane trebaju OCR
   (Vision on-device, ništa se ne uploaduje).
4. Excerpt za model max ~4000 znakova, format `"label: vrednost | label: vrednost"`.
5. Ako menjaš logiku ekstrakcije, sinhronizuj OBA mesta:
   `aiFlow/PDFInspector.swift` i `tools/pdf-inspect/main.swift`.

## E-Sign (potpis PDF-a)

- Kod: `aiFlow/SignaturePad.swift` (port `signature_pad`, MIT — zadrži
  licencu na dnu fajla), `ESignEngine.swift` (biblioteka potpisa, flatten,
  Ed25519 pečat), `ESignWindow.swift` (prozor, PDFView, Services),
  `SignatureCreatorSheet.swift`.
- Testovi/harness: postavi `FF_ESIGN_DIR=<privremeni folder>` — tada se potpisi
  i ključ pišu tamo, nikad u korisnikov
  `~/Library/Application Support/FinderFlow/Signatures/` (tu je njegov pravi
  ključ za pečat; ne diraj ga i ne briši).
- Original se nikad ne mijenja: izlaz je uvijek nova "(signed)" kopija.

## Brend (aiFlow)

- Vidljivo ime je **aiFlow** (wordmark: „ai" u gradijentu ikone + „Flow").
  Source folderi su preimenovani: `aiFlow/` (app kod), `aiFlowExtension/`,
  `aiFlowShareAgent/`, projekat `aiFlow.xcodeproj`, Mail skripta `aiFlowSave`.
  Xcode proizvod je `aiFlow.app` (izvršni fajl `aiFlow`), release daje
  `aiFlow-<verzija>.dmg` + `.sha256`.
  Interno ostaje staro ime: bundle ID `com.finderflow.app` (+ `.extension`),
  Swift modul `FinderFlow` (`PRODUCT_MODULE_NAME`, `-module-name`), Xcode
  target/scheme `FinderFlow`, `FinderFlowExtension.appex`, folderi u
  Application Support, Keychain ključevi, URL scheme `finderflow://`,
  launchd label `com.finderflow.share-agent` — ne mijenjaj ih (podešavanja,
  ključevi i dozvole bi se izgubili).
- Repo i izdanja: **github.com/nnikolaandric-sudo/aiFlow**. Updater
  (`aiFlow/UpdateManager.swift`) čita samo njegova izdanja; svako izdanje
  mora imati DMG **i** `<dmg>.sha256`, inače updater odbija. Instalacijska
  skripta u UpdateManageru je bash — samo `#` komentari (`//` ruši update).
- Lokalni build daje `build/local/aiFlow.app` (izvršni fajl `aiFlow`);
  instalirano je `/Applications/aiFlow.app` — nikad ne vraćaj `FinderFlow.app` pored nje.
- Ikona: `swift tools/brand/make_icon.swift <dir>` (16 px ima pojednostavljen crtež).

## Build

- App bez Xcode-a: `./build-local.sh --no-run` (samo Command Line Tools).
  U rsync kopiji bez `build/` kopiraj i `build/cloudflared/` — inače build
  skida cloudflared s mreže i pada bez interneta.
- Novi `.swift` fajl upiši i u `aiFlow.xcodeproj/project.pbxproj`
  (PBXBuildFile + PBXFileReference + grupa + Sources faza app targeta).
  `build-local.sh` kompajlira `aiFlow/*.swift` pa propust ne vidi, ali
  `release.sh` (xcodebuild) pada — 2026-09-24 je nedostajalo 18 fajlova.
  Provjera: svaki `aiFlow/*.swift` mora imati `path = <ime>;` u pbxproj.
- Release bez Xcode-a: `./build-local.sh Release --no-run` pa
  `./release.sh --prebuilt build/local/aiFlow.app` (Apple Silicon, bez
  Finder ekstenzije); s Xcode-om samo `./release.sh` (Universal).
- CLI provera: `./tools/pdf-inspect/run.sh --build-only`.
- Gdrive harness: `./tools/gdrive-test/run.sh`.

## Privatnost

Sve lokalno na Mac-u. Mreža samo za opt-in: AI Organizer (OpenRouter),
Folder Rules AI (Settings ▸ Folder Rules, podrazumijevano isključeno),
Send to Discord, Check for Updates. Nikad ne šalji sadržaj fajlova van
onoga što korisnik eksplicitno odobri.

## Folder Rules (automatsko sređivanje)

- Kod: `aiFlow/FolderRules.swift` (model, offline parser pravila, engine,
  watcher, AI gate) i `aiFlow/FolderRulesUI.swift` (desni klik, prozor s
  pravilima, Settings sekcija, bedž u statusnoj traci).
- Testovi/harness: postavi `FF_FOLDER_RULES_DIR=<privremeni folder>` (dnevnik
  i AI keš idu tamo, ne u korisnikov Application Support), podmetni
  `AIService.keysProvider` i `FolderRulesAI.session` (URLProtocol mock) —
  nikad pravi ključ ni mreža.
- Nikad trajno brisanje: akcija je samo Trash, svaki potez ide u dnevnik sa
  Undo. AI bez uključenog prekidača ne smije poslati nijedan zahtjev.

## Mail Inbox
- Kod: `MailFilingService.swift` (pipeline, AI, reorganize + undo),
  `MailInboxView.swift`, `MailInboxWindow.swift` (Settings),
  `MailSources.swift` (uvoz iz Mail.app, instalacija Mail pravila, auto-sync).
- Testovi/harness: postavi `FF_MAIL_DIR=<privremeni folder>` i
  `ffMailRoot` na privremeni Email folder — nikad korisnikov store u
  Application Support; `AIService.keysProvider` podmetni, nikad pravi ključ.
- Ne diraj korisnikov Mail.app iz testova (uvoz selekcije šalje Apple Events).

## Workspace Mode (projektni sloj na folderu, Preview panel)

- Kod: `WorkspaceModels.swift` (taskovi, reminderi, review lifecycle,
  validity/expiry, relacije, file requests, activity; reference na fajlove su
  relativne na root), `WorkspaceStore.swift` (CRUD, JSON persistencija,
  bedževi, macOS notifikacije, SecureShare lookup, quick-capture composer),
  `WorkspaceViews.swift` (overview, file tabovi, sheetovi).
- `Workspace` ima custom `init(from:)` sa `decodeIfPresent` defaultima —
  store iz starije verzije se mora učitati, nikad obrisati. Novo polje uvijek
  dodaj i u `CodingKeys` i u `init(from:)`.
- Testovi/harness: postavi `FF_WORKSPACE_DIR=<privremeni folder>` i
  `FF_WORKSPACE_DISABLE_NOTIF=1` (bez auth prompta); store se može
  kompajlirati headless (`WorkspaceModels` + `WorkspaceStore` + stub za
  `SecureShareDatabase`) jer je Foundation-only.
- Privatnost: sve lokalno (JSON u Application Support); jedini izlazak je
  sistemski notification prompt (jednokratno, na prvoj notifikaciji) i
  postojeći SecureShare prozor kad ga korisnik sam otvori. Nikad ne diraj
  korisnikov `~/Library/Application Support/FinderFlow/Workspaces/` iz testova.

## Today, ⌘K paleta, PDF Tools, App Intents (Shortcuts)

- Kod: `TodayView.swift` (Today prozor + sidebar red s bedžom; ne čuva
  podatke — `TodaySnapshot.build` računa iz Workspace/Mail/Folder Rules
  storeova, akcije idu kroz njihove API-je), `CommandPalette.swift` (⌘K;
  selekciju browsera daje `FFSelectionBridge` modifier na ContentView),
  `PDFTools.swift` (`PDFToolsEngine` bez UI-ja + prozor + desni klik +
  Finder Services), `AppIntents.swift` (Shortcuts akcije + App Shortcut).
- Today izmjene idu SAMO kroz `TodayEditor.apply` (jedan `updateWorkspace` po
  workspaceu + activity red po stavci) i `TodayModel.perform` (undo preko
  window UndoManagera = snapshot workspacea). Dokumenti se iz Today nikad ne
  brišu — „delete" na reviewu/isteku samo odbacuje podsjetnik.
- PDF Tools nikad ne mijenja original — rezultat je nova datoteka pored
  njega (`uniqueDestinationURL`). OCR = PDFKit `saveTextFromOCROption`
  (Vision na uređaju, ništa se ne uploaduje).
- ⚠️ App Intents bez Xcodea: `build-local.sh` piše
  `Contents/Resources/Metadata.appintents` preko
  `tools/appintents/make_metadata.py` (mangled imena čita iz binarnog `nm`).
  Novi/preimenovani intent ili `@Parameter` → ažuriraj `INTENTS` u skripti,
  inače Shortcuts prikaže akciju ali je ne može pokrenuti.
- Testovi/harness: `FF_WORKSPACE_DIR`, `FF_WORKSPACE_DISABLE_NOTIF=1`,
  `FF_MAIL_DIR`, `FF_FOLDER_RULES_DIR`, `FF_SHARE_DIR` (Today čita Secure
  Share registar), sve na privremene foldere. Folder Rules čeka da se
  svjež fajl „slegne" — u testu postavi stariji modification date.

## Version History (verzije dokumenata)

- Kod: `VersionStore.swift` (motor, Foundation-only: FSEvents watcher,
  APFS clonefile snimci u `Application Support/FinderFlow/Versions/blobs`
  imenovani po SHA-256, labele v1…/v3.1, rename/fork detekcija, 5 GB cap),
  `VersionViews.swift` (stablo, Preview/Restore/Duplicate/Compare, Settings ▸
  Browse sekcija, desni klik). Badge `v4` ide kroz `WorkspaceStore.Badge.versionLabel`
  (`WorkspaceStore.versionLabelProvider` postavlja VersionStore.start()).
- Prate se Workspace folderi + folderi iz desnog klika ▸ Track Versions.
  Korisnikovi fajlovi se diraju SAMO na Restore/Duplicate (Restore prvo
  snimi trenutno stanje). Obrezivanje briše samo naše kopije, nikad
  trenutnu verziju ni zadnje 3 po fajlu.
- Putanje: `VersionStore.canonical` = realpath foldera + ime (FSEvents oblik);
  NE `resolvingSymlinksInPath`/`standardizedFileURL` — oni skidaju `/private`
  samo dok fajl postoji. Labele se registruju pod oba zapisa.
- Fork za .docx/.xlsx/.pptx: porede se samo sadržajni dijelovi (document.xml,
  slides, sheets) raspakovani preko Compression (raw DEFLATE), 3-gram riječi;
  šablonski dijelovi (styles/theme) bi inače spojili nepovezane dokumente.
- Performanse (2026-09-25, bio je uzrok usporenja): Git work tree-ovi se ne
  verzionišu; >20 novih fajlova u jednom settle prozoru = bulk → samo SHA
  provjera; najviše 8 poređenja po fajlu i JEDAN `MDItem` (lastUsed) za
  najboljeg kandidata — nikad Spotlight po kandidatu; queue je `.background`.
  Benchmark: 400 novih fajlova u 1.200-fajl projektu mora ostati < 1 s.
- Testovi/harness: `FF_VERSIONS_DIR=<privremeni folder>`, `processSync` /
  `scanSync` / `setRootsSync`, `VersionStore.capBytes` se smije spustiti u
  testu. Nikad ne diraj korisnikov `Application Support/FinderFlow/Versions/`.
