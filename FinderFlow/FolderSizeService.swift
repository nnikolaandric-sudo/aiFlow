import Foundation

// MARK: - Recursive folder sizes (disk-hunter)

/// Computes recursive folder sizes off the main thread with a stamp-validated
/// cache, behind the opt-in "Calculate folder sizes" pref (default OFF).
///
/// Design notes, mirroring the existing DirectoryCache idioms:
/// - Cache key is the folder path; entries carry the folder's `stat` mtime
///   stamp, so any add/remove/rename inside invalidates — same contract as
///   `DirectoryCache.Stamp`. Revisits and Back/Forth are instant.
/// - The walk itself is synchronous and cancellable via `isCancelled`; the
///   caller (ContentView) runs folders serially on a utility queue so one
///   giant tree (node_modules, photo library) can't fan out into an I/O
///   storm, and navigation away cancels via the generation guard.
/// - Safety: package descendants are skipped (an .app counts as opaque, like
///   everywhere else in the app), symlinks are never followed (no cycles),
///   and cloud folders that aren't downloaded are skipped entirely so sizing
///   can never trigger a multi-GB download.
/// - Pure Foundation, no SwiftUI — testable like DirectoryCache.

final class FolderSizeService {
    static let shared = FolderSizeService()

    private final class SizeBox: NSObject {
        let bytes: Int64
        let stamp: DirectoryCache.Stamp?
        init(bytes: Int64, stamp: DirectoryCache.Stamp?) {
            self.bytes = bytes
            self.stamp = stamp
        }
    }

    private let cache: NSCache<NSString, SizeBox> = {
        let c = NSCache<NSString, SizeBox>()
        c.name = "FinderFlow.folderSizeCache"
        c.countLimit = 2000
        return c
    }()
    private let lock = NSLock()

    /// Cached recursive size, or nil when unknown/stale. Never touches disk
    /// beyond one stat(2) for stamp validation.
    func cachedSize(for directory: URL) -> Int64? {
        let key = directory.path as NSString
        lock.lock()
        let hit = cache.object(forKey: key)
        lock.unlock()
        guard let hit else { return nil }
        guard let listed = hit.stamp else { return hit.bytes }
        guard let now = DirectoryCache.Stamp.of(directory), now == listed else {
            lock.lock()
            cache.removeObject(forKey: key)
            lock.unlock()
            return nil
        }
        return hit.bytes
    }

    func store(_ bytes: Int64, for directory: URL) {
        let box = SizeBox(bytes: bytes, stamp: DirectoryCache.Stamp.of(directory))
        lock.lock()
        cache.setObject(box, forKey: directory.path as NSString)
        lock.unlock()
    }

    func invalidate(_ directory: URL) {
        lock.lock()
        cache.removeObject(forKey: directory.path as NSString)
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }

    /// Attaches already-cached sizes to a listing without any directory walk.
    /// Used by views that own their own listing (Columns panes, preview) so
    /// they show whatever the sizing run (or an earlier visit) computed —
    /// stamp-validated, stat-only, safe to call on the main thread.
    /// Returns the original array untouched when there is nothing to attach.
    static func attachingCachedSizes(to items: [FileItem],
                                     service: FolderSizeService = .shared) -> [FileItem] {
        guard items.contains(where: { $0.isBrowsableFolder && $0.folderSize == nil }) else {
            return items
        }
        return items.map { item in
            guard item.isBrowsableFolder, item.folderSize == nil,
                  let hit = service.cachedSize(for: item.url) else { return item }
            return item.withFolderSize(hit)
        }
    }

    /// Non-recursive children of `dir` that can hold a recursive size,
    /// consuming `budget` (nearest panes spend it first). Symlinks and
    /// packages are never sizing roots — same contract as `computeSize`.
    /// Pure readdir + metadata, no recursion — safe for the caller to invoke
    /// off the main thread in bulk.
    static func browsableSubfolders(of dir: URL, includeHidden: Bool,
                                    budget: inout Int) -> [URL] {
        guard budget > 0 else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey,
                                      .isSymbolicLinkKey, .isHiddenKey]
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for u in kids {
            if budget <= 0 { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isHidden == true, !includeHidden { continue }
            guard v.isDirectory == true, v.isPackage != true,
                  v.isSymbolicLink != true else { continue }
            out.append(u)
            budget -= 1
        }
        return out
    }

    /// Recursive sum of regular-file sizes under `directory`. Returns nil
    /// when cancelled. Call off the main thread — this is pure disk I/O.
    static func computeSize(of directory: URL,
                            includeHidden: Bool,
                            isCancelled: () -> Bool) -> Int64? {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey,
                                      .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: options, errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        var checked = 0
        for case let url as URL in enumerator {
            checked += 1
            // Cooperative cancellation — checked in batches to stay cheap.
            if checked & 255 == 0, isCancelled() { return nil }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return isCancelled() ? nil : total
    }
}
