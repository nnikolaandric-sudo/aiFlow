import SwiftUI
import AppKit
import Quartz

struct ContentView: View {
    @StateObject private var folderService = FolderCreationService()
    @StateObject private var searchEngine  = SearchEngine()
    @StateObject private var fileOps       = FileOperationsService()
    @StateObject private var tagService    = TagService()
    @StateObject private var navHistory    = NavigationHistory()
    @StateObject private var discord       = DiscordShareService.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @EnvironmentObject  var  favorites:      FavoritesService

    @State private var currentPath:     URL       = FileManager.default.homeDirectoryForCurrentUser
    @State private var sidebarItem:     SidebarItem?
    @State private var isHistoryNav = false
    @State private var showGoToFolder = false

    // Browser tabs (v1): svaki tab drzi svoju putanju; aktivni tab vozi
    // currentPath (navigacija upisuje nazad u tab). Globalni navHistory je
    // zasad deljen — per-tab istorija je sledeca faza.
    // Inicijalno stanje dolazi iz init-a (sacuvani tabovi) da prvi frejm vec
    // ima traku — inace bi se pojavila frejm kasnije i pomerila sadrzaj.
    @State private var tabs: [BrowserTab] = []
    @State private var activeTabID: UUID?

    init() {
        let initial = BrowserTabsStore.initial()
        _tabs = State(initialValue: initial.tabs)
        _activeTabID = State(initialValue: initial.activeID)
    }

    // Persisted browse prefs — Finder-like defaults on first launch
    @AppStorage(UserPreferences.viewModeKey)       private var viewModeRaw       = UserPreferences.defaultViewMode.rawValue
    @AppStorage(UserPreferences.sortFieldKey)      private var sortFieldRaw      = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey)  private var sortAscending     = UserPreferences.defaultSortAscending
    @AppStorage(UserPreferences.groupByKey)        private var groupByRaw        = UserPreferences.defaultGroupBy.rawValue
    @AppStorage(UserPreferences.folderOrderKey)    private var folderOrderRaw    = UserPreferences.defaultFolderOrder.rawValue
    @AppStorage(UserPreferences.showHiddenKey)     private var showHidden        = false
    @AppStorage(UserPreferences.showPreviewKey)    private var showPreview       = false
    // Preview width ("ffPreviewWidth") lives in PreviewSplit: dragging it
    // must not re-evaluate this whole view on every mouse move.
    /// Compact rows (View menu); flows via environment so row views
    /// (incl. .equatable() ones) update with no signature changes.
    @AppStorage(UserPreferences.compactDensityKey) private var compactDensity = false
    @AppStorage(UserPreferences.showColumnTreeKey) private var showColumnTree    = false
    @AppStorage(UserPreferences.showDualPaneKey)   private var isDualPane      = false
    @AppStorage(UserPreferences.showFolderSizesKey) private var showFolderSizes = false
    @AppStorage(UserPreferences.didShowFirstRunKey) private var didShowFirstRun  = false
    @State private var showFirstRun = false

    // Dual-pane + batch rename state
    @State private var secondaryPath: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var secondaryIDs: Set<String> = []
    @State private var secondaryFiles: [FileItem] = []
    @State private var secondaryPendingRenameURL: URL?
    @State private var secondaryLoading = false
    @State private var secondaryGeneration: UInt = 0
    @State private var showBatchRename = false
    @State private var batchTargets: [FileItem] = []
    /// Workspace quick capture sheets (right-click → Add Task/Reminder).
    @State private var composeTask: WorkspaceComposeRequest?
    @State private var composeReminder: WorkspaceComposeRequest?
    @State private var showDiscordSheet = false
    @State private var discordTargets: [FileItem] = []

    private var viewMode: ViewMode       { ViewMode.fromStorage(viewModeRaw) }
    private var sortField: SortField     { SortField.fromStorage(sortFieldRaw) }
    private var groupBy: GroupBy         { GroupBy.fromStorage(groupByRaw) }
    private var folderOrder: FolderOrder { FolderOrder.fromStorage(folderOrderRaw) }

    @State private var selectedIDs:      Set<String> = []
    @State private var rawFiles:            [FileItem] = []
    @State private var searchDisplayFiles:  [FileItem] = []   // pre-computed search results (avoid reloading on every render)
    @State private var pendingSelectURL: URL?
    /// Batch reveal: svi rezultati poslednje operacije (paste N fajlova,
    /// batch rename…). `pendingSelectURL` ostaje kao legacy za single putanje
    /// (rename prompt, ffRevealFile) — novi put puni ovaj niz.
    @State private var pendingSelectURLs: [URL] = []
    /// Folder kojem `pendingSelectURLs` pripada. Štiti od stale selecta:
    /// operacija u A + brza navigacija u B + reload B ne smije selektirati
    /// ni skrolati ništa (path-match je ionako siguran, ali pending bi
    /// visio zauvijek i iznenadio pri povratku u A). Reveal postavlja,
    /// potrošnja čisti, ručna navigacija drugdje odbacuje.
    @State private var pendingSelectDestination: URL?
    /// Reveal za desni (secondary) pane u dual-pane modu — primarni
    /// `pendingSelect*` ga nikad nije hranio pa je copy→secondary ostajao
    /// nevidljiv dok se rucno ne ode u taj folder.
    @State private var pendingSecondarySelectURLs: [URL] = []
    @State private var pendingRenameURL: URL?
    @State private var activeTagFilter:  String? = nil
    @State private var tagDisplayFiles:  [FileItem] = []
    @State private var toastItem:        ToastPayload?
    /// Auto-dismiss for the current toast. Scheduled in showToast — the
    /// overlay's onAppear doesn't fire again when a new toast replaces one
    /// that's still visible, so that toast used to stay up for good.
    @State private var toastDismissWork: DispatchWorkItem?
    @State private var showAIOrganizer = false
    @State private var errorMsg:         String?
    /// Folder-navigation fade dip (see primaryPane): true for one frame on
    /// currentPath change, then animated back to false.
    @State private var reloadGeneration: UInt = 0
    /// Bumped every time `rawFiles` is assigned a new listing. Lets memo keys
    /// fold in "which listing" in O(1) instead of hashing the whole folder.
    @State private var filesIdentity: UInt = 0
    /// Same for the Spotlight tag-result list (`tagDisplayFiles`).
    @State private var tagFilesIdentity: UInt = 0
    // Cached tag list for the sidebar — `usedTagNames` does Set+flatMap+sort
    // over all files, so recompute only when `rawFiles` changes, not per render.
    @State private var cachedUsedTagNames: [String] = []
    // Render memo cache (reference type, never triggers refresh): dedupe+sort
    // and fuzzy rank previously re-ran on every body eval (selection/sort
    // changes). A plain class avoids "modifying state during view update".
    private let memo = DisplayMemoCache()
    // UX: distinguishes "still loading" from "folder is really empty" so we
    // don't flash a false EmptyFolderView on every navigation.
    @State private var isLoading: Bool = true
    // Greška čitanja tekućeg foldera (TCC dozvola, nestao folder, Drive…).
    // Ranije se prikazivao lažni "prazan folder" — sada UI pokazuje razlog.
    @State private var folderError: FolderReadError?
    @State private var secondaryError: FolderReadError?
    // Lokalni fuzzy rank van main threada: `displayFiles` se evaluira na svaki
    // body eval (i na svaki klik), a rank celog foldera na mainu je zamrzavao
    // kucanje. Rank se računa u pozadini na promenu query-ja/listinga, a ovde
    // se samo čita gotov rezultat — nikad blokada rendera.
    @State private var localSearchFiles: [FileItem] = []
    @State private var localSearchKey = ""
    @State private var localSearchGen: UInt = 0
    /// Debounce work item for scheduleLocalRank — coalesces rapid keystrokes
    /// so a full-folder fuzzy rank doesn't launch on every character.
    @State private var localRankWork: DispatchWorkItem?
    /// Identity for search/tag result listings — bumps whenever those lists
    /// change so grouping memos use an O(1) key instead of contentSignature.
    @State private var searchIdentity: UInt = 1
    // Sort velikih foldera (>2k) ide u pozadinu: `localizedCompare` nad 10k
    // fajlova na mainu je 200ms+ blokade. Generacija štiti od trke.
    @State private var largeSortGen: UInt = 0
    /// Granica iznad koje se sortiranje seli sa main threada u pozadinu.
    private let largeFolderThreshold = 2000
    /// Keširani snimak veći od ovoga sortira se van maina (vidi `_reload`).
    private let backgroundSortThreshold = 1000
    // Recursive folder sizing ("Calculate folder sizes", default OFF):
    // thread-safe run state (the background walk reads it off-main) + a flag
    // driving the "Calculating sizes…" status-bar indicator.
    @State private var folderSizingActive = false
    /// Bumped on every sizing publish so Columns panes (which own their own
    /// listings) can re-attach freshly cached sizes without any disk walk.
    @State private var folderSizesVersion: UInt = 0
    private let folderSizeRuns = FolderSizeRunState()

    // Derived selected item for preview. Reuses the memoized selection so a
    // single-item body eval doesn't scan the folder twice (once here, once in
    // the SelectionActionBar's filter).
    private var selectedItem: FileItem? {
        let sel = primarySelectedItems
        guard sel.count == 1 else { return sel.first }
        return sel[0]
    }

    // Selected folder URL — used by IDE toolbar buttons to open the right folder
    private var selectedFolderURL: URL? {
        guard let item = selectedItem, item.isBrowsableFolder else { return nil }
        return item.url
    }

    // Active destination: used for both paste and new-item creation.
    // If exactly one folder is selected, target it; otherwise use currentPath.
    // Derivirano iz memoizovanog primarySelectedItems — bez novog O(n) skena
    // foldera na svaki klik (pre je displayFiles.first(where:) skenirao sve).
    private var activeDestination: URL {
        let sel = primarySelectedItems
        if sel.count == 1, let s = sel.first, s.isBrowsableFolder {
            return s.url
        }
        return currentPath
    }

    private var pasteDestination: URL { activeDestination }

    // MARK: - Reveal after file operations (jump-ako-nevidljivo)

    /// Centralni reveal: nakon rename/paste/extract/duplicate… selektuj
    /// rezultat tamo gdje je sleteo. Jump (promjena currentPath) samo ako
    /// rezultat nije u trenutno vidljivom folderu; inače samo select+scroll.
    /// Pane-aware: ako je destinacija secondary pane, selekcija ide tamo.
    func revealFileResults(_ urls: [URL], destination: URL?, forceJump: Bool = false) {
        guard !urls.isEmpty else { return }
        let dest = destination ?? urls.first!.deletingLastPathComponent()
        // Ne prekidaj inline rename dijalog — samo zapamti selekciju.
        if isEditingText() {
            pendingSelectURLs = urls
            pendingSelectDestination = dest
            NotificationCenter.default.post(name: .refreshDirectory, object: dest)
            return
        }
        // Destinacija je secondary pane (isti folder ili njegov subfolder dok
        // primarni gleda drugdje) → selektuj/jumpuj tamo, ne diraj primarni.
        if isDualPane && !ffSamePath(dest, currentPath)
            && (ffSamePath(dest, secondaryPath) || ffIsAncestor(path: secondaryPath, of: dest)) {
            // Jump secondary-ja u subfolder ako treba (paste u selektovani
            // subfolder dok gledaš parent u desnom pane-u).
            if !ffSamePath(dest, secondaryPath) {
                pendingSecondarySelectURLs = urls
                secondaryPath = dest // onChange → reloadSecondary → select
            } else {
                pendingSecondarySelectURLs = urls
                // Ako je listing već tu, selektuj odmah; inače će onChange
                // secondaryFiles to odraditi nakon reloadSecondary.
                let ids = Set(secondaryFiles.filter { f in urls.contains(f.url) }.map(\.id))
                if !ids.isEmpty {
                    secondaryIDs = ids
                    pendingSecondarySelectURLs = []
                } else {
                    reloadSecondary()
                }
            }
            NotificationCenter.default.post(name: .refreshDirectory, object: dest)
            return
        }
        // Search/tag mod zamjenjuje listing — jump bi bacio query; ostani i
        // ponudi "Show" preko toasta (revealURLs su već u payloadu).
        // forceJump (eksplicitni klik na Show) izlazi iz searcha i skače.
        if isSearchActive && !forceJump {
            pendingSelectURLs = urls
            pendingSelectDestination = dest
            NotificationCenter.default.post(name: .refreshDirectory, object: dest)
            return
        }
        if isSearchActive && forceJump {
            searchEngine.query = ""
            activeTagFilter = nil
        }
        if !ffSamePath(dest, currentPath) {
            // Jump u folder gdje je operacija sletela; onChange(currentPath)
            // → reload → onChange(rawFiles) selektuje via pendingSelectURLs.
            pendingSelectURLs = urls
            pendingSelectURL = urls.first
            pendingSelectDestination = dest
            currentPath = dest
        } else {
            // Isti folder: selektuj + scroll nakon reloada (sigurnije od
            // samog pending jer reload može donijeti novi listing).
            pendingSelectURLs = urls
            pendingSelectURL = urls.first
            pendingSelectDestination = dest
            _reload {
                self.selectPrimaryURLs(urls)
            }
        }
        NotificationCenter.default.post(name: .refreshDirectory, object: dest)
    }

    /// Selektuje `urls` u primarnom pane-u ako su u trenutnom listingu i
    /// skroluje do prvog. Bezopasno zvati i kad listing još putuje — tada
    /// pending ostaje za onChange(rawFiles).
    private func selectPrimaryURLs(_ urls: [URL]) {
        let set = Set(urls.map(\.path))
        let matched = rawFiles.filter { set.contains($0.url.path) }
        guard !matched.isEmpty else { return }
        selectedIDs = Set(matched.map(\.id))
        pendingSelectURLs = pendingSelectURLs.filter { !set.contains($0.path) }
        if pendingSelectURLs.count <= 1, let first = matched.first,
           first.url == pendingSelectURL { pendingSelectURL = nil }
        else if pendingSelectURLs.isEmpty { pendingSelectURL = nil }
        if pendingSelectURLs.isEmpty { pendingSelectDestination = nil }
        // Bez ??0 fallbacka: kad target nije u vidljivom displayu
        // (search/tag filter, stale rank) scroll na row 0 je skok na
        // nepovezani fajl. Tada ostani gdje jesi — selekcija je već postavljena.
        guard let row = displayFiles.firstIndex(where: { $0.id == matched.first!.id }) else { return }
        scrollTableView(toRow: row)
    }

    // Split out of `body` so each chained expression stays within the Swift
    // type-checker's complexity budget (adding more modifiers to one giant
    // expression triggers "unable to type-check in reasonable time").
    private var splitView: some View {
        NavigationSplitView {
            SidebarView(currentPath: $currentPath, selection: $sidebarItem,
                        activeTagFilter: $activeTagFilter, usedTagNames: usedTagNames,
                        fileOps: fileOps, onReload: reload)
                .frame(minWidth: 160, idealWidth: 220)
                .background(ArrowCursorArea())   // resets cursor when leaving the sidebar divider
                .resetsCursorOnEnter()           // clears the divider's stuck resize cursor on entry
        } detail: {
            VStack(spacing: 0) {
                if case .available(let version, _, _, _) = updateManager.phase {
                    UpdateBanner(manager: updateManager, version: version)
                }
                // Tab bar: vidi se samo kad ima 2+ taba (jedan tab je samo
                // potrosen red — ⌘T i dalje radi, traka se pojavi s drugim tabom).
                if tabs.count > 1 {
                    BrowserTabBar(
                        tabs: $tabs,
                        activeID: $activeTabID,
                        onSelect: { selectTab($0.id) },
                        onNewTab: { newTab() },
                        onClose: { closeTab($0.id) },
                        onCloseOthers: { closeOtherTabs(keeping: $0.id) },
                        onDuplicate: { duplicateTab($0.id) }
                    )
                    .resetsCursorOnEnter()
                }
                // Combined top bar: breadcrumbs left, search right — one chrome
                // row instead of two stacked bars (~35px saved). Breadcrumbs
                // scroll internally, so the row degrades gracefully at narrow
                // widths; search keeps a usable minimum width.
                // Narrow windows (<~640pt): stack vertically so breadcrumbs
                // keep full width and search drops below (no clipping).
                // Search moved up into the window toolbar (top right, like
                // Finder) — this row is the path alone, full width.
                PathBarView(currentPath: $currentPath, fileOps: fileOps, onReload: reload,
                            hidesChrome: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider().opacity(0.6) }
                .resetsCursorOnEnter()   // clear a stuck resize cursor when moving up from the file list
                // Unified contextual toolbar (single row): no-selection → folder
                // actions, selection → Open/Cut/Copy/Rename/Compress/Extract/
                // Share inline here. The old second SelectionActionBar strip
                // is gone — one chrome row instead of two.
                QuickActionsToolbar(
                    currentPath:    $currentPath,
                    selectedURL:    selectedFolderURL,
                    selectedCount:  selectedIDs.count,
                    selectedURLs:   primarySelectedItems.map(\.url),
                    onCreateFolder: promptAndCreateFolder,
                    onCreateFile:   promptAndCreateFile,
                    onDelete:       confirmAndDeleteSelected,
                    onTrash:        trashSelected,
                    pasteDestination: pasteDestination,
                    fileOps:        fileOps,
                    viewMode:       viewModeBinding,
                    sortField:      sortFieldBinding,
                    sortAscending:  $sortAscending,
                    showHidden:     $showHidden,
                    groupBy:        groupByBinding,
                    folderOrder:    folderOrderBinding,
                    showPreview:    $showPreview,
                    showColumnTree: $showColumnTree,
                    onReload:       reload,
                    canGoBack:      navHistory.canGoBack,
                    canGoForward:   navHistory.canGoForward,
                    onGoBack:       goBack,
                    onGoForward:    goForward,
                    onGoToFolder:   { showGoToFolder = true },
                    isDualPane:     isDualPane,
                    onToggleDualPane: toggleDualPane,
                    onBatchRename:  { openBatchRename(primarySelectedItems) },
                    onAIOrganize:   { aiOrganizeCurrentFolder() },
                    showFolderSizes: $showFolderSizes,
                    selectedItems: primarySelectedItems,
                    onNavigateItem: navigateItem,
                    onRenameItem: { renameRequest($0) },
                    onBatchRenameItems: openBatchRename,
                    onSendToDiscordItems: openDiscordShare,
                    onClearSelection: { selectedIDs.removeAll() }
                )
                .resetsCursorOnEnter()
                .animation(.easeOut(duration: 0.15), value: selectedIDs.count)

                // Browser + preview (splits into two panes when enabled).
                browserArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBarView(files: displayFiles, selectedIDs: selectedIDs, currentPath: currentPath,
                              filesIdentity: filesIdentity, selectionFingerprint: selectionFingerprint,
                              isSizing: folderSizingActive,
                              operationText: fileOps.lastActionFeedback.flatMap { $0.icon == "hourglass" ? $0.message : nil },
                              isLoading: isLoading || tagService.isSearchingTags)
            }
            .background(ArrowCursorArea())   // resets IBeam / resize cursor leaving search bar or column handles
            .resetsCursorOnEnter()           // clears the divider's stuck resize cursor on entry
            .overlay(alignment: .bottom) {
                if let toast = toastItem {
                    InAppToast(icon: toast.icon, message: toast.message, onShow: toast.revealURLs != nil ? {
                        if let urls = toast.revealURLs {
                            revealFileResults(urls, destination: toast.revealDestination, forceJump: true)
                            toastDismissWork?.cancel()
                            withAnimation(.easeOut(duration: 0.25)) { toastItem = nil }
                        }
                    } : nil)
                        .padding(.bottom, 30)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal:   .opacity
                        ))
                        .allowsHitTesting(toast.revealURLs != nil)
                        .id(toast.id)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastItem?.id)
        }
        .frame(minWidth: 640, minHeight: 480)
        // Finder layout: the folder name is the window title, search sits
        // top right in the title bar (the bar was an empty strip before).
        .navigationTitle(currentPath.lastPathComponent.isEmpty ? "aiFlow" : currentPath.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SearchScopeView(currentPath: currentPath, searchEngine: searchEngine,
                                localResultCount: localSearchFiles.count, hidesChrome: true)
                    .frame(width: 260)
            }
        }
        .background(QLResponderSetup())
        .environment(\.ffCompactRows, compactDensity)

        // ── Keyboard shortcuts ──────────────────────────────────────────
        .background(keyboardShortcuts)
    }

    private var splitWithChanges: some View {
        splitView
        // ── Lifecycle ───────────────────────────────────────────────────
        .onAppear {
            UserPreferences.migrateBrowseDefaultsIfNeeded()
            // Touchpad swipe: dva prsta levo/desno = Back/Forward.
            // Instaliraj monitor + ugasi ga u Columns modu (horizontalni
            // scroll tamo pripada kolonama, ne navigaciji).
            _ = TrackpadSwipeNav.shared
            TrackpadSwipeNav.shared.browserSwipeEnabled = (viewMode != .columns)
            // Backspace → Enclosing Folder monitor (AppKit level: SwiftUI's
            // hidden .delete shortcut never fires from the file list).
            _ = BackspaceUpNav.shared
            initTabsIfNeeded()
            navHistory.seed(currentPath)
            // Keep SearchEngine's hidden-file flag in sync — it was never
            // written anywhere, so local/recursive searches always skipped
            // hidden files even with Show Hidden Files on.
            searchEngine.showHidden = showHidden
            reload()
            GitService.shared.refresh(for: currentPath)
            if isDualPane { reloadSecondary() }
            updateManager.checkIfNeeded()
            if !didShowFirstRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showFirstRun = true
                }
            }
            // Cold launch via "Open in FinderFlow" / default folder handler:
            // the open request may arrive before this view is listening.
            if let pending = AppDelegate.pendingNavigationURL {
                AppDelegate.pendingNavigationURL = nil
                if pending != currentPath { currentPath = pending }
            }
        }
        // Don't clear the icon cache on every navigation — NSCache evicts under
        // memory pressure automatically; keeping icons warm makes navigation fast.
        .onChange(of: currentPath)   { _, newPath  in
            // History: user navigations push; back/forward pops set the flag.
            if isHistoryNav {
                isHistoryNav = false
            } else {
                navHistory.push(newPath)
            }
            // Aktivni tab prati navigaciju (vidi BrowserTabs.swift).
            syncActiveTabPath(newPath)
            // Instant feedback: if we have a snapshot, paint it immediately
            // (no flash of empty/spinner). Otherwise clear and show spinner
            // while the background reload runs.
            selectedIDs = []
            activeTagFilter = nil
            // Stale reveal guard: ručna navigacija u folder različit od
            // destinacije operacije odbacuje pending (premještanje/brisanje/
            // reorganizacija + brz Back/klik ne smije kasnije selektirati
            // niti skrolati u pogrešnom folderu). Reveal-navigacija postavlja
            // pendingSelectDestination == newPath pa je pošteđena.
            if let dest = pendingSelectDestination, !ffSamePath(dest, newPath) {
                pendingSelectURLs = []
                pendingSelectURL = nil
                pendingSelectDestination = nil
            }
            // Stara greška ne sme da treperi na novom folderu dok load putuje.
            folderError = nil
            if DirectoryCache.shared.cachedItems(for: newPath, showHidden: showHidden) != nil {
                isLoading = false
            } else {
                rawFiles = []
                filesIdentity &+= 1
                isLoading = true
            }
            reload()
            // Git-aware filesystem: svaka navigacija detektuje repo (.git ka
            // parentima) i osvježava status/branch za bedževe i status bar.
            GitService.shared.refresh(for: newPath)
        }
        .onChange(of: viewModeRaw) { _, raw in
            TrackpadSwipeNav.shared.browserSwipeEnabled = (ViewMode.fromStorage(raw) != .columns)
        }
        .onChange(of: sortFieldRaw)     { _, _  in applySortPrefsChange() }
        .onChange(of: sortAscending) { _, _  in applySortPrefsChange() }
        .onChange(of: folderOrderRaw)   { _, _  in applySortPrefsChange() }
        .onChange(of: showHidden)    { _, hidden in
            searchEngine.showHidden = hidden
            reload(); if isDualPane { reloadSecondary() }
        }
        .onChange(of: showFolderSizes) { _, enabled in
            if enabled { maybeStartFolderSizing() }
            else {
                folderSizeRuns.next()
                folderSizingActive = false
                stripFolderSizes()
                // Bez ovoga bi ostao redosled po obrisanim veličinama.
                if sortField == .size { applySortPrefsChange() }
            }
        }
        .onChange(of: secondaryPath) { _, _ in
            secondaryIDs = []
            secondaryError = nil
        }
        .onChange(of: isDualPane) { _, enabled in
            if enabled { reloadSecondary() } else { secondaryIDs = [] }
        }
        // Rank search results in background (never on the render thread): one flat
        // list, closest match to the query first, newest first among equal matches.
        .onChange(of: searchEngine.resultsVersion) { _, version in
            let results = searchEngine.results
            if results.isEmpty { searchDisplayFiles = []; searchIdentity &+= 1; return }
            let query = searchEngine.query
            let attachSizes = showFolderSizes
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = results.compactMap { FileItem.load(from: $0) }
                // Spotlight hits are fresh snapshots (no folderSize) — attach
                // whatever the sizing run cached so folders show sizes here
                // too. No walk is ever triggered from search results.
                let sized = attachSizes ? FolderSizeService.attachingCachedSizes(to: loaded) : loaded
                let files = rankedPrefilteredItems(sized, query: query)
                DispatchQueue.main.async {
                    // A newer result set may have landed while this one was ranking.
                    guard version == searchEngine.resultsVersion else { return }
                    searchDisplayFiles = files
                    searchIdentity &+= 1
                }
            }
        }
        // Lokalni rank van maina: na svaku promenu query-ja ili listinga
        // (filesIdentity) rankira se u pozadini; displayFiles samo čita gotovo.
        // Samo za .thisFolder scope — ostali scope-ovi idu kroz SearchEngine
        // (Spotlight / rekurzivna šetnja), pa bi dupli pipeline bio uzaludan rad.
        .onChange(of: searchEngine.query) { _, q in handleSearchQueryChange(q) }
        .onChange(of: searchEngine.selectedScope) { _, _ in
            guard !searchEngine.query.isEmpty else { return }
            handleSearchQueryChange(searchEngine.query)
        }
        .onChange(of: filesIdentity) { _, identity in
            guard !searchEngine.query.isEmpty,
                  searchEngine.selectedScope == .thisFolder else { return }
            scheduleLocalRank(query: searchEngine.query, files: rawFiles, identity: identity)
        }
        // Select items after paste/duplicate/rename/extract (multi-select za
        // batch operacije). Jump-ako-nevidljivo postavlja pendingSelectURLs
        // prije currentPath promjene pa ovaj handler selektuje nakon reloada.
        // Tijelo je u helperu ispod — inline verzija je rušila type-checker.
        // (Secondary pane ima svoj onChange uz SecondaryPane u browserArea —
        // još jedan modifier ovdje probija type-checker budžet.)
        .onChange(of: rawFiles) { _, newFiles in applyPendingPrimarySelection(newFiles) }
    }

    private func applyPendingPrimarySelection(_ newFiles: [FileItem]) {
        refreshUsedTagNamesAsync(from: newFiles)
        if !pendingSelectURLs.isEmpty {
            applyPendingBatchSelection(newFiles)
            return
        }
        guard let url = pendingSelectURL else { return }
        // Stale guard: pending pripada drugom folderu (brza navigacija
        // nakon operacije) — ne selektiraj niti skrolaj, samo očisti.
        if let dest = pendingSelectDestination, !ffSamePath(dest, currentPath) {
            pendingSelectURL = nil
            pendingSelectDestination = nil
            return
        }
        guard let item = newFiles.first(where: { $0.url == url }) else { return }
        selectedIDs = [item.id]
        pendingSelectURL = nil
        pendingSelectDestination = nil
        let targetID = item.id
        DispatchQueue.main.async {
            // Bez ??0: nevidljiv target ne smije skrolati na vrh.
            guard let row = displayFiles.firstIndex(where: { $0.id == targetID }) else { return }
            scrollTableView(toRow: row)
        }
    }

    private func applyPendingBatchSelection(_ newFiles: [FileItem]) {
        // Stale guard: listing je za drugi folder od onog gdje je
        // operacija sletela (premještanje/brisanje/reorganizacija +
        // brza navigacija). Odbaci bez selekcije i bez skrola.
        if let dest = pendingSelectDestination, !ffSamePath(dest, currentPath) {
            pendingSelectURLs = []
            pendingSelectURL = nil
            pendingSelectDestination = nil
            return
        }
        let wanted = Set(pendingSelectURLs.map(\.path))
        let matched = newFiles.filter { wanted.contains($0.url.path) }
        guard !matched.isEmpty else { return }
        selectedIDs = Set(matched.map(\.id))
        let matchedPaths = Set(matched.map { $0.url.path })
        pendingSelectURLs.removeAll(where: { matchedPaths.contains($0.path) })
        if let single = pendingSelectURL, matchedPaths.contains(single.path) {
            pendingSelectURL = nil
        }
        if pendingSelectURLs.isEmpty {
            pendingSelectURL = nil
            pendingSelectDestination = nil
        }
        else if pendingSelectURLs.count == 1 { pendingSelectURL = pendingSelectURLs.first }
        guard let firstID = matched.first?.id else { return }
        DispatchQueue.main.async {
            // Bez ??0 fallbacka na row 0 (skok na nepovezani fajl).
            guard let row = displayFiles.firstIndex(where: { $0.id == firstID }) else { return }
            scrollTableView(toRow: row)
        }
    }

    private func applyPendingSecondarySelection(_ newFiles: [FileItem]) {
        guard !pendingSecondarySelectURLs.isEmpty else { return }
        let wanted = Set(pendingSecondarySelectURLs.map(\.path))
        let matched = newFiles.filter { wanted.contains($0.url.path) }
        guard !matched.isEmpty else { return }
        secondaryIDs = Set(matched.map(\.id))
        pendingSecondarySelectURLs = []
    }

    private var withCommandEvents: some View {
        splitWithChanges
        .onReceive(NotificationCenter.default.publisher(for: .createNewFolder)) { _ in
            promptAndCreateFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewFile)) { _ in
            promptAndCreateFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleHiddenFiles)) { _ in
            showHidden.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffTrashSelected)) { _ in
            guard !isEditingText() else { return }
            trashSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffShowInfo)) { _ in
            guard !isEditingText() else { return }
            showInfoForSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffSendViaMail)) { _ in
            if isEditingText() {
                showToast(ActionFeedback(icon: "exclamationmark.circle",
                                         message: "Click the file list first (focus is in a text field)"))
                return
            }
            sendSelectedViaMail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffQuickLink)) { _ in
            if isEditingText() {
                showToast(ActionFeedback(icon: "exclamationmark.circle",
                                         message: "Click the file list first (focus is in a text field)"))
                return
            }
            quickLinkSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGoBack)) { _ in goBack() }
        .onReceive(NotificationCenter.default.publisher(for: .ffGoForward)) { _ in goForward() }
        .onReceive(NotificationCenter.default.publisher(for: .ffGoUp)) { _ in goUp() }
        .onReceive(NotificationCenter.default.publisher(for: .ffGoToFolder)) { _ in showGoToFolder = true }
        .onReceive(NotificationCenter.default.publisher(for: .ffAIOrganize)) { _ in aiOrganizeCurrentFolder() }
        // File ▸ Sign Document…: selektovani PDF/slika, inace picker u ovom folderu.
        .onReceive(NotificationCenter.default.publisher(for: .ffESignSelection)) { n in
            guard let request = n.object as? ESignMenuRequest, !request.handled else { return }
            request.handled = true
            if let item = primarySelectedItems.first(where: { ESignSource.canSign($0.url) }) {
                ESignWindowManager.shared.open(item.url)
            } else {
                ESignWindowManager.shared.openPanel(in: currentPath)
            }
        }
        // Potpisana kopija (E-Sign) → osvezi i selektuj; "navigate" otvara i njen folder.
        .onReceive(NotificationCenter.default.publisher(for: .ffRevealFile)) { n in
            guard let url = n.object as? URL else { return }
            revealFileResults([url], destination: url.deletingLastPathComponent())
            // ffRevealFile nosi explicitni navigate flag — revealFileResults
            // jumpuje samo ako je nevidljivo, pa za navigate:true forsiraj.
            if n.userInfo?["navigate"] as? Bool == true,
               !ffSamePath(url.deletingLastPathComponent(), currentPath) {
                // Kao forceJump: izlazak iz search/tag moda je obavezan —
                // inače display i dalje pokazuje search rezultate pa pending
                // za drugi folder promaši firstIndex i (prije fixa) skoči na row 0.
                searchEngine.query = ""
                activeTagFilter = nil
                pendingSelectURLs = [url]
                pendingSelectURL = url
                pendingSelectDestination = url.deletingLastPathComponent()
                currentPath = url.deletingLastPathComponent()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffRefresh)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPath)) { n in
            AppDelegate.pendingNavigationURL = nil
            if let url = n.object as? URL, !ffSamePath(url, currentPath) { currentPath = url }
        }
    }

    /// Git notifications live in their own chain: the command-event chain
    /// above already sits at the type-checker's complexity budget (same
    /// reason as withTabEvents below).
    private var withGitEvents: some View {
        withCommandEvents
        // Git: desni klik / prečica traži preview (Diff/History/Repo).
        // Preview se otvara (showPreview=true), fajl se selektuje ili se
        // navigira u njegov folder — sam tab preuzima FilePreviewPanel.
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowDiff)) { n in
            if let url = n.object as? URL { handleGitPreviewRequest(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowHistory)) { n in
            if let url = n.object as? URL { handleGitPreviewRequest(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowRepo)) { n in
            if let url = n.object as? URL { handleGitPreviewRequest(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitDidChange)) { _ in reload() }
        // Git meni (Git ▸ View Changes ⌥⌘G / Status ⇧⌘G / History ⌥⌘H):
        // rezolvuje tekuću selekciju pa delegira istom preview putu.
        .onReceive(NotificationCenter.default.publisher(for: .ffGitDiffCurrent)) { _ in
            guard !isEditingText() else { return }
            gitDiffCurrent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitHistoryCurrent)) { _ in
            guard !isEditingText() else { return }
            gitHistoryCurrent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitRepoCurrent)) { _ in
            guard !isEditingText() else { return }
            gitRepoCurrent()
        }
    }

    private func gitDiffCurrent() {
        if let first = primarySelectedItems.first {
            GitUIRequest.shared.showDiff(for: first.url)
            handleGitPreviewRequest(first.url)
        } else {
            GitUIRequest.shared.showRepo(for: currentPath)
            handleGitPreviewRequest(currentPath)
        }
    }

    private func gitHistoryCurrent() {
        if let first = primarySelectedItems.first {
            GitUIRequest.shared.showHistory(for: first.url)
            handleGitPreviewRequest(first.url)
        } else {
            GitUIRequest.shared.showHistory(for: currentPath)
            handleGitPreviewRequest(currentPath)
        }
    }

    private func gitRepoCurrent() {
        if let first = primarySelectedItems.first {
            GitUIRequest.shared.showRepo(for: first.url)
            handleGitPreviewRequest(first.url)
        } else {
            GitUIRequest.shared.showRepo(for: currentPath)
            handleGitPreviewRequest(currentPath)
        }
    }

    /// Git preview zahtjev: otvori preview panel i dovedi URL u selekciju.
    private func handleGitPreviewRequest(_ url: URL) {
        showPreview = true
        // Sam repo folder (ili tekući folder) — samo otvori preview,
        // FilePreviewPanel pokazuje Repo tab preko currentFolder-a.
        if ffSamePath(url, currentPath) { return }
        let parent = url.deletingLastPathComponent()
        if ffSamePath(parent, currentPath) {
            // Fajl je u vidljivom folderu — selektuj direktno.
            selectedIDs = [url.path]
            return
        }
        var isDir: ObjCBool = false
        let existsDir = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        if existsDir, FileItem.isBrowsableFolder(url) {
            // Folder izvan tekućeg prikaza — navigiraj u njega.
            currentPath = url
            return
        }
        revealFileInBrowser(url)
    }

    /// Tab notifications live in their own chain: the command-event chain
    /// above already sits at the type-checker's complexity budget, and five
    /// more onReceive modifiers pushed it over ("unable to type-check").
    private var withTabEvents: some View {
        withGitEvents
        .onReceive(NotificationCenter.default.publisher(for: .ffNewTab)) { _ in newTab() }
        .onReceive(NotificationCenter.default.publisher(for: .ffCloseTab)) { _ in
            if let id = activeTabID { closeTab(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffNextTab)) { _ in cycleTab(forward: true) }
        .onReceive(NotificationCenter.default.publisher(for: .ffPrevTab)) { _ in cycleTab(forward: false) }
        .onReceive(NotificationCenter.default.publisher(for: .ffOpenInNewTab)) { n in
            if let url = n.object as? URL { openInNewTab(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffComposeTask)) { n in
            if let req = WorkspaceComposeRequest(notification: n) { composeTask = req }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffComposeReminder)) { n in
            if let req = WorkspaceComposeRequest(notification: n) { composeReminder = req }
        }
    }

    private var withServiceEvents: some View {
        withTabEvents
        // Folder/file created → navigate to destination if needed, then select & scroll.
        .onReceive(folderService.$lastCreatedURL.compactMap { $0 }) { url in
            revealFileResults([url], destination: url.deletingLastPathComponent())
        }
        .onReceive(fileOps.$lastOpURLs.compactMap { $0 }) { urls in
            revealFileResults(urls, destination: fileOps.lastOpDestination)
        }
        .onReceive(folderService.$errorMessage.compactMap      { $0 }) { msg in errorMsg = msg }
        .onReceive(fileOps.$errorMessage.compactMap            { $0 }) { msg in errorMsg = msg }
        .onReceive(fileOps.$lastActionFeedback) { f in
            if let f { showToast(f) } else { clearProgressToast() }
        }
        .onReceive(folderService.$lastActionFeedback.compactMap { $0 }) { f in showToast(f) }
        // Mail attach: picker se zatvori PRE AppleScript-a, pa se lastError
        // u footeru pickera nikad ne vidi — ovde ga dižemo na global sheet/toast.
        .onReceive(MailAttachService.shared.$lastError.compactMap { $0 }) { msg in
            errorMsg = msg
            MailAttachService.shared.lastError = nil
        }
        .onReceive(MailAttachService.shared.$lastMessage.compactMap { $0 }) { msg in
            showToast(ActionFeedback(icon: "paperclip.fill", message: msg))
            MailAttachService.shared.lastMessage = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffCopyPathFeedback)) { _ in
            showToast(ActionFeedback(icon: "doc.on.clipboard.fill", message: "Path copied"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffQuickLinkStarted)) { _ in
            showToast(ActionFeedback(icon: "hourglass", message: "Creating quick link…"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffQuickLinkFeedback)) { n in
            let msg = n.userInfo?["message"] as? String ?? "Link copied"
            let ok = n.userInfo?["success"] as? Bool ?? true
            if ok {
                showToast(ActionFeedback(icon: "link", message: msg))
            } else {
                showToast(ActionFeedback(icon: "exclamationmark.circle", message: msg))
            }
        }
        // When a tag is selected, search Mac-wide; when cleared, reset tagged results
        .onChange(of: activeTagFilter) { _, tag in
            if let tag {
                tagService.searchFiles(forTag: tag)
                // Tag-rezultati preuzimaju prikaz — otkaži run (vidi search).
                folderSizeRuns.next()
                folderSizingActive = false
            } else {
                tagService.stopSearch()
                tagDisplayFiles = []
                tagFilesIdentity &+= 1
                maybeStartFolderSizing()
            }
        }
        // Convert Spotlight tag results to FileItems in background
        .onChange(of: tagService.taggedFileURLs) { _, urls in
            let field = sortField; let asc = sortAscending; let fold = folderOrder
            let attachSizes = showFolderSizes
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = urls.compactMap { FileItem.load(from: $0) }
                // Attach before sorting so a Size sort is correct immediately.
                let sized = attachSizes ? FolderSizeService.attachingCachedSizes(to: loaded) : loaded
                let files = sortedItems(sized, by: field, ascending: asc, folderOrder: fold)
                DispatchQueue.main.async {
                    tagDisplayFiles = files
                    tagFilesIdentity &+= 1
                    searchIdentity &+= 1
                }
            }
        }
    }

    var body: some View {
        withServiceEvents
        .sheet(isPresented: Binding(
            get: { errorMsg != nil },
            set: { if !$0 {
                errorMsg = nil
                folderService.errorMessage = nil
                fileOps.errorMessage = nil
                MailAttachService.shared.lastError = nil
            }}
        )) {
            ErrorReportSheet(message: errorMsg ?? "") {
                errorMsg = nil
                folderService.errorMessage = nil
                fileOps.errorMessage = nil
                MailAttachService.shared.lastError = nil
            }
        }
        .sheet(isPresented: $showFirstRun, onDismiss: {
            didShowFirstRun = true
        }) {
            FirstRunSheet(isPresented: $showFirstRun)
        }
        .sheet(isPresented: $showGoToFolder) {
            GoToFolderSheet(currentPath: $currentPath, isPresented: $showGoToFolder)
        }
        .sheet(isPresented: $showBatchRename) {
            BatchRenameSheet(files: batchTargets, fileOps: fileOps, onDone: reloadBoth)
        }
        .sheet(isPresented: $showDiscordSheet) {
            SendToDiscordSheet(files: discordTargets, discord: discord) { msg in
                showToast(ActionFeedback(icon: "paperplane.fill", message: msg))
            }
        }
        .sheet(isPresented: $showAIOrganizer) {
            AIOrganizerSheet(folder: currentPath, folderFiles: rawFiles, selectedFiles: primarySelectedItems,
                             fileOps: fileOps, onApplied: reloadBoth)
        }
        // Workspace quick capture: right-click on any file → task/reminder
        // auto-linked to it (composer request via .ffComposeTask/Reminder).
        .sheet(item: $composeTask) { req in
            TaskEditSheet(workspaceID: req.workspaceID, rootURL: req.rootURL,
                           linkedFile: req.relative)
        }
        .sheet(item: $composeReminder) { req in
            ReminderSheet(workspaceID: req.workspaceID, linkedFile: req.relative)
        }
    }

    // MARK: - Keyboard shortcuts (hidden buttons)
    // Extracted from `body` to keep the main view expression within the Swift
    // type-checker's complexity budget.

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Group {
            Button("") { guard !isEditingText() else { return }; fileOps.undo() }
                .keyboardShortcut("z", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { guard !isEditingText() else { return }; fileOps.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).hidden().accessibilityHidden(true)
            Button("") {
                guard !isEditingText() else { return }
                let sel = displayFiles.filter { selectedIDs.contains($0.id) }
                if !sel.isEmpty { fileOps.copy(sel.map(\.url)) }
            }.keyboardShortcut("c", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") {
                guard !isEditingText() else { return }
                let sel = displayFiles.filter { selectedIDs.contains($0.id) }
                if !sel.isEmpty { fileOps.cut(sel.map(\.url)) }
            }.keyboardShortcut("x", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { guard !isEditingText() else { return }; fileOps.paste(to: pasteDestination, reload: reload) }
                .keyboardShortcut("v", modifiers: .command).hidden().accessibilityHidden(true)
            // ── Navigation (⌘[, ⌘], ⌘↑, ⇧⌘G) handled by FinderFlowCommands menu
            // → notifications (see onReceive above). No hidden duplicates here
            // to avoid double navigation.
            // ── View modes (⌘1/2/3) handled by View menu → same @AppStorage key.
            // No hidden duplicates: they double-fired with the menu.
            // ── Open selection ──────────────────────────────────────
            Button("") { guard !isEditingText() else { return }; openSelected() }
                .keyboardShortcut(.downArrow, modifiers: .command).hidden().accessibilityHidden(true)
            // ── Dual-pane toggle (no menu duplicate) ──────────────────────
            Button("") { toggleDualPane() }
                .keyboardShortcut("d", modifiers: [.command, .option]).hidden().accessibilityHidden(true)
            // ── Finder standards (hidden only where no menu duplicate exists) ──
            // NOTE: New Folder, Trash (⌘⌫ via File menu → notification), Hidden
            // toggle, Refresh, Back/Forward/Up, Go-to-Folder and Get Info are
            // handled by FinderFlowCommands menu shortcuts → NotificationCenter
            // → onReceive above. Duplicating them here as hidden buttons would
            // double-fire (e.g. toggle twice = no-op, go-back twice = skip a
            // folder, two Trash calls).
            // Copy path of selection (Finder: ⌥⌘C) — no menu equivalent.
            Button("") { guard !isEditingText() else { return }; copySelectedPath() }
                .keyboardShortcut("c", modifiers: [.command, .option]).hidden().accessibilityHidden(true)
            // ── Select All (Finder: ⌘A) — no menu equivalent here. ──────
            Button("") {
                guard !isEditingText() else { return }
                selectedIDs = Set(displayFiles.map(\.id))
            }.keyboardShortcut("a", modifiers: .command).hidden().accessibilityHidden(true)
            // ── Duplicate selection (Finder: ⌘D) — no menu equivalent. ───
            Button("") {
                guard !isEditingText() else { return }
                let sel = displayFiles.filter { selectedIDs.contains($0.id) }
                if !sel.isEmpty { fileOps.duplicate(sel.map(\.url), reload: reload) }
            }.keyboardShortcut("d", modifiers: .command).hidden().accessibilityHidden(true)
            // ── Backspace exits the folder (go up) — no menu equivalent.
            // Primary path is BackspaceUpNav (AppKit local monitor, same
            // .ffGoUp notification): the hidden Button below is a fallback
            // for contexts the monitor doesn't cover. No double-fire risk —
            // the monitor swallows the event when it navigates.
            // Guarded: while renaming or typing in search/path fields
            // Backspace must edit text, not navigate.
            Button("") { guard !isEditingText() else { return }; goUp() }
                .keyboardShortcut(.delete, modifiers: []).hidden().accessibilityHidden(true)
            // ── Escape clears selection (Finder). No-op while typing (inline
            // rename / search / path bar own Escape via onExitCommand) and
            // while a sheet is up (its Cancel already claims Escape).
            Button("") {
                guard !isEditingText() else { return }
                guard !showFirstRun, !showGoToFolder, !showBatchRename,
                      !showDiscordSheet, !showAIOrganizer, errorMsg == nil else { return }
                selectedIDs.removeAll()
                secondaryIDs.removeAll()
            }
            .keyboardShortcut(.escape, modifiers: []).hidden().accessibilityHidden(true)
            // Quick Look on selection is handled in List/Icons via Space.
        }
    }

    // MARK: - Navigation helpers (history-aware)

    private func goBack() {
        guard let prev = navHistory.back() else { return }
        isHistoryNav = true
        currentPath = prev
    }

    private func goForward() {
        guard let next = navHistory.forward() else { return }
        isHistoryNav = true
        currentPath = next
    }

    private func goUp() {
        let p = currentPath.deletingLastPathComponent()
        if p != currentPath { currentPath = p }
    }

    // MARK: - Browser tabs

    private var activeTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == id })
    }

    private func initTabsIfNeeded() {
        // Tabovi su vec postavljeni u init-u (prvi frejm ih ima); ovo je
        // sigurnosna mreza + sinhronizacija currentPath na aktivni tab
        // (restore iz prethodne sesije moze da se razlikuje od Home).
        if tabs.isEmpty {
            let initial = BrowserTabsStore.initial()
            tabs = initial.tabs
            activeTabID = initial.activeID
        }
        if let idx = activeTabIndex, !ffSamePath(currentPath, tabs[idx].path) {
            currentPath = tabs[idx].path
        }
        // Upisi pocetno stanje da restore radi i ako korisnik samo ugasi app.
        saveTabs()
    }

    private func saveTabs() {
        guard !tabs.isEmpty else { return }
        let idx = activeTabIndex ?? 0
        BrowserTabsStore.save(paths: tabs.map(\.path), active: idx)
    }

    /// Navigacija upisuje putanju nazad u aktivni tab (bez istorije tabova v1).
    private func syncActiveTabPath(_ path: URL) {
        guard let idx = activeTabIndex, !ffSamePath(tabs[idx].path, path) else { return }
        tabs[idx].path = path
        saveTabs()
    }

    private func selectTab(_ id: UUID) {
        guard id != activeTabID,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        // Search pripada starom folderu — ocisti pre navigacije da rezultati
        // ne trepere na novom tabu.
        if !searchEngine.query.isEmpty {
            searchEngine.query = ""
            searchEngine.cancelSearch()
        }
        activeTabID = id
        saveTabs()
        if !ffSamePath(currentPath, tab.path) {
            currentPath = tab.path
        } else {
            reload()
        }
    }

    private func newTab(path: URL? = nil) {
        let target = path ?? currentPath
        let tab = BrowserTab(path: target)
        tabs.append(tab)
        activeTabID = tab.id
        saveTabs()
        if !searchEngine.query.isEmpty {
            searchEngine.query = ""
            searchEngine.cancelSearch()
        }
        if !ffSamePath(currentPath, target) {
            currentPath = target
        } else {
            reload()
        }
    }

    private func openInNewTab(_ url: URL) {
        guard FileItem.isBrowsableFolder(url) else { return }
        newTab(path: url)
    }

    private func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let copy = BrowserTab(path: tab.path)
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs.insert(copy, at: idx + 1)
        } else {
            tabs.append(copy)
        }
        activeTabID = copy.id
        saveTabs()
        if !ffSamePath(currentPath, copy.path) {
            currentPath = copy.path
        }
    }

    private func closeTab(_ id: UUID) {
        guard tabs.count > 1,
              let idx = tabs.firstIndex(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        let wasActive = (id == activeTabID)
        tabs.remove(at: idx)
        if wasActive {
            let next = tabs[min(idx, tabs.count - 1)]
            activeTabID = next.id
            saveTabs()
            if !ffSamePath(currentPath, next.path) {
                currentPath = next.path
            } else {
                reload()
            }
        } else {
            saveTabs()
        }
    }

    private func closeOtherTabs(keeping id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tabs = [tab]
        activeTabID = tab.id
        saveTabs()
        if !ffSamePath(currentPath, tab.path) {
            currentPath = tab.path
        }
    }

    private func cycleTab(forward: Bool) {
        guard tabs.count > 1 else { return }
        let idx = activeTabIndex ?? 0
        let next = forward
            ? tabs[(idx + 1) % tabs.count]
            : tabs[(idx - 1 + tabs.count) % tabs.count]
        selectTab(next.id)
    }

    private func openSelected() {
        guard let id = selectedIDs.first,
              let item = displayFiles.first(where: { $0.id == id }) else { return }
        navigateItem(item)
    }

    private func trashSelected() {
        let urls = displayFiles.filter { selectedIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        // Selection is cleared by the reload after a successful trash — clearing
        // it first meant a failed operation silently dropped the selection.
        fileOps.trash(urls, reload: reload)
    }

    /// SelectionActionBar rename: ListView does inline rename via
    /// pendingRenameURL; Icons/Columns never consumed that binding, so the
    /// pencil was a silent no-op there. Route by view mode.
    private func renameRequest(_ item: FileItem) {
        if viewMode == .list {
            pendingRenameURL = item.url
        } else {
            FileRenamePrompt.rename(item, fileOps: fileOps, reload: reload)
        }
    }

    // MARK: - Search query → local-rank pipeline

    /// Local fuzzy rank is debounced (120 ms) and only used for `.thisFolder`
    /// — other scopes go through SearchEngine (Spotlight / recursive walk).
    private func handleSearchQueryChange(_ q: String) {
        if q.isEmpty {
            localRankWork?.cancel(); localRankWork = nil
            localSearchGen &+= 1
            localSearchFiles = []
            localSearchKey = ""
            maybeStartFolderSizing()
        } else {
            // Pretraga preuzima primarni prikaz — otkaži run da ne troši
            // I/O u pozadini; novi kreće kad se pretraga obriše.
            folderSizeRuns.next()
            folderSizingActive = false
            guard searchEngine.selectedScope == .thisFolder else {
                // Spotlight/recursive scope owns the results — drop stale local rank.
                localRankWork?.cancel(); localRankWork = nil
                localSearchGen &+= 1
                localSearchFiles = []
                localSearchKey = ""
                return
            }
            scheduleLocalRank(query: q, files: rawFiles, identity: filesIdentity)
        }
    }

    private func copySelectedPath() {
        let sel = displayFiles.filter { selectedIDs.contains($0.id) }
        if sel.isEmpty {
            fileOps.copyPath(currentPath.path)
        } else {
            fileOps.copyPath(sel.map(\.url.path).joined(separator: "\n"))
        }
    }

    private func showInfoForSelection() {
        let urls = displayFiles.filter { selectedIDs.contains($0.id) }.map(\.url)
        let targets = urls.isEmpty ? [currentPath] : urls
        showGetInfoInFinder(targets)
    }

    /// 1-klik Mail attach: selekcija → novi Mail compose sa attachmentima.
    /// Shortcut: ⇧⌘M (File meni). Prazna selekcija = vidljiv toast, ne tihi no-op.
    private func sendSelectedViaMail() {
        let urls = displayFiles.filter { selectedIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else {
            showToast(ActionFeedback(icon: "exclamationmark.circle",
                                     message: "Select at least one file first"))
            return
        }
        fileOps.shareViaMail(urls)
    }

    /// 1-klik Quick Link: 24h link sa laptopa, bez dijaloga — odmah kopiran + toast.
    /// Shortcut: ⌥⌘L (File meni). Više fajlova/foldera → jedan .zip (limiti
    /// SecureShareLimits); detaljna provera veličine tek u pozadini uz toast.
    private func quickLinkSelected() {
        let urls = displayFiles.filter { selectedIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else {
            showToast(ActionFeedback(icon: "exclamationmark.circle",
                                     message: "Select at least one file or folder first"))
            return
        }
        guard urls.count <= SecureShareLimits.maxItems else {
            showToast(ActionFeedback(icon: "exclamationmark.circle",
                                     message: "Select up to \(SecureShareLimits.maxItems) items — split it into smaller shares"))
            return
        }
        guard SecureShareManager.canQuickLink(urls) else {
            showToast(ActionFeedback(icon: "exclamationmark.circle",
                                     message: "Links, packages and online-only files can't be shared."))
            return
        }
        Task { await SecureShareManager.shared.quickLink(for: urls) }
    }

    /// AI Organizer: opens the sheet for THIS folder's listing (rawFiles —
    /// never search results, which may span folders) or the selected files;
    /// the plan is reviewed there and applied under one Undo.
    private func aiOrganizeCurrentFolder() {
        showAIOrganizer = true
    }

    // MARK: - Dual-pane + batch rename

    private var primarySelectedItems: [FileItem] {
        // Memoized: body reads this 3× per eval (toolbar callback, visibility
        // check, SelectionActionBar) and each read filters the whole folder.
        // The key is O(selection), NOT O(folder): hashing the whole list here
        // cost more than the filter it was memoizing (10k Hasher rounds per
        // click). Raw-file identity is folded in via `filesIdentity`, which
        // bumps only when the listing actually changes.
        let list = displayFiles
        // Display-list diskriminator: search/tag rezultati menjaju `list` dok
        // se filesIdentity ne pomeri — bez ovoga memo ostaje na starom folderu.
        // O(1): count + endpoints + query/tag.
        let first = list.first?.id ?? "-"
        let last = list.last?.id ?? "-"
        let key = "\(filesIdentity)#\(tagFilesIdentity)#\(searchEngine.query)#\(activeTagFilter ?? "-")#\(list.count)#\(first)#\(last)#\(selectedIDs.count)#\(selectionFingerprint)"
        if key == memo.selectedKey {
            // XOR kolizija (A^B==C^D) bi vratila pogresnu selekciju za bar i
            // preview — verifikuj sadrzaj pre return-a, self-heals sledecim citanjem.
            let cached = memo.selectedItems
            if cached.count == selectedIDs.count && cached.allSatisfy({ selectedIDs.contains($0.id) }) {
                return cached
            }
        }
        let sel = list.filter { selectedIDs.contains($0.id) }
        memo.selectedKey = key
        memo.selectedItems = sel
        return sel
    }

    /// O(selection) fingerprint — order-independent, no sorting. Two different
    /// same-count selections collide only if their hashes XOR equally
    /// (practically never; worst case one stale memo hit, self-heals next read
    /// because `selectedItems` content is compared by the caller paths that
    /// matter — visibility check + bar render both re-derive from this).
    private var selectionFingerprint: Int {
        selectedIDs.reduce(0) { $0 ^ $1.hashValue }
    }

    private var secondarySelectedURLs: [URL] {
        secondaryFiles.filter { secondaryIDs.contains($0.id) }.map(\.url)
    }

    private func reloadBoth() {
        reload()
        if isDualPane { reloadSecondary() }
    }

    private func reloadSecondary() {
        secondaryGeneration &+= 1
        let gen = secondaryGeneration
        let dir = secondaryPath
        let hidden = showHidden
        let field = sortField
        let asc = sortAscending
        let fold = folderOrder
        if let snapshot = DirectoryCache.shared.cachedItems(for: dir, showHidden: hidden) {
            // Veliki folder u drugom panelu: isto kao primarni — skupi
            // string-sort van maina i bez brisanja starog prikaza (bez
            // flasha praznog panela + duplog diffa); jeftini sortovi idu
            // odmah na main kao mali folderi.
            if snapshot.count > largeFolderThreshold && !isCheapSortField(field) {
                secondaryLoading = true
                secondaryError = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    let sorted = sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold)
                    let res = loadFreshItems(at: dir, showHidden: hidden)
                    let fresh = sortedItems(res.items,
                                            by: field, ascending: asc, folderOrder: fold)
                    let final = (fresh != sorted) ? fresh : sorted
                    DispatchQueue.main.async {
                        // dir check is belt-and-braces: every secondaryPath
                        // mutation goes through reloadSecondary (bumps gen),
                        // but a stale load must never paint another folder.
                        guard gen == secondaryGeneration, dir == secondaryPath else { return }
                        secondaryFiles = final
                        secondaryLoading = false
                        secondaryError = res.error
                        maybeStartFolderSizing()
                    }
                }
                return
            }
            secondaryFiles = sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold)
            secondaryLoading = false
            secondaryError = nil
            maybeStartFolderSizing()
            DispatchQueue.global(qos: .userInitiated).async {
                let res = loadFreshItems(at: dir, showHidden: hidden)
                let fresh = sortedItems(res.items,
                                        by: field, ascending: asc, folderOrder: fold)
                DispatchQueue.main.async {
                    guard gen == secondaryGeneration, dir == secondaryPath else { return }
                    // Same-list guard: re-publishing an identical array still
                    // rebuilds every visible row (SwiftUI diff by identity).
                    if fresh != secondaryFiles {
                        secondaryFiles = fresh
                        maybeStartFolderSizing()
                    }
                    secondaryError = res.error
                }
            }
            return
        }
        if secondaryFiles.isEmpty { secondaryLoading = true }
        secondaryError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let res = loadItems(at: dir, showHidden: hidden)
            let items = sortedItems(res.items,
                                    by: field, ascending: asc, folderOrder: fold)
            DispatchQueue.main.async {
                guard gen == secondaryGeneration, dir == secondaryPath else { return }
                secondaryFiles = items
                secondaryLoading = false
                secondaryError = res.error
                maybeStartFolderSizing()
            }
        }
    }

    private func toggleDualPane() {
        if !isDualPane {
            // Opening: avoid both panes on the same folder when possible.
            if secondaryPath == currentPath {
                let parent = currentPath.deletingLastPathComponent()
                secondaryPath = (parent != currentPath) ? parent : FileManager.default.homeDirectoryForCurrentUser
            }
            // onChange(of: isDualPane) below reloads the secondary pane —
            // no explicit reloadSecondary() here (that double-fired).
            isDualPane = true
        } else {
            isDualPane = false
        }
    }

    private func swapPanes() {
        let left = currentPath
        // No isHistoryNav: the swap IS a navigation — letting onChange push
        // keeps Back/Forward coherent (Back returns to the pre-swap folder;
        // the old flag left history pointing at it, skipping a step).
        currentPath = secondaryPath
        secondaryPath = left
        secondaryIDs = []
        // No explicit reloadSecondary(): SecondaryPane.onChange(of: path)
        // already calls onReload() when secondaryPath changes — the old
        // explicit call double-reloaded (second run was generation-discarded
        // wasted work).
    }

    private func copyPrimaryToSecondary() {
        let urls = primarySelectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        fileOps.copy(urls)
        fileOps.paste(to: secondaryPath, reload: reloadBoth)
    }

    private func movePrimaryToSecondary() {
        let urls = primarySelectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        fileOps.cut(urls)
        fileOps.paste(to: secondaryPath, reload: reloadBoth)
    }

    private func copySecondaryToPrimary() {
        let urls = secondarySelectedURLs
        guard !urls.isEmpty else { return }
        fileOps.copy(urls)
        fileOps.paste(to: currentPath, reload: reloadBoth)
    }

    private func moveSecondaryToPrimary() {
        let urls = secondarySelectedURLs
        guard !urls.isEmpty else { return }
        fileOps.cut(urls)
        fileOps.paste(to: currentPath, reload: reloadBoth)
    }

    private func openBatchRename(_ items: [FileItem]) {
        guard items.count > 1 else { return }
        batchTargets = items
        showBatchRename = true
    }

    private func openDiscordShare(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        discordTargets = items
        showDiscordSheet = true
    }

    // MARK: - Pre-named creation dialogs

    // Show a name dialog BEFORE creating, so the item appears with the correct name immediately.
    // Respects the active destination (selected folder or currentPath).

    func promptAndCreateFolder() {
        let dest = activeDestination
        let alert = NSAlert()
        alert.messageText     = "New Folder in \"\(dest.lastPathComponent)\""
        alert.informativeText = "Enter a name for the new folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = "New Folder"; tf.selectText(nil)
        alert.accessoryView = tf; alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        folderService.createFolder(at: dest, name: name)
    }

    func promptAndCreateFile() {
        let dest = activeDestination
        let alert = NSAlert()
        alert.messageText     = "New File in \"\(dest.lastPathComponent)\""
        alert.informativeText = "Enter a name for the new file (include extension, e.g. notes.txt):"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = "untitled.txt"; tf.selectText(nil)
        alert.accessoryView = tf; alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        folderService.createFile(at: dest, name: name)
    }

    // MARK: - Permanent delete with confirmation

    func confirmAndDeleteSelected() {
        let items = displayFiles.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else { return }

        let names = items.map(\.name)
        let label = items.count == 1 ? "\"\(names[0])\"" : "\(items.count) items"

        let alert = NSAlert()
        alert.messageText     = "Permanently delete \(label)?"
        alert.informativeText = "This cannot be undone. The \(items.count == 1 ? "item" : "items") will be permanently deleted and cannot be recovered from Trash."
        alert.alertStyle      = .warning
        let deleteBtn = alert.addButton(withTitle: "Delete Permanently")
        deleteBtn.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selectedIDs = []
        fileOps.permanentlyDelete(items.map(\.url), reload: reload)
    }

    // MARK: - File browser

    // True while a search query or tag filter is replacing the folder listing.
    private var isSearchActive: Bool {
        !searchEngine.query.isEmpty || activeTagFilter != nil
    }

    // A text search shows one flat, relevance-ranked list instead of date/kind groups.
    private var browserGroupBy: GroupBy {
        searchEngine.query.isEmpty ? groupBy : .none
    }

    @ViewBuilder
    private var browserArea: some View {
        if isDualPane {
            HSplitView {
                primaryPane
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                PaneTransferBar(
                    primaryCount: selectedIDs.count,
                    secondaryCount: secondaryIDs.count,
                    onCopyToSecondary: copyPrimaryToSecondary,
                    onMoveToSecondary: movePrimaryToSecondary,
                    onCopyToPrimary: copySecondaryToPrimary,
                    onMoveToPrimary: moveSecondaryToPrimary,
                    // Drop files onto the strip → move to the OTHER pane
                    // (the one the drag did not come from, by volume rule).
                    onDropURLs: { urls in
                        let toSecondary = urls.allSatisfy {
                            $0.deletingLastPathComponent().resolvingSymlinksInPath().path
                                != secondaryPath.resolvingSymlinksInPath().path
                        }
                        let dest = toSecondary ? secondaryPath : currentPath
                        fileOps.importURLs(urls, to: dest,
                                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                                           reload: reloadBoth)
                    }
                )
                VStack(spacing: 0) {
                    SecondaryPaneHeader(
                        path: $secondaryPath,
                        onSwap: swapPanes,
                        onClose: { isDualPane = false }
                    )
                    SecondaryPane(
                        path: $secondaryPath,
                        files: secondaryFiles,
                        isLoading: secondaryLoading,
                        loadError: secondaryError,
                        selectedIDs: $secondaryIDs,
                        pendingRenameURL: $secondaryPendingRenameURL,
                        viewMode: viewMode,
                        sortField: sortFieldBinding,
                        sortAscending: $sortAscending,
                        groupBy: groupBy,
                        folderOrder: folderOrder,
                        showHidden: showHidden,
                        fileOps: fileOps,
                        favorites: favorites,
                        onOpenFile: { navigateItem($0) },
                        onReload: reloadSecondary,
                        onBatchRename: openBatchRename,
                        onSendToDiscord: openDiscordShare,
                        sizesVersion: folderSizesVersion,
                        sizingActive: folderSizingActive
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                // Reveal u desnom pane-u: poseban lanac da splitWithChanges ne
                // probije type-checker budžet (vidi komentar uz rawFiles).
                .onChange(of: secondaryFiles) { _, newFiles in applyPendingSecondarySelection(newFiles) }
            }
        } else {
            primaryPane
        }
    }

    /// Left (main) pane with the optional right preview panel.
    @ViewBuilder
    private var primaryPane: some View {
        PreviewSplit(showsPreview: showPreview && viewMode != .columns) {
            VStack(spacing: 0) {
                // Neuspesno citanje se vise ne prikazuje kao "prazan folder":
                // prazno + greska -> ekran sa razlogom i akcijama; fajlovi uz
                // gresku refresha -> lista + traka upozorenja.
                if let err = folderError, displayFiles.isEmpty, !isLoading {
                    FolderErrorView(url: currentPath, error: err,
                                    onRetry: reload,
                                    onGoHome: { currentPath = FileManager.default.homeDirectoryForCurrentUser })
                } else {
                    if let err = folderError, !displayFiles.isEmpty {
                        FolderErrorBanner(error: err, onRetry: reload)
                    }
                    fileBrowser
                        // View-mode crossfade (⌘1/2/3): opacity-only, container
                        // level — per-row animation would kill the 8k-row perf
                        // work. .id() makes the swap explicit so the transition
                        // runs; scroll reset on mode switch matches Finder.
                        .id(viewMode)
                        .transition(.opacity)
                        // (Bez „dip" animacije pri promjeni foldera: dvije
                        // promjene stanja + 120 ms animirane prozirnosti preko
                        // liste koja se baš tada mijenja koštale su ~115 ms
                        // glavne niti po prelazu i vidljivo treptanje.)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: viewMode)
        } preview: {
            // Handle, limits, the remembered width and the show/hide
            // transition all live in PreviewSplit (NavigationUI.swift).
            FilePreviewPanel(item: selectedItem, fileOps: fileOps, onReload: reload,
                             showHidden: showHidden,
                             currentFolder: currentPath,
                             onOpenFile: navigateItem,
                             onEnterFolder: { currentPath = $0 },
                             onRevealFile: { revealFileInBrowser($0) })
        }
    }

    @ViewBuilder
    private var fileBrowser: some View {
        switch viewMode {
        case .list:
            ListView(
                files:            displayFiles,
                selectedIDs:      $selectedIDs,
                pendingRenameURL: $pendingRenameURL,
                currentPath:      currentPath,
                sortField:        sortFieldBinding,
                sortAscending:    $sortAscending,
                groupBy:          browserGroupBy,
                onNavigate:       navigateItem,
                onBrowseInto:     { currentPath = $0 },
                onReload:         reload,
                fileOps:          fileOps,
                favorites:        favorites,
                isSearching:      isSearchActive,
                isLoading:        (isLoading || tagService.isSearchingTags) && displayFiles.isEmpty,
                onBatchRename:    openBatchRename,
                filesIdentity:    isSearchActive ? searchIdentity : filesIdentity,
                onSendToDiscord:  openDiscordShare,
                // Search results ride the grouped-list path (one row view per
                // item) even with Group By = None: the Table hosts every cell
                // in its own NSHostingView, so swapping in thousands of result
                // rows rebuilt the whole table and froze the keystroke.
                showsFlatList:    !searchEngine.query.isEmpty,
                sizingActive:     folderSizingActive
            )
        case .icons:
            IconsView(
                files:       displayFiles,
                selectedIDs: $selectedIDs,
                currentPath: currentPath,
                groupBy:     browserGroupBy,
                onNavigate:  navigateItem,
                onBrowseInto: { currentPath = $0 },
                onReload:    reload,
                fileOps:     fileOps,
                favorites:   favorites,
                isSearching: isSearchActive,
                isLoading:   isLoading && displayFiles.isEmpty,
                onBatchRename: openBatchRename,
                filesIdentity: isSearchActive ? searchIdentity : filesIdentity,
                onSendToDiscord: openDiscordShare,
                sortAscending: sortAscending,
                onCreateFile: { NotificationCenter.default.post(name: .createNewFile, object: nil) },
                arrowsEnabled: !isDualPane
            )
        case .columns:
            ColumnsView(
                currentPath:    $currentPath,
                showHidden:     showHidden,
                showColumnTree: showColumnTree,
                groupBy:        groupBy,
                sortField:      sortField,
                sortAscending:  sortAscending,
                folderOrder:    folderOrder,
                fileOps:        fileOps,
                favorites:      favorites,
                searchResults:  displayFiles,
                isSearchActive: !searchEngine.query.isEmpty || activeTagFilter != nil,
                isLoading:      isLoading && displayFiles.isEmpty,
                onOpen:         navigate,
                selectedIDs:    $selectedIDs,
                showFolderSizes: showFolderSizes,
                sizesVersion:   folderSizesVersion,
                sizingActive:   folderSizingActive,
                arrowsEnabled:  !isDualPane
            )
        }
    }

    // Tags used by items in the current folder — shown in the sidebar Tags section.
    // Only shows tags that actually exist here, so the sidebar stays clean.
    // When a tag is tapped, TagService searches Mac-wide via Spotlight.
    // Cached: recomputed on rawFiles change (see onChange below), not per render.
    private var usedTagNames: [String] { cachedUsedTagNames }

    @State private var usedTagNamesGeneration: UInt = 0

    /// Set+flatMap+sort over all files — for an 8k folder this is measurable
    /// on the main thread, so compute off-main and publish when done.
    private func refreshUsedTagNamesAsync(from files: [FileItem]) {
        usedTagNamesGeneration &+= 1
        let gen = usedTagNamesGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let names = Array(Set(files.flatMap(\.tagNames))).sorted()
            DispatchQueue.main.async {
                guard gen == self.usedTagNamesGeneration else { return }
                self.cachedUsedTagNames = names
            }
        }
    }

    // MARK: - Display list

    private var displayFiles: [FileItem] {
        // Tag filter: Mac-wide Spotlight matches UNION current-folder items carrying
        // the color. The local pass is what guarantees correctness — Spotlight only
        // finds files with a real kMDItemUserTags value, while the local match also
        // catches files that only have the legacy color label (kMDItemFSLabel), which
        // Spotlight cannot search. So tagged items in the folder you're viewing always
        // appear, regardless of how they were tagged.
        if let tag = activeTagFilter {
            let merged = mergedTagResults(for: tag)
            guard !searchEngine.query.isEmpty else { return merged }
            // Memoized in DisplayMemoCache (reference type — safe to write
            // during body): rankedSearchItems on every body eval was a full
            // fuzzy rank + sort on the main thread for each click/keystroke.
            let key = "\(tag)#\(searchEngine.query)#\(tagFilesIdentity)#\(filesIdentity)"
            if key != memo.tagKey {
                memo.tagKey = key
                memo.tagFiles = rankedSearchItems(merged, query: searchEngine.query)
            }
            return memo.tagFiles
        }
        // Search results are pre-ranked into searchDisplayFiles to avoid
        // calling FileItem.load(from:) on every SwiftUI re-render.
        // While fresh results are still being ranked, keep the instant list (or
        // the previous results) instead of flashing an empty one: every swap
        // rebuilds the visible rows.
        if !searchEngine.results.isEmpty, !searchDisplayFiles.isEmpty { return searchDisplayFiles }
        if !searchEngine.query.isEmpty {
            // Rank je prethodno rađen OVDE, sinhrono na mainu, na svaki body
            // eval (svaki klik/kucanje) — zamrzavanje na velikim folderima.
            // Sada se rankira u pozadini (scheduleLocalRank na query/listing
            // promenu), a ovde se samo čita gotovo. Dok rank putuje, prikazuje
            // se prethodni rank (ili ceo folder na prvom kucanju) — jedan
            // dodatni render umesto blokade.
            let key = "\(searchEngine.query)#\(filesIdentity)"
            if key == localSearchKey { return localSearchFiles }
            return localSearchFiles.isEmpty ? rawFiles : localSearchFiles
        }
        return rawFiles
    }

    /// Rankira `files` za `query` u pozadini i objavljuje pod `key`.
    /// Debounced (120 ms) + stale guard preko generacije: brzo kucanje ne
    /// pokreće rank po svakom znaku, a stari rezultat nikad ne pregazi sveži.
    private func scheduleLocalRank(query: String, files: [FileItem], identity: UInt) {
        localRankWork?.cancel()
        localSearchGen &+= 1
        let gen = localSearchGen
        let key = "\(query)#\(identity)"
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .userInitiated).async {
                let ranked = rankedSearchItems(files, query: query)
                DispatchQueue.main.async {
                    guard gen == localSearchGen else { return }
                    localSearchFiles = ranked
                    localSearchKey = key
                    searchIdentity &+= 1
                }
            }
        }
        localRankWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Sort na promenu prefs: mali folderi sinhrono (instant), veliki (>2k)
    /// u pozadini da main ne zamrzne na `localizedCompare` lavini.
    private func applySortPrefsChange() {
        let field = sortField; let asc = sortAscending; let fold = folderOrder
        guard rawFiles.count > largeFolderThreshold else {
            rawFiles = sortedItems(rawFiles, by: field, ascending: asc, folderOrder: fold)
            filesIdentity &+= 1
            return
        }
        largeSortGen &+= 1
        let gen = largeSortGen
        let files = rawFiles
        DispatchQueue.global(qos: .userInitiated).async {
            let sorted = sortedItems(files, by: field, ascending: asc, folderOrder: fold)
            DispatchQueue.main.async {
                guard gen == largeSortGen else { return }
                rawFiles = sorted
                filesIdentity &+= 1
            }
        }
    }

    // MARK: - Folder sizes (opt-in disk-hunter)

    /// Starts (or restarts) the background sizing run for the visible listings.
    /// Every call cancels the previous run via the run-state generation, so
    /// navigation, reloads and toggles can never publish stale sizes.
    /// The primary pane is skipped while a search/tag filter is active (those
    /// modes don't show rawFiles, so sizing would be wasted I/O); the
    /// secondary pane has no search and is always covered when visible.
    /// In Columns tree mode the run additionally sizes the visible ancestor
    /// panes' children into the shared cache (nearest first, budgeted) — the
    /// panes themselves never walk disk, they attach via `folderSizesVersion`.
    /// Sizes land progressively (batched publishes); when sorting by Size the
    /// final re-sort happens once at the end instead of per batch.
    private func maybeStartFolderSizing() {
        let gen = folderSizeRuns.next()
        guard showFolderSizes else {
            folderSizingActive = false
            return
        }
        let path = currentPath
        let hidden = showHidden
        let columnsMode = viewMode == .columns
        let treeMode = showColumnTree
        let primaryBrowsable = searchEngine.query.isEmpty && activeTagFilter == nil
        let primaryTargets = primaryBrowsable
            ? rawFiles.filter { $0.isBrowsableFolder && $0.folderSize == nil }
            : []
        let secondaryTargets = isDualPane
            ? secondaryFiles.filter { $0.isBrowsableFolder && $0.folderSize == nil }
            : []
        // Visible ancestor panes (tree mode): the active folder itself is
        // covered by primaryTargets — these are its parents up to the root.
        // Computed from the path alone, no plumbing needed: ColumnsView builds
        // exactly this chain in tree mode.
        var extraDirs: [URL] = []
        if columnsMode, treeMode {
            var p = path.deletingLastPathComponent()
            while extraDirs.count < 24 {
                if p != path { extraDirs.append(p) }
                let up = p.deletingLastPathComponent()
                if up == p { break }
                p = up
            }
        }
        guard !primaryTargets.isEmpty || !secondaryTargets.isEmpty || !extraDirs.isEmpty else {
            folderSizingActive = false
            return
        }
        folderSizingActive = true
        // Veliki folderi: svaki publish rebuilda vidljivu listu (Table diff),
        // pa se progresivni flush razređuje da ne secka skrol dok traje.
        let flushInterval = rawFiles.count > largeFolderThreshold ? 1.5 : 0.4
        DispatchQueue.global(qos: .utility).async {
            let service = FolderSizeService.shared
            // Extra dirs resolve here (cheap non-recursive readdir): their
            // children are sized straight into the cache — no array owns them.
            // Nearest panes first with a hard budget so a tree rooted at "/"
            // can't turn one opt-in toggle into a full-disk crawl.
            var extraBudget = 150
            var allTargets = (primaryTargets + secondaryTargets).map { ($0.id, $0.url) }
            if !extraDirs.isEmpty {
                for dir in extraDirs {
                    guard folderSizeRuns.isCurrent(gen) else { return }
                    if extraBudget <= 0 { break }
                    let kids = FolderSizeService.browsableSubfolders(of: dir, includeHidden: hidden,
                                                                     budget: &extraBudget)
                    for u in kids {
                        guard folderSizeRuns.isCurrent(gen) else { return }
                        // Sam aktivni folder se nikad ne meri kao red (prikazuju
                        // se njegova deca) — walk nad njim bi bio čist trošak.
                        if u != path,
                           service.cachedSize(for: u) == nil,
                           !FileItem.isNotDownloaded(u) {
                            allTargets.append((u.path, u))
                        }
                    }
                }
            }
            guard !allTargets.isEmpty else {
                DispatchQueue.main.async {
                    guard folderSizeRuns.isCurrent(gen), path == currentPath else { return }
                    folderSizingActive = false
                }
                return
            }
            var pending: [String: Int64] = [:]
            pending.reserveCapacity(allTargets.count)
            // True when the batch holds freshly computed (never cached)
            // values. Only those bump folderSizesVersion — cache hits were
            // attachable by every view all along, so re-notifying for them
            // would just re-sort the secondary pane for nothing.
            var pendingHasFresh = false
            var lastFlush = Date()
            // Patch helper: replaces sized elements (struct copy) in both
            // panes and bumps identities so Table diff + group memos
            // invalidate. Columns panes refresh from the cache via
            // folderSizesVersion (no disk walk on their side).
            func publish(_ batch: [String: Int64], fresh: Bool) {
                guard !batch.isEmpty else { return }
                DispatchQueue.main.async {
                    guard folderSizeRuns.isCurrent(gen), path == currentPath else { return }
                    var changed = false
                    // Odvojene zastavice po pane-u: dodela @State bez promene
                    // i dalje košta re-render, pa se prazan pane preskače.
                    if !primaryTargets.isEmpty {
                        var files = rawFiles
                        var paneChanged = false
                        for (i, item) in files.enumerated() {
                            if let bytes = batch[item.id] {
                                files[i] = item.withFolderSize(bytes)
                                paneChanged = true
                            }
                        }
                        if paneChanged { rawFiles = files; changed = true }
                    }
                    if !secondaryTargets.isEmpty {
                        var files = secondaryFiles
                        var paneChanged = false
                        for (i, item) in files.enumerated() {
                            if let bytes = batch[item.id] {
                                files[i] = item.withFolderSize(bytes)
                                paneChanged = true
                            }
                        }
                        if paneChanged { secondaryFiles = files; changed = true }
                    }
                    if changed { filesIdentity &+= 1 }
                    if fresh { folderSizesVersion &+= 1 }
                }
            }
            for (_, url) in allTargets {
                guard folderSizeRuns.isCurrent(gen) else { return }
                if let hit = service.cachedSize(for: url) {
                    pending[url.path] = hit
                } else if FileItem.isNotDownloaded(url) {
                    // Nikad ne skidati cloud sadržaj zbog merenja veličine.
                    continue
                } else if let bytes = FolderSizeService.computeSize(
                    of: url, includeHidden: hidden,
                    isCancelled: { !folderSizeRuns.isCurrent(gen) }) {
                    service.store(bytes, for: url)
                    pending[url.path] = bytes
                    pendingHasFresh = true
                }
                if !pending.isEmpty, Date().timeIntervalSince(lastFlush) > flushInterval {
                    publish(pending, fresh: pendingHasFresh)
                    pending = [:]
                    pendingHasFresh = false
                    lastFlush = Date()
                }
            }
            let tail = pending
            let tailFresh = pendingHasFresh
            DispatchQueue.main.async {
                guard folderSizeRuns.isCurrent(gen), path == currentPath else { return }
                if !tail.isEmpty {
                    var changed = false
                    if !primaryTargets.isEmpty {
                        var files = rawFiles
                        var paneChanged = false
                        for (i, item) in files.enumerated() {
                            if let bytes = tail[item.id] {
                                files[i] = item.withFolderSize(bytes)
                                paneChanged = true
                            }
                        }
                        if paneChanged { rawFiles = files; changed = true }
                    }
                    if !secondaryTargets.isEmpty {
                        var files = secondaryFiles
                        var paneChanged = false
                        for (i, item) in files.enumerated() {
                            if let bytes = tail[item.id] {
                                files[i] = item.withFolderSize(bytes)
                                paneChanged = true
                            }
                        }
                        if paneChanged { secondaryFiles = files; changed = true }
                    }
                    if changed { filesIdentity &+= 1 }
                    if tailFresh { folderSizesVersion &+= 1 }
                }
                folderSizingActive = false
                // Konačan redosled tek kad su sve veličine tu — po batchu bi
                // velike foldere (>2k) re-sortiralo N puta uzastopno.
                if sortField == .size {
                    applySortPrefsChange()
                    if isDualPane {
                        secondaryFiles = sortedItems(secondaryFiles, by: sortField,
                                                     ascending: sortAscending,
                                                     folderOrder: folderOrder)
                    }
                }
            }
        }
    }

    /// Removes computed sizes from the current listings (pref toggled off).
    /// Cheap O(n) maps, single publish each. The version bumps only when
    /// something was actually stripped (otherwise the secondary pane would
    /// re-sort and columns panes would re-scan for nothing).
    private func stripFolderSizes() {
        var stripped = false
        if rawFiles.contains(where: { $0.folderSize != nil }) {
            rawFiles = rawFiles.map { $0.folderSize == nil ? $0 : $0.withFolderSize(nil) }
            filesIdentity &+= 1
            stripped = true
        }
        if secondaryFiles.contains(where: { $0.folderSize != nil }) {
            secondaryFiles = secondaryFiles.map { $0.folderSize == nil ? $0 : $0.withFolderSize(nil) }
            stripped = true
        }
        if stripped { folderSizesVersion &+= 1 }
    }

    // Spotlight (Mac-wide) results unioned with current-folder color matches, deduped
    // by path and sorted. The local match covers items that only carry the legacy
    // color label, which Spotlight can't find.
    // Memoized per (tag, sort prefs, listing identity) — body re-evaluates
    // constantly. Tag-result lists bump their identities on every publish, so
    // O(1) keys stay correct without hashing either folder.
    private func mergedTagResults(for tag: String) -> [FileItem] {
        let key = "\(tag)#\(sortFieldRaw)#\(sortAscending)#\(folderOrderRaw)#\(tagFilesIdentity)#\(filesIdentity)"
        if key == memo.tagKey { return memo.tagFiles }
        let colorNumber = FileItem.colorNameToLabel[tag.lowercased()]
        let local = rawFiles.filter { item in
            item.tagNames.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
                || (colorNumber != nil && colorNumber == item.labelNumber)
        }
        var seen = Set<String>()
        var merged: [FileItem] = []
        merged.reserveCapacity(tagDisplayFiles.count + local.count)
        for f in tagDisplayFiles + local where seen.insert(f.url.path).inserted {
            merged.append(f)
        }
        let sorted = sortedItems(merged, by: sortField, ascending: sortAscending, folderOrder: folderOrder)
        memo.tagKey = key
        memo.tagFiles = sorted
        return sorted
    }

    // MARK: - Persisted preference bindings

    private var viewModeBinding: Binding<ViewMode> {
        Binding(get: { viewMode }, set: { viewModeRaw = $0.rawValue })
    }
    private var sortFieldBinding: Binding<SortField> {
        Binding(get: { sortField }, set: { sortFieldRaw = $0.rawValue })
    }
    private var groupByBinding: Binding<GroupBy> {
        Binding(get: { groupBy }, set: { groupByRaw = $0.rawValue })
    }
    private var folderOrderBinding: Binding<FolderOrder> {
        Binding(get: { folderOrder }, set: { folderOrderRaw = $0.rawValue })
    }

    // MARK: - Helpers

    /// Fast path when the row's `FileItem` is already loaded — no extra disk stat.
    private func navigateItem(_ item: FileItem) {
        if item.isBrowsableFolder {
            currentPath = item.url
            return
        }
        // Google Docs: .gdoc/.gsheet stub (Drive for Desktop) i exportovani Docs
        // iz našeg mirrora žive na webu — otvori original (⌥ otvara lokalnu kopiju).
        if GoogleDocsOpener.openIfGoogleDoc(item.url) { return }
        let ext = item.fileExtension
        if ext == "md" {
            MarkdownWindowManager.shared.open(item.url)
            return
        }
        // Known text extensions skip the 8KB disk sniff.
        if !ext.isEmpty && TextFileDetector.knownTextExtensions.contains(ext) {
            EditorWindowManager.shared.open(item.url)
            return
        }
        if TextFileDetector.knownTextFilenames.contains(item.name.lowercased()) {
            EditorWindowManager.shared.open(item.url)
            return
        }
        if TextFileDetector.isEditableText(item.url) {
            EditorWindowManager.shared.open(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func navigate(_ url: URL) {
        if FileItem.isBrowsableFolder(url) {
            currentPath = url
        } else if GoogleDocsOpener.openIfGoogleDoc(url) {
            return
        } else if url.pathExtension.lowercased() == "md" {
            MarkdownWindowManager.shared.open(url)
        } else if TextFileDetector.isEditableText(url) {
            EditorWindowManager.shared.open(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Workspace relations ("§10: klik na dokument odmah ga selektuje u
    /// lijevom file browseru"): jump the main pane to the file's parent and
    /// select the file there (pending-select survives the reload).
    private func revealFileInBrowser(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        pendingSelectURL = url
        pendingSelectDestination = parent
        if !ffSamePath(parent, currentPath) {
            currentPath = parent
        } else {
            reload()
        }
    }

    private func scrollTableView(toRow row: Int) {
        guard row >= 0 else { return }
        // Cached lookup: the AppKit table doesn't move within the window, but
        // the old code walked the entire NSView tree (thousands of SwiftUI
        // hosting views for a big folder) on every paste/create/select.
        // The holder lives on the non-mutating memo so this stays a plain func.
        if let tv = memo.cachedTableView { tv.scrollRowToVisible(row); return }
        func find(_ v: NSView) -> NSTableView? {
            if let tv = v as? NSTableView { return tv }
            return v.subviews.lazy.compactMap { find($0) }.first
        }
        if let tv = find(NSApp.keyWindow?.contentView ?? NSView()) {
            memo.cachedTableView = tv
            tv.scrollRowToVisible(row)
        }
    }

    // MARK: - Toast

    private func showToast(_ feedback: ActionFeedback) {
        let payload = ToastPayload(icon: feedback.icon, message: feedback.message,
                                   revealURLs: feedback.revealURLs,
                                   revealDestination: feedback.revealDestination)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastItem = payload
        }
        // Every toast gets its own timer here (see toastDismissWork); longer
        // messages stay up a little longer so they can be read.
        toastDismissWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                if toastItem?.id == payload.id { toastItem = nil }
            }
        }
        toastDismissWork = work
        let seconds = min(6, 2.5 + Double(max(0, feedback.message.count - 50)) * 0.04)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The engine publishes nil when an operation failed outright after its
    /// "Moving…"/"Copying…" toast went up — take that progress toast down.
    private func clearProgressToast() {
        guard toastItem?.icon == "hourglass" else { return }
        toastDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { toastItem = nil }
    }

    func reload() { _reload(then: nil) }

    private func _reload(then: (() -> Void)?) {
        reloadGeneration &+= 1
        let gen    = reloadGeneration
        let path   = currentPath
        let hidden = showHidden
        let field  = sortField
        let asc    = sortAscending
        let fold   = folderOrder
        // Stara greska se cisti odmah (ne ceka load) da ne treperi na novom sadrzaju.
        folderError = nil
        // Instant paint: if we've seen this folder, show the snapshot
        // immediately (re-sorted with current prefs — no disk I/O), then
        // revalidate in background. This is what makes Back/Forth feel instant.
        if let snapshot = DirectoryCache.shared.cachedItems(for: path, showHidden: hidden) {
            // Veliki folder (>2k) sa skupim string-sortom (name/kind/ext):
            // `localizedCompare` lavina ne sme na main, pa sort + revalidacija
            // idu u pozadinu uz jedan publish. Stari prikaz se NE briše —
            // ranije je `rawFiles = []` pravio flash praznog spinnera + dupli
            // Table diff (npr. 71→0→8k) što je prebacivanje Desktop/Downloads/
            // Documents u sidebaru činilo "veoma sporim". Stari folder ostaje
            // vidljiv dok pozadina ne donese sortirani snimak (jedan diff).
            // Jeftini sortovi (datum/veličina = integer poređenja, ~2ms za 8k)
            // padaju na brzi put ispod, kao mali folderi.
            // Sortiranje van maina za SVAKI keširani snimak preko ~1000
            // stavki, i kod „jeftinih" sortova (datum/veličina): FileItem je
            // velika struktura, pa je sort 8k stavki po datumu držao main
            // 10–25 ms baš u trenutku klika na Downloads/Documents.
            if snapshot.count > backgroundSortThreshold {
                largeSortGen &+= 1
                let lgen = largeSortGen
                // Bez brisanja: stari folder ostaje na ekranu dok sortirani
                // snimak ne stigne (spinner se prikazuje samo kad je lista
                // zaista prazna — vidi `isLoading && displayFiles.isEmpty`).
                isLoading = true
                // Dva koraka, ne jedan: prvo se keširani snimak samo presloži
                // (van main threada) i odmah prikaže, pa tek onda ide provjera
                // s diska. Ranije se čekalo i čitanje foldera prije prvog
                // prikaza, pa je Back u veliki folder držao spinner sve dok se
                // svih 8k stavki ne pročita — bez razloga, jer snimak je tu.
                DispatchQueue.global(qos: .userInitiated).async {
                    let sorted = sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold)
                    DispatchQueue.main.async {
                        guard lgen == largeSortGen, gen == reloadGeneration, path == currentPath else { return }
                        rawFiles = sorted
                        filesIdentity &+= 1
                        isLoading = false
                        maybeStartFolderSizing()
                    }
                    // Revalidacija: drugi publish samo ako se folder stvarno
                    // promijenio (inače bi pregradnja svih redova bila džaba).
                    let res = loadFreshItems(at: path, showHidden: hidden)
                    let fresh = sortedItems(res.items,
                                            by: field, ascending: asc, folderOrder: fold)
                    // Poređenje 8k stavki ovdje, ne na mainu: generacija ispod
                    // garantuje da je na ekranu upravo `sorted`.
                    let changed = fresh != sorted
                    DispatchQueue.main.async {
                        guard lgen == largeSortGen, gen == reloadGeneration, path == currentPath else { return }
                        if changed {
                            rawFiles = fresh
                            filesIdentity &+= 1
                            isLoading = false
                            maybeStartFolderSizing()
                        }
                        // Greška se pamti i uz keširani prikaz (baner), ne samo
                        // na prazno — inače bi odbijena dozvola bila nevidljiva.
                        folderError = res.error
                        then?()
                        if res.error == nil {
                            DirectoryCache.shared.prefetchSubfolders(of: path, showHidden: hidden)
                        }
                    }
                }
                return
            }
            rawFiles = sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold)
            filesIdentity &+= 1
            isLoading = false
            then?()
            maybeStartFolderSizing()
            // Background revalidation keeps it fresh (external changes, etc.).
            // Skip the second publish when nothing changed: assigning `rawFiles`
            // again rebuilds the whole visible list (Table/List diff over every
            // row) — the profiled freeze on every navigation.
            DispatchQueue.global(qos: .userInitiated).async {
                let res = loadFreshItems(at: path, showHidden: hidden)
                let fresh = sortedItems(res.items,
                                        by: field, ascending: asc, folderOrder: fold)
                DispatchQueue.main.async {
                    guard gen == reloadGeneration, path == currentPath else { return }
                    if fresh != rawFiles {
                        rawFiles = fresh
                        filesIdentity &+= 1
                        maybeStartFolderSizing()
                    }
                    folderError = res.error
                    if res.error == nil {
                        DirectoryCache.shared.prefetchSubfolders(of: path, showHidden: hidden)
                    }
                }
            }
            return
        }
        // Cold path: no snapshot — show spinner only if truly nothing to show.
        if rawFiles.isEmpty { isLoading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let res = loadItems(at: path, showHidden: hidden)
            let items = sortedItems(res.items, by: field, ascending: asc, folderOrder: fold)
            DispatchQueue.main.async {
                guard gen == reloadGeneration else { return }
                rawFiles = items
                filesIdentity &+= 1
                isLoading = false
                folderError = res.error
                then?()
                if res.error == nil {
                    DirectoryCache.shared.prefetchSubfolders(of: path, showHidden: hidden)
                }
                maybeStartFolderSizing()
            }
        }
    }
}

// MARK: - Display memo cache

/// Thread-safe generation counter for folder-size runs. Lives outside @State
/// because the background sizing walk must read it off the main thread —
/// reading @State off-main would be a data race. Bumping it cancels any
/// in-flight run; publishes re-check it (plus the path) on the main thread.
private final class FolderSizeRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var gen: UInt = 0
    @discardableResult
    func next() -> UInt {
        lock.lock(); defer { lock.unlock() }
        gen &+= 1
        return gen
    }
    func isCurrent(_ g: UInt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return g == gen
    }
}

/// Non-reactive memo for expensive `displayFiles` derivations (fuzzy rank,
/// merged tag results). Plain reference type on purpose: writing it during
/// `body` never triggers a view update, unlike `@State`.
private final class DisplayMemoCache {
    var searchKey = ""
    var searchFiles: [FileItem] = []
    var tagKey = ""
    var tagFiles: [FileItem] = []
    var selectedKey = ""
    var selectedItems: [FileItem] = []
    /// Cached AppKit table for programmatic scrolls (see `scrollTableView`).
    /// Weak: the Table is recreated when switching view modes.
    weak var cachedTableView: NSTableView?
}

// MARK: - Toast payload

struct ToastPayload: Equatable {
    let id      = UUID()
    let icon:    String
    let message: String
    /// Reveal kandidat za "Show" dugme — rezultat operacije van vidljivog
    /// foldera (paste u subfolder iz searcha, move u drugi pane…). Nil za
    /// obične toastove bez destinacije.
    var revealURLs: [URL]? = nil
    var revealDestination: URL? = nil
    static func == (l: ToastPayload, r: ToastPayload) -> Bool { l.id == r.id }
}

// MARK: - In-app toast view

struct InAppToast: View {
    let icon:    String
    let message: String
    var onShow: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            // Two lines: longer results (AI organizer summary, "stopped early")
            // were cut off at one.
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if onShow != nil {
                Divider().frame(height: 16)
                Button("Show") { onShow?() }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: FFTheme.floatingShape)
        .overlay(FFTheme.floatingShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        // Outermost, so the pill still hugs short messages and only long ones wrap.
        .frame(maxWidth: 560)
    }
}

// MARK: - File preview panel (right sidebar)
// Uses native QLPreviewView (same engine as macOS Finder's preview column)

struct FilePreviewPanel: View {
    let item: FileItem?
    @ObservedObject var fileOps: FileOperationsService
    var onReload: () -> Void = {}
    var showHidden: Bool = false
    /// Current main-pane folder — used when nothing is selected (§16:
    /// "rad vezan za trenutno odabrani folder ili fajl").
    var currentFolder: URL? = nil
    var onOpenFile: (FileItem) -> Void = { _ in }
    var onEnterFolder: (URL) -> Void = { _ in }
    /// Selects a file in the left browser (workspace relation jumps, §10).
    var onRevealFile: (URL) -> Void = { _ in }
    @ObservedObject private var workspaces: WorkspaceStore = .shared
    @ObservedObject private var git: GitService = .shared
    /// Git tab: Preview (postojeći QL/workspace) / Diff / History / Repo.
    /// Desni klik Git ▸ View changes + ⌥⌘G postavljaju Diff preko notifikacije.
    @State private var gitTab: GitPreviewTab = .preview

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                if let root = git.repoRoot(for: item.url) {
                    gitFileBody(item: item, root: root)
                } else {
                    workspaceBody(for: item)
                }
            } else if let folder = currentFolder,
                      workspaces.isWorkspace(folder),
                      let ws = workspaces.workspace(at: folder) {
                // Nothing selected, but the current folder is a workspace.
                WorkspaceOverviewView(workspaceID: ws.id, rootURL: folder,
                                      onRevealFile: onRevealFile,
                                      onEnterFolder: onEnterFolder)
            } else if let folder = currentFolder,
                      let root = git.repoRoot(for: folder) {
                // Ništa selektovano, ali je folder Git repo — repo panel
                // (branch, changes, commit, pull/push) direktno.
                GitRepoPanel(root: root, onRevealFile: onRevealFile, onReload: onReload)
            } else {
                // Jedno prazno stanje za sve preview površine (FFEmptyPreview):
                // prije je ovdje stajao nepostojeći simbol „doc.magnifyingglass",
                // pa se vidio samo prazan krug.
                FFEmptyPreview(symbol: "doc.text.magnifyingglass",
                               title: "No selection",
                               message: "Pick a file and its preview shows up here.",
                               hint: ("Space", "Quick Look"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowDiff)) { n in
            if let url = n.object as? URL, url == item?.url { gitTab = .diff }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowHistory)) { n in
            if let url = n.object as? URL, url == item?.url { gitTab = .history }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowRepo)) { n in
            if let url = n.object as? URL {
                if url == item?.url || url == currentFolder { gitTab = .repo }
            }
        }
        .onChange(of: item?.id ?? "") { _, _ in
            // Nova selekcija: zadrži traženi tab ako je zahtjev baš za nju
            // (desni klik → select + showDiff trka), inače reset na Preview.
            if let req = GitUIRequest.shared.url, req == item?.url {
                gitTab = GitUIRequest.shared.tab
            } else {
                gitTab = .preview
            }
        }
        .onAppear { git.refresh(for: item?.url ?? currentFolder ?? FileManager.default.homeDirectoryForCurrentUser) }
    }

    // MARK: - Git file body (Preview / Diff / History / Repo tabovi)

    @ViewBuilder
    private func gitFileBody(item: FileItem, root: URL) -> some View {
        Picker("", selection: $gitTab) {
            Text("Preview").tag(GitPreviewTab.preview)
            Text("Diff").tag(GitPreviewTab.diff)
            Text("History").tag(GitPreviewTab.history)
            Text("Repo").tag(GitPreviewTab.repo)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        Divider().opacity(0.6)
        switch gitTab {
        case .preview:
            workspaceBody(for: item)
        case .diff:
            if item.isBrowsableFolder {
                GitRepoPanel(root: root, onRevealFile: onRevealFile, onReload: onReload)
            } else {
                GitFileDiffView(url: item.url, onReload: onReload)
            }
        case .history:
            GitHistoryView(url: item.url, root: root)
        case .repo:
            GitRepoPanel(root: root, onRevealFile: onRevealFile, onReload: onReload)
        }
    }

    // MARK: - Workspace routing (§2–§5)

    @ViewBuilder
    private func workspaceBody(for item: FileItem) -> some View {
        if item.isBrowsableFolder, workspaces.isWorkspace(item.url),
           let ws = workspaces.workspace(at: item.url) {
            // Workspace root selected → whole-project overview (§3).
            WorkspaceOverviewView(workspaceID: ws.id, rootURL: item.url,
                                  onRevealFile: onRevealFile,
                                  onEnterFolder: onEnterFolder)
        } else if let found = workspaces.enclosingWorkspace(for: item.url) {
            if item.isBrowsableFolder {
                // Subfolder inside a workspace: compact banner + plain list.
                WorkspaceSubfolderBanner(workspaceID: found.workspace.id, rootURL: found.root) {
                    onEnterFolder(found.root)
                }
                FolderContentsPreview(
                    item: item,
                    showHidden: showHidden,
                    onOpenFile: onOpenFile,
                    onEnterFolder: onEnterFolder,
                    onRevealInMain: { onEnterFolder(item.url) }
                )
            } else if let rel = workspaces.relativePath(of: item.url, to: found.root) {
                // File inside a workspace → preview + work tabs (§5).
                workspaceFileBody(item: item, ws: found.workspace, root: found.root, relative: rel)
            } else {
                legacyBody(for: item)
            }
        } else if item.isBrowsableFolder {
            // Plain folder: folder list + Enable Workspace entry (§2).
            FolderContentsPreview(
                item: item,
                showHidden: showHidden,
                onOpenFile: onOpenFile,
                onEnterFolder: onEnterFolder,
                onRevealInMain: { onEnterFolder(item.url) }
            )
            Divider().opacity(0.6)
            EnableWorkspacePrompt(folder: item.url)
        } else {
            legacyBody(for: item)
        }
    }

    /// File inside a workspace: compact QuickLook on top, work tabs below.
    @ViewBuilder
    private func workspaceFileBody(item: FileItem, ws: Workspace, root: URL, relative: String) -> some View {
        // Jedan metadata lookup po selekciji: isNotDownloaded je stat
        // (ubiquitousItemDownloadingStatus) — pre se zvao 2× po body
        // evaluaciji (archive grana + else-if), svaki put na mainu.
        let onlineOnly = item.isNotDownloaded
        if onlineOnly {
            OnlineOnlyFileView(item: item)
        } else if item.isArchive {
            ArchivePreviewView(item: item) {
                fileOps.extract(item.url, reload: onReload)
            }
        } else {
            DebouncedQLPreview(item: item)
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 260)
                .clipShape(FFTheme.cardShape)
                .padding([.horizontal, .top], 8)
        }
        Divider().opacity(0.6)
        WorkspaceFilePanel(workspaceID: ws.id, rootURL: root,
                           fileURL: item.url, relative: relative,
                           onRevealFile: onRevealFile)
    }

    // MARK: - Legacy (non-workspace) preview

    @ViewBuilder
    private func legacyBody(for item: FileItem) -> some View {
        // Jedan metadata lookup po selekciji: isNotDownloaded je stat
        // (ubiquitousItemDownloadingStatus) — pre se zvao 2× po body
        // evaluaciji (archive grana + else-if), svaki put na mainu.
        let onlineOnly = item.isNotDownloaded
        if item.isBrowsableFolder {
            // Folders: scrollable clickable list instead of a blank QL view.
            FolderContentsPreview(
                item: item,
                showHidden: showHidden,
                onOpenFile: onOpenFile,
                onEnterFolder: onEnterFolder,
                onRevealInMain: { onEnterFolder(item.url) }
            )
        } else if item.isArchive {
                    // Archives: contents listing + one-click extract.
                    // Ali ne za online-only fajlove — čitanje arhive bi skinulo
                    // ceo fajl sa mreže. Prvo neka se preuzme duplim klikom.
                    if onlineOnly {
                        OnlineOnlyFileView(item: item)
                    } else {
                        ArchivePreviewView(item: item) {
                            fileOps.extract(item.url, reload: onReload)
                        }
                    }
                } else if onlineOnly {
                    // Online-only cloud fajl (Drive Stream, OneDrive On-Demand…):
                    // QuickLook bi pokrenuo preuzimanje celog fajla čim ga
                    // selektuješ — zato placeholder umesto preview-a.
                    OnlineOnlyFileView(item: item)
                } else {
                    // Same inset and radius as the info card below: the
                    // preview no longer runs into the panel edges and the
                    // resize handle, and the two read as one column of cards.
                    DebouncedQLPreview(item: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(FFTheme.cardShape)
                        .padding([.horizontal, .top], 8)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            FileIconView(item: item, size: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                TagDotsView(colors: item.tagColors, size: 9)
                            }
                        }
                        Divider().opacity(0.6)
                        FFKindRow(item: item)
                        if !item.isDirectory { FFSizeRow(item: item, size: item.formattedSize) }
                        detailRow("Modified", item.formattedDateModified)
                        detailRow("Created",  item.formattedDateCreated)
                        GoogleDriveInfoRow(url: item.url)
                        ESignPreviewRow(url: item.url)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        FFTheme.cardShape
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        FFTheme.cardShape
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .padding(8)
                }
        }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":").font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value).font(.caption).lineLimit(2)
        }
    }
}

// MARK: - Online-only cloud file placeholder
//
// Fajl postoji samo na mreži (Drive Stream, OneDrive On-Demand, iCloud).
// Bilo kakvo čitanje sadržaja (preview, sniff, listanje arhive) skinulo bi ceo
// fajl — zato samo metadata + uputstvo. Dupli klik ga otvara preko sistema,
// koji preuzimanje odradi kako treba (sa progresom u Finderu/Drive app-u).
struct OnlineOnlyFileView: View {
    let item: FileItem

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.softGradient)
                        .frame(width: 64, height: 64)
                    Image(systemName: "cloud")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text("Online only")
                    .font(.system(size: 13, weight: .semibold))
                Text("Double-click downloads and opens the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    FileIconView(item: item, size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        TagDotsView(colors: item.tagColors, size: 9)
                    }
                }
                Divider().opacity(0.6)
                FFKindRow(item: item)
                if !item.isDirectory {
                    HStack(alignment: .top, spacing: 4) {
                        Text("Size:").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(item.formattedSize).font(.caption).lineLimit(2)
                    }
                }
                HStack(alignment: .top, spacing: 4) {
                    Text("Modified:").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(item.formattedDateModified).font(.caption).lineLimit(2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FFTheme.cardShape
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                FFTheme.cardShape
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(8)
        }
    }
}

// MARK: - Debounced QuickLook preview (shared: sidebar panel + columns pane)
//
// QuickLook generation for big files (video, large PDF) takes hundreds of ms;
// generating it on every arrow-key step freezes stepping through a folder.
// Match Finder's behavior: the old preview stays for 120ms while stepping
// quickly, and files over 100MB skip generation entirely (metadata only).
struct DebouncedQLPreview: View {
    let item: FileItem

    @State private var previewURL: URL?
    @State private var previewWork: DispatchWorkItem?
    /// Fajl za koji je zakazan (ili završen) tekući preview — stale guard za
    /// pozadinsku online-only proveru: selekcija se pomerila dok je stat putovao.
    @State private var scheduledURL: URL?
    /// True when the current item intentionally has no preview (>100MB).
    /// Disambiguates "oversized" from "debounce pending" — both have nil URL,
    /// but only the latter has pending work.
    @State private var isOversized = false
    /// True kada je fajl samo na mreži (nije skinut) — QuickLook bi pokrenuo
    /// preuzimanje celog fajla na samu selekciju, zato se ne preview-uje.
    @State private var isOnlineOnly = false

    var body: some View {
        Group {
            if let previewURL {
                QLSidebarPreview(url: previewURL)
            } else if isOversized {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text("Preview skipped — file over 100 MB")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isOnlineOnly {
                VStack(spacing: 8) {
                    Image(systemName: "cloud")
                        .font(.title2).foregroundStyle(.secondary)
                    Text("Online only — double-click downloads the file")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading preview…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { schedulePreview(for: item) }
        .onChange(of: item.id) { _, _ in schedulePreview(for: item) }
        .onDisappear { previewWork?.cancel(); previewWork = nil }
    }

    private func schedulePreview(for item: FileItem) {
        previewWork?.cancel()
        previewWork = nil
        if !item.isDirectory, item.size > 100 * 1024 * 1024 {
            previewURL = nil
            scheduledURL = item.url
            isOversized = true
            isOnlineOnly = false
            return
        }
        isOversized = false
        // Stari preview ostaje dok debounce putuje (Finder ponašanje pri brzom
        // stepovanju kroz folder strelicama).
        if item.url == previewURL, !isOnlineOnly { scheduledURL = item.url; return }
        // Online-only provera je stat na mainu — pre je svaki klik/selekcija
        // blokirala render dok stat ne stigne (cloud volumeni: milisekunde).
        // Sada se proverava u pozadini, unutar istog debounce prozora, pa klik
        // nikad ne čeka disk; zastareli rezultati se odbacuju preko scheduledURL.
        let target = item.url
        scheduledURL = target
        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            guard !work.isCancelled else { return }
            let onlineOnly = FileItem.isNotDownloaded(target)
            DispatchQueue.main.async {
                guard !work.isCancelled, target == scheduledURL else { return }
                if onlineOnly {
                    previewURL = nil
                    isOnlineOnly = true
                } else {
                    isOnlineOnly = false
                    previewURL = target
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

// MARK: - Native QL preview (mirrors Finder's preview panel)
// QLPreviewView must be created after the view enters the window hierarchy —
// creating it with a zero frame or before a window exists silently produces nothing.

struct QLSidebarPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> _QLSidebarHost { _QLSidebarHost() }
    func updateNSView(_ host: _QLSidebarHost, context: Context) { host.show(url) }
}

final class _QLSidebarHost: NSView {
    private var qlView: QLPreviewView?
    private var pendingURL: URL?

    func show(_ url: URL) {
        // SwiftUI calls this on every parent update; handing QuickLook the same
        // item again makes it reload the whole preview.
        if url == pendingURL, qlView != nil { return }
        pendingURL = url
        if let ql = qlView {
            ql.previewItem = url as NSURL
        } else {
            setupQL()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { setupQL() }
    }

    override func layout() {
        super.layout()
        qlView?.frame = bounds
    }

    private func setupQL() {
        guard window != nil, qlView == nil else { return }
        // Use a concrete initial frame; zero frame produces a blank view.
        let frame = bounds.isEmpty ? NSRect(x: 0, y: 0, width: 260, height: 300) : bounds
        guard let ql = QLPreviewView(frame: frame, style: .normal) else { return }
        ql.autoresizingMask = [.width, .height]
        ql.autostarts = true
        ql.shouldCloseWithWindow = false
        addSubview(ql)
        qlView = ql
        if let url = pendingURL {
            ql.previewItem = url as NSURL
        }
    }
}

// MARK: - Arrow cursor catch-all
//
// Place this as .background() on any region that should show the default arrow cursor
// when nothing else has claimed it (file list, sidebar list, toolbar, etc.).
//
// Uses NSTrackingArea with .cursorUpdate. AppKit's rule: if a cursor rect is active
// at the mouse position (text field → IBeam, resize handle → resizeLeftRight, the
// NavigationSplitView divider → resizeLeftRight), that cursor rect takes priority and
// cursorUpdate(with:) is NOT called. In every other area the tracking area fires
// cursorUpdate(with:) and we reset to arrow — which clears any IBeam or resize cursor
// that the previous area set via NSCursor.set() rather than via a cursor rect.
//
// hitTest returns nil so this transparent layer never intercepts clicks or drags.

struct ArrowCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> _ArrowCursorAreaView { _ArrowCursorAreaView() }
    func updateNSView(_ v: _ArrowCursorAreaView, context: Context) {}
}

final class _ArrowCursorAreaView: NSView {
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

// MARK: - Cursor reset on exit
//
// A zero-cost transparent layer that forces the cursor back to the default arrow
// the instant the pointer LEAVES its bounds. Apply to any view that hands the
// cursor to a child which sets a non-default cursor (text fields → I-beam) so the
// cursor never "sticks" after the pointer moves on.
//
// Why this exists alongside ArrowCursorArea: the catch-all above resets via a
// .cursorUpdate tracking area placed as a .background(), which the front-most
// AppKit table/list views occlude — so leaving a text field onto the file list
// would not fire it and the I-beam would persist. This uses geometry-based
// .mouseEnteredAndExited on the field itself, which fires the moment the pointer
// crosses the field boundary regardless of what is in front of it.
//
// hitTest returns nil so it never intercepts clicks, drags, or text selection.

struct CursorResetOnExit: NSViewRepresentable {
    func makeNSView(context: Context) -> _CursorResetView { _CursorResetView() }
    func updateNSView(_ v: _CursorResetView, context: Context) {}
}

final class _CursorResetView: NSView {
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        // No .enabledDuringMouseDrag — we must not reset to arrow mid text-selection
        // drag; we only care about a plain pointer move leaving the field.
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

extension View {
    /// Forces the cursor back to the default arrow the moment the pointer leaves
    /// this view. Use on text fields so the I-beam never sticks after moving away.
    func resetsCursorOnExit() -> some View { background(CursorResetOnExit()) }
}

// MARK: - Cursor reset on enter
//
// Sibling of CursorResetOnExit, but fires on ENTER. This exists specifically for
// the NavigationSplitView divider: the divider sets a resize cursor while hovered,
// and when the pointer moves off it onto a pane the divider's cursor would stick.
// The existing .cursorUpdate catch-all (ArrowCursorArea) can't clear it because the
// pane's List/Table is painted in front and steals the cursorUpdate. A geometry
// based .mouseEntered fires the instant the pointer crosses into the pane regardless
// of what is in front, so the stale resize cursor is released immediately.
//
// We only reset on ENTER (not exit) so internal cursors — text-field I-beams, the
// column resize handles — are left untouched; those views manage their own cursor
// once the pointer is already inside the pane.

struct CursorResetOnEnter: NSViewRepresentable {
    func makeNSView(context: Context) -> _CursorResetOnEnterView { _CursorResetOnEnterView() }
    func updateNSView(_ v: _CursorResetOnEnterView, context: Context) {}
}

final class _CursorResetOnEnterView: NSView {
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        guard !bounds.isEmpty else { return }
        // No .enabledDuringMouseDrag — while the user is actively dragging the
        // divider we must keep the resize cursor; we only reset once the drag is
        // over and the pointer moves into the pane.
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

extension View {
    /// Forces the cursor back to the default arrow the moment the pointer enters
    /// this view. Use on split-view panes so the divider's resize cursor never
    /// sticks after the pointer moves off the divider onto the pane.
    func resetsCursorOnEnter() -> some View { background(CursorResetOnEnter()) }
}
