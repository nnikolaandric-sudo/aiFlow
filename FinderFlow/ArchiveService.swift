import Foundation
import AppKit

// MARK: - ArchiveService
//
// Detects, previews, extracts and creates archives with the tools that ship
// with macOS (ditto, tar, gunzip, bunzip2, compression_tool), plus 7-Zip, unar
// or The Unarchiver when installed for 7z / RAR.
//
// Every path here follows three rules:
//  - Extraction happens in a hidden staging folder next to the archive, and
//    the result is then moved out under a free name, so extracting never
//    overwrites existing files. Like Archive Utility, a single top-level item
//    keeps its own name and several get wrapped in a folder named after the
//    archive.
//  - Child processes read /dev/null and their output is drained while they
//    run, so a long listing can't fill the pipe and hang the caller.
//  - Member names are passed as "./name", so a file called "-T" is never
//    mistaken for a command-line option.

enum ArchiveFormat: String {
    case zip
    case tar
    case tarGz    // .tgz, .tar.gz
    case tarBz2   // .tbz, .tbz2, .tar.bz2
    case tarXz    // .txz, .tlz, .tar.xz
    case gz       // single-file gzip
    case bz2
    case xz
    case sevenZip // .7z
    case rar
    case dmg
    case pkg
    case unknown

    /// Formats "Extract Here" can unpack. Disk images and installer packages
    /// are opened rather than extracted, so they don't count as archives.
    var isExtractable: Bool {
        switch self {
        case .zip, .tar, .tarGz, .tarBz2, .tarXz, .gz, .bz2, .xz, .sevenZip, .rar:
            return true
        case .dmg, .pkg, .unknown:
            return false
        }
    }

    var canListContents: Bool { isExtractable }

    /// Handled by tools that ship with macOS — no 7-Zip or unar needed.
    var canExtractNatively: Bool {
        switch self {
        case .zip, .tar, .tarGz, .tarBz2, .tarXz, .gz, .bz2, .xz:
            return true
        case .sevenZip, .rar, .dmg, .pkg, .unknown:
            return false
        }
    }
}

struct ArchiveService {
    // MARK: Detection

    static func format(for url: URL) -> ArchiveFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") || name.hasSuffix(".tlz") { return .tarXz }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "tar": return .tar
        case "gz":  return .gz
        case "bz2": return .bz2
        case "xz":  return .xz
        case "7z":  return .sevenZip
        case "rar": return .rar
        case "dmg": return .dmg
        case "pkg": return .pkg
        default:    return .unknown
        }
    }

    static func isSupportedArchive(_ url: URL) -> Bool {
        format(for: url).isExtractable
    }

    /// Human label used in menus / preview ("ZIP archive", "RAR archive", …).
    static func displayName(for url: URL) -> String {
        switch format(for: url) {
        case .zip: return "ZIP archive"
        case .tar: return "TAR archive"
        case .tarGz: return "GZip TAR archive"
        case .tarBz2: return "BZip2 TAR archive"
        case .tarXz: return "XZ TAR archive"
        case .gz: return "GZip file"
        case .bz2: return "BZip2 file"
        case .xz: return "XZ file"
        case .sevenZip: return "7-Zip archive"
        case .rar: return "RAR archive"
        case .dmg: return "Disk image"
        case .pkg: return "Installer package"
        case .unknown: return "File"
        }
    }

    // MARK: Helper tools

    /// First installed executable among `names`. GUI apps don't inherit a shell
    /// PATH, so Homebrew, MacPorts and system locations are searched directly.
    /// Hardening: Homebrew dirs are user-writable — reject world-writable
    /// binaries / parent dirs to block a planted `7z`/`unar` shim.
    static func helperPath(_ names: [String]) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        for dir in dirs {
            for name in names {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path),
                   !isWorldWritable(path: path), !isWorldWritable(path: dir) { return path }
            }
        }
        return nil
    }

    private static func isWorldWritable(path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? Int else { return true }
        return (perms & 0o002) != 0
    }

    // MARK: Listing (for preview pane)

    /// Up to `limit` entry names inside the archive. Empty on any failure.
    /// Cancelling the calling task stops the listing tool.
    static func listContents(of url: URL, limit: Int = 100) async -> [String] {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: listContentsSync(of: url, limit: limit, isCancelled: { flag.isSet }))
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    static func listContentsSync(of url: URL, limit: Int = 100) -> [String] {
        listContentsSync(of: url, limit: limit, isCancelled: { false })
    }

    private static func listContentsSync(of url: URL, limit: Int, isCancelled: @escaping () -> Bool) -> [String] {
        let fmt = format(for: url)
        let path = url.path
        switch fmt {
        case .zip:
            return firstLines(of: "/usr/bin/zipinfo", ["-1", path], limit: limit, isCancelled: isCancelled) { line in
                // Finder-made zips store resource forks as __MACOSX/… and ._name entries.
                let leaf = line.split(separator: "/").last.map(String.init) ?? line
                return line.hasPrefix("__MACOSX/") || leaf.hasPrefix("._") ? nil : line
            }
        case .tar, .tarGz, .tarBz2, .tarXz:
            // bsdtar detects the compression itself.
            return firstLines(of: "/usr/bin/tar", ["-tf", path], limit: limit, isCancelled: isCancelled) { line in
                let entry = line.hasPrefix("./") ? String(line.dropFirst(2)) : line
                return entry.isEmpty ? nil : entry
            }
        case .gz, .bz2, .xz:
            // Single-file compressors hold exactly one file.
            return [decompressedName(for: url)]
        case .sevenZip, .rar:
            if let seven = helperPath(["7zz", "7z"]) {
                // -slt prints one "Path = …" line per entry, which keeps names with
                // spaces intact (the column layout of plain `l` doesn't).
                return firstLines(of: seven, ["l", "-slt", "-ba", path], limit: limit, isCancelled: isCancelled) { line in
                    guard line.hasPrefix("Path = ") else { return nil }
                    let entry = String(line.dropFirst("Path = ".count))
                    return entry == path ? nil : entry
                }
            }
            if fmt == .rar, let lsar = helperPath(["lsar"]) {
                let header = url.lastPathComponent + ": "
                return firstLines(of: lsar, [path], limit: limit, isCancelled: isCancelled) { line in
                    line.hasPrefix(header) ? nil : line
                }
            }
            return []
        case .dmg, .pkg, .unknown:
            return []
        }
    }

    /// Runs a listing tool and returns its first `limit` entries, then stops the
    /// tool — previewing a multi-gigabyte tarball shouldn't decompress all of it.
    /// `transform` maps a raw output line to an entry, or nil to skip the line.
    private static func firstLines(of exe: String, _ args: [String], limit: Int,
                                   isCancelled: @escaping () -> Bool,
                                   transform: (String) -> String?) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            NSLog("FinderFlow: list tool %@ failed to launch: %@", exe, error.localizedDescription)
            return []
        }

        let reader = pipe.fileHandleForReading
        // Watchdog: cancel moze da stigne dok availableData blokira — tada
        // prekini alat da se pipe zatvori i citanje odblokira. Bez ovoga cancel
        // nikad ne bi prekinuo blokirani read.
        let watchdog = DispatchWorkItem {
            while process.isRunning {
                if isCancelled() {
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: watchdog)
        defer { watchdog.cancel() }
        var entries: [String] = []
        var pending = Data()
        var stoppedEarly = false
        while entries.count < limit {
            if isCancelled() { stoppedEarly = true; break }
            let chunk = reader.availableData   // blocks until output arrives or EOF
            if chunk.isEmpty {
                if !pending.isEmpty, let entry = transform(String(decoding: pending, as: UTF8.self)) {
                    entries.append(entry)
                }
                break
            }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                let line = String(decoding: pending[start..<newline], as: UTF8.self)
                start = pending.index(after: newline)
                if !line.isEmpty, let entry = transform(line) { entries.append(entry) }
            }
            pending = Data(pending[start...])
        }
        if entries.count >= limit { stoppedEarly = true }
        if process.isRunning { process.terminate() }
        // Bounded wait: alat koji ignorise SIGTERM ne sme da visi zauvek na
        // global queue threadu — posle grace perioda sledi SIGKILL.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        // A tool we stopped exits by signal, which is expected; otherwise a
        // failing exit status means the archive couldn't be read.
        if !stoppedEarly && process.terminationStatus != 0 { return [] }
        return Array(entries.prefix(limit))
    }

    // MARK: Extract

    /// Extracts `url` next to itself without overwriting anything. `onExtracted`
    /// receives the new top-level items — empty when the archive was handed to
    /// The Unarchiver, which finishes on its own schedule. Callbacks run on main.
    static func extract(_ url: URL, onError: @escaping (String) -> Void,
                        onExtracted: @escaping ([URL]) -> Void) {
        let fmt = format(for: url)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let unpack = unpacker(for: url, format: fmt) else {
                DispatchQueue.main.async {
                    openInUnarchiver(url, format: fmt, onError: onError) { onExtracted([]) }
                }
                return
            }
            do {
                let created = try extractStaged(url, unpack: unpack)
                DispatchQueue.main.async { onExtracted(created) }
            } catch {
                DispatchQueue.main.async { onError(error.localizedDescription) }
            }
        }
    }

    /// Completion-only variant for callers that don't need the new items.
    static func extract(_ url: URL, onError: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        extract(url, onError: onError, onExtracted: { _ in onDone() })
    }

    /// The command that unpacks `url` into an empty staging folder, or nil when
    /// no installed tool handles the format.
    private static func unpacker(for url: URL, format fmt: ArchiveFormat) -> ((URL) throws -> Void)? {
        let src = url.path
        let single = decompressedName(for: url)
        switch fmt {
        case .zip:
            // ditto is what Archive Utility uses: it restores resource forks and
            // extended attributes instead of leaving __MACOSX folders behind.
            return { stage in try run("/usr/bin/ditto", ["-x", "-k", src, stage.path]) }
        case .tar, .tarGz, .tarBz2, .tarXz:
            // bsdtar detects the compression and refuses "../" and symlink escapes.
            return { stage in try run("/usr/bin/tar", ["-xf", src, "-C", stage.path]) }
        case .gz:
            // Not `tar -xzf`: tar reads a plain compressed file as an mtree spec
            // and creates empty files named after its lines.
            return { stage in try run("/usr/bin/gunzip", ["-c", src], stdoutTo: stage.appendingPathComponent(single)) }
        case .bz2:
            return { stage in try run("/usr/bin/bunzip2", ["-c", src], stdoutTo: stage.appendingPathComponent(single)) }
        case .xz:
            return { stage in
                try run("/usr/bin/compression_tool",
                        ["-decode", "-a", "lzma", "-i", src, "-o", stage.appendingPathComponent(single).path])
            }
        case .sevenZip, .rar:
            if fmt == .rar, let unar = helperPath(["unar"]) {
                return { stage in try run(unar, ["-q", "-D", "-o", stage.path, src]) }
            }
            if let seven = helperPath(["7zz", "7z"]) {
                return { stage in try run(seven, ["x", "-y", "-bd", "-o" + stage.path, src]) }
            }
            return nil
        case .dmg, .pkg, .unknown:
            return nil
        }
    }

    /// Unpacks into a hidden staging folder beside the archive, then moves the
    /// result out under a name that doesn't collide with anything already there.
    private static func extractStaged(_ url: URL, unpack: (URL) throws -> Void) throws -> [URL] {
        let fm = FileManager.default
        let dest = url.deletingLastPathComponent()
        let stage = dest.appendingPathComponent(
            ".\(url.lastPathComponent).extracting-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        } catch {
            throw ArchiveError.notWritable(dest)
        }
        defer { try? fm.removeItem(at: stage) }

        try unpack(stage)
        try? fm.removeItem(at: stage.appendingPathComponent("__MACOSX"))

        // Post-extract containment: alati bi trebalo da odbiju zip-slip
        // (apsolutne putanje, ../, symlink escape), ali nijedna linija to nije
        // proveravala — ako alat propusti, fajlovi slecu pored arhive van
        // undo-evidencije. Prosetaj stage i asertuj da je sve unutra.
        let stageRoot = stage.standardizedFileURL.path
        if let enumerator = fm.enumerator(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in enumerator {
                let p = item.standardizedFileURL.path
                guard p.hasPrefix(stageRoot + "/") || p == stageRoot else {
                    throw ArchiveError.toolFailed(tool: "extract", message: "Archive tries to write outside its folder — blocked.")
                }
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                   let dest = try? fm.destinationOfSymbolicLink(atPath: item.path) {
                    let resolved: String
                    if dest.hasPrefix("/") {
                        resolved = URL(fileURLWithPath: dest).standardizedFileURL.path
                    } else {
                        resolved = item.deletingLastPathComponent().appendingPathComponent(dest).standardizedFileURL.path
                    }
                    guard resolved.hasPrefix(stageRoot + "/") || resolved == stageRoot else {
                        throw ArchiveError.toolFailed(tool: "extract", message: "Archive contains an unsafe link — blocked.")
                    }
                }
            }
        }

        let items = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
        guard !items.isEmpty else { throw ArchiveError.empty(url) }
        if items.count == 1 {
            let target = uniqueDestinationURL(for: dest.appendingPathComponent(items[0].lastPathComponent),
                                              isFolder: isPlainFolder(items[0]))
            try fm.moveItem(at: items[0], to: target)
            return [target]
        }
        let folder = uniqueDestinationURL(for: dest.appendingPathComponent(archiveBaseName(for: url)), isFolder: true)
        try fm.moveItem(at: stage, to: folder)
        return [folder]
    }

    /// Used for formats no installed command-line tool can unpack.
    private static func openInUnarchiver(_ url: URL, format fmt: ArchiveFormat,
                                         onError: @escaping (String) -> Void,
                                         onOpened: @escaping () -> Void) {
        guard fmt.isExtractable else {
            onError(ArchiveError.unsupported(url).localizedDescription)
            return
        }
        let bundleIDs = ["cx.c3.theunarchiver", "com.macpaw.site.theunarchiver"]
        guard let app = bundleIDs.lazy
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first else {
            onError(fmt == .sevenZip
                ? "Can't extract 7-Zip archives yet — install The Unarchiver, or run `brew install sevenzip`."
                : "Can't extract RAR archives yet — install The Unarchiver, or run `brew install unar`.")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                if let error { onError(error.localizedDescription) } else { onOpened() }
            }
        }
    }

    // MARK: Compress

    enum CompressFormat {
        case zip
        case tarGz

        var fileExtension: String { self == .zip ? "zip" : "tar.gz" }
    }

    /// Compresses `urls` into one archive in their common folder, named the way
    /// Finder does ("Name.zip" for one item, "Archive.zip" for several).
    /// Callbacks run on main.
    static func compress(_ urls: [URL], as format: CompressFormat,
                         onError: @escaping (String) -> Void, onDone: @escaping (URL) -> Void) {
        guard let first = urls.first else { return }
        // One archive lives in one folder: a selection spanning volumes would
        // resolve commonParent to /Volumes (unwritable) and build "./A/…"
        // members against the wrong root. Refuse with a clear message instead
        // of a confusing write error.
        let volumeIDs = Set(urls.compactMap {
            (try? $0.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? AnyHashable
        })
        guard volumeIDs.count <= 1 else {
            DispatchQueue.main.async {
                onError("Can't compress items from different disks into one archive.")
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let base = commonParent(of: urls)
            let name = urls.count == 1 ? first.lastPathComponent : "Archive"
            // Write under a temporary name first: a failed run leaves nothing
            // half-written behind, and zip never appends to an existing archive.
            let partial = base.appendingPathComponent(
                ".FinderFlow-\(UUID().uuidString.prefix(8)).partial.\(format.fileExtension)")
            let members = urls.map { "./" + relativePath(of: $0, from: base) }
            do {
                switch format {
                case .zip:
                    // -y stores symlinks as links instead of following them.
                    try run("/usr/bin/zip", ["-q", "-r", "-y", partial.path] + members, cwd: base)
                case .tarGz:
                    try run("/usr/bin/tar", ["-czf", partial.path] + members, cwd: base)
                }
                let dest = uniqueDestinationURL(for: base.appendingPathComponent("\(name).\(format.fileExtension)"))
                try fm.moveItem(at: partial, to: dest)
                DispatchQueue.main.async { onDone(dest) }
            } catch {
                try? fm.removeItem(at: partial)
                DispatchQueue.main.async { onError(error.localizedDescription) }
            }
        }
    }

    /// Deepest folder containing every item. A selection can span folders when
    /// it comes from recursive search results. Paths are compared as listed —
    /// `standardizedFileURL` would turn /private/tmp into /tmp, and the new
    /// archive's URL would then no longer match the folder listing.
    private static func commonParent(of urls: [URL]) -> URL {
        var common = urls[0].deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let comps = url.deletingLastPathComponent().pathComponents
            var shared = 0
            while shared < min(common.count, comps.count) && common[shared] == comps[shared] { shared += 1 }
            common.removeLast(common.count - shared)
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common.isEmpty ? ["/"] : common),
                   isDirectory: true)
    }

    private static func relativePath(of url: URL, from base: URL) -> String {
        NSString.path(withComponents: Array(url.pathComponents.dropFirst(base.pathComponents.count)))
    }

    // MARK: Running tools

    /// Runs a tool to completion and throws with its stderr if it fails. stdin is
    /// /dev/null and output is drained while the tool runs (or stdout goes
    /// straight into `stdoutTo`), so it can never block on a full pipe.
    private static func run(_ exe: String, _ args: [String], cwd: URL? = nil, stdoutTo output: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        var outFile: FileHandle?
        if let output {
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: output) else {
                throw ArchiveError.notWritable(output.deletingLastPathComponent())
            }
            outFile = handle
            process.standardOutput = handle
        } else {
            process.standardOutput = outPipe
        }
        defer { try? outFile?.close() }
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        let drained = DispatchGroup()
        if output == nil {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            var message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.count > 2_000 { message = "…" + message.suffix(2_000) }
            throw ArchiveError.toolFailed(tool: (exe as NSString).lastPathComponent, message: message)
        }
    }

    // MARK: Naming

    /// "notes.txt.gz" → "notes.txt".
    static func decompressedName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty || stem == url.lastPathComponent ? url.lastPathComponent + " (decompressed)" : stem
    }

    /// Folder name for an archive with several top-level items: "photos.tar.gz" → "photos".
    static func archiveBaseName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? name : stem
    }

    // MARK: Errors

    enum ArchiveError: LocalizedError {
        case notWritable(URL)
        case empty(URL)
        case unsupported(URL)
        case toolFailed(tool: String, message: String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let folder):
                return "Can't write to “\(folder.lastPathComponent)”."
            case .empty(let url):
                return "“\(url.lastPathComponent)” is empty."
            case .unsupported(let url):
                return "“\(url.lastPathComponent)” isn't an archive aiFlow can extract."
            case .toolFailed(let tool, let message):
                return message.isEmpty ? "\(tool) failed." : "\(tool) failed: \(message)"
            }
        }
    }
}

/// Thread-safe flag flipped by a task cancellation handler.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

extension URL {
    var ffArchiveFormat: ArchiveFormat { ArchiveService.format(for: self) }
}
