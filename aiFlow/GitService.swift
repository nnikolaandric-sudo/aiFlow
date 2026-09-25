import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - Git integration (MVP: git CLI, arhitektura spremna za libgit2)
//
// FinderFlow postaje "Git-aware filesystem": čim uđe u Git repository,
// file browser dobija Git intelligence — status bedževe, branch, diff u
// postojećem Preview panelu, Stage/Discard/Commit/Pull/Push.
//
// Arhitektura (iz plana):
//   GitService
//    ├── RepositoryDetector (repoRoot(for:) — walk ka parentima, traži .git)
//    ├── StatusProvider     (git status --porcelain, branch, ahead/behind)
//    ├── DiffProvider       (git diff, git show)
//    ├── BranchManager      (list/create/switch)
//    ├── CommitManager      (stage/unstage/commit)
//    ├── RemoteManager      (pull/push, remote URL)
//    └── CredentialManager  (MVP: oslanja se na sistemski git credential helper)
//
// MVP koristi `git` CLI preko Process() — najbrži put do funkcionalnog
// prototype-a. Kasnija zamjena: libgit2 + Swift bindings, ali GitService API
// ostaje isti pa UI ne mora da se mijenja.

// MARK: - Model

/// Status jednog fajla — VS Code stil, ali FinderFlow jednostavnije.
enum GitState: String {
    case modified   = "M"
    case added      = "A"
    case deleted    = "D"
    case untracked  = "?"
    case conflicted = "!"
    case renamed    = "R"

    var label: String {
        switch self {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .untracked:  return "Untracked"
        case .conflicted: return "Conflict"
        case .renamed:    return "Renamed"
        }
    }

    var color: Color {
        switch self {
        case .modified:   return Color.orange
        case .added:      return Color.green
        case .deleted:    return Color.red
        case .untracked:  return Color.gray
        case .conflicted: return Color.red
        case .renamed:    return Color.blue
        }
    }

    var nsColor: NSColor {
        switch self {
        case .modified:   return .systemOrange
        case .added:      return .systemGreen
        case .deleted:    return .systemRed
        case .untracked:  return .systemGray
        case .conflicted: return .systemRed
        case .renamed:    return .systemBlue
        }
    }
}

struct GitFileStatus: Hashable {
    let url: URL
    /// Relativna putanja u odnosu na repo root (za git komande).
    let relativePath: String
    let state: GitState
    /// true = izmjena je u indexu (staged, `X` kolona u porcelain).
    let staged: Bool
    /// true = izmjena je u worktree-u (unstaged, `Y` kolona).
    let unstaged: Bool
}

struct GitCommit: Identifiable, Hashable {
    let id: String          // puni hash
    var shortHash: String { String(id.prefix(7)) }
    let author: String
    let date: String        // kratki datum (git %ad --date=short)
    let message: String
}

struct GitBranch: Identifiable, Hashable {
    let id: String          // ime brancha
    var name: String { id }
    let isCurrent: Bool
}

// MARK: - Notifications (desni klik → preview + prečica)

extension Notification.Name {
    /// Desni klik Git ▸ View changes + prečica ⌥⌘G: otvori preview na Diff tabu.
    /// object = URL fajla/foldera.
    static let ffGitShowDiff = Notification.Name("FF.gitShowDiff")
    /// Git ▸ History: otvori preview na History tabu.
    static let ffGitShowHistory = Notification.Name("FF.gitShowHistory")
    /// Git ▸ Commit… / folder repo panel: otvori preview na Repo tabu.
    static let ffGitShowRepo = Notification.Name("FF.gitShowRepo")
    /// Git status se promijenio (stage/commit/pull…) — browser da reloada.
    static let ffGitDidChange = Notification.Name("FF.gitDidChange")
}

/// Koji tab Git preview pokazuje. Zahtjev stiže preko notifikacije
/// (desni klik / prečica), FilePreviewPanel ga konzumira.
enum GitPreviewTab: String {
    case preview, diff, history, repo
}

// MARK: - GitService

private final class GitOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        let result = data
        lock.unlock()
        return result
    }
}

/// Centralni Git sloj. Singleton ObservableObject — UI (bedževi, preview,
/// status bar) ga posmatra, akcije idu preko njega.
///
/// Threading: `git` se uvijek izvršava van maina (global queue).
/// @Published polja se objavljuju na mainu.
final class GitService: ObservableObject {
    static let shared = GitService()

    // MARK: Published state (tekući repo = folder koji browser gleda)

    /// Root detektovanog repo-a za tekući folder (nil = nije git).
    @Published var repoRoot: URL?
    /// Branch tekućeg repo-a (nil dok se ne učita).
    @Published var branch: String?
    @Published var ahead: Int = 0
    @Published var behind: Int = 0
    /// Svi dirty fajlovi repo-a, ključ = apsolutna putanja.
    @Published var statuses: [String: GitFileStatus] = [:] {
        didSet { rebuildBadges() }
    }
    /// Row badges: every changed path plus its folders (strongest child
    /// state), built once per refresh — the file lists look up O(1) instead
    /// of scanning every status per folder row (34k in a big repo). Untracked
    /// is left out: a "?" next to each document in a folder that happens to
    /// be a repo (e.g. ~/Documents) says nothing useful.
    private(set) var badges: [String: GitFileStatus] = [:]
    @Published var isLoading = false
    @Published var lastError: String?
    /// Lista branch-eva (osvježava se uz status).
    @Published var branches: [GitBranch] = []
    /// Bump na svaku mutaciju — tabele/liste koje ne posmatraju statuses
    /// direktno (NativeFileTable AppKit ćelije) mogu da se relo-aduju.
    @Published var version: UInt = 0

    private var lastFolder: String = ""
    private var refreshWork: DispatchWorkItem?
    private var refreshGeneration: UInt = 0
    private let lock = NSLock()

    private init() {}

    // MARK: - Git binary

    /// CLI zavisi od Git instalacije — traži na poznatim stazama.
    /// (Razlog zašto je dugoročni plan libgit2: bez ove zavisnosti.)
    static var gitURL: URL {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }

    static var isGitAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: gitURL.path)
    }

    // MARK: - RepositoryDetector

    /// Walk ka parentima, traži `.git` (dir ili worktree gitlink fajl).
    /// Vraća root repo-a ili nil. Brzo: max ~30 nivoa, po jedan stat.
    func repoRoot(for url: URL) -> URL? {
        var dir: URL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            dir = url
        } else {
            dir = url.deletingLastPathComponent()
        }
        var depth = 0
        var cur = dir.standardizedFileURL
        let fm = FileManager.default
        while depth < 30 {
            let dotGit = cur.appendingPathComponent(".git")
            var gitIsDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &gitIsDir) {
                // Dir (.git/) ili worktree/submodule gitlink (fajl sa "gitdir: ...").
                return cur
            }
            let parent = cur.deletingLastPathComponent()
            if parent == cur { break }
            cur = parent
            depth += 1
        }
        return nil
    }

    func isGitRepo(_ url: URL) -> Bool { repoRoot(for: url) != nil }

    /// Relativna putanja fajla u odnosu na root (za `git -C root <cmd> -- <rel>`).
    func relativePath(of file: URL, to root: URL) -> String {
        let r = root.standardizedFileURL.path
        let f = file.standardizedFileURL.path
        guard f == r || f.hasPrefix(r + "/") else { return file.lastPathComponent }
        var rel = String(f.dropFirst(r.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? "." : rel
    }

    // MARK: - Refresh (StatusProvider + BranchManager read)

    /// Poziva browser na svaku navigaciju / reload. Debounced 250ms —
    /// brzo stepovanje kroz foldere ne pokreće git lavinu.
    func refresh(for folder: URL) {
        refreshWork?.cancel()
        lock.lock()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        lock.unlock()
        let target = folder
        let work = DispatchWorkItem { [weak self] in
            self?.doRefresh(for: target, generation: generation)
        }
        refreshWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Sinhroni refresh bez debounce-a (poslije stage/commit/pull/push).
    func refreshNow(for folder: URL) {
        refreshWork?.cancel()
        lock.lock()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.doRefresh(for: folder, generation: generation)
        }
    }

    private func isCurrentRefresh(_ generation: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return refreshGeneration == generation
    }

    private func doRefresh(for folder: URL, generation: UInt) {
        guard isCurrentRefresh(generation) else { return }
        guard Self.isGitAvailable else {
            publishIfCurrent(generation) { $0.repoRoot = nil; $0.lastError = "Git nije instaliran." }
            return
        }
        guard let root = repoRoot(for: folder) else {
            publishIfCurrent(generation) {
                $0.repoRoot = nil; $0.branch = nil
            $0.statuses = [:]
            $0.branches = []
            $0.ahead = 0; $0.behind = 0; $0.lastError = nil
            $0.version &+= 1
            }
            return
        }
        publishIfCurrent(generation) { $0.isLoading = true }
        let (porcelain, code) = Self.runGit(in: root, args: ["status", "--porcelain=v1", "-uall", "-b", "-z"])
        guard isCurrentRefresh(generation) else { return }
        guard code == 0 else {
            publishIfCurrent(generation) {
                $0.repoRoot = root
                $0.branch = nil
                $0.statuses = [:]
                $0.branches = []
                $0.ahead = 0
                $0.behind = 0
                $0.isLoading = false
                $0.lastError = porcelain.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return
        }
        let parsed = Self.parseStatus(porcelain, root: root)
        let branchList = Self.parseBranches(in: root)
        publishIfCurrent(generation) {
            $0.repoRoot = root
            $0.branch = parsed.branch
            $0.ahead = parsed.ahead
            $0.behind = parsed.behind
            $0.statuses = parsed.statuses
            $0.branches = branchList
            $0.isLoading = false
            $0.lastError = nil
            $0.version &+= 1
        }
        lock.lock(); lastFolder = folder.path; lock.unlock()
    }

    private func publish(_ mutate: @escaping (GitService) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }

    private func publishIfCurrent(_ generation: UInt, _ mutate: @escaping (GitService) -> Void) {
        DispatchQueue.main.async {
            guard self.isCurrentRefresh(generation) else { return }
            mutate(self)
        }
    }

    // MARK: - Status query (za bedževe u browseru)

    /// Status jednog fajla. Folderi: najjači status djece (conflict > modified…).
    func status(for url: URL) -> GitFileStatus? {
        let path = url.standardizedFileURL.path
        if let hit = statuses[path] { return hit }
        // Folder: agregiraj prvi dirty descendant (dovoljno za bedž).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var best: GitFileStatus?
        for (p, st) in statuses where p.hasPrefix(prefix) {
            if best == nil || rank(st.state) < rank(best!.state) { best = st }
        }
        return best
    }

    /// Broj dirty fajlova (za status bar / repo panel).
    var changeCount: Int { statuses.count }

    /// Badge for a list row (files and folders), never "?" — see `badges`.
    func badgeStatus(for url: URL) -> GitFileStatus? {
        badges[url.standardizedFileURL.path]
    }

    /// Git doesn't track this file or a folder above it: the preview shows
    /// the plain file, not Diff / History / Repo tabs with nothing in them.
    func isUntracked(_ url: URL) -> Bool {
        let root = repoRoot?.standardizedFileURL.path
        var p = url.standardizedFileURL.path
        while !p.isEmpty, p != "/" {
            if statuses[p]?.state == .untracked { return true }
            if p == root { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return false
    }

    private func rebuildBadges() {
        let root = repoRoot?.standardizedFileURL.path
        var out: [String: GitFileStatus] = [:]
        for (path, st) in statuses where st.state != .untracked {
            out[path] = st
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty, dir != "/" {
                if let cur = out[dir], rank(cur.state) <= rank(st.state) { break }
                out[dir] = st
                if dir == root { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        badges = out
    }

    private func rank(_ s: GitState) -> Int {
        switch s {
        case .conflicted: return 0
        case .deleted:    return 1
        case .modified:   return 2
        case .added:      return 3
        case .renamed:    return 4
        case .untracked:  return 5
        }
    }

    // MARK: - DiffProvider

    /// Diff tekst fajla (unstaged + staged vs HEAD). Za untracked vraća
    /// sadržaj fajla kao "+ new file" pseudo-diff (git diff je prazan).
    func diffText(for file: URL, completion: @escaping (String) -> Void) {
        guard let root = repoRoot(for: file) else { completion("Nije Git repository."); return }
        let rel = relativePath(of: file, to: root)
        DispatchQueue.global(qos: .userInitiated).async {
            if self.isUntracked(file, root: root) {
                let body = (try? String(contentsOf: file, encoding: .utf8)) ?? "(binarni fajl — diff nije dostupan)"
                let lines = body.components(separatedBy: .newlines).prefix(400).map { "+\($0)" }.joined(separator: "\n")
                completion("New file: \(rel)\n\n\(lines)")
                return
            }
            let (out, code) = Self.runGit(in: root, args: ["diff", "HEAD", "--no-color", "--", rel])
            if code == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion(out)
                return
            }
            // Prazan diff (npr. samo staged, ili binary): probaj staged-only.
            let (cached, _) = Self.runGit(in: root, args: ["diff", "--cached", "--no-color", "--", rel])
            if !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion(cached); return
            }
            completion(out.isEmpty ? "Nema izmjena za \(rel)." : out)
        }
    }

    private func isUntracked(_ file: URL, root: URL) -> Bool {
        let rel = relativePath(of: file, to: root)
        let (out, code) = Self.runGit(in: root, args: ["ls-files", "--others", "--exclude-standard", "--", rel])
        return code == 0 && out.split(separator: "\n").contains { $0 == Substring(rel) }
    }

    /// Diff jednog historijskog commita (`git show`).
    func showCommit(_ hash: String, in root: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (out, code) = Self.runGit(in: root, args: ["show", "--no-color", "--stat", "-p", hash])
            completion(code == 0 ? out : "Ne mogu da prikažem commit \(hash).")
        }
    }

    /// Historija fajla ili cijelog repo-a (newest first).
    func history(for fileOrRepo: URL, limit: Int = 50, completion: @escaping ([GitCommit]) -> Void) {
        guard let root = repoRoot(for: fileOrRepo) else { completion([]); return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: fileOrRepo.path, isDirectory: &isDir)
        let rel: String? = isDir.boolValue ? nil : relativePath(of: fileOrRepo, to: root)
        DispatchQueue.global(qos: .userInitiated).async {
            var args = ["log", "--pretty=format:%H%x1f%an%x1f%ad%x1f%s", "--date=short", "-n", "\(limit)"]
            if let rel { args += ["--", rel] }
            let (out, code) = Self.runGit(in: root, args: args)
            guard code == 0 else { completion([]); return }
            let commits: [GitCommit] = out.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\u{1f}")
                guard parts.count == 4 else { return nil }
                return GitCommit(id: parts[0], author: parts[1], date: parts[2], message: parts[3])
            }
            completion(commits)
        }
    }

    // MARK: - CommitManager (Stage / Unstage / Discard / Commit)

    func stage(_ urls: [URL], completion: ((Bool, String) -> Void)? = nil) {
        if let error = repositoryError(for: urls) { completion?(false, error); return }
        guard let root = commonRoot(for: urls) else { completion?(false, "Nije Git repository."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            var msg = ""
            for u in urls {
                let rel = self.relativePath(of: u, to: root)
                let (out, code) = Self.runGit(in: root, args: ["add", "--", rel])
                if code != 0 { ok = false; msg = out }
            }
            self.afterMutation(ok: ok, message: msg, root: root, completion: completion)
        }
    }

    func unstage(_ urls: [URL], completion: ((Bool, String) -> Void)? = nil) {
        if let error = repositoryError(for: urls) { completion?(false, error); return }
        guard let root = commonRoot(for: urls) else { completion?(false, "Nije Git repository."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let hasHead = Self.runGit(in: root, args: ["rev-parse", "--verify", "HEAD"]).1 == 0
            var ok = true
            var msg = ""
            for u in urls {
                let rel = self.relativePath(of: u, to: root)
                var (out, code) = hasHead
                    ? Self.runGit(in: root, args: ["restore", "--staged", "--", rel])
                    : Self.runGit(in: root, args: ["rm", "--cached", "--", rel])
                if code != 0 && hasHead {
                    (out, code) = Self.runGit(in: root, args: ["reset", "HEAD", "--", rel])
                }
                if code != 0 { ok = false; msg = out }
            }
            self.afterMutation(ok: ok, message: msg, root: root, completion: completion)
        }
    }

    /// Discard: tracked changes are restored from HEAD and untracked files are
    /// removed only when explicitly requested by the caller.
    func discard(_ urls: [URL], includeUntracked: Bool = false, completion: ((Bool, String) -> Void)? = nil) {
        if let error = repositoryError(for: urls) { completion?(false, error); return }
        guard let root = commonRoot(for: urls) else { completion?(false, "Nije Git repository."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let hasHead = Self.runGit(in: root, args: ["rev-parse", "--verify", "HEAD"]).1 == 0
            var ok = true
            var msg = ""
            for u in urls {
                let rel = self.relativePath(of: u, to: root)
                let untracked = Self.runGit(in: root, args: ["ls-files", "--others", "--exclude-standard", "--", rel]).0
                    .split(separator: "\n").contains { $0 == Substring(rel) }
                let trackedInHead = Self.runGit(in: root, args: ["ls-tree", "-r", "--name-only", "HEAD", "--", rel]).1 == 0
                if untracked || !trackedInHead {
                    if !untracked && hasHead {
                        let (resetOut, resetCode) = Self.runGit(in: root, args: ["reset", "--quiet", "HEAD", "--", rel])
                        if resetCode != 0 { ok = false; msg = resetOut }
                    } else if hasHead {
                        let (removeOut, removeCode) = Self.runGit(in: root, args: ["rm", "--cached", "--ignore-unmatch", "--", rel])
                        if removeCode != 0 { ok = false; msg = removeOut }
                    }
                    if includeUntracked {
                        let (cleanOut, cleanCode) = Self.runGit(in: root, args: ["clean", "-fd", "--", rel])
                        if cleanCode != 0 { ok = false; msg = cleanOut }
                    }
                } else {
                    var (out, code) = Self.runGit(in: root, args: ["restore", "--source=HEAD", "--staged", "--worktree", "--", rel])
                    if code != 0 {
                        (out, code) = Self.runGit(in: root, args: ["checkout", "HEAD", "--", rel])
                    }
                    if code != 0 { ok = false; msg = out }
                }
            }
            self.afterMutation(ok: ok, message: msg, root: root, completion: completion)
        }
    }

    func commit(in root: URL, message: String, completion: ((Bool, String) -> Void)? = nil) {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { completion?(false, "Commit poruka je prazna."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (out, code) = Self.runGit(in: root, args: ["commit", "-m", msg])
            self.afterMutation(ok: code == 0, message: out, root: root, completion: completion)
        }
    }

    // MARK: - RemoteManager (Pull / Push)

    func pull(in root: URL, completion: ((Bool, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (out, code) = Self.runGit(in: root, args: ["pull", "--ff-only"])
            self.afterMutation(ok: code == 0, message: out, root: root, completion: completion)
        }
    }

    func push(in root: URL, completion: ((Bool, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (out, code) = Self.runGit(in: root, args: ["push"])
            self.afterMutation(ok: code == 0, message: out, root: root, completion: completion)
        }
    }

    func remoteURL(in root: URL) -> String? {
        let (out, code) = Self.runGit(in: root, args: ["remote", "get-url", "origin"])
        guard code == 0 else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedWebRemote(_ remote: String) -> URL? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":") {
            let host = value[value.index(value.startIndex, offsetBy: 4)..<colon]
            let path = value[value.index(after: colon)...]
            return URL(string: "https://\(host)/\(path)")
        }
        if let url = URL(string: value), url.scheme == "ssh", let host = url.host {
            return URL(string: "https://\(host)\(url.path)")
        }
        return URL(string: value)
    }

    func githubLink(for url: URL, completion: @escaping (URL?) -> Void) {
        guard let root = repoRoot(for: url) else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let remote = self.remoteURL(in: root), let base = self.normalizedWebRemote(remote) else {
                completion(nil); return
            }
            let branchName = self.branch ?? "main"
            let rel = self.relativePath(of: url, to: root)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let kind = isDir.boolValue ? "tree" : "blob"
            let path = rel == "." ? "" : "/" + rel.components(separatedBy: "/").map {
                $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
            }.joined(separator: "/")
            completion(URL(string: "\(base.absoluteString)/\(kind)/\(branchName)\(path)"))
        }
    }

    func copyGithubLink(for url: URL, completion: @escaping (Bool) -> Void) {
        githubLink(for: url) { link in
            guard let link else { completion(false); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            NotificationCenter.default.post(name: .ffExternalPasteboardWrite, object: nil)
            completion(true)
        }
    }

    func openRepository(_ root: URL) {
        NSWorkspace.shared.open(root)
    }

    // MARK: - BranchManager

    func switchBranch(_ name: String, in root: URL, completion: ((Bool, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var (out, code) = Self.runGit(in: root, args: ["switch", name])
            if code != 0 { (out, code) = Self.runGit(in: root, args: ["checkout", name]) }
            self.afterMutation(ok: code == 0, message: out, root: root, completion: completion)
        }
    }

    func createBranch(_ name: String, in root: URL, completion: ((Bool, String) -> Void)? = nil) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { completion?(false, "Ime brancha je prazno."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var (out, code) = Self.runGit(in: root, args: ["switch", "-c", n])
            if code != 0 { (out, code) = Self.runGit(in: root, args: ["checkout", "-b", n]) }
            self.afterMutation(ok: code == 0, message: out, root: root, completion: completion)
        }
    }

    // MARK: - Helpers

    private func commonRoot(for urls: [URL]) -> URL? {
        guard let first = urls.first, let root = repoRoot(for: first) else { return nil }
        let rootPath = root.standardizedFileURL.path
        for url in urls {
            guard let urlRoot = repoRoot(for: url),
                  urlRoot.standardizedFileURL.path == rootPath else { return nil }
            let path = url.standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        }
        return root
    }

    func repositoryError(for urls: [URL]) -> String? {
        guard let first = urls.first, let root = repoRoot(for: first) else {
            return "Svi izabrani fajlovi moraju biti u istom Git repozitorijumu."
        }
        let rootPath = root.standardizedFileURL.path
        for url in urls {
            guard let urlRoot = repoRoot(for: url),
                  urlRoot.standardizedFileURL.path == rootPath else {
                return "Svi izabrani fajlovi moraju biti u istom Git repozitorijumu."
            }
            let path = url.standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else {
                return "Svi izabrani fajlovi moraju biti u istom Git repozitorijumu."
            }
        }
        return nil
    }

    private func mutate(_ urls: [URL], args: @escaping (String) -> [String], completion: ((Bool, String) -> Void)?) {
        if let error = repositoryError(for: urls) { completion?(false, error); return }
        guard let root = commonRoot(for: urls) else { completion?(false, "Nije Git repository."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            var msg = ""
            for u in urls {
                let rel = self.relativePath(of: u, to: root)
                let (out, code) = Self.runGit(in: root, args: args(rel))
                if code != 0 { ok = false; msg = out }
            }
            self.afterMutation(ok: ok, message: msg, root: root, completion: completion)
        }
    }

    private func afterMutation(ok: Bool, message: String, root: URL, completion: ((Bool, String) -> Void)?) {
        refreshNow(for: root)
        DispatchQueue.main.async {
            self.version &+= 1
            self.lastError = ok ? nil : message
            NotificationCenter.default.post(name: .ffGitDidChange, object: root)
            NotificationCenter.default.post(name: .refreshDirectory, object: root)
            completion?(ok, message)
        }
    }

    /// Sinhrono izvršavanje git komande. NIKAD na mainu.
    static func runGit(in repo: URL, args: [String]) -> (String, Int32) {
        let p = Process()
        p.executableURL = gitURL
        p.arguments = ["-C", repo.path] + args
        // Bez interaktivnih promptova (credential helper / editor) — GUI app
        // ne smije da visi čekajući terminalski input.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_LITERAL_PATHSPECS"] = "1"
        p.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let processDone = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in processDone.signal() }
        do {
            try p.run()
        } catch {
            return ("Git nije dostupan: \(error.localizedDescription)", 127)
        }
        let group = DispatchGroup()
        let outBox = GitOutputBox()
        let errBox = GitOutputBox()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [outPipe] in
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [errPipe] in
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if processDone.wait(timeout: .now() + 120) == .timedOut {
            p.terminate()
            p.waitUntilExit()
            return ("Git command timed out after 120 seconds.", 124)
        }
        p.waitUntilExit()
        group.wait()
        let out = String(data: outBox.value(), encoding: .utf8) ?? ""
        let err = String(data: errBox.value(), encoding: .utf8) ?? ""
        let code = p.terminationStatus
        // Greške idu na stderr — spoji da UI ima šta da pokaže.
        if code != 0, !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (err, code)
        }
        return (out, code)
    }

    // MARK: - Porcelain parsing

    struct ParsedStatus {
        var branch: String?
        var ahead = 0
        var behind = 0
        var statuses: [String: GitFileStatus] = [:]
    }

    static func parseStatus(_ porcelain: String, root: URL) -> ParsedStatus {
        var res = ParsedStatus()
        let records = porcelain.contains("\0")
            ? porcelain.components(separatedBy: "\0")
            : porcelain.components(separatedBy: "\n")
        var recordIndex = 0
        while recordIndex < records.count {
            let line = records[recordIndex]
            recordIndex += 1
            if line.hasPrefix("## ") {
                let info = String(line.dropFirst(3))
                if let dots = info.range(of: "...") {
                    res.branch = String(info[..<dots.lowerBound])
                    let rest = String(info[dots.upperBound...])
                    if let l = rest.range(of: "["), let r = rest.range(of: "]") {
                        let inside = String(rest[l.upperBound..<r.lowerBound])
                        for part in inside.components(separatedBy: ",") {
                            let t = part.trimmingCharacters(in: .whitespaces)
                            if t.hasPrefix("ahead ") { res.ahead = Int(t.dropFirst(6)) ?? 0 }
                            if t.hasPrefix("behind ") { res.behind = Int(t.dropFirst(7)) ?? 0 }
                        }
                    }
                } else if info.hasPrefix("No commits yet on ") {
                    res.branch = String(info.dropFirst("No commits yet on ".count)).components(separatedBy: " ").first
                } else if info == "HEAD (no branch)" || info.hasPrefix("HEAD") {
                    res.branch = "HEAD"
                } else {
                    res.branch = info.components(separatedBy: " ").first
                }
                continue
            }
            guard line.count >= 4 else { continue }
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            var pathPart = String(chars.dropFirst(3))
            if x == "R", porcelain.contains("\0") {
                recordIndex += 1
            } else if x == "R", let arrow = pathPart.range(of: " -> ") {
                pathPart = String(pathPart[arrow.upperBound...])
            }
            if pathPart.hasPrefix("\""), pathPart.hasSuffix("\""), pathPart.count >= 2 {
                pathPart = String(pathPart.dropFirst().dropLast())
            }
            let absURL = root.appendingPathComponent(pathPart).standardizedFileURL
            let state: GitState
            if x == "?" && y == "?" { state = .untracked }
            else if (x == "U" || y == "U") || (x == "A" && y == "A") || (x == "D" && y == "D") { state = .conflicted }
            else if x == "A" { state = .added }
            else if x == "R" { state = .renamed }
            else if x == "D" || y == "D" { state = .deleted }
            else { state = .modified }
            let staged = x != " " && x != "?" && x != "!"
            let unstaged = y != " " && y != "?"
            res.statuses[absURL.path] = GitFileStatus(
                url: absURL, relativePath: pathPart,
                state: state, staged: staged, unstaged: unstaged)
        }
        return res
    }

    static func parseBranches(in root: URL) -> [GitBranch] {
        let (out, code) = runGit(in: root, args: ["branch", "--list", "--format=%(refname:short)%00%(HEAD)"])
        guard code == 0 else { return [] }
        return out.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\0")
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            // %(HEAD) daje "*" za tekući, " " inače.
            return GitBranch(id: parts[0], isCurrent: parts[1].trimmingCharacters(in: .whitespaces) == "*")
        }
    }
}

// MARK: - Git UI requests (desni klik / prečica → preview)

/// Mali bridge: FileContextMenu (nema pristup showPreview bindingu) samo
/// pošalje notifikaciju, ContentView je konzumira (showPreview=true +
/// select), a FilePreviewPanel preko ovoga zna koji tab da otvori.
final class GitUIRequest: ObservableObject {
    static let shared = GitUIRequest()
    @Published var tab: GitPreviewTab = .preview
    @Published var url: URL?
    @Published var generation: UInt = 0

    func showDiff(for url: URL) {
        DispatchQueue.main.async {
            self.tab = .diff; self.url = url; self.generation &+= 1
            NotificationCenter.default.post(name: .ffGitShowDiff, object: url)
        }
    }

    func showHistory(for url: URL) {
        DispatchQueue.main.async {
            self.tab = .history; self.url = url; self.generation &+= 1
            NotificationCenter.default.post(name: .ffGitShowHistory, object: url)
        }
    }

    func showRepo(for url: URL) {
        DispatchQueue.main.async {
            self.tab = .repo; self.url = url; self.generation &+= 1
            NotificationCenter.default.post(name: .ffGitShowRepo, object: url)
        }
    }
}
