import SwiftUI

// MARK: - Dual-pane split (FinderFlow+ power UI)
//
// A second, independent folder pane beside the main browser. Both panes share
// the global sort/group prefs but keep their own folder and selection.
// The parent (ContentView) owns the secondary listing so cross-pane transfer
// (copy / move via FileOperationsService) sees both selections at once.
// Transfer reuses copy/cut + paste, so undo, toasts and cache invalidation
// keep working exactly like the main pane.

/// Slim header for the secondary pane: location, Up / Swap / Close.
struct SecondaryPaneHeader: View {
    @Binding var path: URL
    var onSwap: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13)).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
            Text(path.lastPathComponent.isEmpty ? "/" : path.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(path.deletingLastPathComponent().path)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            ToolbarActionButton(icon: "arrow.up", label: "Up") {
                let p = path.deletingLastPathComponent()
                if p != path { path = p }
            }
            ToolbarActionButton(icon: "arrow.left.arrow.right", label: "Swap panes") { onSwap() }
            ToolbarActionButton(icon: "xmark", label: "Close second pane") { onClose() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

/// Vertical transfer strip between the two panes.
/// Also a drop target: drop files here to transfer them across panes.
struct PaneTransferBar: View {
    let primaryCount: Int
    let secondaryCount: Int
    var onCopyToSecondary: () -> Void
    var onMoveToSecondary: () -> Void
    var onCopyToPrimary: () -> Void
    var onMoveToPrimary: () -> Void
    /// Dropped URLs are forwarded here (ContentView routes them to the other pane).
    var onDropURLs: (([URL]) -> Void)? = nil

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            ToolbarActionButton(icon: "arrow.right", label: "Copy selected → right pane (\(primaryCount))") { onCopyToSecondary() }
                .disabled(primaryCount == 0)
            ToolbarActionButton(icon: "arrow.right.to.line", label: "Move selected → right pane (\(primaryCount))") { onMoveToSecondary() }
                .disabled(primaryCount == 0)
            ToolbarActionButton(icon: "arrow.left", label: "Copy selected → left pane (\(secondaryCount))") { onCopyToPrimary() }
                .disabled(secondaryCount == 0)
            ToolbarActionButton(icon: "arrow.left.to.line", label: "Move selected → left pane (\(secondaryCount))") { onMoveToPrimary() }
                .disabled(secondaryCount == 0)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .leading) { Divider().opacity(0.6) }
        .overlay(alignment: .trailing) { Divider().opacity(0.6) }
        .overlay(
            // Drop highlight: red accent ring while files hover this strip.
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(isTargeted ? 0.10 : 0))
                )
                .allowsHitTesting(false)
        )
        .overlay(alignment: .top) {
            if isTargeted {
                DropActionPill(isCopy: false, folderName: "other pane")
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .onDrop(of: [.fileURL, .text],
                delegate: PaneTransferDropDelegate(onDropURLs: onDropURLs,
                                                   isTargeted: $isTargeted))
    }
}

private struct PaneTransferDropDelegate: DropDelegate {
    let onDropURLs: (([URL]) -> Void)?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        onDropURLs != nil && FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo)  { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let onDropURLs else { return false }
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            onDropURLs(urls)
        }
        return true
    }
}

/// The secondary browser pane. The listing is owned by the parent (shared
/// sort prefs are applied here for display so external pref changes resort
/// without a disk reload); navigation stays local except file opens.
struct SecondaryPane: View {
    @Binding var path: URL
    let files: [FileItem]
    var isLoading: Bool = false
    /// Greska citanja foldera (dozvola/nestao/Drive) — umesto laznog "prazno".
    var loadError: FolderReadError? = nil
    @Binding var selectedIDs: Set<String>
    @Binding var pendingRenameURL: URL?
    let viewMode: ViewMode
    @Binding var sortField: SortField
    @Binding var sortAscending: Bool
    let groupBy: GroupBy
    let folderOrder: FolderOrder
    let showHidden: Bool
    @ObservedObject var fileOps: FileOperationsService
    @ObservedObject var favorites: FavoritesService
    let onOpenFile: (FileItem) -> Void
    let onReload: () -> Void
    var onBatchRename: (([FileItem]) -> Void)? = nil
    var onSendToDiscord: (([FileItem]) -> Void)? = nil
    /// Folder-size publish generation from ContentView: sizing patches arrive
    /// as new FileItem copies with identical ids, so the memo key below must
    /// include it — otherwise computed sizes would never repaint here.
    var sizesVersion: UInt = 0
    /// While true, unsized folders render "…" instead of "—" in Size cells.
    var sizingActive: Bool = false

    /// Display order follows the shared prefs even when they change elsewhere.
    /// Memoized on explicit inputs (not in the getter): the old getter hashed
    /// the whole folder (O(n)) on every body eval (every selection click) and
    /// wrote @State from body via async — double render per click. Now sort
    /// runs only when files/sort prefs actually change.
    @State private var displayCache: [FileItem] = []
    @State private var displayKey = ""
    /// Broj sized itema pri poslednjem re-sortu — sizesVersion bumpovi stižu
    /// i za primarne/extra publish-eve koji ovaj pane ne dotiču; bez ovog
    /// brojača bi se veliki secondary folder re-sortirao uzalud na svaki.
    @State private var lastSizedCount = -1

    private func sizedCount(_ files: [FileItem]) -> Int {
        var n = 0
        for f in files where f.folderSize != nil { n += 1 }
        return n
    }

    private func memoKey(files: [FileItem]) -> String {
        // O(1): count + endpoints + prefs + size generation. In-place rename
        // keeps same endpoints but changes sort position — files array
        // identity changes on reload, and reload posts onChange(files) which
        // re-sorts. Selection changes don't touch `files`, so no re-sort on
        // click. sizesVersion changes on every sizing publish (same ids, new
        // folderSize copies) so sizes repaint + re-sort progressively.
        let first = files.first?.id ?? "-"
        let last = files.last?.id ?? "-"
        return "\(files.count)#\(first)#\(last)#\(sortField.rawValue)#\(sortAscending)#\(folderOrder.rawValue)#s\(sizesVersion)"
    }

    private func resortIfNeeded(files: [FileItem]) {
        let key = memoKey(files: files)
        guard key != displayKey else { return }
        displayKey = key
        displayCache = sortedItems(files, by: sortField, ascending: sortAscending, folderOrder: folderOrder)
    }

    var body: some View {
        // displayCache se odrzava kroz onChange (ispod) — body samo cita,
        // nikad ne sortira i nikad ne pise state.
        let display = displayCache.isEmpty && !files.isEmpty ? files : displayCache
        Group {
            if let err = loadError, display.isEmpty, !isLoading {
                FolderErrorView(url: path, error: err, onRetry: onReload)
            } else {
                VStack(spacing: 0) {
                    if let err = loadError, !display.isEmpty {
                        FolderErrorBanner(error: err, onRetry: onReload)
                    }
                    switch viewMode {
            case .columns:
                // Columns carry their own tree state — secondary stays a flat list.
                ListView(
                    files: display, selectedIDs: $selectedIDs,
                    pendingRenameURL: $pendingRenameURL,
                    currentPath: path,
                    sortField: $sortField, sortAscending: $sortAscending,
                    groupBy: groupBy,
                    onNavigate: navigate, onBrowseInto: { path = $0 },
                    onReload: onReload, fileOps: fileOps, favorites: favorites,
                    isLoading: isLoading && display.isEmpty,
                    onBatchRename: onBatchRename,
                    onSendToDiscord: onSendToDiscord,
                    sizingActive: sizingActive
                )
            case .list:
                ListView(
                    files: display, selectedIDs: $selectedIDs,
                    pendingRenameURL: $pendingRenameURL,
                    currentPath: path,
                    sortField: $sortField, sortAscending: $sortAscending,
                    groupBy: groupBy,
                    onNavigate: navigate, onBrowseInto: { path = $0 },
                    onReload: onReload, fileOps: fileOps, favorites: favorites,
                    isLoading: isLoading && display.isEmpty,
                    onBatchRename: onBatchRename,
                    onSendToDiscord: onSendToDiscord,
                    sizingActive: sizingActive
                )
            case .icons:
                IconsView(
                    files: display, selectedIDs: $selectedIDs,
                    currentPath: path, groupBy: groupBy,
                    onNavigate: navigate, onBrowseInto: { path = $0 },
                    onReload: onReload, fileOps: fileOps, favorites: favorites,
                    isLoading: isLoading && display.isEmpty,
                    onBatchRename: onBatchRename,
                    onSendToDiscord: onSendToDiscord,
                    sortAscending: sortAscending
                )
                }
                }
            }
        }
        .onChange(of: path) { _, _ in selectedIDs = []; onReload() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshDirectory)) { n in
            if let url = n.object as? URL, url == path { onReload() }
        }
        .onAppear { resortIfNeeded(files: files) }
        .onChange(of: files) { _, f in
            lastSizedCount = sizedCount(f)
            resortIfNeeded(files: f)
        }
        .onChange(of: sizesVersion) { _, _ in
            let n = sizedCount(files)
            guard n != lastSizedCount else { return }
            lastSizedCount = n
            resortIfNeeded(files: files)
        }
        .onChange(of: sortField) { _, _ in resortIfNeeded(files: files) }
        .onChange(of: sortAscending) { _, _ in resortIfNeeded(files: files) }
        .onChange(of: folderOrder) { _, _ in resortIfNeeded(files: files) }
    }

    private func navigate(_ item: FileItem) {
        if item.isBrowsableFolder { path = item.url }
        else { onOpenFile(item) }
    }
}
