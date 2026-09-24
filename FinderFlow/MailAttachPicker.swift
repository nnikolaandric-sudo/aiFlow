import SwiftUI
import AppKit
import Combine
import ApplicationServices
import UniformTypeIdentifiers
import Quartz

// MARK: - Kind filter

enum MailAttachKind: Int, CaseIterable {
    case all, pdf, image, document, sheet

    var title: String {
        switch self {
        case .all: return "Sve"
        case .pdf: return "PDF"
        case .image: return "Slike"
        case .document: return "Dokumenti"
        case .sheet: return "Tabele"
        }
    }

    private static let docExt: Set<String> = ["doc", "docx", "pages", "rtf", "rtfd", "txt", "md", "odt", "key", "ppt", "pptx"]
    private static let sheetExt: Set<String> = ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]

    func matches(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch self {
        case .all: return true
        case .pdf: return ext == "pdf"
        case .image: return UTType(filenameExtension: ext)?.conforms(to: .image) == true
        case .document: return Self.docExt.contains(ext)
        case .sheet: return Self.sheetExt.contains(ext)
        }
    }
}

// MARK: - Picker model (recent + downloads + favorites + Spotlight search + folder browse)

final class MailAttachPickerModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var results: [URL] = []
    @Published var isSearching = false
    @Published var recentFiles: [URL] = []
    @Published var pinned: [URL] = []
    @Published var recentFolders: [URL] = []
    /// Najnoviji fajlovi iz ~/Downloads — najcesce se odatle kaci.
    @Published var downloads: [URL] = []
    /// Folder otvoren u pickeru (nil = pocetni ekran / Spotlight).
    @Published private(set) var browsing: URL?
    @Published private(set) var folderItems: [URL] = []
    /// Poznati folderi (Favorites, Recent folders, sadrzaj otvorenog foldera)
    /// — da provera "folder ili fajl" ne ide na disk u main threadu.
    private(set) var knownDirectories = Set<URL>()
    static let browseDisplayLimit = 500

    private var metaQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private var browseToken = 0

    init() {
        reloadStatic()
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
        // Isti folder u Favorites i Recent folders = dupli ID u istoj Listi.
        let pinnedSet = Set(pinned.map(\.path))
        recentFolders = recPaths.map { URL(fileURLWithPath: $0) }
            .filter { !pinnedSet.contains($0.path) && fm.fileExists(atPath: $0.path) }
        knownDirectories.formUnion(pinned)
        knownDirectories.formUnion(recentFolders)
    }

    func appeared() {
        reloadStatic()
        loadDownloads()
        scheduleSearch()
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

    /// Spotlight vraca i sistemski/app smece (~/Library keševi, sadrzaj .app
    /// paketa, node_modules...). iCloud Drive i CloudStorage (Google Drive,
    /// Dropbox) su pravi korisnicki fajlovi i ostaju.
    nonisolated static func isNoise(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") {
            return !(path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/"))
        }
        for prefix in ["/System/", "/Library/", "/private/", "/usr/", "/opt/", "/Applications/", "/bin/", "/sbin/"]
            where path.hasPrefix(prefix) { return true }
        for part in [".app/", "/node_modules/", "/.git/", "/.Trash/", "/DerivedData/", ".photoslibrary/"]
            where path.contains(part) { return true }
        return false
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
            let dirs = items.filter(isDir).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let files = items.filter { !isDir($0) }.sorted { date($0) > date($1) }
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
        if browsing != nil {
            // U folderu: lokalni fuzzy filter, bez Spotlight-a — trenutno.
            results = q.isEmpty ? Array(folderItems.prefix(Self.browseDisplayLimit))
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
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
            }
            let ranked = FuzzySearch.rankedKeepingAll(urls, query: q,
                name: { $0.lastPathComponent },
                date: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast })
            let top = Array(ranked.prefix(50))
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

// MARK: - Row

/// Ikona + datum + folder? — citano sa diska jednom, van main threada.
struct MailAttachRowInfo {
    let icon: NSImage
    let modLabel: String
    let isDirectory: Bool
    let size: Int64?

    var sizeLabel: String {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    private static let cache = NSCache<NSURL, Box>()
    private final class Box { let info: MailAttachRowInfo; init(_ i: MailAttachRowInfo) { info = i } }

    static func cached(_ url: URL) -> MailAttachRowInfo? { cache.object(forKey: url as NSURL)?.info }

    @discardableResult
    static func preload(_ url: URL) -> MailAttachRowInfo {
        if let hit = cached(url) { return hit }
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey])
        var label = ""
        if let d = v?.contentModificationDate {
            if Calendar.current.isDateInToday(d) { label = d.formatted(date: .omitted, time: .shortened) }
            else if Calendar.current.isDateInYesterday(d) { label = "yesterday" }
            else { label = d.formatted(date: .abbreviated, time: .omitted) }
        }
        let info = MailAttachRowInfo(icon: NSWorkspace.shared.icon(forFile: url.path),
                                     modLabel: label, isDirectory: v?.isDirectory == true,
                                     size: v?.isDirectory == true ? nil : v?.fileSize.map(Int64.init))
        cache.setObject(Box(info), forKey: url as NSURL)
        return info
    }
}

struct MailAttachRow: View {
    let url: URL
    var inTray = false
    var onToggleTray: (() -> Void)? = nil
    @State private var info: MailAttachRowInfo?

    private var parentLabel: String {
        url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onToggleTray {
                Button(action: onToggleTray) {
                    Image(systemName: inTray ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(inTray ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(inTray ? "Izbaci iz korpe" : "Dodaj u korpu (⇧↩)")
            }
            Group {
                if let icon = (info ?? MailAttachRowInfo.cached(url))?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(parentLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            let resolved = info ?? MailAttachRowInfo.cached(url)
            if resolved?.isDirectory == true {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(resolved?.modLabel ?? "").font(.caption).foregroundStyle(.secondary)
                    Text(resolved?.sizeLabel ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .task(id: url) {
            guard MailAttachRowInfo.cached(url) == nil else { return }
            let u = url
            info = await Task.detached(priority: .userInitiated) { MailAttachRowInfo.preload(u) }.value
        }
    }
}

// MARK: - Picker window

struct MailAttachPickerView: View {
    @StateObject private var model = MailAttachPickerModel()
    @State private var selection = Set<URL>()
    /// Korpa: fajlovi skupljeni iz vise pretraga/foldera, attach odjednom.
    @State private var tray: [URL] = []
    @AppStorage("ffMailAttachShowPreview") private var showPreview = true
    @State private var kind: MailAttachKind = .all
    @FocusState private var searchFocused: Bool
    @ObservedObject private var service = MailAttachService.shared
    // MARK: - Pick mode (workspace Attach file… → tvoj attacher)
    /// Kad je set, picker ne kaci u Mail nego vraca izabrane fajlove kroz
    /// `onPick` (Choose umesto Attach). Nil = klasican Mail attach rezim.
    var pickTitle: String? = nil
    var pickAllowsMultiple: Bool = true
    var pickInitialDirectory: URL? = nil
    var onPick: (([URL]) -> Void)? = nil
    var onCancelPick: (() -> Void)? = nil
    @State private var didInitPickBrowse = false
    private var isPickMode: Bool { onPick != nil }

    /// Prvi oznaceni red po redosledu na ekranu — njega prikazuje preview.
    private var previewURL: URL? { visibleOrder.first { selection.contains($0) } }

    private var trimmedQuery: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showingHome: Bool { model.browsing == nil && trimmedQuery.isEmpty }

    /// Redosled kojim ih korisnik vidi — za ↑/↓ i "prvi rezultat".
    private var visibleOrder: [URL] {
        showingHome ? homeFiles(model.recentFiles) + homeFiles(model.downloads) + model.pinned + model.recentFolders
            : model.results.filter { isFolder($0) || kind.matches($0) }
    }

    private func homeFiles(_ urls: [URL]) -> [URL] { urls.filter(kind.matches) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextField(model.browsing == nil ? "Search files — npr. acme ugovor" : "Filter \(model.browsing!.lastPathComponent)",
                      text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { attachSelection() }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.leftArrow) {
                    guard model.query.isEmpty, model.browsing != nil else { return .ignored }
                    model.browseUp(); return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard model.query.isEmpty, let sel = selection.first, isFolder(sel) else { return .ignored }
                    model.browse(sel); return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    addSelectionToTray(); return .handled
                }
            kindBar
            HStack(spacing: 12) {
                list.frame(minWidth: 320)
                if showPreview {
                    MailAttachPreviewPane(url: previewURL) { model.browse($0) }
                        .frame(width: 300)
                }
            }
            if !tray.isEmpty, pickAllowsMultiple { trayBar }
            if !MailAttachService.shared.accessibilityTrusted() {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Bez Accessibility dozvole fajl ide u novu poruku (Settings ▸ Mail integration).")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            footer
        }
        .padding(14)
        .frame(minWidth: 640, idealWidth: 880, maxWidth: .infinity,
               minHeight: 420, idealHeight: 540, maxHeight: .infinity)
        .onAppear {
            model.appeared()
            // Pick mode krece od zadatog foldera (npr. workspace root).
            if !didInitPickBrowse, let dir = pickInitialDirectory {
                didInitPickBrowse = true
                model.browse(dir)
            }
            searchFocused = true
            selectFirst()
        }
        // Model menja `results` sinhrono u query.didSet, pa je selectFirst
        // tacan bez obzira kojim redom SwiftUI javi ove promene.
        .onChange(of: model.query) { selectFirst() }
        .onChange(of: model.results) { selectFirst() }
        .onChange(of: model.browsing) { selectFirst() }
        .onChange(of: model.downloads) { if selection.isEmpty { selectFirst() } }
        .onExitCommand { MailAttachWindowManager.shared.close() }
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
            } else if let pickTitle {
                Label(pickTitle, systemImage: "paperclip").font(.headline)
            } else {
                Label("aiFlow — Attach file", systemImage: "paperclip").font(.headline)
            }
            Spacer()
            Button { showPreview.toggle() } label: {
                Image(systemName: "sidebar.right").foregroundStyle(showPreview ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("y", modifiers: .command)
            .help("Preview (⌘Y)")
            Text("⌥⌘A").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var kindBar: some View {
        HStack(spacing: 6) {
            ForEach(MailAttachKind.allCases, id: \.self) { k in
                Button { kind = k; selectFirst() } label: {
                    Text(k.title)
                        .font(.caption.weight(kind == k ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(kind == k ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                        .foregroundStyle(kind == k ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(k.rawValue + 1)")), modifiers: .command)
                .help("⌘\(k.rawValue + 1)")
            }
            Spacer()
        }
    }

    private var trayBytes: Int64 {
        tray.reduce(0) { sum, url in
            sum + (MailAttachRowInfo.cached(url)?.size
                   ?? Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
    }

    private var trayBar: some View {
        HStack(spacing: 8) {
            Label("\(tray.count)", systemImage: "tray.full.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.accentColor)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tray, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(nsImage: MailAttachRowInfo.cached(url)?.icon ?? NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 16, height: 16)
                            Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                .frame(maxWidth: 150, alignment: .leading)
                            Button { tray.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
            let bytes = trayBytes
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(bytes > 20_000_000 ? Color.orange : Color.secondary)
                .help(bytes > 20_000_000 ? "Preko 20 MB — Mail će ponuditi Mail Drop ili server može odbiti poruku." : "Ukupna veličina")
            Button("Isprazni") { tray = [] }
                .buttonStyle(.link).font(.caption)
        }
    }

    @ViewBuilder
    private var list: some View {
        if !showingHome && model.isSearching && model.results.isEmpty {
            HStack { Spacer(); ProgressView("Searching…"); Spacer() }.frame(maxHeight: .infinity)
        } else if !showingHome && visibleOrder.isEmpty {
            HStack { Spacer(); Text(model.browsing != nil && trimmedQuery.isEmpty ? "Folder je prazan" : "Nema rezultata")
                .foregroundStyle(.secondary); Spacer() }
                .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                if showingHome {
                    section("Recent", homeFiles(model.recentFiles))
                    section("Downloads", homeFiles(model.downloads))
                    section("Favorites", model.pinned)
                    section("Recent folders", model.recentFolders)
                } else {
                    ForEach(visibleOrder, id: \.self) { row($0) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            // Dupli klik bez onTapGesture(count: 2): ta varijanta tera List
            // da ceka ~300 ms na svaki obican klik pre nego sto oznaci red.
            .contextMenu(forSelectionType: URL.self) { urls in
                contextMenu(urls)
            } primaryAction: { urls in
                open(urls)
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
        // Single-pick: bez korpe, klik bira jedan fajl.
        let trayToggle = (isFolder(url) || (isPickMode && !pickAllowsMultiple)) ? nil : { toggleTray(url) }
        return MailAttachRow(url: url, inTray: tray.contains(url),
                      onToggleTray: trayToggle)
            .tag(url)
            .onDrag { NSItemProvider(object: url as NSURL) }
    }

    @ViewBuilder
    private func contextMenu(_ urls: Set<URL>) -> some View {
        let files = urls.filter { !isFolder($0) }
        if !files.isEmpty {
            if isPickMode {
                Button(files.count == 1 ? "Choose" : "Choose \(files.count) Files") { pickUrls(Array(files)) }
            } else {
                Button(files.count == 1 ? "Attach" : "Attach \(files.count) Files") { attach(Array(files)) }
            }
        }
        if !files.isEmpty, pickAllowsMultiple || !isPickMode {
            if files.allSatisfy(tray.contains) {
                Button("Izbaci iz korpe") { tray.removeAll(where: files.contains) }
            } else {
                Button("Dodaj u korpu (⇧↩)") { addToTray(Array(files)) }
            }
        }
        if urls.count == 1, let only = urls.first, isFolder(only) {
            Button("Open") { model.browse(only) }
        }
        Divider()
        Button("Show in Finder") { FinderReveal.reveal(Array(urls)) }
        Button("Copy") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(Array(urls) as [NSURL])
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let err = service.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("↑↓ ↩ · ⇧↩ u korpu · ⌘1–5 tip · ⌘Y preview · ← →")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button("Open dialog assistant…") { MailAttachService.shared.openAssistant() }
                .controlSize(.small)
                .buttonStyle(.link)
            Button("Cancel") {
                if let onCancelPick { onCancelPick() }
                else { MailAttachWindowManager.shared.close() }
            }
                .keyboardShortcut(.escape)
            Button(attachTitle) { attachSelection() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(visibleOrder.isEmpty && tray.isEmpty)
        }
    }

    private var attachTitle: String {
        if isPickMode {
            let files = pickAllowsMultiple ? trayOrSelectionFiles : Array(trayOrSelectionFiles.prefix(1))
            if !tray.isEmpty, pickAllowsMultiple { return tray.count == 1 ? "Choose 1 File" : "Choose \(tray.count) Files" }
            if files.count > 1 { return "Choose \(files.count) Files" }
            return "Choose"
        }
        if !tray.isEmpty { return tray.count == 1 ? "Attach 1 File" : "Attach \(tray.count) Files" }
        let files = selection.filter { !isFolder($0) }
        if selection.count == 1, let only = selection.first, isFolder(only) { return "Open" }
        return files.count > 1 ? "Attach \(files.count) Files" : "Attach"
    }

    // MARK: Actions

    private func isFolder(_ url: URL) -> Bool {
        if model.knownDirectories.contains(url) { return true }
        if let info = MailAttachRowInfo.cached(url) { return info.isDirectory }
        // Recent/Spotlight/sadrzaj foldera koji nije u knownDirectories su fajlovi.
        return false
    }

    private func selectFirst() {
        if let first = visibleOrder.first(where: { !isFolder($0) }) ?? visibleOrder.first {
            selection = [first]
        } else {
            selection = []
        }
    }

    private func moveSelection(_ delta: Int) {
        let order = visibleOrder
        guard !order.isEmpty else { return }
        let current = order.firstIndex { selection.contains($0) }
        let next = current.map { min(max($0 + delta, 0), order.count - 1) } ?? 0
        selection = [order[next]]
    }

    private func toggleTray(_ url: URL) {
        if let i = tray.firstIndex(of: url) { tray.remove(at: i) } else { tray.append(url) }
    }

    private func addToTray(_ urls: [URL]) {
        for u in urls where !tray.contains(u) { tray.append(u) }
    }

    private func addSelectionToTray() {
        // Single-pick nema korpu: ⇧↩ bira odmah.
        if isPickMode, !pickAllowsMultiple {
            pickUrls(trayOrSelectionFiles)
            return
        }
        let files = visibleOrder.filter { selection.contains($0) && !isFolder($0) }
        addToTray(files)
        // Posle dodavanja pomeri se na sledeci red — brzo biranje ⇧↩ ⇧↩ ⇧↩.
        moveSelection(1)
    }

    private func attachSelection() {
        if isPickMode {
            pickUrls(trayOrSelectionFiles)
            return
        }
        if !tray.isEmpty { attach(tray); return }
        let chosen = selection.isEmpty ? Set(visibleOrder.prefix(1)) : selection
        open(chosen)
    }

    /// Fajlovi za pick: korpa ima prednost, inace trenutna selekcija.
    private var trayOrSelectionFiles: [URL] {
        if !tray.isEmpty { return tray.filter { !isFolder($0) } }
        let chosen = selection.isEmpty ? Set(visibleOrder.prefix(1)) : selection
        let files = chosen.filter { !isFolder($0) }
        let ordered = visibleOrder.filter(files.contains)
        return ordered.isEmpty ? Array(files) : ordered
    }

    private func pickUrls(_ urls: [URL]) {
        let files = urls.filter { !isFolder($0) }
        guard !files.isEmpty else { return }
        onPick?(pickAllowsMultiple ? files : Array(files.prefix(1)))
    }

    /// Folder → udji u njega; fajlovi → attach (pick mode: → onPick).
    private func open(_ urls: Set<URL>) {
        if urls.count == 1, let only = urls.first, isFolder(only) {
            model.browse(only)
            return
        }
        let files = urls.filter { !isFolder($0) }
        guard !files.isEmpty else { return }
        let ordered = visibleOrder.filter(files.contains)
        let out = ordered.isEmpty ? Array(files) : ordered
        if isPickMode { pickUrls(out); return }
        attach(out)
    }

    private func attach(_ urls: [URL]) {
        if let onPick {
            pickUrls(urls)
            return
        }
        if MailAttachService.shared.attach(urls) {
            MailAttachWindowManager.shared.close()
        }
    }
}


// MARK: - Preview

struct MailAttachPreviewPane: View {
    let url: URL?
    let onOpenFolder: (URL) -> Void
    @State private var shown: URL?
    @State private var details: Details?

    struct Details {
        let kind: String
        let size: String
        let modified: String
        let isDirectory: Bool
        let children: [URL]
        let childCount: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shown, let details {
                if details.isDirectory {
                    folderContents(shown, details)
                } else {
                    MailAttachQuickLookView(url: shown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                info(shown, details)
            } else {
                Spacer()
                HStack { Spacer()
                    Text(url == nil ? "Izaberi fajl za preview" : "…").foregroundStyle(.secondary)
                    Spacer() }
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .task(id: url) {
            // Brzo strelicama: ne pravi preview za svaki red kroz koji prodje.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard let url else { shown = nil; details = nil; return }
            let d = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
            guard !Task.isCancelled else { return }
            details = d
            shown = url
        }
    }

    private func folderContents(_ folder: URL, _ d: Details) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.childCount == 1 ? "1 stavka" : "\(d.childCount) stavki")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(d.children, id: \.self) { child in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: child.path))
                                .resizable().frame(width: 16, height: 16)
                            Text(child.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if d.childCount > d.children.count {
                        Text("+ još \(d.childCount - d.children.count)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Otvori folder") { onOpenFolder(folder) }.controlSize(.small)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func info(_ url: URL, _ d: Details) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(2)
            Text([d.kind, d.size].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if !d.modified.isEmpty {
                Text("Izmenjeno \(d.modified)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { FinderReveal.reveal([url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }

    nonisolated static func load(_ url: URL) -> Details {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey,
                                                  .contentModificationDateKey])
        let isDir = v?.isDirectory == true
        var children: [URL] = []
        var count = 0
        if isDir {
            let all = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            count = all.count
            func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            children = Array(all.sorted { date($0) > date($1) }.prefix(40))
        }
        return Details(
            kind: v?.localizedTypeDescription ?? "",
            size: isDir ? "" : v?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "",
            modified: v?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "",
            isDirectory: isDir, children: children, childCount: count)
    }
}

/// Pravi Quick Look (PDF stranice, slike, Office, video) u panelu.
struct MailAttachQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
        v.autostarts = true
        v.shouldCloseWithWindow = false
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) {
        v.close()
    }
}
final class MailAttachWindowManager: NSObject, NSWindowDelegate {
    static let shared = MailAttachWindowManager()
    private var panel: NSPanel?
    // MARK: - Pick mode (Attach file… → tvoj attacher)
    private var pickOnPick: (([URL]) -> Void)?
    private var pickOnCancel: (() -> Void)?
    private var isCompletingPick = false

    /// Otvara attacher kao file picker: Choose vraca fajlove kroz `onPick`,
    /// Cancel/X kroz `onCancel`. Panel je isti prozor (Recent/Downloads/
    /// Favorites/Search/Preview), samo ne kaci u Mail.
    func openForPick(title: String,
                     allowsMultiple: Bool = true,
                     initialDirectory: URL? = nil,
                     onPick: @escaping ([URL]) -> Void,
                     onCancel: @escaping () -> Void = {}) {
        pickOnPick = onPick
        pickOnCancel = onCancel
        isCompletingPick = false
        let view = MailAttachPickerView(
            pickTitle: title,
            pickAllowsMultiple: allowsMultiple,
            pickInitialDirectory: initialDirectory,
            onPick: { [weak self] urls in self?.completePick(urls) },
            onCancelPick: { [weak self] in self?.cancelPick() }
        )
        let p = panel ?? makePanel()
        p.contentViewController = NSHostingController(rootView: view)
        panel = p
        centerOnMouseScreen(p)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
    }

    private func completePick(_ urls: [URL]) {
        let cb = pickOnPick
        pickOnPick = nil
        pickOnCancel = nil
        isCompletingPick = true
        panel?.close()
        cb?(urls)
    }

    private func cancelPick() {
        let cb = pickOnCancel
        pickOnPick = nil
        pickOnCancel = nil
        isCompletingPick = true
        panel?.close()
        cb?()
    }

    /// Non-activating (kao Spotlight): prima tastaturu a FinderFlow ne
    /// postaje aktivan, pa macOS ne prebacuje Space — picker iskoci preko
    /// Maila (i fullscreen) na ekranu gde je mis, Mail ostaje napred.
    func open() {
        // Mail rezim: ugasi eventualni pick (bez onCancel — korisnik je
        // trazio Mail picker) i vrati klasicni sadrzaj.
        pickOnPick = nil
        pickOnCancel = nil
        isCompletingPick = false
        let p: NSPanel
        if let existing = panel {
            existing.contentViewController = NSHostingController(rootView: MailAttachPickerView())
            p = existing
        } else {
            p = makePanel()
        }
        panel = p
        centerOnMouseScreen(p)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
    }

    /// Nevidljivo iscrta panel jednom posle starta, da prvi ⌥⌘A ne placa
    /// hladno ucitavanje SwiftUI/Quick Look-a.
    func prewarm() {
        guard panel == nil else { return }
        let p = makePanel()
        p.alphaValue = 0
        p.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        p.orderFrontRegardless()
        p.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            p.orderOut(nil)
            p.close()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentViewController = NSHostingController(rootView: MailAttachPickerView())
        p.title = "aiFlow — Attach file"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.level = .floating
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setContentSize(NSSize(width: 880, height: 540))
        p.minSize = NSSize(width: 640, height: 420)
        p.isReleasedWhenClosed = false
        p.delegate = self
        return p
    }

    private func centerOnMouseScreen(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { p.center(); return }
        let f = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.1))
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        panel = nil
        // X u pick rezimu = otkazivanje (osim kad je Choose vec pokrenut).
        if !isCompletingPick, let cb = pickOnCancel {
            pickOnPick = nil
            pickOnCancel = nil
            cb()
        }
        isCompletingPick = false
    }
}

// MARK: - Open/Save assistant (uz sistemski dialog)

struct MailPanelAssistantView: View {
    @StateObject private var model = MailAttachPickerModel()
    @State private var selection: URL?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("FINDERFLOW ASSISTANT", systemImage: "sparkles")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Search files", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            List(selection: $selection) {
                if !model.query.isEmpty {
                    ForEach(model.results, id: \.self) { url in
                        MailAttachRow(url: url).tag(url as URL?)
                    }
                } else {
                    if !model.recentFiles.isEmpty {
                        Section("Recent files") {
                            ForEach(model.recentFiles, id: \.self) { url in
                                MailAttachRow(url: url).tag(url as URL?)
                            }
                        }
                    }
                    if !model.pinned.isEmpty {
                        Section("Favorites") {
                            ForEach(model.pinned, id: \.self) { url in
                                MailAttachRow(url: url).tag(url as URL?)
                            }
                        }
                    }
                    if !model.recentFolders.isEmpty {
                        Section("Recent folders") {
                            ForEach(model.recentFolders, id: \.self) { url in
                                MailAttachRow(url: url).tag(url as URL?)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 220)
            Text("Klik vodi otvoreni Attach/Open dialog tamo (⇧⌘G → path → Enter).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { MailPanelAssistantWindowManager.shared.close() }
                Button("Go there in dialog") { goSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil)
            }
        }
        .padding(12)
        .frame(width: 380, height: 520)
        .onAppear { model.appeared(); searchFocused = true }
        .onExitCommand { MailPanelAssistantWindowManager.shared.close() }
    }

    private func goSelected() {
        guard let sel = selection ?? model.results.first ?? model.recentFiles.first else { return }
        MailAttachService.shared.driveOpenPanel(to: sel)
    }
}

// MARK: - Settings section (Mail integration)

struct MailAttachSettingsSection: View {
    @AppStorage(MailAttachPrefs.enabledKey) private var enabled = true
    @AppStorage(MailAttachPrefs.recentKey) private var showRecent = true
    @AppStorage(MailAttachPrefs.favKey) private var showFavorites = true
    @AppStorage(MailAttachPrefs.searchKey) private var showSearch = true
    @AppStorage(MailAttachPrefs.assistantKey) private var assistant = true
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var signing: SigningState = .missing
    @State private var creatingIdentity = false
    @State private var identityError: String?
    @ObservedObject private var attachService = MailAttachService.shared
    private var service = MailAttachService.shared

    private enum SigningState { case missing, pendingRebuild, active }

    private var signingDetail: String {
        if let identityError { return identityError }
        switch signing {
        case .active: return "Permission survives rebuilds."
        case .pendingRebuild: return "Certificate is ready — takes effect from the next build (./build-local.sh)."
        case .missing: return "Create a local certificate \"\(FFSigningIdentity.name)\" in the login keychain (no password), so macOS keeps the permission across rebuilds."
        }
    }

    private func refreshSetup() {
        axTrusted = AXIsProcessTrusted()
        if FFSigningIdentity.appIsSignedWithIt() { signing = .active; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = FFSigningIdentity.isInstalled()
            DispatchQueue.main.async { signing = installed ? .pendingRebuild : .missing }
        }
    }

    private func createIdentity() {
        creatingIdentity = true
        identityError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let err = FFSigningIdentity.create()
            DispatchQueue.main.async {
                creatingIdentity = false
                identityError = err
                refreshSetup()
            }
        }
    }

    private func setupRow<B: View>(done: Bool, title: String, detail: String,
                                   @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            button()
        }
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("⌥⌘A — Attach from aiFlow")
                    Text("A global picker above everything: type a few letters, Enter — the file lands in your open Mail compose. aiFlow must be running in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: enabled) { MailAttachService.shared.start() }
            Toggle("Show recent files", isOn: $showRecent)
            Toggle("Search indexed documents", isOn: $showSearch)
            Toggle("Show favorites", isOn: $showFavorites)
            Toggle(isOn: $assistant) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show aiFlow Assistant")
                    Text("A small window next to the system Attach/Open dialog: a click steers the dialog to that folder (⇧⌘G → path → Enter).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Inserting into an already open message")
                Text("Mail doesn't expose the open message to scripts, so aiFlow inserts via Accessibility. Until both steps are ✓, ⌥⌘A opens a new message with the attachment.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                setupRow(done: signing == .active,
                         title: "1. Stable signature",
                         detail: signingDetail) {
                    if signing == .missing {
                        Button(creatingIdentity ? "Creating…" : "Create") { createIdentity() }
                            .controlSize(.small)
                            .disabled(creatingIdentity)
                    }
                }
                setupRow(done: axTrusted,
                         title: "2. Accessibility permission",
                         detail: axTrusted ? "Enabled."
                            : "Click Fix: removes the stale aiFlow entry, the system asks again — enable aiFlow in the list.") {
                    if !axTrusted {
                        Button("Fix…") { service.resetAndPromptAccessibility() }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("Test attach") { MailAttachWindowManager.shared.open() }
                        .controlSize(.small)
                }
            }
            .onAppear(perform: refreshSetup)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshSetup()
            }
            HStack {
                Label(attachService.hotkeyActive ? "Hotkey ⌥⌘A: active" : "Hotkey ⌥⌘A: not active — relaunch the app",
                      systemImage: attachService.hotkeyActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(attachService.hotkeyActive ? .green : .orange)
            }
            HStack {
                Button("Check Mail permission") { attachService.probeMailScripting() }
                    .controlSize(.small)
                if let probe = attachService.probeResult {
                    Text(probe).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Check whether Mail accepts commands — triggers the system Allow dialog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            FFSectionHeader(title: "Mail integration", symbol: "envelope.fill", tint: .blue)
        }
    }
}

final class MailPanelAssistantWindowManager: NSObject, NSWindowDelegate {
    static let shared = MailPanelAssistantWindowManager()
    private var panel: NSPanel?

    func open() {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: MailPanelAssistantView())
        let p = NSPanel(contentViewController: host)
        p.title = "aiFlow Assistant"
        p.styleMask = [.titled, .closable, .resizable]
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setContentSize(NSSize(width: 380, height: 520))
        // Desno od centra — da ne poklopi sistemski Attach dialog.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX + 40, y: f.midY - 260))
        } else { p.center() }
        p.delegate = self
        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { panel = nil }
    }
}
