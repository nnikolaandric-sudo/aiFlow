import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// Shared helpers so List / Icons / Columns can drag real files out to Finder,
/// Desktop, upload dialogs, browsers, Mail compose (attach via drop), and
/// other apps — the same pasteboard contract macOS uses for Finder → Finder
/// file drags and Finder → Mail attaches.
enum FileDragSupport {

    /// Build an `NSItemProvider` that carries one or more existing file URLs.
    /// Upload panels / Finder / Mail compose accept this for both single and
    /// multi-file drops. Usage: drag out of FinderFlow, drop into Mail compose
    /// to attach (single or multiple files).
    static func provider(for urls: [URL]) -> NSItemProvider {
        let unique = Self.dedupe(urls)
        guard !unique.isEmpty else { return NSItemProvider() }

        if unique.count == 1, let single = NSItemProvider(contentsOf: unique[0]) {
            // Single file: `contentsOf:` vends public.file-url + filename —
            // Mail compose attaches it on drop, same as Finder → Mail.
            single.suggestedName = unique[0].lastPathComponent
            return single
        }

        // Multi-file: advertise the classic filename-list type Finder / Mail /
        // browsers and upload panels understand, plus a primary file-URL for
        // the first item. Mail reads NSFilenamesPboardType and attaches ALL
        // listed paths (verified Finder → Mail contract), not just the first.
        let provider = NSItemProvider(object: unique[0] as NSURL)
        provider.suggestedName = unique[0].lastPathComponent
        provider.registerDataRepresentation(
            forTypeIdentifier: "NSFilenamesPboardType",
            visibility: .all
        ) { completion in
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: unique.map(\.path),
                    format: .xml,
                    options: 0
                )
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        return provider
    }

    /// One provider per URL (proper multi-item drag). Use with SwiftUI
    /// `.draggable(...)` / Transferable on macOS 13+ where an array of
    /// providers is supported. Kept alongside `provider(for:)` (single
    /// provider + NSFilenamesPboardType) for `onDrag` call sites.
    static func providers(for urls: [URL]) -> [NSItemProvider] {
        Self.dedupe(urls).map { url in
            if let p = NSItemProvider(contentsOf: url) {
                p.suggestedName = url.lastPathComponent
                return p
            }
            let p = NSItemProvider(object: url as NSURL)
            p.suggestedName = url.lastPathComponent
            return p
        }
    }

    /// Resolve which URLs should ride along with a drag that starts on `item`.
    /// If the clicked item is part of the current selection, drag the whole
    /// selection; otherwise just that one item (Finder behaviour).
    static func urlsForDrag(item: FileItem, files: [FileItem], selectedIDs: Set<String>) -> [URL] {
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            return files.filter { selectedIDs.contains($0.id) }.map(\.url)
        }
        return [item.url]
    }

    private static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for u in urls {
            let key = u.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }
}

// MARK: - SwiftUI convenience

extension View {
    /// Attach Finder-style file drag-out to any row / icon / cell.
    /// Drop target can be Finder, Desktop, an upload dialog, a browser,
    /// or Mail compose (drop = attach). Hint for users: drag → drop into
    /// the Mail message body to attach.
    ///
    /// When `count` > 1, a count badge ("×N") is overlaid on the dragged
    /// view while the drag session is active (Finder-style multi-drag hint).
    func fileDragOut(item: FileItem, files: [FileItem], selectedIDs: Set<String>) -> some View {
        let urls = FileDragSupport.urlsForDrag(item: item, files: files, selectedIDs: selectedIDs)
        return fileDragOutURLs(urls)
    }

    /// Lower-level: attach a drag source for an explicit URL list (sidebar,
    /// breadcrumbs, etc.). Overlays a "×N" count badge when count > 1.
    func fileDragOutURLs(_ urls: [URL]) -> some View {
        overlay(alignment: .topTrailing) {
            if urls.count > 1 {
                Text("\(urls.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .offset(x: 8, y: -6)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onDrag {
            FileDragSupport.provider(for: urls)
        } preview: {
            DragPreviewView(urls: urls)
        }
    }
}

/// Finder-style drag ghost: stacked file icons + count badge when multi-drag.
private struct DragPreviewView: View {
    let urls: [URL]

    var body: some View {
        if urls.count == 1, let item = FileItem.load(from: urls[0]) {
            FileIconView(item: item, size: 48)
                .frame(width: 48, height: 48)
        } else {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.regularMaterial)
                    .frame(width: 48, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                if urls.count > 1 {
                    Text("\(urls.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 8, y: -4)
                }
            }
            .frame(width: 48, height: 48)
        }
    }
}
