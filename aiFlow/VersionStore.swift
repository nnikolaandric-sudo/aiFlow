import Combine
import Compression
import CoreServices
import CryptoKit
import Darwin
import Foundation

// MARK: - Version History (engine)
//
// Every document in a tracked folder gets a version tree, whatever its type:
//   Save → v2, Save again → v3; Save As / Duplicate of v3 → v3.1, and editing
//   that copy → v3.2, v3.3. The main file keeps going: v4, v5…
//
// Tracked = every Workspace folder + folders the user turns on (right-click
// ▸ Track Versions). FSEvents reports changes; after the file settles, its
// content is cloned (APFS clonefile — no extra space until the file changes)
// into Application Support/FinderFlow/Versions/blobs, named by SHA-256, so
// identical content is stored once.
//
// A new file is compared with recently worked-on documents: same content, or
// the same parts inside a .docx/.xlsx/.pptx zip, or mostly the same text or
// bytes → it is a branch of that version. Unsure → a suggestion the user
// accepts or dismisses ("Create branch v3.1 / Keep separate").
//
// History is capped at 5 GB: the oldest versions lose their stored copy first
// (never a file's current version, never its last 3). Files over 500 MB are
// not copied. Nothing here ever touches the user's files except Restore /
// Duplicate, which the user asks for; Restore first saves the current state.
//
// Foundation-only (no AppKit/SwiftUI): tests drive it headless with
// FF_VERSIONS_DIR and the *Sync entry points.

struct DocVersion: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// "v3", "v3.1", "v3.1.1".
    var label: String
    /// The file's modification date when captured.
    var date: Date
    var capturedAt: Date = Date()
    var size: Int64
    var sha256: String
    /// Blob file name in blobs/, nil when pruned (over the storage cap).
    var blob: String?
    /// "Restored from v2", "Created from Ugovor.docx v3", "Renamed from …".
    var note: String?

    var isKept: Bool { blob != nil }
}

/// One file's history. The first line of a family is the main line; the
/// others branched from a version (`base`).
struct VersionLine: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var path: String
    var base: String?
    /// The file vanished (deleted or moved out of tracked folders).
    var missingSince: Date?
    var versions: [DocVersion]

    var name: String { (path as NSString).lastPathComponent }
    var current: DocVersion? { versions.last }
}

struct VersionFamily: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var lines: [VersionLine]

    var main: VersionLine { lines[0] }
    var branchCount: Int { lines.count - 1 }

    /// Next label for a line: v(N+1) on the main line; for a branch the next
    /// free child number of its base ("v3.1", "v3.2" — shared by every
    /// branch of v3, so labels stay unique).
    func nextLabel(forLine index: Int) -> String {
        let line = lines[index]
        guard let base = line.base else {
            let n = line.versions.compactMap { Int($0.label.dropFirst()) }.max() ?? 0
            return "v\(n + 1)"
        }
        return Self.childLabel(of: base, in: self)
    }

    static func childLabel(of base: String, in family: VersionFamily?) -> String {
        let prefix = base + "."
        var maxChild = 0
        for line in family?.lines ?? [] {
            for v in line.versions where v.label.hasPrefix(prefix) {
                let rest = v.label.dropFirst(prefix.count)
                if !rest.contains("."), let n = Int(rest) { maxChild = max(maxChild, n) }
            }
        }
        return "\(base).\(maxChild + 1)"
    }

    func version(labeled label: String) -> (line: Int, version: Int)? {
        for (li, line) in lines.enumerated() {
            if let vi = line.versions.firstIndex(where: { $0.label == label }) { return (li, vi) }
        }
        return nil
    }
}

/// "This file appears to be a new version of Ugovor.docx v3."
struct ForkSuggestion: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var newPath: String
    var familyID: String
    var baseLabel: String
    var baseName: String
    var score: Double
    var date: Date = Date()
}

struct VersionIndex: Codable, Equatable {
    var families: [VersionFamily] = []
    /// Folders the user turned on (workspaces are always tracked).
    var folders: [String] = []
    var suggestions: [ForkSuggestion] = []
    /// Roots whose existing files already got their v1.
    var scannedRoots: [String] = []
    var enabled = true
}

// MARK: - Store

final class VersionStore: ObservableObject {
    static let shared = VersionStore()

    /// 5 GB of history (FF_VERSIONS_CAP overrides it in tests).
    static var capBytes: Int64 = ProcessInfo.processInfo.environment["FF_VERSIONS_CAP"].flatMap { Int64($0) }
        ?? 5_000_000_000
    /// Decimal, like Finder and the Settings readout ("5 GB", "500 MB").
    static let maxFileBytes: Int64 = 500_000_000
    static let keepPerLine = 3

    /// Bumped on every change (views and list badges observe it).
    @Published private(set) var version: UInt = 0
    /// Main-thread copy of the index for views.
    @Published private(set) var index = VersionIndex()
    @Published private(set) var historyBytes: Int64 = 0

    private var labelByPath: [String: String] = [:]
    private var lineByPath: [String: (family: String, line: String)] = [:]

    // Queue-owned state
    private let queue = DispatchQueue(label: "FinderFlow.versions", qos: .utility)
    private var work = VersionIndex()
    private var roots: [String] = []
    private var pending = Set<String>()
    private var flushItem: DispatchWorkItem?
    private var saveItem: DispatchWorkItem?
    private var watcher: VersionWatcher?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    var storeDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FF_VERSIONS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FinderFlow/Versions", isDirectory: true)
    }
    private var indexFile: URL { storeDir.appendingPathComponent("index.json") }
    var blobsDir: URL { storeDir.appendingPathComponent("blobs", isDirectory: true) }

    init() {
        queue.sync { loadLocked() }
        publish(work)
    }

    // MARK: Lifecycle

    /// App launch: watch tracked roots, catch up on changes made while the
    /// app was closed, keep roots in sync with Workspaces.
    func start() {
        guard !started else { return }
        started = true
        // Version labels ride along the workspace badges in every file list.
        WorkspaceStore.versionLabelProvider = { [weak self] url in self?.label(for: url) }
        WorkspaceStore.shared.$workspaces
            .map { $0.map(\.rootPath) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rootsChanged() }
            .store(in: &cancellables)
        rootsChanged()
    }

    /// Workspace roots + user folders, deduplicated, nested ones dropped.
    func trackedRoots() -> [String] {
        let ws = WorkspaceStore.shared.workspaces.map(\.rootPath)
        let all = Set((ws + index.folders).map { Self.canonical($0) })
        let sorted = all.sorted()
        return sorted.filter { p in !sorted.contains { $0 != p && p.hasPrefix($0 + "/") } }
    }

    private func rootsChanged() {
        let r = index.enabled ? trackedRoots() : []
        queue.async { [weak self] in
            guard let self else { return }
            self.roots = r
            if self.watcher == nil {
                self.watcher = VersionWatcher(queue: self.queue) { [weak self] paths in self?.enqueue(paths) }
            }
            self.watcher?.watch(r)
            for root in r where !self.work.scannedRoots.contains(root) { self.scanLocked(root: root, baseline: true) }
            self.catchUpLocked()
        }
    }

    // MARK: Queries (main thread)

    /// One spelling per file, the one FSEvents reports: realpath() of the
    /// folder (a directory itself when it exists) + the name. Not
    /// resolvingSymlinksInPath — it drops "/private" only while the file
    /// exists, so a deleted file would stop matching its history.
    static func canonical(_ path: String) -> String {
        let std = URL(fileURLWithPath: path).standardizedFileURL
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue, let r = real(std.path) {
            return r
        }
        var dir = std.deletingLastPathComponent()
        var tail = [std.lastPathComponent]
        while dir.path != "/" {
            if let r = real(dir.path) { return ([r == "/" ? "" : r] + tail.reversed()).joined(separator: "/") }
            tail.append(dir.lastPathComponent)
            dir = dir.deletingLastPathComponent()
        }
        return std.path
    }

    /// Per visible list row: dictionary lookups (paths are registered in
    /// both spellings, see `keys(for:)`), no realpath per row.
    func label(for url: URL) -> String? {
        labelByPath[url.path] ?? labelByPath[url.standardizedFileURL.path]
    }

    /// Foundation's standardized paths drop "/private" when the file exists
    /// (/private/tmp → /tmp), realpath keeps it: register both.
    private static func keys(for path: String) -> [String] {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        return std == path ? [path] : [path, std]
    }

    func isTracked(_ url: URL) -> Bool {
        let p = Self.canonical(url.path)
        return trackedRoots().contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    func isUserFolder(_ url: URL) -> Bool { index.folders.contains(Self.canonical(url.path)) }

    func family(for url: URL) -> (family: VersionFamily, line: Int)? {
        let key = lineByPath[url.path] ?? lineByPath[url.standardizedFileURL.path] ?? lineByPath[Self.canonical(url.path)]
        guard let key, let fam = index.families.first(where: { $0.id == key.family }),
              let li = fam.lines.firstIndex(where: { $0.id == key.line }) else { return nil }
        return (fam, li)
    }

    func suggestion(for url: URL) -> ForkSuggestion? {
        let p = Self.canonical(url.path)
        return index.suggestions.first { $0.newPath == p }
    }

    func blobURL(_ v: DocVersion) -> URL? {
        guard let b = v.blob else { return nil }
        let u = blobsDir.appendingPathComponent(b)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: Settings (main thread)

    func setFolderTracked(_ url: URL, _ on: Bool) {
        let p = Self.canonical(url.path)
        mutate { idx in
            if on { if !idx.folders.contains(p) { idx.folders.append(p) } }
            else { idx.folders.removeAll { $0 == p }; idx.scannedRoots.removeAll { $0 == p } }
        }
    }

    func setEnabled(_ on: Bool) {
        mutate { $0.enabled = on }
    }

    /// Deletes every stored version (files themselves are untouched).
    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let folders = self.work.folders, enabled = self.work.enabled
            try? FileManager.default.removeItem(at: self.blobsDir)
            self.work = VersionIndex(folders: folders, enabled: enabled)
            self.commitLocked()
        }
    }

    private func mutate(_ block: @escaping (inout VersionIndex) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            block(&self.work)
            self.commitLocked()
            DispatchQueue.main.async { self.rootsChanged() }
        }
    }

    // MARK: Actions (main thread API, work on the queue)

    /// Captures the file now (e.g. "Save Version Now"), even if unchanged.
    func captureNow(_ url: URL, completion: ((String?) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let label = self.captureLocked(Self.canonical(url.path), detectForks: true)
            self.commitLocked()
            DispatchQueue.main.async { completion?(label) }
        }
    }

    /// Puts `version` back into its file. The current state is captured
    /// first; the restore itself becomes the next version ("Restored from v2").
    func restore(_ version: DocVersion, lineID: String, familyID: String,
                 completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let r = Result { try self.restoreLocked(version, lineID: lineID, familyID: familyID) }
            self.commitLocked()
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Writes `version` as a new file next to the original, as a branch of
    /// it ("Ugovor (v2).docx" → v2.1).
    func duplicate(_ version: DocVersion, lineID: String, familyID: String,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let r = Result { try self.duplicateLocked(version, lineID: lineID, familyID: familyID) }
            self.commitLocked()
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// A readable copy of a stored version ("Ugovor v2.docx") for Quick Look
    /// or Compare — the blob itself is never handed out.
    func exportForPreview(_ version: DocVersion, name: String) -> URL? {
        guard let src = blobURL(version) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiFlow-Versions", isDirectory: true)
            .appendingPathComponent(version.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ns = name as NSString
        let ext = ns.pathExtension
        let file = ext.isEmpty ? "\(ns) \(version.label)" : "\(ns.deletingPathExtension) \(version.label).\(ext)"
        let dst = dir.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: dst.path) {
            if clonefile(src.path, dst.path, 0) != 0 {
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        return FileManager.default.fileExists(atPath: dst.path) ? dst : nil
    }

    func acceptSuggestion(_ id: String) {
        queue.async { [weak self] in
            guard let self, let s = self.work.suggestions.first(where: { $0.id == id }) else { return }
            self.work.suggestions.removeAll { $0.id == id }
            self.mergeAsBranchLocked(path: s.newPath, into: s.familyID, base: s.baseLabel,
                                     note: "Created from \(s.baseName) \(s.baseLabel)")
            self.commitLocked()
        }
    }

    func dismissSuggestion(_ id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.work.suggestions.removeAll { $0.id == id }
            self.commitLocked()
        }
    }

    /// Forget one file's history (its stored copies go too, unless shared).
    func forgetLine(_ lineID: String, familyID: String) {
        queue.async { [weak self] in
            guard let self, let fi = self.work.families.firstIndex(where: { $0.id == familyID }),
                  let li = self.work.families[fi].lines.firstIndex(where: { $0.id == lineID }) else { return }
            let blobs = self.work.families[fi].lines[li].versions.compactMap(\.blob)
            if li == 0 {
                self.work.families.remove(at: fi)
            } else {
                self.work.families[fi].lines.remove(at: li)
            }
            self.deleteUnreferencedLocked(blobs)
            self.commitLocked()
        }
    }

    // MARK: Test / harness entry points (synchronous)

    func processSync(_ paths: [String]) {
        queue.sync {
            for p in paths { handleLocked(Self.canonical(p)) }
            commitLocked(flush: true)
        }
        publishNow()
    }

    func scanSync(root: URL, baseline: Bool = true) {
        queue.sync {
            scanLocked(root: Self.canonical(root.path), baseline: baseline)
            commitLocked(flush: true)
        }
        publishNow()
    }

    func setRootsSync(_ list: [URL]) {
        queue.sync { roots = list.map { Self.canonical($0.path) } }
    }

    func resetForTests() {
        queue.sync {
            try? FileManager.default.removeItem(at: storeDir)
            work = VersionIndex()
            roots = []
        }
        publishNow()
    }

    private func publishNow() {
        let snap = queue.sync { work }
        let bytes = queue.sync { historyBytesLocked() }
        if Thread.isMainThread { apply(snap, bytes: bytes) } else { DispatchQueue.main.sync { apply(snap, bytes: bytes) } }
    }

    // MARK: Watching

    private func enqueue(_ paths: [String]) {
        // Called on `queue` by the watcher.
        for p in paths { pending.insert(p) }
        flushItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushLocked() }
        flushItem = item
        // Settle: editors write in several steps (temp file, rename, xattrs).
        queue.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func flushLocked() {
        let batch = pending
        pending.removeAll()
        var retry: [String] = []
        for p in batch.sorted() {
            let path = Self.canonical(p)
            // Still being written: try again shortly.
            if let m = Self.stat(path)?.mtime, Date().timeIntervalSince(m) < 1.0 { retry.append(p); continue }
            handleLocked(path)
        }
        commitLocked()
        if !retry.isEmpty { enqueue(retry) }
    }

    /// Changes made while aiFlow wasn't running: tracked files whose size or
    /// date moved get a new version; files that disappeared are marked.
    private func catchUpLocked() {
        for fi in work.families.indices {
            for li in work.families[fi].lines.indices {
                let line = work.families[fi].lines[li]
                guard inRootsLocked(line.path) else { continue }
                if let st = Self.stat(line.path) {
                    if let cur = line.current, st.size == cur.size, st.mtime == cur.date { continue }
                    _ = captureLocked(line.path, detectForks: false)
                } else if line.missingSince == nil {
                    work.families[fi].lines[li].missingSince = Date()
                }
            }
        }
        for root in roots { scanLocked(root: root, baseline: false) }
        commitLocked()
    }

    // MARK: Engine

    private func inRootsLocked(_ path: String) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func handleLocked(_ path: String) {
        guard work.enabled, inRootsLocked(path) else { return }
        if Self.stat(path) == nil {
            // Gone: keep the history, mark the line (a rename shows up as a
            // new path with the same content and moves the line there).
            for fi in work.families.indices {
                for li in work.families[fi].lines.indices where work.families[fi].lines[li].path == path {
                    if work.families[fi].lines[li].missingSince == nil { work.families[fi].lines[li].missingSince = Date() }
                }
            }
            // A folder that vanished takes its files with it.
            for fi in work.families.indices {
                for li in work.families[fi].lines.indices where work.families[fi].lines[li].path.hasPrefix(path + "/") {
                    if work.families[fi].lines[li].missingSince == nil { work.families[fi].lines[li].missingSince = Date() }
                }
            }
            work.suggestions.removeAll { $0.newPath == path }
            return
        }
        guard VersionRules.isEligible(path) else { return }
        if let st = Self.stat(path), !st.isRegular {
            // A folder appeared (created, renamed, moved in): FSEvents names
            // only the folder, so its files are looked at here — renamed
            // documents keep their history by content.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                scanLocked(root: path, baseline: false)
            }
            return
        }
        _ = captureLocked(path, detectForks: true)
    }

    /// Records the file's current content. Returns the version label.
    @discardableResult
    private func captureLocked(_ path: String, detectForks: Bool) -> String? {
        guard let st = Self.stat(path), st.isRegular, st.size <= Self.maxFileBytes,
              VersionRules.isEligible(path) else { return nil }
        guard let snap = snapshotLocked(path) else { return nil }
        defer { try? FileManager.default.removeItem(at: snap.temp) }

        if let (fi, li) = lineIndexLocked(path: path) {
            var line = work.families[fi].lines[li]
            line.missingSince = nil
            if let cur = line.current, cur.sha256 == snap.sha {
                line.versions[line.versions.count - 1].date = st.mtime
                work.families[fi].lines[li] = line
                return cur.label
            }
            let label = work.families[fi].nextLabel(forLine: li)
            let blob = storeBlobLocked(snap, ext: (path as NSString).pathExtension)
            line.versions.append(DocVersion(label: label, date: st.mtime, size: st.size, sha256: snap.sha, blob: blob))
            work.families[fi].lines[li] = line
            return label
        }

        // New path. A rename/move keeps its history.
        if let (fi, li) = renameCandidateLocked(sha: snap.sha, newPath: path) {
            let old = work.families[fi].lines[li].path
            work.families[fi].lines[li].path = path
            work.families[fi].lines[li].missingSince = nil
            if let last = work.families[fi].lines[li].versions.indices.last {
                let note = "Moved from \((old as NSString).lastPathComponent)"
                if work.families[fi].lines[li].versions[last].note == nil { work.families[fi].lines[li].versions[last].note = note }
            }
            return work.families[fi].lines[li].current?.label
        }

        let blob = storeBlobLocked(snap, ext: (path as NSString).pathExtension)
        if detectForks, let fork = forkCandidateLocked(path: path, snap: snap, size: st.size) {
            let parentName = work.families[fork.family].lines[fork.line].name
            if fork.confident {
                let fam = work.families[fork.family]
                let label = VersionFamily.childLabel(of: fork.base, in: fam)
                let v = DocVersion(label: label, date: st.mtime, size: st.size, sha256: snap.sha, blob: blob,
                                   note: "Created from \(parentName) \(fork.base)")
                work.families[fork.family].lines.append(VersionLine(path: path, base: fork.base, versions: [v]))
                return label
            }
            // Unsure: own history for now, and ask.
            work.families.append(VersionFamily(lines: [VersionLine(path: path, versions: [
                DocVersion(label: "v1", date: st.mtime, size: st.size, sha256: snap.sha, blob: blob)])]))
            work.suggestions.removeAll { $0.newPath == path }
            work.suggestions.append(ForkSuggestion(newPath: path, familyID: work.families[fork.family].id,
                                                   baseLabel: fork.base, baseName: parentName, score: fork.score))
            return "v1"
        }
        work.families.append(VersionFamily(lines: [VersionLine(path: path, versions: [
            DocVersion(label: "v1", date: st.mtime, size: st.size, sha256: snap.sha, blob: blob)])]))
        return "v1"
    }

    private func lineIndexLocked(path: String) -> (Int, Int)? {
        for (fi, fam) in work.families.enumerated() {
            if let li = fam.lines.firstIndex(where: { $0.path == path }) { return (fi, li) }
        }
        return nil
    }

    /// A line whose file is gone (or no longer at its path) and whose last
    /// content equals the new file — the same document, renamed or moved.
    private func renameCandidateLocked(sha: String, newPath: String) -> (Int, Int)? {
        for (fi, fam) in work.families.enumerated() {
            for (li, line) in fam.lines.enumerated() where line.current?.sha256 == sha && line.path != newPath {
                if line.missingSince != nil || Self.stat(line.path) == nil { return (fi, li) }
            }
        }
        return nil
    }

    struct ForkMatch { var family: Int; var line: Int; var base: String; var score: Double; var confident: Bool }

    /// Is the new file a copy / Save As of a tracked document?
    private func forkCandidateLocked(path: String, snap: Snapshot, size: Int64) -> ForkMatch? {
        // 1. Same bytes as any stored version (Duplicate, Finder copy).
        for (fi, fam) in work.families.enumerated() {
            for (li, line) in fam.lines.enumerated() {
                if let v = line.versions.last(where: { $0.sha256 == snap.sha }) {
                    return ForkMatch(family: fi, line: li, base: v.label, score: 1, confident: true)
                }
            }
        }
        // 2. Similar content: same extension, comparable size, recent work.
        let ext = (path as NSString).pathExtension.lowercased()
        let now = Date()
        var best: ForkMatch?
        var candidates: [(fi: Int, li: Int, v: DocVersion, recent: Bool, when: Date)] = []
        for (fi, fam) in work.families.enumerated() {
            for (li, line) in fam.lines.enumerated() where line.path != path {
                guard (line.path as NSString).pathExtension.lowercased() == ext,
                      let cur = line.current, cur.blob != nil else { continue }
                let ratio = Double(size) / Double(max(cur.size, 1))
                guard ratio > 0.5, ratio < 2.0 else { continue }
                let lastUsed = Self.lastUsed(line.path)
                let active = [cur.capturedAt, cur.date, lastUsed ?? .distantPast].max()!
                guard now.timeIntervalSince(active) < 30 * 86_400 else { continue }
                candidates.append((fi, li, cur, now.timeIntervalSince(active) < 2 * 3_600, active))
            }
        }
        candidates.sort { $0.when > $1.when }
        for c in candidates.prefix(20) {
            guard let blob = c.v.blob else { continue }
            let score = VersionSimilarity.score(snap.temp, blobsDir.appendingPathComponent(blob))
            guard score >= 0.6 else { continue }
            let m = ForkMatch(family: c.fi, line: c.li, base: c.v.label, score: score,
                              confident: score >= 0.85 && c.recent)
            if best == nil || m.score > best!.score { best = m }
        }
        return best
    }

    /// Turns a file's own history (from an unsure fork) into a branch.
    private func mergeAsBranchLocked(path: String, into familyID: String, base: String, note: String) {
        guard let pi = work.families.firstIndex(where: { $0.id == familyID }) else { return }
        guard let (fi, li) = lineIndexLocked(path: path) else { return }
        var line = work.families[fi].lines[li]
        if fi == pi { return }
        // The file's own family goes away (its other lines stay separate).
        if li == 0 && work.families[fi].lines.count == 1 {
            work.families.remove(at: fi)
        } else {
            work.families[fi].lines.remove(at: li)
            if li == 0 { work.families[fi].lines[0].base = nil }
        }
        guard let pIndex = work.families.firstIndex(where: { $0.id == familyID }) else { return }
        line.base = base
        var fam = work.families[pIndex]
        fam.lines.append(VersionLine(path: line.path, base: base, versions: []))
        let newLine = fam.lines.count - 1
        for (i, var v) in line.versions.enumerated() {
            v.label = fam.nextLabel(forLine: newLine)
            if i == 0, v.note == nil { v.note = note }
            fam.lines[newLine].versions.append(v)
        }
        work.families[pIndex] = fam
    }

    private func restoreLocked(_ version: DocVersion, lineID: String, familyID: String) throws -> String {
        guard let fi = work.families.firstIndex(where: { $0.id == familyID }),
              let li = work.families[fi].lines.firstIndex(where: { $0.id == lineID }) else { throw VersionError.notFound }
        guard let blob = version.blob, FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(blob).path) else {
            throw VersionError.notKept(version.label)
        }
        let path = work.families[fi].lines[li].path
        // Whatever is in the file now is saved before it's replaced.
        if Self.stat(path) != nil { _ = captureLocked(path, detectForks: false) }
        let target = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".aiflow-restore-\(UUID().uuidString).\(target.pathExtension)")
        let src = blobsDir.appendingPathComponent(blob)
        if clonefile(src.path, temp.path, 0) != 0 { try FileManager.default.copyItem(at: src, to: temp) }
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: target)
        }
        guard let st = Self.stat(path) else { throw VersionError.notFound }
        guard let (nfi, nli) = lineIndexLocked(path: path) else { throw VersionError.notFound }
        let label = work.families[nfi].nextLabel(forLine: nli)
        work.families[nfi].lines[nli].missingSince = nil
        work.families[nfi].lines[nli].versions.append(DocVersion(
            label: label, date: st.mtime, size: st.size, sha256: version.sha256, blob: blob,
            note: "Restored from \(version.label)"))
        return label
    }

    private func duplicateLocked(_ version: DocVersion, lineID: String, familyID: String) throws -> URL {
        guard let fi = work.families.firstIndex(where: { $0.id == familyID }),
              let li = work.families[fi].lines.firstIndex(where: { $0.id == lineID }) else { throw VersionError.notFound }
        guard let blob = version.blob, FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(blob).path) else {
            throw VersionError.notKept(version.label)
        }
        let original = URL(fileURLWithPath: work.families[fi].lines[li].path)
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var dst = original.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? "\(stem) (\(version.label))" : "\(stem) (\(version.label)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = original.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(stem) (\(version.label)) \(n)" : "\(stem) (\(version.label)) \(n).\(ext)")
            n += 1
        }
        let src = blobsDir.appendingPathComponent(blob)
        if clonefile(src.path, dst.path, 0) != 0 { try FileManager.default.copyItem(at: src, to: dst) }
        guard let st = Self.stat(dst.path) else { throw VersionError.notFound }
        let label = VersionFamily.childLabel(of: version.label, in: work.families[fi])
        work.families[fi].lines.append(VersionLine(path: Self.canonical(dst.path), base: version.label, versions: [
            DocVersion(label: label, date: st.mtime, size: st.size, sha256: version.sha256, blob: blob,
                       note: "Duplicated from \(version.label)")]))
        return dst
    }

    // MARK: Scanning

    /// Existing files in a root: v1 for each (baseline: no fork guessing —
    /// files that were already side by side aren't copies of each other).
    private func scanLocked(root: String, baseline: Bool) {
        guard work.enabled else { return }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var seen = 0
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if VersionRules.ignoredDirs.contains(url.lastPathComponent) || v.isPackage == true { en.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true else { continue }
            seen += 1
            if seen > 20_000 { break }
            let path = Self.canonical(url.path)
            if baseline {
                if lineIndexLocked(path: path) == nil { _ = captureLocked(path, detectForks: false) }
            } else if lineIndexLocked(path: path) == nil {
                // Appeared while aiFlow was closed: exact copies still branch.
                _ = captureLocked(path, detectForks: true)
            }
        }
        if baseline, !work.scannedRoots.contains(root) { work.scannedRoots.append(root) }
    }

    // MARK: Blobs

    struct Snapshot { var temp: URL; var sha: String }

    /// Clone first, hash the clone: the bytes can't change under us.
    private func snapshotLocked(_ path: String) -> Snapshot? {
        let tmpDir = storeDir.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let temp = tmpDir.appendingPathComponent(UUID().uuidString)
        if clonefile(path, temp.path, 0) != 0 {
            do { try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: temp) } catch { return nil }
        }
        guard let sha = Self.sha256(temp) else { try? FileManager.default.removeItem(at: temp); return nil }
        return Snapshot(temp: temp, sha: sha)
    }

    private func storeBlobLocked(_ snap: Snapshot, ext: String) -> String? {
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let name = ext.isEmpty ? snap.sha : "\(snap.sha).\(ext.lowercased())"
        let dst = blobsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dst.path) { return name }
        if clonefile(snap.temp.path, dst.path, 0) != 0 {
            do { try FileManager.default.copyItem(at: snap.temp, to: dst) } catch { return nil }
        }
        return name
    }

    private func deleteUnreferencedLocked(_ blobs: [String]) {
        let used = Set(work.families.flatMap { $0.lines.flatMap { $0.versions.compactMap(\.blob) } })
        for b in Set(blobs) where !used.contains(b) {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(b))
        }
    }

    /// Bytes of stored copies that aren't any file's current version.
    private func historyBytesLocked() -> Int64 {
        let live = Set(work.families.flatMap { $0.lines.compactMap { $0.current?.blob } })
        var sizes: [String: Int64] = [:]
        for fam in work.families {
            for line in fam.lines {
                for v in line.versions {
                    if let b = v.blob, !live.contains(b) { sizes[b] = v.size }
                }
            }
        }
        return sizes.values.reduce(0, +)
    }

    /// Over the cap: oldest stored copies go first — never a file's current
    /// version and never its last `keepPerLine` versions (metadata stays).
    private func pruneLocked() {
        var total = historyBytesLocked()
        guard total > Self.capBytes else { return }
        let live = Set(work.families.flatMap { $0.lines.compactMap { $0.current?.blob } })
        var candidates: [(fi: Int, li: Int, vi: Int, at: Date)] = []
        for (fi, fam) in work.families.enumerated() {
            for (li, line) in fam.lines.enumerated() {
                let protected = max(0, line.versions.count - Self.keepPerLine)
                for vi in 0..<protected where line.versions[vi].blob != nil {
                    candidates.append((fi, li, vi, line.versions[vi].capturedAt))
                }
            }
        }
        candidates.sort { $0.at < $1.at }
        for c in candidates {
            guard total > Self.capBytes else { break }
            guard let b = work.families[c.fi].lines[c.li].versions[c.vi].blob, !live.contains(b) else { continue }
            work.families[c.fi].lines[c.li].versions[c.vi].blob = nil
            let stillUsed = work.families.contains { $0.lines.contains { $0.versions.contains { $0.blob == b } } }
            if !stillUsed {
                try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(b))
                total -= work.families[c.fi].lines[c.li].versions[c.vi].size
            }
        }
    }

    // MARK: Persistence + publishing

    private func loadLocked() {
        guard let data = try? Data(contentsOf: indexFile),
              let idx = try? JSONDecoder().decode(VersionIndex.self, from: data) else { return }
        work = idx
    }

    private func commitLocked(flush: Bool = false) {
        pruneLocked()
        let snap = work
        let bytes = historyBytesLocked()
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: self.storeDir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snap) { try? data.write(to: self.indexFile, options: .atomic) }
        }
        saveItem = item
        if flush { item.perform() } else { queue.asyncAfter(deadline: .now() + 0.3, execute: item) }
        DispatchQueue.main.async { [weak self] in self?.apply(snap, bytes: bytes) }
    }

    /// Flushes the pending index write (tests, quitting).
    func saveNow() {
        queue.sync { saveItem?.perform(); saveItem = nil }
    }

    private func publish(_ snap: VersionIndex) {
        let bytes = queue.sync { historyBytesLocked() }
        apply(snap, bytes: bytes)
    }

    private func apply(_ snap: VersionIndex, bytes: Int64) {
        var labels: [String: String] = [:]
        var lines: [String: (String, String)] = [:]
        for fam in snap.families {
            for line in fam.lines where line.missingSince == nil {
                for key in Self.keys(for: line.path) {
                    if let l = line.current?.label { labels[key] = l }
                    lines[key] = (fam.id, line.id)
                }
            }
        }
        let changed = labels != labelByPath
        labelByPath = labels
        lineByPath = lines.mapValues { (family: $0.0, line: $0.1) }
        index = snap
        historyBytes = bytes
        version &+= 1
        if changed { WorkspaceStore.shared.refreshBadges() }
    }

    // MARK: File helpers

    struct FileStat { var size: Int64; var mtime: Date; var isRegular: Bool }

    static func stat(_ path: String) -> FileStat? {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return nil }
        let isReg = (st.st_mode & S_IFMT) == S_IFREG
        let t = st.st_mtimespec
        let mtime = Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
        return FileStat(size: Int64(st.st_size), mtime: mtime, isRegular: isReg)
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// When the document was last opened (LaunchServices / Spotlight).
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString),
              let v = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return v as? Date
    }
}

enum VersionError: LocalizedError {
    case notFound
    case notKept(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "The file or its history couldn't be found."
        case .notKept(let label): return "\(label) is no longer stored — older copies are removed when history passes 5 GB."
        }
    }
}

// MARK: - What gets versioned

enum VersionRules {
    static let ignoredDirs: Set<String> = [
        "node_modules", ".git", "build", "DerivedData", "Pods", ".build", "__pycache__",
        "venv", ".venv", "dist", "target", ".Trash",
    ]
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "rtfd", "pages", "key", "numbers", "photoslibrary",
        "fcpbundle", "xcodeproj", "xcworkspace", "playground", "sparsebundle", "logicx",
        "band", "imovielibrary", "plugin", "kext", "lproj",
    ]
    static let tempSuffixes = [".tmp", ".temp", ".swp", ".swx", ".crdownload", ".part", ".partial",
                               ".download", ".icloud", "~", ".lock", ".sb-"]

    /// Documents yes; editors' temp files, hidden files, build output and
    /// package internals no.
    static func isEligible(_ path: String) -> Bool {
        let comps = path.split(separator: "/")
        guard let last = comps.last.map(String.init) else { return false }
        for c in comps.dropLast() {
            if c.hasPrefix(".") || ignoredDirs.contains(String(c)) { return false }
            if packageExtensions.contains((String(c) as NSString).pathExtension.lowercased()) { return false }
        }
        if last.hasPrefix(".") || last.hasPrefix("~$") || last.hasPrefix("~") || last.hasPrefix(".~lock") { return false }
        if last == "Icon\r" || last == ".DS_Store" { return false }
        let lower = last.lowercased()
        if tempSuffixes.contains(where: { lower.hasSuffix($0) }) { return false }
        if lower.contains(".sb-") { return false }
        // Excel/Word write 8-hex-digit temp files next to the document.
        if last.count == 8, !last.contains("."), last.allSatisfy(\.isHexDigit) { return false }
        return true
    }
}

// MARK: - Similarity (is this new file a variant of that version?)

enum VersionSimilarity {
    /// 0…1. Office/ODF documents compare the words of their content parts
    /// (word/document.xml, slides, sheets, content.xml — not the styles and
    /// themes every file from the same template shares); other zips compare
    /// parts by CRC; text compares lines; anything else 4 KB blocks.
    static func score(_ a: URL, _ b: URL) -> Double {
        if let za = zipEntries(a), let zb = zipEntries(b) {
            let ca = za.filter { isContentPart($0.key) }, cb = zb.filter { isContentPart($0.key) }
            if !ca.isEmpty || !cb.isEmpty {
                if ca.count == cb.count, ca.allSatisfy({ cb[$0.key]?.crc == $0.value.crc && cb[$0.key]?.size == $0.value.size }) {
                    return 1
                }
                return jaccard(shingles(zipText(a, ca)), shingles(zipText(b, cb)))
            }
            return partsScore(za, zb)
        }
        if let ta = textLines(a), let tb = textLines(b) { return jaccard(ta, tb) }
        return jaccard(blocks(a), blocks(b))
    }

    struct ZipEntry { var crc: UInt32; var size: UInt32; var compSize: UInt32; var method: UInt16; var offset: UInt32 }

    static func isContentPart(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "word/document.xml" || n == "xl/sharedstrings.xml" || n == "content.xml"
            || (n.hasPrefix("xl/worksheets/sheet") && n.hasSuffix(".xml"))
            || (n.hasPrefix("ppt/slides/slide") && n.hasSuffix(".xml"))
    }

    /// Zip central directory → parts (docProps / metadata dropped: dates and
    /// word counts that every Save As rewrites).
    static func zipEntries(_ url: URL) -> [String: ZipEntry]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4), magic == Data([0x50, 0x4B, 0x03, 0x04]) else { return nil }
        guard let end = try? h.seekToEnd(), end > 22 else { return nil }
        let tail = min(end, 65_557)
        try? h.seek(toOffset: end - tail)
        guard let buf = try? h.read(upToCount: Int(tail)) else { return nil }
        let bytes = [UInt8](buf)
        var eocd: Int?
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        let count = u16(bytes, e + 10)
        let cdSize = Int(u32(bytes, e + 12))
        let cdOffset = UInt64(u32(bytes, e + 16))
        guard cdSize > 0, cdSize < 64 << 20, (try? h.seek(toOffset: cdOffset)) != nil,
              let cdData = try? h.read(upToCount: cdSize) else { return nil }
        let cd = [UInt8](cdData)
        var out: [String: ZipEntry] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x02014B50 else { break }
            let entry = ZipEntry(crc: u32(cd, p + 16), size: u32(cd, p + 24), compSize: u32(cd, p + 20),
                                 method: UInt16(u16(cd, p + 10)), offset: u32(cd, p + 42))
            let nameLen = u16(cd, p + 28), extra = u16(cd, p + 30), comment = u16(cd, p + 32)
            guard p + 46 + nameLen <= cd.count else { break }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            if !name.hasPrefix("docProps/"), !name.hasSuffix("/"), name != "meta.xml", !name.hasPrefix("Metadata/") {
                out[name] = entry
            }
            p += 46 + nameLen + extra + comment
        }
        return out.isEmpty ? nil : out
    }

    /// Text of the given parts: stored or DEFLATE (Apple's COMPRESSION_ZLIB
    /// is raw DEFLATE, exactly what zip uses), tags stripped.
    static func zipText(_ url: URL, _ entries: [String: ZipEntry]) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        var text = ""
        for (_, e) in entries.sorted(by: { $0.key < $1.key }) where e.size > 0 && e.size < 16 << 20 {
            guard (try? h.seek(toOffset: UInt64(e.offset))) != nil,
                  let lh = try? h.read(upToCount: 30), lh.count == 30 else { continue }
            let l = [UInt8](lh)
            guard u32(l, 0) == 0x04034B50 else { continue }
            let skip = u16(l, 26) + u16(l, 28)
            guard (try? h.seek(toOffset: UInt64(e.offset) + 30 + UInt64(skip))) != nil,
                  let comp = try? h.read(upToCount: Int(e.compSize)) else { continue }
            var raw: Data?
            if e.method == 0 {
                raw = comp
            } else if e.method == 8 {
                var out = Data(count: Int(e.size))
                let n = out.withUnsafeMutableBytes { dst in
                    comp.withUnsafeBytes { src in
                        compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(e.size),
                                                  src.bindMemory(to: UInt8.self).baseAddress!, comp.count,
                                                  nil, COMPRESSION_ZLIB)
                    }
                }
                if n > 0 { raw = out.prefix(n) }
            }
            if let raw, let xml = String(data: raw, encoding: .utf8) {
                text += xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) + "\n"
            }
        }
        return text
    }

    /// Word 3-grams: shared boilerplate words don't make two texts similar,
    /// shared sentences do.
    static func shingles(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= 3 else { return Set(words) }
        var out = Set<String>()
        for i in 0...(words.count - 3) { out.insert(words[i..<(i + 3)].joined(separator: " ")) }
        return out
    }

    /// Generic zip: share of identical parts, weighted by size.
    static func partsScore(_ a: [String: ZipEntry], _ b: [String: ZipEntry]) -> Double {
        var same = 0.0, total = 0.0
        for name in Set(a.keys).union(b.keys) {
            let w = max(Double(a[name]?.size ?? 0), Double(b[name]?.size ?? 0), 1)
            total += w
            if let x = a[name], let y = b[name], x.crc == y.crc, x.size == y.size { same += w }
        }
        return total > 0 ? same / total : 0
    }

    static func textLines(_ url: URL) -> Set<String>? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 2 << 20), !data.isEmpty,
              let s = String(data: data, encoding: .utf8) else { return nil }
        if s.contains("\u{0}") { return nil }
        let lines = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : Set(lines)
    }

    static func blocks(_ url: URL) -> Set<Int> {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        var out = Set<Int>()
        var read = 0
        while read < 32 << 20, let chunk = try? h.read(upToCount: 4096), !chunk.isEmpty {
            out.insert(chunk.hashValue)
            read += chunk.count
        }
        return out
    }

    static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func u16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    private static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
}

// MARK: - FSEvents

final class VersionWatcher {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    fileprivate let onPaths: ([String]) -> Void

    init(queue: DispatchQueue, onPaths: @escaping ([String]) -> Void) {
        self.queue = queue
        self.onPaths = onPaths
    }

    deinit { stop() }

    func watch(_ roots: [String]) {
        stop()
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<VersionWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.onPaths(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, roots as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
