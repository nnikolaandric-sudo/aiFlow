import SwiftUI
import AppKit

enum SidebarItem: Hashable {
    case location(URL)
    case pinned(URL)
    case recent(URL)
}

// MARK: - Favorites service (pinned folders)

class FavoritesService: ObservableObject {
    @Published var pinnedURLs: [URL] = []

    init() { load() }

    func load() {
        pinnedURLs = (UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func pin(_ url: URL) {
        guard url.hasDirectoryPath, !pinnedURLs.contains(url) else { return }
        pinnedURLs.insert(url, at: 0)
        save()
    }

    func unpin(_ url: URL) {
        pinnedURLs.removeAll { $0 == url }
        save()
    }

    func isPinned(_ url: URL) -> Bool { pinnedURLs.contains(url) }

    private func save() {
        UserDefaults.standard.set(pinnedURLs.map(\.path), forKey: "pinnedFolders")
    }
}

// MARK: - Cloud folders service (custom cloud nalozi)

/// Ručno dodati cloud folderi (drugi Google nalog, custom OneDrive putanja…).
/// Auto-detekcija pokriva standardne lokacije, a ovo su korisnički dodaci.
/// Čuvaju se kao putanje u UserDefaults — sidebar ih spaja sa detektovanim.
class CloudFoldersService: ObservableObject {
    static let storageKey = "ffCustomCloudFolders"

    @Published var customURLs: [URL] = []

    init() { load() }

    func load() {
        customURLs = (UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
    }

    /// Samo postojeći folderi se prikazuju, ali nepostojeći ostaju u listi
    /// (npr. eksterni disk trenutno nije priključen).
    var existingCustomURLs: [URL] {
        customURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        guard !customURLs.contains(where: { $0.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) else { return }
        customURLs.append(url)
        save()
    }

    func remove(_ url: URL) {
        customURLs.removeAll {
            $0 == url || $0.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
        }
        save()
    }

    func isCustom(_ url: URL) -> Bool {
        customURLs.contains(where: {
            $0 == url || $0.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
        })
    }

    private func save() {
        UserDefaults.standard.set(customURLs.map(\.path), forKey: Self.storageKey)
    }

    /// Sistemski folder-picker — bira se lokalni sync folder (npr. drugi Google nalog).
    static func pickFolder(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose a cloud sync folder (e.g. Google Drive, OneDrive, Dropbox). It is a normal local folder."
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

// MARK: - Sidebar view

struct SidebarView: View {
    @Binding var currentPath:     URL
    @Binding var selection:       SidebarItem?
    @Binding var activeTagFilter: String?
    let usedTagNames: [String]
    @EnvironmentObject var favorites: FavoritesService
    @EnvironmentObject var cloudFolders: CloudFoldersService
    /// Drop support: needs fileOps. Optional so previews/older call sites keep
    /// compiling; when nil, sidebar rows are not drop targets.
    var fileOps: FileOperationsService? = nil
    var onReload: (() -> Void)? = nil
    @AppStorage("ffShowCloudFolders") private var showCloudFolders = true
    @State private var recentFolders: [URL] = []
    /// Cached volume list — `mountedVolumeURLs` hits disk, so never call it
    /// from `body`. Refreshed on appear + on mount/unmount notifications.
    @State private var cachedVolumes: [URL] = []
    /// Cached cloud folders (Google Drive, iCloud, OneDrive, …) — same reason:
    /// directory scans stay off the render path.
    @State private var cachedCloudFolders: [URL] = []

    var body: some View {
        List(selection: $selection) {
            Section("Sharing") {
                Button { SecureShareWindowManager.shared.open() } label: {
                    Label("Shared Files", systemImage: "link")
                }.buttonStyle(.plain)
            }


            // ── System locations ──────────────────────────────────────────
            Section("Favorites") {
                ForEach(systemLocations, id: \.self) { url in
                    sidebarDropRow(url: url, tag: SidebarItem.location(url)) {
                        SidebarRow(url: url)
                            .onTapGesture { go(url) }
                    }
                }
            }

            // ── User-pinned folders ───────────────────────────────────────
            if !favorites.pinnedURLs.isEmpty {
                Section("Pinned") {
                    ForEach(favorites.pinnedURLs, id: \.self) { url in
                        sidebarDropRow(url: url, tag: SidebarItem.pinned(url)) {
                            SidebarRow(url: url)
                                .onTapGesture { go(url) }
                                .contextMenu {
                                    Button("Remove from Pinned") { favorites.unpin(url) }
                                }
                        }
                    }
                    .onDelete { idx in
                        // Snapshot first: unpin mutates the array, so resolving
                        // each index lazily removes the wrong item — or traps
                        // out of bounds (e.g. deleting rows {0,2} of 3).
                        let urls = idx.map { favorites.pinnedURLs[$0] }
                        urls.forEach(favorites.unpin)
                    }
                }
            }

            // ── Google Drive nativno (OAuth API mirror, bez Drive aplikacije) ──
            // Više naloga, svaki kao poseban root. Radi i kad Drive for Desktop
            // nije instaliran. Lokalni mirror se browse-uje kao običan folder.
            GoogleDriveSidebarSection(
                currentPath: $currentPath,
                selection: $selection,
                fileOps: fileOps,
                onReload: onReload
            )

            // ── Cloud folders (Google Drive, iCloud Drive, OneDrive, …) ────
            // Lokalni sync folderi — rade kao obični folderi, bez mreže i naloga.
            // Auto-detekcija + ručno dodati nalozi (Settings → Sidebar ili + dole).
            if showCloudFolders {
                Section {
                    ForEach(cachedCloudFolders, id: \.self) { url in
                        sidebarDropRow(url: url, tag: SidebarItem.location(url)) {
                            SidebarRow(url: url, subtitle: "Local folder")
                                .onTapGesture { go(url) }
                                .contextMenu {
                                    if favorites.isPinned(url) {
                                        Button("Remove from Pinned") { favorites.unpin(url) }
                                    } else {
                                        Button("Pin to Sidebar") { favorites.pin(url) }
                                    }
                                    if cloudFolders.isCustom(url) {
                                        Button("Remove Cloud Account", role: .destructive) {
                                            cloudFolders.remove(url)
                                        }
                                    }
                                    Button("Show in Finder") {
                                        FinderReveal.reveal([url])
                                    }
                                }
                        }
                    }
                    Button {
                        CloudFoldersService.pickFolder { picked in
                            if let picked { cloudFolders.add(picked); refreshCloudFolders() }
                        }
                    } label: {
                        Label("Add Cloud Folder…", systemImage: "plus.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add Google Drive, OneDrive, Dropbox or any sync folder")
                } header: {
                    Text("Cloud")
                } footer: {
                    if cachedCloudFolders.isEmpty {
                        Text("No cloud folders found — click + to add one.")
                    }
                }
            }

            // ── Volumes (mounted disks, USB, network) ─────────────────────
            if !cachedVolumes.isEmpty {
                Section("Locations") {
                    ForEach(cachedVolumes, id: \.self) { url in
                        sidebarDropRow(url: url, tag: SidebarItem.location(url)) {
                            SidebarRow(url: url)
                                .onTapGesture { go(url) }
                                .contextMenu {
                                    Button("Show in Finder") {
                                        FinderReveal.reveal([url])
                                    }
                                }
                        }
                    }
                }
            }

            // ── Recent ────────────────────────────────────────────────────
            if !recentFolders.isEmpty {
                Section("Recent") {
                    ForEach(recentFolders.prefix(8), id: \.self) { url in
                        sidebarDropRow(url: url, tag: SidebarItem.recent(url)) {
                            SidebarRow(url: url)
                                .onTapGesture { go(url) }
                        }
                    }
                }
            }

            // ── Tags (only when files in current folder are tagged) ────────
            if !usedTagNames.isEmpty {
                Section("Tags") {
                    ForEach(usedTagNames, id: \.self) { tag in
                        if let fileOps, let onReload {
                            TagDropWrapper(tag: tag, fileOps: fileOps, onReload: onReload) {
                                tagRow(tag: tag)
                            }
                        } else {
                            tagRow(tag: tag)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { loadRecent(); refreshVolumes(); refreshCloudFolders() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshVolumes(); refreshCloudFolders() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshVolumes(); refreshCloudFolders() }
        .onChange(of: cloudFolders.customURLs) { _, _ in refreshCloudFolders() }
        .onChange(of: currentPath) { _, path in
            if path.hasDirectoryPath { addToRecent(path) }
            syncSelection(to: path)
        }
    }

    /// Navigacija iz sidebara: nova putanja otvara folder, ponovni klik na
    /// vec otvoreni folder osvezava prikaz (ranije drugi klik nije radio nista
    /// jer se `currentPath` nije promenio pa nije bilo reload-a).
    private func go(_ url: URL) {
        selection = item(for: url) ?? selection
        // /tmp i /private/tmp su isti folder — bez lažne navigacije/duplog history-ja.
        if ffSamePath(currentPath, url) {
            onReload?()
        } else {
            // Oznaka prvo, navigacija u sljedećem prolazu run loop-a. Kad su
            // išle zajedno, oznaka u sidebaru se pomjerala tek kad se nova
            // lista složi — izmjereno +224…288 ms posle klika (Downloads ↔
            // Desktop ↔ Documents), pa je klik djelovao kao da nije primljen.
            // Ovako se oznaka nacrta za ~20 ms, a lista stiže odmah za njom.
            DispatchQueue.main.async { currentPath = url }
        }
    }

    /// Mapira URL u SidebarItem za highlight. Redosled: system → pinned →
    /// recent → cloud/volumes (location). Poređenja su kanonska da /tmp i
    /// /private/tmp daju isti highlight.
    private func item(for url: URL) -> SidebarItem? {
        if systemLocations.contains(where: { ffSamePath($0, url) }) { return .location(url) }
        if favorites.pinnedURLs.contains(where: { ffSamePath($0, url) }) { return .pinned(url) }
        if recentFolders.contains(where: { ffSamePath($0, url) }) { return .recent(url) }
        return .location(url)
    }

    private func syncSelection(to path: URL) {
        // Ne gazi tag-selekciju dok korisnik nije navigirao (selection==nil za tagove se drzi van List selection-a).
        selection = item(for: path)
    }

    /// Sidebar row that also accepts file drops onto its folder.
    @ViewBuilder
    private func sidebarDropRow<Content: View>(url: URL, tag: SidebarItem, @ViewBuilder content: @escaping () -> Content) -> some View {
        if let fileOps, let onReload {
            SidebarDropWrapper(destination: url, fileOps: fileOps, onReload: onReload,
                               onSpringOpen: { go($0) }, content: content)
                // Drag-out: folder proxy to Finder / other panes (same as Finder).
                .onDrag { FileDragSupport.provider(for: [url]) }
                .tag(tag)
        } else {
            content()
                .onDrag { FileDragSupport.provider(for: [url]) }
                .tag(tag)
        }
    }

    /// Volume enumeration off the main thread; result cached for renders.
    private func refreshVolumes() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey],
                                            options: [.skipHiddenVolumes]) ?? []
            let home = fm.homeDirectoryForCurrentUser.path
            let filtered = vols.filter { url in
                !home.hasPrefix(url.path) || url.path == "/"
            }
            .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async { cachedVolumes = filtered }
        }
    }

    private var mountedVolumes: [URL] { cachedVolumes }

    // MARK: - Cloud folders (Google Drive, iCloud Drive, OneDrive, Dropbox…)

    /// Svi cloud sync folderi su obični lokalni folderi — zato rade bez mrežnog
    /// koda, naloga i telemetrije: samo ih prikažemo kao prečice u sidebaru.
    /// Spaja auto-detekciju sa ručno dodatim nalozima.
    private func refreshCloudFolders() {
        let custom = cloudFolders.existingCustomURLs
        DispatchQueue.global(qos: .utility).async {
            let auto = Self.detectedCloudFolders()
            var seen = Set<String>()
            var merged: [URL] = []
            for url in custom + auto {
                let key = url.resolvingSymlinksInPath().path
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                merged.append(url)
            }
            merged.sort {
                SidebarRow.cloudDisplayName(for: $0)
                    .localizedCaseInsensitiveCompare(SidebarRow.cloudDisplayName(for: $1)) == .orderedAscending
            }
            let result = merged
            DispatchQueue.main.async { cachedCloudFolders = result }
        }
    }

    static func detectedCloudFolders() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        // 1. ~/Library/CloudStorage/* — tu žive Google Drive, OneDrive, Dropbox, Box
        //    npr. ~/Library/CloudStorage/GoogleDrive-user@gmail.com
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: cloudStorage,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) {
            for url in children {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    candidates.append(url)
                }
            }
        }

        // 2. iCloud Drive — standardna macOS lokacija
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            candidates.append(iCloud)
        }

        // 3. Legacy / ručne lokacije (stari installer-i, custom putanje)
        for name in ["Google Drive", "GoogleDrive", "My Drive",
                     "Dropbox", "Dropbox (Personal)",
                     "OneDrive", "OneDrive - Personal",
                     "Box", "pCloud Drive", "Tresorit"] {
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                candidates.append(url)
            }
        }

        // Dedupe po resolved path + sort po lepom imenu
        var seen = Set<String>()
        let unique = candidates.filter { url in
            let key = url.resolvingSymlinksInPath().path
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        return unique.sorted {
            SidebarRow.cloudDisplayName(for: $0)
                .localizedCaseInsensitiveCompare(SidebarRow.cloudDisplayName(for: $1)) == .orderedAscending
        }
    }

    /// System locations se ne menjaju tokom sesije — ranije su se 4
    /// FileManager lookup-a (home + desktop/documents/downloads) plaćala na
    /// SVAKU evaluaciju body-ja (svaki klik), plus ponovo u item(for:).
    private static let systemLocationURLs: [URL] = {
        let fm = FileManager.default
        return [
            fm.homeDirectoryForCurrentUser,
            fm.urls(for: .desktopDirectory,  in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }
    }()

    private var systemLocations: [URL] { Self.systemLocationURLs }

    private func loadRecent() {
        recentFolders = (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addToRecent(_ url: URL) {
        // Debounced UserDefaults write — navigation previously wrote to disk on
        // every folder change. Coalesce rapid Back/Forth into one write/sec.
        RecentStore.shared.record(url) { recentFolders = $0 }
    }

    @ViewBuilder
    private func tagRow(tag: String) -> some View {
        let isActive = activeTagFilter == tag
        let dotColor = FileItem.colorForTagName(tag) ?? Color(nsColor: .systemGray)
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            Text(tag)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isActive ? Color.accentColor.opacity(0.13) : Color.clear)
        .clipShape(FFTheme.controlShape)
        .overlay(
            FFTheme.controlShape
                .strokeBorder(Color.accentColor.opacity(isActive ? 0.35 : 0), lineWidth: 1)
        )
        .onTapGesture {
            activeTagFilter = isActive ? nil : tag
        }
    }
}

// MARK: - Debounced recent-folders store (limits UserDefaults disk writes)

/// Coalesces rapid navigation (Back/Forth, column drill-down) into at most
/// one UserDefaults write per second. Previously every `currentPath` change
/// did a synchronous read-modify-write to disk.
final class RecentStore {
    static let shared = RecentStore()
    private let queue = DispatchQueue(label: "FinderFlow.recentStore")
    private var pending: [String] = []
    private var flushWork: DispatchWorkItem?
    private var lastFlush = Date.distantPast
    private var seeded = false
    private init() {}

    /// Seed in-memory pending from disk once, so the first record() after
    /// relaunch doesn't overwrite history with a single entry.
    private func ensureSeeded() {
        guard !seeded else { return }
        seeded = true
        pending = (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
    }

    func record(_ url: URL, completion: @escaping ([URL]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureSeeded()
            self.pending.removeAll { $0 == url.path }
            self.pending.insert(url.path, at: 0)
            self.pending = Array(self.pending.prefix(20))
            let snapshot = self.pending
            let recent = Array(snapshot.prefix(8)).compactMap { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async { completion(recent) }
            self.scheduleFlush(paths: snapshot)
        }
    }

    private func scheduleFlush(paths: [String]) {
        flushWork?.cancel()
        let elapsed = Date().timeIntervalSince(lastFlush)
        let delay: TimeInterval = elapsed >= 1.0 ? 0.25 : 1.0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                let latest = self.pending
                self.lastFlush = Date()
                DispatchQueue.global(qos: .utility).async {
                    UserDefaults.standard.set(Array(latest.prefix(20)), forKey: "recentFolders")
                }
            }
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

struct SidebarRow: View {
    let url: URL
    let subtitle: String?
    @Environment(\.ffCompactRows) private var compact
    init(url: URL, subtitle: String? = nil) {
        self.url = url
        self.subtitle = subtitle
    }
    private var displayName: String { Self.cloudDisplayName(for: url) }
    /// Lepa imena za cloud foldere: "GoogleDrive-user@gmail.com" → "Google Drive",
    /// "com~apple~CloudDocs" → "iCloud Drive". Obični folderi zadržavaju svoje ime.
    static func cloudDisplayName(for url: URL) -> String {
        let last = url.lastPathComponent
        if last == "com~apple~CloudDocs" { return "iCloud Drive" }
        let lower = last.lowercased()
        if lower.hasPrefix("googledrive") { return "Google Drive" }
        if lower.hasPrefix("onedrive") { return "OneDrive" }
        if lower.hasPrefix("dropbox") { return "Dropbox" }
        if lower == "box" || lower.hasPrefix("box-") { return "Box" }
        if !last.isEmpty { return last }
        return "Macintosh HD"
    }
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            URLIconView(url: url, isDirectory: true, isPackage: false, size: 16)
                .frame(width: 20, height: 20)
        }
        .padding(.vertical, compact ? 1 : 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar drop wrapper (state per row)

/// Highlights one sidebar row while a file drag hovers it. Plain @State,
/// no observable object per row — the rows re-render on every selection
/// change and a @StateObject each would add up.
private struct SidebarDropWrapper<Content: View>: View {
    let destination: URL
    let fileOps: FileOperationsService
    let onReload: () -> Void
    /// Spring-open after 0.8 s hover (same as folder rows): navigates into
    /// the hovered sidebar folder mid-drag so drops can drill deeper.
    var onSpringOpen: ((URL) -> Void)? = nil
    let content: () -> Content

    @State private var isTargeted = false
    @State private var dropIsCopy = false
    @State private var dropSources: [URL] = []
    @State private var springWork: DispatchWorkItem?

    var body: some View {
        DropHighlight(isTargeted: isTargeted, isCopy: dropIsCopy, content: content)
            .onDrop(of: [.fileURL, .text],
                    delegate: SidebarRowDropDelegate(destination: destination,
                                                     fileOps: fileOps,
                                                     onReload: onReload,
                                                     isTargeted: $isTargeted,
                                                     dropIsCopy: $dropIsCopy,
                                                     sources: $dropSources))
            .onChange(of: isTargeted) { _, targeted in
                springWork?.cancel()
                springWork = nil
                if targeted, let spring = onSpringOpen {
                    let dest = destination
                    let work = DispatchWorkItem { spring(dest) }
                    springWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                }
            }
    }
}

/// Struct delegate (see RowDropDelegate): zero cost until a drag hovers.
/// Resolves source URLs on hover so the volume rule (same-volume → move,
/// cross-volume → copy) drives the indicator — same as folder rows.
private struct SidebarRowDropDelegate: DropDelegate {
    let destination: URL
    let fileOps: FileOperationsService
    let onReload: () -> Void
    @Binding var isTargeted: Bool
    @Binding var dropIsCopy: Bool
    @Binding var sources: [URL]

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        sources = []
        dropIsCopy = NSEvent.modifierFlags.contains(.option)
        FileDropSupport.hoverCursor(valid: true)
        let dest = destination
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { return }
            sources = urls
            dropIsCopy = !FileDropSupport.shouldMove(sources: urls, destination: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let copy: Bool
        if sources.isEmpty {
            copy = NSEvent.modifierFlags.contains(.option)
        } else {
            copy = !FileDropSupport.shouldMove(sources: sources, destination: destination)
        }
        dropIsCopy = copy
        return DropProposal(operation: copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        sources = []
        FileDropSupport.hoverCursor(valid: false)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        FileDropSupport.hoverCursor(valid: false)
        let dest = destination
        let ops = fileOps
        let reload = onReload
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
        }
        return true
    }
}

// MARK: - Tag drop wrapper (drop-to-tag on sidebar tag rows)

/// Wraps a tag row so dropped files get that Finder tag applied.
private struct TagDropWrapper<Content: View>: View {
    let tag: String
    let fileOps: FileOperationsService
    let onReload: () -> Void
    let content: () -> Content

    @State private var isTargeted = false

    var body: some View {
        content()
            .overlay(
                FFTheme.controlShape
                    .strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0)
                    .background(
                        FFTheme.controlShape
                            .fill(Color.accentColor.opacity(isTargeted ? 0.10 : 0))
                    )
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) {
                if isTargeted {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onDrop(of: [.fileURL, .text],
                    delegate: TagDropDelegate(tag: tag,
                                              fileOps: fileOps,
                                              onReload: onReload,
                                              isTargeted: $isTargeted))
    }
}

private struct TagDropDelegate: DropDelegate {
    let tag: String
    let fileOps: FileOperationsService
    let onReload: () -> Void
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func dropExited(info: DropInfo)  { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let tagName = tag
        let ops = fileOps
        let reload = onReload
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            // Toggle the tag on each dropped URL: if it already has the tag,
            // remove it; otherwise add. Same semantics as TagMenuContent.
            for url in urls {
                ops.toggleColorTag(tagName, on: [url], reload: {})
            }
            reload()
            DispatchQueue.main.async {
                for url in urls {
                    NotificationCenter.default.post(name: .refreshDirectory,
                                                    object: url.deletingLastPathComponent())
                }
            }
        }
        return true
    }
}
