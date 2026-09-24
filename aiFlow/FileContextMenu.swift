import SwiftUI
import AppKit

// MARK: - Open With submenu (shared: desni klik + gornja traka)
//
// Sistemski default + recommended apps + Terminal/IDE specijali + Other...

struct OpenWithMenuContent: View {
    let urls: [URL]
    /// Default + recommended ucitani VAN rendera: `urlForApplication` /
    /// `urlsForApplications` su NSWorkspace IPC i znali su da stucaju
    /// otvaranje menija na 100ms+. Meni se otvori odmah (Other… + IDE),
    /// aplikacije upadnu cim stignu.
    @State private var defEntry: (url: URL, name: String)?
    @State private var recEntries: [(url: URL, name: String)] = []
    @State private var loadedKey = ""

    var body: some View {
        Group {
            // Warm the IDE-availability cache off the render path so the first
            // menu open doesn't pay NSWorkspace IPC synchronously.
            OpenWithCacheWarmer(urls: urls)
            if urls.isEmpty {
                Text("No file selected")
            } else if urls.count == 1, let url = urls.first {
                singleFileContent(url: url)
            } else {
                multiFileContent(urls: urls)
            }
        }
        .onAppear { loadApps() }
        .onChange(of: urls) { _, _ in loadApps() }
    }

    @ViewBuilder
    private func singleFileContent(url: URL) -> some View {
        // Default app (stize asinhrono)
        if let def = defEntry {
            Button("Open with \(def.name) (Default)") {
                OpenWithService.open([url], with: def.url)
            }
            Divider()
        }
        // Recommended (bez default duplikata — pre se default pojavljivao 2×)
        if !recEntries.isEmpty {
            ForEach(recEntries, id: \.url) { app in
                Button("Open with \(app.name)") {
                    OpenWithService.open([url], with: app.url)
                }
            }
            Divider()
        }
        // Terminal + IDE (kesirano, jeftino — smije sinhrono)
        Button { OpenWithService.openInTerminal(url) } label: {
            Label("Open in Terminal", systemImage: "terminal")
        }
        if OpenWithService.isVSCodeInstalled() {
            Button("Open in VS Code") { OpenWithService.openInVSCode(url) }
        }
        if OpenWithService.isCursorInstalled() {
            Button("Open in Cursor") { OpenWithService.openInCursor(url) }
        }
        if OpenWithService.isClaudeInstalled() {
            Button("Open in Claude Code (Terminal)") { OpenWithService.openInClaudeCode(url) }
        }
        if OpenWithService.isCodexInstalled() {
            Button("Open in Codex") { OpenWithService.openInCodex(url) }
        }
        Divider()
        Button { OpenWithService.openWithOther([url]) } label: {
            Label("Other…", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func multiFileContent(urls: [URL]) -> some View {
        if let def = defEntry {
            Button("Open \(urls.count) items with \(def.name)") {
                OpenWithService.open(urls, with: def.url)
            }
            Divider()
        }
        Button { for url in urls { OpenWithService.openInTerminal(url) } } label: {
            Label("Open in Terminal", systemImage: "terminal")
        }
        if OpenWithService.isVSCodeInstalled() {
            Button("Open \(urls.count) items in VS Code") {
                for url in urls { OpenWithService.openInVSCode(url) }
            }
        }
        Divider()
        Button { OpenWithService.openWithOther(urls) } label: {
            Label("Other…", systemImage: "ellipsis.circle")
        }
    }

    private func loadApps() {
        let key = urls.map(\.path).joined(separator: "\n")
        guard key != loadedKey else { return }
        loadedKey = key
        defEntry = nil
        recEntries = []
        let list = urls
        let single = list.count == 1
        DispatchQueue.global(qos: .userInitiated).async {
            var d: (URL, String)? = nil
            if let first = list.first,
               let defURL = OpenWithService.defaultApp(for: first) {
                d = (defURL, OpenWithService.appName(for: defURL))
            }
            var r: [(URL, String)] = []
            if single, let first = list.first {
                let defURL = d?.0
                r = OpenWithService.recommendedApps(for: first, limit: 6)
                    .filter { $0 != defURL }
                    .map { ($0, OpenWithService.appName(for: $0)) }
            }
            let dd = d, rr = r
            DispatchQueue.main.async {
                // Kasna kompletacija za drugi skup fajlova se odbacuje.
                guard key == loadedKey else { return }
                defEntry = dd
                recEntries = rr
            }
        }
    }
}

// MARK: - Background warmer for Open With availability

/// Kicks off the async IDE-availability refresh when the menu appears, so
/// `isVSCodeInstalled()` etc. serve the cache instead of blocking menu render.
private struct OpenWithCacheWarmer: View {
    let urls: [URL]
    var body: some View {
        EmptyView()
            .onAppear { OpenWithService.refreshAvailability() }
    }
}

// MARK: - Ujedinjen desni klik: sve od Copy do Unzip + programi
//
// Jedan izvor istine za List / Grouped / Icons / Columns.
// Redosled je Finder-style: Open, Open With, QuickLook/Info, Rename/Duplicate,
// Compress/Extract, Cut/Copy/Paste, Share, Tags, Sidebar, Finder/Copy Path, Trash.

struct FileContextMenuContent: View {
    let targets: [FileItem]
    let currentPath: URL
    @ObservedObject var fileOps: FileOperationsService
    @ObservedObject var favorites: FavoritesService
    @ObservedObject var git: GitService = .shared
    var onNavigate: (FileItem) -> Void = { _ in }
    var onBrowseInto: (URL) -> Void = { _ in }
    var onRename: (FileItem) -> Void = { _ in }
    var onBatchRename: (([FileItem]) -> Void)? = nil
    var onSendToDiscord: (([FileItem]) -> Void)? = nil
    var onReload: () -> Void = {}

    var body: some View {
        if targets.isEmpty {
            FileBackgroundMenuContent(fileOps: fileOps, currentPath: currentPath, onReload: onReload)
        } else {
            populatedMenu
        }
    }

    @ViewBuilder
    private var populatedMenu: some View {
        let urls = targets.map(\.url)
        let first = targets[0]
        let single = targets.count == 1

        Button { onNavigate(first) } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        if first.isBrowsableFolder {
            Button { NSWorkspace.shared.open(first.url) } label: {
                Label("Open in New Window", systemImage: "macwindow")
            }
            Button {
                NotificationCenter.default.post(name: .ffOpenInNewTab, object: first.url)
            } label: {
                Label("Open in New Tab", systemImage: "plus.rectangle.on.folder")
            }
        } else if first.isPackage {
            Button { onBrowseInto(first.url) } label: {
                Label("Show Package Contents", systemImage: "shippingbox")
            }
        }
        Menu {
            OpenWithMenuContent(urls: urls)
        } label: {
            Label("Open With", systemImage: "app.badge")
        }
        Divider()
        Button { QuickLookController.shared.show(urls) } label: {
            Label("Quick Look", systemImage: "eye")
        }
        Button { showGetInfoInFinder(urls) } label: {
            Label("Get Info", systemImage: "info.circle")
        }
        // E-Sign: potpis PDF-a / slike / Word dokumenta (novi prozor) + provjera
        // FinderFlow pečata — za svaki potpisiv fajl u selekciji, ne samo jedan.
        let signable = urls.filter(ESignSource.canSign)
        if !signable.isEmpty {
            Button { ESignWindowManager.shared.open(signable) } label: {
                Label(ESignWindowManager.signTitle(for: signable, ofTotal: urls.count), systemImage: "signature")
            }
        }
        let pdfs = urls.filter(ESignSource.isPDF)
        if !pdfs.isEmpty {
            Button { ESignVerification.present(for: pdfs) } label: {
                Label(pdfs.count == 1 ? "Verify Signature" : "Verify \(pdfs.count) Signatures", systemImage: "checkmark.seal")
            }
        }
        // PDF Tools ▸ combine / images → PDF / split / OCR… (PDFTools.swift).
        PDFToolsMenuItems(urls: urls)
        // Workspace quick capture: task/reminder auto-linked to this file
        // (§4+§6). Works anywhere — outside a workspace the parent folder
        // is enabled first, so the entry always has a home.
        if single {
            Button { WorkspaceComposer.requestTask(for: first.url) } label: {
                Label("Add Task…", systemImage: "checklist")
            }
            Button { WorkspaceComposer.requestReminder(for: first.url) } label: {
                Label("Add Reminder…", systemImage: "bell")
            }
        }
        // Folder Rules: "Auto-Sort This Folder" checkmark + the rules window.
        if single, first.isBrowsableFolder {
            Divider()
            FolderRulesMenuItems(folder: first.url)
        }
        // Workspace Mode (PRD §2): project layer on any folder, driven
        // from the preview panel. Menu entry is a shortcut to the same.
        if single, first.isBrowsableFolder {
            if WorkspaceStore.shared.isWorkspace(first.url) {
                Button { WorkspaceStore.shared.disableWorkspace(at: first.url) } label: {
                    Label("Disable Workspace", systemImage: "briefcase.fill")
                }
            } else {
                Button { WorkspaceStore.shared.enableWorkspace(at: first.url) } label: {
                    Label("Enable Workspace", systemImage: "briefcase")
                }
            }
        }
        Divider()
        Button { onRename(first) } label: {
            Label("Rename…", systemImage: "pencil")
        }
        if targets.count > 1, let onBatchRename {
            Button { onBatchRename(targets) } label: {
                Label("Rename \(targets.count) Items…", systemImage: "square.and.pencil")
            }
        }
        Button {
            fileOps.duplicate(urls, reload: onReload)
        } label: {
            Label(single ? "Duplicate" : "Duplicate \(targets.count) Items", systemImage: "plus.square.on.square")
        }
        Button {
            urls.forEach { fileOps.makeAlias(for: $0, reload: onReload) }
        } label: {
            Label(single ? "Make Alias" : "Make \(targets.count) Aliases", systemImage: "link")
        }
        Menu {
            Button {
                fileOps.compress(urls, reload: onReload)
            } label: {
                Label(single ? "Compress \"\(first.name)\" as .zip" : "Compress \(targets.count) Items as .zip", systemImage: "archivebox")
            }
            Button {
                fileOps.compress(urls, as: .tarGz, reload: onReload)
            } label: {
                Label(single ? "Compress \"\(first.name)\" as Tar.gz" : "Compress \(targets.count) Items as Tar.gz", systemImage: "archivebox.fill")
            }
        } label: {
            Label(single ? "Compress \"\(first.name)\"" : "Compress \(targets.count) Items", systemImage: "archivebox")
        }
        if single && first.isArchive {
            Button { fileOps.extract(first.url, reload: onReload) } label: {
                Label("Extract Here", systemImage: "tray.and.arrow.down.fill")
            }
        }
        Divider()
        Button { fileOps.cut(urls) } label: {
            Label("Cut", systemImage: "scissors")
        }
        Button { fileOps.copy(urls) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            fileOps.paste(to: pasteDestination, reload: onReload)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(fileOps.pasteboardURLs.isEmpty)
        Divider()
        Menu {
            Button {
                Task { await SecureShareManager.shared.quickLink(for: urls) }
            } label: {
                Label(urls.count > 1 ? "Quick Link — Copy 24h Link (\(urls.count) items as .zip)" : "Quick Link — Copy 24h Link", systemImage: "link")
            }
            .disabled(!SecureShareManager.canQuickLink(urls))
            Button { SecureShareWindowManager.shared.open(urls: urls) } label: {
                Label(SecureShareManager.shareMenuTitle(for: urls), systemImage: "link.badge.plus")
            }
            .disabled(!SecureShareManager.canQuickLink(urls))
            .help("Multiple files/folders are packed into one .zip (\(SecureShareLimits.maxItems) items max).")
            Divider()
            Button { fileOps.shareViaAirDrop(urls) } label: {
                Label("AirDrop", systemImage: "antenna.radiowaves.left.and.right")
            }
            Button { fileOps.shareViaMail(urls) } label: {
                Label("Send via Mail", systemImage: "envelope")
            }
            Button {
                fileOps.copyFilesForMailAttach(urls)
            } label: {
                Label("Copy to Attach in Mail", systemImage: "paperclip")
            }
            Divider()
            Button { fileOps.showShareSheet(for: urls) } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        // 1-klik Quick Link: 24h link sa laptopa, bez dijaloga — odmah kopiran + toast.
        // Radi i za više stavki/foldere (pakuje u .zip, uz limite).
        Button {
            Task { await SecureShareManager.shared.quickLink(for: urls) }
        } label: {
            Label(urls.count > 1 ? "Quick Link (\(urls.count) items, 24h)" : "Quick Link (24h)", systemImage: "link")
        }
        .disabled(!SecureShareManager.canQuickLink(urls))
        // 1-klik prečica: isto kao Share > Send via Mail, ali na top levelu.
        Button { fileOps.shareViaMail(urls) } label: {
            Label("Send via Mail…", systemImage: "envelope.fill")
        }
        if let onSendToDiscord {
            Button { onSendToDiscord(targets) } label: {
                Label("Send to Discord…", systemImage: "paperplane")
            }
        }
        Divider()
        Menu {
            TagMenuContent(targets: targets, fileOps: fileOps, onReload: onReload)
        } label: {
            Label("Tags", systemImage: "tag")
        }
        // Git-aware filesystem: desni klik dobija Git podmeni samo unutar
        // repo-a (detekcija .git ka parentima). "View changes" otvara Diff
        // u Preview panelu (prečica ⌥⌘G), ostalo radi direktno.
        if git.isGitRepo(first.url) {
            Divider()
            GitMenuContent(urls: urls, onReload: onReload)
        }
        Divider()
        if single && first.isBrowsableFolder && !SidebarView.isSystemLocation(first.url) {
            if favorites.isPinned(first.url) {
                Button { favorites.unpin(first.url) } label: {
                    Label("Remove from Sidebar", systemImage: "pin.slash")
                }
            } else {
                Button { favorites.pin(first.url) } label: {
                    Label("Add to Sidebar", systemImage: "pin")
                }
            }
        }
        Button {
            FinderReveal.reveal([first.url])
        } label: {
            Label("Show in Finder", systemImage: "arrow.up.right.square")
        }
        Button {
            fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
        } label: {
            Label(single ? "Copy Path" : "Copy \(targets.count) Paths", systemImage: "doc.on.clipboard.fill")
        }
        Divider()
        Button(role: .destructive) {
            fileOps.trash(urls, reload: onReload)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
        Button(role: .destructive) {
            confirmPermanentDelete(names: targets.map(\.name)) {
                fileOps.permanentlyDelete(urls, reload: onReload)
            }
        } label: {
            Label("Delete Permanently…", systemImage: "trash.fill")
        }
    }

    /// Smart paste: ako je tacno 1 BROWSEABILAN folder selektovan -> u njega,
    /// inace currentPath. isDirectory bi progutao i .app pakete (paste bi
    /// zavrsio unutar bundle-a) — paketi se otvaraju, ne browse-uju.
    private var pasteDestination: URL {
        if targets.count == 1, targets[0].isBrowsableFolder {
            return targets[0].url
        }
        return currentPath
    }
}

// MARK: - Background meni (prazan prostor / prazan folder)

struct FileBackgroundMenuContent: View {
    @ObservedObject var fileOps: FileOperationsService
    @ObservedObject var git: GitService = .shared
    let currentPath: URL
    var onReload: () -> Void = {}

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .createNewFolder, object: nil)
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button {
            NotificationCenter.default.post(name: .createNewFile, object: nil)
        } label: {
            Label("New Text File", systemImage: "doc.badge.plus")
        }
        Divider()
        Button { fileOps.paste(to: currentPath, reload: onReload) } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
            .disabled(fileOps.pasteboardURLs.isEmpty)
        if fileOps.canUndo {
            Button { fileOps.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
        }
        if fileOps.canRedo {
            Button { fileOps.redo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
        }
        Divider()
        FolderRulesMenuItems(folder: currentPath)
        if git.isGitRepo(currentPath) {
            Divider()
            Menu {
                Button { GitUIRequest.shared.showRepo(for: currentPath) } label: {
                    Label("Repository Status…", systemImage: "arrow.triangle.branch")
                }
                Button { GitUIRequest.shared.showHistory(for: currentPath) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Divider()
                Button {
                    if let root = git.repoRoot(for: currentPath) {
                        git.pull(in: root) { _, _ in onReload() }
                    }
                } label: {
                    Label("Pull", systemImage: "arrow.down.to.line")
                }
                Button {
                    if let root = git.repoRoot(for: currentPath) {
                        git.push(in: root) { _, _ in onReload() }
                    }
                } label: {
                    Label("Push", systemImage: "arrow.up.to.line")
                }
            } label: {
                Label("Git", systemImage: "arrow.triangle.branch")
            }
        }
        Divider()
        Button { onReload() } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }
}

// MARK: - Git context menu (desni klik → preview + akcije)
//
// Spec:
//   Git
//    ├─ View changes (⌥⌘G, otvara Diff u Preview panelu)
//    ├─ Stage / Unstage
//    ├─ Discard changes…
//    ├─ Commit…
//    ├─ History
//    ├─ Copy GitHub link
//    └─ Open repository

struct GitMenuContent: View {
    let urls: [URL]
    @ObservedObject var git: GitService = .shared
    @State private var errorMessage: String?
    var onReload: () -> Void = {}

    private var singleURL: URL? { urls.count == 1 ? urls.first : nil }

    var body: some View {
        Menu {
            Button {
                if let u = singleURL { GitUIRequest.shared.showDiff(for: u) }
                else if let first = urls.first { GitUIRequest.shared.showRepo(for: first) }
            } label: {
                Label("View Changes", systemImage: "diff")
            }
            .keyboardShortcut("g", modifiers: [.command, .option])

            Button {
                if let u = singleURL { GitUIRequest.shared.showHistory(for: u) }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .disabled(singleURL == nil)

            Divider()

            Button {
                git.stage(urls) { ok, message in
                    errorMessage = ok ? nil : message
                    onReload()
                }
            } label: {
                Label(urls.count == 1 ? "Stage" : "Stage \(urls.count) Items", systemImage: "plus.circle")
            }
            Button {
                git.unstage(urls) { ok, message in
                    errorMessage = ok ? nil : message
                    onReload()
                }
            } label: {
                Label(urls.count == 1 ? "Unstage" : "Unstage \(urls.count) Items", systemImage: "minus.circle")
            }
            Button(role: .destructive) { confirmDiscard(urls: urls) } label: {
                Label("Discard Changes…", systemImage: "arrow.uturn.backward")
            }

            Divider()

            Button {
                if let u = singleURL ?? urls.first { GitUIRequest.shared.showRepo(for: u) }
            } label: {
                Label("Commit…", systemImage: "checkmark.circle")
            }

            Divider()

            Button {
                if let u = singleURL {
                    git.copyGithubLink(for: u) { copied in
                        if copied {
                            NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
                        } else {
                            errorMessage = "Copy GitHub link failed."
                        }
                    }
                }
            } label: {
                Label("Copy GitHub Link", systemImage: "link")
            }
            .disabled(singleURL == nil)

            Button {
                if let u = singleURL ?? urls.first,
                   let root = git.repoRoot(for: u) {
                    git.openRepository(root)
                }
            } label: {
                Label("Open Repository", systemImage: "folder")
            }
        } label: {
            Label("Git", systemImage: "arrow.triangle.branch")
        }
        .alert("Git action failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown Git error")
        }
    }

    private func confirmDiscard(urls: [URL]) {
        let names = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Discard changes in \"\(names)\"?"
            : "Discard changes in \(urls.count) items?"
        alert.informativeText = "Tracked changes are restored from HEAD. Untracked files are permanently deleted. This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        git.discard(urls, includeUntracked: true) { ok, message in
            errorMessage = ok ? nil : message
            onReload()
        }
    }
}
