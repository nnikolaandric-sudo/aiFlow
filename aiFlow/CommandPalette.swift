import AppKit
import SwiftUI

// MARK: - Command palette (⌘K)
//
// Every action in one fuzzy list: menu commands (most live only in ⋯ or a
// right-click since the toolbar went from 30 to 15 buttons), actions for the
// current selection (PDF tools, sign, share, task…), places (Favorites,
// pinned, recent folders, workspaces) and open workspace tasks. Typing
// matches English titles and Bosnian/Croatian/Serbian keywords ("spoji pdf",
// "danas", "potpiši").
//
// Commands reuse the notifications the menus post, so the palette can't
// drift from what the menu does. The browser's selection comes from
// FFSelectionBridge (one modifier on ContentView).

// MARK: Selection bridge

/// Asks the browser window for its selection and folder, synchronously
/// (same pattern as ESignMenuRequest). `preferredWindow` picks the window
/// the user was in when there are several.
final class FFSelectionRequest {
    var handled = false
    var selection: [URL] = []
    var folder: URL?
    weak var preferredWindow: NSWindow?

    static func current(preferring window: NSWindow?) -> FFSelectionRequest {
        let req = FFSelectionRequest()
        req.preferredWindow = window
        NotificationCenter.default.post(name: .ffSelectionRequest, object: req)
        if !req.handled, window != nil {
            // The preferred window isn't a browser (e.g. Today was key).
            req.preferredWindow = nil
            NotificationCenter.default.post(name: .ffSelectionRequest, object: req)
        }
        return req
    }
}

extension Notification.Name {
    static let ffSelectionRequest = Notification.Name("FF.selectionRequest")
}

private final class FFWeakWindow {
    weak var value: NSWindow?
}

private struct FFWindowReader: NSViewRepresentable {
    let box: FFWeakWindow
    func makeNSView(context: Context) -> NSView { ReaderView(box: box) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        let box: FFWeakWindow
        init(box: FFWeakWindow) { self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box.value = window
        }
    }
}

/// Attach to the browser view: answers FFSelectionRequest with the current
/// selection and folder. Closures are read at request time, never in body.
struct FFSelectionBridge: ViewModifier {
    let selection: () -> [URL]
    let folder: () -> URL
    @State private var window = FFWeakWindow()

    func body(content: Content) -> some View {
        content
            .background(FFWindowReader(box: window))
            .onReceive(NotificationCenter.default.publisher(for: .ffSelectionRequest)) { n in
                guard let req = n.object as? FFSelectionRequest, !req.handled else { return }
                if let want = req.preferredWindow, let mine = window.value, want !== mine { return }
                req.handled = true
                req.selection = selection()
                req.folder = folder()
            }
    }
}

// MARK: Items

struct PaletteItem: Identifiable {
    enum Group: Int, CaseIterable {
        case selection, actions, places, workspaces, tasks

        var title: String {
            switch self {
            case .selection: return "Selection"
            case .actions: return "Actions"
            case .places: return "Places"
            case .workspaces: return "Workspaces"
            case .tasks: return "Tasks"
            }
        }
    }

    let id: String
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var shortcut: String? = nil
    let group: Group
    /// Extra words that should find this item (synonyms, local language).
    var keywords: String = ""
    let run: @MainActor () -> Void
}

@MainActor
enum PaletteCatalog {
    /// Everything the palette can do right now, for this selection.
    static func items(selection: [URL], folder: URL?) -> [PaletteItem] {
        var out: [PaletteItem] = []
        out += selectionItems(selection, folder: folder)
        out += actionItems(folder: folder)
        out += placeItems()
        out += workspaceItems()
        return out
    }

    private static func post(_ name: Notification.Name, _ object: Any? = nil) -> @MainActor () -> Void {
        { NotificationCenter.default.post(name: name, object: object); FFMainWindow.bringToFront() }
    }

    private static func quoted(_ urls: [URL], noun: String) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) \(noun)"
    }

    // MARK: Selection

    private static func selectionItems(_ sel: [URL], folder: URL?) -> [PaletteItem] {
        var out: [PaletteItem] = []
        if !sel.isEmpty {
            for tool in PDFTool.allCases where tool.accepts(sel) {
                let what: String
                switch tool {
                case .combine: what = "Combine \(sel.count) Files into PDF…"
                case .imagesToPDF: what = sel.count == 1 ? "Convert \(quoted(sel, noun: "images")) to PDF…" : "Combine \(sel.count) Images into PDF…"
                default: what = "\(tool.title) — \(quoted(sel, noun: "files"))…"
                }
                out.append(PaletteItem(id: "pdf.\(tool.rawValue)", title: what, symbol: tool.symbol,
                                       group: .selection, keywords: pdfKeywords(tool)) {
                    PDFToolsWindowManager.shared.open(tool: tool, urls: sel)
                })
            }
            let signable = sel.filter(ESignSource.canSign)
            if !signable.isEmpty {
                out.append(PaletteItem(id: "sel.sign", title: "Sign \(quoted(signable, noun: "documents"))…",
                                       symbol: "signature", shortcut: "⌥⌘E", group: .selection,
                                       keywords: "e-sign potpis potpisi potpiši signature") {
                    ESignWindowManager.shared.open(signable)
                })
            }
            out.append(PaletteItem(id: "sel.share", title: "Share \(quoted(sel, noun: "items")) with a Secure Link…",
                                   symbol: "link", group: .selection, keywords: "link podijeli dijeli share secure") {
                SecureShareWindowManager.shared.open(urls: sel)
            })
            if sel.count == 1 {
                out.append(PaletteItem(id: "sel.task", title: "Add Task to \(quoted(sel, noun: ""))…",
                                       symbol: "checklist", group: .selection, keywords: "zadatak task todo workspace") {
                    WorkspaceComposer.requestTask(for: sel[0]); FFMainWindow.bringToFront()
                })
                out.append(PaletteItem(id: "sel.reminder", title: "Add Reminder to \(quoted(sel, noun: ""))…",
                                       symbol: "bell", group: .selection, keywords: "podsjetnik podsetnik reminder") {
                    WorkspaceComposer.requestReminder(for: sel[0]); FFMainWindow.bringToFront()
                })
            }
            if sel.count == 1, VersionStore.shared.family(for: sel[0]) != nil || VersionStore.shared.isTracked(sel[0]) {
                let v = VersionStore.shared.label(for: sel[0]).map { " (\($0))" } ?? ""
                out.append(PaletteItem(id: "sel.versions", title: "Version History of \(quoted(sel, noun: ""))\(v)…",
                                       symbol: "clock.arrow.circlepath", group: .selection,
                                       keywords: "verzije historija istorija version history restore vrati") {
                    VersionHistoryWindowManager.shared.open(sel[0])
                })
            }
            out.append(PaletteItem(id: "sel.copypath", title: "Copy Path of \(quoted(sel, noun: "items"))",
                                   symbol: "doc.on.clipboard", group: .selection, keywords: "putanja kopiraj path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(sel.map(\.path).joined(separator: "\n"), forType: .string)
                NotificationCenter.default.post(name: .ffExternalPasteboardWrite, object: nil)
                NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
            })
        }
        if let folder {
            let name = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
            out.append(PaletteItem(id: "folder.rules", title: "Auto-Sort Rules for “\(name)”…",
                                   symbol: "wand.and.stars", group: .selection,
                                   keywords: "folder rules pravila sortiraj sredi automatski hazel") {
                FolderRulesWindowManager.shared.open(folder)
            })
            let isWorkspace = WorkspaceStore.shared.isWorkspace(folder)
            if !isWorkspace {
                let tracking = VersionStore.shared.isUserFolder(folder)
                out.append(PaletteItem(id: "folder.versions",
                                       title: tracking ? "Stop Tracking Versions in “\(name)”" : "Track Versions in “\(name)”",
                                       symbol: "clock.arrow.circlepath", group: .selection,
                                       keywords: "verzije historija version history prati")
                {
                    VersionStore.shared.setFolderTracked(folder, !tracking)
                })
            }
            out.append(PaletteItem(id: "folder.workspace",
                                   title: isWorkspace ? "Disable Workspace on “\(name)”" : "Enable Workspace on “\(name)”",
                                   symbol: isWorkspace ? "briefcase.fill" : "briefcase", group: .selection,
                                   keywords: "projekat project workspace radni prostor") {
                if isWorkspace {
                    WorkspaceStore.shared.disableWorkspace(at: folder)
                } else {
                    _ = WorkspaceStore.shared.enableWorkspace(at: folder)
                }
                FFMainWindow.bringToFront()
            })
        }
        return out
    }

    private static func pdfKeywords(_ tool: PDFTool) -> String {
        switch tool {
        case .combine: return "pdf merge spoji spajanje sastavi join"
        case .imagesToPDF: return "pdf slike slika image jpg png scan skeniraj"
        case .split: return "pdf razdvoji podijeli stranice split"
        case .extractPages: return "pdf izdvoji stranice extract"
        case .rotate: return "pdf rotiraj okreni zarotiraj"
        case .compress: return "pdf smanji kompresuj velicina compress shrink"
        case .makeSearchable: return "pdf ocr pretrazivo prepoznaj tekst skeniran scan searchable"
        }
    }

    // MARK: Actions

    private static func actionItems(folder: URL?) -> [PaletteItem] {
        let d = UserDefaults.standard
        func toggle(_ key: String, _ title: String, _ symbol: String, _ shortcut: String?, _ kw: String, default def: Bool = false) -> PaletteItem {
            let on = d.object(forKey: key) as? Bool ?? def
            return PaletteItem(id: "toggle.\(key)", title: (on ? "Hide " : "Show ") + title, symbol: symbol,
                               shortcut: shortcut, group: .actions, keywords: kw) {
                d.set(!on, forKey: key)
            }
        }
        func view(_ mode: ViewMode, _ title: String, _ symbol: String, _ key: String) -> PaletteItem {
            PaletteItem(id: "view.\(mode.rawValue)", title: "View as \(title)", symbol: symbol,
                        shortcut: key, group: .actions, keywords: "prikaz view") {
                d.set(mode.rawValue, forKey: UserPreferences.viewModeKey)
            }
        }
        var out: [PaletteItem] = [
            PaletteItem(id: "today", title: "Today", subtitle: "Tasks, reminders, reviews and mail that need you",
                        symbol: "sun.max", shortcut: "⌘0", group: .actions,
                        keywords: "danas today agenda rokovi zadaci podsjetnici dashboard") {
                TodayWindowManager.shared.open()
            },
            PaletteItem(id: "pdf.tools", title: "PDF Tools…", symbol: "doc.richtext", group: .actions,
                        keywords: "pdf spoji ocr kompresuj rotiraj razdvoji alati") {
                PDFToolsWindowManager.shared.open(tool: .combine, urls: [])
            },
            PaletteItem(id: "new.folder", title: "New Folder", symbol: "folder.badge.plus", shortcut: "⇧⌘N",
                        group: .actions, keywords: "novi folder mapa napravi", run: post(.createNewFolder)),
            PaletteItem(id: "new.file", title: "New Text File", symbol: "doc.badge.plus", shortcut: "⌥⌘N",
                        group: .actions, keywords: "novi fajl tekst datoteka", run: post(.createNewFile)),
            PaletteItem(id: "trash", title: "Move to Trash", symbol: "trash", shortcut: "⌘⌫",
                        group: .actions, keywords: "obrisi smece kanta delete", run: post(.ffTrashSelected)),
            PaletteItem(id: "info", title: "Get Info", symbol: "info.circle", shortcut: "⌘I",
                        group: .actions, keywords: "informacije info", run: post(.ffShowInfo)),
            PaletteItem(id: "mail.send", title: "Send via Mail…", symbol: "envelope", shortcut: "⇧⌘M",
                        group: .actions, keywords: "posalji mail email", run: post(.ffSendViaMail)),
            PaletteItem(id: "mail.attach", title: "Attach from aiFlow…", symbol: "paperclip", shortcut: "⌥⌘A",
                        group: .actions, keywords: "prilozi prilog attach", run: post(.ffAttachFromFinderFlow)),
            PaletteItem(id: "mail.inbox", title: "Mail Inbox…", symbol: "tray.full", shortcut: "⌥⌘M",
                        group: .actions, keywords: "posta inbox mail racuni") {
                MailInboxWindowManager.shared.open()
            },
            PaletteItem(id: "ai.organize", title: "Organize with AI…", symbol: "sparkles", shortcut: "⌥⌘O",
                        group: .actions, keywords: "ai organizuj sredi", run: post(.ffAIOrganize)),
            PaletteItem(id: "sign", title: "Sign Document…", symbol: "signature", shortcut: "⌥⌘E",
                        group: .actions, keywords: "potpis potpisi e-sign") {
                ESignWindowManager.shared.signFromMenu()
            },
            PaletteItem(id: "shared", title: "Shared Files…", symbol: "link", group: .actions,
                        keywords: "dijeljeni linkovi share") {
                SecureShareWindowManager.shared.open()
            },
            PaletteItem(id: "quicklink", title: "Copy Quick Link (24h)", symbol: "link.badge.plus", shortcut: "⌥⌘L",
                        group: .actions, keywords: "link brzi", run: post(.ffQuickLink)),
            PaletteItem(id: "go.back", title: "Back", symbol: "chevron.left", shortcut: "⌘[",
                        group: .actions, keywords: "nazad", run: post(.ffGoBack)),
            PaletteItem(id: "go.forward", title: "Forward", symbol: "chevron.right", shortcut: "⌘]",
                        group: .actions, keywords: "naprijed", run: post(.ffGoForward)),
            PaletteItem(id: "go.up", title: "Enclosing Folder", symbol: "arrow.up", shortcut: "⌘↑",
                        group: .actions, keywords: "gore roditelj parent", run: post(.ffGoUp)),
            PaletteItem(id: "go.folder", title: "Go to Folder…", symbol: "arrow.right.to.line", shortcut: "⇧⌘G",
                        group: .actions, keywords: "idi putanja path", run: post(.ffGoToFolder)),
            PaletteItem(id: "tab.new", title: "New Tab", symbol: "plus.square.on.square", shortcut: "⌘T",
                        group: .actions, keywords: "novi tab kartica", run: post(.ffNewTab)),
            PaletteItem(id: "tab.close", title: "Close Tab", symbol: "xmark.square", shortcut: "⇧⌘W",
                        group: .actions, keywords: "zatvori tab", run: post(.ffCloseTab)),
            PaletteItem(id: "git.diff", title: "Git: View Changes", symbol: "plusminus", shortcut: "⌥⌘G",
                        group: .actions, keywords: "git diff promjene", run: post(.ffGitDiffCurrent)),
            PaletteItem(id: "git.status", title: "Git: Repository Status", symbol: "arrow.triangle.branch",
                        group: .actions, keywords: "git status repo", run: post(.ffGitRepoCurrent)),
            PaletteItem(id: "git.history", title: "Git: History", symbol: "clock.arrow.circlepath", shortcut: "⌥⌘H",
                        group: .actions, keywords: "git log istorija historija", run: post(.ffGitHistoryCurrent)),
            view(.list, "List", "list.bullet", "⌘1"),
            view(.icons, "Icons", "square.grid.2x2", "⌘2"),
            view(.columns, "Columns", "rectangle.split.3x1", "⌘3"),
            toggle(UserPreferences.showHiddenKey, "Hidden Files", "eye.slash", "⇧⌘.", "skriveni hidden"),
            toggle(UserPreferences.showPreviewKey, "Preview", "sidebar.right", "⌥⌘P", "pregled preview"),
            toggle(UserPreferences.showFolderSizesKey, "Folder Sizes", "externaldrive", "⌥⌘S", "velicina foldera size"),
            PaletteItem(id: "refresh", title: "Refresh", symbol: "arrow.clockwise", shortcut: "⌘R",
                        group: .actions, keywords: "osvjezi reload", run: post(.ffRefresh)),
            PaletteItem(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: "⌘,",
                        group: .actions, keywords: "postavke podesavanja preferences") {
                openSettings()
            },
            PaletteItem(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", shortcut: "⇧⌘/",
                        group: .actions, keywords: "precice tastatura") {
                ShortcutsWindowManager.shared.open()
            },
            PaletteItem(id: "updates", title: "Check for Updates…", symbol: "arrow.down.circle", group: .actions,
                        keywords: "azuriranje update nova verzija") {
                Task { @MainActor in await UpdateManager.shared.checkForUpdates(force: true) }
            },
        ]
        // Folder-dependent entries need a browser folder to act on.
        if folder == nil {
            out.removeAll { ["trash", "info", "new.folder", "new.file"].contains($0.id) }
        }
        return out
    }

    /// The SwiftUI Settings scene has no public AppKit entry point
    /// (showSettingsWindow: is refused on macOS 14+), so press the menu item.
    private static func openSettings() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        appMenu.performActionForItem(at: i)
    }

    // MARK: Places

    private static func placeItems() -> [PaletteItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var seen = Set<String>()
        var out: [PaletteItem] = []
        func add(_ url: URL, kind: String, symbol: String) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted, fm.fileExists(atPath: key) else { return }
            let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
            out.append(PaletteItem(id: "place.\(key)", title: url.lastPathComponent,
                                   subtitle: "\(kind) · \(parent)", symbol: symbol, group: .places,
                                   keywords: kind.lowercased() + " folder idi") {
                FFMainWindow.open(folder: url)
            })
        }
        let system: [(String, String)] = [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"),
                                          ("Downloads", "arrow.down.circle")]
        add(home, kind: "Home", symbol: "house")
        for (name, symbol) in system { add(home.appendingPathComponent(name), kind: "Favorite", symbol: symbol) }
        add(URL(fileURLWithPath: "/Applications"), kind: "Favorite", symbol: "square.grid.3x3")
        for p in UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [] {
            add(URL(fileURLWithPath: p), kind: "Pinned", symbol: "pin")
        }
        for p in (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []).prefix(15) {
            add(URL(fileURLWithPath: p), kind: "Recent", symbol: "clock")
        }
        return out
    }

    // MARK: Workspaces + tasks

    private static func workspaceItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        for ws in WorkspaceStore.shared.workspaces {
            let root = URL(fileURLWithPath: ws.rootPath, isDirectory: true)
            let open = ws.openTasks.count
            out.append(PaletteItem(id: "ws.\(ws.id)", title: ws.name,
                                   subtitle: "Workspace · \(ws.status)" + (open > 0 ? " · \(open) open task\(open == 1 ? "" : "s")" : ""),
                                   symbol: "briefcase", group: .workspaces, keywords: "workspace projekat") {
                FFMainWindow.open(folder: root)
            })
            for t in ws.openTasks {
                let due = t.dueDate.map { " · due " + $0.formatted(.dateTime.day().month(.abbreviated)) } ?? ""
                out.append(PaletteItem(id: "task.\(ws.id).\(t.id)", title: t.title,
                                       subtitle: "Task in \(ws.name)\(due)",
                                       symbol: t.isOverdue ? "exclamationmark.circle" : "circle",
                                       group: .tasks, keywords: "task zadatak") {
                    if let rel = t.linkedFile {
                        FFMainWindow.reveal(root.appendingPathComponent(rel))
                    } else {
                        FFMainWindow.open(folder: root)
                    }
                })
            }
        }
        return out
    }
}

// MARK: - Model

@MainActor
final class CommandPaletteModel: ObservableObject {
    @Published var query = "" { didSet { recompute() } }
    @Published private(set) var results: [PaletteItem] = []
    @Published var highlighted = 0

    private let all: [PaletteItem]
    /// Folded words of title + keywords + subtitle, per item (same order).
    private let words: [[String]]
    let selectionCount: Int
    private static let recentKey = "ffPaletteRecent"

    init(items: [PaletteItem], selectionCount: Int) {
        self.all = items
        self.words = items.map { Self.foldedWords([$0.title, $0.keywords, $0.subtitle ?? ""].joined(separator: " ")) }
        self.selectionCount = selectionCount
        recompute()
    }

    /// "Potpiši PDF…" → ["potpisi", "pdf"] (case and diacritics folded).
    static func foldedWords(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Empty query: selection actions, recently used, Today, then places.
    /// Typed: fuzzy over the title, word prefixes over keywords/subtitle
    /// (fuzzy there matched "pdf" in "podesavanja preferences"). Groups stay
    /// contiguous: actions for the selection first whenever any matches,
    /// then the other groups by their best hit.
    private func recompute() {
        let q = query.trimmingCharacters(in: .whitespaces)
        highlighted = 0
        if q.isEmpty {
            let recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
            var out = all.filter { $0.group == .selection }
            let ids = Set(out.map(\.id))
            out += recent.compactMap { id in all.first { $0.id == id && !ids.contains(id) } }
            if !out.contains(where: { $0.id == "today" }), let today = all.first(where: { $0.id == "today" }) {
                out.append(today)
            }
            let shown = Set(out.map(\.id))
            out += all.filter { $0.group == .places && !shown.contains($0.id) }.prefix(6)
            results = out
            return
        }
        let terms = Self.foldedWords(q)
        var scored: [(item: PaletteItem, score: Int)] = []
        for (i, item) in all.enumerated() {
            let byTitle = FuzzySearch.score(query: q, name: item.title)
            let byWords = !terms.isEmpty && terms.allSatisfy { t in words[i].contains { $0.hasPrefix(t) } }
                ? 6 : nil
            guard let best = [byTitle, byWords].compactMap({ $0 }).min() else { continue }
            scored.append((item, best))
        }
        let byItem: (PaletteItem, Int, PaletteItem, Int) -> Bool = { a, sa, b, sb in
            sa != sb ? sa < sb : a.title.count < b.title.count
        }
        var groupBest: [PaletteItem.Group: Int] = [:]
        for s in scored {
            let bias = s.item.group == .selection ? -100_000 : 0
            groupBest[s.item.group] = min(groupBest[s.item.group] ?? .max, s.score + bias)
        }
        scored.sort { a, b in
            if a.item.group != b.item.group {
                let ga = groupBest[a.item.group]!, gb = groupBest[b.item.group]!
                return ga != gb ? ga < gb : a.item.group.rawValue < b.item.group.rawValue
            }
            return byItem(a.item, a.score, b.item, b.score)
        }
        results = scored.prefix(60).map(\.item)
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    /// Runs the item after the panel is gone, so sheets and new windows
    /// land in front of the browser, not behind the palette.
    func run(_ item: PaletteItem, close: () -> Void) {
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if item.group != .selection {
            recent.removeAll { $0 == item.id }
            recent.insert(item.id, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(6)), forKey: Self.recentKey)
        }
        close()
        Task { @MainActor in item.run() }
    }

    func runHighlighted(close: () -> Void) {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted], close: close)
    }
}

// MARK: - Panel

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    static let shared = CommandPaletteController()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.close(); return }
        show()
    }

    func show() {
        let origin = NSApp.keyWindow ?? NSApp.mainWindow
        let req = FFSelectionRequest.current(preferring: origin)
        let items = PaletteCatalog.items(selection: req.selection, folder: req.folder)
        let model = CommandPaletteModel(items: items, selectionCount: req.selection.count)
        let view = CommandPaletteView(model: model) { [weak self] in self?.panel?.close() }

        let panel = self.panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 620, height: 420))
        position(panel, over: origin)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                                 styleMask: [.titled, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.delegate = self
        return panel
    }

    /// Upper third of the window the user was in (Spotlight-like).
    private func position(_ panel: NSPanel, over window: NSWindow?) {
        let frame = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - frame.height * 0.18 - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: max(frame.minY + 20, y)))
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.close()
    }
}

// MARK: - View

struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel
    var close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($fieldFocused)
                    .onSubmit { model.runHighlighted(close: close) }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            if model.results.isEmpty {
                VStack(spacing: 6) {
                    Text("No matches").foregroundStyle(.secondary)
                    Text("Try an action (“combine”, “spoji”), a folder or a task.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                results
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .frame(width: 620, height: 420)
        .onAppear { fieldFocused = true }
    }

    private var placeholder: String {
        model.selectionCount > 0
            ? "Search actions for \(model.selectionCount) selected item\(model.selectionCount == 1 ? "" : "s"), places, tasks…"
            : "Search actions, places, workspaces, tasks…"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, item in
                        if showsHeader(at: i) {
                            Text(headerTitle(at: i))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 18).padding(.top, i == 0 ? 8 : 12).padding(.bottom, 4)
                        }
                        row(item, highlighted: i == model.highlighted)
                            .id(item.id)
                            .onTapGesture { model.run(item, close: close) }
                            .onHover { if $0 { model.highlighted = i } }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.highlighted) { _, i in
                guard model.results.indices.contains(i) else { return }
                proxy.scrollTo(model.results[i].id)
            }
        }
    }

    /// Empty query shows "Suggested"; typed results show their groups.
    private func showsHeader(at i: Int) -> Bool {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty { return i == 0 }
        return i == 0 || model.results[i].group != model.results[i - 1].group
    }

    private func headerTitle(at i: Int) -> String {
        model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "Suggested" : model.results[i].group.title
    }

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(highlighted ? Color.white : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let sub = item.subtitle {
                    Text(sub).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.8) : .secondary)
                }
            }
            Spacer(minLength: 8)
            if let key = item.shortcut {
                Text(key)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("to select", systemImage: "arrow.up.arrow.down")
            Label("to run", systemImage: "return")
            Label("to close", systemImage: "escape")
            Spacer()
            Text("⌘K").font(.system(size: 11, design: .rounded))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(PaletteHintLabelStyle())
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
}

private struct PaletteHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}
