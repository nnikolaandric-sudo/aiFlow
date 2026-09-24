import Foundation
import AppKit

// MARK: - Permanent delete confirmation (shared across all views)

func confirmPermanentDelete(names: [String], onConfirm: @escaping () -> Void) {
    let label = names.count == 1 ? "\"\(names[0])\"" : "\(names.count) items"
    let alert = NSAlert()
    alert.messageText     = "Permanently delete \(label)?"
    alert.informativeText = "This cannot be undone. \(names.count == 1 ? "The item" : "The items") will be permanently deleted and cannot be recovered."
    alert.alertStyle      = .warning
    let deleteBtn = alert.addButton(withTitle: "Delete Permanently")
    deleteBtn.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
}

// MARK: - Action feedback (drives the in-app toast)

struct ActionFeedback {
    let icon: String
    let message: String
    /// Reveal kandidat za toast "Show" dugme: rezultat operacije + folder
    /// u koji je sleteo. Nil za obične copy/cut poruke bez destinacije.
    var revealURLs: [URL]? = nil
    var revealDestination: URL? = nil
}

// MARK: - Safe AppleScript helpers
//
// Filenames on macOS may legally contain double quotes and backslashes. Building
// an AppleScript source string by interpolating a raw path lets a crafted file
// name break out of the string literal and inject arbitrary AppleScript (which
// can run shell commands) — a real code-execution risk when the user merely
// right-clicks a downloaded file. Always wrap untrusted text with this helper so
// it becomes a single, properly escaped AppleScript string literal.

/// Escapes `s` and wraps it in double quotes so it is a safe AppleScript string
/// literal — backslashes first, then quotes. Control characters (newline,
/// carriage return, NUL, other C0) would break out of the one-line "..."
/// literal, so they are stripped to spaces as defense-in-depth; callers that
/// need exact paths should pre-check with `containsAppleScriptUnsafeChars`
/// and refuse instead of running a mangled path.
func appleScriptStringLiteral(_ s: String) -> String {
    var clean = s.replacingOccurrences(of: "\0", with: " ")
    clean = String(clean.unicodeScalars.map { $0.value < 32 ? " " : String($0) }.joined())
    return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// True when `s` contains characters that must never reach an AppleScript
/// `do script` / `POSIX file` literal (C0 controls incl. newline). Callers
/// should refuse the action fail-closed instead of running a mangled path.
func containsAppleScriptUnsafeChars(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value < 32 }
}

/// Opens the native Finder "Get Info" window for each URL, with the path safely
/// escaped against AppleScript injection.
func showGetInfoInFinder(_ urls: [URL]) {
    for url in urls {
        guard !containsAppleScriptUnsafeChars(url.path) else { continue }
        let pathLiteral = appleScriptStringLiteral(url.path)
        let src = """
        tell application "Finder"
            activate
            open information window of (POSIX file \(pathLiteral) as alias)
        end tell
        """
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }
}

// MARK: - Destination naming (shared by file operations and archives)

/// True when anything is at `url` — including a broken symlink, which
/// `fileExists(atPath:)` follows and would report as free.
func itemExists(at url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
}

/// A real folder, as opposed to a file or a package such as an .app, whose
/// extension is part of its type.
func isPlainFolder(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
    return values.isDirectory == true && values.isPackage != true
}

/// Splits a name into stem and extension the way Finder numbers copies: folder
/// names have no extension ("Photos.2024"), and ".tar.gz"-style double
/// extensions stay together.
func splitItemName(_ name: String, isFolder: Bool) -> (stem: String, ext: String) {
    guard !isFolder else { return (name, "") }
    let lower = name.lowercased()
    for compound in ["tar.gz", "tar.bz2", "tar.xz"] where lower.hasSuffix("." + compound) && name.count > compound.count + 1 {
        return (String(name.dropLast(compound.count + 1)), String(name.suffix(compound.count)))
    }
    let ns = name as NSString
    return (ns.deletingPathExtension, ns.pathExtension)
}

/// `desired` when nothing is there yet, otherwise the first free "name 2",
/// "name 3", … beside it — "Report 2.pdf", "Backup 2.tar.gz", "Photos.2024 2".
func uniqueDestinationURL(for desired: URL, isFolder: Bool = false) -> URL {
    guard itemExists(at: desired) else { return desired }
    let parent = desired.deletingLastPathComponent()
    let (stem, ext) = splitItemName(desired.lastPathComponent, isFolder: isFolder)
    var n = 2
    while true {
        let candidate = parent.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
        if !itemExists(at: candidate) { return candidate }
        n += 1
    }
}

/// Why the file system can't use `name` for an item, or nil when it can.
/// Shared with BatchRenameSheet so preview flags exactly what apply skips.
func invalidNameReason(_ name: String) -> String? {
    if name.isEmpty { return "A name can't be empty." }
    if name.contains("/") { return "“\(name)” can't be used — names can't contain “/”." }
    if name == "." || name == ".." { return "“\(name)” is reserved and can't be used as a name." }
    return nil
}

// MARK: - Folder / File creation

class FolderCreationService: ObservableObject {
    @Published var lastCreatedURL:     URL?
    @Published var errorMessage:       String?
    @Published var lastActionFeedback: ActionFeedback?

    func createFolder(at path: URL, name: String = "New Folder") {
        if let reason = invalidNameReason(name) {
            DispatchQueue.main.async { self.errorMessage = reason }
            return
        }
        let target = uniqueDestinationURL(for: path.appendingPathComponent(name), isFolder: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(
                    icon: "folder.badge.plus",
                    message: "Created \"\(target.lastPathComponent)\""
                )
                self.lastCreatedURL = target
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
        }
    }

    func createFile(at path: URL, name: String = "untitled.txt") {
        if let reason = invalidNameReason(name) {
            DispatchQueue.main.async { self.errorMessage = reason }
            return
        }
        let target = uniqueDestinationURL(for: path.appendingPathComponent(name))
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            DispatchQueue.main.async {
                self.errorMessage = "Could not create file at \(target.path)"
            }
            return
        }
        DispatchQueue.main.async {
            self.lastActionFeedback = ActionFeedback(
                icon: "doc.badge.plus",
                message: "Created \"\(target.lastPathComponent)\""
            )
            self.lastCreatedURL = target
        }
    }
}

// MARK: - File operations (cut / copy / paste / rename / duplicate / undo)

class FileOperationsService: NSObject, ObservableObject {
    @Published var clipboardURLs:      [URL]           = [] {
        didSet { cutURLSet = Set(clipboardURLs.map(\.path)) }
    }
    /// O(1) membership for row rendering (`ListView` checks this per visible
    /// row; the array scan was O(rows × clipboard)).
    private(set) var cutURLSet = Set<String>()
    @Published var isCut:              Bool            = false
    @Published var lastOpURL:          URL?
    /// Batch reveal: SVI rezultati operacije + destinacija u koju su sleteli.
    /// `lastOpURL` se zadržava radi kompatibilnosti (prvi URL), ali novi
    /// reveal put sluša `lastOpURLs`/`lastOpDestination` da bi uradio
    /// jump-ako-nevidljivo + multi-select (paste N fajlova, batch rename…).
    @Published var lastOpURLs:         [URL]?
    @Published var lastOpDestination:  URL?
    @Published var errorMessage:       String?
    @Published var lastActionFeedback: ActionFeedback?

    private let undoMgr = UndoManager()
    /// Copies and permanent deletes run here — one at a time, off the main
    /// thread — so pasting or deleting a large folder never freezes the window.
    private let workQueue = DispatchQueue(label: "FinderFlow.fileOperations", qos: .userInitiated)
    /// Pasteboard change count right after Cut. Copying anything else afterwards
    /// (in any app) voids the cut, so Paste then copies instead of moving.
    private var cutChangeCount: Int?
    /// First failure while replaying an undo or redo; shown instead of the toast.
    private var replayFailure: String?

    override init() {
        // Bound the undo stack: each FileStep holds strong URL pairs, and a
        // long session of bulk pastes could otherwise grow it without limit.
        undoMgr.levelsOfUndo = 50
        super.init()
        // Synchronous seed so Paste isn't briefly disabled on launch; later
        // updates go through the async cache refresh.
        let seed = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) as? [URL]
                    ?? []).filter(\.isFileURL)
        cachedPasteboardURLs = seed
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppActivated),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // String upisi (Copy Path, Copy diagnostics) ponistavaju cut i kes —
        // osvezi da Paste ne zalepi ustajale fajlove.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleExternalPasteboardWrite),
            name: .ffExternalPasteboardWrite, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFileURLsPasteboardWrite),
            name: .ffFileURLsPasteboardWrite, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppActivated() { refreshPasteboardCache() }

    @objc private func handleExternalPasteboardWrite() {
        // Eksterni string upis (Copy Path, diagnostics) ponistava cut: ako na
        // pasteboardu vise nema file URL-ova, ocisti cut da bi Paste ne zalepio ustajale fajlove.
        if isCut {
            let hasFiles = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL])?.contains(where: \.isFileURL) ?? false
            if !hasFiles { clipboardURLs = []; isCut = false; cutChangeCount = nil }
        }
        refreshPasteboardCache()
    }

    @objc private func handleFileURLsPasteboardWrite(_ notification: Notification) {
        guard let writer = notification.object as? FileOperationsService, writer !== self else { return }
        if isCut { isCut = false; cutChangeCount = nil }
        refreshPasteboardCache()
    }

    var canUndo: Bool { undoMgr.canUndo }
    var canRedo: Bool { undoMgr.canRedo }

    // MARK: Clipboard

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        clipboardURLs = urls; isCut = false; cutChangeCount = nil
        writeToPasteboard(urls)
        // Seed synchronously: the async re-read below may not have run when
        // the user hits Paste immediately after Copy (rapid ⌘C ⌘V pasted the
        // previous clipboard contents).
        cachedPasteboardURLs = urls
        refreshPasteboardCache()
        lastActionFeedback = ActionFeedback(icon: "doc.on.doc", message: "Copied \(itemsLabel(urls))")
    }

    func cut(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        clipboardURLs = urls; isCut = true
        writeToPasteboard(urls)
        cachedPasteboardURLs = urls
        cutChangeCount = NSPasteboard.general.changeCount
        refreshPasteboardCache()
        lastActionFeedback = ActionFeedback(icon: "scissors", message: "Cut \(itemsLabel(urls))")
    }

    /// Re-read the system pasteboard and publish the snapshot.
    /// Cheap enough to call on copy/cut/paste + app activation.
    func refreshPasteboardCache() {
        // Main only: NSPasteboard isn't thread-safe — an off-main read raced
        // main-thread writes (Mail attach, copy) and crashed in
        // -[NSPasteboard _updateTypeCacheIfNeeded].
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
                        ?? self.clipboardURLs).filter(\.isFileURL)
            self.cachedPasteboardURLs = urls
        }
    }

    private func writeToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        NotificationCenter.default.post(name: .ffFileURLsPasteboardWrite, object: self)
    }

    /// Cached pasteboard snapshot — `readObjects` is XPC/IPC to pboard, so
    /// never call it from a SwiftUI `body`/`disabled()` evaluation. Refreshed
    /// on copy/cut/paste and on app activation (covers external copies).
    @Published private(set) var cachedPasteboardURLs: [URL] = []

    var pasteboardURLs: [URL] { cachedPasteboardURLs }

    // MARK: Paste

    func paste(to destination: URL, reload: @escaping () -> Void) {
        let sources = pasteboardURLs
        guard !sources.isEmpty else { return }
        let wasCut = isCut && cutChangeCount == NSPasteboard.general.changeCount
        if isCut && !wasCut { clipboardURLs = []; isCut = false; cutChangeCount = nil }

        // Pasting a folder into itself would copy it into its own copy until the
        // path length runs out.
        let destPath = destination.resolvingSymlinksInPath().path
        if let loop = sources.first(where: {
            let src = $0.resolvingSymlinksInPath().path
            return destPath == src || destPath.hasPrefix(src + "/")
        }) {
            let verb = wasCut ? "move" : "copy"
            DispatchQueue.main.async { self.errorMessage = "Can't \(verb) “\(loop.lastPathComponent)” into itself." }
            return
        }

        let pending = showPendingToast("\(wasCut ? "Moving" : "Copying") \(itemsLabel(sources))…")
        workQueue.async {
            var inverse: [FileStep] = []
            var landed: [URL] = []
            var failure: Error?
            for src in sources {
                // Cut and paste into the folder the item is already in leaves it
                // alone instead of renaming it to "name 2".
                if wasCut && src.deletingLastPathComponent().resolvingSymlinksInPath().path == destPath { continue }
                let dest = uniqueDestinationURL(for: destination.appendingPathComponent(src.lastPathComponent),
                                                isFolder: isPlainFolder(src))
                do {
                    if let back = try self.perform(wasCut ? .move(src, dest) : .copy(src, dest)) {
                        inverse.append(back)
                    }
                    landed.append(dest)
                } catch {
                    // Stop at the first failure but keep undo for what already
                    // succeeded, so a partial move never strands files.
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async {
                pending.cancel()
                if let failure { self.errorMessage = failure.localizedDescription }
                guard !landed.isEmpty else {
                    // Total failure after the toast already fired would leave
                    // the hourglass "Moving/Copying…" stuck — clear it; the
                    // error alert carries the message.
                    if failure != nil { self.lastActionFeedback = nil }
                    return
                }
                if wasCut {
                    self.clipboardURLs = []; self.isCut = false; self.cutChangeCount = nil
                    // A cut is consumed by the move (Finder behaviour): without
                    // this the stale system pasteboard keeps offering Paste
                    // for already-moved files.
                    NSPasteboard.general.clearContents()
                    self.cachedPasteboardURLs = []
                }
                self.registerUndo(wasCut ? "Move" : "Paste", inverse: inverse, reload: reload)
                self.lastActionFeedback = ActionFeedback(
                    icon: "doc.on.clipboard",
                    message: (wasCut ? "Moved " : "Pasted ") + self.itemsLabel(landed),
                    revealURLs: landed,
                    revealDestination: destination
                )
                self.publishOp(urls: landed, destination: destination)
                // Destination + (on move) source parents may show in the other
                // pane / column panes — same notify as importURLs, inace source
                // pane ostaje stale do rucnog refresha.
                var notify = Set<String>([destination.path])
                if wasCut {
                    for s in sources { notify.insert(s.deletingLastPathComponent().path) }
                    DirectoryCache.shared.invalidate(directory: destination)
                    for s in sources { DirectoryCache.shared.invalidate(directory: s.deletingLastPathComponent()) }
                } else {
                    DirectoryCache.shared.invalidate(directory: destination)
                }
                for p in notify {
                    NotificationCenter.default.post(name: .refreshDirectory, object: URL(fileURLWithPath: p))
                }
                reload()
            }
        }
    }

    // MARK: - Drop import (external Finder drops + internal drag & drop)

    /// Copy or move `sources` into `destination` (a folder). Used by drag &
    /// drop: external drops from Finder and internal drags between panes.
    /// `shouldMove` is decided by the drop delegate (Option = copy, otherwise
    /// move within a volume, copy across volumes — Finder behaviour).
    /// Self-drops and same-folder moves are silent no-ops; loops are refused.
    func importURLs(_ sources: [URL], to destination: URL, shouldMove: Bool, reload: @escaping () -> Void) {
        let filtered = sources.filter(\.isFileURL)
        guard !filtered.isEmpty else { return }
        // Drops only ever target folders, but be safe if a file slips through.
        var destDir = destination
        if let v = try? destDir.resourceValues(forKeys: [.isDirectoryKey]), v.isDirectory != true {
            destDir = destDir.deletingLastPathComponent()
        }
        let destPath = destDir.resolvingSymlinksInPath().path
        // Dropping an item onto itself: silent no-op (no error sheet for a mis-drop).
        let candidates = filtered.filter {
            $0.resolvingSymlinksInPath().path != destPath
        }
        guard !candidates.isEmpty else { return }
        // Moving/copying a folder into its own descendant would recurse forever.
        if let loop = candidates.first(where: {
            destPath.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }) {
            let verb = shouldMove ? "move" : "copy"
            DispatchQueue.main.async { self.errorMessage = "Can't \(verb) “\(loop.lastPathComponent)” into itself." }
            return
        }

        let pending = showPendingToast("\(shouldMove ? "Moving" : "Copying") \(itemsLabel(candidates))…")
        workQueue.async {
            var inverse: [FileStep] = []
            var landed: [URL] = []
            var failure: Error?
            for src in candidates {
                // Moving onto the folder the item already lives in: nothing to do.
                if shouldMove && src.deletingLastPathComponent().resolvingSymlinksInPath().path == destPath { continue }
                let dest = uniqueDestinationURL(for: destDir.appendingPathComponent(src.lastPathComponent),
                                                isFolder: isPlainFolder(src))
                do {
                    if let back = try self.perform(shouldMove ? .move(src, dest) : .copy(src, dest)) {
                        inverse.append(back)
                    }
                    landed.append(dest)
                } catch {
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async {
                pending.cancel()
                if let failure { self.errorMessage = failure.localizedDescription }
                guard !landed.isEmpty else {
                    if failure != nil { self.lastActionFeedback = nil }
                    return
                }
                // Destination + (on move) source parents may be showing in column
                // panes or the second pane — tell them to refresh. The main pane
                // refreshes via `reload()` below.
                var notify = Set<String>([destDir.path])
                if shouldMove {
                    for s in candidates { notify.insert(s.deletingLastPathComponent().path) }
                }
                for p in notify {
                    NotificationCenter.default.post(name: .refreshDirectory, object: URL(fileURLWithPath: p))
                }
                self.invalidateCache(directories: notify.map { URL(fileURLWithPath: $0) })
                self.registerUndo(shouldMove ? "Move" : "Paste", inverse: inverse, reload: reload)
                self.lastActionFeedback = ActionFeedback(
                    icon: shouldMove ? "arrow.right.doc.on.clipboard" : "doc.on.clipboard",
                    message: (shouldMove ? "Moved " : "Copied ") + self.itemsLabel(landed),
                    revealURLs: landed,
                    revealDestination: destDir
                )
                self.publishOp(urls: landed, destination: destDir)
                reload()
            }
        }
    }

    // MARK: Rename

    func rename(_ url: URL, to newName: String, reload: @escaping () -> Void) {
        guard newName != url.lastPathComponent else { return }
        if let reason = invalidNameReason(newName) {
            DispatchQueue.main.async { self.errorMessage = reason }
            return
        }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        // "readme" → "README" is the same item on a case-insensitive volume, so
        // only a different item with that name is a real clash.
        if itemExists(at: newURL) && !isSameItem(url, newURL) {
            DispatchQueue.main.async { self.errorMessage = "An item named “\(newName)” already exists here." }
            return
        }
        // FileManager IO van maina — na mrezim volumenima rename zamrzne prozor.
        metadataQueue.async { [weak self] in
            guard let self else { return }
            if itemExists(at: newURL) && !self.isSameItem(url, newURL) {
                DispatchQueue.main.async { self.errorMessage = "An item named “\(newName)” already exists here." }
                return
            }
            do {
                let back = try self.perform(.move(url, newURL))
                self.invalidateCache(directories: [url.deletingLastPathComponent()])
                DispatchQueue.main.async {
                    if let back { self.registerUndo("Rename", inverse: [back], reload: reload) }
                    self.lastActionFeedback = ActionFeedback(
                        icon: "pencil",
                        message: "Renamed to \"\(newName)\"",
                        revealURLs: [newURL],
                        revealDestination: newURL.deletingLastPathComponent()
                    )
                    self.publishOp(urls: [newURL], destination: newURL.deletingLastPathComponent())
                    reload()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.errorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: Duplicate

    func duplicate(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        let pending = showPendingToast("Duplicating \(itemsLabel(urls))…")
        workQueue.async {
            var inverse: [FileStep] = []
            var created: [URL] = []
            var failure: Error?
            for url in urls {
                let folder = isPlainFolder(url)
                let (stem, ext) = splitItemName(url.lastPathComponent, isFolder: folder)
                let name = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
                let dest = uniqueDestinationURL(for: url.deletingLastPathComponent().appendingPathComponent(name),
                                                isFolder: folder)
                do {
                    if let back = try self.perform(.copy(url, dest)) { inverse.append(back) }
                    created.append(dest)
                } catch {
                    failure = failure ?? error
                }
            }
            DispatchQueue.main.async {
                pending.cancel()
                if let failure { self.errorMessage = failure.localizedDescription }
                guard !created.isEmpty else {
                    if failure != nil { self.lastActionFeedback = nil }
                    return
                }
                self.registerUndo("Duplicate", inverse: inverse, reload: reload)
                self.lastActionFeedback = ActionFeedback(icon: "plus.square.on.square",
                                                         message: "Duplicated \(self.itemsLabel(created))",
                                                         revealURLs: created,
                                                         revealDestination: created.first?.deletingLastPathComponent())
                self.publishOp(urls: created, destination: created.first?.deletingLastPathComponent())
                self.invalidateCache(directories: self.parentDirs(of: created))
                reload()
            }
        }
    }

    // MARK: - Batch rename (one undo for the whole set)

    /// Trash and batch rename run here: usually quick metadata changes, but
    /// hundreds of items — or a volume whose Trash needs a real copy — must not
    /// freeze the window. Kept apart from `workQueue` so they never wait behind
    /// a long copy.
    private let metadataQueue = DispatchQueue(label: "FinderFlow.metadataOperations", qos: .userInitiated)

    /// Rename many files at once. `pairs` holds source URL + desired new name
    /// (bare name, same folder). Unchanged names are skipped silently;
    /// collisions and failures count as skipped. A single undo restores all.
    func batchRename(_ pairs: [(from: URL, toName: String)], reload: @escaping () -> Void) {
        metadataQueue.async {
            let fm = FileManager.default
            var done: [(from: URL, to: URL)] = []
            var skipped = 0
            for p in pairs {
                let trimmed = p.toName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != p.from.lastPathComponent else { continue }
                // Same rules as single rename (empty / "/", ".", ".."): without
                // this, "." / ".." would reach moveItem as parent/grandparent
                // paths and surface as a confusing "name taken" skip.
                guard invalidNameReason(trimmed) == nil else { skipped += 1; continue }
                let dest = p.from.deletingLastPathComponent().appendingPathComponent(trimmed)
                guard !itemExists(at: dest) || self.isSameItem(p.from, dest) else { skipped += 1; continue }
                do {
                    try fm.moveItem(at: p.from, to: dest)
                    done.append((p.from, dest))
                } catch {
                    skipped += 1
                }
            }
            guard !done.isEmpty else {
                DispatchQueue.main.async {
                    self.errorMessage = skipped > 0
                        ? "Nothing renamed — \(skipped) \(skipped == 1 ? "item" : "items") skipped (name taken or invalid)."
                        : "Nothing to rename."
                }
                return
            }
            let msg = skipped > 0
                ? "Renamed \(done.count), skipped \(skipped)"
                : "Renamed \(done.count) \(done.count == 1 ? "item" : "items")"
            DispatchQueue.main.async {
                self.registerUndo("Batch Rename", inverse: done.map { .move($0.to, $0.from) }, reload: reload)
                self.lastActionFeedback = ActionFeedback(icon: "square.and.pencil", message: msg,
                                                         revealURLs: done.map(\.to),
                                                         revealDestination: done.first?.to.deletingLastPathComponent())
                self.publishOp(urls: done.map(\.to), destination: done.first?.to.deletingLastPathComponent())
                reload()
            }
        }
    }

    // MARK: Trash

    func trash(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        let pending = showPendingToast("Moving \(itemsLabel(urls)) to Trash…")
        metadataQueue.async {
            var inverse: [FileStep] = []
            var trashed: [URL] = []
            var failure: Error?
            for url in urls {
                do {
                    if let back = try self.perform(.trash(url)) { inverse.append(back) }
                    trashed.append(url)
                } catch {
                    failure = failure ?? error
                }
            }
            DispatchQueue.main.async {
                pending.cancel()
                if let failure { self.errorMessage = failure.localizedDescription }
                guard !trashed.isEmpty else {
                    if failure != nil { self.lastActionFeedback = nil }
                    return
                }
                self.registerUndo("Move to Trash", inverse: inverse, reload: reload)
                self.lastActionFeedback = ActionFeedback(icon: "trash", message: "Trashed \(self.itemsLabel(trashed))")
                self.invalidateCache(directories: self.parentDirs(of: trashed))
                reload()
            }
        }
    }

    // MARK: - Extract archive (staged, never overwrites — see ArchiveService)

    func extract(_ url: URL, reload: @escaping () -> Void) {
        let pending = showPendingToast("Extracting \(itemsLabel([url]))…")
        ArchiveService.extract(url, onError: { [weak self] message in
            pending.cancel()
            self?.errorMessage = message
        }, onExtracted: { [weak self] created in
            pending.cancel()
            guard let self else { return }
            guard !created.isEmpty else {
                // Handed to The Unarchiver, which extracts on its own.
                self.lastActionFeedback = ActionFeedback(icon: "archivebox", message: "Opened in The Unarchiver")
                return
            }
            self.registerUndo("Extract", inverse: created.map { .trash($0) }, reload: reload)
            self.lastActionFeedback = ActionFeedback(icon: "archivebox", message: "Extracted \(self.itemsLabel(created))",
                                                     revealURLs: created,
                                                     revealDestination: created.first?.deletingLastPathComponent())
            self.publishOp(urls: created, destination: created.first?.deletingLastPathComponent())
            reload()
        })
    }

    // MARK: - Compress (zip + tar.gz)

    func compress(_ urls: [URL], reload: @escaping () -> Void) {
        compress(urls, as: .zip, reload: reload)
    }

    func compress(_ urls: [URL], as format: ArchiveService.CompressFormat, reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        let pending = showPendingToast("Compressing \(itemsLabel(urls))…")
        ArchiveService.compress(urls, as: format, onError: { [weak self] message in
            pending.cancel()
            self?.errorMessage = message
        }, onDone: { [weak self] created in
            pending.cancel()
            guard let self else { return }
            self.registerUndo("Compress", inverse: [.trash(created)], reload: reload)
            self.lastActionFeedback = ActionFeedback(
                icon: "archivebox.fill",
                message: "Compressed to \"\(created.lastPathComponent)\"",
                revealURLs: [created],
                revealDestination: created.deletingLastPathComponent()
            )
            self.publishOp(urls: [created], destination: created.deletingLastPathComponent())
            reload()
        })
    }

    // MARK: - Make Alias (symlink)

    func makeAlias(for url: URL, reload: @escaping () -> Void) {
        // Stat + symlink van maina.
        metadataQueue.async { [weak self] in
            guard let self else { return }
            let folder = isPlainFolder(url)
            let (stem, ext) = splitItemName(url.lastPathComponent, isFolder: folder)
            let name = ext.isEmpty ? "\(stem) alias" : "\(stem) alias.\(ext)"
            let dest = uniqueDestinationURL(for: url.deletingLastPathComponent().appendingPathComponent(name),
                                            isFolder: folder)
            do {
                try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url)
                self.invalidateCache(directories: [url.deletingLastPathComponent()])
                DispatchQueue.main.async {
                    self.registerUndo("Make Alias", inverse: [.trash(dest)], reload: reload)
                    self.lastActionFeedback = ActionFeedback(icon: "link",
                                                             message: "Created alias \"\(dest.lastPathComponent)\"",
                                                             revealURLs: [dest],
                                                             revealDestination: dest.deletingLastPathComponent())
                    self.publishOp(urls: [dest], destination: dest.deletingLastPathComponent())
                    reload()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.errorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: - Tags (Finder-compatible: real color tags, multiple per file, toggle)

    /// Toggle a standard Finder color tag on the given files, mirroring Finder:
    /// if EVERY file already has the color it is removed from all; otherwise it is
    /// added to all. Other tags on the file (additional colors, custom text tags)
    /// are always preserved.
    func toggleColorTag(_ colorName: String, on urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty,
              let number = FileItem.colorNameToLabel[colorName.lowercased()] else { return }
        let canonical = FileItem.labelToColorName[number] ?? colorName
        let target    = canonical.lowercased()

        DispatchQueue.global(qos: .userInitiated).async {
            let allHave = urls.allSatisfy { url in
                self.readTagNames(url).contains { $0.lowercased() == target }
            }
            for url in urls {
                var names = self.readTagNames(url)
                names.removeAll { $0.lowercased() == target }   // de-dupe / remove existing
                if !allHave { names.append(canonical) }          // add unless we're toggling off
                self.writeTags(names, to: url)
            }
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(
                    icon:    allHave ? "tag.slash" : "tag.fill",
                    message: allHave ? "Removed \(canonical) tag" : "Tagged \(canonical)"
                )
                reload()
            }
        }
    }

    /// Remove every tag (colors + custom) from the given files.
    func clearTags(on urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls { self.writeTags([], to: url) }
            DispatchQueue.main.async {
                self.lastActionFeedback = ActionFeedback(icon: "tag.slash", message: "Cleared tags")
                reload()
            }
        }
    }

    /// Current tag names. The system returns plain display names (e.g. "Red",
    /// "Work") with any color-index suffix already stripped.
    private func readTagNames(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// Write tags, encoding each of the 7 standard colors as "Name\nNumber" so
    /// macOS registers a REAL color tag (verified: a plain "Red" string is stored
    /// as a colorless custom tag, while "Red\n6" sets the red swatch / labelNumber
    /// 6). Custom (non-color) tags are written through unchanged.
    private func writeTags(_ names: [String], to url: URL) {
        let encoded: [String] = names.map { name in
            if let num = FileItem.colorNameToLabel[name.lowercased()] {
                let canonical = FileItem.labelToColorName[num] ?? name
                return "\(canonical)\n\(num)"
            }
            return name
        }
        try? (url as NSURL).setResourceValue(encoded as NSArray, forKey: .tagNamesKey)
    }

    // MARK: - Copy path to clipboard

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        // Pisanje stringa ponistava i eventualni cut (changeCount), a kesirani
        // URL-ovi bi ostali ustajali pa bi sledeci Paste zalepio STARE fajlove
        // umesto nicega — ocisti cut stanje pa osvezi kes (fallback je prazan).
        clipboardURLs = []; isCut = false; cutChangeCount = nil
        cachedPasteboardURLs = []
        refreshPasteboardCache()
        // Post with object:nil — Swift structs don't bridge through NSNotification.object
        // (id in ObjC), so the receiver can't cast them back. ContentView hardcodes the toast.
        NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
        NotificationCenter.default.post(name: .ffExternalPasteboardWrite, object: nil)
    }

    // MARK: - Share

    func showShareSheet(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            guard let win = NSApp.keyWindow, let view = win.contentView else {
                self.errorMessage = "Couldn't open the Share menu — no active window."
                return
            }
            NSSharingServicePicker(items: urls.map { $0 as NSURL })
                .show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    func shareViaAirDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls.map { $0 as NSURL })
    }

    /// One-click Mail attach: opens a new Mail compose with the files attached.
    /// Unlike the generic Share… picker (which only shows Mail if the system
    /// offers it), this directly invokes the composeEmail service.
    /// Returns false when Mail's share service isn't available.
    @discardableResult
    func shareViaMail(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // Every failure below reports visibly: this used to fail silently
        // (no window, no error, no toast) which looked like "nothing happens".
        guard let service = NSSharingService(named: .composeEmail) else {
            DispatchQueue.main.async {
                self.errorMessage = "Apple Mail isn't available — install and open Mail once to send files directly."
            }
            return false
        }
        guard service.canPerform(withItems: urls.map { $0 as NSURL }) else {
            // Fallback: generic picker so the user can still pick Mail manually.
            showShareSheet(for: urls)
            return false
        }
        service.perform(withItems: urls.map { $0 as NSURL })
        lastActionFeedback = ActionFeedback(icon: "envelope.fill", message: "Opening Mail…")
        return true
    }

    /// Copy files (not paths) so ⌘V in Mail compose attaches them.
    /// This is the correct "Copy → attach in Mail" flow: Finder-style file URLs
    /// on the pasteboard. For pasting the path as TEXT, use copyPath(_:) instead.
    func copyFilesForMailAttach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        copy(urls)
        lastActionFeedback = ActionFeedback(
            icon: "envelope.fill",
            message: "Copied — paste in Mail with ⌘V"
        )
    }

    // MARK: - Permanent delete (no undo — caller must confirm first)

    func permanentlyDelete(_ urls: [URL], reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        let pending = showPendingToast("Deleting \(itemsLabel(urls))…")
        workQueue.async {
            var deleted: [URL] = []
            var failure: Error?
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                    deleted.append(url)
                } catch {
                    failure = failure ?? error
                }
            }
            DispatchQueue.main.async {
                pending.cancel()
                if let failure { self.errorMessage = failure.localizedDescription }
                guard !deleted.isEmpty else {
                    if failure != nil { self.lastActionFeedback = nil }
                    return
                }
                self.lastActionFeedback = ActionFeedback(icon: "trash.fill",
                                                         message: "Permanently deleted \(self.itemsLabel(deleted))")
                reload()
            }
        }
    }

    // MARK: - AI Organize (apply a reviewed plan — see AIOrganizerSheet)

    /// Applies an AI organizer plan inside `folder`: creates the subfolders it
    /// needs, then renames/moves each file — all under ONE Undo that moves the
    /// files back and removes the folders it created, but only while they are
    /// still empty, so nothing put there later is ever thrown away. A name
    /// that got taken since the plan was made is numbered ("Invoice 2.pdf");
    /// nothing is overwritten. Changes flagged `isDelete` are moved to Trash
    /// (recoverable, undoable) instead of renamed/moved. `completion` runs on
    /// main. A run that changed something shows its own toast; a run that
    /// changed nothing reports only through `completion`, so the sheet still
    /// on screen can say why.
    func applyAIPlan(_ changes: [AIPlanChange], in folder: URL,
                     reload: @escaping () -> Void,
                     completion: @escaping (AIApplyResult) -> Void) {
        metadataQueue.async {
            var inverse: [FileStep] = []
            var createdDirs: [URL] = []
            var result = AIApplyResult()
            var firstRenamedInPlace: URL?
            for change in changes {
                // MARK: Duplicates → Trash (undo restores from Trash)
                if change.isDelete {
                    do {
                        if let back = try self.perform(.trash(change.source)) { inverse.append(back) }
                        result.changed += 1
                        result.deleted += 1
                    } catch {
                        result.skipped += 1
                        result.firstError = result.firstError ?? error.localizedDescription
                    }
                    continue
                }
                var destDir = folder
                if !change.folder.isEmpty {
                    // AI-generisani folder/name: odbaci path traversal (../, /, \) i
                    // rezervisana imena pre bilo kakvog FileManager poziva — u
                    // suprotnom plan moze da izadje iz ciljanog foldera.
                    let f = change.folder.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !f.isEmpty, !f.contains("/"), !f.contains("\\"),
                          f != ".", f != "..", !f.contains(".."),
                          invalidNameReason(f) == nil else {
                        result.skipped += 1
                        result.firstError = result.firstError ?? "Skipped unsafe folder name “\(change.folder)”."
                        continue
                    }
                    guard invalidNameReason(change.name) == nil else {
                        result.skipped += 1
                        result.firstError = result.firstError ?? "Skipped unsafe file name “\(change.name)”."
                        continue
                    }
                    destDir = folder.appendingPathComponent(f, isDirectory: true)
                    // Belt-and-suspenders: dest mora ostati unutar foldera.
                    guard destDir.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
                            || destDir.standardizedFileURL.path == folder.standardizedFileURL.path else {
                        result.skipped += 1
                        result.firstError = result.firstError ?? "Skipped folder outside target."
                        continue
                    }
                    if !isPlainFolder(destDir) {
                        do {
                            // Chronological steps: replay runs them backwards, so a
                            // folder is removed only after its files moved back out.
                            if let back = try self.perform(.makeDir(destDir)) { inverse.append(back) }
                            createdDirs.append(destDir)
                        } catch {
                            // A file already has that name, or no permission.
                            result.skipped += 1
                            result.firstError = result.firstError ?? error.localizedDescription
                            continue
                        }
                    }
                }
                var dest = destDir.appendingPathComponent(change.name)
                if dest.standardizedFileURL.path == change.source.standardizedFileURL.path { continue }
                // Ime se validira i kad ostaje u istom folderu (prazan folder slucaj).
                if change.folder.isEmpty, invalidNameReason(change.name) != nil {
                    result.skipped += 1
                    result.firstError = result.firstError ?? "Skipped unsafe file name “\(change.name)”."
                    continue
                }
                // "readme" → "README" is the same item on a case-insensitive volume.
                if itemExists(at: dest) && !self.isSameItem(change.source, dest) {
                    dest = uniqueDestinationURL(for: dest, isFolder: isPlainFolder(change.source))
                    result.numbered += 1
                }
                do {
                    if let back = try self.perform(.move(change.source, dest)) { inverse.append(back) }
                    result.changed += 1
                    if dest.lastPathComponent != change.source.lastPathComponent { result.renamed += 1 }
                    if change.folder.isEmpty {
                        firstRenamedInPlace = firstRenamedInPlace ?? dest
                    } else {
                        result.moved += 1
                    }
                } catch {
                    result.skipped += 1
                    result.firstError = result.firstError ?? error.localizedDescription
                }
            }
            if result.changed == 0 {
                // Nothing moved: don't leave empty folders behind.
                for dir in createdDirs.reversed() { _ = try? self.perform(.removeEmptyDir(dir)) }
                createdDirs.removeAll()
                inverse.removeAll()
            }
            result.createdFolders = createdDirs.count
            DispatchQueue.main.async {
                if result.changed > 0 {
                    let undoName = (result.deleted > 0 && result.renamed == 0 && result.moved == 0)
                        ? "AI Delete Duplicates" : "AI Organize"
                    self.registerUndo(undoName, inverse: inverse, reload: reload)
                    self.lastActionFeedback = ActionFeedback(icon: result.deleted > 0 ? "trash" : "sparkles", message: result.summary,
                                                             revealURLs: (createdDirs.first ?? firstRenamedInPlace).map { [$0] },
                                                             revealDestination: folder)
                    // Select what's new in this listing: the first created folder.
                    if let pick = createdDirs.first ?? firstRenamedInPlace { self.publishOp(urls: [pick], destination: folder) }
                    self.invalidateCache(directories: [folder] + createdDirs)
                    NotificationCenter.default.post(name: .refreshDirectory, object: folder)
                    reload()
                }
                completion(result)
            }
        }
    }

    // MARK: Undo / Redo

    func undo() {
        guard undoMgr.canUndo else { NSSound.beep(); return }
        let name = undoMgr.undoActionName
        replayFailure = nil
        // Tezak IO se desava u replay-u na workQueue — ovde samo okini i
        // prikazi optimisticni toast; greska stize preko errorMessage kad zavrsi.
        undoMgr.undo()
        objectWillChange.send()
        lastActionFeedback = ActionFeedback(icon: "arrow.uturn.backward",
                                            message: name.isEmpty ? "Undone" : "Undone: \(name)")
    }

    func redo() {
        guard undoMgr.canRedo else { NSSound.beep(); return }
        let name = undoMgr.redoActionName
        replayFailure = nil
        redoMgrWork(name: name)
    }

    /// Redo path izdvojen da undo()/redo() ostanu tanki; stvarni rad je u replay-u.
    private func redoMgrWork(name: String) {
        undoMgr.redo()
        objectWillChange.send()
        lastActionFeedback = ActionFeedback(icon: "arrow.uturn.forward",
                                            message: name.isEmpty ? "Redone" : "Redone: \(name)")
    }

    /// One reversible change on disk.
    private enum FileStep {
        case move(URL, URL)   // move from → to
        case copy(URL, URL)   // copy from → to
        case trash(URL)
        case makeDir(URL)          // create an empty folder
        case removeEmptyDir(URL)   // remove a folder only while it is still empty
    }

    /// Performs `step` and returns the step that reverts it — nil when it can't
    /// be reverted (a volume without a Trash deletes the item outright).
    private func perform(_ step: FileStep) throws -> FileStep? {
        let fm = FileManager.default
        switch step {
        case .move(let from, let to):
            try fm.moveItem(at: from, to: to)
            return .move(to, from)
        case .copy(let from, let to):
            try fm.copyItem(at: from, to: to)
            return .trash(to)   // undoing a copy keeps it recoverable in the Trash
        case .trash(let url):
            var trashed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashed)
            return (trashed as URL?).map { FileStep.move($0, url) }
        case .makeDir(let url):
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return .removeEmptyDir(url)
        case .removeEmptyDir(let url):
            // Anything put in the folder since keeps it (no error, nothing lost).
            guard isPlainFolder(url),
                  let contents = try? fm.contentsOfDirectory(atPath: url.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return nil }
            try fm.removeItem(at: url)
            return .makeDir(url)
        }
    }

    /// Puts `inverse` on the undo stack. Replaying it registers its own inverse
    /// in turn, which is what gives every file operation a working Redo.
    private func registerUndo(_ name: String, inverse: [FileStep], reload: @escaping () -> Void) {
        guard !inverse.isEmpty else { return }
        undoMgr.registerUndo(withTarget: self) { target in
            target.replay(inverse, name: name, reload: reload)
        }
        undoMgr.setActionName(name)
        objectWillChange.send()
    }

    private func replay(_ steps: [FileStep], name: String, reload: @escaping () -> Void) {
        // NSUndoManager zove replay sinhrono na mainu — FileManager IO bi
        // zamrznuo UI za velike foldere, zato rad ide na workQueue, a UI nazad
        // na main. `isRedoing` se cita odmah jer se kasnije menja.
        let redoing = undoMgr.isRedoing
        let action = redoing ? "redo" : "undo"
        let pending = showPendingToast("\(redoing ? "Redoing" : "Undoing") “\(name)”…")
        workQueue.async { [weak self] in
            guard let self else { return }
            var inverse: [FileStep] = []
            var failure: String?
            var touchedParents = Set<String>()
            // Revert the most recent change first.
            for step in steps.reversed() {
                touchedParents.formUnion(Self.parents(of: step))
                do {
                    if let back = try self.perform(step) { inverse.append(back) }
                } catch {
                    failure = failure ?? "Couldn't fully \(action) “\(name)”: \(error.localizedDescription)"
                }
            }
            let finishedInverse = inverse
            let finishedFailure = failure
            let parents = touchedParents.map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pending.cancel()
                self.invalidateCache(directories: parents)
                for p in parents {
                    NotificationCenter.default.post(name: .refreshDirectory, object: p)
                }
                self.registerUndo(name, inverse: finishedInverse, reload: reload)
                if let finishedFailure {
                    self.replayFailure = finishedFailure
                    self.errorMessage = finishedFailure
                }
                reload()
            }
        }
    }

    /// Parent folderi koje FileStep dodiruje — za cache invalidaciju + notify.
    private static func parents(of step: FileStep) -> Set<String> {
        switch step {
        case .move(let from, let to):
            return [from.deletingLastPathComponent().path, to.deletingLastPathComponent().path]
        case .copy(let from, let to):
            return [from.deletingLastPathComponent().path, to.deletingLastPathComponent().path]
        case .trash(let url):
            return [url.deletingLastPathComponent().path]
        case .makeDir(let url), .removeEmptyDir(let url):
            return [url.deletingLastPathComponent().path, url.path]
        }
    }

    // MARK: Helpers

    private func itemsLabel(_ urls: [URL]) -> String {
        urls.count == 1 ? "\"\(urls[0].lastPathComponent)\"" : "\(urls.count) items"
    }

    /// Centralni reveal publish: postavlja i legacy `lastOpURL` (prvi) i novi
    /// batch `lastOpURLs` + `lastOpDestination`. Mora se zvati na mainu.
    private func publishOp(urls: [URL], destination: URL?) {
        guard !urls.isEmpty else { return }
        self.lastOpURL = urls.first
        self.lastOpURLs = urls
        self.lastOpDestination = destination ?? urls.first?.deletingLastPathComponent()
    }

    /// Mutacija je gotova — izbaci kesirane listinge da sledeci reload ne bi
    /// servirao stale sadrzaj (narocito FAT32/exFAT sa grubim mtime).
    private func invalidateCache(directories: [URL]) {
        for d in directories { DirectoryCache.shared.invalidate(directory: d) }
    }

    private func parentDirs(of urls: [URL]) -> [URL] {
        Array(Set(urls.map { $0.deletingLastPathComponent() }))
    }

    /// Shows `message` only if the work is still running after a moment, so quick
    /// operations don't flash an extra toast.
    private func showPendingToast(_ message: String) -> DispatchWorkItem {
        let toast = DispatchWorkItem { [weak self] in
            self?.lastActionFeedback = ActionFeedback(icon: "hourglass", message: message)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: toast)
        return toast
    }

    private func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let idA = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
           let idB = try? b.resourceValues(forKeys: key).fileResourceIdentifier {
            return idA.isEqual(idB)
        }
        // Fallback for volumes without stable file IDs (ExFAT, FAT32, some
        // network shares) where the identifier above is nil: compare device +
        // inode from stat. A case-only rename ("readme" → "README") keeps both
        // on a case-insensitive volume, so it still resolves as the same item
        // instead of falsely reporting "already exists". Distinct files have
        // distinct inodes, so real collisions still return false.
        let fm = FileManager.default
        guard let attrA = try? fm.attributesOfItem(atPath: a.path),
              let attrB = try? fm.attributesOfItem(atPath: b.path),
              let inoA = attrA[.systemFileNumber] as? NSNumber,
              let inoB = attrB[.systemFileNumber] as? NSNumber,
              let devA = attrA[.systemNumber] as? NSNumber,
              let devB = attrB[.systemNumber] as? NSNumber,
              inoA == inoB, devA == devB else { return false }
        return true
    }
}

// MARK: - Quick Look bridge

import Quartz

final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private(set) var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate   = self
        panel.isVisible ? panel.reloadData() : panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        (urls.indices.contains(index) ? urls[index] : urls[0]) as NSURL
    }
}

// MARK: - QL responder chain shim

import SwiftUI

struct QLResponderSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> _QLResponderView { _QLResponderView() }
    func updateNSView(_ nsView: _QLResponderView, context: Context) {}
}

final class _QLResponderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        if !(w.nextResponder is _QLResponderView) {
            nextResponder   = w.nextResponder
            w.nextResponder = self
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate   = QuickLookController.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
