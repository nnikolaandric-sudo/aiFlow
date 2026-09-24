import Foundation
import Combine

// Extract file URLs from finished NSMetadataQuery *items*.
//
// IMPORTANT: NSMetadataItemURLKey ("kMDItemURL") frequently comes back nil for
// Spotlight results (verified on this system), which silently dropped every match
// when used with compactMap. kMDItemPath is reliably populated, so prefer it and
// fall back to the URL key only if the path is somehow missing.
//
// Callers snapshot `NSMetadataItem`s on the main thread (the query isn't
// thread-safe for result access) and extract attributes here, off-main:
// each `value(forAttribute:)` is an IPC round-trip, and a wide scope returns
// thousands of items.
func metadataItemsURLs(_ items: [NSMetadataItem]) -> [URL] {
    items.compactMap { item in
        if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
            return URL(fileURLWithPath: path)
        }
        return item.value(forAttribute: NSMetadataItemURLKey) as? URL
    }
}

class SearchEngine: ObservableObject {
    @Published var query          = ""
    @Published var results:   [URL] = [] {
        didSet {
            if results != oldValue { resultsVersion &+= 1 }
        }
    }
    /// Bumped on every `results` assignment — even an identical list — so the file
    /// list re-ranks for the latest query without diffing large URL arrays.
    @Published private(set) var resultsVersion = 0
    @Published var selectedScope: SearchScope = .thisFolder
    @Published var showHidden = false
    @Published var isSearching    = false

    private var metadataQuery:      NSMetadataQuery?
    private var spotlightObservers: [NSObjectProtocol] = []
    private var spotlightTimeout:   Task<Void, Never>?
    private var searchTask:         Task<Void, Never>?
    private var debounceTask:       Task<Void, Never>?
    /// Keystroke debounce before any search starts, local or Spotlight.
    private let debounceNanoseconds: UInt64 = 180_000_000 // 0.18s

    func cancelSearch() {
        debounceTask?.cancel(); debounceTask = nil
        searchTask?.cancel()
        stopSpotlight()
        results = []
        isSearching = false
    }

    func search(in directory: URL) {
        guard !query.isEmpty else {
            debounceTask?.cancel(); debounceTask = nil
            searchTask?.cancel()
            stopSpotlight()
            results = []; isSearching = false; return
        }

        searchTask?.cancel()
        debounceTask?.cancel()
        // Don't flip the spinner on before the debounce elapses — it flickered
        // once per keystroke. It turns on when the debounced search actually
        // starts (searchFlat / searchRecursive / searchWithSpotlight below).

        switch selectedScope {
        case .thisFolder, .thisFolderRecursive:
            // Debounce rapid typing: only the last keystroke in the window runs.
            let q = query
            let recursive = (selectedScope == .thisFolderRecursive)
            let delay = debounceNanoseconds
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                let current = await MainActor.run { self.query }
                guard current == q else { return }
                await MainActor.run {
                    self.isSearching = true
                    if recursive { self.searchRecursive(in: directory) }
                    else { self.searchFlat(in: directory) }
                }
            }
        default:
            // Restarting a Spotlight query re-gathers every match, so wait for a
            // pause in typing like the local scopes do. Stop the old query now so
            // it can't publish results for text that has already changed.
            stopSpotlight()
            let q = query
            let scope = selectedScope
            let delay = debounceNanoseconds
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    guard self.query == q, self.selectedScope == scope else { return }
                    self.searchWithSpotlight(scope: scope, fallbackDir: directory)
                }
            }
        }
    }

    // MARK: - Flat local search (current folder only, fuzzy-ranked)

    private func searchFlat(in directory: URL) {
        let q       = query
        let hidden  = showHidden
        // Detached: a plain `Task` inherits MainActor from the SwiftUI caller,
        // so enumeration + scoring ran on the render thread and froze typing.
        searchTask  = Task.detached(priority: .userInitiated) { [weak self] in
            let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: opts
            )) ?? []
            if Task.isCancelled { return }
            // Fuzzy-ranked: prefix > word-boundary > consecutive > scattered.
            // Extension queries (".pdf") and multi-term ("report 2026") handled inside.
            let filtered = FuzzySearch.rankedFilter(urls: urls, query: q, limit: 5_000)
            if Task.isCancelled { return }
            // `self` je weak-captured var — prepiši u lokalni let pre skoka na
            // main (Swift 6: captured-var u concurrently-executing kodu je greška).
            guard let engine = self else { return }
            await MainActor.run { engine.results = filtered; engine.isSearching = false }
        }
    }

    // MARK: - Recursive local search (folder + all subfolders, fuzzy-ranked, no Spotlight)

    private func searchRecursive(in directory: URL) {
        let q       = query
        let hidden  = showHidden
        // Detached: the old plain `Task` inherited MainActor, so walking up to
        // 120k files + scoring each one blocked the UI for seconds.
        searchTask  = Task.detached(priority: .userInitiated) { [weak self] in
            // Extension fast path: exact match, no scoring needed.
            let isExtQuery = q.trimmingCharacters(in: .whitespaces).hasPrefix(".")
            let terms = isExtQuery ? [] : FuzzySearch.foldedTerms(q)
            let wanted = isExtQuery ? "" : q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var scored: [(url: URL, score: Int)] = []
            var extMatched: [URL] = []
            scored.reserveCapacity(1024)
            // Packages are never descended into: with "show hidden" on, the old
            // `hidden ? [] : …` dropped skipsPackageDescendants and walked
            // every .app bundle (thousands of files eating the 8k cap).
            let opts: FileManager.DirectoryEnumerationOptions =
                hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: opts
            )
            var visited = 0
            while let url = autoreleasepool(invoking: { enumerator?.nextObject() as? URL }) {
                if Task.isCancelled { break }
                visited += 1
                // Cooperative cancellation + safety cap for huge trees.
                if visited % 512 == 0 { await Task.yield() }
                if isExtQuery {
                    if FuzzySearch.matchesExtensionQuery(q, url: url) == true {
                        extMatched.append(url)
                        if extMatched.count >= 5_000 { break }
                    }
                } else if let s = FuzzySearch.scoreFolded(terms: terms, wanted: wanted, name: url.lastPathComponent) {
                    scored.append((url, s))
                    if scored.count >= 8_000 { break }
                }
                if visited >= 120_000 { break } // don't walk entire disk on mistake
            }
            if Task.isCancelled { return }
            let found: [URL]
            if isExtQuery {
                found = Array(extMatched.sorted {
                    $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending
                }.prefix(5_000))
            } else {
                scored.sort {
                    if $0.score != $1.score { return $0.score < $1.score }
                    return $0.url.lastPathComponent.localizedCompare($1.url.lastPathComponent) == .orderedAscending
                }
                found = scored.prefix(5_000).map(\.url)
            }
            guard let engine = self else { return }
            await MainActor.run { engine.results = found; engine.isSearching = false }
        }
    }

    // MARK: - Spotlight search (Desktop / Documents / Downloads / Home / Entire Mac)

    private func searchWithSpotlight(scope: SearchScope, fallbackDir: URL) {
        stopSpotlight()
        // Previous results stay on screen until this query gathers; clearing
        // them first rebuilt the whole list twice per search.
        isSearching = true

        let q = NSMetadataQuery()

        // Map scope → correct NSMetadataQuery search scope
        switch scope {
        case .entireMac:
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        default:
            let url = scope.baseURL(currentPath: fallbackDir)
            q.searchScopes = [url as NSURL]
        }

        q.predicate = buildSpotlightPredicate()
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

        // Collect results on finish AND on each incremental update
        let collect: (Notification) -> Void = { [weak self, weak q] _ in
            self?.collectSpotlightResults(from: q)
        }
        spotlightObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: collect),
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: collect),
        ]

        q.start()
        metadataQuery = q
        // Dead-man's switch for the spinner: a query that never gathers (no
        // index, denied volume…) sends zero updates and collect() never runs,
        // which used to leave isSearching=true forever. This only clears the
        // spinner — a late gather still publishes through collect() above.
        spotlightTimeout?.cancel()
        // NSMetadataQuery nije Sendable — ne hvataj `q` u @Sendable closure
        // (Swift 6 greška), već samo ObjectIdentifier za poređenje identiteta.
        let queryID = ObjectIdentifier(q)
        spotlightTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if let current = self.metadataQuery, ObjectIdentifier(current) == queryID {
                    self.isSearching = false
                }
            }
        }
    }

    private func collectSpotlightResults(from q: NSMetadataQuery?) {
        guard let q else { return }
        // Snapshot the result items on main (NSMetadataQuery isn't thread-safe
        // for result access), then extract paths off-main: a big scope returns
        // thousands of NSMetadataItems and each value(forAttribute:) is IPC.
        q.disableUpdates()
        let items = (0..<q.resultCount).compactMap { q.result(at: $0) as? NSMetadataItem }
        q.enableUpdates()
        // Cap: rendering 50k rows freezes regardless of thread; Spotlight keeps
        // gathering and DidUpdate republishes as the user types more.
        let capped = Array(items.prefix(5_000))
        // Generation token: extraction runs off-main, and a newer query may
        // start (and finish) before this one lands — a stale gather must
        // never overwrite fresher results. Obavezno i scope: promena scope-a
        // uz isti tekst bi pustila stari gather da pregazi svezije rezultate.
        let queryAtGather = query
        let scopeAtGather = selectedScope
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urls = metadataItemsURLs(capped)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.query == queryAtGather, self.selectedScope == scopeAtGather else { return }
                self.results = urls
                self.isSearching = false
            }
        }
    }

    private func stopSpotlight() {
        spotlightTimeout?.cancel(); spotlightTimeout = nil
        metadataQuery?.stop()
        spotlightObservers.forEach { NotificationCenter.default.removeObserver($0) }
        spotlightObservers = []
        metadataQuery      = nil
    }

    // MARK: - Query helpers

    /// Extension prefix: ".pdf" → match by extension; otherwise fuzzy-ranked name match.
    /// Kept for compatibility; new code prefers `FuzzySearch` directly.
    private func matches(url: URL, query: String) -> Bool {
        if let extHit = FuzzySearch.matchesExtensionQuery(query, url: url) { return extHit }
        return FuzzySearch.score(query: query, name: url.lastPathComponent) != nil
    }

    /// Build an NSPredicate that mirrors the local `matches` logic for Spotlight.
    private func buildSpotlightPredicate() -> NSPredicate {
        if query.hasPrefix(".") {
            // Isto kao lokalni matchesExtensionQuery: trim + prva rec
            // (".pdf foo" → ext "pdf", ne "pdf foo").
            let ext = String(query.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init) ?? ""
            guard !ext.isEmpty else {
                return NSPredicate(value: false)
            }
            return NSPredicate(format: "kMDItemFSExtension ==[cd] %@", ext)
        }
        return NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, query)
    }

    deinit {
        stopSpotlight()
        searchTask?.cancel()
        debounceTask?.cancel()
    }
}

// MARK: - Mac-wide tag-based Spotlight search

class TagService: NSObject, ObservableObject {
    @Published var taggedFileURLs:  [URL] = []
    @Published var isSearchingTags: Bool  = false

    private var searchQuery:     NSMetadataQuery?
    private var searchObservers: [NSObjectProtocol] = []
    /// Tag this query is gathering for — a fast filter switch must not let
    /// the older gather overwrite the newer one (same race as Spotlight).
    private var activeTag: String?

    // Search Mac-wide for all files tagged with `tag`.
    // Uses ==[cd] so "Red" matches "red", "RED", etc.
    func searchFiles(forTag tag: String) {
        stopSearch()
        activeTag = tag
        isSearchingTags = true
        let q = NSMetadataQuery()
        q.searchScopes    = [NSMetadataQueryLocalComputerScope]
        // Match the modern user tag by name AND, for the 7 standard colors, the
        // legacy color label (kMDItemFSLabel). Finder's color sidebar matches the
        // label too, so this also surfaces files tagged by Finder or older builds
        // that carry the color label but no kMDItemUserTags value.
        let tagPredicate = NSPredicate(format: "kMDItemUserTags ==[cd] %@", tag)
        if let colorNumber = FileItem.colorNameToLabel[tag.lowercased()] {
            let labelPredicate = NSPredicate(format: "kMDItemFSLabel == %d", colorNumber)
            q.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [tagPredicate, labelPredicate])
        } else {
            q.predicate = tagPredicate
        }
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

        let handle: (Notification) -> Void = { [weak self, weak q] _ in
            self?.collectTaggedFiles(from: q)
        }
        searchObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: handle),
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: handle),
        ]
        q.start()
        searchQuery = q
    }

    private func collectTaggedFiles(from q: NSMetadataQuery?) {
        guard let q else { return }
        // Same as Spotlight collect above: snapshot items on main, extract
        // paths off-main. A popular color tag matches thousands of files.
        q.disableUpdates()
        let items = (0..<q.resultCount).compactMap { q.result(at: $0) as? NSMetadataItem }
        q.enableUpdates()
        let capped = Array(items.prefix(5_000))
        let tagAtGather = activeTag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urls = metadataItemsURLs(capped)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeTag == tagAtGather else { return }
                self.taggedFileURLs  = urls
                self.isSearchingTags = false
            }
        }
    }

    func stopSearch() {
        activeTag = nil
        searchQuery?.stop()
        searchObservers.forEach { NotificationCenter.default.removeObserver($0) }
        searchObservers = []
        searchQuery     = nil
        taggedFileURLs  = []
        isSearchingTags = false
    }

    deinit { stopSearch() }
}
