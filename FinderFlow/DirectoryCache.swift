import Foundation

// MARK: - Directory listing cache (FinderFlow+ performance improvement)
//
// Folder reloads happen on every navigation, sort change, undo/redo and after
// every file op. Without a cache, quickly going Back/Forth re-hits the disk
// every time. This TTL cache keeps the *URL list* (not FileItems, so
// sort/group prefs always apply fresh) — enough to make Back/Forth, tab
// switches and post-op reloads feel instant, short enough that external
// changes are never stale for long (background refresh always revalidates).
// A cached URL list is only reused while the folder's modification time is
// unchanged, so items added, removed or renamed elsewhere show up right away.
//
// Thread-safe via NSLock. Pure Foundation so it stays testable.

final class DirectoryCache {
    static let shared = DirectoryCache()

    /// A folder's modification time — adding, removing or renaming an entry bumps it.
    struct Stamp: Equatable {
        let sec: Int
        let nsec: Int

        /// Current stamp of `directory` (follows symlinks), or nil when unreadable.
        /// Plain stat(2): URL resource values are cached per URL instance and
        /// would keep returning the old time.
        static func of(_ directory: URL) -> Stamp? {
            var st = stat()
            guard stat(directory.path, &st) == 0 else { return nil }
            return Stamp(sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec)
        }

        var date: Date {
            Date(timeIntervalSince1970: TimeInterval(sec) + TimeInterval(nsec) / 1_000_000_000)
        }
    }

    private struct Entry {
        let urls: [URL]
        let timestamp: Date
        var lastAccess: Date
        let stamp: Stamp?
    }

    private var store: [String: Entry] = [:]
    private let lock = NSLock()
    private var refreshKeys: Set<String> = []
    var ttl: TimeInterval = 15.0
    var maxEntries: Int = 128
    /// Upper bound on cached FileItems across all entries — 128 folders × 10k
    /// items previously meant hundreds of MB with no ceiling.
    var maxTotalItems: Int = 20_000
    private var totalItemCount: Int = 0

    // FileItem snapshot cache: instant paint without any disk I/O.
    // Sort/group prefs are re-applied on read, so cached snapshots stay valid
    // across sort changes. Background refresh overwrites within ~100ms.
    private var itemStore: [String: (items: [FileItem], timestamp: Date, lastAccess: Date)] = [:]

    private func key(for directory: URL, showHidden: Bool) -> String {
        "\(directory.path)#hidden=\(showHidden ? 1 : 0)"
    }

    func cachedURLs(for directory: URL, showHidden: Bool) -> [URL]? {
        let k = key(for: directory, showHidden: showHidden)
        lock.lock()
        let found = store[k]
        lock.unlock()
        guard let e = found else { return nil }
        // Validated outside the lock — stat is disk I/O.
        guard Date().timeIntervalSince(e.timestamp) < ttl, isCurrent(e, directory: directory) else {
            lock.lock()
            if store[k]?.timestamp == e.timestamp { store.removeValue(forKey: k) }
            lock.unlock()
            return nil
        }
        // LRU touch.
        lock.lock()
        if var current = store[k], current.timestamp == e.timestamp {
            current.lastAccess = Date()
            store[k] = current
        }
        lock.unlock()
        return e.urls
    }

    /// True while the folder provably hasn't changed since it was listed. A folder
    /// modified within 2 s before the listing isn't trusted: file systems with
    /// 1-second timestamps can't tell a change in that window apart.
    private func isCurrent(_ e: Entry, directory: URL) -> Bool {
        guard let listed = e.stamp else { return true }   // stored without a stamp: TTL only
        guard let now = Stamp.of(directory), now == listed else { return false }
        return e.timestamp.timeIntervalSince(listed.date) >= 2
    }

    /// Non-expiring peek for instant paint: returns stale URLs even past TTL
    /// so the UI can show *something* immediately while fresh data loads.
    func peekURLs(for directory: URL, showHidden: Bool) -> [URL]? {
        lock.lock(); defer { lock.unlock() }
        let k = key(for: directory, showHidden: showHidden)
        guard var e = store[k] else { return nil }
        e.lastAccess = Date()
        store[k] = e
        return e.urls
    }

    /// Pass the folder's `stamp` read *before* listing it, so a change that lands
    /// mid-listing still invalidates the entry. Without a stamp only the TTL applies.
    func store(_ urls: [URL], for directory: URL, showHidden: Bool, stamp: Stamp? = nil) {
        lock.lock(); defer { lock.unlock() }
        // Bound memory: evict least-recently-used entries.
        if store.count >= maxEntries {
            let sorted = store.sorted { $0.value.lastAccess < $1.value.lastAccess }
            for (k, _) in sorted.prefix(store.count - maxEntries + 1) {
                store.removeValue(forKey: k)
            }
        }
        let now = Date()
        store[key(for: directory, showHidden: showHidden)] =
            Entry(urls: urls, timestamp: now, lastAccess: now, stamp: stamp)
    }

    func invalidate(directory: URL) {
        lock.lock(); defer { lock.unlock() }
        for k in store.keys where k.hasPrefix(directory.path + "#") || k.hasPrefix(directory.path + "/") {
            store.removeValue(forKey: k)
        }
        for k in itemStore.keys where k.hasPrefix(directory.path + "#") || k.hasPrefix(directory.path + "/") {
            if let old = itemStore.removeValue(forKey: k) { totalItemCount -= old.items.count }
        }
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
        itemStore.removeAll()
        totalItemCount = 0
        refreshKeys.removeAll()
    }

    func beginRefresh(for directory: URL, showHidden: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        let k = key(for: directory, showHidden: showHidden)
        guard !refreshKeys.contains(k) else { return nil }
        refreshKeys.insert(k)
        return k
    }

    func endRefresh(_ refreshKey: String) {
        lock.lock(); defer { lock.unlock() }
        refreshKeys.remove(refreshKey)
    }

    // MARK: - FileItem snapshots (instant paint)

    func cachedItems(for directory: URL, showHidden: Bool) -> [FileItem]? {
        lock.lock(); defer { lock.unlock() }
        let k = key(for: directory, showHidden: showHidden)
        guard var e = itemStore[k] else { return nil }
        // Snapshots serve stale-while-revalidate: return even past TTL,
        // the caller always refreshes in background.
        e.lastAccess = Date()
        itemStore[k] = e
        return e.items
    }

    func storeItems(_ items: [FileItem], for directory: URL, showHidden: Bool) {
        lock.lock(); defer { lock.unlock() }
        let k = key(for: directory, showHidden: showHidden)
        // Drop the old snapshot first so eviction below never has to skip it.
        if let old = itemStore.removeValue(forKey: k) { totalItemCount -= old.items.count }
        // A folder bigger than the whole budget gets no snapshot: painting a cut-off
        // listing would show wrong contents until the refresh lands.
        guard items.count <= maxTotalItems else { return }
        // Evict LRU until both entry-count and total-item budgets fit.
        while !itemStore.isEmpty && (itemStore.count >= maxEntries || totalItemCount + items.count > maxTotalItems) {
            guard let oldest = itemStore.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
            totalItemCount -= oldest.value.items.count
            itemStore.removeValue(forKey: oldest.key)
        }
        let now = Date()
        itemStore[k] = (items, now, now)
        totalItemCount += items.count
    }

    /// True za cloud sync lokacije: poznate putanje (CloudStorage, iCloud) ili
    /// bilo koji folder kojim upravlja File Provider (Drive, Dropbox, OneDrive
    /// na custom putanji…). Metadata lookup, ne skida sadržaj.
    private static func isCloudLocation(_ url: URL) -> Bool {
        let p = url.path
        if p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
            || p.contains("com~apple~CloudDocs") { return true }
        if let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           v.isUbiquitousItem == true { return true }
        return false
    }
    /// Warm the cache for likely-next folders in the background (subfolders of
    /// the current directory, first level only). Called after a folder paints
    /// so the *next* click is already cached. Uses the already-cached parent
    /// URL list instead of re-enumerating the parent directory.
    /// Coalesced: at most one prefetch flight per directory per TTL window,
    /// skipped on network volumes and capped by item count to bound I/O.
    /// Debounced (0.35s) + serial I/O: brzo klikanje Back/Forward pre je
    /// slagalo po jedan konkurentni prefetch po svakom folderu (N foldera × 8
    /// subfoldera uporedo na globalnom redu) koji se takmičio sa stvarnim
    /// loadovima za disk. Sada se čeka da se korisnik zaustavi — samo zadnji
    /// folder se greje — i to serijski, nikad uporedo sa samim sobom.
    private var prefetchInFlight: Set<String> = []
    private let prefetchQueue = DispatchQueue(label: "FinderFlow.prefetch", qos: .background)
    private var pendingPrefetch: DispatchWorkItem?
    func prefetchSubfolders(of directory: URL, showHidden: Bool, limit: Int = 8) {
        lock.lock()
        pendingPrefetch?.cancel()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard !work.isCancelled else { return }
            self?.runPrefetch(of: directory, showHidden: showHidden, limit: limit)
        }
        pendingPrefetch = work
        lock.unlock()
        prefetchQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func runPrefetch(of directory: URL, showHidden: Bool, limit: Int) {
        let k = key(for: directory, showHidden: showHidden)
        lock.lock()
        guard !prefetchInFlight.contains(k) else { lock.unlock(); return }
        prefetchInFlight.insert(k)
        lock.unlock()
        // Cap total work: huge folders already cost enough to list.
        guard let urls = peekURLs(for: directory, showHidden: showHidden),
              !urls.isEmpty, urls.count <= 2000 else {
            lock.lock(); prefetchInFlight.remove(k); lock.unlock()
            return
        }
        // Cloud / File Provider folderi (Drive Stream, OneDrive On-Demand, iCloud):
        // svako listanje je mrežni round-trip ka FileProvider ekstenziji — prefetch
        // bi gušio red dok korisnik lista, a dobit je nikakva jer se sadržaj ionako
        // menja na serveru. Samo preskoči; folder se učita na klik kao i pre.
        if Self.isCloudLocation(directory) {
            lock.lock(); prefetchInFlight.remove(k); lock.unlock()
            return
        }
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        // Serijski red (prefetchQueue): više prefetch letova se nikad ne
        // preklapaju — pre su svi išli uporedo na globalnom konkurentnom redu.
        // Never prefetch on network volumes — each subfolder listing is a
        // round-trip that stalls the disk queue and drains laptop battery.
        if let vals = try? directory.resourceValues(forKeys: [.volumeIsLocalKey]),
           vals.volumeIsLocal == false {
            lock.lock(); prefetchInFlight.remove(k); lock.unlock()
            return
        }
        var warmed = 0
        for u in urls {
            if warmed >= limit { break }
            guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey]),
                  v.isDirectory == true else { continue }
            if peekURLs(for: u, showHidden: showHidden) != nil { continue }
            let stamp = Stamp.of(u)
            if let sub = try? FileManager.default.contentsOfDirectory(
                at: u, includingPropertiesForKeys: FileItem.resourceKeys, options: opts
            ) {
                store(sub, for: u, showHidden: showHidden, stamp: stamp)
                warmed += 1
            }
        }
        lock.lock(); prefetchInFlight.remove(k); lock.unlock()
    }
}
