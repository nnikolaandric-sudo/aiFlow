import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Text/binary detection + editor eligibility

enum TextFileDetector {

    /// Extensions we always treat as editable text (fast path, no disk sniff).
    static let knownTextExtensions: Set<String> = [
        "txt","text","log","md","markdown","mdown","rtf",
        "json","json5","jsonc","yaml","yml","toml","ini","conf","cfg","properties","env",
        "xml","plist","svg","html","htm","xhtml","css","scss","sass","less",
        "js","jsx","mjs","cjs","ts","tsx","swift","m","mm","h","hpp","c","cc","cpp","cxx",
        "java","kt","kts","go","rs","rb","php","py","pyw","pl","pm","lua","r","dart","scala",
        "sh","bash","zsh","fish","ps1","bat","cmd","sql","graphql","gql",
        "vue","svelte","astro","tex","bib","csv","tsv","diff","patch","gitignore",
        "gitattributes","editorconfig","dockerfile","makefile","mk","cmake","gradle",
        "asm","s","vim","el","clj","ex","exs","erl","hs","ml","fs","groovy","nim","zig"
    ]

    /// Filenames (no extension) commonly used for text/config files.
    static let knownTextFilenames: Set<String> = [
        "makefile","dockerfile","readme","license","changelog","authors",
        ".gitignore",".gitattributes",".editorconfig",".env",".zshrc",".bashrc",".bash_profile",
        ".profile",".vimrc","podfile","gemfile","rakefile",".npmrc",".prettierrc",".eslintrc"
    ]

    /// When true (default), unknown file types are sniffed and opened in the editor
    /// if they look like text. When false, only known text types open in the editor.
    static var sniffUnknown: Bool {
        UserDefaults.standard.object(forKey: "ffEditorSniffUnknown") as? Bool ?? true
    }

    /// Decide whether a file should open in the in-app code editor.
    static func isEditableText(_ url: URL) -> Bool {
        let ext  = url.pathExtension.lowercased()
        if !ext.isEmpty && knownTextExtensions.contains(ext) { return true }
        let name = url.lastPathComponent.lowercased()
        if knownTextFilenames.contains(name) { return true }
        guard sniffUnknown else { return false }
        return sniffIsText(url)
    }

    private static func sniffIsText(_ url: URL) -> Bool {
        // Online-only cloud fajl (Drive Stream, OneDrive On-Demand…): čitanje bi
        // pokrenulo puno preuzimanje fajla na glavnoj niti i zakuca app na
        // minutima za velike fajlove. Nikad ne sniffuj — otvori preko sistema
        // (koji skida fajl kako treba) ili neka korisnik prvo skine fajl.
        if FileItem.isNotDownloaded(url) { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8192)
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        if String(data: data, encoding: .utf8) != nil { return true }
        if String(data: data, encoding: .isoLatin1) != nil { return true }
        return false
    }
}

// MARK: - Open document model

struct OpenDoc: Identifiable, Equatable {
    let id: String
    let url: URL
    var modified: Bool = false
    /// Kodna stranica procitana pri otvaranju — cuvanje uvek istom da latin1
    /// fajl ne postane mojibake (cita utf8->latin1 fallback, pise nazad isto).
    var encoding: String.Encoding = .utf8
}

// MARK: - Standalone editor window manager (real macOS window, non-blocking)

@MainActor
final class EditorWindowManager: NSObject, NSWindowDelegate {
    static let shared = EditorWindowManager()

    private var window: NSWindow?
    private var controller: AceEditorController?

    /// True when any tab holds unsaved changes (quit protection polls this —
    /// Cmd-Q never consults windowShouldClose, verified by probe).
    var hasUnsavedChanges: Bool { controller?.docs.contains(where: \.modified) == true }

    /// Save-all for the quit flow: always completes exactly once (10s timeout
    /// cancels instead of hanging termination on a wedged renderer).
    func saveAllForQuit(completion: @escaping (Bool) -> Void) {
        guard let controller else { completion(true); return }
        var done = false
        func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            completion(ok)
        }
        controller.saveAllDirty { finish($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(false) }
    }

    /// Open a file in the editor window — creating the window on first use,
    /// otherwise adding the file as a new tab in the existing window.
    /// Fajlovi preko limita se ne ucitavaju u Ace (ceo fajl ide u JS string +
    /// memoriju i zakuca prozor) — otvaraju se sistemskim defaultom.
    func open(_ url: URL) {
        if AceEditorController.isTooLarge(url) {
            NSWorkspace.shared.open(url)
            return
        }
        if let controller, let window {
            controller.open(urls: [url])
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = AceEditorController(urls: [url])
        self.controller = controller

        let hosting = NSHostingController(rootView: CodeEditorView(controller: controller))
        let window  = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("FinderFlowEditorWindow")
        self.window = window

        controller.onTitleChange = { [weak window] title in window?.title = title }
        controller.onRequestClose = { [weak self] in self?.window?.performClose(nil) }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Zatvaranje prozora sa prljavim tabovima trazi potvrdu — ranije je ×
    /// cutao sve nesnimljeno bez pitanja.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller, controller.docs.contains(where: \.modified) else { return true }
        let dirty = controller.docs.filter(\.modified)
        let label = dirty.count == 1 ? "“\(dirty[0].url.lastPathComponent)”" : "\(dirty.count) documents"
        let alert = NSAlert()
        alert.messageText = "Save changes to \(label)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            controller.saveAllDirty { [weak sender] ok in
                if ok { sender?.close() }
                // Neuspeh: ostaje otvoreno (bez petlje — close se ne poziva).
            }
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        controller = nil
        window = nil
    }
}

// MARK: - Controller bridging WKWebView (Ace) and SwiftUI

final class AceEditorController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    let webView: WKWebView

    @Published var docs: [OpenDoc] = []
    @Published var activeID: String?
    @Published var statusFlash: String?
    @Published var isReady = false
    /// Cap open editor tabs — each tab keeps a full Ace JS document alive in
    /// the WKWebView plus the Swift-side string, so unbounded tabs leak RAM.
    static let maxOpenDocs = 20

    /// Callbacks owned by the window manager.
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?

    // Mirrored from @AppStorage by the view.
    var wrap        = false
    var fontSize    = 14
    var sublimeKeys = false
    var minimapOn   = true

    private var pendingURLs: [URL]
    private let handlerName = "bridge"

    init(urls: [URL]) {
        self.pendingURLs = urls

        let config = WKWebViewConfiguration()
        let ucc    = WKUserContentController()
        config.userContentController = ucc
        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        ucc.add(WeakScriptMessageProxy(self), name: handlerName)
        webView.navigationDelegate = self

        if let html = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "AceEditor") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    }

    var activeDoc: OpenDoc? { docs.first { $0.id == activeID } }

    private var currentTitle: String {
        guard let d = activeDoc else { return "Editor" }
        return (d.modified ? "• " : "") + d.url.lastPathComponent
    }

    private func notifyTitle() { onTitleChange?(currentTitle) }

    private var themeForAppearance: String {
        let dark = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? "ace/theme/monokai" : "ace/theme/github"
    }

    // MARK: JS → Swift

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let queued = pendingURLs
            pendingURLs = []
            for url in queued { openOne(url) }
        case "changed":
            if let id = body["id"] as? String { setModified(id, true) }
        case "save":
            // Strogi nil-guard: sadrzaj koji nedostaje ne sme da postane ""
            // jer bi write() skratio fajl na nulu (gubitak podataka).
            if let id = body["id"] as? String, let content = body["content"] as? String {
                write(id: id, content: content)
            }
        case "open":
            presentOpenPanel()
        case "closeTab":
            if let id = body["id"] as? String { closeTab(id) }
        case "minimap":
            if let on = body["on"] as? Bool {
                minimapOn = on
                UserDefaults.standard.set(on, forKey: "ffEditorMinimap")
            }
        default:
            break
        }
    }

    // MARK: Tabs

    func open(urls: [URL]) {
        for url in urls where Self.isTooLarge(url) { NSWorkspace.shared.open(url) }
        let fitting = urls.filter { !Self.isTooLarge($0) }
        guard !fitting.isEmpty else { return }
        guard isReady else { pendingURLs.append(contentsOf: fitting); return }
        for url in fitting { openOne(url) }
    }

    /// Preveliki fajlovi se ne otvaraju u Ace editoru (vidi EditorWindowManager).
    static let maxEditableBytes: Int64 = 20 * 1024 * 1024

    static func isTooLarge(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return size > maxEditableBytes
    }

    private func openOne(_ url: URL) {
        if let existing = docs.first(where: { $0.url == url }) {
            switchTo(existing.id)
            return
        }
        // Izbaci najstariji POZADINSKI NECISTI tab. Prljavi tabovi se nikad
        // ne izbacuju cuteci — ranije je evikcija brisala nesnimljeno.
        // Ako su svi ostali prljavi, cap se meko probija za 1 (sledeci open
        // ponovo pokusa) umesto gubitka podataka.
        if docs.count >= Self.maxOpenDocs {
            if let victim = docs.first(where: { $0.id != activeID && !$0.modified }) {
                run("FF.closeDoc(\"\(victim.id)\");")
                docs.removeAll { $0.id == victim.id }
            }
        }
        let id = UUID().uuidString
        guard let read = readFile(url) else {
            // Unreadable (missing, no permission, I/O error): never open an
            // empty doc bound to the real URL — a later Save would truncate
            // the original to zero bytes.
            flash("Couldn't open \(url.lastPathComponent)")
            return
        }
        docs.append(OpenDoc(id: id, url: url, encoding: read.encoding))
        activeID = id
        let enc = JSONEncoder()
        guard let textJSON = String(data: (try? enc.encode(read.text)) ?? Data(), encoding: .utf8),
              let nameJSON = String(data: (try? enc.encode(url.lastPathComponent)) ?? Data(), encoding: .utf8)
        else { return }
        let keymap = sublimeKeys ? "\"ace/keyboard/sublime\"" : "null"
        let js = "FF.openDoc(\"\(id)\", \(textJSON), \(nameJSON), \"\(themeForAppearance)\", \(wrap), \(keymap), \(fontSize));"
        run(js)
        run("FF.setMinimap(\(minimapOn));")
        notifyTitle()
    }

    func switchTo(_ id: String) {
        activeID = id
        run("FF.switchDoc(\"\(id)\");")
        notifyTitle()
    }

    /// Zatvaranje taba sa nesnimljenim izmenama trazi potvrdu — ranije je ×
    /// cutao izmene bez pitanja (gubitak podataka).
    func closeTab(_ id: String) {
        guard let doc = docs.first(where: { $0.id == id }) else { return }
        guard doc.modified else { performCloseTab(id); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(doc.url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            webView.evaluateJavaScript("FF.getDocContent(\"\(id)\");") { [weak self] result, _ in
                guard let self else { return }
                // Sadrzaj koji nedostaje ne sme da postane "" (skratio bi fajl).
                guard let content = result as? String else { return }
                if self.write(id: id, content: content) { self.performCloseTab(id) }
                // Neuspeh cuvanja: tab ostaje otvoren, greska je vec flash-ovana.
            }
        case .alertSecondButtonReturn:
            performCloseTab(id)
        default:
            break
        }
    }

    private func performCloseTab(_ id: String) {
        run("FF.closeDoc(\"\(id)\");")
        docs.removeAll { $0.id == id }
        if activeID == id { activeID = docs.last?.id }
        if let a = activeID { run("FF.switchDoc(\"\(a)\");") }
        if docs.isEmpty { onRequestClose?() } else { notifyTitle() }
    }

    // MARK: Save

    func saveActive() {
        guard let id = activeID else { return }
        webView.evaluateJavaScript("FF.getDocContent(\"\(id)\");") { [weak self] result, _ in
            guard let content = result as? String else { return }
            self?.write(id: id, content: content)
        }
    }

    /// Snima sve prljave tabove (za windowShouldClose → Save All).
    /// Completion na mainu: true kad je sve snimljeno.
    func saveAllDirty(completion: @escaping (Bool) -> Void) {
        let dirty = docs.filter(\.modified)
        guard !dirty.isEmpty else { completion(true); return }
        var pending = dirty.count
        var ok = true
        for doc in dirty {
            webView.evaluateJavaScript("FF.getDocContent(\"\(doc.id)\");") { [weak self] result, _ in
                if let content = result as? String {
                    ok = (self?.write(id: doc.id, content: content) ?? false) && ok
                } else {
                    ok = false
                }
                pending -= 1
                if pending == 0 { completion(ok) }
            }
        }
    }

    /// Pise sadrzaj istom kodnom stranicom kojom je procitan. Vraca uspeh.
    @discardableResult
    private func write(id: String, content: String) -> Bool {
        guard let doc = docs.first(where: { $0.id == id }) else { return false }
        do {
            try content.write(to: doc.url, atomically: true, encoding: doc.encoding)
            setModified(id, false)
            flash("Saved \(doc.url.lastPathComponent)")
            return true
        } catch {
            flash("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func setModified(_ id: String, _ value: Bool) {
        guard let idx = docs.firstIndex(where: { $0.id == id }), docs[idx].modified != value else { return }
        docs[idx].modified = value
        notifyTitle()
    }

    // MARK: Open panel

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            let editable = panel.urls.filter { TextFileDetector.isEditableText($0) }
            if !editable.isEmpty { self.open(urls: editable) }
        }
    }

    // MARK: Editor commands (toolbar)

    func setMinimap(_ on: Bool) { minimapOn = on; run("FF.setMinimap(\(on));") }
    func toggleWrap()        { wrap.toggle(); run("FF.setWrapAll(\(wrap));") }
    func setFontSize(_ n: Int) { fontSize = max(8, min(36, n)); run("FF.setFontSize(\(fontSize));") }
    func toggleSublime()     { sublimeKeys.toggle(); run("FF.setKeymap(\(sublimeKeys ? "\"ace/keyboard/sublime\"" : "null"));") }
    func find()              { run("FF.find();") }
    func gotoLine()          { run("FF.gotoLine();") }
    func palette()           { run("FF.palette();") }
    func settings()          { run("FF.settings();") }

    private func run(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    /// Nil when the file can't be read at all (missing, no permission, I/O
    /// error) — the caller must refuse to open instead of showing an empty
    /// doc (see openOne). isoLatin1 decodes any byte sequence, so reaching
    /// nil means the read itself failed, not the decoding.
    private func readFile(_ url: URL) -> (text: String, encoding: String.Encoding)? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return (s, .utf8) }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return (s, .isoLatin1) }
        return nil
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { statusFlash = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.statusFlash = nil }
        }
    }
}

/// Breaks the retain cycle WKUserContentController → handler → controller.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(uc, didReceive: message)
    }
}

// MARK: - NSViewRepresentable host

private struct AceWebView: NSViewRepresentable {
    let controller: AceEditorController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Editor view (hosted inside the standalone window)

struct CodeEditorView: View {
    @ObservedObject var ctrl: AceEditorController

    @AppStorage("ffEditorWrap")        private var wrap        = false
    @AppStorage("ffEditorFontSize")    private var fontSize    = 14
    @AppStorage("ffEditorSublimeKeys") private var sublimeKeys = false
    @AppStorage("ffEditorMinimap")     private var minimap     = true

    init(controller: AceEditorController) { self.ctrl = controller }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if ctrl.docs.count > 1 { tabBar; Divider() }
            AceWebView(controller: ctrl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            ctrl.wrap        = wrap
            ctrl.fontSize    = fontSize
            ctrl.sublimeKeys = sublimeKeys
            ctrl.minimapOn   = minimap
        }
        .background(
            Button("") { ctrl.saveActive() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            if let flash = ctrl.statusFlash {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(flash)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            ToolbarActionButton(icon: "command", label: "Command Palette  ⌘⇧P") { ctrl.palette() }
            ToolbarActionButton(icon: "magnifyingglass", label: "Find / Replace  ⌘F") { ctrl.find() }
            ToolbarActionButton(icon: "arrow.right.to.line", label: "Go to Line  ⌘L") { ctrl.gotoLine() }
            ToolbarActionButton(icon: "doc.badge.plus", label: "Open File in New Tab  ⌘O") { ctrl.presentOpenPanel() }
            ToolbarActionButton(icon: wrap ? "text.alignleft" : "text.append", label: wrap ? "Wrap: on" : "Wrap: off") {
                ctrl.toggleWrap(); wrap = ctrl.wrap
            }

            Toggle(isOn: Binding(
                get: { minimap },
                set: { minimap = $0; ctrl.setMinimap($0) }
            )) {
                Label("Minimap", systemImage: "rectangle.righthalf.inset.filled")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button).buttonStyle(.borderless)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(minimap ? Color.accentColor : Color.primary)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
            .ffActivePill(minimap)
            .help(minimap ? "Minimap: on  ⌘⇧M" : "Minimap: off  ⌘⇧M")

            Menu {
                Button("Settings…")     { ctrl.settings() }
                Divider()
                Button("Increase Font") { ctrl.setFontSize(fontSize + 1); fontSize = ctrl.fontSize }
                Button("Decrease Font") { ctrl.setFontSize(fontSize - 1); fontSize = ctrl.fontSize }
                Divider()
                Toggle("Sublime Keybindings", isOn: Binding(
                    get: { sublimeKeys },
                    set: { _ in ctrl.toggleSublime(); sublimeKeys = ctrl.sublimeKeys }
                ))
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).help("Editor options")

            ToolbarActionButton(icon: "square.and.arrow.down", label: "Save  ⌘S") { ctrl.saveActive() }
                .disabled(ctrl.activeDoc?.modified != true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ctrl.docs) { doc in
                    EditorTabChip(doc: doc, isActive: doc.id == ctrl.activeID, ctrl: ctrl)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

private struct EditorTabChip: View {
    let doc: OpenDoc
    let isActive: Bool
    @ObservedObject var ctrl: AceEditorController
    @State private var hovering = false
    @State private var closeHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text((doc.modified ? "• " : "") + doc.url.lastPathComponent)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button { ctrl.closeTab(doc.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .background(
                        FFTheme.controlShape
                            .fill(closeHovering ? Color.primary.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { closeHovering = $0 }
            .help("Close Tab  ⌘W")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            FFTheme.controlShape
                .fill(isActive ? Color.accentColor.opacity(0.16) : (hovering ? FFTheme.hoverBG : Color.clear))
        )
        .overlay(
            FFTheme.controlShape
                .strokeBorder(Color.accentColor.opacity(isActive ? 0.30 : 0), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .onTapGesture { ctrl.switchTo(doc.id) }
        .help(doc.url.path)
    }
}
