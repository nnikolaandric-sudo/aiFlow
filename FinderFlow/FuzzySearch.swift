import Foundation

// MARK: - Fuzzy + ranked matching (FinderFlow+ improvement)
//
// Replaces the old `localizedCaseInsensitiveContains` filter with a small,
// dependency-free scorer:
//
//  - `.pdf` prefix still matches by extension (exact, fast path)
//  - multi-term queries ("report 2026") require ALL terms (AND)
//  - single terms use subsequence fuzzy match with relevance scoring:
//    exact name > prefix > word-boundary > inside the name > scattered,
//    ignoring case and diacritics ("racun" finds "Račun.pdf", like Spotlight)
//  - the engine ranks by score, then by name for stability; the file list uses
//    `ranked`, which puts the newest file first among equally relevant hits
//
// Pure Foundation — no AppKit/SwiftUI so it can be unit-tested with `swift`.

enum FuzzySearch {
    /// Score a single term against a file name. Lower is better.
    /// Returns nil when the term is not a subsequence of the name.
    static func fuzzyScore(term: String, in name: String) -> Int? {
        let lowerTerm = fold(term)
        let lowerName = fold(name)
        let t = Array(lowerTerm)
        let n = Array(lowerName)
        guard !t.isEmpty else { return nil }
        // Fast path: an exact substring always beats a scattered match.
        if lowerName.contains(lowerTerm) {
            if lowerName.hasPrefix(lowerTerm) { return 1 }
            // Bonus when match starts at a word boundary (space, -, _, ., /, (, [).
            let boundaries: Set<Character> = [" ", "-", "_", ".", "/", "(", "[", "{", "+"]
            if n.count >= t.count {
                for i in 0...(n.count - t.count) {
                    var ok = true
                    for j in 0..<t.count where n[i + j] != t[j] { ok = false; break }
                    if ok {
                        if i > 0 && boundaries.contains(n[i - 1]) { return 5 }
                        return 10
                    }
                }
            }
            return 10
        }
        // Subsequence fuzzy pass.
        var ti = 0
        var score = 50
        var consecutive = 0
        var prevMatch = -2
        for (ni, ch) in n.enumerated() {
            if ti < t.count && ch == t[ti] {
                // Consecutive bonus, word-boundary bonus.
                if ni == prevMatch + 1 { consecutive += 1; score -= 3 }
                if ni == 0 { score -= 20 }
                else if ni > 0 {
                    let prev: Character = n[ni - 1]
                    if prev == " " || prev == "-" || prev == "_" || prev == "." || prev == "/" {
                        score -= 8
                    }
                }
                // Late matches cost a little (prefer early hits).
                score += ni / 8
                prevMatch = ni
                ti += 1
            }
        }
        guard ti == t.count else { return nil }
        score -= consecutive * 2
        // Scattered hits always rank below contiguous substring matches (1–10).
        return max(score, 11)
    }

    /// Score a full query (possibly multi-term) against a file name.
    /// Extension queries (".pdf") are handled by the caller.
    static func score(query: String, name: String) -> Int? {
        scoreFolded(terms: foldedTerms(query), wanted: fold(query), name: name)
    }

    /// Pre-folded query terms: `score(query:name:)` folds the query once per
    /// file (~8k folds per keystroke in a big folder). Ranking loops fold once
    /// and call the plural form below instead.
    static func foldedTerms(_ query: String) -> [String] {
        // Split on any whitespace (space, tab, newline…) — splitting on " "
        // alone left "report\t2026" as one unmatchable term with a tab in it.
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// Score with a pre-folded query (see `foldedTerms`). `wanted` is the
    /// folded whole query for the exact-name fast path.
    static func scoreFolded(terms: [String], wanted: String, name: String) -> Int? {
        guard !terms.isEmpty else { return nil }
        // The whole name, with or without its extension, is the closest match.
        let foldedName = fold(name)
        if foldedName == wanted || (foldedName as NSString).deletingPathExtension == wanted {
            return 0
        }
        var total = 0
        for term in terms {
            guard let s = fuzzyScoreFolded(term: term, in: name, foldedName: foldedName) else { return nil }
            total += s
        }
        // Prefer shorter names when scores tie (less noise).
        total += name.count / 64
        return total
    }

    /// `fuzzyScore` with both sides pre-folded (query terms come from
    /// `foldedTerms`, the name is folded once per file, not once per term).
    static func fuzzyScoreFolded(term: String, in name: String, foldedName: String? = nil) -> Int? {
        let lowerTerm = term
        let lowerName = foldedName ?? fold(name)
        return fuzzyScoreFoldedImpl(lowerTerm: lowerTerm, lowerName: lowerName)
    }

    private static func fuzzyScoreFoldedImpl(lowerTerm: String, lowerName: String) -> Int? {
        let t = Array(lowerTerm)
        let n = Array(lowerName)
        guard !t.isEmpty else { return nil }
        // Fast path: an exact substring always beats a scattered match.
        if lowerName.contains(lowerTerm) {
            if lowerName.hasPrefix(lowerTerm) { return 1 }
            // Bonus when match starts at a word boundary (space, -, _, ., /, (, [).
            let boundaries: Set<Character> = [" ", "-", "_", ".", "/", "(", "[", "{", "+"]
            if n.count >= t.count {
                for i in 0...(n.count - t.count) {
                    var ok = true
                    for j in 0..<t.count where n[i + j] != t[j] { ok = false; break }
                    if ok {
                        if i > 0 && boundaries.contains(n[i - 1]) { return 5 }
                        return 10
                    }
                }
            }
            return 10
        }
        // Subsequence fuzzy pass.
        var ti = 0
        var score = 50
        var consecutive = 0
        var prevMatch = -2
        for (ni, ch) in n.enumerated() {
            if ti < t.count && ch == t[ti] {
                // Consecutive bonus, word-boundary bonus.
                if ni == prevMatch + 1 { consecutive += 1; score -= 3 }
                if ni == 0 { score -= 20 }
                else if ni > 0 {
                    let prev: Character = n[ni - 1]
                    if prev == " " || prev == "-" || prev == "_" || prev == "." || prev == "/" {
                        score -= 8
                    }
                }
                // Late matches cost a little (prefer early hits).
                score += ni / 8
                prevMatch = ni
                ti += 1
            }
        }
        guard ti == t.count else { return nil }
        score -= consecutive * 2
        // Scattered hits always rank below contiguous substring matches (1–10).
        return max(score, 11)
    }

    /// Extension-prefix match: ".pdf" → pathExtension == "pdf".
    static func matchesExtensionQuery(_ query: String, url: URL) -> Bool? {
        guard query.hasPrefix(".") else { return nil }
        let ext = String(query.dropFirst()).lowercased()
            .split(separator: " ").first.map(String.init) ?? ""
        guard !ext.isEmpty else { return false }
        return url.pathExtension.lowercased() == ext
    }

    /// Ranked filter for flat URL lists. Returns URLs sorted by relevance.
    static func rankedFilter(urls: [URL], query: String, limit: Int = 5_000) -> [URL] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        // Extension fast path keeps old behaviour (exact, alphabetical).
        if q.hasPrefix(".") {
            let filtered = urls.filter { matchesExtensionQuery(q, url: $0) == true }
            return Array(filtered.sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }.prefix(limit))
        }
        // Single character: subsequence-fuzzy would match nearly everything
        // (thousands of rows) and freeze the render. Substring-only for 1 char,
        // capped to 1k rows — enough to see, cheap to render.
        if q.count == 1 {
            let folded = fold(q)
            let hits = urls.filter { fold($0.lastPathComponent).contains(folded) }
            return Array(hits.sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }.prefix(min(limit, 1_000)))
        }
        let terms = foldedTerms(q)
        let wanted = fold(q)
        var scored: [(url: URL, score: Int)] = []
        scored.reserveCapacity(min(urls.count, 2048))
        // Bez ranog break-a na scored.count: prekid enumeracije pre skoringa
        // svih sakrio bi bolji mec kasnije u folderu (relevance bug, ne samo
        // cap). Skoruju se svi (uz visited cap za absurdne liste), pa tek onda
        // sort + prefix(limit).
        var visited = 0
        for url in urls {
            visited += 1
            if visited > 120_000 { break }
            if let s = scoreFolded(terms: terms, wanted: wanted, name: url.lastPathComponent) {
                scored.append((url, s))
            }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.url.lastPathComponent.localizedCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return scored.prefix(limit).map(\.url)
    }

    /// Display order for search hits: best score first; equally relevant hits put
    /// the most recently modified first, then sort by name. Extension queries
    /// (".pdf") are an exact extension filter (newest first among matches).
    ///
    /// Local callers (`displayFiles`) rely on the fuzzy **filter** here — items
    /// the scorer can't match are dropped, not just ranked last. (Spotlight
    /// pre-filtered lists pass their own hits through unchanged.)
    ///
    /// Single-character queries are prefix-only and capped: subsequence-fuzzy
    /// on 1 char matches most of the folder (5k+ rows), which froze the render
    /// when deleting back to the last letter. `limit` caps the returned rows
    /// (1-char queries additionally cap to 1k — enough to see, cheap to draw).
    static func ranked<T>(_ items: [T], query: String,
                          name: (T) -> String, date: (T) -> Date,
                          fileExtension: (T) -> String = { _ in "" },
                          limit: Int = 5_000) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [(item: T, score: Int, date: Date)] = []
        entries.reserveCapacity(min(items.count, 2048))
        if q.hasPrefix(".") {
            // Exact extension filter — the old `localizedCaseInsensitiveContains`
            // pre-filter only *looked* like matching everything: names containing
            // ".pdf" as a substring passed. The documented behavior (search field
            // placeholder, rankedFilter fast path) is extension-exact.
            let wanted = String(q.dropFirst()).lowercased()
                .split(separator: " ").first.map(String.init) ?? ""
            guard !wanted.isEmpty else { return [] }
            for item in items where fileExtension(item).lowercased() == wanted {
                entries.append((item, 0, date(item)))
            }
        } else if q.count == 1 {
            // Substring, not subsequence-fuzzy: 1 char is a subsequence of
            // nearly every name, which produced 5k+ rows and froze the render.
            let folded = fold(q)
            for item in items where fold(name(item)).contains(folded) {
                entries.append((item, 1, date(item)))
            }
        } else {
            let terms = foldedTerms(q)
            let wanted = fold(q)
            var visited = 0
            for item in items {
                visited += 1
                if visited > 120_000 { break }
                if let s = scoreFolded(terms: terms, wanted: wanted, name: name(item)) {
                    entries.append((item, s, date(item)))
                }
            }
        }
        entries.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            return name($0.item).localizedCompare(name($1.item)) == .orderedAscending
        }
        // 1-char prefix matches are the widest result set — cap rows so the
        // list render stays cheap even in an 8k folder.
        let cap = q.count == 1 ? min(limit, 1_000) : limit
        return entries.prefix(cap).map(\.item)
    }

    /// Ranking for results another engine already filtered (Spotlight): keeps
    /// every item, closest fuzzy match first. Anything the scorer can't match
    /// goes last instead of being dropped.
    static func rankedKeepingAll<T>(_ items: [T], query: String,
                                    name: (T) -> String, date: (T) -> Date) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let byExtension = q.hasPrefix(".")
        let terms = byExtension ? [] : foldedTerms(q)
        let wanted = byExtension ? "" : fold(q)
        var entries: [(item: T, score: Int, date: Date)] = []
        entries.reserveCapacity(items.count)
        for item in items {
            let s = byExtension ? 0 : (scoreFolded(terms: terms, wanted: wanted, name: name(item)) ?? Int.max)
            entries.append((item, s, date(item)))
        }
        entries.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            return name($0.item).localizedCompare(name($1.item)) == .orderedAscending
        }
        return entries.map(\.item)
    }

    /// Case- and diacritic-insensitive form used for every comparison.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
