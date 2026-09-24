import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag & drop INTO FinderFlow (companion to FileDragSupport.swift)
//
// Files dragged from Finder, the Desktop, browsers, or other apps can be
// dropped onto folders, the list background, the sidebar, path breadcrumbs
// and the column panes. Semantics mirror Finder exactly:
//   • same volume           → move (Option held → copy)
//   • different volume      → copy (no way to force-move across volumes)
//   • internal drag         → same rule as Finder, based on volume
// Packages (.app etc.) behave like single files, never like folders.
//
// Finder advertises drops as UTType.fileURL items; legacy
// "NSFilenamesPboardType" plists and "public.file-url" strings are honored
// too so drops from older apps keep working.

enum FileDropSupport {

    /// Extract file URLs from a drop. Async because NSItemProvider loads off
    /// the caller's thread. Calls `completion` on the main queue with deduped
    /// file URLs.
    static func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else { completion([]); return }
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()

        func append(_ urls: [URL]) {
            guard !urls.isEmpty else { return }
            lock.lock()
            collected.append(contentsOf: urls)
            lock.unlock()
        }

        for provider in providers {
            // 1. Modern file URL: UTType.fileURL content.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL, url.isFileURL { append([url]) }
                }
                continue
            }
            // 2. Legacy filename list: plist-encoded [String] paths.
            if provider.hasItemConformingToTypeIdentifier("NSFilenamesPboardType") {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType") { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
                    else { return }
                    append(paths.map { URL(fileURLWithPath: $0) })
                }
                continue
            }
            // 3. public.file-url as UTF-8 string.
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    defer { group.leave() }
                    guard let data,
                          let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let url = URL(string: s), url.isFileURL else { return }
                    append([url])
                }
                continue
            }
            // 4. Fallback: ask for a file URL anyway (some apps only advertise
            //    a parent type with an attached file URL).
            if provider.registeredTypeIdentifiers.contains(where: {
                UTType($0)?.conforms(to: .fileURL) == true
            }) {
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL, url.isFileURL { append([url]) }
                }
                continue
            }
            // 5. Plain-text path: some apps (browsers, text editors) only
            //    advertise public.plain-text containing a file:// URL or path.
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    defer { group.leave() }
                    guard let s = item as? String else { return }
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: trimmed), url.isFileURL {
                        append([url])
                    } else if FileManager.default.fileExists(atPath: (trimmed as NSString).expandingTildeInPath) {
                        append([URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)])
                    }
                }
            }
        }

        group.notify(queue: .main) {
            var seen = Set<String>()
            let unique = collected.filter { $0.isFileURL && seen.insert($0.path).inserted }
            completion(unique)
        }
    }

    /// True if at least one provider looks like it carries files. Used to pick
    /// the drop operation (copy vs forbidden) before loading any data.
    /// Also accepts plain-text payloads (some apps only advertise text with
    /// a file path inside).
    static func carriesFiles(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { p in
            p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || p.hasItemConformingToTypeIdentifier("NSFilenamesPboardType")
                || p.hasItemConformingToTypeIdentifier("public.file-url")
                || p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                || p.registeredTypeIdentifiers.contains(where: {
                    UTType($0)?.conforms(to: .fileURL) == true
                })
        }
    }

    /// Finder rule for the *default* action (before Option):
    /// same volume → move, different volume → copy. On any failure defaults
    /// to copy, which is always safe.
    static func defaultShouldMove(sources: [URL], destination: URL) -> Bool {
        guard let destVol = try? destination.resourceValues(forKeys: [.volumeURLKey]).volume else {
            return false
        }
        return sources.allSatisfy { src in
            (try? src.resourceValues(forKeys: [.volumeURLKey]).volume) == destVol
        }
    }

    /// The live action for the current modifier state. Reads `.option` at call
    /// time so holding/releasing Option mid-drag flips the indicator.
    static func shouldMove(sources: [URL], destination: URL) -> Bool {
        if NSEvent.modifierFlags.contains(.option) { return false }   // force copy
        return defaultShouldMove(sources: sources, destination: destination)
    }

    /// Best-effort cursor feedback during a drag hover: pointing hand over a
    /// valid target, arrow when leaving. Plain `set()` (no push/pop stack),
    /// so an unpaired call can never wedge the cursor.
    static func hoverCursor(valid: Bool) {
        (valid ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// True when the drop would create a loop (folder into its own descendant)
    /// or when the destination is not writable. Used for `.forbidden` proposals.
    static func isForbidden(sources: [URL], destination: URL) -> Bool {
        let destPath = destination.resolvingSymlinksInPath().path
        // Folder into itself or its own descendant → infinite recursion.
        for src in sources where src.hasDirectoryPath {
            if destPath == src.resolvingSymlinksInPath().path ||
               destPath.hasPrefix(src.resolvingSymlinksInPath().path + "/") {
                return true
            }
        }
        // Read-only volume / no write permission.
        if !FileManager.default.isWritableFile(atPath: destPath) { return true }
        return false
    }
}

// MARK: - Drop state (one per folder target, held in @StateObject)

/// Validates + performs a file drop onto `destination` (a folder).
/// `isTargeted` drives the blue highlight; `dropIsCopy` tracks copy vs move
/// so the target can show a "+" (copy) or "→" (move) indicator.
///
/// A reference type held in `@StateObject` so the instance — and its resolved
/// source URLs — survive view re-renders mid-drag. `destination`/`onReload`
/// are plain vars re-synced every render via `retarget` (never stale, never
/// publishing during `body`).
final class FolderDropState: ObservableObject, DropDelegate {
    @Published var isTargeted = false
    @Published var dropIsCopy = false

    var destination: URL
    var fileOps: FileOperationsService
    var onReload: () -> Void

    /// Sources resolved on hover, reused when the drop lands (no second load).
    private var resolvedSources: [URL] = []
    private var generation = 0

    init(destination: URL, fileOps: FileOperationsService, onReload: @escaping () -> Void) {
        self.destination = destination
        self.fileOps = fileOps
        self.onReload = onReload
    }

    /// Re-point at a new destination each render (navigation changes it while
    /// the view identity — and this object — stays alive).
    func retarget(destination: URL, fileOps: FileOperationsService, onReload: @escaping () -> Void) {
        self.destination = destination
        self.fileOps = fileOps
        self.onReload = onReload
    }

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) {
        generation &+= 1
        let gen = generation
        isTargeted = true
        resolvedSources = []
        dropIsCopy = NSEvent.modifierFlags.contains(.option)
        FileDropSupport.hoverCursor(valid: true)
        // Refine copy-vs-move once real URLs resolve (volume check).
        let dest = destination
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard gen == self.generation, !urls.isEmpty else { return }
            self.resolvedSources = urls
            self.dropIsCopy = !FileDropSupport.shouldMove(sources: urls, destination: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Forbidden: folder into itself / not writable.
        if !resolvedSources.isEmpty &&
           FileDropSupport.isForbidden(sources: resolvedSources, destination: destination) {
            return DropProposal(operation: .forbidden)
        }
        // Refresh the live indicator as Option is pressed/released mid-drag.
        let copy: Bool
        if resolvedSources.isEmpty {
            copy = NSEvent.modifierFlags.contains(.option)
        } else {
            copy = !FileDropSupport.shouldMove(sources: resolvedSources, destination: destination)
        }
        dropIsCopy = copy
        return DropProposal(operation: copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        generation &+= 1
        resolvedSources = []
        isTargeted = false
        FileDropSupport.hoverCursor(valid: false)
    }

    func performDrop(info: DropInfo) -> Bool {
        generation &+= 1
        isTargeted = false
        FileDropSupport.hoverCursor(valid: false)
        let dest = destination
        let ops = fileOps
        let reload = onReload
        // Modifiers are read live at drop time, so an Option pressed at the
        // last moment still forces a copy.
        if !resolvedSources.isEmpty {
            let sources = resolvedSources
            resolvedSources = []
            ops.importURLs(sources, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: sources, destination: dest),
                           reload: reload)
            return true
        }
        resolvedSources = []
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
        }
        return true
    }
}

// MARK: - Folder row wrapper (drop onto a folder, spring-open on hover)

/// Wraps a folder row/cell/breadcrumb so files can be dropped onto it.
/// Non-folders pass through untouched (the background catcher below accepts).
/// `onSpringOpen` fires after 0.8 s of hover (Finder spring-loaded folders).
struct FolderDropRow<Content: View>: View {
    let item: FileItem
    let fileOps: FileOperationsService
    let onReload: () -> Void
    var onSpringOpen: ((FileItem) -> Void)? = nil
    let content: () -> Content

    // NOTE: no @StateObject here. Every folder row used to own a
    // FolderDropState, meaning a 500-folder listing created 500 observable
    // objects on every render — the profiled cost behind sluggish clicking.
    // The drop delegate is now a cheap value created only while a drag
    // hovers (see RowDropDelegate below); idle rows add zero objects.
    @State private var springWork: DispatchWorkItem?
    @State private var isTargeted = false
    @State private var dropIsCopy = false
    @State private var dropIsForbidden = false
    /// Izvori razreseni na hover (za tacan copy/move indikator pre sletanja).
    @State private var dropSources: [URL] = []

    var body: some View {
        if item.isBrowsableFolder {
            DropHighlight(isTargeted: isTargeted, isCopy: dropIsCopy,
                          isForbidden: dropIsForbidden, content: content)
                .onDrop(of: [.fileURL, .text],
                        delegate: RowDropDelegate(destination: item.url,
                                                  fileOps: fileOps,
                                                  onReload: onReload,
                                                  isTargeted: $isTargeted,
                                                  dropIsCopy: $dropIsCopy,
                                                  dropIsForbidden: $dropIsForbidden,
                                                  sources: $dropSources))
                .onChange(of: isTargeted) { _, targeted in
                    springWork?.cancel()
                    springWork = nil
                    if targeted, let spring = onSpringOpen {
                        let work = DispatchWorkItem { spring(item) }
                        springWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                    }
                }
        } else {
            content()
        }
    }
}

// MARK: - Lightweight per-row delegate (struct, zero cost when idle)

// Unlike FolderDropState (a @StateObject kept alive by background catchers),
// this is a plain struct SwiftUI only instantiates while a drag session is
// active — hovering rows costs nothing, so big folders stay snappy.
private struct RowDropDelegate: DropDelegate {
    let destination: URL
    let fileOps: FileOperationsService
    let onReload: () -> Void
    @Binding var isTargeted: Bool
    @Binding var dropIsCopy: Bool
    @Binding var dropIsForbidden: Bool
    /// Razreseni izvori sa hovera (prazno dok se ne razrese ili posle izlaza).
    @Binding var sources: [URL]

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        sources = []
        dropIsCopy = NSEvent.modifierFlags.contains(.option)
        dropIsForbidden = false
        FileDropSupport.hoverCursor(valid: true)
        // Refine copy-vs-move once real URLs resolve (volume check).
        let dest = destination
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { return }
            // Kasna kompletacija napustenog hovera je bezopasna: pise state
            // reda koji vise nije ciljan pa se nikad ne cita.
            sources = urls
            dropIsForbidden = FileDropSupport.isForbidden(sources: urls, destination: dest)
            dropIsCopy = !FileDropSupport.shouldMove(sources: urls, destination: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !sources.isEmpty && FileDropSupport.isForbidden(sources: sources, destination: destination) {
            dropIsForbidden = true
            return DropProposal(operation: .forbidden)
        }
        dropIsForbidden = false
        // Sa razresenim izvorima vazi volume pravilo (isti volumen -> move),
        // inace samo Option — kao FolderDropState za pozadinu.
        let copy: Bool
        if sources.isEmpty {
            copy = NSEvent.modifierFlags.contains(.option)
        } else {
            copy = !FileDropSupport.shouldMove(sources: sources, destination: destination)
        }
        dropIsCopy = copy
        return DropProposal(operation: copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dropIsForbidden = false
        sources = []
        FileDropSupport.hoverCursor(valid: false)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        dropIsForbidden = false
        FileDropSupport.hoverCursor(valid: false)
        let dest = destination
        let ops = fileOps
        let reload = onReload
        // Hover-izvori se recikliraju (bez drugog ucitavanja); inace se ucita.
        if !sources.isEmpty {
            let urls = sources
            sources = []
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
            return true
        }
        sources = []
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
        }
        return true
    }
}

// MARK: - Background catcher (drop anywhere → current folder)

/// Full-area drop catcher: drops anywhere on `content` land in `destination`.
/// Shows a subtle inset ring + a floating "Copy/Move to X" pill while targeted.
struct DropCatcher<Content: View>: View {
    let destination: URL
    let folderName: String
    let fileOps: FileOperationsService
    let onReload: () -> Void
    let content: () -> Content

    @StateObject private var drop: FolderDropState

    init(destination: URL,
         folderName: String,
         fileOps: FileOperationsService,
         onReload: @escaping () -> Void,
         content: @escaping () -> Content) {
        self.destination = destination
        self.folderName = folderName
        self.fileOps = fileOps
        self.onReload = onReload
        self.content = content
        _drop = StateObject(wrappedValue: FolderDropState(destination: destination,
                                                           fileOps: fileOps,
                                                           onReload: onReload))
    }

    var body: some View {
        drop.retarget(destination: destination, fileOps: fileOps, onReload: onReload)
        return content()
            .overlay {
                if drop.isTargeted {
                    FFTheme.cardShape
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(FFTheme.cardShape
                            .fill(Color.accentColor.opacity(0.06)))
                        .padding(4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if drop.isTargeted {
                    DropActionPill(isCopy: drop.dropIsCopy, folderName: folderName)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: drop.isTargeted)
            .onDrop(of: [.fileURL, .text], delegate: drop)
    }
}

// MARK: - Drop highlight (Finder-style blue ring + action badge)

/// Blue rounded-rectangle hover ring Finder shows on a valid drop target,
/// plus a small "+" (copy) / "→" (move) / "×" (forbidden) badge.
struct DropHighlight<Content: View>: View {
    let isTargeted: Bool
    let isCopy: Bool
    /// Optional: when true, shows a red × badge instead of + / →.
    var isForbidden: Bool = false
    let content: () -> Content

    var body: some View {
        content()
            .overlay(
                FFTheme.controlShape
                    .strokeBorder(isForbidden ? Color.red : Color.accentColor,
                                  lineWidth: isTargeted ? 2 : 0)
                    .background(
                        FFTheme.controlShape
                            .fill((isForbidden ? Color.red : Color.accentColor)
                                  .opacity(isTargeted ? 0.12 : 0))
                    )
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) {
                if isTargeted {
                    Image(systemName: isForbidden
                          ? "xmark.circle.fill"
                          : (isCopy ? "plus.circle.fill" : "arrow.right.circle.fill"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white, isForbidden ? Color.red : Color.accentColor)
                        .offset(x: 6, y: -6)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

/// Floating "Copy to X" / "Move to X" pill for background drops.
struct DropActionPill: View {
    let isCopy: Bool
    let folderName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isCopy ? "plus.circle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(isCopy ? "Copy to “\(folderName)”" : "Move to “\(folderName)”")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .allowsHitTesting(false)
    }
}
