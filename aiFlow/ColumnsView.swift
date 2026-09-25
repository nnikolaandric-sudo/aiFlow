import SwiftUI
import AppKit

private let kDefaultColWidth: CGFloat = 230
private let kMinColWidth:     CGFloat = 120
private let kPreviewWidth:    CGFloat = 260

// MARK: - Columns view (macOS Finder-style)

struct ColumnsView: View {
    @Binding var currentPath: URL
    let showHidden:     Bool
    let showColumnTree: Bool
    let groupBy:        GroupBy
    let sortField:      SortField
    let sortAscending:  Bool
    let folderOrder:    FolderOrder
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    @ObservedObject var git: GitService = .shared
    // Search support — when isSearchActive the column browser is replaced by a flat results list
    let searchResults:  [FileItem]
    let isSearchActive: Bool
    var isLoading: Bool = false
    /// Opens files the same way List/Icons do (Markdown reader, Ace, workspace).
    let onOpen: (URL) -> Void
    /// Shared selection so StatusBar/toolbar/⌘C work in Columns mode too.
    /// Nil when embedded without selection sync (previews keep working).
    var selectedIDs: Binding<Set<String>>? = nil
    /// Recursive folder sizes (opt-in): panes attach whatever the sizing run
    /// cached — no disk walk on their side. `sizesVersion` bumps on every
    /// sizing publish so panes refresh without waiting for their own reload.
    var showFolderSizes = false
    var sizesVersion: UInt = 0
    /// While true, the preview Size row renders "…" for still-unmeasured
    /// folders instead of "—".
    var sizingActive = false
    /// Arrow-key navigation (← climbs up). Off in dual-pane mode — the
    /// secondary list owns the arrows there (same rule as IconsView).
    var arrowsEnabled = true

    @State private var columns:         [URL]          = []
    @State private var colWidths:       [Int: CGFloat] = [:]
    @State private var selectedFileURL: URL?
    /// Preview column width, remembered across launches
    /// ("ffColumnsPreviewWidth"). Dragging changes @State; the value is written
    /// to settings only when the handle is released.
    @State private var previewWidth:    CGFloat        = ColumnsView.savedPreviewWidth
    private static var savedPreviewWidth: CGFloat {
        let w = UserDefaults.standard.double(forKey: "ffColumnsPreviewWidth")
        return w >= 180 ? CGFloat(w) : kPreviewWidth
    }

    var body: some View {
        if isSearchActive {
            searchResultsView
                .background(quickLookButton)
        } else {
            columnBrowserView
                .background(quickLookButton)
                .background(goUpButton)
        }
    }

    /// ← climbs to the parent folder and selects the folder we came from
    /// (Finder parity — List/Table do this natively, columns never did).
    private var goUpButton: some View {
        Button("") {
            guard arrowsEnabled, !isEditingText() else { return }
            let p = currentPath.deletingLastPathComponent()
            guard p != currentPath else { return }
            selectedIDs?.wrappedValue = [currentPath.path]
            currentPath = p
        }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .hidden()
        .accessibilityHidden(true)
    }

    /// Space → Quick Look on the shared selection (List/Icons already bind
    /// Space themselves; Columns never did, so Space was dead in this mode).
    /// `item.id` is the file path, so selectedIDs map straight to URLs.
    private var quickLookButton: some View {
        Button("") {
            guard !isEditingText() else { return }
            guard let ids = selectedIDs?.wrappedValue, !ids.isEmpty else { return }
            QuickLookController.shared.show(ids.map { URL(fileURLWithPath: $0) })
        }
        .keyboardShortcut(.space, modifiers: [])
        .hidden()
        .accessibilityHidden(true)
    }

    // MARK: - Search results flat list

    private var searchResultsView: some View {
        DropCatcher(destination: currentPath,
                    folderName: currentPath.lastPathComponent,
                    fileOps: fileOps,
                    onReload: { NotificationCenter.default.post(name: .refreshDirectory, object: currentPath) }) {
            Group {
                if searchResults.isEmpty && isLoading {
                    LoadingFolderView(folderName: currentPath.lastPathComponent)
                } else if searchResults.isEmpty {
                    EmptyFolderView(folderName: currentPath.lastPathComponent, isSearching: true,
                                    onCreateFolder: nil, onCreateFile: nil)
                } else {
                    searchResultsList
                }
            }
        }
    }

    private var searchResultsList: some View {
        List(searchResults) { item in
            FolderDropRow(item: item, fileOps: fileOps,
                          onReload: {
                              NotificationCenter.default.post(name: .refreshDirectory, object: currentPath)
                          },
                          onSpringOpen: { currentPath = $0.url }) {
                HStack(spacing: 8) {
                    FileIconView(item: item, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            if let wsBadge = WorkspaceStore.shared.badge(for: item.url) {
                                WorkspaceBadgeView(badge: wsBadge)
                            }
                            GitBadgeView(status: git.status(for: item.url), size: 9)
                            TagDotsView(colors: item.tagColors, size: 9)
                        }
                        // Lokacija umjesto pune apsolutne putanje: u rezultatima
                        // je svaki red pokazivao isti dugi „/private/tmp/…" tekst.
                        if let place = ffSearchLocation(of: item.url, relativeTo: currentPath) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(place)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .help(item.url.deletingLastPathComponent().path)
                        }
                    }
                    Spacer()
                    if item.isBrowsableFolder {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .fileDragOut(item: item, files: searchResults, selectedIDs: [item.id])
                // Double-click opens/navigates (single click only selects) —
                // a single stray click used to eject you from the search context.
                .onTapGesture {
                    selectedIDs?.wrappedValue = [item.id]
                    guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
                    if item.isBrowsableFolder {
                        currentPath = item.url
                    } else {
                        selectedFileURL = item.url
                        onOpen(item.url)
                    }
                }
            }
            .contextMenu {
                FileContextMenuContent(
                    targets: [item],
                    currentPath: currentPath,
                    fileOps: fileOps,
                    favorites: favorites,
                    onNavigate: { target in
                        if target.isBrowsableFolder { currentPath = target.url }
                        else { onOpen(target.url) }
                    },
                    onBrowseInto: { currentPath = $0 },
                    onRename: { target in
                        FileRenamePrompt.rename(target, fileOps: fileOps) {
                            NotificationCenter.default.post(name: .refreshDirectory, object: currentPath)
                        }
                    },
                    onBatchRename: nil,
                    onReload: {
                        NotificationCenter.default.post(name: .refreshDirectory, object: currentPath)
                    }
                )
            }
        }
        .listStyle(.plain)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Normal column browser

    private var columnBrowserView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { idx, dir in
                        paneAndHandle(idx: idx, dir: dir)
                    }
                    // Preview column — auto-shown when a file is selected, just like macOS Finder
                    if let fileURL = selectedFileURL {
                        ResizeHandle(
                            onDrag: { delta in previewWidth = min(900, max(180, previewWidth + delta)) },
                            onEnded: {
                                UserDefaults.standard.set(Double(previewWidth), forKey: "ffColumnsPreviewWidth")
                            },
                            onDoubleClick: {
                                previewWidth = kPreviewWidth
                                UserDefaults.standard.removeObject(forKey: "ffColumnsPreviewWidth")
                            }
                        )
                        ColumnPreviewPane(url: fileURL, showFolderSizes: showFolderSizes,
                                          sizesVersion: sizesVersion, sizingActive: sizingActive,
                                          showHidden: showHidden,
                                          onOpenFile: { onOpen($0.url) },
                                          onEnterFolder: { currentPath = $0 },
                                          onRevealFile: { revealColumnFile($0) },
                                          fileOps: fileOps,
                                          onReload: {
                                              NotificationCenter.default.post(name: .refreshDirectory, object: currentPath)
                                          })
                            .frame(width: previewWidth)
                            .id("preview")
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            }
            .onChange(of: columns) { _, cols in
                if let last = cols.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
            .onChange(of: selectedFileURL) { _, url in
                if let url {
                    selectedIDs?.wrappedValue = [url.path]
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("preview", anchor: .trailing) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Faint trailing hint when a single column leaves the right side
        // blank (overlay: zero layout impact, ignores hits; hidden once
        // deeper columns or a file preview take the space).
        .overlay(alignment: .trailing) {
            if selectedFileURL == nil && columns.count <= 1 {
                columnsHintView
            }
        }
        .onAppear       { buildColumns() }
        .onChange(of: currentPath)    { _, newPath in
            // Symlink-oblici (/tmp vs /private/tmp) su isti folder —
            // sirovi firstIndex/hasPrefix bi promašio pretka i razbio kolone.
            if let idx = columns.firstIndex(where: { ffSamePath($0, newPath) }) {
                // Navigated to an ancestor already shown (Up/Back/PathBar):
                // drop deeper columns instead of a full rebuild. The click
                // path (onSelect) already truncated, so this is idempotent.
                columns = Array(columns.prefix(idx + 1))
                if let f = selectedFileURL,
                   !ffSamePath(f, newPath) && !ffIsAncestor(path: newPath, of: f) {
                    selectedFileURL = nil
                }
            } else {
                buildColumns()
            }
        }
        .onChange(of: showColumnTree) { _, _ in buildColumns() }
        // Eksterni reveal (paste/rename/extract iz ContentView.revealFileResults)
        // postavlja samo shared selectedIDs — Columns highlight ide preko
        // selectedFileURL pa ga ovdje syncamo kad selekcija dolazi izvana.
        .onChange(of: selectedIDs?.wrappedValue ?? []) { _, new in
            guard !isSearchActive, new.count == 1, let path = new.first else { return }
            let url = URL(fileURLWithPath: path)
            // Samo djeca tekućeg foldera; inače je selekcija iz drugog
            // konteksta (search/tag) i preview se ne dira.
            guard ffSamePath(url.deletingLastPathComponent(), currentPath) else { return }
            if selectedFileURL != url { selectedFileURL = url }
        }
    }

    @ViewBuilder
    private func paneAndHandle(idx: Int, dir: URL) -> some View {
        // The last column highlights the selected file; other columns highlight the next dir.
        let highlighted: URL? = {
            if idx + 1 < columns.count { return columns[idx + 1] }
            if idx == columns.count - 1 { return selectedFileURL }
            return nil
        }()

        ColumnPane(
            directory:      dir,
            highlightedURL: highlighted,
            showHidden:     showHidden,
            groupBy:        groupBy,
            sortField:      sortField,
            sortAscending:  sortAscending,
            folderOrder:    folderOrder,
            showFolderSizes: showFolderSizes,
            sizesVersion:   sizesVersion,
            onSelect: { selected in
                if selected.isBrowsableFolder {
                    columns = Array(columns.prefix(idx + 1)) + [selected.url]
                    currentPath = selected.url
                    selectedFileURL = nil
                    selectedIDs?.wrappedValue = [selected.id]
                } else {
                    columns = Array(columns.prefix(idx + 1))
                    selectedFileURL = selected.url
                    selectedIDs?.wrappedValue = [selected.id]
                }
            },
            onBrowseInto: { url in
                columns = Array(columns.prefix(idx + 1)) + [url]
                currentPath = url
                selectedFileURL = nil
            },
            onOpen: onOpen,
            fileOps:   fileOps,
            favorites: favorites,
            isActivePane: idx == columns.count - 1
        )
        .frame(width: colWidths[idx, default: kDefaultColWidth], alignment: .topLeading)
        .id(idx)

        ResizeHandle(
            onDrag: { delta in
                let current = colWidths[idx, default: kDefaultColWidth]
                colWidths[idx] = max(kMinColWidth, current + delta)
            },
            // Double-click restores the default column width.
            onDoubleClick: { colWidths[idx] = nil }
        )
    }

    /// Faint "nothing selected" hint for the blank trailing area.
    /// Same visual language as the preview panel's empty state.
    private var columnsHintView: some View {
        FFEmptyPreview(symbol: "doc.text.magnifyingglass",
                       title: "No selection",
                       message: "Pick a file to preview it.",
                       compact: true)
            .frame(width: 220)
            .padding(.trailing, 32)
            .allowsHitTesting(false)
    }

    // NOTE: ranije je ovde postojao mrtav columnContextMenu(item:directory:)
    // (nikad pozvan — ColumnPane ima svoj) sa bagovitim reload: {} — obrisan
    // da ga neko slucajno ne ozivi.

    /// Workspace relation jump (§10): selects the file in the column
    /// browser, rebuilding columns first when it lives in another branch.
    private func revealColumnFile(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if !ffSamePath(parent, currentPath) {
            currentPath = parent
            let target = url
            DispatchQueue.main.async {
                selectedFileURL = target
                selectedIDs?.wrappedValue = [target.path]
            }
        } else {
            selectedFileURL = url
            selectedIDs?.wrappedValue = [url.path]
        }
    }

    private func buildColumns() {
        // Prelaz iz List/Icons sa selekcijom je brisao preview (nil pa nikad
        // restore jer onChange ne okine na istu vrijednost) — sacuvaj pa vrati
        // ako selekcija i dalje pripada tekucem folderu.
        let preserved: URL? = {
            if let url = selectedFileURL,
               ffSamePath(url.deletingLastPathComponent(), currentPath) { return url }
            if let ids = selectedIDs?.wrappedValue, ids.count == 1, let path = ids.first {
                let url = URL(fileURLWithPath: path)
                if ffSamePath(url.deletingLastPathComponent(), currentPath),
                   !FileItem.isBrowsableFolder(url) { return url }
            }
            return nil
        }()
        selectedFileURL = preserved
        guard showColumnTree else {
            // Default: show only the current folder, no ancestor tree
            columns = [currentPath]
            return
        }        // Full ancestor chain up to root
        var path  = currentPath
        var paths = [path]
        while path.pathComponents.count > 1 {
            path = path.deletingLastPathComponent()
            paths.insert(path, at: 0)
        }
        columns = paths
    }
}

// MARK: - Preview column (mirrors Finder's rightmost preview pane)

struct ColumnPreviewPane: View {
    let url: URL
    var showFolderSizes = false
    var sizesVersion: UInt = 0
    var sizingActive = false
    var showHidden = false
    var onOpenFile: (FileItem) -> Void = { _ in }
    var onEnterFolder: (URL) -> Void = { _ in }
    /// Selects a file in the column browser (workspace relation jumps, §10).
    var onRevealFile: (URL) -> Void = { _ in }
    /// Drag & drop u preview koloni: redovi se povlace van, drop na
    /// foldere/pocinje premjesta — isto kao glavni preview panel.
    /// Optional da stari call site-ovi ostanu kompajlirani.
    var fileOps: FileOperationsService? = nil
    var onReload: (() -> Void)? = nil
    @ObservedObject var workspaces: WorkspaceStore = .shared
    @ObservedObject var git: GitService = .shared
    @State private var item: FileItem?
    @State private var gitTab: GitPreviewTab = .diff

    private func load() {
        guard var loaded = FileItem.load(from: url) else { item = nil; return }
        if showFolderSizes,
           loaded.isBrowsableFolder, loaded.folderSize == nil,
           let hit = FolderSizeService.shared.cachedSize(for: url) {
            loaded = loaded.withFolderSize(hit)
        }
        item = loaded
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                if let root = git.repoRoot(for: item.url) {
                    gitPreview(item: item, root: root)
                } else if item.isBrowsableFolder, workspaces.isWorkspace(item.url),
                   let ws = workspaces.workspace(at: item.url) {
                    // Workspace root → whole-project overview (§3).
                    WorkspaceOverviewView(workspaceID: ws.id, rootURL: item.url,
                                          onRevealFile: onRevealFile,
                                          onEnterFolder: onEnterFolder,
                                          fileOps: fileOps,
                                          onReload: onReload)
                } else if let found = workspaces.enclosingWorkspace(for: item.url) {
                    if item.isBrowsableFolder {
                        WorkspaceSubfolderBanner(workspaceID: found.workspace.id, rootURL: found.root) {
                            onEnterFolder(found.root)
                        }
                        FolderContentsPreview(
                            item: item,
                            showHidden: showHidden,
                            onOpenFile: onOpenFile,
                            onEnterFolder: onEnterFolder,
                            onRevealInMain: { onEnterFolder(item.url) },
                            fileOps: fileOps,
                            onDropReload: onReload
                        )
                    } else if let rel = workspaces.relativePath(of: item.url, to: found.root) {
                        workspaceFilePreview(item: item, ws: found.workspace,
                                             root: found.root, relative: rel)
                    } else {
                        legacyPreview(item: item)
                    }
                } else if item.isBrowsableFolder {
                    FolderContentsPreview(
                        item: item,
                        showHidden: showHidden,
                        onOpenFile: onOpenFile,
                        onEnterFolder: onEnterFolder,
                        onRevealInMain: { onEnterFolder(item.url) },
                        fileOps: fileOps,
                        onDropReload: onReload
                    )
                    Divider().opacity(0.6)
                    Button("Enable Workspace") {
                        workspaces.enableWorkspace(at: item.url)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.vertical, 8)
                } else {
                    legacyPreview(item: item)
                }
            } else {
                FFEmptyPreview(symbol: "doc.text.magnifyingglass",
                               title: "No selection",
                               message: "Pick a file and its preview shows up here.",
                               hint: ("Space", "Quick Look"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear   { load() }
        .onChange(of: url) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowDiff)) { n in
            if let request = n.object as? URL, request == url { gitTab = .diff }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowHistory)) { n in
            if let request = n.object as? URL, request == url { gitTab = .history }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ffGitShowRepo)) { n in
            if let request = n.object as? URL, request == url || request == url.deletingLastPathComponent() { gitTab = .repo }
        }
        .onChange(of: sizesVersion) { _, _ in
            // Sizing run je keširao veličinu u međuvremenu — pokupi bez reload-a.
            if showFolderSizes, let current = item,
               current.isBrowsableFolder, current.folderSize == nil,
               let hit = FolderSizeService.shared.cachedSize(for: url) {
                item = current.withFolderSize(hit)
            }
        }
    }

    @ViewBuilder
    private func gitPreview(item: FileItem, root: URL) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $gitTab) {
                Text("Preview").tag(GitPreviewTab.preview)
                Text("Diff").tag(GitPreviewTab.diff)
                Text("History").tag(GitPreviewTab.history)
                Text("Repo").tag(GitPreviewTab.repo)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider().opacity(0.6)
            switch gitTab {
            case .preview:
                legacyPreview(item: item)
            case .diff:
                GitFileDiffView(url: item.url, onReload: {
                    NotificationCenter.default.post(name: .refreshDirectory, object: item.url.deletingLastPathComponent())
                })
            case .history:
                GitHistoryView(url: item.url, root: root)
            case .repo:
                GitRepoPanel(root: root, onRevealFile: onRevealFile, onReload: {
                    NotificationCenter.default.post(name: .refreshDirectory, object: root)
                })
            }
        }
    }

    /// File inside a workspace: compact QuickLook + the same work tabs as
    /// the sidebar preview (§5). The column is narrow but the panel is a
    /// plain VStack, so it adapts (widen with the preview handle if needed).
    @ViewBuilder
    private func workspaceFilePreview(item: FileItem, ws: Workspace,
                                      root: URL, relative: String) -> some View {
        DebouncedQLPreview(item: item)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 220)
            .clipShape(FFTheme.cardShape)
            .padding([.horizontal, .top], 8)
        Divider().opacity(0.6)
        WorkspaceFilePanel(workspaceID: ws.id, rootURL: root,
                           fileURL: item.url, relative: relative,
                           onRevealFile: onRevealFile,
                           fileOps: fileOps,
                           onReload: onReload)
    }

    /// Original non-workspace file preview, kept as-is.
    @ViewBuilder
    private func legacyPreview(item: FileItem) -> some View {
                    // Previews for files/archives show QL, same as before — the
                    // debounced wrapper only gates generation timing + 100MB skip.
                    // Inset + radius like the main preview panel.
                    DebouncedQLPreview(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(FFTheme.cardShape)
                    .padding([.horizontal, .top], 8)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        FileIconView(item: item, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(2)
                                .truncationMode(.middle)
                            TagDotsView(colors: item.tagColors, size: 9)
                        }
                    }
                    .fileDragOutURLs([item.url])
                    .help("Drag to move/copy “\(item.name)” into another pane, tab or folder")
                    Divider().opacity(0.6)
                    FFKindRow(item: item)
                    FFSizeRow(item: item, size: item.displaySize(sizingActive: sizingActive))
                    detailRow("Modified", item.formattedDateModified)
                    detailRow("Created",  item.formattedDateCreated)
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

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":").font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value).font(.caption).lineLimit(2)
        }
    }
}

// MARK: - Drag handle (column panes + preview panels)
//
// The handle is an AppKit view, not a SwiftUI DragGesture. The old gesture
// version had two faults, and together they are why the right-hand preview
// "had a line but wouldn't resize":
//   • the gesture hung on an 8 pt `Color.clear` strip — a transparent surface
//     with no contentShape doesn't reliably take the click, so the drag often
//     never started (the cursor still changed, because a separate
//     NSTrackingArea set it);
//   • when it did start, it measured movement in the handle's LOCAL
//     coordinates, and the handle moves along with the pane it resizes, so
//     the measured movement drifted and the pane lagged/jittered behind the
//     pointer.
// An NSView receives mouseDown/mouseDragged/mouseUp directly and measures in
// WINDOW coordinates, which don't move. The same view drives the cursor.
//
// Cursor: NOT via addCursorRect — AppKit suppresses cursor rects during a drag,
// so the resize cursor would stay stuck after releasing over the file list.
// Instead: enter/exit + cursorUpdate on a tracking area (the handle is the
// hit-test target, so it beats ArrowCursorArea underneath) plus explicit
// sets on mouseDown/Dragged/Up: the arrow comes back the moment there is
// nothing left to drag.

/// Shared column/preview-pane drag handle. Draws its own separator line.
struct ResizeHandle: View {
    /// Movement since the previous drag event, in points (+ = right).
    let onDrag: (CGFloat) -> Void
    /// Drag start (e.g. remember the starting width).
    var onBegan: (() -> Void)? = nil
    /// Total movement since mouse-down — stays exact even when the target
    /// hits its limit, so backing out of an overshoot responds immediately.
    var onTotal: ((CGFloat) -> Void)? = nil
    /// Drag end (e.g. write the width to settings — once, not on every move).
    var onEnded: (() -> Void)? = nil
    /// Double-click on the handle (e.g. restore the default width).
    var onDoubleClick: (() -> Void)? = nil

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        _ResizeHandleRepresentable(
            onHover: { hovering = $0 },
            onBegan: { dragging = true; onBegan?() },
            onChanged: { total, delta in
                if delta != 0 { onDrag(delta) }
                onTotal?(total)
            },
            onEnded: { dragging = false; onEnded?() },
            onDoubleClick: onDoubleClick
        )
        .frame(width: 8)
        // Line behind the (transparent) NSView: thin while idle, accent on
        // hover, thicker while dragging — you can see what you are holding.
        .background(
            Rectangle()
                .fill(hovering || dragging
                      ? Color.accentColor.opacity(dragging ? 0.9 : 0.7)
                      : Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: dragging ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: hovering || dragging)
    }
}

private struct _ResizeHandleRepresentable: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onBegan: () -> Void
    var onChanged: (_ total: CGFloat, _ delta: CGFloat) -> Void
    var onEnded: () -> Void
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> _ResizeHandleNSView { _ResizeHandleNSView() }

    func updateNSView(_ v: _ResizeHandleNSView, context: Context) {
        v.onHover = onHover
        v.onBegan = onBegan
        v.onChanged = onChanged
        v.onEnded = onEnded
        v.onDoubleClick = onDoubleClick
        v.toolTip = onDoubleClick == nil
            ? "Drag to resize"
            : "Drag to resize · double-click to restore the default width"
    }
}

final class _ResizeHandleNSView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    var onChanged: (_ total: CGFloat, _ delta: CGFloat) -> Void = { _, _ in }
    var onEnded: () -> Void = {}
    var onDoubleClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var dragging = false
    private var startX: CGFloat = 0
    private var lastX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    // Grabbing the handle must never drag the window along with it.
    override var mouseDownCanMoveWindow: Bool { false }
    // The first click in an inactive window already grabs the handle.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // .inVisibleRect follows the view's visible part on its own;
        // .enabledDuringMouseDrag keeps hover accurate while resizing.
        let ta = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp,
                      .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        // While resizing, the pointer may run ahead of the 8 pt handle — the
        // cursor has to stay the resize cursor until the button is released.
        if !dragging { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, let onDoubleClick {
            dragging = false
            onDoubleClick()
            return
        }
        dragging = true
        startX = event.locationInWindow.x
        lastX = startX
        NSCursor.resizeLeftRight.set()
        onBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let x = event.locationInWindow.x
        let delta = x - lastX
        lastX = x
        NSCursor.resizeLeftRight.set()
        onChanged(x - startX, delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnded()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setHovering(inside)
        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        onHover(value)
    }
}

// MARK: - Column pane

struct ColumnPane: View {
    let directory:      URL
    let highlightedURL: URL?
    let showHidden:     Bool
    let groupBy:        GroupBy
    let sortField:      SortField
    let sortAscending:  Bool
    let folderOrder:    FolderOrder
    /// Recursive folder sizes (opt-in, forwarded from ColumnsView): the pane
    /// never walks the disk itself — it attaches stamp-validated cache hits
    /// on reload and re-attaches whenever `sizesVersion` bumps (the sizing
    /// run in ContentView fills the cache for the active folder).
    var showFolderSizes = false
    var sizesVersion: UInt = 0
    let onSelect:       (FileItem) -> Void
    let onBrowseInto:   (URL) -> Void
    let onOpen:         (URL) -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    /// Workspace bedževi (§13): verzija se spušta redovima da `.equatable()`
    /// redovi preslikaju kad task/review/expiry/share stigne.
    @ObservedObject var workspaces: WorkspaceStore = .shared
    @ObservedObject var git: GitService = .shared
    /// ↑/↓ act only in the last (active) pane — every pane registers the
    /// shortcut, the guard picks the live one.
    var isActivePane = false

    @State private var items: [FileItem] = []
    /// Highlight ide preko malog objekta, ne kroz ulaze redova: klik mijenja
    /// samo njega, pa se redovi cijelog foldera ne grade iznova (vidi
    /// `ColumnPaneRows`). Preslikava se iz `highlightedURL` u `onChange`.
    @StateObject private var highlight = ColumnHighlightState()
    /// Akcije reda u referenci — closure koji hvata pane je nova adresa na
    /// svaku evaluaciju, pa bi SwiftUI svaki put gradio sve redove.
    @State private var rowActions = ColumnRowActions()
    @State private var reloadGeneration: UInt = 0
    @State private var isLoadingPane: Bool = true
    /// Greska citanja foldera (dozvola/nestao/Drive) — umesto laznog "prazno".
    @State private var loadError: FolderReadError? = nil

    // O(1) po kliku: highlight menja body, ali ne i listing — stari put je
    // na svaku selekciju heširao ceo folder (contentSignature, O(n)) samo da
    // bi memo proverio pogodak. reloadGeneration se bumpuje samo na reload/
    // re-sort, pa selekcija pogađa keš bez ikakvog heširanja.
    // (folderSize ne utiče na grupe: SizeBand svrstava foldere u .folders bez
    // obzira na rekurzivnu veličinu, pa sizing publish ne mora da invalidira.)
    private var groups: [FileGroup] {
        groupedItems(items, by: groupBy, identity: reloadGeneration, ascending: sortAscending)
    }

    var body: some View {
        Group {
            if let err = loadError, items.isEmpty, !isLoadingPane {
                FolderErrorView(url: directory, error: err, onRetry: { reload(refresh: true) })
            } else if items.isEmpty && isLoadingPane {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                // Prazan folder u kolonama je bio prazna bela traka bez poruke —
                // isti EmptyFolderView kao list/icons, kompaktan za usku kolonu.
                EmptyFolderView(folderName: directory.lastPathComponent,
                                isSearching: false,
                                onCreateFolder: nil, onCreateFile: nil)
            } else {
                VStack(spacing: 0) {
                    if let err = loadError {
                        FolderErrorBanner(error: err, onRetry: { reload(refresh: true) })
                    }
                    paneList
                }
            }
        }
        // Initial load + directory/showHidden changes live HERE (not on
        // paneList): paneList only exists once items are non-empty, so the
        // old pair (body.onAppear + paneList.onAppear) double-reloaded every
        // cold open and missed directory changes while still empty.
        .onAppear {
            highlight.url = highlightedURL
            reload(refresh: true)
        }
        .onChange(of: highlightedURL) { _, url in highlight.url = url }
        .onChange(of: directory)  { _, _ in reload(refresh: true) }
        .onChange(of: showHidden) { _, _ in reload(refresh: true) }
        // Sizing run je upisao nove veličine u keš — pokupi ih bez reload-a
        // sa diska (samo stat-validirani lookup + re-sort po potrebi).
        .onChange(of: sizesVersion) { _, _ in refreshCachedSizes() }
        .onChange(of: showFolderSizes) { _, enabled in
            if enabled { refreshCachedSizes() }
            else if items.contains(where: { $0.folderSize != nil }) {
                let stripped = items.map { $0.folderSize == nil ? $0 : $0.withFolderSize(nil) }
                // Bez re-sorta bi ostao redosled po (sada obrisanim) rekurzivnim
                // veličinama dok se pane ne reloada iz drugog razloga.
                items = sortField == .size
                    ? sortedItems(stripped, by: sortField, ascending: sortAscending, folderOrder: folderOrder)
                    : stripped
            }
        }
        // ↑/↓ step through this pane (same as tap → onSelect). Hidden buttons
        // live in every pane; only the active (last) one acts.
        .background(
            Group {
                Button("") { stepSelection(-1) }
                    .keyboardShortcut(.upArrow, modifiers: []).hidden()
                Button("") { stepSelection(1) }
                    .keyboardShortcut(.downArrow, modifiers: []).hidden()
            }
        )
    }

    /// ↑/↓ moves highlight within this pane and selects via onSelect (folders
    /// drill in, files preview — identical to tap semantics).
    private func stepSelection(_ dir: Int) {
        guard isActivePane, !isEditingText(), !items.isEmpty else { return }
        let cur = items.firstIndex(where: { $0.url == highlight.url }) ?? (dir > 0 ? -1 : items.count)
        let next = min(max(cur + dir, 0), items.count - 1)
        onSelect(items[next])
    }

    /// Re-attaches cached folder sizes to the current items (no disk walk).
    /// `==` ignores folderSize by design, so the change check compares the
    /// size channel explicitly — otherwise cache fills would never repaint.
    private func refreshCachedSizes() {
        guard showFolderSizes else { return }
        let attached = FolderSizeService.attachingCachedSizes(to: items)
        guard attached.map(\.folderSize) != items.map(\.folderSize) else { return }
        items = sortField == .size
            ? sortedItems(attached, by: sortField, ascending: sortAscending, folderOrder: folderOrder)
            : attached
    }

    /// Cache-attach wrapper for reload publishes: sorted AFTER attaching so
    /// a Size sort is correct the moment the pane paints.
    private func sized(_ list: [FileItem]) -> [FileItem] {
        showFolderSizes ? FolderSizeService.attachingCachedSizes(to: list) : list
    }

    private var paneList: some View {
        DropCatcher(destination: directory,
                    folderName: directory.lastPathComponent,
                    fileOps: fileOps,
                    onReload: { reload(refresh: true) }) {
            paneListContent
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshDirectory)) { notif in
            if let url = notif.object as? URL, url == directory { reload(refresh: true) }
        }
    }

    private var paneListContent: some View {
        // Akcije se osvježavaju u referenci (ista adresa kroz cio život pane-a),
        // pa ulazi redova ostaju nepromijenjeni i kad se ovo tijelo evaluira.
        rowActions.update(fileOps: fileOps, favorites: favorites, directory: directory,
                          onReload: { reload(refresh: true) },
                          onSelect: onSelect, onBrowseInto: onBrowseInto, onOpen: onOpen,
                          onRename: { promptRename(item: $0) })
        // NE umotavati u `.equatable()` — EquatableView unutar `List` spljošti
        // sav sadržaj u JEDAN red (provjereno).
        return List {
            ColumnPaneRows(items: items, groups: groups, grouped: groupBy != .none,
                           listGeneration: reloadGeneration,
                           highlight: highlight, actions: rowActions,
                           workspaceVersion: workspaces.version, gitVersion: git.version)
        }
        .listStyle(.plain)
        // Background right-click (empty space or empty folder)
        .contextMenu {
            FileBackgroundMenuContent(fileOps: fileOps, currentPath: directory, onReload: { reload(refresh: true) })
        }
        // directory/showHidden reloads moved to body (see above) — the old
        // paneList.onAppear + body.onAppear pair double-loaded every pane.
        .onChange(of: sortField)     { _, _ in reload(refresh: false) }
        .onChange(of: sortAscending) { _, _ in reload(refresh: false) }
        .onChange(of: folderOrder)   { _, _ in reload(refresh: false) }
    }

    // MARK: - Helpers

    private func reload(refresh: Bool = true) {
        reloadGeneration &+= 1
        let gen    = reloadGeneration
        let field  = sortField
        let asc    = sortAscending
        let fold   = folderOrder
        let hidden = showHidden
        let dir    = directory
        loadError = nil
        if let snapshot = DirectoryCache.shared.cachedItems(for: dir, showHidden: hidden) {
            // Veliki folder (>2k): sync sort bi zamrznuo main na localizedCompare
            // lavini — sort + revalidacija u pozadini uz jedan publish, bez
            // brisanja starog prikaza (bez flasha praznog pane-a + duplog diffa).
            if snapshot.count > 2000 {
                isLoadingPane = true
                guard refresh else {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let sorted = sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold)
                        DispatchQueue.main.async {
                            guard gen == reloadGeneration else { return }
                            items = sized(sorted)
                            isLoadingPane = false
                        }
                    }
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let sorted = sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold)
                    let res = loadFreshItems(at: dir, showHidden: hidden)
                    let fresh = sortedItems(res.items,
                                            by: field, ascending: asc, folderOrder: fold)
                    let final = (fresh != sorted) ? fresh : sorted
                    DispatchQueue.main.async {
                        guard gen == reloadGeneration else { return }
                        // Same-list guard: re-publishing an identical array still
                        // rebuilds every visible row (SwiftUI diff by identity).
                        // (== ignores folderSize; cache freshness arrives via
                        // sizesVersion instead — no disk walk here.)
                        if final != items { items = sized(final) }
                        isLoadingPane = false
                        loadError = res.error
                    }
                }
                return
            }
            items = sized(sortedItems(snapshot, by: field, ascending: asc, folderOrder: fold))
            isLoadingPane = false
            guard refresh else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let res = loadFreshItems(at: dir, showHidden: hidden)
                let fresh = sortedItems(res.items,
                                        by: field, ascending: asc, folderOrder: fold)
                DispatchQueue.main.async {
                    guard gen == reloadGeneration else { return }
                    // Same-list guard: re-publishing an identical array still
                    // rebuilds every visible row (SwiftUI diff by identity).
                    if fresh != items { items = sized(fresh) }
                    loadError = res.error
                }
            }
            return
        }
        if items.isEmpty { isLoadingPane = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let res = loadItems(at: dir, showHidden: hidden)
            let loaded = sortedItems(res.items,
                                     by: field, ascending: asc, folderOrder: fold)
            DispatchQueue.main.async {
                guard gen == reloadGeneration else { return }
                items = sized(loaded)
                isLoadingPane = false
                loadError = res.error
            }
        }
    }

    private func showGetInfo(item: FileItem) {
        showGetInfoInFinder([item.url])
    }

    private func promptRename(item: FileItem) {
        FileRenamePrompt.rename(item, fileOps: fileOps) { reload(refresh: true) }
    }
}

// MARK: - Redovi kolone (odvojeni od pane-a)
//
// Zašto: pane se evaluira na svaki klik (highlight, nove closure iz roditelja),
// a dok su redovi bili u njemu, svaki klik je gradio redove CIJELOG foldera
// (izmjereno: 530-890 ms zaključane glavne niti u folderu od 8k fajlova).
// Ovdje nema nijednog closure-a koji hvata pane — sve što se mijenja ide kroz
// reference (`actions`, `highlight`) — pa SwiftUI ove ulaze vidi kao
// nepromijenjene i preskače ih.
private struct ColumnPaneRows: View {
    let items:          [FileItem]
    let groups:         [FileGroup]
    let grouped:        Bool
    /// Mijenja se samo na reload/re-sort — ne na klik.
    let listGeneration: UInt
    let highlight:      ColumnHighlightState
    let actions:        ColumnRowActions
    /// Verzija Workspace store-a (§13): red se preslika kad task/review/
    /// expiry/share stigne; bedž se čita u telu reda, ne ovde.
    let workspaceVersion: UInt
    let gitVersion: UInt

    var body: some View {
        if grouped {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in rowFor(item) }
                } header: {
                    DateSectionHeader(title: group.title, count: group.items.count)
                }
            }
        } else {
            ForEach(items) { item in rowFor(item) }
        }
    }

    @ViewBuilder
    private func rowFor(_ item: FileItem) -> some View {
        FolderDropRow(item: item, fileOps: actions.fileOps,
                      onReload: actions.onReload,
                      onSpringOpen: actions.onSelect) {
            // Highlight čita sam red iz `highlight` — ovdje ga namjerno nema,
            // da klik ne mijenja ulaze redova.
            ColumnRow(item: item, highlight: highlight, workspaceVersion: workspaceVersion, gitVersion: gitVersion)
                .equatable()
        }
            .contentShape(Rectangle())
            // Selekcija u kolonama je uvijek jedna stavka, a `urlsForDrag` za
            // jednu stavku ionako vraća samo nju — zato prazan skup.
            .fileDragOut(item: item, files: items, selectedIDs: [])
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if item.isBrowsableFolder {
                    actions.onSelect(item)
                } else {
                    actions.onOpen(item.url)
                }
            })
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                actions.onSelect(item)
            })
            .contextMenu { columnContextMenu(item: item) }
    }

    @ViewBuilder
    private func columnContextMenu(item: FileItem) -> some View {
        FileContextMenuContent(
            targets: [item],
            currentPath: actions.directory,
            fileOps: actions.fileOps,
            favorites: actions.favorites,
            onNavigate: { target in
                if target.isBrowsableFolder { actions.onSelect(target) }
                else { actions.onOpen(target.url) }
            },
            onBrowseInto: actions.onBrowseInto,
            onRename: { actions.onRename($0) },
            onBatchRename: nil,
            onReload: actions.onReload
        )
    }
}

/// Koji red je označen u ovoj koloni. Red ga posmatra sam, pa se na klik
/// preslikaju samo nacrtani redovi, a ne cijeli folder.
final class ColumnHighlightState: ObservableObject {
    @Published var url: URL?
}

/// Akcije reda u referenci (vidi `ColumnPaneRows`).
final class ColumnRowActions {
    /// Postavlja ih pane prije nego što se ijedan red nacrta (vidi `update`).
    private(set) var fileOps: FileOperationsService!
    private(set) var favorites: FavoritesService!
    private(set) var directory: URL = URL(fileURLWithPath: "/")
    private(set) var onReload: () -> Void = {}
    private(set) var onSelect: (FileItem) -> Void = { _ in }
    private(set) var onBrowseInto: (URL) -> Void = { _ in }
    private(set) var onOpen: (URL) -> Void = { _ in }
    private(set) var onRename: (FileItem) -> Void = { _ in }

    func update(fileOps: FileOperationsService, favorites: FavoritesService, directory: URL,
                onReload: @escaping () -> Void, onSelect: @escaping (FileItem) -> Void,
                onBrowseInto: @escaping (URL) -> Void, onOpen: @escaping (URL) -> Void,
                onRename: @escaping (FileItem) -> Void) {
        self.fileOps = fileOps; self.favorites = favorites; self.directory = directory
        self.onReload = onReload; self.onSelect = onSelect
        self.onBrowseInto = onBrowseInto; self.onOpen = onOpen; self.onRename = onRename
    }
}

// MARK: - Column row

struct ColumnRow: View {
    let item:          FileItem
    /// Posmatra se: klik mijenja samo ovaj objekat, pa se preslikaju redovi
    /// koji se stvarno crtaju, a ne cijeli folder.
    @ObservedObject var highlight: ColumnHighlightState
    /// Verzija Workspace store-a (§13): bedž se računa u `body` (samo za
    /// nacrtane redove), a ovo polje tjera preslikavanje kad podaci stignu.
    var workspaceVersion: UInt = 0
    var gitVersion: UInt = 0
    @State private var hovering = false
    @Environment(\.ffCompactRows) private var compact

    var body: some View {
        let isHighlighted = highlight.url == item.url
        let wsBadge = WorkspaceStore.shared.badge(for: item.url)
        let gitStatus = GitService.shared.status(for: item.url)
        return HStack(spacing: 8) {
            FileIconView(item: item, size: 16)
                .frame(width: 20, height: 20)
            Text(item.name)
                .font(.system(size: 12, weight: isHighlighted ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if let wsBadge {
                WorkspaceBadgeView(badge: wsBadge)
            }
            GitBadgeView(status: gitStatus, size: 9)
            TagDotsView(colors: item.tagColors, size: 9)
            Spacer(minLength: 4)
            if item.isBrowsableFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.vertical, compact ? 2 : 3)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .help(item.url.path)
        .background(
            FFTheme.controlShape
                .fill(isHighlighted ? Color.accentColor.opacity(0.16)
                      : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            FFTheme.controlShape
                .strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.30 : 0), lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }
}

extension ColumnRow: Equatable {
    // Same as GroupedRow: skip rows whose content + highlight state is
    // unchanged when the pane rebuilds on selection change.
    static func == (lhs: ColumnRow, rhs: ColumnRow) -> Bool {
        lhs.item == rhs.item && lhs.highlight === rhs.highlight
            && lhs.workspaceVersion == rhs.workspaceVersion
            && lhs.gitVersion == rhs.gitVersion
    }
}
