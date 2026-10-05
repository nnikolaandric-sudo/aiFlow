import Foundation

// Reproduces the reported bug: bouncing between folders (Downloads -> Desktop
// -> Documents) ran a FULL fresh listing on every navigation, so each click
// paid 150–330 ms of background disk I/O that then competed with the next
// click and read as "kuca".
//
// What is REAL here: DirectoryCache (compiled from the app's own source,
// Foundation-only) and the gate that decides revalidation.
// What is a COST MODEL: `freshListingCostMs` replicates what
// `loadFreshItems` does (contentsOfDirectory + resourceValues for every entry)
// because FileItem.swift cannot compile outside the app bundle. The gate is
// what the fix changed; the cost model only prices what the gate now skips.

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let dirs = ["Downloads", "Desktop", "Documents"].map { home.appendingPathComponent($0) }

guard dirs.allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
    FileHandle.standardError.write(Data("fixture folderi ne postoje\n".utf8))
    exit(1)
}

/// Mirrors FileItem.resourceKeys — the metadata every fresh listing reads.
private let keys: [URLResourceKey] = [
    .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
    .creationDateKey, .isHiddenKey, .labelNumberKey,
]

/// Cost model for one `loadFreshItems`-equivalent pass.
func freshListingCostMs(_ dir: URL, showHidden: Bool) -> Double {
    let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    let s = Date()
    guard let urls = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: keys, options: opts) else { return 0 }
    var slots = [Bool?](repeating: nil, count: urls.count)
    slots.withUnsafeMutableBufferPointer { buf in
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            autoreleasepool { buf[i] = (try? urls[i].resourceValues(forKeys: Set(keys))) != nil }
        }
    }
    return Date().timeIntervalSince(s) * 1000
}

for d in dirs {
    let n = (try? fm.contentsOfDirectory(atPath: d.path).count) ?? 0
    print("fixture: \(d.lastPathComponent.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n) stavki")
}
print("")

let cache = DirectoryCache.shared
cache.invalidateAll()

// Prime the cache the way a first visit does: snapshot + stamp stored.
for d in dirs {
    _ = freshListingCostMs(d, showHidden: false)
    cache.storeItems([], for: d, showHidden: false)   // items content irrelevant here
    cache.store([], for: d, showHidden: false, stamp: DirectoryCache.Stamp.of(d))
}

var checkTotalMs: Double = 0
var checks = 0
var revalidations = 0
var byFolder: [String: Int] = [:]
let bounces = 12

for _ in 0..<bounces {
    for d in dirs {
        _ = cache.cachedItems(for: d, showHidden: false)          // instant paint
        let s = Date()
        let needs = cache.needsRevalidation(for: d, showHidden: false)
        checkTotalMs += Date().timeIntervalSince(s) * 1000
        checks += 1
        if needs {
            revalidations += 1
            byFolder[d.lastPathComponent, default: 0] += 1
            _ = freshListingCostMs(d, showHidden: false)
        }
    }
}

let navigations = bounces * dirs.count
print("navigacija (skakanje):  \(navigations)")
print("pune revalidacije:      \(revalidations)   (prije fiksa: \(navigations))")
print("  po folderu:           \(byFolder)")
print("provjere pečata:        \(checks) ukupno \(String(format: "%.2f", checkTotalMs)) ms " +
      "(\(String(format: "%.3f", checkTotalMs / Double(max(checks, 1)))) ms po navigaciji)")

// Price the OLD behaviour: one full listing pass per navigation, which is what
// the code did before the gate. Measured on the same folders.
let passMs = dirs.map { (d: $0, ms: freshListingCostMs($0, showHidden: false)) }
let oldTotal = passMs.map(\.ms).reduce(0, +) * Double(bounces)
print("")
print("cijena jednog punog prolaza (što je prijeradio svaki klik):")
for p in passMs {
    print("  \(p.d.lastPathComponent.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%6.0f", p.ms)) ms")
}
print("  ukupno za \(navigations) navigacija: \(String(format: "%.1f", oldTotal / 1000)) s " +
      "→ sada \(String(format: "%.2f", checkTotalMs / 1000)) s pečata")

// Sanity: the gate must NOT hide a real change. Touch a file in Downloads and
// confirm the gate reopens immediately (directory mtime bumps).
let probe = dirs[0].appendingPathComponent(".perf-bounce-probe")
fm.createFile(atPath: probe.path, contents: Data())
defer { try? fm.removeItem(at: probe) }
Thread.sleep(forTimeInterval: 0.1)
let afterChange = cache.needsRevalidation(for: dirs[0], showHidden: false)
print("")
print("nova stavka u Downloads → revalidacija tražena: \(afterChange ? "DA (ispravno)" : "NE (BUG)")")
if afterChange == false { exit(1) }
if revalidations == 0 { print("OK: skakanje između foldera ne dira disk") }
