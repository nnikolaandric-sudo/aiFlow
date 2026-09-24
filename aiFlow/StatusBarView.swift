import SwiftUI

struct StatusBarView: View {
    let files: [FileItem]
    let selectedIDs: Set<String>
    let currentPath: URL
    /// O(1) listing identity from the parent (bumps on every new listing).
    /// Lets memo keys avoid hashing the whole folder on every click.
    var filesIdentity: UInt = 0
    /// O(selection) fingerprint from the parent — avoids re-sorting the
    /// selection set here on every render.
    var selectionFingerprint: Int = 0
    /// True while background folder sizing is running — shows a progress hint.
    var isSizing: Bool = false
    /// Copy/move/trash progress message from FileOperationsService
    /// (the "Moving…"/"Copying…" hourglass toast). Shown inline here so long
    /// operations are visible without waiting for the toast.
    var operationText: String? = nil
    /// True while the folder listing (or a tag search) is still loading —
    /// without it the bar lied "Empty folder" during every cold navigation.
    var isLoading: Bool = false

    /// Cached free-space lookup — `resourceValues(.volumeAvailableCapacityKey)`
    /// hits disk, and `body` re-evaluates on every selection/sort change.
    /// Refresh only when the volume (path) changes, at most every 30s.
    @State private var cachedFreeSpace: String?
    /// Udio slobodnog prostora (0…1) za semafor; nil dok se ne zna ukupan
    /// kapacitet — tada bar ostaje neutralno siv kao ranije.
    @State private var cachedFreeFraction: Double?
    @State private var lastFreeSpaceCheck = Date.distantPast
    @State private var lastVolumePath: String = ""

    var body: some View {
        // Slim single line: left = items • size (+ selection), right = progress
        // + rules badge + free % — no middle cluster anymore.
        HStack(spacing: 8) {
            // ── Left: compact count ──
            Text(itemCountText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()

            if !selectedIDs.isEmpty {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(selectionText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            // ── Middle-right: ONE progress slot (operation wins over sizing) ──
            if let op = operationText {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(op)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if isSizing {
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Calculating sizes…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // Auto-sort badge for watched folders (FolderRulesUI.swift).
            FolderRulesStatusBadge(currentPath: currentPath)

            // Git-aware filesystem: branch ▾ ↑↓ + changes (VS Code stil, jednostavnije).
            GitStatusBarPill()

            // ── Right: free space WITH % (was tooltip-only) ──
            if let free = cachedFreeSpace {
                let neutral = Color.secondary
                let tint = cachedFreeFraction.map { FFTheme.freeSpaceColor(fraction: $0) } ?? neutral
                let low  = (cachedFreeFraction ?? 1) < 0.15
                Text(low ? "\(free) free (\(freePctString))" : "\(free) free (\(freePctString))")
                    .font(.system(size: 11, weight: low ? .semibold : .regular))
                    .foregroundStyle(low ? tint : neutral)
                    .lineLimit(1)
                    .fixedSize()
                    .monospacedDigit()
                    .help(freeSpaceHelp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .onAppear { refreshFreeSpaceIfNeeded(force: true) }
        .onChange(of: currentPath) { _, _ in refreshFreeSpaceIfNeeded() }
    }

    /// "32%" — always visible now (was hover-only), so low disk never surprises.
    private var freePctString: String {
        guard let f = cachedFreeFraction else { return "—" }
        return "\(max(0, min(100, Int((f * 100).rounded()))))%"
    }

    // Memoizovano po O(1) ključu (identity + count + endpoints): body se
    // re-evaluira na svaki klik/selekciju, a direktan O(n) prolaz + dva
    // ByteCountFormatter-a po kliku su se merili u velikim folderima.
    // Ključ namerno sadrži i sadržinski diskriminator jer search/tag rezultati
    // menjaju `files` bez bumpovanja filesIdentity.
    private var itemCountText: String {
        StatusBarMemo.shared.countText(
            files: files, isLoading: isLoading, identity: filesIdentity)
    }

    private func computeItemCountText() -> String {
        StatusBarMemo.computeCountText(files: files, isLoading: isLoading)
    }

    // Selekcija: single-put preko keširane id→item mape (O(1) po kliku umesto
    // O(n) first(where:) skena), multi-put memoizovan po fingerprintu — body
    // se zbog animacija evaluira više puta po jednom kliku.
    private var selectionText: String {
        guard !selectedIDs.isEmpty else { return "" }
        return StatusBarMemo.shared.selectionText(
            files: files, selectedIDs: selectedIDs,
            fingerprint: selectionFingerprint, identity: filesIdentity)
    }

    /// Non-reactive memo za statusnu traku (samo main thread, kao DisplayMemoCache
    /// i GroupMemoCache — upis tokom body-ja nikad ne trigeruje view update).
    private final class StatusBarMemo {
        static let shared = StatusBarMemo()

        private var countKey = ""
        private var countValue = ""
        private var selKey = ""
        private var selValue = ""
        // id→item mapa za O(1) single-selekciju; gradi se jednom po listingu.
        private var mapKey = ""
        private var idMap: [String: FileItem] = [:]

        /// O(1) diskriminator liste: search/tag menjaju `files` bez bumpovanja
        /// identity-ja, pa sam brojač nije dovoljan (ista lekcija kao u memoima
        /// za selekciju i grupe).
        private func filesKey(_ files: [FileItem], identity: UInt, extra: String = "") -> String {
            guard !files.isEmpty else { return "i\(identity)#c0\(extra)" }
            let mid = files.count / 2
            return "i\(identity)#c\(files.count)#f\(files[0].id)#m\(files[mid].id)#l\(files[files.count - 1].id)\(extra)"
        }

        func countText(files: [FileItem], isLoading: Bool, identity: UInt) -> String {
            let key = filesKey(files, identity: identity, extra: isLoading ? "#l1" : "#l0")
            if key == countKey { return countValue }
            let value = StatusBarMemo.computeCountText(files: files, isLoading: isLoading)
            countKey = key
            countValue = value
            return value
        }

        func selectionText(files: [FileItem], selectedIDs: Set<String>,
                           fingerprint: Int, identity: UInt) -> String {
            let fk = filesKey(files, identity: identity)
            let key = "\(fk)#s\(selectedIDs.count)#\(fingerprint)"
            if key == selKey { return selValue }
            let value = computeSelection(files: files, selectedIDs: selectedIDs, filesKey: fk)
            selKey = key
            selValue = value
            return value
        }

        private func computeSelection(files: [FileItem], selectedIDs: Set<String>,
                                      filesKey fk: String) -> String {
            if selectedIDs.count == 1, let id = selectedIDs.first {
                // O(1) preko keširane mape; mapa se gradi jednom po listingu.
                if mapKey != fk {
                    idMap = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
                    mapKey = fk
                }
                guard let item = idMap[id] else { return "1 selected" }
                if item.isDirectory {
                    if let fs = item.folderSize, fs > 0 {
                        return "1 selected — \(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))"
                    }
                    return "1 selected"
                }
                if item.size > 0 {
                    return "1 selected — \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))"
                }
                return "1 selected"
            }
            // Multi-selekcija je retka (shift/cmd): direktan filter, bez diranja
            // single-mape iznad (ostaje važeća za sledeći klik na 1 fajl).
            let sel = files.filter { selectedIDs.contains($0.id) }
            let totalBytes: Int64 = sel.reduce(0) { acc, item in
                if item.isBrowsableFolder { return acc + (item.folderSize ?? 0) }
                return item.isDirectory ? acc : acc + item.size
            }
            let countStr = "\(sel.count) selected"
            return totalBytes > 0
                ? "\(countStr) — \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                : countStr
        }

        /// Compact: "12 items • 340 MB" (was "2 folders, 10 files • …").
        /// Folder/file split lives in the browser itself — the bar stays quiet.
        static func computeCountText(files: [FileItem], isLoading: Bool) -> String {
            if isLoading && files.isEmpty { return "Loading…" }
            guard !files.isEmpty else { return "Empty folder" }
            var bytes: Int64 = 0
            for f in files {
                if f.isBrowsableFolder {
                    if let fs = f.folderSize { bytes += fs }
                }
                else if !f.isDirectory { bytes += f.size }
            }
            var text = "\(files.count) \(files.count == 1 ? "item" : "items")"
            if bytes > 0 {
                text += " • \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            }
            return text
        }
    }

    private var freeDiskSpace: String? { cachedFreeSpace }

    private var freeSpaceHelp: String {
        guard let f = cachedFreeFraction else { return "Free space on this volume" }
        let pct = max(0, min(100, Int((f * 100).rounded())))
        return "\(pct)% of this volume is free"
    }

    /// Disk stat on a background queue, cached per-volume with 30s TTL.
    private func refreshFreeSpaceIfNeeded(force: Bool = false) {
        // Volume resolution (resourceValues) is a disk stat — do it off-main
        // like the capacity lookup below, not synchronously in body/onChange.
        // @State se čita unapred (plain letovi): struct ne može `weak self`,
        // a čitanje Statea sa background threada bi bila trka.
        let path = currentPath
        let now = Date()
        let lastPath = lastVolumePath
        let lastCheck = lastFreeSpaceCheck
        DispatchQueue.global(qos: .utility).async {
            let volumeKey = (try? path.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
                ?? path.path
            guard force || volumeKey != lastPath
                || now.timeIntervalSince(lastCheck) > 30 else { return }
            guard let v = try? path.resourceValues(forKeys: [.volumeAvailableCapacityKey,
                                                              .volumeTotalCapacityKey]),
                  let bytes = v.volumeAvailableCapacity else { return }
            let text = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            // Isti stat vraća i ukupan kapacitet — semafor ne košta dodatni I/O.
            var fraction: Double?
            if let total = v.volumeTotalCapacity, total > 0 {
                fraction = Double(bytes) / Double(total)
            }
            DispatchQueue.main.async {
                // Stale guard bez ikakvog stat-a na mainu: ako je korisnik
                // otišao drugde, onChange(currentPath) je već zakazao svoj
                // refresh za novi folder — ovaj rezultat se odbacuje.
                guard self.currentPath == path else { return }
                self.lastVolumePath = volumeKey
                self.lastFreeSpaceCheck = now
                self.cachedFreeSpace = text
                self.cachedFreeFraction = fraction
            }
        }
    }
}
