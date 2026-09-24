import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Date category (Finder-style Recent / Older grouping)

/// Matches Finder's "Group by Date" buckets — including the "Previous 90 Days"
/// band Finder added after the old 30-day / Earlier split.
enum DateCategory: String, CaseIterable, Identifiable {
    case today        = "Today"
    case yesterday    = "Yesterday"
    case previous7    = "Previous 7 Days"
    case previous30   = "Previous 30 Days"
    case previous90   = "Previous 90 Days"
    case earlier      = "Earlier"

    var id: String { rawValue }

    static func of(_ date: Date) -> DateCategory { Classifier().category(of: date) }

    /// Day boundaries worked out once: grouping a big folder used to run four
    /// calendar calculations per file on every render.
    struct Classifier {
        private let startOfToday, startOfTomorrow, startOfYesterday: Date
        /// "At most n whole days ago" means later than now minus n + 1 days.
        private let after7, after30, after90: Date

        init(now: Date = Date(), calendar: Calendar = .current) {
            let today = calendar.startOfDay(for: now)
            startOfToday     = today
            startOfTomorrow  = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            startOfYesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? now
            after7  = calendar.date(byAdding: .day, value: -8, to: now) ?? now
            after30 = calendar.date(byAdding: .day, value: -31, to: now) ?? now
            after90 = calendar.date(byAdding: .day, value: -91, to: now) ?? now
        }

        func category(of date: Date) -> DateCategory {
            // Future timestamps (clock skew, copied metadata) group with
            // today — previously any future date fell through to previous7.
            if date >= startOfToday { return .today }
            if date >= startOfYesterday && date < startOfToday { return .yesterday }
            if date > after7  { return .previous7 }
            if date > after30 { return .previous30 }
            if date > after90 { return .previous90 }
            return .earlier
        }
    }
}

// MARK: - Grouping & folder order

/// How items are visually sectioned. Sort field still applies *inside* each group.
enum GroupBy: String, CaseIterable, Identifiable {
    case none = "None"
    case dateModified = "Date Modified"
    case dateCreated  = "Date Created"
    case kind         = "Kind"
    case extension_   = "Extension"
    case size         = "Size"
    case nameInitial  = "Name"

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .none:         return "None"
        case .dateModified: return "Date Modified"
        case .dateCreated:  return "Date Created"
        case .kind:         return "Kind"
        case .extension_:   return "Extension"
        case .size:         return "Size"
        case .nameInitial:  return "Name"
        }
    }
}

/// Whether folders float above files, sink below, or mix with the sort.
enum FolderOrder: String, CaseIterable, Identifiable {
    case foldersFirst = "Folders on Top"
    case filesFirst   = "Files on Top"
    case mixed        = "Mixed (Sort Only)"

    var id: String { rawValue }
}

/// A labeled section of already-sorted items used by list / icon / column views.
struct FileGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [FileItem]
}

/// Bucket absolute file sizes into Finder / Explorer-like bands.
enum SizeBand: String, CaseIterable, Identifiable {
    case folders     = "Folders"
    case zero        = "Zero KB"
    case tiny        = "1 KB – 100 KB"
    case small       = "100 KB – 1 MB"
    case medium      = "1 MB – 100 MB"
    case large       = "100 MB – 1 GB"
    case huge        = "Over 1 GB"

    var id: String { rawValue }

    static func of(_ item: FileItem) -> SizeBand {
        if item.isBrowsableFolder { return .folders }
        let s = item.size
        if s <= 0          { return .zero }
        if s < 100_000     { return .tiny }
        if s < 1_000_000   { return .small }
        if s < 100_000_000 { return .medium }
        if s < 1_000_000_000 { return .large }
        return .huge
    }
}

// MARK: - FileItem

struct FileItem: Identifiable, Hashable {
    /// Stable path-based id so selection / rename survive directory reloads.
    let id:            String
    let url:           URL
    let name:          String
    let isDirectory:   Bool
    let isPackage:     Bool      // opaque bundle (.app, .pages, …) — open, don't browse
    let isHidden:      Bool
    let size:          Int64
    let dateModified:  Date
    let dateCreated:   Date
    let kind:          String
    let fileExtension: String

    let labelNumber: Int
    let tagNames:    [String]   // macOS modern tags (multiple per file)
    /// Recursive folder size in bytes, filled asynchronously by
    /// FolderSizeService when "Calculate folder sizes" is on. Nil = unknown
    /// (not computed, skipped, or not a browsable folder). Deliberately
    /// EXCLUDED from `==` so background revalidation (`fresh != rawFiles`)
    /// doesn't wipe freshly computed sizes on every reload — but INCLUDED
    /// in `contentHash` so size-grouping memos invalidate when sizes land.
    let folderSize:  Int64?
    /// Pre-rendered row strings, computed once in `init` while the listing is
    /// built off-main: `DateFormatter.string` / `ByteCountFormatter` per row
    /// per render was main-thread time on every selection change. Derived
    /// purely from the fields above, so `==`/hash (which compare those
    /// fields) stay consistent; `withFolderSize` copies them through.
    /// Folder size text stays dynamic (recursive total lands async) — see
    /// `formattedSize`; `fileSizeText` covers plain files only.
    let formattedDateModified: String
    let formattedDateCreated: String
    let fileSizeText: String

    init(id: String, url: URL, name: String, isDirectory: Bool, isPackage: Bool,
         isHidden: Bool, size: Int64, dateModified: Date, dateCreated: Date,
         kind: String, fileExtension: String, labelNumber: Int, tagNames: [String],
         folderSize: Int64? = nil) {
        self.id = id; self.url = url; self.name = name
        self.isDirectory = isDirectory; self.isPackage = isPackage
        self.isHidden = isHidden; self.size = size
        self.dateModified = dateModified; self.dateCreated = dateCreated
        self.kind = kind; self.fileExtension = fileExtension
        self.labelNumber = labelNumber; self.tagNames = tagNames
        self.folderSize = folderSize
        self.formattedDateModified = Self.itemDateFormatter.string(from: dateModified)
        self.formattedDateCreated = Self.itemDateFormatter.string(from: dateCreated)
        self.fileSizeText = isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Keys needed to browse / sort / group quickly. Kind description and tags
    /// are filled with cheap fallbacks so folder opens don't wait on UTType/tag I/O.
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .isHiddenKey, .labelNumberKey,
    ]
    static let resourceKeySet: Set<URLResourceKey> = Set(resourceKeys)

    /// Extra keys for Get Info / tag UI enrichment (optional second pass).
    static let enrichKeys: [URLResourceKey] = [
        .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    /// True when double-click should navigate into this item like a normal folder.
    /// Application bundles and other opaque packages launch instead (Finder behaviour).
    var isBrowsableFolder: Bool { isDirectory && !isPackage }

    /// True when the file is online-only (not downloaded): Google Drive Stream,
    /// OneDrive Files On-Demand, iCloud "Remove Download" itd. Čitanje sadržaja
    /// takvog fajla pokrenulo bi puno preuzimanje — zato ga nikad ne sniffujemo,
    /// ne preview-ujemo i ne čitamo na glavnoj niti. Samo metadata (ime, veličina,
    /// datumi) je bezbedna. Vraća false za obične lokalne fajlove.
    static func isNotDownloaded(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = v.ubiquitousItemDownloadingStatus else { return false }
        return status == .notDownloaded
    }

    /// Instance varijanta — poziv je jeftin metadata lookup (ne skida fajl),
    /// ali ga ne zovi po svakom redu u velikom folderu, samo za selektovani item.
    var isNotDownloaded: Bool { Self.isNotDownloaded(url) }

    /// URL-level check used before a `FileItem` exists (path bar / external opens).
    /// Prefer `item.isBrowsableFolder` when a `FileItem` is already loaded.
    static func isBrowsableFolder(_ url: URL) -> Bool {
        // Fast path: .app is never browsable as a folder.
        if url.pathExtension.lowercased() == "app" { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        if let v = try? url.resourceValues(forKeys: [.isPackageKey]), v.isPackage == true {
            return false
        }
        return true
    }

    static func load(from url: URL) -> FileItem? {
        guard let v = try? url.resourceValues(forKeys: resourceKeySet) else { return nil }
        let ext = url.pathExtension.lowercased()
        let isPkg = v.isPackage ?? (ext == "app")
        let isDir = v.isDirectory ?? false
        // Prefer localized kind when present; otherwise a cheap extension-based label
        // so we don't require .localizedTypeDescriptionKey on every folder open.
        let kind = v.localizedTypeDescription
            ?? (isDir && !isPkg ? "Folder"
                : (ext.isEmpty ? "File" : "\(ext.uppercased()) File"))
        return FileItem(
            id:            url.path,
            url:           url,
            name:          url.lastPathComponent,
            isDirectory:   isDir,
            isPackage:     isPkg,
            isHidden:      v.isHidden ?? false,
            size:          Int64(v.fileSize ?? 0),
            dateModified:  v.contentModificationDate ?? .distantPast,
            dateCreated:   v.creationDate ?? .distantPast,
            kind:          kind,
            fileExtension: ext,
            labelNumber:   v.labelNumber ?? 0,
            tagNames:      v.tagNames ?? []
        )
    }

    // Icon with NSCache — safe, thread-checked, and limits RAM to ~500 entries
    // NOTE: `icon` is synchronous and hits NSWorkspace on a miss — never call
    // it directly from a SwiftUI row body for large folders. Prefer
    // `FileIconView` below (async, placeholder-first) or `cachedIcon(for:)`.
    var icon: NSImage {
        let key = url.path as NSString
        if let hit = FileItem.iconCache.object(forKey: key) { return hit }
        let img = FileItem.loadIcon(url: url, isDirectory: isDirectory, isPackage: isPackage)
        FileItem.cacheIcon(img, forKey: key)
        return img
    }

    private static let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.name = "FinderFlow.iconCache"
        c.countLimit = 2000
        // Honored only because every insertion below passes an explicit cost
        // (32px RGBA bitmap, downsampled in `loadIcon`, ~4KB each).
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()

    /// Store a per-file icon with its real byte cost so `totalCostLimit` above
    /// actually bounds RAM. Callers must pass downsampled images (see `loadIcon`).
    /// Cost is summed over the bitmap reps (32px + 64px ≈ 20KB), not `img.size`
    /// points — point size alone would undercount @2x by 5×.
    private static func cacheIcon(_ img: NSImage, forKey key: NSString) {
        var cost = 0
        for rep in img.representations {
            if let bitmap = rep as? NSBitmapImageRep {
                cost += bitmap.pixelsWide * bitmap.pixelsHigh * 4
            }
        }
        iconCache.setObject(img, forKey: key, cost: max(cost, 1024))
    }

    /// Serial-ish background queue for icon loads so scrolling a 10k folder
    /// doesn't spawn 10k concurrent NSWorkspace calls.
    private static let iconQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        q.name = "FinderFlow.iconQueue"
        return q
    }()

    /// Instant non-blocking lookup. Returns nil on miss (caller shows placeholder).
    static func cachedIcon(for url: URL) -> NSImage? {
        iconCache.object(forKey: url.path as NSString)
    }

    /// Placeholder shown before the real icon arrives — no disk/AppKit lookup.
    static func placeholderIcon(isDirectory: Bool, isPackage: Bool) -> NSImage {
        let key = ((isDirectory && !isPackage) ? "__folder__" : "__file__") as NSString
        if let hit = iconCache.object(forKey: key) { return hit }
        let img: NSImage
        if isDirectory && !isPackage {
            img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                ?? NSImage(size: NSSize(width: 32, height: 32))
        } else {
            // Filled (not outline "doc"): matches the visual weight of loaded
            // type icons and the filled folder glyph, so rows don't flash
            // thin outlines while icons stream in.
            img = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "File")
                ?? NSWorkspace.shared.icon(for: .data)
        }
        img.size = NSSize(width: 32, height: 32)
        iconCache.setObject(img, forKey: key, cost: 0)
        return img
    }

    /// Background icon fetch. Completion always runs on main.
    static func requestIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        requestIcon(url: item.url, isDirectory: item.isDirectory, isPackage: item.isPackage, completion: completion)
    }

    static func requestIcon(url: URL, isDirectory: Bool, isPackage: Bool,
                            completion: @escaping (NSImage) -> Void) {
        let key = url.path as NSString
        if let hit = iconCache.object(forKey: key) {
            completion(hit)
            return
        }
        // A document whose type icon is already loaded needs no background hop,
        // so its row paints the real icon right away instead of a placeholder.
        if let typeKey = typeIconKey(url: url, isDirectory: isDirectory, isPackage: isPackage),
           let hit = iconCache.object(forKey: typeKey) {
            cacheIcon(hit, forKey: key)
            completion(hit)
            return
        }
        iconQueue.addOperation {
            let img = loadIcon(url: url, isDirectory: isDirectory, isPackage: isPackage)
            cacheIcon(img, forKey: key)
            OperationQueue.main.addOperation { completion(img) }
        }
    }

    static func clearIconCache() { iconCache.removeAllObjects() }

    /// Plain documents of these types always show their type's icon (the same
    /// pixels as the per-file icon), so each type shares one image: about 2x
    /// faster than a lookup per file and ~10 KB less memory per file. Folders,
    /// packages and other files keep per-file icons, which can be custom.
    private static let sharedIconExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg",
        "raw", "dng", "cr2", "cr3", "nef", "arw", "psd",
        "mp3", "m4a", "wav", "aac", "flac", "aif", "aiff", "ogg",
        "mp4", "m4v", "mov", "avi", "mkv", "webm",
        "pdf", "txt", "md", "rtf", "csv", "json", "xml", "yaml", "yml", "log",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "swift", "py", "js", "ts", "tsx", "jsx", "html", "htm", "css", "c", "h", "cpp", "hpp",
        "m", "mm", "java", "kt", "go", "rs", "rb", "php", "sh", "zsh", "sql",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar",
    ]

    private static func typeIconKey(url: URL, isDirectory: Bool, isPackage: Bool) -> NSString? {
        guard !isDirectory, !isPackage else { return nil }
        let ext = url.pathExtension.lowercased()
        return sharedIconExtensions.contains(ext) ? "__type__.\(ext)" as NSString : nil
    }

    /// Loads one item's icon, reusing the shared type icon where possible.
    /// Hits NSWorkspace on a miss, so keep it off the main thread.
    ///
    /// The returned image is a real 32pt downsample (@1x + @2x reps) — NOT the
    /// full-resolution icon with its display size tweaked. `NSWorkspace`
    /// hands back representations up to 512/1024px (~1MB), and caching 2000
    /// of those pushed the app past 2GB (profiled). Every UI surface displays
    /// ≤64px except the icon-size slider (up to 128px), where the @2x rep
    /// keeps things crisp enough at 1/100th the memory.
    private static func loadIcon(url: URL, isDirectory: Bool, isPackage: Bool) -> NSImage {
        guard let typeKey = typeIconKey(url: url, isDirectory: isDirectory, isPackage: isPackage) else {
            // Copy: NSWorkspace may hand out a shared instance; reading its
            // pixels while AppKit mutates it elsewhere is a data race.
            let src = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage)
                ?? NSWorkspace.shared.icon(forFile: url.path)
            return downsampled(src)
        }
        if let hit = iconCache.object(forKey: typeKey) { return hit }
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        // Copy: NSWorkspace may hand out a shared instance, and ours gets resized.
        let src = (NSWorkspace.shared.icon(for: type).copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: url.path)
        let img = downsampled(src)
        iconCache.setObject(img, forKey: typeKey, cost: 0)
        return img
    }

    /// Renders `src` into a fresh 32pt bitmap (@1x and @2x reps), dropping the
    /// large representations NSWorkspace attaches (they are what ate the RAM:
    /// up to 1024px, ~1MB per icon, ×2000 cached = profiled 2GB peak).
    /// Safe to call on any thread: no drawing goes to a window or context.
    ///
    /// Each rep is drawn in *pixel* space (pixelsWide × pixelsHigh), not point
    /// space: drawing 32pt into the 64px rep would paint only the bottom-left
    /// quarter and leave the rest transparent (Retina icons would show a
    /// quarter-size image in the corner).
    private static func downsampled(_ src: NSImage) -> NSImage {
        let dst = NSImage(size: NSSize(width: 32, height: 32))
        let sizes = [32, 64]
        for px in sizes {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: 32, height: 32)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            // `draw(in:from:)` would re-pick a rep from `src` by size; draw via
            // the source's best CGImage instead so the full-res art lands here.
            if let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let ctx = NSGraphicsContext.current?.cgContext
                ctx?.interpolationQuality = .high
                // NSBitmapImageRep contexts are flipped relative to CG.
                ctx?.saveGState()
                ctx?.translateBy(x: 0, y: CGFloat(px))
                ctx?.scaleBy(x: 1, y: -1)
                ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
                ctx?.restoreGState()
            } else {
                src.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                         from: NSRect(origin: .zero, size: src.size),
                         operation: .copy, fraction: 1.0)
            }
            NSGraphicsContext.restoreGraphicsState()
            dst.addRepresentation(rep)
        }
        return dst
    }

    // MARK: - Real thumbnails (Finder-style image/PDF/movie previews)

    /// File types that get a real content thumbnail instead of the generic
    /// type icon. Finder shows these everywhere — without them every image
    /// is a blank white page next to vivid folders.
    private static let thumbnailExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
        "pdf",
        "mp4", "m4v", "mov",
    ]

    /// Thumbnails for huge files stall the queue (a 4GB movie seeks before it
    /// renders) — those keep the instant type icon.
    private static let thumbnailMaxBytes: Int64 = 300 * 1024 * 1024

    static func wantsThumbnail(for item: FileItem) -> Bool {
        !item.isDirectory && !item.isPackage
            && item.size > 0 && item.size <= thumbnailMaxBytes
            && thumbnailExtensions.contains(item.fileExtension.lowercased())
    }

    /// Per path+mtime so an edited file refreshes instead of showing stale art.
    /// Old keys linger in the NSCache and are evicted under pressure.
    private static func thumbnailKey(for item: FileItem) -> NSString {
        "__thumb__\(item.url.path)#\(Int(item.dateModified.timeIntervalSince1970))" as NSString
    }

    /// QLThumbnailGenerator art at grid size (128px covers the max icon-size
    /// slider; rows downscale). Completion always runs on main. Nil on any
    /// failure — caller falls back to the NSWorkspace type icon.
    ///
    /// Throttled: at most 4 generations run at once (same width as the icon
    /// queue). Firing one QL request per visible image/PDF row unthrottled
    /// flooded quicklookd while scrolling big media folders — hundreds of
    /// concurrent XPC generations competing with the real folder load.
    /// The returned handle lets the row cancel when it scrolls away or is
    /// reused; cancelled pendings are skipped, in-flight ones are dropped at
    /// the main-thread completion. Cancel is idempotent and safe to call
    /// from any thread.
    @discardableResult
    static func requestThumbnail(for item: FileItem, completion: @escaping (NSImage?) -> Void) -> ThumbnailRequest {
        let key = thumbnailKey(for: item)
        if let hit = iconCache.object(forKey: key) {
            completion(hit)
            // Main thread here (SwiftUI row path) — capture the scale before
            // the work hops to the throttle queue.
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return ThumbnailRequest.finished(item: item, key: key, scale: scale)
        }
        // Main thread here (SwiftUI row path) — capture the scale before the
        // work hops to the throttle queue.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = ThumbnailRequest(item: item, key: key, scale: scale, completion: completion)
        thumbSync.async { enqueueThumbnail(req) }
        return req
    }

    /// Serial bookkeeping for the throttle (never the heavy work itself —
    /// that lives in quicklookd). Default QoS: completions hop to main anyway.
    private static let thumbSync = DispatchQueue(label: "FinderFlow.thumbnails")
    private static var thumbInFlight = 0
    private static let thumbMaxInFlight = 4
    private static var thumbPending: [ThumbnailRequest] = []

    /// Queue a fetch or start it now. thumbSync only.
    private static func enqueueThumbnail(_ req: ThumbnailRequest) {
        guard !req.isCancelled else { return }
        guard thumbInFlight < thumbMaxInFlight else {
            thumbPending.append(req)
            return
        }
        thumbInFlight += 1
        launchThumbnail(req)
    }

    /// Fire one QL generation. thumbSync only.
    private static func launchThumbnail(_ req: ThumbnailRequest) {
        let request = QLThumbnailGenerator.Request(
            fileAt: req.item.url,
            size: CGSize(width: 128, height: 128),
            scale: req.scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let img = rep?.nsImage
            if let img { cacheIcon(img, forKey: req.key) }
            thumbSync.async { finishThumbnailSlot() }
            OperationQueue.main.addOperation { req.complete(with: img) }
        }
    }

    /// Free a slot and drain the queue, skipping whatever was cancelled while
    /// waiting (fast scroll leaves stale rows behind). thumbSync only.
    private static func finishThumbnailSlot() {
        thumbInFlight -= 1
        while thumbInFlight < thumbMaxInFlight, !thumbPending.isEmpty {
            let next = thumbPending.removeFirst()
            guard !next.isCancelled else { continue }
            thumbInFlight += 1
            launchThumbnail(next)
        }
    }

    fileprivate static func cancelThumbnail(_ req: ThumbnailRequest) {
        thumbSync.async {
            thumbPending.removeAll { $0 === req }
            // An in-flight generation can't be recalled from quicklookd;
            // its main-thread completion drops the result instead.
        }
    }

    // Convenience
    /// Size used for display, totals and size-sort: recursive total for
    /// sized folders, plain file size otherwise.
    var effectiveSize: Int64 {
        if isBrowsableFolder, let fs = folderSize { return fs }
        return size
    }
    var formattedSize: String {
        if isBrowsableFolder {
            guard let fs = folderSize else { return "—" }
            return ByteCountFormatter.string(fromByteCount: fs, countStyle: .file)
        }
        // Plain files reuse the load-time string (same value, no formatter
        // on the render path); folders stay dynamic, see fileSizeText.
        return isDirectory ? "—" : fileSizeText
    }

    /// Row-level size text: while a sizing run is in flight, folders that are
    /// still unmeasured show "…" (pending) instead of "—", so progress reads
    /// per row and the status-bar "Calculating sizes…" has a visible partner.
    func displaySize(sizingActive: Bool) -> String {
        if isBrowsableFolder, folderSize == nil, sizingActive { return "…" }
        return formattedSize
    }

    /// Copy with the recursive folder size attached (struct copy-on-write —
    /// the caller replaces the element in its array to publish the update).
    /// Passing nil strips a previously computed size (pref toggled off).
    func withFolderSize(_ bytes: Int64?) -> FileItem {
        FileItem(id: id, url: url, name: name, isDirectory: isDirectory,
                 isPackage: isPackage, isHidden: isHidden, size: size,
                 dateModified: dateModified, dateCreated: dateCreated,
                 kind: kind, fileExtension: fileExtension,
                 labelNumber: labelNumber, tagNames: tagNames,
                 folderSize: bytes)
    }

    var dateCategory: DateCategory { DateCategory.of(dateModified) }
    var dateCreatedCategory: DateCategory { DateCategory.of(dateCreated) }

    /// First letter (A–Z) used by "Group by Name"; everything else → "#".
    var nameGroupKey: String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
        // Uppercasing can expand ("ß" → "SS"), so only a single A–Z scalar matches.
        // Plain scalar check, not a regex: this runs once per file per grouping
        // (~19ms per 10k items with NSRegularExpression).
        let upper = String(first).uppercased()
        guard upper.count == 1, let scalar = upper.unicodeScalars.first,
              scalar.value >= 65, scalar.value <= 90 else { return "#" }
        return upper
    }

    // All tag colors for this item — uses modern tagNames first (multiple colors
    // per file), falls back to the legacy labelNumber if tagNames is empty.
    // Fast path first: untagged files (the common case) skip two switch calls
    // and an array alloc. This runs once per visible row per render.
    var tagColors: [Color] {
        if tagNames.isEmpty {
            if labelNumber == 0 { return [] }
            return FileItem.colorForLabelNumber(labelNumber).map { [$0] } ?? []
        }
        let fromNames = tagNames.compactMap { FileItem.colorForTagName($0) }
        if !fromNames.isEmpty { return fromNames }
        return FileItem.colorForLabelNumber(labelNumber).map { [$0] } ?? []
    }

    // Single-color convenience kept for backward compat.
    var tagColor: Color? { tagColors.first }

    // macOS Finder exact system tag colors (matches Tag preferences in Finder).
    static func colorForTagName(_ name: String) -> Color? {
        switch name.lowercased() {
        case "red":          return Color(red: 1.00, green: 0.23, blue: 0.19)
        case "orange":       return Color(red: 1.00, green: 0.58, blue: 0.00)
        case "yellow":       return Color(red: 1.00, green: 0.80, blue: 0.00)
        case "green":        return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "blue":         return Color(red: 0.00, green: 0.48, blue: 1.00)
        case "purple":       return Color(red: 0.69, green: 0.32, blue: 0.87)
        case "gray", "grey": return Color(nsColor: .systemGray)
        default:             return nil   // custom tag with no standard color
        }
    }

    static func colorForLabelNumber(_ n: Int) -> Color? {
        switch n {
        case 1: return Color(nsColor: .systemGray)
        case 2: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case 3: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case 4: return Color(red: 0.00, green: 0.48, blue: 1.00)
        case 5: return Color(red: 1.00, green: 0.80, blue: 0.00)
        case 6: return Color(red: 1.00, green: 0.23, blue: 0.19)
        case 7: return Color(red: 1.00, green: 0.58, blue: 0.00)
        default: return nil
        }
    }

    // Standard color name → label number, mirrors macOS Finder.
    static let colorNameToLabel: [String: Int] = [
        "gray": 1, "green": 2, "purple": 3, "blue": 4,
        "yellow": 5, "red": 6, "orange": 7
    ]
    static let labelToColorName: [Int: String] = [
        1: "Gray", 2: "Green", 3: "Purple", 4: "Blue",
        5: "Yellow", 6: "Red", 7: "Orange"
    ]

    // Order the 7 standard colors are presented in the Tags menu (matches Finder).
    static let colorMenuOrder = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]

    // True when this item carries the given standard color tag (case-insensitive).
    func hasColorTag(_ name: String) -> Bool {
        tagNames.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    var isArchive: Bool {
        ArchiveService.isSupportedArchive(url)
    }

    /// DateFormatter is not thread-safe, and items are built on background
    /// queues (parallel listing). One cached formatter per thread — main
    /// keeps its own, workers keep theirs: no lock, no per-item alloc.
    /// Values are frozen at load; a mid-session locale change refreshes on
    /// the next reload (same as the icon cache).
    private static var itemDateFormatter: DateFormatter {
        let key = "FinderFlow.itemDateFormatter"
        if let hit = Thread.current.threadDictionary[key] as? DateFormatter { return hit }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        Thread.current.threadDictionary[key] = f
        return f
    }

    // Identity is path-based (selection/rename survive reloads), but equality
    // compares full content: the reload same-list guard (`fresh != rawFiles`)
    // must detect a same-path file whose size/dates/tags changed, or the UI
    // would keep showing stale rows.
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.name == rhs.name
            && lhs.isDirectory == rhs.isDirectory
            && lhs.isPackage == rhs.isPackage
            && lhs.isHidden == rhs.isHidden
            && lhs.size == rhs.size
            && lhs.dateModified == rhs.dateModified
            && lhs.dateCreated == rhs.dateCreated
            && lhs.kind == rhs.kind
            && lhs.fileExtension == rhs.fileExtension
            && lhs.labelNumber == rhs.labelNumber
            && lhs.tagNames == rhs.tagNames
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Cheap content hash for memo fingerprints: identity + the fields that
    /// affect sort/group/display. Two lists with equal hashes are treated as
    /// unchanged by the render memo caches (sort order is part of the hash).
    var contentHash: Int {
        var h = Hasher()
        h.combine(id)
        h.combine(size)
        h.combine(folderSize)
        h.combine(dateModified)
        h.combine(dateCreated)
        h.combine(kind)
        h.combine(labelNumber)
        h.combine(tagNames)
        return h.finalize()
    }
}

extension Array where Element == FileItem {
    /// Order-sensitive list hash: count + a position-weighted mix over the
    /// whole list, so ANY content change, swap or reorder invalidates.
    /// O(n) integer hashing — ~50µs per 10k items, vs 225ms uncached grouping.
    var contentSignature: Int {
        var h = Hasher()
        h.combine(count)
        for (i, item) in enumerated() {
            // Position in the mix: a swap of two items changes the stream even
            // though the multiset of hashes is identical (XOR alone wouldn't).
            h.combine(i)
            h.combine(item.contentHash)
        }
        return h.finalize()
    }
}

// MARK: - Tag dot(s) view — matches macOS Finder's colored-circle appearance

struct TagDotsView: View {
    let colors: [Color]
    var size: CGFloat = 10

    var body: some View {
        if !colors.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .overlay(
                            Circle().strokeBorder(color.opacity(0.4), lineWidth: 0.5)
                        )
                }
            }
        }
    }
}

// MARK: - Cancellable thumbnail request (throttle handle)

/// Handle for one throttled thumbnail fetch (see `FileItem.requestThumbnail`).
/// Rows keep the current request and cancel it on reuse/disappear, so a fast
/// scroll doesn't queue hundreds of stale generations ahead of the visible
/// rows. The flag is lock-guarded (set from the UI thread, read from the
/// throttle queue and the main-thread completion). The cancel-vs-complete
/// race is airtight by main-queue serial ordering: either the completion runs
/// fully before the cancel lands (image applies, the row then reloads
/// normally) or the cancel lands first and the completion is dropped.
final class ThumbnailRequest: @unchecked Sendable {
    fileprivate let item: FileItem
    fileprivate let key: NSString
    fileprivate let scale: CGFloat
    private let completion: (NSImage?) -> Void
    private let lock = NSLock()
    private var _cancelled = false

    fileprivate init(item: FileItem, key: NSString, scale: CGFloat,
                     completion: @escaping (NSImage?) -> Void) {
        self.item = item; self.key = key; self.scale = scale
        self.completion = completion
    }

    /// Pre-cancelled handle for the cache-hit path: the completion already
    /// ran synchronously, so there is nothing to throttle or cancel — but
    /// the caller can still call `cancel()` unconditionally.
    fileprivate static func finished(item: FileItem, key: NSString, scale: CGFloat) -> ThumbnailRequest {
        let req = ThumbnailRequest(item: item, key: key, scale: scale, completion: { _ in })
        req._cancelled = true
        return req
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    /// Drop the pending queue entry (if still waiting); an in-flight
    /// generation finishes in quicklookd but its result is discarded at the
    /// main-thread completion. Idempotent, safe from any thread.
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        FileItem.cancelThumbnail(self)
    }

    /// Main thread only (all completions hop through OperationQueue.main).
    fileprivate func complete(with img: NSImage?) {
        lock.lock(); let cancelled = _cancelled; lock.unlock()
        guard !cancelled else { return }
        completion(img)
    }
}

// MARK: - Async file icon (placeholder-first, never blocks row render)

/// Drop-in replacement for `Image(nsImage: item.icon)`.
///
/// Why: `NSWorkspace.icon(forFile:)` does IPC + disk I/O and used to run
/// synchronously inside every row body — opening a folder with N visible rows
/// paid N× icon cost on the main thread before anything painted. This view
/// paints a cached placeholder instantly and swaps in the real icon when the
/// background load finishes.
struct FileIconView: View {
    let item: FileItem
    var size: CGFloat = 16

    @State private var nsImage: NSImage?
    @State private var requestedID: String?
    /// Current thumbnail fetch, if any. Cancelled when the row is reused for
    /// another item or scrolls away, so stale generations never jump the
    /// queue ahead of visible rows (and never paint a wrong image).
    @State private var thumbnailRequest: ThumbnailRequest?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
            } else {
                Image(nsImage: FileItem.placeholderIcon(isDirectory: item.isDirectory,
                                                        isPackage: item.isPackage))
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .onAppear { load() }
        .onDisappear {
            // Scrolled away: drop the queued fetch. Reappear reloads from the
            // icon cache (hit when it already arrived) or re-queues.
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
            requestedID = nil
        }
        .onChange(of: item.id) { _, _ in
            requestedID = nil
            load()
        }
    }

    private func load() {
        let id = item.id
        guard requestedID != id else { return }
        // Row reused: the previous fetch (if any) belongs to another item.
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        requestedID = id
        if let hit = FileItem.cachedIcon(for: item.url) {
            nsImage = hit
            requestedID = nil
            return
        }
        // Thumbnailable types (images/PDFs/movies) get real Finder-style art
        // first; anything else — or any thumbnail failure — falls back to the
        // NSWorkspace type icon path below. Cancellation (not an id check)
        // guards staleness: a reused row cancels here, so this completion
        // only ever runs for the item the row still shows.
        if FileItem.wantsThumbnail(for: item) {
            thumbnailRequest = FileItem.requestThumbnail(for: item) { img in
                requestedID = nil
                if let img {
                    nsImage = img
                } else {
                    requestTypeIcon(id: id, item: item)
                }
            }
            return
        }
        requestTypeIcon(id: id, item: item)
    }

    private func requestTypeIcon(id: String, item: FileItem) {
        FileItem.requestIcon(for: item) { [item] img in
            guard id == item.id else { return }
            requestedID = nil
            nsImage = img
        }
    }
}

// MARK: - Async URL icon (placeholder-first, never blocks row render)

struct URLIconView: View {
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    var size: CGFloat = 16

    @State private var nsImage: NSImage?
    @State private var requestedPath: String?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
            } else {
                Image(nsImage: FileItem.placeholderIcon(isDirectory: isDirectory,
                                                        isPackage: isPackage))
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .onAppear { load() }
        .onChange(of: url.path) { _, _ in
            requestedPath = nil
            load()
        }
    }

    private func load() {
        let path = url.path
        guard requestedPath != path else { return }
        requestedPath = path
        if let hit = FileItem.cachedIcon(for: url) {
            nsImage = hit
            requestedPath = nil
            return
        }
        FileItem.requestIcon(url: url, isDirectory: isDirectory, isPackage: isPackage) { img in
            guard path == url.path else { return }
            requestedPath = nil
            nsImage = img
        }
    }
}
// MARK: - Tags submenu (shared by list / grouped / icons / columns)
//
// Renders the 7 Finder colors as toggles (a checkmark shows when EVERY targeted
// item already carries that color) plus a "Clear Tags" action. Toggling adds the
// color when absent and removes it when present — exactly like Finder, and with
// multiple colors per file preserved.

struct TagMenuContent: View {
    let targets: [FileItem]
    @ObservedObject var fileOps: FileOperationsService
    let onReload: () -> Void

    private var urls: [URL] { targets.map(\.url) }

    private func applied(_ color: String) -> Bool {
        !targets.isEmpty && targets.allSatisfy { $0.hasColorTag(color) }
    }

    var body: some View {
        ForEach(FileItem.colorMenuOrder, id: \.self) { color in
            Toggle(isOn: Binding(
                get: { applied(color) },
                set: { _ in fileOps.toggleColorTag(color, on: urls, reload: onReload) }
            )) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(FileItem.colorForTagName(color) ?? Color(nsColor: .systemGray))
                        .frame(width: 10, height: 10)
                    Text(color)
                }
            }
        }
        Divider()
        Button { fileOps.clearTags(on: urls, reload: onReload) } label: {
            Label("Clear Tags", systemImage: "xmark.circle")
        }
            .disabled(targets.allSatisfy { $0.tagNames.isEmpty })
    }
}

// MARK: - Sort

enum SortField: String, CaseIterable, Identifiable {
    case name         = "Name"
    case dateModified = "Date Modified"
    case dateCreated  = "Date Created"
    case size         = "Size"
    case kind         = "Kind"
    case ext          = "Extension"
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable {
    case list, icons, columns
    var icon: String {
        switch self {
        case .list:    "list.bullet"
        case .icons:   "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        }
    }
}

func sortedItems(_ items: [FileItem],
                 by field: SortField,
                 ascending: Bool,
                 folderOrder: FolderOrder = .foldersFirst) -> [FileItem] {
    guard items.count >= 2 else { return items }
    // Folder/file particija je izvučena IZ komparatora: pre se na SVAKO
    // poređenje (130k+ za 10k fajlova) proveravao folderOrder + radio
    // localizedCompare. Sada O(n) particija + sort svake grupe posebno —
    // isti stabilan rezultat, daleko manje grananja po poređenju.
    switch folderOrder {
    case .mixed:
        return items.sorted { compareItems($0, $1, by: field, ascending: ascending) }
    case .foldersFirst:
        let folders = items.filter { $0.isBrowsableFolder }
        // Brzi put: folder bez podfoldera ili bez fajlova — jedan sort.
        if folders.isEmpty || folders.count == items.count {
            return items.sorted { compareItems($0, $1, by: field, ascending: ascending) }
        }
        let files = items.filter { !$0.isBrowsableFolder }
        let sf = folders.sorted { compareItems($0, $1, by: field, ascending: ascending) }
        let sfiles = files.sorted { compareItems($0, $1, by: field, ascending: ascending) }
        return sf + sfiles
    case .filesFirst:
        let folders = items.filter { $0.isBrowsableFolder }
        if folders.isEmpty || folders.count == items.count {
            return items.sorted { compareItems($0, $1, by: field, ascending: ascending) }
        }
        let files = items.filter { !$0.isBrowsableFolder }
        let sf = folders.sorted { compareItems($0, $1, by: field, ascending: ascending) }
        let sfiles = files.sorted { compareItems($0, $1, by: field, ascending: ascending) }
        return sfiles + sf
    }
}

private func compareItems(_ a: FileItem, _ b: FileItem,
                          by field: SortField, ascending: Bool) -> Bool {
    // Descending swaps the operands instead of negating: `!r` returns true
    // both ways on ties (equal size/date/…), which violates strict weak
    // ordering and makes descending sorts nondeterministic. Swapping keeps
    // ties false both ways, so the (stable) sort preserves input order.
    ascending ? lessThan(a, b, by: field) : lessThan(b, a, by: field)
}

/// True for sort fields backed by integer/date compares (no
/// `localizedCompare`): sorting even an 8k snapshot costs ~1–2ms, so callers
/// may sort synchronously on main instead of flashing a spinner while a
/// background sort runs. Name/kind/extension pay locale-aware string compares
/// (~70ms for 8k) and belong off-main.
func isCheapSortField(_ field: SortField) -> Bool {
    switch field {
    case .dateModified, .dateCreated, .size:
        return true
    case .name, .kind, .ext:
        return false
    }
}

private func lessThan(_ a: FileItem, _ b: FileItem, by field: SortField) -> Bool {
    switch field {
    case .name:         return a.name.localizedCompare(b.name) == .orderedAscending
    case .dateModified: return a.dateModified < b.dateModified
    case .dateCreated:  return a.dateCreated  < b.dateCreated
    case .size:         return a.effectiveSize < b.effectiveSize
    case .kind:         return a.kind.localizedCompare(b.kind) == .orderedAscending
    case .ext:          return a.fileExtension.localizedCompare(b.fileExtension) == .orderedAscending
    }
}

/// Search hits as one flat list: closest match to `query` first, newest first
/// among equally close matches.
func rankedSearchItems(_ items: [FileItem], query: String) -> [FileItem] {
    FuzzySearch.ranked(items, query: query, name: \.name, date: \.dateModified,
                       fileExtension: \.fileExtension)
}

/// Ranking for pre-filtered hits (Spotlight / tag search): keeps everything,
/// closest match first. Anything the fuzzy scorer can't match goes last.
func rankedPrefilteredItems(_ items: [FileItem], query: String) -> [FileItem] {
    FuzzySearch.rankedKeepingAll(items, query: query, name: \.name, date: \.dateModified)
}

/// Split an already-sorted list into visible section groups.
///
/// Non-reactive memo: grouping runs Calendar/string work per file, and the
/// views that call this re-evaluate their body on every selection change.
/// Same inputs (grouping + list content) return the cached result instead
/// of re-bucketing. One entry per pane (windows/panes show different folders
/// at once), keyed by an order-sensitive content signature — a same-path
/// rename or a swap of two middle items invalidates instead of showing stale
/// groups. NSCache evicts under memory pressure; `countLimit` bounds entries.
private final class GroupBox: NSObject {
    let groups: [FileGroup]
    init(_ groups: [FileGroup]) { self.groups = groups }
}

private final class GroupMemoCache {
    static let shared = GroupMemoCache()
    private let cache: NSCache<NSString, GroupBox> = {
        let c = NSCache<NSString, GroupBox>()
        c.name = "FinderFlow.groupMemoCache"
        c.countLimit = 16
        return c
    }()

    func grouped(_ items: [FileItem], by grouping: GroupBy, ascending: Bool = true) -> [FileGroup] {
        let k = "\(grouping.rawValue)#a\(ascending ? 1 : 0)#\(items.contentSignature)" as NSString
        if let hit = cache.object(forKey: k) { return hit.groups }
        let computed = groupedItemsUncached(items, by: grouping, ascending: ascending)
        cache.setObject(GroupBox(computed), forKey: k)
        return computed
    }

    /// O(1) varijanta: pozivalac prosleđuje `filesIdentity` koji se menja samo
    /// kad se listing zaista promeni (ContentView ga već održava). Klik na
    /// selekciju tada NE hešira ceo folder.
    /// identity == 0 znači "nemam hint" → fallback na contentSignature.
    ///
    /// Ključ sadrži i O(1) diskriminator sadržaja (count + first/middle/last
    /// id): sam brojač nije dovoljan jer isti `files` parametar ume da nosi
    /// search/tag rezultate dok se filesIdentity ne pomeri (stale grupe pri
    /// kucanju), a deljeni keš bi se sudarao i između dva prozora sa istim
    /// brojačem a različitim folderima. Tri tačke su O(1) indeksi — i dalje
    /// bez heširanja celog foldera.
    func grouped(_ items: [FileItem], by grouping: GroupBy, identity: UInt, ascending: Bool = true) -> [FileGroup] {
        guard identity != 0 else { return grouped(items, by: grouping, ascending: ascending) }
        let k = identityKey(for: items, grouping: grouping, identity: identity, ascending: ascending)
        if let hit = cache.object(forKey: k) { return hit.groups }
        let computed = groupedItemsUncached(items, by: grouping, ascending: ascending)
        cache.setObject(GroupBox(computed), forKey: k)
        return computed
    }

    private func identityKey(for items: [FileItem], grouping: GroupBy, identity: UInt, ascending: Bool) -> NSString {
        guard !items.isEmpty else {
            return "\(grouping.rawValue)#a\(ascending ? 1 : 0)#i\(identity)#c0" as NSString
        }
        let mid = items.count / 2
        return ("\(grouping.rawValue)#a\(ascending ? 1 : 0)#i\(identity)#c\(items.count)"
            + "#f\(items[0].id)#m\(items[mid].id)#l\(items[items.count - 1].id)") as NSString
    }
}

func groupedItems(_ items: [FileItem], by grouping: GroupBy, ascending: Bool = true) -> [FileGroup] {
    GroupMemoCache.shared.grouped(items, by: grouping, ascending: ascending)
}

/// O(1) varijanta — za view-ove koji dobijaju filesIdentity od roditelja.
/// Selekcija/sort-indikator se menjaju bez re-heširanja celog foldera.
func groupedItems(_ items: [FileItem], by grouping: GroupBy, identity: UInt, ascending: Bool = true) -> [FileGroup] {
    GroupMemoCache.shared.grouped(items, by: grouping, identity: identity, ascending: ascending)
}

private func groupedItemsUncached(_ items: [FileItem], by grouping: GroupBy, ascending: Bool = true) -> [FileGroup] {
    guard grouping != .none, !items.isEmpty else {
        return items.isEmpty ? [] : [FileGroup(id: "all", title: "", items: items)]
    }

    switch grouping {
    case .none:
        return [FileGroup(id: "all", title: "", items: items)]

    case .dateModified:
        let classifier = DateCategory.Classifier()
        var buckets: [DateCategory: [FileItem]] = [:]
        buckets.reserveCapacity(DateCategory.allCases.count)
        for item in items {
            buckets[classifier.category(of: item.dateModified), default: []].append(item)
        }
        let cats = ascending ? DateCategory.allCases : DateCategory.allCases.reversed()
        return cats.compactMap { cat in
            guard let g = buckets[cat], !g.isEmpty else { return nil }
            return FileGroup(id: "dm-\(cat.rawValue)", title: cat.rawValue, items: g)
        }

    case .dateCreated:
        let classifier = DateCategory.Classifier()
        var buckets: [DateCategory: [FileItem]] = [:]
        buckets.reserveCapacity(DateCategory.allCases.count)
        for item in items {
            buckets[classifier.category(of: item.dateCreated), default: []].append(item)
        }
        let cats = ascending ? DateCategory.allCases : DateCategory.allCases.reversed()
        return cats.compactMap { cat in
            guard let g = buckets[cat], !g.isEmpty else { return nil }
            return FileGroup(id: "dc-\(cat.rawValue)", title: cat.rawValue, items: g)
        }

    case .kind:
        // Preserve encounter order from the sorted list so relative sort holds.
        var order: [String] = []
        var buckets: [String: [FileItem]] = [:]
        for item in items {
            let key = item.kind.isEmpty ? "Unknown" : item.kind
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { FileGroup(id: "kind-\($0)", title: $0, items: buckets[$0] ?? []) }

    case .extension_:
        var order: [String] = []
        var buckets: [String: [FileItem]] = [:]
        for item in items {
            let key: String
            if item.isBrowsableFolder {
                key = "Folders"
            } else if item.fileExtension.isEmpty {
                key = "Other"
            } else {
                key = item.fileExtension.uppercased()
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { FileGroup(id: "ext-\($0)", title: $0, items: buckets[$0] ?? []) }

    case .size:
        // Single pass (was 7× filter over all items).
        var sizeBuckets: [SizeBand: [FileItem]] = [:]
        sizeBuckets.reserveCapacity(SizeBand.allCases.count)
        for item in items {
            sizeBuckets[SizeBand.of(item), default: []].append(item)
        }
        let bands = ascending ? SizeBand.allCases : SizeBand.allCases.reversed()
        return bands.compactMap { band in
            guard let g = sizeBuckets[band], !g.isEmpty else { return nil }
            return FileGroup(id: "sz-\(band.rawValue)", title: band.rawValue, items: g)
        }

    case .nameInitial:
        // Single pass (was 27× filter over all items).
        var nameBuckets: [String: [FileItem]] = [:]
        nameBuckets.reserveCapacity(27)
        for item in items {
            nameBuckets[item.nameGroupKey, default: []].append(item)
        }
        var keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init) + ["#"]
        if !ascending { keys.reverse() }
        return keys.compactMap { key in
            guard let g = nameBuckets[key], !g.isEmpty else { return nil }
            return FileGroup(id: "nm-\(key)", title: key, items: g)
        }
    }
}

func loadItems(at url: URL, showHidden: Bool) -> (items: [FileItem], error: FolderReadError?) {
    let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    // Fast path: reuse the cached URL list so Back/Forth and tab switches
    // skip the directory enumeration entirely. URLs are refetched fresh on a
    // miss; FileItems are always rebuilt so sort/group prefs apply fresh.
    // NOTE: cached URLs replay old attributes — that's why we only cache the
    // URL list and always rebuild FileItem below.
    // Prazan folder je validan keš pogodak (nil = nema keša): pre se `[]`
    // tretirao kao promašaj pa su se prazni folderi čitali sa diska svaki put.
    if let cached = DirectoryCache.shared.cachedURLs(for: url, showHidden: showHidden) {
        let built = buildItems(from: cached)
        DirectoryCache.shared.storeItems(built.items, for: url, showHidden: showHidden)
        // Every entry failed to load (per-file permissions, mid-listing
        // deletion…): report it instead of showing a fake "empty folder".
        if !cached.isEmpty && built.items.isEmpty {
            return ([], .underlying(url, "Couldn't read the contents of “\(url.lastPathComponent)”."))
        }
        return (built.items, nil)
    }
    // The bulk listing prefetches every browse attribute in one pass, so building
    // the items below needs no further disk access. The folder's stamp is read
    // first so a change during the listing still invalidates the cached URLs.
    let stamp = DirectoryCache.Stamp.of(url)
    do {
        let urls = try listDirectoryURLs(at: url, options: opts)
        // Keširaj i prazne foldere da sledeće otvaranje ne ide na disk.
        // Greška se NE kešira: odbijena dozvola danas može biti odobrena sutra.
        guard !urls.isEmpty else {
            DirectoryCache.shared.store([], for: url, showHidden: showHidden, stamp: stamp)
            DirectoryCache.shared.storeItems([], for: url, showHidden: showHidden)
            return ([], nil)
        }
        DirectoryCache.shared.store(urls, for: url, showHidden: showHidden, stamp: stamp)
        let built = buildItems(from: urls)
        DirectoryCache.shared.storeItems(built.items, for: url, showHidden: showHidden)
        if built.items.isEmpty {
            return ([], .underlying(url, "Couldn't read the contents of “\(url.lastPathComponent)”."))
        }
        return (built.items, nil)
    } catch let e as FolderReadError {
        return ([], e)
    } catch {
        return ([], .underlying(url, (error as NSError).localizedDescription))
    }
}

/// Parallel FileItem construction shared by the cached and fresh paths.
/// Reports how many entries failed to load so callers can tell "empty folder"
/// apart from "nothing was readable".
private func buildItems(from urls: [URL]) -> (items: [FileItem], dropped: Int) {
    // Build items in parallel. Writing through the buffer pointer (not the array)
    // keeps the concurrent writes to separate slots free of exclusivity conflicts.
    // Each slot is wrapped in an autoreleasepool so 10k-file folders don't
    // accumulate NSURL/NSDate temporaries until the GCD block drains.
    var slots = [FileItem?](repeating: nil, count: urls.count)
    slots.withUnsafeMutableBufferPointer { buffer in
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            autoreleasepool {
                buffer[i] = FileItem.load(from: urls[i])
            }
        }
    }
    let items = slots.compactMap { $0 }
    return (items, urls.count - items.count)
}

// MARK: - Folder read errors (never silently empty)
//
// Ranije je svako čitanje foldera bilo `try?` → `[]`: uskraćena TCC dozvola
// (Desktop/Documents/Downloads), ugašen Google Drive ili obrisan folder
// prikazivali su se kao "prazan folder" bez ikakvog objašnjenja — klik radi,
// ali "ništa se ne otvori". Sada se greška vraća uz listing i UI je prikazuje.

enum FolderReadError: Error, Equatable {
    /// Folder ne postoji (obrisan, disk nije priključen, Drive nije podešen).
    case notFound(URL)
    /// Sistem brani čitanje: TCC privatnost (Desktop/Documents/Downloads),
    /// File Provider nedostupan (Google Drive), EACCES/EPERM.
    case noPermission(URL)
    /// Sve ostalo — nosi opis za prikaz.
    case underlying(URL, String)

    var url: URL {
        switch self {
        case .notFound(let u), .noPermission(let u), .underlying(let u, _): return u
        }
    }

    var title: String {
        switch self {
        case .notFound:      return "Folder isn't available"
        case .noPermission:  return "No permission to open this folder"
        case .underlying:    return "Couldn't open this folder"
        }
    }

    var message: String {
        switch self {
        case .notFound(let u):
            return "“\(u.lastPathComponent)” doesn't exist or isn't mounted right now."
        case .noPermission(let u):
            return "macOS blocked aiFlow from reading “\(u.lastPathComponent)”."
        case .underlying(_, let d):
            return d
        }
    }

    /// Savet za oporavak prikazan ispod poruke (samo kad ima smisla).
    var recoveryHint: String? {
        switch self {
        case .noPermission:
            return "Allow aiFlow under System Settings → Privacy & Security → Files and Folders, then try again."
        case .notFound:
            return "If it's a cloud drive (Google Drive, OneDrive), make sure sync is signed in and running."
        case .underlying:
            return nil
        }
    }
}

/// Enumeracija sa mapiranim greškama umesto `try?`. Baca `FolderReadError`.
/// Keširanje rade pozivaoci i to SAMO na uspeh — greška se nikad ne kešira.
func listDirectoryURLs(at url: URL,
                       options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
          isDir.boolValue else {
        throw FolderReadError.notFound(url)
    }
    // Brza pre-provera pre enumeracije: za TCC-odbijene foldere vraća false
    // bez izuzetka, pa grešku prijavimo odmah sa jasnim razlogom.
    guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw FolderReadError.noPermission(url)
    }
    do {
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: options
        )
    } catch {
        throw mapFolderReadError(error, url: url)
    }
}

/// Preslikava Cocoa/POSIX greške na FolderReadError.
func mapFolderReadError(_ error: Error, url: URL) -> FolderReadError {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        // Simbolički kodovi (257 = no permission, 260 = no such file) +
        // numerički fallback 4 (NSFileNoSuchFileError) — bez nagađanja imena.
        if ns.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return .noPermission(url)
        }
        if ns.code == CocoaError.Code.fileReadNoSuchFile.rawValue || ns.code == 4 {
            return .notFound(url)
        }
    }
    if ns.domain == NSPOSIXErrorDomain {
        // EACCES/EPERM su Int32 — eksplicitna konverzija radi poređenja sa Int kodom.
        switch ns.code {
        case Int(EACCES), Int(EPERM):
            return .noPermission(url)
        case Int(ENOENT), Int(ENOTDIR):
            return .notFound(url)
        default:
            break
        }
    }
    // File Provider (Google Drive/OneDrive) ume da vrati generičke greške kad
    // sync nije prijavljen — opis ostaje koristan, a hint kaže gde gledati.
    return .underlying(url, ns.localizedDescription)
}

/// Always hits the disk (bypasses the URL cache) and refreshes both caches.
/// Used for background revalidation after an instant cached paint.
func loadFreshItems(at url: URL, showHidden: Bool) -> (items: [FileItem], error: FolderReadError?) {
    guard let refreshKey = DirectoryCache.shared.beginRefresh(for: url, showHidden: showHidden) else {
        // Drugi refresh je već u letu za isti folder. Staro ponašanje je
        // vraćalo (stale) snapshot kao "fresh" — pozivalac bi ga uporedio,
        // video "nema promene" i odbacio, a pravi refresh iz prvog leta bi
        // pao na generation guard → folder zauvek ostane zastareo.
        // Umesto toga odradimo običan neglavni fresh load bez coalescinga:
        // dupli I/O samo u retkom sudaru, ali uvek tačan rezultat.
        return freshLoadItems(at: url, showHidden: showHidden)
    }
    defer { DirectoryCache.shared.endRefresh(refreshKey) }
    return freshLoadItems(at: url, showHidden: showHidden)
}

/// Neglovani disk load + upis u oba keša (pozivaju ga i guarded i bypass put).
/// Greška se vraća pozivaocu i NAMERNO ne upisuje `[]` u keš: odbijena
/// dozvola (TCC) ili nedostupan File Provider danas može proraditi sutra —
/// keširani `[]` bi zauvek prikazivao "prazan folder".
private func freshLoadItems(at url: URL, showHidden: Bool) -> (items: [FileItem], error: FolderReadError?) {
    let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
    let stamp = DirectoryCache.Stamp.of(url)
    do {
        let urls = try listDirectoryURLs(at: url, options: opts)
        DirectoryCache.shared.store(urls, for: url, showHidden: showHidden, stamp: stamp)
        let built = buildItems(from: urls)
        DirectoryCache.shared.storeItems(built.items, for: url, showHidden: showHidden)
        // urls.isEmpty = genuinely empty folder (no error); non-empty urls
        // with zero readable items = report instead of fake-empty.
        if !urls.isEmpty && built.items.isEmpty {
            return ([], .underlying(url, "Couldn't read the contents of “\(url.lastPathComponent)”."))
        }
        return (built.items, nil)
    } catch let e as FolderReadError {
        return ([], e)
    } catch {
        return ([], .underlying(url, (error as NSError).localizedDescription))
    }
}

// MARK: - DriveBadgeRow conformance (bedževi čitaju id/name/ext/url bez FileItem importa u harnessu)
extension FileItem: DriveBadgeRow {}

// MARK: - Kanonska putanja za poređenja navigacije
//
// macOS ima symlinkovane rootove (/tmp → /private/tmp, isto /var i /etc):
// sirovo `urlA == urlB` vidi dva oblika istog foldera kao različite, pa
// PathBar/Columns/Sidebar/ContentView upadnu u lažnu navigaciju, dupli
// history ili izgubljenu selekciju. `standardizedFileURL` NE razrešava
// symlinkove (samo leksički ../), zato ovde ide resolvingSymlinksInPath.
// Zovi samo na navigacionim događajima (retko), nikad po redu liste.
func ffCanonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

func ffSamePath(_ a: URL, _ b: URL) -> Bool {
    ffCanonicalPath(a) == ffCanonicalPath(b)
}

func ffIsAncestor(path: URL, of url: URL) -> Bool {
    let p = ffCanonicalPath(path)
    let u = ffCanonicalPath(url)
    return u == p || u.hasPrefix(p + "/")
}
