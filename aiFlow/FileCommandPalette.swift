import AppKit
import Carbon
import SwiftUI

// MARK: - File command palette (⌘F)
//
// Compact Attach-style file finder docked above the status bar. It searches
// the whole Mac, lets the user browse into folders, mark several files or
// folders, drag them out to Mail/browsers/Finder, copy them, or create a
// quick link. Enter opens the active file or browses into the active folder.

final class FileCommandPaletteModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var results: [URL] = []
    @Published var isSearching = false
    @Published var recentFiles: [URL] = []
    @Published var downloads: [URL] = []
    @Published var pinned: [URL] = []
    @Published var recentFolders: [URL] = []
    @Published var initialFolder: URL?
    @Published private(set) var browsing: URL?
    @Published private(set) var folderItems: [URL] = []
    private(set) var knownDirectories = Set<URL>()

    static let browseDisplayLimit = 500
    static let searchDisplayLimit = 100

    private var metaQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private var browseToken = 0

    func appeared(initialFolder: URL?) {
        updateInitialFolder(initialFolder)
        reloadStatic()
        loadDownloads()
        scheduleSearch()
    }

    func updateInitialFolder(_ folder: URL?) {
        initialFolder = folder
        if let folder, FileManager.default.fileExists(atPath: folder.path) {
            knownDirectories.insert(folder)
        }
    }

    func reloadStatic() {
        let fm = FileManager.default
        recentFiles = MailAttachPrefs.showRecent ? MailAttachPrefs.recentFiles() : []
        let pinPaths = MailAttachPrefs.showFavorites
            ? (UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? []) : []
        pinned = pinPaths.map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        let recPaths = MailAttachPrefs.showFavorites
            ? (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []) : []
        let pinnedSet = Set(pinned.map(\.path))
        recentFolders = recPaths.map { URL(fileURLWithPath: $0) }
            .filter { !pinnedSet.contains($0.path) && fm.fileExists(atPath: $0.path) }
        knownDirectories.formUnion(pinned)
        knownDirectories.formUnion(recentFolders)
        if let initialFolder, fm.fileExists(atPath: initialFolder.path) {
            knownDirectories.insert(initialFolder)
        }
    }

    private func loadDownloads() {
        guard MailAttachPrefs.showRecent else { downloads = []; return }
        let recent = Set(recentFiles)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .contentModificationDateKey]
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            func added(_ u: URL) -> Date {
                let v = try? u.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
                return v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
            }
            let latest = items
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !recent.contains($0) }
                .sorted { added($0) > added($1) }
                .prefix(6)
            let top = Array(latest)
            top.forEach { MailAttachRowInfo.preload($0) }
            DispatchQueue.main.async { self?.downloads = top }
        }
    }

    func isFolder(_ url: URL) -> Bool {
        if knownDirectories.contains(url) { return true }
        if let info = MailAttachRowInfo.cached(url) {
            return info.isDirectory && FileItem.isBrowsableFolder(url)
        }
        return FileItem.isBrowsableFolder(url)
    }

    // MARK: Folder browse

    func browse(_ folder: URL?) {
        browseToken += 1
        let token = browseToken
        browsing = folder
        folderItems = []
        query = ""
        results = []
        guard let folder else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            let dirs = items.filter { isDir($0) && FileItem.isBrowsableFolder($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let files = items.filter { !dirs.contains($0) }.sorted { date($0) > date($1) }
            DispatchQueue.main.async {
                guard let self, self.browseToken == token else { return }
                self.knownDirectories.formUnion(dirs)
                self.folderItems = dirs + files
                self.scheduleSearch()
            }
        }
    }

    func browseUp() {
        guard let b = browsing else { return }
        let parent = b.deletingLastPathComponent()
        let isRoot = pinned.contains(b) || recentFolders.contains(b) || parent.path == b.path
        browse(isRoot ? nil : parent)
    }

    // MARK: Search

    private func scheduleSearch() {
        debounce?.cancel()
        stopSpotlight()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let _ = browsing {
            results = q.isEmpty
                ? Array(folderItems.prefix(Self.browseDisplayLimit))
                : FuzzySearch.rankedFilter(urls: folderItems, query: q, limit: Self.browseDisplayLimit)
            isSearching = false
            return
        }
        guard !q.isEmpty else { results = []; isSearching = false; return }
        guard MailAttachPrefs.showSearch else { results = []; isSearching = false; return }
        results = []
        isSearching = true
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.startSpotlight(query: q) }
        }
    }

    private func startSpotlight(query q: String) {
        stopSpotlight()
        isSearching = true
        let mq = NSMetadataQuery()
        mq.searchScopes = [NSMetadataQueryLocalComputerScope]
        if q.hasPrefix(".") {
            let ext = String(q.dropFirst()).split(separator: " ").first.map(String.init) ?? ""
            guard !ext.isEmpty else { isSearching = false; return }
            mq.predicate = NSPredicate(format: "kMDItemFSExtension ==[cd] %@", ext)
        } else {
            mq.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, q)
        }
        mq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        let collect: (Notification) -> Void = { [weak self, weak mq] _ in
            self?.collect(from: mq, query: q)
        }
        observers = [
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: mq, queue: .main, using: collect),
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: mq, queue: .main, using: collect),
        ]
        mq.start()
        metaQuery = mq
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak mq] in
            guard let self, let mq, self.metaQuery === mq else { return }
            self.isSearching = false
        }
    }

    private func collect(from mq: NSMetadataQuery?, query q: String) {
        guard let mq else { return }
        mq.disableUpdates()
        let items = (0..<mq.resultCount).compactMap { mq.result(at: $0) as? NSMetadataItem }
        mq.enableUpdates()
        let capped = Array(items.prefix(800))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urls = metadataItemsURLs(capped).filter {
                !MailAttachPickerModel.isNoise($0.path)
            }
            var seen = Set<String>()
            let unique = urls.filter { seen.insert($0.path).inserted }
            let ranked = FuzzySearch.rankedKeepingAll(unique, query: q,
                name: { $0.lastPathComponent },
                date: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast })
            let top = Array(ranked.prefix(Self.searchDisplayLimit))
            top.forEach { MailAttachRowInfo.preload($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.browsing == nil,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
                self.results = top
                self.isSearching = false
            }
        }
    }

    private func stopSpotlight() {
        metaQuery?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        metaQuery = nil
    }

    deinit {
        debounce?.cancel()
        stopSpotlight()
    }
}

struct FileCommandPaletteView: View {
    @StateObject private var model = FileCommandPaletteModel()
    @State private var selection = Set<URL>()
    @State private var basket: [URL] = []
    @FocusState private var searchFocused: Bool

    let initialFolder: URL
    let focusToken: UInt
    let onClose: () -> Void
    let onOpen: ([URL]) -> Void
    let onCopy: ([URL]) -> Void
    let onQuickLink: ([URL]) -> Void

    private var trimmedQuery: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showingHome: Bool { model.browsing == nil && trimmedQuery.isEmpty }

    private var visibleOrder: [URL] {
        if showingHome {
            return currentFolderRow + homeFiles(model.recentFiles) + homeFiles(model.downloads)
                + model.pinned + model.recentFolders
        }
        return model.results
    }

    private var currentFolderRow: [URL] {
        let folder = effectiveInitialFolder
        return FileManager.default.fileExists(atPath: folder.path) ? [folder] : []
    }

    private var effectiveInitialFolder: URL { model.initialFolder ?? initialFolder }

    private func homeFiles(_ urls: [URL]) -> [URL] {
        urls.filter { !model.isFolder($0) }
    }

    private var orderedSelection: [URL] {
        visibleOrder.filter(selection.contains)
    }

    private var actionURLs: [URL] {
        if !basket.isEmpty { return basket }
        return orderedSelection
    }

    private var availableActionURLs: [URL] {
        existing(actionURLs)
    }

    private func actionURLs(for context: Set<URL>?) -> [URL] {
        if let context, !context.isEmpty {
            let ordered = visibleOrder.filter(context.contains)
            return ordered.isEmpty ? Array(context) : ordered
        }
        return actionURLs
    }

    private var activeURL: URL? {
        visibleOrder.first { selection.contains($0) } ?? visibleOrder.first
    }

    private var activeIsFolder: Bool {
        activeURL.map { model.isFolder($0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField(model.browsing == nil ? "Search entire Mac — start typing" : "Filter \(model.browsing!.lastPathComponent)",
                      text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { openActive() }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.leftArrow) {
                    guard model.browsing != nil else { return .ignored }
                    model.browseUp(); return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard trimmedQuery.isEmpty, let sel = activeURL, model.isFolder(sel) else { return .ignored }
                    model.browse(sel); return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    addSelectionToBasket(); return .handled
                }
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !basket.isEmpty { basketBar }
            actionBar
        }
        .padding(10)
        .frame(height: 272)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .onAppear {
            model.appeared(initialFolder: initialFolder)
            selectFirst()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.query) { selectFirst() }
        .onChange(of: initialFolder) { _, newFolder in model.updateInitialFolder(newFolder) }
        .onChange(of: model.results) { selectFirst() }
        .onChange(of: model.browsing) { selectFirst() }
        .onChange(of: model.downloads) { if selection.isEmpty { selectFirst() } }
        .onChange(of: focusToken) { searchFocused = true }
        .onExitCommand { onClose() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let folder = model.browsing {
                Button { model.browseUp() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back (←)")
                Image(nsImage: MailAttachRowInfo.cached(folder)?.icon ?? NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable().frame(width: 18, height: 18)
                Text(folder.lastPathComponent).font(.headline).lineLimit(1)
                Text(folder.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            } else {
                Label("Files", systemImage: "magnifyingglass").font(.headline)
                Text("Entire Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.browsing == nil {
                Button { model.browse(effectiveInitialFolder) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Browse current folder")
            } else {
                Button { model.browse(nil) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search entire Mac")
            }
            Button { onClose() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private var list: some View {
        if !showingHome && model.isSearching && model.results.isEmpty {
            HStack { Spacer(); ProgressView("Searching…"); Spacer() }.frame(maxHeight: .infinity)
        } else if visibleOrder.isEmpty {
            HStack { Spacer(); Text(model.browsing != nil && trimmedQuery.isEmpty ? "Folder is empty" : "No results")
                .foregroundStyle(.secondary); Spacer() }
                .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                if showingHome {
                    section("Current folder", currentFolderRow)
                    section("Recent", homeFiles(model.recentFiles))
                    section("Downloads", homeFiles(model.downloads))
                    section("Favorites", model.pinned)
                    section("Recent folders", model.recentFolders)
                } else {
                    ForEach(visibleOrder, id: \.self) { row($0) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: URL.self) { urls in
                contextMenu(urls)
            } primaryAction: { _ in
                openActive()
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ urls: [URL]) -> some View {
        if !urls.isEmpty {
            Section(title) { ForEach(urls, id: \.self) { row($0) } }
        }
    }

    private func row(_ url: URL) -> some View {
        MailAttachRow(url: url, inTray: basket.contains(url),
                      onToggleTray: { toggleBasket(url) })
            .tag(url)
            .fileDragOutURLs(dragURLs(for: url))
    }

    private func dragURLs(for url: URL) -> [URL] {
        if basket.contains(url) { return existing(basket) }
        if selection.contains(url) {
            let ordered = orderedSelection
            if ordered.count > 1 { return existing(ordered) }
        }
        return existing([url])
    }

    @ViewBuilder
    private func contextMenu(_ urls: Set<URL>) -> some View {
        let targets = existing(actionURLs(for: urls))
        if targets.count == 1, let only = targets.first, model.isFolder(only) {
            Button("Open Folder") { model.browse(only) }
        } else if targets.count == 1 {
            Button("Open") { onOpen(targets) }
        }
        if !targets.isEmpty {
            if targets.allSatisfy(basket.contains) {
                Button("Remove from marked") { basket.removeAll(where: targets.contains) }
            } else {
                Button("Add to marked (⇧↩)") { addToBasket(targets) }
            }
        }
        Divider()
        Button("Copy") { onCopy(existing(targets)) }
            .disabled(targets.isEmpty)
        Button("Share Link") { onQuickLink(existing(targets)) }
            .disabled(targets.isEmpty)
        Button("Show in Finder") { FinderReveal.reveal(targets) }
            .disabled(targets.isEmpty)
    }

    private var basketBar: some View {
        HStack(spacing: 8) {
            Label("\(basket.count)", systemImage: "tray.full.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.accentColor)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(basket, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(nsImage: MailAttachRowInfo.cached(url)?.icon ?? NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 16, height: 16)
                            Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                .frame(maxWidth: 150, alignment: .leading)
                            Button { basket.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
            Button("Clear") { basket = [] }
                .buttonStyle(.link).font(.caption)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text("\(orderedSelection.count) selected · \(basket.count) marked")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("Drag rows to Mail, browser, or Finder")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            Button(activeIsFolder ? "Enter Folder" : "Open") { openActive() }
                .controlSize(.small)
                .disabled(activeURL == nil)
                .help(activeIsFolder ? "Enter folder (⏎)" : "Open file (⏎)")
            Button("Copy") { onCopy(availableActionURLs) }
                .controlSize(.small)
                .disabled(availableActionURLs.isEmpty)
                .help("Copy marked items, or the current selection")
            Button("Share Link") { onQuickLink(availableActionURLs) }
                .controlSize(.small)
                .disabled(availableActionURLs.isEmpty)
                .help("Create a 24h quick link for marked items, or the current selection")
        }
    }

    // MARK: Actions

    private func existing(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func selectFirst() {
        let visible = Set(visibleOrder)
        selection.formIntersection(visible)
        if selection.isEmpty {
            selection = visibleOrder.first.map { [$0] } ?? []
        }
    }

    private func moveSelection(_ delta: Int) {
        let order = visibleOrder
        guard !order.isEmpty else { return }
        let current = order.firstIndex { selection.contains($0) }
        let next = current.map { min(max($0 + delta, 0), order.count - 1) } ?? 0
        selection = [order[next]]
    }

    private func toggleBasket(_ url: URL) {
        if let i = basket.firstIndex(of: url) { basket.remove(at: i) } else { basket.append(url) }
    }

    private func addToBasket(_ urls: [URL]) {
        for u in urls where !basket.contains(u) { basket.append(u) }
    }

    private func addSelectionToBasket() {
        addToBasket(orderedSelection)
        moveSelection(1)
    }

    private func openActive() {
        guard let target = activeURL else { return }
        if model.isFolder(target) {
            model.browse(target)
        } else {
            onOpen([target])
        }
    }
}

private final class FilePalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FileCommandPaletteWindowManager: NSObject, NSWindowDelegate {
    static let shared = FileCommandPaletteWindowManager()

    private var panel: NSPanel?
    private weak var hostWindow: NSWindow?
    private var shortcutMonitor: Any?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private var currentFolder: URL
    private let hotkeyID = EventHotKeyID(signature: OSType(0x4650464C), id: 2)
    private let fileOps = FileOperationsService()

    override init() {
        currentFolder = FileManager.default.homeDirectoryForCurrentUser
        super.init()
    }

    func setCurrentFolder(_ folder: URL) {
        currentFolder = folder
    }

    func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat,
                  event.keyCode == 3,
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  let self,
                  let keyWindow = NSApp.keyWindow,
                  keyWindow !== self.panel,
                  keyWindow.isVisible else { return event }
            self.open()
            return nil
        }
        registerCarbonHotkey()
    }

    private func registerCarbonHotkey() {
        unregisterCarbonHotkey()
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_F), UInt32(cmdKey | shiftKey), hotkeyID,
            GetApplicationEventTarget(), 0, &carbonHotKey
        )
        guard status == noErr else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var receivedID = EventHotKeyID()
            let eventStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &receivedID
            )
            guard eventStatus == noErr,
                  receivedID.signature == OSType(0x4650464C),
                  receivedID.id == 2 else { return noErr }
            DispatchQueue.main.async {
                FileCommandPaletteWindowManager.shared.open(onActiveScreen: true)
            }
            return noErr
        }
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &spec, nil, &handlerRef
        )
        if handlerStatus == noErr {
            carbonHandler = handlerRef
        }
    }

    private func unregisterCarbonHotkey() {
        if let hotkey = carbonHotKey {
            UnregisterEventHotKey(hotkey)
            carbonHotKey = nil
        }
        if let handler = carbonHandler {
            RemoveEventHandler(handler)
            carbonHandler = nil
        }
    }

    func open(initialFolder: URL? = nil, onActiveScreen: Bool = false) {
        if let panel, panel.isVisible {
            if onActiveScreen { NSApp.activate(ignoringOtherApps: true) }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }
        let active = NSApp.keyWindow
        let host: NSWindow? = onActiveScreen ? nil : (
            active !== panel && active?.isVisible == true
                ? active
                : (hostWindow?.isVisible == true ? hostWindow : NSApp.mainWindow)
        )
        if !onActiveScreen { hostWindow = host }
        let view = FileCommandPaletteView(
            initialFolder: initialFolder ?? currentFolder,
            focusToken: 0,
            onClose: { [weak self] in self?.close() },
            onOpen: { [weak self] urls in self?.openURLs(urls) },
            onCopy: { [weak self] urls in self?.fileOps.copy(urls) },
            onQuickLink: { urls in
                guard SecureShareManager.canQuickLink(urls) else { return }
                Task { await SecureShareManager.shared.quickLink(for: urls) }
            }
        )
        let p = panel ?? makePanel()
        p.contentViewController = NSHostingController(rootView: view)
        panel = p
        position(p, relativeTo: host, useMouseScreen: onActiveScreen)
        if onActiveScreen { NSApp.activate(ignoringOtherApps: true) }
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
    }

    deinit {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
        }
        if let hotkey = carbonHotKey {
            UnregisterEventHotKey(hotkey)
        }
        if let handler = carbonHandler {
            RemoveEventHandler(handler)
        }
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel {
            panel = nil
            hostWindow = nil
        }
    }

    private func openURLs(_ urls: [URL]) {
        guard let url = urls.first else { return }
        close()
        if FileItem.isBrowsableFolder(url) {
            NotificationCenter.default.post(name: .navigateToPath, object: url)
        } else {
            NotificationCenter.default.post(name: .ffOpenPaletteURL, object: url)
        }
    }

    private func makePanel() -> FilePalettePanel {
        let p = FilePalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        return p
    }

    private func position(_ p: NSPanel, relativeTo host: NSWindow?, useMouseScreen: Bool) {
        let width = min(max((host?.contentView?.bounds.width ?? 900) - 32, 640), 920)
        p.setContentSize(NSSize(width: width, height: 340))
        if useMouseScreen, let screen = screenUnderMouse() {
            let frame = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.maxY - 356))
            return
        }
        guard let host else {
            p.center()
            return
        }
        let frame = host.frame
        p.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.minY + 52))
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSPointInRect(mouse, $0.frame) } ?? NSScreen.main
    }
}
