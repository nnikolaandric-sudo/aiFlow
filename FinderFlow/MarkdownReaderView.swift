import SwiftUI
import WebKit
import AppKit

// MARK: - Wrapper so URL works with .sheet(item:)

struct MarkdownFileItem: Identifiable {
    let id  = UUID()
    let url: URL
}

// MARK: - Read / Edit mode

private enum MDMode: String, Hashable {
    case read = "Read"
    case edit = "Edit"
}

// MARK: - Full Markdown reader + editor sheet

struct MarkdownReaderView: View {
    let initialURL: URL
    /// Closes the hosting window (supplied by MarkdownWindowManager).
    var onClose: () -> Void = {}
    /// Pushes the live document title (with • when dirty) to the window titlebar.
    var onTitleChange: ((String) -> Void)? = nil
    /// Mirrors isModified to the window manager (quit protection can't read
    /// SwiftUI @State after the fact).
    var onDirtyChange: ((Bool) -> Void)? = nil

    @State private var navStack:   [URL]   = []
    /// Cap back-stack depth — unbounded navigation history pins URL objects.
    private static let maxNavDepth = 50
    @State private var current:    URL
    @State private var mode:       MDMode  = .read
    @State private var editText:   String  = ""
    @State private var isModified: Bool    = false
    /// Encoding the current file was read with — saves write back the same
    /// one (a latin1 file silently re-saved as utf8 changes bytes/mojibake).
    @State private var encoding: String.Encoding = .utf8
    /// The current file couldn't be read: buffer is empty by necessity, and
    /// saving is blocked so an empty buffer can never truncate the original.
    @State private var loadFailed: Bool = false
    @State private var saveFlash:  String? = nil
    @State private var refreshID:  UUID    = UUID()
    @State private var previewText: String = ""
    @StateObject private var editorCtrl = MarkdownEditorController()
    @State private var showLinkSheet = false
    @State private var linkURLDraft  = "https://"
    @State private var backHover = false
    @State private var previewTask: Task<Void, Never>?

    init(url: URL,
         onClose: @escaping () -> Void = {},
         onTitleChange: ((String) -> Void)? = nil,
         onDirtyChange: ((Bool) -> Void)? = nil) {
        self.initialURL    = url
        self.onClose       = onClose
        self.onTitleChange = onTitleChange
        self.onDirtyChange = onDirtyChange
        self._current      = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if mode == .edit {
                formatToolbar
                Divider()
            } else {
                Divider()
            }
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear        { loadFile(); pushTitle(); previewText = editText }
        .onChange(of: current)    { _, _ in loadFile(); pushTitle(); previewText = editText }
        .onChange(of: isModified) { _, _ in pushTitle(); onDirtyChange?(isModified) }
        .onChange(of: editText) { _, newValue in
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                previewText = newValue
                refreshID = UUID()
            }
        }
        // Safety net: never lose edits if the window is closed another way.
        // Ide kroz commitSave (ne tihi try?): neuspeh (pun disk, dozvola)
        // ostavlja isModified=true + "Save failed" umesto laznog osecaja da
        // je sacuvano — explicitni save putevi (Done/Back/read-mode) vec postoje.
        .onDisappear {
            previewTask?.cancel()
            commitSave()
        }
        .sheet(isPresented: $showLinkSheet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(FFTheme.softGradient)
                            .frame(width: 30, height: 30)
                        Image(systemName: "link")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("Insert link")
                        .font(.system(size: 13, weight: .semibold))
                }
                TextField("https://…", text: $linkURLDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(FFTheme.cardShape)
                    .overlay(
                        FFTheme.cardShape
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                HStack {
                    Spacer()
                    Button("Cancel") { showLinkSheet = false }
                    Button("Insert") {
                        editorCtrl.run { MarkdownFormatActions.link($0, url: linkURLDraft) }
                        showLinkSheet = false
                        isModified = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Toolbar
    // ─────────────────────────────────────────────────────────────

    private var toolbar: some View {
        HStack(spacing: 4) {

            // Back — only appears after the user has followed an internal .md link
            if !navStack.isEmpty {
                Button {
                    if isModified { commitSave() }
                    let prev = navStack.removeLast()
                    current  = prev
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(navStack.last?.deletingPathExtension().lastPathComponent ?? "Back")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(
                        FFTheme.controlShape
                            .fill(backHover ? FFTheme.hoverBG : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { backHover = $0 }
                .help("Go back")

                Divider().frame(height: 18).opacity(0.6)
            }

            // File icon + name  (• prefix while there are unsaved changes)
            Image(systemName: "doc.text.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            Text((isModified ? "• " : "") + current.deletingPathExtension().lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Saved / Save-failed flash message
            if let flash = saveFlash {
                HStack(spacing: 4) {
                    Image(systemName: flash == "Saved" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(flash)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(flash == "Saved" ? .green : .secondary)
                .transition(.opacity)
            }

            // Read / Edit segmented toggle
            Picker("", selection: $mode) {
                Text("Read").tag(MDMode.read)
                Text("Edit").tag(MDMode.edit)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .onChange(of: mode) { _, newMode in
                // Auto-save when switching back to reader so WebView shows fresh content
                if newMode == .read, isModified {
                    commitSave()
                    refreshID = UUID()
                }
            }

            // Save button — only in edit mode, enabled when dirty
            if mode == .edit {
                ToolbarActionButton(icon: "square.and.arrow.down", label: "Save  ⌘S") { commitSave() }
                    .disabled(!isModified || loadFailed)
                    // Hidden button captures ⌘S keyboard shortcut
                    .background(
                        Button("") { commitSave() }
                            .keyboardShortcut("s", modifiers: .command)
                            .hidden()
                    )
            }

            Divider().frame(height: 18).opacity(0.6)

            // Open this file in FinderFlow's own built-in code editor
            ToolbarActionButton(icon: "chevron.left.forwardslash.chevron.right", label: "Open in aiFlow editor") {
                if isModified { commitSave() }
                EditorWindowManager.shared.open(current)
            }

            Divider().frame(height: 18).opacity(0.6)

            Button("Done") { if isModified { commitSave() }; onClose() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Format toolbar (edit mode)
    // ─────────────────────────────────────────────────────────────

    private var formatToolbar: some View {
        HStack(spacing: 2) {
            MDFormatButton("arrow.uturn.backward", help: "Undo", enabled: editorCtrl.canUndo) {
                editorCtrl.run { MarkdownFormatActions.undo($0) }
            }
            MDFormatButton("arrow.uturn.forward", help: "Redo", enabled: editorCtrl.canRedo) {
                editorCtrl.run { MarkdownFormatActions.redo($0) }
            }
            Divider().frame(height: 18).opacity(0.6).padding(.horizontal, 4)

            MDFormatButton("bold", help: "Bold") {
                editorCtrl.run { MarkdownFormatActions.bold($0) }; isModified = true
            }
            MDFormatButton("italic", help: "Italic") {
                editorCtrl.run { MarkdownFormatActions.italic($0) }; isModified = true
            }
            MDFormatButton("strikethrough", help: "Strikethrough") {
                editorCtrl.run { MarkdownFormatActions.strikethrough($0) }; isModified = true
            }
            MDFormatButton("chevron.left.forwardslash.chevron.right", help: "Inline code") {
                editorCtrl.run { MarkdownFormatActions.inlineCode($0) }; isModified = true
            }
            Divider().frame(height: 18).opacity(0.6).padding(.horizontal, 4)

            MDFormatButton("textformat.size.larger", help: "Heading 1") {
                editorCtrl.run { MarkdownFormatActions.heading($0, level: 1) }; isModified = true
            }
            MDFormatButton("textformat.size", help: "Heading 2") {
                editorCtrl.run { MarkdownFormatActions.heading($0, level: 2) }; isModified = true
            }
            MDFormatButton("textformat.size.smaller", help: "Heading 3") {
                editorCtrl.run { MarkdownFormatActions.heading($0, level: 3) }; isModified = true
            }
            Divider().frame(height: 18).opacity(0.6).padding(.horizontal, 4)

            MDFormatButton("list.bullet", help: "Bullet list") {
                editorCtrl.run { MarkdownFormatActions.bulletList($0) }; isModified = true
            }
            MDFormatButton("list.number", help: "Numbered list") {
                editorCtrl.run { MarkdownFormatActions.numberedList($0) }; isModified = true
            }
            MDFormatButton("text.quote", help: "Quote") {
                editorCtrl.run { MarkdownFormatActions.quote($0) }; isModified = true
            }
            MDFormatButton("curlybraces", help: "Code block") {
                editorCtrl.run { MarkdownFormatActions.codeFence($0) }; isModified = true
            }
            MDFormatButton("link", help: "Link") {
                linkURLDraft = "https://"
                showLinkSheet = true
            }
            MDFormatButton("minus", help: "Horizontal rule") {
                editorCtrl.run { MarkdownFormatActions.horizontalRule($0) }; isModified = true
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Content area
    // ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private var contentArea: some View {
        switch mode {
        case .read:
            // Reuse in-memory buffer — avoid a second disk read for the preview.
            MarkdownWebView(source: .string(editText, title: current.deletingPathExtension().lastPathComponent),
                            refreshID: refreshID) { dest in
                pushNav(current)
                current = dest
            }
            case .edit:
            HSplitView {
                MarkdownEditorView(text: $editText, isModified: $isModified, controller: editorCtrl)
                    .frame(minWidth: 280)
                MarkdownWebView(source: .string(previewText, title: current.deletingPathExtension().lastPathComponent),
                                refreshID: refreshID) { dest in
                    if isModified { commitSave() }
                    pushNav(current)
                    current = dest
                    mode = .read
                }
                .frame(minWidth: 240)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────────────────────

    private func pushNav(_ url: URL) {
        navStack.append(url)
        if navStack.count > Self.maxNavDepth {
            navStack.removeFirst(navStack.count - Self.maxNavDepth)
        }
    }

    private func loadFile() {
        // Prvo sacuvaj prljavi bafer: pracenje linka u READ rezimu (bez
        // commitSave pre navigacije) bi inace cutke pregazilo nesnimljeno.
        if isModified { commitSave() }
        if let s = try? String(contentsOf: current, encoding: .utf8) {
            (editText, encoding, loadFailed) = (s, .utf8, false)
        } else if let s = try? String(contentsOf: current, encoding: .isoLatin1) {
            (editText, encoding, loadFailed) = (s, .isoLatin1, false)
        } else {
            // Unreadable: keep the buffer empty but block saving (see
            // commitSave) — persisting an empty buffer would truncate the
            // original the moment it becomes writable again.
            (editText, loadFailed) = ("", true)
            saveFlash = "Couldn't read file"
        }
        isModified = false
    }

    private func commitSave() {
        guard isModified, !loadFailed else { return }
        do {
            try editText.write(to: current, atomically: true, encoding: encoding)
            isModified = false
            withAnimation(.easeOut(duration: 0.2)) { saveFlash = "Saved" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.3)) { saveFlash = nil }
            }
        } catch {
            saveFlash = "Save failed"
        }
    }

    /// Keep the window titlebar in sync with the current file + dirty state.
    private func pushTitle() {
        let name = current.deletingPathExtension().lastPathComponent
        onTitleChange?((isModified ? "• " : "") + name)
    }
}

// MARK: - Format toolbar button (hover + disabled dim)

private struct MDFormatButton: View {
    let systemName: String
    let help: String
    var enabled: Bool = true
    let action: () -> Void
    @State private var hovering = false

    init(_ systemName: String, help: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .background(
                    FFTheme.controlShape
                        .fill(hovering && enabled ? FFTheme.hoverBG : Color.clear)
                )
                .opacity(enabled ? 1.0 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Standalone Markdown window (real macOS window: draggable + resizable)

/// Hosts `MarkdownReaderView` in a genuine `NSWindow` — mirroring the code
/// editor — so the reader can be dragged by its titlebar, resized, zoomed and
/// minimised like any native window (instead of a fixed, modal sheet).
@MainActor
final class MarkdownWindowManager: NSObject, NSWindowDelegate {
    static let shared = MarkdownWindowManager()

    private var window: NSWindow?
    /// Mirrored from the hosted view via onDirtyChange (quit protection).
    private(set) var hasUnsavedChanges = false

    /// Open a `.md` file in the reader window, reusing the existing window if any.
    func open(_ url: URL) {
        // Fresh view = clean buffer; the mirror is per-view state.
        hasUnsavedChanges = false
        if let window {
            window.contentViewController = makeHosting(url)
            window.title = url.deletingPathExtension().lastPathComponent
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: makeHosting(url))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = url.deletingPathExtension().lastPathComponent
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 560, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("FinderFlowMarkdownWindow")
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeHosting(_ url: URL) -> NSHostingController<MarkdownReaderView> {
        NSHostingController(rootView: MarkdownReaderView(
            url: url,
            onClose:       { [weak self] in self?.window?.performClose(nil) },
            onTitleChange: { [weak self] title in self?.window?.title = title },
            onDirtyChange: { [weak self] dirty in self?.hasUnsavedChanges = dirty }
        ))
    }

    /// Bring the reader forward (quit protection parks termination here when
    /// the buffer is dirty so the user saves explicitly — zero loss risk).
    func activate() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        hasUnsavedChanges = false
        window = nil
    }
}

// MARK: - WKWebView representable

enum MarkdownWebSource: Equatable {
    case file(URL)
    case string(String, title: String)
}

struct MarkdownWebView: NSViewRepresentable {
    let source:     MarkdownWebSource
    let refreshID:  UUID          // bump to force reload of the same URL after a save
    let onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        context.coordinator.render(source: source, refreshID: refreshID, in: wv)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.render(source: source, refreshID: refreshID, in: wv)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onNavigate: (URL) -> Void
        private var loadedKey: String?

        init(onNavigate: @escaping (URL) -> Void) { self.onNavigate = onNavigate }

        func render(source: MarkdownWebSource, refreshID: UUID, in wv: WKWebView) {
            let key: String
            let md: String
            let title: String
            let base: URL?
            switch source {
            case .file(let url):
                key = "file:\(url.path):\(refreshID.uuidString)"
                // Never trigger a full cloud download on the render thread:
                // online-only files show a placeholder until opened (which
                // downloads) instead of freezing the UI mid-preview.
                if FileItem.isNotDownloaded(url) {
                    md = "*Not downloaded — open the file to download it.*"
                } else {
                    md = (try? String(contentsOf: url, encoding: .utf8))
                        ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                        ?? "*Unable to read file.*"
                }
                title = url.deletingPathExtension().lastPathComponent
                base = url.deletingLastPathComponent()
            case .string(let text, let t):
                // Hash content so live preview updates when text changes
                key = "str:\(t):\(text.hashValue)"
                md = text
                title = t
                base = nil
            }
            guard key != loadedKey else { return }
            loadedKey = key
            let html = MarkdownToHTML.render(md, title: title)
            wv.loadHTMLString(html, baseURL: base)
        }

        func webView(_ wv: WKWebView, decidePolicyFor nav: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard nav.navigationType == .linkActivated,
                  let target = nav.request.url else { decisionHandler(.allow); return }
            decisionHandler(.cancel)
            if target.isFileURL && target.pathExtension.lowercased() == "md" {
                onNavigate(target)
            } else if let scheme = target.scheme?.lowercased(),
                      ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(target)
            }
            // Block javascript:, data:, file opens of non-md, etc.
        }
    }
}

// MARK: - In-app Markdown editor (NSTextView-based, Obsidian-styled)

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text:       String
    @Binding var isModified: Bool
    var controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isModified: $isModified, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }

        tv.delegate                             = context.coordinator
        tv.isEditable                           = true
        tv.isRichText                           = false
        tv.allowsUndo                           = true
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled    = false
        tv.isAutomaticLinkDetectionEnabled      = false
        tv.isContinuousSpellCheckingEnabled     = false
        tv.font                                 = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textContainerInset                   = NSSize(width: 36, height: 28)
        tv.isVerticallyResizable                = true
        tv.isHorizontallyResizable              = false
        tv.textContainer?.widthTracksTextView   = true
        tv.insertionPointColor                  = .controlAccentColor

        // Obsidian-inspired background — adapts to macOS dark / light mode
        tv.backgroundColor = Self.editorBackground()

        // Line spacing & paragraph style
        let para = NSMutableParagraphStyle()
        para.lineSpacing        = 5
        para.paragraphSpacing   = 4
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [
            .font:            NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle:  para,
        ]

        tv.string = text
        context.coordinator.textView = tv
        controller.attach(tv)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        context.coordinator.controller = controller
        if controller.textView !== tv { controller.attach(tv) }
        // Only update the backing store when the text changed externally
        // (e.g. file reload after navigation) — avoids cursor/scroll reset while typing.
        guard tv.string != text else { return }
        let sel = tv.selectedRange()
        tv.string = text
        let safeLoc = min(sel.location, (text as NSString).length)
        tv.setSelectedRange(NSRange(location: safeLoc, length: 0))
    }

    /// Dynamic background: Obsidian #1e1e2e in dark mode, near-white in light mode.
    private static func editorBackground() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.180, alpha: 1)  // #1e1e2e
                : NSColor(srgbRed: 0.980, green: 0.980, blue: 0.984, alpha: 1)  // #fafafa
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text:       String
        @Binding var isModified: Bool
        var controller: MarkdownEditorController
        weak var textView: NSTextView?

        init(text: Binding<String>, isModified: Binding<Bool>, controller: MarkdownEditorController) {
            self._text       = text
            self._isModified = isModified
            self.controller  = controller
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text       = tv.string
            isModified = true
            controller.refreshUndoState()
        }
    }
}

// MARK: - Swift Markdown → HTML renderer
// (MarkdownToHTML enum is defined below — unchanged from previous version)

enum MarkdownToHTML {

    static func render(_ markdown: String, title: String) -> String {
        htmlTemplate(title: title, body: parseBlocks(markdown))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Block-level parser
    // ─────────────────────────────────────────────────────────────────────

    private static func parseBlocks(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var out   = ""
        var i     = 0

        while i < lines.count {
            let line = lines[i]
            let trim = line.trimmingCharacters(in: .whitespaces)

            if trim.isEmpty { i += 1; continue }

            // Fenced code block
            let fenceSeq: String? = line.hasPrefix("```") ? "```"
                                  : line.hasPrefix("~~~") ? "~~~" : nil
            if let fence = fenceSeq {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix(fence) {
                    body.append(escapeHTML(lines[i])); i += 1
                }
                if i < lines.count { i += 1 }
                let cls = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
                out += "<pre><code\(cls)>\(body.joined(separator: "\n"))</code></pre>\n"
                continue
            }

            // ATX heading
            if let (lvl, txt) = atxHeading(trim) {
                let anchor = txt.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }.joined(separator: "-")
                out += "<h\(lvl) id=\"\(anchor)\">\(parseInline(txt))</h\(lvl)>\n"
                i += 1; continue
            }

            // Horizontal rule
            if isHR(trim) { out += "<hr>\n"; i += 1; continue }

            // Blockquote
            if line.hasPrefix(">") {
                var bqLines: [String] = []
                while i < lines.count &&
                      (lines[i].hasPrefix(">") ||
                       lines[i].trimmingCharacters(in: .whitespaces).isEmpty) {
                    let l = lines[i]
                    if l.hasPrefix("> ")     { bqLines.append(String(l.dropFirst(2))) }
                    else if l.hasPrefix(">") { bqLines.append(String(l.dropFirst())) }
                    else                     { bqLines.append("") }
                    i += 1
                }
                out += "<blockquote>\(parseBlocks(bqLines.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            // Unordered list
            if isULItem(line) {
                out += "<ul>\n"
                while i < lines.count && isULItem(lines[i]) {
                    out += "  <li>\(parseInline(String(lines[i].dropFirst(2))))</li>\n"; i += 1
                }
                out += "</ul>\n"; continue
            }

            // Ordered list
            if isOLItem(line) {
                out += "<ol>\n"
                while i < lines.count && isOLItem(lines[i]) {
                    let content = lines[i].replacingOccurrences(
                        of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    out += "  <li>\(parseInline(content))</li>\n"; i += 1
                }
                out += "</ol>\n"; continue
            }

            // Table
            if trim.contains("|"), i + 1 < lines.count, isSepRow(lines[i + 1]) {
                let headers = tableRow(line); i += 2
                out += "<table>\n<thead>\n<tr>"
                for h in headers { out += "<th>\(parseInline(h))</th>" }
                out += "</tr>\n</thead>\n<tbody>\n"
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    out += "<tr>"
                    for c in tableRow(lines[i]) { out += "<td>\(parseInline(c))</td>" }
                    out += "</tr>\n"; i += 1
                }
                out += "</tbody>\n</table>\n"; continue
            }

            // Paragraph
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]; let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if atxHeading(t) != nil || isHR(t) { break }
                if l.hasPrefix("```") || l.hasPrefix("~~~") { break }
                if isULItem(l) || isOLItem(l) || l.hasPrefix(">") { break }
                if i + 1 < lines.count {
                    let nxt = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if !nxt.isEmpty && nxt.allSatisfy({ $0 == "=" }) {
                        out += "<h1>\(parseInline(t))</h1>\n"; i += 2; paraLines = []; break
                    }
                    if !nxt.isEmpty && nxt.count >= 2 && nxt.allSatisfy({ $0 == "-" }) {
                        out += "<h2>\(parseInline(t))</h2>\n"; i += 2; paraLines = []; break
                    }
                }
                paraLines.append(l); i += 1
            }
            if !paraLines.isEmpty {
                let text = paraLines.map { $0.hasSuffix("  ") ? String($0.dropLast(2)) + "<br>" : $0 }
                    .joined(separator: "\n")
                out += "<p>\(parseInline(text))</p>\n"
            }
        }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Inline formatter
    // ─────────────────────────────────────────────────────────────────────

    private static func parseInline(_ raw: String) -> String {
        var slots: [String] = []
        var s     = ""
        var idx   = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx]
            if ch == "`" {
                var end = raw.index(after: idx)
                while end < raw.endIndex && raw[end] != "`" { end = raw.index(after: end) }
                if end < raw.endIndex {
                    let inner = escapeHTML(String(raw[raw.index(after: idx)..<end]))
                    s += "\u{FFFE}\(slots.count)\u{FFFF}"
                    slots.append("<code>\(inner)</code>")
                    idx = raw.index(after: end); continue
                }
            }
            switch ch {
            case "&":  s += "&amp;"
            case "<":  s += "&lt;"
            case ">":  s += "&gt;"
            case "\"": s += "&quot;"
            default:   s.append(ch)
            }
            idx = raw.index(after: idx)
        }

        let rules: [(String, String)] = [
            (#"\*\*\*(.+?)\*\*\*"#,        "<strong><em>$1</em></strong>"),
            (#"___(.+?)___"#,               "<strong><em>$1</em></strong>"),
            (#"\*\*(.+?)\*\*"#,             "<strong>$1</strong>"),
            (#"__(.+?)__"#,                 "<strong>$1</strong>"),
            (#"\*([^*\n]+)\*"#,             "<em>$1</em>"),
            (#"_([^_\n]+)_"#,              "<em>$1</em>"),
            (#"~~(.+?)~~"#,                 "<del>$1</del>"),
        ]
        for (pat, tmpl) in rules {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
        }
        // Images / links — only allow safe URL schemes
        if let imgRe = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
            s = replaceLinks(in: s, regex: imgRe) { alt, url in
                guard let safe = sanitizedURL(url) else { return escapeHTML(alt) }
                return "<img src=\"\(escapeHTML(safe))\" alt=\"\(escapeHTML(alt))\">"
            }
        }
        if let aRe = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
            s = replaceLinks(in: s, regex: aRe) { text, url in
                guard let safe = sanitizedURL(url) else { return escapeHTML(text) }
                return "<a href=\"\(escapeHTML(safe))\">\(text)</a>"
            }
        }
        for (n, code) in slots.enumerated() { s = s.replacingOccurrences(of: "\u{FFFE}\(n)\u{FFFF}", with: code) }
        return s
    }

    private static func replaceLinks(in s: String, regex: NSRegularExpression,
                                     build: (String, String) -> String) -> String {
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
        var result = s
        for m in matches {
            guard m.numberOfRanges >= 3,
                  let r0 = Range(m.range(at: 0), in: result),
                  let r1 = Range(m.range(at: 1), in: result),
                  let r2 = Range(m.range(at: 2), in: result) else { continue }
            let text = String(result[r1])
            let url  = String(result[r2])
            result.replaceSubrange(r0, with: build(text, url))
        }
        return result
    }

    /// Allow http(s), mailto and same-folder relative paths — block javascript:/data:,
    /// file:, absolute paths and ".." escapes. The preview's baseURL is the .md's
    /// parent folder, so "../" or "/etc/passwd" would otherwise exfiltrate local
    /// files via <img src>. Same-dir "pic.png"/"./pic.png" still renders.
    private static func sanitizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return trimmed }
        if trimmed.contains("\0") || trimmed.rangeOfCharacter(from: .controlCharacters) != nil { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("vbscript:") { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("../") || trimmed == ".." { return nil }
        if trimmed.split(separator: "/").contains("..") { return nil }
        if trimmed.hasPrefix("./") {
            let rest = String(trimmed.dropFirst(2))
            if rest.isEmpty || rest.contains(":") || rest.split(separator: "/").contains("..") { return nil }
            return trimmed
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            // Bare relative path like "notes.md" — same folder only.
            if !trimmed.contains(":") { return trimmed }
            return nil
        }
        switch scheme {
        case "http", "https", "mailto": return trimmed
        default: return nil
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Helpers
    // ─────────────────────────────────────────────────────────────────────

    private static func atxHeading(_ s: String) -> (Int, String)? {
        var lvl = 0
        for c in s { if c == "#" { lvl += 1 } else { break } }
        guard lvl >= 1, lvl <= 6 else { return nil }
        let rest = String(s.dropFirst(lvl)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : (lvl, rest)
    }
    private static func isHR(_ s: String) -> Bool {
        let c = s.filter { !$0.isWhitespace }
        guard c.count >= 3, let ch = c.first else { return false }
        return (ch == "-" || ch == "*" || ch == "_") && c.allSatisfy { $0 == ch }
    }
    private static func isULItem(_ l: String) -> Bool { l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") }
    private static func isOLItem(_ l: String) -> Bool { l.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }
    private static func isSepRow(_ l: String) -> Bool {
        let s = l.trimmingCharacters(in: .whitespaces)
        return s.contains("|") && s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }
    private static func tableRow(_ l: String) -> [String] {
        var s = l.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: HTML template  (Obsidian-inspired dark/light)
    // ─────────────────────────────────────────────────────────────────────

    private static func htmlTemplate(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        :root {
            --bg:      #ffffff;
            --surface: #f6f8fa;
            --border:  #d0d7de;
            --text:    #1f2328;
            --muted:   #57606a;
            --accent:  #2d52e0;
            --code-fg: #2d52e0;
            --code-bg: #eef1fe;
            --pre-bg:  #f6f8fa;
            --bq-bar:  #2d52e0;
            --bq-bg:   rgba(45,82,224,0.07);
            --th-bg:   #f0f2f5;
            --del-fg:  #cf222e;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg:      #1e1e2e;
                --surface: #181825;
                --border:  #45475a;
                --text:    #cdd6f4;
                --muted:   #a6adc8;
                --accent:  #7e9bff;
                --code-fg: #a6e3a1;
                --code-bg: #313244;
                --pre-bg:  #181825;
                --bq-bar:  #7e9bff;
                --bq-bg:   rgba(126,155,255,0.08);
                --th-bg:   #181825;
                --del-fg:  #f38ba8;
            }
        }

        html, body { background: var(--bg); color: var(--text);
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 16px; line-height: 1.75; }
        body { max-width: 820px; margin: 0 auto; padding: 36px 36px 80px; }
        ::selection { background: rgba(45,82,224,0.22); }
        @media (prefers-color-scheme: dark) {
            ::selection { background: rgba(126,155,255,0.35); }
        }

        h1,h2,h3,h4,h5,h6 { font-weight: 650; line-height: 1.3; margin: 1.6em 0 0.5em; }
        h1:first-child,h2:first-child { margin-top: 0; }
        h1 { font-size:2em;   border-bottom: 2px solid var(--border); padding-bottom:.3em; }
        h2 { font-size:1.5em; border-bottom: 1px solid var(--border); padding-bottom:.2em; }
        h3 { font-size:1.25em; } h4 { font-size:1.05em; }
        h5 { font-size:.95em; } h6 { font-size:.875em; color:var(--muted); }

        p { margin:.75em 0; }
        a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }
        strong { font-weight:700; } em { font-style:italic; }
        del { color:var(--del-fg); text-decoration:line-through; }

        code { font-family:"SF Mono",ui-monospace,"Cascadia Code",Consolas,monospace;
               font-size:.85em; background:var(--code-bg); color:var(--code-fg);
               padding:.15em .4em; border-radius:6px; border:1px solid var(--border); }
        pre { background:var(--pre-bg); border:1px solid var(--border); border-radius:8px;
              padding:18px 20px; overflow-x:auto; margin:1.1em 0; }
        pre code { background:transparent; border:none; padding:0; color:var(--text);
                   font-size:.875em; line-height:1.65; }

        blockquote { border-left:4px solid var(--bq-bar); background:var(--bq-bg);
                     margin:1em 0; padding:10px 18px; border-radius:0 8px 8px 0; }
        blockquote p { margin:0; color:var(--muted); }

        ul,ol { padding-left:1.8em; margin:.75em 0; } li { margin:.3em 0; }
        li > ul, li > ol { margin:.2em 0; }
        hr { border:none; border-top:1px solid var(--border); margin:2em 0; }

        table { border-collapse:collapse; width:100%; margin:1em 0; font-size:.9em;
                display:block; overflow-x:auto; }
        th,td { border:1px solid var(--border); padding:8px 14px; text-align:left; }
        th { background:var(--th-bg); font-weight:650; white-space:nowrap; }
        tr:nth-child(even) td { background:var(--surface); }

        img { max-width:100%; height:auto; border-radius:8px; margin:.5em 0; display:block; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
