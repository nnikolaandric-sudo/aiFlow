import SwiftUI
import AppKit

// MARK: - SelectionActionBar (akcije za selektovanu datoteku)
//
// Dva rezima: sticky full-bleed header pod toolbarom (floating: false,
// legacy) i plutajuca pilula na dnu sadrzaja (floating: true) koja ne
// pomera listu kad se pojavi/nestane. Samo akcije kojima TREBA selekcija
// (Open, Quick Look, Rename, Share…). Paste / Copy Path / Trash se ne
// dupliraju — zive u glavnom toolbaru (jedna akcija, jedno mesto).

struct SelectionActionBar: View {
    let selectedItems: [FileItem]
    let currentPath: URL
    @ObservedObject var fileOps: FileOperationsService
    @ObservedObject var favorites: FavoritesService
    var onNavigate: (FileItem) -> Void = { _ in }
    var onBrowseInto: (URL) -> Void = { _ in }
    var onRename: (FileItem) -> Void = { _ in }
    var onBatchRename: (([FileItem]) -> Void)? = nil
    var onSendToDiscord: (([FileItem]) -> Void)? = nil
    var onReload: () -> Void = {}
    /// Dugme ✕ na desnom kraju trake — uklanja celu selekciju.
    var onClear: (() -> Void)? = nil
    /// Plutajuca pilula na dnu (overlay, ne pomera listu) umesto
    /// full-bleed sticky headera pod toolbarom.
    var floating = false

    private var urls: [URL] { selectedItems.map(\.url) }
    private var signableURLs: [URL] { urls.filter(ESignSource.canSign) }
    private var single: FileItem? { selectedItems.count == 1 ? selectedItems[0] : nil }
    private var isSingleArchive: Bool { single?.isArchive == true }

    var body: some View {
        if selectedItems.isEmpty {
            EmptyView()
        } else {
            barContent
        }
    }

    private var barContent: some View {
        // ViewThatFits: at the 860pt minimum (sidebar + preview open) the full
        // ~18-control row clipped; the compact variant keeps the essentials
        // and moves the rest into one overflow menu.
        Group {
            if floating {
                barControls
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: FFTheme.floatingShape)
                    .overlay(
                        FFTheme.floatingShape
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            } else {
                barControls
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Sticky header chrome: full-bleed strip welded under the toolbar —
                    // bar material + faint accent wash ("selection mode" is on) + hairline
                    // bottom edge. No floating card, no shadow, no side inset.
                    .background {
                        Rectangle()
                            .fill(.bar)
                            .overlay {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.07))
                            }
                            .overlay(alignment: .bottom) { Divider() }
                    }
            }
        }
    }

    private var barControls: some View {
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
    }

    private var fullBar: some View {
        HStack(spacing: 6) {
            // Ime selekcije
            selectionLabel

            Divider().frame(height: 18).opacity(0.4)

            // ── Open ──
            ToolbarActionButton(icon: "arrow.up.forward.app", label: openHelp) {
                if let s = single { onNavigate(s) }
                else if let s = selectedItems.first { onNavigate(s) }
            }

            Menu {
                OpenWithMenuContent(urls: urls)
            } label: {
                Image(systemName: "app.badge")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Open With — default app, recommended, Terminal / VS Code / Cursor / Claude / Codex")

            ToolbarActionButton(icon: "eye", label: "Quick Look (Space)") {
                QuickLookController.shared.show(urls)
            }
            ToolbarActionButton(icon: "info.circle", label: "Get Info (⌘I)") {
                showGetInfoInFinder(urls)
            }
            // E-Sign (isto kao desni klik): PDF, slike, Word/RTF.
            if !signableURLs.isEmpty {
                ToolbarActionButton(icon: "signature",
                                    label: ESignWindowManager.signTitle(for: signableURLs, ofTotal: urls.count)) {
                    ESignWindowManager.shared.open(signableURLs)
                }
            }

            Divider().frame(height: 18).opacity(0.4)

            // ── Cut / Copy (Paste živi u glavnom toolbaru) ──
            ToolbarActionButton(icon: "scissors", label: "Cut (⌘X)") {
                fileOps.cut(urls)
            }
            ToolbarActionButton(icon: "doc.on.doc", label: "Copy (⌘C)") {
                fileOps.copy(urls)
            }

            ToolbarActionButton(icon: "plus.square.on.square", label: "Duplicate (⌘D)") {
                fileOps.duplicate(urls, reload: onReload)
            }
            ToolbarActionButton(icon: "pencil", label: "Rename…") {
                if let s = single { onRename(s) }
                else if let onBatchRename { onBatchRename(selectedItems) }
            }

            Divider().frame(height: 18).opacity(0.4)

            // ── Compress: 1 click = .zip (the common case), chevron for .tar.gz ──
            HStack(spacing: 0) {
                ToolbarActionButton(icon: "archivebox", label: compressHelp) {
                    fileOps.compress(urls, reload: onReload)
                }
                Menu {
                    Button("Compress as .zip") { fileOps.compress(urls, reload: onReload) }
                    Button("Compress as .tar.gz") { fileOps.compress(urls, as: .tarGz, reload: onReload) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("More archive formats")
            }

            ToolbarActionButton(icon: "tray.and.arrow.down.fill", label: "Extract Here") {
                if let s = single { fileOps.extract(s.url, reload: onReload) }
            }
            .disabled(!isSingleArchive)

            Divider().frame(height: 18).opacity(0.4)

            // ── Share (Trash živi u glavnom toolbaru) ──
            ToolbarActionButton(icon: "link", label: "Quick Link (24h) — create & copy link, no dialog") {
                Task { await SecureShareManager.shared.quickLink(for: urls) }
            }
            .disabled(!SecureShareManager.canQuickLink(urls))
            Menu {
                Button("Quick Link — Copy 24h Link") { Task { await SecureShareManager.shared.quickLink(for: urls) } }
                    .disabled(!SecureShareManager.canQuickLink(urls))
                Divider()
                Button("AirDrop") { fileOps.shareViaAirDrop(urls) }
                Button("Send via Mail") { fileOps.shareViaMail(urls) }
                Divider()
                Button(SecureShareManager.shareMenuTitle(for: urls)) { SecureShareWindowManager.shared.open(urls: urls) }
                    .disabled(!SecureShareManager.canQuickLink(urls))
                Button("Share…") { fileOps.showShareSheet(for: urls) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Share")

            // 1-klik Mail attach — bez otvaranja menija. Shortcut: ⇧⌘M.
            ToolbarActionButton(icon: "envelope.fill", label: "Send via Mail (⇧⌘M)") {
                fileOps.shareViaMail(urls)
            }

            if onSendToDiscord != nil {
                ToolbarActionButton(icon: "paperplane", label: "Send to Discord…", tint: FFTheme.discord) {
                    onSendToDiscord?(selectedItems)
                }
            }

            Spacer(minLength: 12)

            if let onClear {
                Divider().frame(height: 18).opacity(0.4)
                ToolbarActionButton(icon: "xmark", label: "Clear Selection (Esc)") { onClear() }
            }
        }
    }

    /// Narrow-window fallback: essentials inline, the rest behind ⋯.
    private var compactBar: some View {
        HStack(spacing: 6) {
            selectionLabel

            Divider().frame(height: 18).opacity(0.4)

            ToolbarActionButton(icon: "arrow.up.forward.app", label: openHelp) {
                if let s = single { onNavigate(s) }
                else if let s = selectedItems.first { onNavigate(s) }
            }
            ToolbarActionButton(icon: "eye", label: "Quick Look (Space)") {
                QuickLookController.shared.show(urls)
            }
            ToolbarActionButton(icon: "scissors", label: "Cut (⌘X)") { fileOps.cut(urls) }
            ToolbarActionButton(icon: "doc.on.doc", label: "Copy (⌘C)") { fileOps.copy(urls) }
            ToolbarActionButton(icon: "pencil", label: "Rename…") {
                if let s = single { onRename(s) }
                else if let onBatchRename { onBatchRename(selectedItems) }
            }

            Menu {
                overflowMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("More actions")

            Spacer(minLength: 12)

            if let onClear {
                Divider().frame(height: 18).opacity(0.4)
                ToolbarActionButton(icon: "xmark", label: "Clear Selection (Esc)") { onClear() }
            }
        }
    }

    private var overflowMenuContent: some View {
        Group {
            Menu {
                OpenWithMenuContent(urls: urls)
            } label: { Text("Open With") }

            Button("Get Info (⌘I)") { showGetInfoInFinder(urls) }
            if !signableURLs.isEmpty {
                Button(ESignWindowManager.signTitle(for: signableURLs, ofTotal: urls.count)) {
                    ESignWindowManager.shared.open(signableURLs)
                }
            }
            let pdfURLs = urls.filter(ESignSource.isPDF)
            if !pdfURLs.isEmpty {
                Button(pdfsButtonTitle) { ESignVerification.present(for: pdfURLs) }
            }
            Divider()
            Button("Duplicate (⌘D)") { fileOps.duplicate(urls, reload: onReload) }
            Button("Compress as .zip") { fileOps.compress(urls, reload: onReload) }
            Button("Compress as .tar.gz") { fileOps.compress(urls, as: .tarGz, reload: onReload) }
            Button("Extract Here") {
                if let s = single { fileOps.extract(s.url, reload: onReload) }
            }
            .disabled(!isSingleArchive)
            Divider()
            Button("Quick Link (24h) — copy immediately") { Task { await SecureShareManager.shared.quickLink(for: urls) } }
                .disabled(!SecureShareManager.canQuickLink(urls))
            Menu("Share") {
                Button("Quick Link — Copy 24h Link") { Task { await SecureShareManager.shared.quickLink(for: urls) } }
                    .disabled(!SecureShareManager.canQuickLink(urls))
                Divider()
                Button("AirDrop") { fileOps.shareViaAirDrop(urls) }
                Button("Send via Mail") { fileOps.shareViaMail(urls) }
                Button(SecureShareManager.shareMenuTitle(for: urls)) { SecureShareWindowManager.shared.open(urls: urls) }
                    .disabled(!SecureShareManager.canQuickLink(urls))
                Button("Share…") { fileOps.showShareSheet(for: urls) }
            }
            if onSendToDiscord != nil {
                Button("Send to Discord…") { onSendToDiscord?(selectedItems) }
            }
            Button("Copy Path (⌥⌘C)") {
                fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
            }
        }
    }

    private var selectionLabel: some View {
        HStack(spacing: 8) {
            if let s = single {
                FileIconView(item: s, size: 16)
                    .frame(width: 20, height: 20)
                // Name + kind/size at a glance — saves a Get Info click.
                HStack(spacing: 5) {
                    Text(s.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(singleDetailText(for: s))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 320, alignment: .leading)
                .layoutPriority(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(FFTheme.controlShape.fill(Color.primary.opacity(0.06)))
                if s.isArchive {
                    Text(ArchiveService.displayName(for: s.url))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .ffBadge()
                        .lineLimit(1)
                }
            } else {
                Text("\(selectedItems.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                Text("selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .help(selectionHelp)
    }

    // MARK: - Help tekstovi

    /// "· Kind · size" — the size part is dropped while unknown so the
    /// label never ends on a dangling "· —" (unsized folders).
    private func singleDetailText(for s: FileItem) -> String {
        let size = s.displaySize(sizingActive: false)
        if size == "—" || size == "…" { return "· \(s.kind)" }
        return "· \(s.kind) · \(size)"
    }

    private var openHelp: String {
        if let s = single {
            return s.isBrowsableFolder ? "Open folder" : "Open \"\(s.name)\""
        }
        return "Open selected items"
    }

    private var compressHelp: String {
        if let s = single { return "Compress \"\(s.name)\" (.zip / .tar.gz)" }
        return "Compress \(selectedItems.count) items (.zip / .tar.gz)"
    }

    private var pdfsButtonTitle: String {
        let n = urls.filter(ESignSource.isPDF).count
        return n == 1 ? "Verify Signature" : "Verify \(n) Signatures"
    }

    private var selectionHelp: String {
        selectedItems.count == 1
            ? (selectedItems[0].url.path)
            : "\(selectedItems.count) items selected — actions above apply to all"
    }
}
