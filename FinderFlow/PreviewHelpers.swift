import SwiftUI
import AppKit

// MARK: - Folder read error views (never silently empty)
//
// Klik na Desktop/Downloads/Documents/Google Drive je "radio" (navigacija se
// desila) ali se folder prikazivao kao prazan: greska citanja (uskracena TCC
// dozvola, ugasen Drive, obrisan folder) gutala se u `try?` -> `[]`. Sada se
// razlog vidi i nude se akcije: ponovni pokusaj, otvaranje u Finderu (Finder
// ima svoja sistemska prava pa radi i kad smo mi odbijeni) i Privacy Settings.

/// Pun ekran umesto liste kad folder ne može da se pročita (i nema šta da se prikaže).
struct FolderErrorView: View {
    let url: URL
    let error: FolderReadError
    var onRetry: (() -> Void)? = nil
    var onGoHome: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.red.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.orange.opacity(0.30), radius: 12, y: 4)
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(error.title)
                .font(.system(size: 13, weight: .semibold))
            Text("“\(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)” — \(error.message)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint = error.recoveryHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                if case .notFound = error {
                    if let onGoHome {
                        Button("Go to Home") { onGoHome() }
                            .buttonStyle(.link)
                    }
                } else {
                    if onRetry != nil {
                        Button("Try Again") { onRetry?() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                if case .noPermission = error {
                    Button("Open Privacy Settings") {
                        Self.openPrivacySettings()
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var iconName: String {
        switch error {
        case .noPermission: return "lock.shield"
        case .notFound:     return "folder.badge.questionmark"
        case .underlying:   return "exclamationmark.triangle"
        }
    }

    /// Sistemska Privacy & Security podešavanja (Files and Folders).
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Uska traka upozorenja iznad liste kad ima keširanih fajlova ali je svež
/// refresh pao (npr. dozvola ukinuta u međuvremenu) — fajlovi ostaju vidljivi.
struct FolderErrorBanner: View {
    let error: FolderReadError
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if error == .noPermission(error.url) {
                Button("Privacy Settings") {
                    FolderErrorView.openPrivacySettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if onRetry != nil {
                Button("Retry") { onRetry?() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

// MARK: - Shared empty / summary / archive views (FinderFlow+ UI improvement)
//
// Small reusable pieces used by list / icon / column views and the preview
// panel so empty folders, folder selections and archives all get a proper
// first-class presentation instead of a blank panel.

/// App-modal rename prompt used by views without inline rename (Icons,
/// Columns search results, SelectionActionBar fallback). List keeps inline
/// rename via pendingRenameURL.
enum FileRenamePrompt {
    static func rename(_ item: FileItem, fileOps: FileOperationsService, reload: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText     = "Rename \"\(item.name)\""
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = item.name; tf.selectText(nil)
        alert.accessoryView = tf
        alert.window.initialFirstResponder = tf
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: reload)
    }
}

struct LoadingFolderView: View {
    let folderName: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
                .accessibilityLabel("Loading folder contents")
            Text("Loading “\(folderName)”…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct EmptyFolderView: View {
    let folderName: String
    let isSearching: Bool
    let onCreateFolder: (() -> Void)?
    let onCreateFile: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(FFTheme.heroGradient)
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.accentColor.opacity(0.30), radius: 12, y: 4)
                Image(systemName: isSearching ? "magnifyingglass" : "folder.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(isSearching ? "No matches" : "“\(folderName)” is empty")
                .font(.system(size: 13, weight: .semibold))
            Text(isSearching
                 ? "Try a different name, extension (.pdf) or scope."
                 : "Create something to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !isSearching, onCreateFolder != nil || onCreateFile != nil {
                HStack(spacing: 16) {
                    if let onCreateFolder {
                        Button { onCreateFolder() } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.link)
                    }
                    if let onCreateFile {
                        Button { onCreateFile() } label: {
                            Label("New File", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct FolderSummaryView: View {
    let item: FileItem
    let childCount: Int?
    let totalBytes: Int64?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(FFTheme.softGradient)
                    .frame(width: 72, height: 72)
                FileIconView(item: item, size: 40)
            }
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            TagDotsView(colors: item.tagColors, size: 9)
            if let childCount, let totalBytes {
                Text("\(childCount) \(childCount == 1 ? "item" : "items")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .ffBadge()
                if totalBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // Recursive total from the sizing run (opt-in "Calculate folder
                // sizes") — arrives via the item itself, no extra I/O here.
                if let recursive = item.folderSize {
                    Text("\(ByteCountFormatter.string(fromByteCount: recursive, countStyle: .file)) total on disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                ProgressView().scaleEffect(0.7)
                Text("Counting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Modified \(item.formattedDateModified)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct FolderSummaryLoader: View {    let item: FileItem

    @State private var childCount: Int? = nil
    @State private var totalBytes: Int64? = nil
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        FolderSummaryView(item: item, childCount: childCount, totalBytes: totalBytes)
            .onAppear { load() }
            .onDisappear { loadTask?.cancel() }
            .onChange(of: item.id) { _, _ in
                childCount = nil; totalBytes = nil
                load()
            }
    }

    private func load() {
        let url = item.url
        // Keširan summary: ponovni klik na isti folder (napred-nazad,
        // stepovanje strelicama) više ne lista direktorijum svaki put.
        // Stamp-validirano kao DirectoryCache — izmena unutra invalidira.
        if let hit = FolderSummaryCache.shared.get(dir: url) {
            childCount = hit.count
            totalBytes = hit.bytes
            return
        }
        loadTask?.cancel()
        loadTask = Task {
            let stamp = DirectoryCache.Stamp.of(url)
            let (count, bytes) = await withCheckedContinuation { (cont: CheckedContinuation<(Int, Int64), Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
                    let urls = (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: opts
                    )) ?? []
                    var total: Int64 = 0
                    for u in urls {
                        if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                           v.isDirectory != true {
                            total += Int64(v.fileSize ?? 0)
                        }
                    }
                    cont.resume(returning: (urls.count, total))
                }
            }
            guard !Task.isCancelled else { return }
            FolderSummaryCache.shared.set(dir: url, count: count, bytes: bytes, stamp: stamp)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                childCount = count
                totalBytes = bytes
            }
        }
    }
}

// MARK: - Folder contents preview (scrollable, clickable list inside preview)
//
// Folderi su u preview panelu ranije pokazivali samo summary (broj + velicinu)
// ili prazan QL view — sada se vidi scrollabilna lista dece na koju se moze
// kliknuti: jedan klik samo highlightuje red, dupli klik otvara fajl istim
// putem kao glavni prikaz (onOpenFile) odnosno ulazi u subfolder (onEnterFolder).
// Fajl-preview (QL + info kartica) se ne dira.

struct FolderContentsPreview: View {
    /// Koliko redova se max crta u preview-u; ostalo ide preko footera.
    static let maxRows = 300

    let item: FileItem
    var showHidden: Bool = false
    var onOpenFile: (FileItem) -> Void = { _ in }
    var onEnterFolder: (URL) -> Void = { _ in }
    var onRevealInMain: (() -> Void)? = nil

    @State private var children: [FileItem]? = nil
    @State private var loadError: FolderReadError? = nil
    @State private var isLoading = true
    @State private var innerSelection: URL? = nil
    @State private var loadTask: Task<Void, Never>?

    private var totalCount: Int { children?.count ?? 0 }
    private var totalBytes: Int64 {
        children?.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } ?? 0
    }
    private var visible: [FileItem] {
        guard let children else { return [] }
        return children.count > Self.maxRows ? Array(children.prefix(Self.maxRows)) : children
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: item.id) { _, _ in resetAndLoad() }
        .onChange(of: showHidden) { _, _ in resetAndLoad() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FileIconView(item: item, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                if let children {
                    HStack(spacing: 6) {
                        Text("\(children.count) \(children.count == 1 ? "item" : "items")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .ffBadge()
                        if totalBytes > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Text("Modified \(item.formattedDateModified)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Counting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError, (children == nil || children?.isEmpty == true), !isLoading {
            FolderErrorView(url: item.url, error: err, onRetry: { resetAndLoad() })
        } else if isLoading, children == nil {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Text("Loading folder…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let children, children.isEmpty {
            EmptyFolderView(folderName: item.name, isSearching: false,
                            onCreateFolder: nil, onCreateFile: nil)
        } else {
            VStack(spacing: 0) {
                if let err = loadError {
                    FolderErrorBanner(error: err, onRetry: { resetAndLoad() })
                }
                List(visible, id: \.id) { child in
                    row(for: child)
                }
                .listStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if totalCount > Self.maxRows {
            Divider().opacity(0.6)
            VStack(spacing: 4) {
                Text("Showing first \(Self.maxRows) of \(totalCount)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Show all in main view") {
                    if let onRevealInMain { onRevealInMain() }
                    else { onEnterFolder(item.url) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.vertical, 8)
        }
    }

    private func row(for child: FileItem) -> some View {
        let isSelected = innerSelection == child.url
        return HStack(spacing: 8) {
            FileIconView(item: child, size: 16)
                .frame(width: 20, height: 20)
            Text(child.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            TagDotsView(colors: child.tagColors, size: 9)
            Spacer(minLength: 4)
            if child.isBrowsableFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            FFTheme.controlShape
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            FFTheme.controlShape
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.30 : 0), lineWidth: 1)
        )
        .onTapGesture {
            innerSelection = child.url
            guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
            if child.isBrowsableFolder { onEnterFolder(child.url) }
            else { onOpenFile(child) }
        }
        .help(child.url.path)
    }

    private func resetAndLoad() {
        loadTask?.cancel()
        children = nil
        loadError = nil
        isLoading = true
        innerSelection = nil
        load()
    }

    private func load() {
        let url = item.url
        let hidden = showHidden
        // Kesirani listing: trenutni klik se vidi odmah, sveza provera stize iza.
        if let snapshot = DirectoryCache.shared.cachedItems(for: url, showHidden: hidden) {
            children = sortedItems(snapshot, by: .name, ascending: true, folderOrder: .foldersFirst)
            isLoading = false
        } else if children == nil {
            isLoading = true
        }
        loadTask?.cancel()
        loadTask = Task {
            let res: (items: [FileItem], error: FolderReadError?) = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: loadItems(at: url, showHidden: hidden))
                }
            }
            guard !Task.isCancelled else { return }
            let sorted = sortedItems(res.items, by: .name, ascending: true, folderOrder: .foldersFirst)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                children = sorted
                loadError = res.error
                isLoading = false
            }
        }
    }
}

/// Stamp-validiran keš folder summary-ja (broj dece + zbir veličina fajlova).
/// FolderSummaryLoader je pre listao direktorijum na SVAKU selekciju foldera
/// (svaki klik sa otvorenim preview-om = readdir + stat po detetu) — sada
/// ponovljene selekcije čitaju keš (jedan stat), a izmena sadržaja invalidira.
private final class FolderSummaryCache {
    static let shared = FolderSummaryCache()

    private struct Entry {
        let count: Int
        let bytes: Int64
        let stamp: DirectoryCache.Stamp?
        let listedAt: Date
    }

    private var store: [String: Entry] = [:]
    private let lock = NSLock()
    private let maxEntries = 500

    func get(dir: URL) -> (count: Int, bytes: Int64)? {
        lock.lock()
        let found = store[dir.path]
        lock.unlock()
        guard let e = found else { return nil }
        // Ista 2s ograda kao DirectoryCache.isCurrent: fajl sistemi sa
        // 1s granularnošću ne razlikuju izmenu u tom prozoru.
        guard let listed = e.stamp else { return (e.count, e.bytes) }
        guard let now = DirectoryCache.Stamp.of(dir), now == listed,
              e.listedAt.timeIntervalSince(listed.date) >= 2 else {
            lock.lock()
            if store[dir.path]?.listedAt == e.listedAt { store.removeValue(forKey: dir.path) }
            lock.unlock()
            return nil
        }
        return (e.count, e.bytes)
    }

    func set(dir: URL, count: Int, bytes: Int64, stamp: DirectoryCache.Stamp?) {
        lock.lock(); defer { lock.unlock() }
        if store.count >= maxEntries { store.removeAll() }
        store[dir.path] = Entry(count: count, bytes: bytes, stamp: stamp, listedAt: Date())
    }
}

struct ArchivePreviewView: View {
    let item: FileItem
    let onExtract: () -> Void

    @State private var entries: [String]? = nil
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.softGradient)
                        .frame(width: 48, height: 48)
                    FileIconView(item: item, size: 30)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text("\(ArchiveService.displayName(for: item.url)) • \(item.formattedSize)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.medium)
                }
                Spacer()
            }
            .padding(12)

            Divider().opacity(0.6)

            if let entries {
                if entries.isEmpty {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(FFTheme.softGradient)
                                .frame(width: 56, height: 56)
                            Image(systemName: "archivebox")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("Can't preview contents")
                            .font(.system(size: 12, weight: .semibold))
                        Text("You can still extract it here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(entries, id: \.self) { e in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(e).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                    if entries.count >= 100 {
                        Text("Showing first 100 entries")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            } else {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Text("Reading archive…")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 6)
                Spacer()
            }

            Divider().opacity(0.6)

            Button("Extract Here") { onExtract() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.vertical, 10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: item.id) { _, _ in
            entries = nil
            load()
        }
    }

    private func load() {
        let url = item.url
        loadTask?.cancel()
        loadTask = Task {
            let list = await ArchiveService.listContents(of: url, limit: 100)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                entries = list
            }
        }
    }
}
