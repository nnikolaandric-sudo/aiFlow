import SwiftUI
import AppKit
import CoreServices

// MARK: - Detected IDE/tool state

struct InstalledApps {
    var vscodePath: String?  = nil   // resolved app path for VS Code
    var claudeCLI:  String?  = nil   // path to `claude` CLI
    var cursorPath: String?  = nil   // resolved app path for Cursor
    var codexPath:  String?  = nil  // resolved app path for Codex (or CLI path)
}

// MARK: - Toolbar

struct QuickActionsToolbar: View {
    @Binding var currentPath:    URL
    let selectedURL:             URL?   // selected folder, nil → use currentPath for IDEs
    let selectedCount:           Int    // enables delete button
    /// All selected items (for selection-aware Copy Path); empty → currentPath.
    var selectedURLs: [URL] = []
    let onCreateFolder:          () -> Void
    let onCreateFile:            () -> Void
    let onDelete:                () -> Void
    var onTrash: (() -> Void)? = nil   // safe Move to Trash (primary); nil → trash via fileOps fallback
    var pasteDestination: URL? = nil   // smart paste target (selected folder or current); nil → currentPath
    @ObservedObject var fileOps: FileOperationsService
    @Binding var viewMode:       ViewMode
    @Binding var sortField:      SortField
    @Binding var sortAscending:  Bool
    @Binding var showHidden:     Bool
    @Binding var groupBy:        GroupBy
    @Binding var folderOrder:    FolderOrder
    @Binding var showPreview:    Bool
    @Binding var showColumnTree: Bool
    let onReload: () -> Void
    // Navigation history (Back/Forward + Go to Folder). Defaults keep
    // existing call sites compiling; ContentView passes the real wiring.
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var onGoBack: () -> Void = {}
    var onGoForward: () -> Void = {}
    var onGoToFolder: () -> Void = {}
    // Power tools: dual-pane split + batch rename (wired by ContentView).
    var isDualPane: Bool = false
    var onToggleDualPane: () -> Void = {}
    var onBatchRename: () -> Void = {}
    // AI organizer (rename + subfolders via OpenRouter); nil key → explains itself.
    var onAIOrganize: () -> Void = {}
    // Recursive folder sizes (opt-in, default off). Binding default keeps
    // previews compiling; ContentView passes the real $binding.
    var showFolderSizes: Binding<Bool> = .constant(false)
    // ── Unified contextual toolbar: selection context (replaces the separate
    // SelectionActionBar strip). Empty → folder-level actions; non-empty →
    // selection actions inline in THIS row (no second bar, no layout jump).
    var selectedItems: [FileItem] = []
    var onNavigateItem: (FileItem) -> Void = { _ in }
    var onRenameItem: (FileItem) -> Void = { _ in }
    var onBatchRenameItems: ([FileItem]) -> Void = { _ in }
    var onSendToDiscordItems: (([FileItem]) -> Void)? = nil
    var onClearSelection: () -> Void = {}
    /// Workspace Mode project layer (§2): observed so the briefcase button
    /// flips between Enable / Open as folders gain workspaces.
    @ObservedObject var workspaces: WorkspaceStore = .shared

    @State private var apps = InstalledApps()

    private var openTarget: URL { selectedURL ?? currentPath }
    private var effectivePasteDestination: URL { pasteDestination ?? currentPath }
    /// Same semantics as the selection bar: selection paths when something is
    /// selected, else the current folder. One icon, one behaviour everywhere.
    private var copyPathURLs: [URL] {
        if !selectedURLs.isEmpty { return selectedURLs }
        return [selectedURL ?? currentPath]
    }

    private var copyPathHelp: String {
        if selectedURLs.count > 1 { return "Copy \(selectedURLs.count) paths (⌥⌘C)" }
        if selectedURLs.count == 1 { return "Copy path of “\(selectedURLs[0].lastPathComponent)” (⌥⌘C)" }
        return "Copy path of current folder (⌥⌘C)"
    }
    private var hasAnyIDE: Bool {
        apps.vscodePath != nil || apps.claudeCLI != nil || apps.cursorPath != nil || apps.codexPath != nil
    }

    private var hasSelection: Bool { !selectedItems.isEmpty }

    var body: some View {
        // Unified contextual toolbar (single row, no second selection strip):
        // - no selection → Navigate / New / Edit / Open In / View / More
        // - selection   → Navigate / Selection (Open·Cut·Copy·Paste·Rename·
        //   Compress·Extract·Share) / Trash+Clear / Open In / View / More
        // Wide windows show the full row; narrow windows fall back to a
        // horizontal scroll (same order, nothing clipped, nothing jumps
        // button↔menu on resize).
        ViewThatFits(in: .horizontal) {
            toolbarContent
            ScrollView(.horizontal, showsIndicators: false) {
                toolbarContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .onAppear {
            // Show IDE buttons instantly from last-known-good cache; only
            // spawn the login-shell `which` probes when the cache is stale —
            // the old code re-detected on EVERY launch despite the 6h TTL.
            if !loadCachedApps() {
                detectInstalledApps()
            }
        }
    }

    /// Full toolbar row — shared by the fitting and scrolling variants
    /// above so both show identical actions in identical order.
    private var toolbarContent: some View {
        HStack(spacing: 10) {

            // ── 1. Navigate: history + up + refresh ─────────────────────
            HStack(spacing: 4) {
                ToolbarActionButton(icon: "chevron.left", label: "Back (⌘[)") { onGoBack() }
                    .disabled(!canGoBack)
                ToolbarActionButton(icon: "chevron.right", label: "Forward (⌘])") { onGoForward() }
                    .disabled(!canGoForward)
                ToolbarActionButton(icon: "arrow.up", label: "Enclosing Folder (⌘↑)") {
                    let p = currentPath.deletingLastPathComponent()
                    if p != currentPath { currentPath = p }
                }
                ToolbarActionButton(icon: "arrow.clockwise", label: "Refresh (⌘R)") { onReload() }
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 20).opacity(0.4)

            // ── 2. Context: New (no selection) OR Selection actions ────
            if hasSelection {
                selectionCluster
            } else {
                HStack(spacing: 4) {
                    ToolbarActionButton(icon: "folder.badge.plus", label: "New Folder (⇧⌘N)") { onCreateFolder() }
                    ToolbarActionButton(icon: "doc.badge.plus",    label: "New Text File (⌥⌘N)") { onCreateFile() }
                    // Inside a workspace with the preview closed, the project
                    // UI would be unreachable — one button reopens it, and a
                    // second one turns it off again (Disable returns to the
                    // normal folder preview; data is removed, files are kept).
                    if workspaces.isWorkspace(currentPath) {
                        ToolbarActionButton(icon: "briefcase.fill", label: "Open Workspace — show the project in the preview panel") {
                            showPreview = true
                        }
                        ToolbarActionButton(icon: "folder.badge.minus", label: "Disable Workspace — turn off the project and return to the normal preview") {
                            workspaces.disableWorkspace(at: currentPath)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Divider().frame(height: 20).opacity(0.4)

            // ── 3. Edit: undo + paste + copy-path + trash ──────────────
            // Always visible (Paste/Undo are folder-level too); Trash doubles
            // as the selection Trash — one place, no duplication.
            HStack(spacing: 4) {
                ToolbarActionButton(icon: "arrow.uturn.backward", label: "Undo (⌘Z)") { fileOps.undo() }
                    .disabled(!fileOps.canUndo)
                ToolbarActionButton(icon: "doc.on.clipboard", label: pasteHelp) {
                    fileOps.paste(to: effectivePasteDestination, reload: onReload)
                }
                .disabled(fileOps.pasteboardURLs.isEmpty)
                TrashDropButton(trashAction: trashAction, onDelete: onDelete,
                                selectedCount: selectedCount, fileOps: fileOps,
                                onReload: onReload)
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 20).opacity(0.4)

            // ── 4. Open In: one menu (Terminal + detected IDEs) ──────
            openInMenu

            Divider().frame(height: 20).opacity(0.4)

            // ── 5. View: segmented switcher + ONE stable display menu ──
            // (no ViewThatFits: toggles used to jump button↔menu on resize)
            HStack(spacing: 4) {
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.icon).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented).frame(width: 96).help("Switch view (⌘1/2/3)")
                .fixedSize(horizontal: true, vertical: false)
                toggleClusterMenu
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            // ── 6. More (⋯): power tools + sort + destructive delete ───
            // Single stable overflow — same bindings as before, shortcuts in
            // labels (not tooltip-only).
            moreMenu
        }
        .background(
            Button("") { showColumnFilter.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .hidden()
        )
    }

    // MARK: - Toolbar UX helpers

    // MARK: - Selection context (merged from SelectionActionBar)

    private var selURLs: [URL] { selectedItems.map(\.url) }
    private var selSingle: FileItem? { selectedItems.count == 1 ? selectedItems[0] : nil }
    private var selIsSingleArchive: Bool { selSingle?.isArchive == true }
    private var selSignable: [URL] { selURLs.filter(ESignSource.canSign) }

    private var selOpenHelp: String {
        if let s = selSingle {
            return s.isBrowsableFolder ? "Open folder (⌘O)" : "Open \"\(s.name)\" (⌘O)"
        }
        return "Open selected items (⌘O)"
    }
    private var selCompressHelp: String {
        if let s = selSingle { return "Compress \"\(s.name)\" into .zip" }
        return "Compress \(selectedItems.count) items into .zip"
    }

    /// Inline selection actions, kept to what people reach for constantly:
    /// count + clear | Quick Look, Get Info | Extract (only for an archive) |
    /// Share | ⋯. Open, Open With, Cut, Copy, Duplicate, Rename, Compress and
    /// links live in ⋯, the right-click menu and their shortcuts — the row
    /// used to carry 17 buttons for a selection and read as noise.
    private var selectionCluster: some View {
        HStack(spacing: 4) {
            // Count + clear — the "selection mode is on" signal + Esc exit.
            HStack(spacing: 5) {
                Text("\(selectedItems.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                ToolbarActionButton(icon: "xmark", label: "Clear Selection (Esc)") { onClearSelection() }
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 20).opacity(0.4)

            HStack(spacing: 4) {
                // Quick Share — 1 klik: 24h link sa laptopa, bez dijaloga,
                // odmah kopiran + toast. Više stavki/folderi → jedan .zip.
                ToolbarActionButton(icon: "link", label: "Quick Share (24h) — create & copy link, no dialog (⌥⌘L)") {
                    Task { await SecureShareManager.shared.quickLink(for: selURLs) }
                }
                .disabled(!SecureShareManager.canQuickLink(selURLs))
                ToolbarActionButton(icon: "eye", label: "Quick Look (Space)") {
                    QuickLookController.shared.show(selURLs)
                }
                ToolbarActionButton(icon: "info.circle", label: "Get Info (⌘I)") {
                    showGetInfoInFinder(selURLs)
                }
                // Workspace (§2): one click on any folder enables the project
                // layer AND opens the preview panel, so the result is visible
                // immediately — no hunting through menus. When already
                // enabled the second button turns it off again (Disable
                // returns to the normal preview).
                if let folder = selSingle, folder.isBrowsableFolder {
                    let enabled = workspaces.isWorkspace(folder.url)
                    ToolbarActionButton(
                        icon: enabled ? "briefcase.fill" : "briefcase",
                        label: enabled
                            ? "Open Workspace — show \"\(folder.name)\" in the preview panel"
                            : "Enable Workspace for \"\(folder.name)\" — tasks, reviews & dates in the preview panel"
                    ) {
                        if !enabled { workspaces.enableWorkspace(at: folder.url) }
                        showPreview = true
                    }
                    if enabled {
                        ToolbarActionButton(
                            icon: "folder.badge.minus",
                            label: "Disable Workspace for \"\(folder.name)\" — turn off and return to the normal preview"
                        ) {
                            workspaces.disableWorkspace(at: folder.url)
                        }
                    }
                }
                if selIsSingleArchive {
                    LabeledToolbarButton(icon: "tray.and.arrow.down.fill", title: "Extract", label: "Extract Here — unpacks the selected archive") {
                        if let s = selSingle { fileOps.extract(s.url, reload: onReload) }
                    }
                }
                Menu {
                    Button("Quick Link — Copy 24h Link (⌥⌘L)") { Task { await SecureShareManager.shared.quickLink(for: selURLs) } }
                        .disabled(SecureShareManager.canQuickLink(selURLs) == false)
                    Button(SecureShareManager.shareMenuTitle(for: selURLs)) { SecureShareWindowManager.shared.open(urls: selURLs) }
                        .disabled(SecureShareManager.canQuickLink(selURLs) == false)
                    Divider()
                    Button("AirDrop") { fileOps.shareViaAirDrop(selURLs) }
                    Button("Send via Mail (⇧⌘M)") { fileOps.shareViaMail(selURLs) }
                    if onSendToDiscordItems != nil {
                        Button("Send to Discord…") { onSendToDiscordItems?(selectedItems) }
                    }
                    Divider()
                    Button("Share…") { fileOps.showShareSheet(for: selURLs) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Share — links, AirDrop, Mail")
                Menu {
                    selectionOverflowContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open, Copy, Rename, Compress and more")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Overflow: same actions, full titles WITH shortcuts (never tooltip-only).
    @ViewBuilder
    private var selectionOverflowContent: some View {
        Button("Open (⌘O)") {
            if let s = selSingle { onNavigateItem(s) }
            else if let s = selectedItems.first { onNavigateItem(s) }
        }
        Menu {
            OpenWithMenuContent(urls: selURLs)
        } label: { Text("Open With") }
        Button("Quick Look (Space)") { QuickLookController.shared.show(selURLs) }
        Button("Get Info (⌘I)") { showGetInfoInFinder(selURLs) }
        if !selSignable.isEmpty {
            Button(ESignWindowManager.signTitle(for: selSignable, ofTotal: selURLs.count)) {
                ESignWindowManager.shared.open(selSignable)
            }
        }
        Divider()
        Button("Cut (⌘X)") { fileOps.cut(selURLs) }
        Button("Copy (⌘C)") { fileOps.copy(selURLs) }
        Button("Duplicate (⌘D)") { fileOps.duplicate(selURLs, reload: onReload) }
        Button("Rename… (Return)") {
            if let s = selSingle { onRenameItem(s) }
            else { onBatchRenameItems(selectedItems); onBatchRename() }
        }
        Button("Copy Path (⌥⌘C)") {
            fileOps.copyPath(selURLs.map(\.path).joined(separator: "\n"))
        }
        Divider()
        Button("Compress as .zip") { fileOps.compress(selURLs, reload: onReload) }
        Button("Compress as .tar.gz") { fileOps.compress(selURLs, as: .tarGz, reload: onReload) }
        Button("Extract Here") {
            if let s = selSingle { fileOps.extract(s.url, reload: onReload) }
        }
        .disabled(!selIsSingleArchive)
        Divider()
        Button("Quick Link (24h) — copy immediately (⌥⌘L)") { Task { await SecureShareManager.shared.quickLink(for: selURLs) } }
            .disabled(!SecureShareManager.canQuickLink(selURLs))
        Button("Send via Mail (⇧⌘M)") { fileOps.shareViaMail(selURLs) }
        if onSendToDiscordItems != nil {
            Button("Send to Discord…") { onSendToDiscordItems?(selectedItems) }
        }
    }

    /// Open In menu (Terminal + detected IDEs), stable layout — no
    /// separate Terminal button, it lives in this menu, one place.
    private var openInMenu: some View {
        Menu {
            if apps.vscodePath != nil {
                Button("Open in VS Code") { openInVSCode(openTarget) }
            }
            if apps.claudeCLI != nil {
                Button("Open in Claude Code (Terminal)") { openInClaudeCode(openTarget) }
            }
            if apps.cursorPath != nil {
                Button("Open in Cursor") { openInCursor(openTarget) }
            }
            if apps.codexPath != nil {
                Button("Open in Codex") { openInCodex(openTarget) }
            }
            if !hasAnyIDE {
                Text("No code editors detected")
            }
            Divider()
            Button("Open in Terminal") { openInTerminal(openTarget) }
        } label: {
            HStack(spacing: 3) {
                // Show up to 2 detected app icons inline for quick access,
                // but keep the overall width fixed so layout never jumps.
                openInIconsPreview
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Open \(openTarget.lastPathComponent) in Terminal / VS Code / Cursor / Claude / Codex")
    }

    @AppStorage("ffShowColumnFilter") private var showColumnFilter = false

    /// Single stable display menu (no ViewThatFits twin): hidden files,
    /// grouping, preview, tree, folder sizes. Shortcuts in titles.
    private var toggleClusterMenu: some View {
        Menu {
            Toggle("Hidden Files (⇧⌘.)", isOn: $showHidden)
            Picker("Group By", selection: $groupBy) {
                ForEach(GroupBy.allCases) { g in
                    Text(g.menuTitle).tag(g)
                }
            }
            .pickerStyle(.menu)
            Toggle("File Preview (⌥⌘P)", isOn: $showPreview)
            Toggle("Column Filter Bar (⌥⌘F)", isOn: $showColumnFilter)
            if viewMode == .columns {
                Toggle("Folder Tree", isOn: $showColumnTree)
            }
            Toggle("Calculate Folder Sizes", isOn: showFolderSizes)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Display options — hidden files (⇧⌘.), grouping, preview (⌥⌘P), folder sizes")
    }

    /// Single stable "More" overflow: power tools + sort (no inline Sort
    /// Picker anymore — List sorts via header click, everything else via this
    /// menu) + destructive delete. Shortcuts in labels, never tooltip-only.
    private var moreMenu: some View {
        Menu {
            Button("Go to Folder… (⇧⌘G)") { onGoToFolder() }
            Button("Redo (⇧⌘Z)") { fileOps.redo() }
                .disabled(!fileOps.canRedo)
            Button(copyPathHelp) {
                fileOps.copyPath(copyPathURLs.map(\.path).joined(separator: "\n"))
            }
            Divider()
            Button(isDualPane ? "Hide Second Pane (⌥⌘D)" : "Show Second Pane (⌥⌘D)") { onToggleDualPane() }
            Button("Rename Selected Items…") { onBatchRename() }
                .disabled(selectedCount < 2)
            Button("Organize with AI… (⌥⌘O)") { onAIOrganize() }
            Divider()
            // Sort lives ONLY here (plus native header click in List).
            Picker("Sort by", selection: $sortField) {
                ForEach(SortField.allCases) { f in Text(sortTitle(f)).tag(f) }
            }
            .pickerStyle(.menu)
            Button(sortAscending ? "Sort: Ascending — switch to Descending" : "Sort: Descending — switch to Ascending") {
                sortAscending.toggle()
            }
            Picker("Folders", selection: $folderOrder) {
                ForEach(FolderOrder.allCases) { o in
                    Text(o.rawValue).tag(o)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Delete Permanently…", role: .destructive) { onDelete() }
                .disabled(selectedCount == 0)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("More — second pane (⌥⌘D), sort, AI organize (⌥⌘O), permanent delete")
    }

    private func sortTitle(_ f: SortField) -> String {
        switch f {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .size: return "Size"
        case .kind: return "Kind"
        case .ext: return "Extension"
        }
    }

    private func viewModeTitle(_ mode: ViewMode) -> String {
        switch mode {
        case .list:    "List"
        case .icons:   "Icons"
        case .columns: "Columns"
        }
    }

    private var pasteHelp: String {
        let dest = effectivePasteDestination.lastPathComponent
        if effectivePasteDestination != currentPath {
            return "Paste into “\(dest)” (⌘V)"
        }
        return "Paste into current folder (⌘V)"
    }

    private func trashAction() {
        if let onTrash {
            onTrash()
        } else {
            // Fallback when host doesn't wire safe-trash (shouldn't happen).
            onDelete()
        }
    }

    @ViewBuilder
    private var openInIconsPreview: some View {
        HStack(spacing: 2) {
            if let path = apps.vscodePath {
                URLIconView(url: URL(fileURLWithPath: path), isDirectory: false, isPackage: false, size: 16)
                    .frame(width: 20, height: 20)
            }
            if let path = apps.cursorPath {
                URLIconView(url: URL(fileURLWithPath: path), isDirectory: false, isPackage: false, size: 16)
                    .frame(width: 20, height: 20)
            }
            if apps.vscodePath == nil && apps.cursorPath == nil {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
            }
        }
    }

    // MARK: - App detection cache (UserDefaults, 6-hour TTL)

    private struct AppCache: Codable {
        let timestamp:  Double   // timeIntervalSince1970
        let vscodePath: String?
        let claudeCLI:  String?
        let claudeApp:  String?
        let cursorPath: String?
        let codexPath:  String?
        let codexCLI:   String?
    }
    private static let kCacheKey = "FF.appDetectionCache.v2"
    private static let kCacheTTL: Double = 6 * 3600   // 6 hours

    /// Returns true when a fresh (within TTL) cache entry was loaded and
    /// applied — callers can then skip a full re-detect on this launch.
    @discardableResult
    private func loadCachedApps() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.kCacheKey),
              let c    = try? JSONDecoder().decode(AppCache.self, from: data),
              Date().timeIntervalSince1970 - c.timestamp < Self.kCacheTTL
        else { return false }

        let fm = FileManager.default
        var a  = InstalledApps()

        if let p = c.vscodePath, fm.fileExists(atPath: p) {
            a.vscodePath = p
        }
        if let cli = c.claudeCLI, fm.fileExists(atPath: cli) {
            a.claudeCLI = cli
        }
        if let p = c.cursorPath, fm.fileExists(atPath: p) {
            a.cursorPath = p
        }
        if let p = c.codexPath, fm.fileExists(atPath: p) {
            a.codexPath = p
        }
        apps = a
        return true
    }

    private func saveCachedApps(_ detected: InstalledApps, claudeApp: String?) {
        let c = AppCache(
            timestamp:  Date().timeIntervalSince1970,
            vscodePath: detected.vscodePath,
            claudeCLI:  detected.claudeCLI,
            claudeApp:  claudeApp,
            cursorPath: detected.cursorPath,
            codexPath:  detected.codexPath,
            codexCLI:   nil
        )
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.kCacheKey)
        }
    }

    // MARK: - App detection (background queue, no UI impact)

    private func detectInstalledApps() {
        DispatchQueue.global(qos: .background).async {
            var detected = InstalledApps()

            // Returns the first matching app URL from direct paths or bundle IDs.
            // File paths first (no IPC); bundle-ID lookup via LaunchServices,
            // which is thread-safe — unlike the old NSWorkspace call that forced
            // a DispatchQueue.main.sync from this background queue (deadlock
            // whenever main was busy, profiled at every cold launch).
            func appURL(bundleIDs: [String], appPaths: [String] = []) -> URL? {
                for path in appPaths where FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
                for bid in bundleIDs {
                    if let arr = LSCopyApplicationURLsForBundleIdentifier(bid as CFString, nil)?.takeRetainedValue() as? [URL],
                       let first = arr.first {
                        return first
                    }
                }
                return nil
            }

            // Find a CLI via login shell `which` — handles nvm, homebrew, etc.
            // `name` must be a bare tool name; anything else refuses (argv would
            // otherwise reach `zsh -c` and allow shell injection).
            func whichCLI(_ name: String) -> String? {
                guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", "which \(name) 2>/dev/null"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError  = Pipe()
                guard (try? p.run()) != nil else { return nil }
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !result.isEmpty, FileManager.default.fileExists(atPath: result) else { return nil }
                return result
            }

            // Also check known fixed paths (fast, no shell spawn)
            func fixedCLI(_ paths: [String]) -> String? {
                paths.first { FileManager.default.fileExists(atPath: $0) }
            }

            // ── VS Code ───────────────────────────────────────────────────
            // Only show VS Code button when the VS Code *app* is installed (not CLI-only),
            // so we're sure we open VS Code and not Cursor's `code` shim.
            if let url = appURL(bundleIDs: ["com.microsoft.VSCode"],
                                 appPaths: ["/Applications/Visual Studio Code.app"]) {
                detected.vscodePath = url.path
            }

            // ── Claude Code ───────────────────────────────────────────────
            // Only show the button when the `claude` CLI is actually installed.
            // Showing it without the CLI just confuses users (Terminal opens
            // but immediately shows "command not found").
            let claudeFixed = fixedCLI([
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
                "\(NSHomeDirectory())/.volta/bin/claude",
            ])
            let claudeCLIPath = claudeFixed ?? whichCLI("claude")
            detected.claudeCLI = claudeCLIPath

            // ── Cursor ───────────────────────────────────────────────────
            if let url = appURL(bundleIDs: ["com.todesktop.230313mzl4w4u92",
                                             "com.cursor.macos",
                                             "com.cursor.cursor"],
                                 appPaths: ["/Applications/Cursor.app"]) {
                detected.cursorPath = url.path
            }

            // ── OpenAI Codex ─────────────────────────────────────────────
            if let url = appURL(bundleIDs: ["com.openai.codex",
                                             "com.openai.codex-desktop"],
                                 appPaths: ["/Applications/Codex.app",
                                            "/Applications/OpenAI Codex.app"]) {
                detected.codexPath = url.path
            } else {
                // Codex may be CLI-only
                let codexCLI = fixedCLI(["/usr/local/bin/codex", "/opt/homebrew/bin/codex"])
                    ?? whichCLI("codex")
                detected.codexPath = codexCLI
            }

            let claudeAppPath = appURL(
                bundleIDs: ["com.anthropic.claudefordesktop",
                            "com.anthropic.claude-mac",
                            "com.anthropic.claude"],
                appPaths:  ["/Applications/Claude.app"]
            )?.path
            DispatchQueue.main.async {
                apps = detected
                saveCachedApps(detected, claudeApp: claudeAppPath)
            }
        }
    }

    // MARK: - Open helpers

    private func openInTerminal(_ url: URL) {
        guard !containsAppleScriptUnsafeChars(url.path) else { return }
        let cmd = "cd \(shellQuoted(url.path))"
        let script = """
tell application "Terminal"
    activate
    do script \(appleScriptStringLiteral(cmd))
end tell
"""
        runAppleScript(script)
    }

    private func openInVSCode(_ url: URL) {
        // Prefer opening via app bundle so we guarantee VS Code, not Cursor's `code` shim
        if let appPath = apps.vscodePath {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: appPath),
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }
    }

    private func openInClaudeCode(_ url: URL) {
        // Claude Code is a TUI — open a NEW Terminal window (which launches a
        // login shell, so PATH is fully configured including nvm / homebrew / npm).
        // Use the detected full CLI path when available, otherwise fall back to
        // the bare `claude` command which the login shell will resolve via PATH.
        guard !containsAppleScriptUnsafeChars(url.path) else { return }
        if let cli = apps.claudeCLI, containsAppleScriptUnsafeChars(cli) { return }
        let safe    = shellQuoted(url.path)
        let cliSafe = apps.claudeCLI.map { shellQuoted($0) } ?? "claude"
        // `do script` without "in front window" always opens a new window/tab.
        let cmd = "cd \(safe) && \(cliSafe) ."
        let script  = """
tell application "Terminal"
    activate
    do script \(appleScriptStringLiteral(cmd))
end tell
"""
        runAppleScript(script)
    }

    private func openInCursor(_ url: URL) {
        // Prefer app bundle — guarantees Cursor opens, not VS Code's code shim
        if let appPath = apps.cursorPath {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: appPath),
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }
        // Fallback: known Cursor CLIs
        let cliCandidates = [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        ]
        if let cli = cliCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [url.path]
            try? p.run()
        }
    }

    private func openInCodex(_ url: URL) {
        // App bundle takes priority
        if let appPath = apps.codexPath, appPath.hasSuffix(".app") {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: appPath),
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }
        // CLI (TUI) fallback — open in Terminal
        let cliCandidates = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        if let cli = ([apps.codexPath].compactMap { $0 } + cliCandidates).first(where: {
            !$0.hasSuffix(".app") && FileManager.default.fileExists(atPath: $0)
        }) {
            guard !containsAppleScriptUnsafeChars(url.path), !containsAppleScriptUnsafeChars(cli) else { return }
            let safe    = shellQuoted(url.path)
            let cliSafe = shellQuoted(cli)
            let cmd = "cd \(safe) && \(cliSafe)"
            let script  = """
tell application "Terminal"
    activate
    do script \(appleScriptStringLiteral(cmd))
end tell
"""
            runAppleScript(script)
        }
    }

    // MARK: - Shared helpers

    /// Single-quote a path for shell embedding — safe against $, `, !, spaces, etc.
    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runAppleScript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try? p.run()
    }
}

// MARK: - Trash button with drop target

/// The toolbar Trash button — also accepts file drops. Drop → Move to Trash
/// (same as dragging onto Finder's Trash). Hover shows a red ring + trash badge.
private struct TrashDropButton: View {
    let trashAction: () -> Void
    let onDelete: () -> Void
    let selectedCount: Int
    let fileOps: FileOperationsService
    let onReload: () -> Void

    @State private var isTargeted = false

    private var help: String {
        if selectedCount == 0 { return "Move to Trash (⌘⌫) — or drop files here" }
        if selectedCount == 1 { return "Move to Trash (⌘⌫) — recoverable" }
        return "Move \(selectedCount) items to Trash (⌘⌫) — recoverable"
    }

    var body: some View {
        ToolbarActionButton(icon: "trash", label: help) { trashAction() }
            .disabled(selectedCount == 0 && !isTargeted)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.red, lineWidth: isTargeted ? 2 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(isTargeted ? 0.12 : 0))
                    )
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) {
                if isTargeted {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white, .red)
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onDrop(of: [.fileURL, .text],
                    delegate: TrashDropDelegate(fileOps: fileOps,
                                                onReload: onReload,
                                                isTargeted: $isTargeted))
    }
}

private struct TrashDropDelegate: DropDelegate {
    let fileOps: FileOperationsService
    let onReload: () -> Void
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo)  { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let ops = fileOps
        let reload = onReload
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            ops.trash(urls, reload: reload)
        }
        return true
    }
}

// MARK: - Toolbar button with SF Symbol icon

struct ToolbarActionButton: View {
    let icon: String; let label: String
    /// Boja ikonice kad je dugme aktivno — nil znači standardno crno/belo.
    /// Koriste je samo dugmad sa sopstvenim brendom (AI ✨, Discord ✈).
    var tint: Color? = nil
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? (tint ?? Color.primary) : Color.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
                .background(
                    FFTheme.controlShape
                        .fill(isHovering && isEnabled ? FFTheme.hoverBG : Color.clear)
                )
                .opacity(isEnabled ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Labeled toolbar button (icon + text, never icon-only)
//
// Top-5 ambiguous actions (Compress vs Extract, Copy vs Move…) use this so
// they can never be confused at a glance. Disabled state dims the whole pill.

struct LabeledToolbarButton: View {
    let icon: String
    let title: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                FFTheme.controlShape
                    .fill(isHovering && isEnabled ? FFTheme.hoverBG : Color.primary.opacity(0.05))
            )
            .opacity(isEnabled ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel("\(title). \(label)")
    }
}

// MARK: - Toolbar button with real app icon

struct AppIconToolbarButton: View {
    let appIcon: NSImage
    let label:   String
    let action:  () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}
