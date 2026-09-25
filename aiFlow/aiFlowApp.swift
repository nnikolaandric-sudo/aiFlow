import SwiftUI
import ServiceManagement
import UserNotifications

@main
struct FinderFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var favorites = FavoritesService()
    @StateObject private var cloudFolders = CloudFoldersService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favorites)
                .environmentObject(cloudFolders)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            FinderFlowCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(cloudFolders)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Folder requested while launching before any window is ready (cold launch).
    /// ContentView consumes this on first appear.
    static var pendingNavigationURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Workspace reminders must banner + ring even with FinderFlow
        // frontmost — without a delegate the system delivers foreground
        // notifications silently (no banner, no sound).
        UNUserNotificationCenter.current().delegate = self
        UserPreferences.migrateBrowseDefaultsIfNeeded()
        // Finder ▸ Services: "Sign with FinderFlow" / "Verify E-Signature with
        // FinderFlow" (NSServices in Info.plist).
        NSApp.servicesProvider = ESignServiceProvider.shared
        NSUpdateDynamicServices()
        // Folder Rules: watched folders start sorting new files (FolderRules.swift).
        FolderRulesService.shared.start()
        // Version History: watch Workspace + chosen folders (VersionStore.swift).
        VersionStore.shared.start()
        // Mail integration: globalni ⌥⌘A picker (MailAttachService.swift).
        MailAttachService.shared.start()
        FileCommandPaletteWindowManager.shared.installShortcutMonitor()
        // Mail Inbox auto-sync (Settings ▸ Mail Inbox, off by default).
        MailInboxWatcher.shared.refresh()
        SecureShareManager.resumeIfConfigured()
        // Sync stored toggle with actual SMAppService registration state
        if #available(macOS 13.0, *) {
            let enabled = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show workspace reminders as banner + sound while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Cmd-Q never consults editor/markdown window delegates (verified by
    /// probe: windowShouldClose is NOT called on terminate), so dirty buffers
    /// would die silently. Intercept here: markdown parks termination until
    /// the user saves explicitly, the editor offers Save All (async → later).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // E-Sign windows with placed-but-unsaved signatures ask first.
        guard ESignWindowManager.shared.confirmQuitDiscardingPlacements() else { return .terminateCancel }
        if MarkdownWindowManager.shared.hasUnsavedChanges {
            MarkdownWindowManager.shared.activate()
            return .terminateCancel
        }
        guard EditorWindowManager.shared.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = "The code editor has unsaved changes."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            EditorWindowManager.shared.saveAllForQuit { ok in
                sender.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - Open folders / finderflow:// links

    /// Handles both file URLs (folder/file opened with FinderFlow, e.g. "Open With",
    /// `open -a`, or being the default folder handler) and the custom `finderflow://`
    /// scheme posted by the Finder Sync extension's "Open in FinderFlow" item.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleOpen(url) }
    }

    private func handleOpen(_ url: URL) {
        // Any app or web page can open a finderflow:// link, so those links only
        // reveal a location or toggle the local Workspace layer — they never
        // launch an app or open a document.
        let isSchemeLink = url.scheme == "finderflow"
        let host = url.host ?? ""
        let comps = isSchemeLink ? URLComponents(url: url, resolvingAgainstBaseURL: false) : nil
        let queryPath = comps?.queryItems?
            .first(where: { $0.name == "path" })?.value

        // Workspace Mode iz pravog Findera (FinderSync extension):
        // Enable pali projekat, Disable ga gasi i vraca normalan preview.
        if isSchemeLink, host == "enable-workspace" {
            guard let path = queryPath, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path) else { return }
            enableWorkspaceFromFinderLink(path: path)
            return
        }
        if isSchemeLink, host == "disable-workspace" {
            guard let path = queryPath, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path) else { return }
            disableWorkspaceFromFinderLink(path: path)
            return
        }

        let targetPath: String?
        if url.isFileURL {
            targetPath = url.path
        } else if isSchemeLink {
            targetPath = queryPath
        } else {
            targetPath = nil
        }

        guard let path = targetPath, path.hasPrefix("/") else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }

        let url = URL(fileURLWithPath: path)

        DispatchQueue.main.async {
            if isDir.boolValue && FileItem.isBrowsableFolder(url) {
                AppDelegate.pendingNavigationURL = url
                NotificationCenter.default.post(name: .navigateToPath, object: url)
            } else if isSchemeLink {
                let parent = url.deletingLastPathComponent()
                AppDelegate.pendingNavigationURL = parent
                NotificationCenter.default.post(name: .navigateToPath, object: parent)
            } else if isDir.boolValue {
                NSWorkspace.shared.open(url)
            } else if DefaultFolderHandler.isFileViewer {
                // We are the system file viewer: another app's "Show in
                // Finder" arrives as a plain open of the file (same event as
                // "Open With" — no reveal flag, checked on macOS 26). A file
                // manager answers it by showing the file selected in its folder.
                let parent = url.deletingLastPathComponent()
                AppDelegate.pendingNavigationURL = parent
                NotificationCenter.default.post(name: .ffRevealFile, object: url, userInfo: ["navigate": true])
                // Cold launch: the window subscribes a moment later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    NotificationCenter.default.post(name: .ffRevealFile, object: url, userInfo: ["navigate": true])
                }
            } else if url.pathExtension.lowercased() == "md" {
                // Markdown → rendered reader window (matches in-app double-click).
                MarkdownWindowManager.shared.open(url)
            } else if TextFileDetector.isEditableText(url) {
                // A text/code file opened with FinderFlow → open it in the editor window.
                EditorWindowManager.shared.open(url)
            } else {
                // Other files: reveal the enclosing folder.
                let parent = url.deletingLastPathComponent()
                AppDelegate.pendingNavigationURL = parent
                NotificationCenter.default.post(name: .navigateToPath, object: parent)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// finderflow://enable-workspace?path=… iz Findera: upali Workspace za
    /// folder (klik na fajl pali parent) i navigiraj na njega da se vidi.
    private func enableWorkspaceFromFinderLink(path: String) {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let folder: URL
        if isDir.boolValue {
            guard FileItem.isBrowsableFolder(url) else { return }
            folder = url
        } else {
            folder = url.deletingLastPathComponent()
            guard FileItem.isBrowsableFolder(folder) else { return }
        }
        DispatchQueue.main.async {
            WorkspaceStore.shared.enableWorkspace(at: folder)
            AppDelegate.pendingNavigationURL = folder
            NotificationCenter.default.post(name: .navigateToPath, object: folder)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// finderflow://disable-workspace?path=… iz Findera: ugasi Workspace i
    /// vrati normalan preview (podaci projekta se brisu, fajlovi ostaju).
    /// Klik na fajl unutar workspacea gasi enclosing workspace.
    private func disableWorkspaceFromFinderLink(path: String) {
        let url = URL(fileURLWithPath: path)
        DispatchQueue.main.async {
            let store = WorkspaceStore.shared
            if store.isWorkspace(url) {
                store.disableWorkspace(at: url)
                AppDelegate.pendingNavigationURL = url
                NotificationCenter.default.post(name: .navigateToPath, object: url)
            } else if let found = store.enclosingWorkspace(for: url) {
                store.disableWorkspace(at: found.root)
                AppDelegate.pendingNavigationURL = found.root
                NotificationCenter.default.post(name: .navigateToPath, object: found.root)
            } else {
                // Nije workspace — samo otvori lokaciju.
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
                AppDelegate.pendingNavigationURL = folder
                NotificationCenter.default.post(name: .navigateToPath, object: folder)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct FinderFlowCommands: Commands {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage(UserPreferences.viewModeKey) private var viewModeRaw = UserPreferences.defaultViewMode.rawValue
    @AppStorage(UserPreferences.showHiddenKey) private var showHidden = false
    @AppStorage(UserPreferences.showPreviewKey) private var showPreview = false
    @AppStorage(UserPreferences.showFolderSizesKey) private var showFolderSizes = false
    @AppStorage(UserPreferences.compactDensityKey) private var compactDensity = false

    var body: some Commands {
        // ── File: app-specific actions appended after the standard New group.
        // (Was CommandMenu("File") — that created a SECOND File menu next to
        // the system one. CommandGroup merges into the existing menu.)
        CommandGroup(after: .newItem) {
            Button("New Folder") {
                NotificationCenter.default.post(name: .createNewFolder, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Text File") {
                NotificationCenter.default.post(name: .createNewFile, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Move to Trash") {
                NotificationCenter.default.post(name: .ffTrashSelected, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Get Info") {
                NotificationCenter.default.post(name: .ffShowInfo, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("Send via Mail…") {
                NotificationCenter.default.post(name: .ffSendViaMail, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Attach from aiFlow…") {
                NotificationCenter.default.post(name: .ffAttachFromFinderFlow, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Search Files…") {
                NotificationCenter.default.post(name: .ffOpenFilePalette, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Show Open/Save Assistant") {
                NotificationCenter.default.post(name: .ffShowPanelAssistant, object: nil)
            }
            Divider()
            Button("Organize with AI…") {
                NotificationCenter.default.post(name: .ffAIOrganize, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Sign Document…") {
                ESignWindowManager.shared.signFromMenu()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Shared Files…") {
                SecureShareWindowManager.shared.open()
            }
            Button("Copy Quick Link (24h)") {
                NotificationCenter.default.post(name: .ffQuickLink, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Mail Inbox…") {
                MailInboxWindowManager.shared.open()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            // Today (TodayView.swift): tasks, reminders, reviews, mail, sorts.
            Button("Today") {
                TodayWindowManager.shared.open()
            }
            .keyboardShortcut("0", modifiers: .command)
            // PDF Tools (PDFTools.swift): the selection, else an empty window.
            Button("PDF Tools…") {
                let sel = FFSelectionRequest.current(preferring: NSApp.keyWindow).selection
                PDFToolsWindowManager.shared.open(tool: nil, urls: sel)
            }
        }
        // ── Go (Finder-style navigation) ────────────────────────────
        CommandMenu("Go") {
            Button("Back") {
                NotificationCenter.default.post(name: .ffGoBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)
            Button("Forward") {
                NotificationCenter.default.post(name: .ffGoForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)
            Button("Enclosing Folder") {
                NotificationCenter.default.post(name: .ffGoUp, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button("Go to Folder…") {
                NotificationCenter.default.post(name: .ffGoToFolder, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        // ── Tab (browser tabs: vise foldera u jednom prozoru) ──────
        CommandMenu("Tab") {
            Button("New Tab") {
                NotificationCenter.default.post(name: .ffNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") {
                NotificationCenter.default.post(name: .ffCloseTab, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") {
                NotificationCenter.default.post(name: .ffNextTab, object: nil)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") {
                NotificationCenter.default.post(name: .ffPrevTab, object: nil)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        // ── Git (Git-aware filesystem: status je dio browsera, ne nova app) ──
        CommandMenu("Git") {
            Button("View Changes") {
                NotificationCenter.default.post(name: .ffGitDiffCurrent, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            Button("Repository Status") {
                NotificationCenter.default.post(name: .ffGitRepoCurrent, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("History") {
                NotificationCenter.default.post(name: .ffGitHistoryCurrent, object: nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
        }
        // ── View: appended after the standard toolbar-visibility group.
        // (Was CommandMenu("View") — duplicate View menu. Merged instead.)
        CommandGroup(after: .toolbar) {
            // ⌘K: every action, place and task in one fuzzy list (CommandPalette.swift).
            Button("Command Palette…") {
                CommandPaletteController.shared.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("as List") { viewModeRaw = ViewMode.list.rawValue }
                .keyboardShortcut("1", modifiers: .command)
            Button("as Icons") { viewModeRaw = ViewMode.icons.rawValue }
                .keyboardShortcut("2", modifiers: .command)
            Button("as Columns") { viewModeRaw = ViewMode.columns.rawValue }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Toggle("Show Hidden Files", isOn: $showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Show Preview", isOn: $showPreview)
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("Calculate Folder Sizes", isOn: $showFolderSizes)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Toggle("Compact Rows", isOn: $compactDensity)
            Divider()
            Button("Refresh") {
                NotificationCenter.default.post(name: .ffRefresh, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        // ── App extras: Check for Updates + Launch at Login, right after
        // About FinderFlow. (Was CommandMenu("FinderFlow") — duplicate app menu.)
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { @MainActor in
                    await UpdateManager.shared.checkForUpdates(force: true)
                }
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    if #available(macOS 13.0, *) {
                        do {
                            if newValue { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    } else {
                        launchAtLogin = newValue
                    }
                }
            ))
        }

        // ── Help: keyboard shortcuts reference in its own window.
        // (Creates the Help menu; ⌘H stays the system Hide.)
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                ShortcutsWindowManager.shared.open()
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let createNewFolder   = Notification.Name("createNewFolder")
    static let createNewFile     = Notification.Name("createNewFile")
    static let toggleHiddenFiles = Notification.Name("toggleHiddenFiles")
    static let navigateToPath    = Notification.Name("navigateToPath")
    static let refreshDirectory  = Notification.Name("FinderFlow.refreshDirectory")
    static let ffCopyPathFeedback = Notification.Name("FF.copyPathFeedback")
    static let ffTrashSelected   = Notification.Name("FF.trashSelected")
    static let ffShowInfo        = Notification.Name("FF.showInfo")
    static let ffSendViaMail     = Notification.Name("FF.sendViaMail")
    static let ffQuickLink       = Notification.Name("FF.quickLink")
    static let ffQuickLinkStarted = Notification.Name("FF.quickLinkStarted")
    static let ffQuickLinkFeedback = Notification.Name("FF.quickLinkFeedback")
    static let ffAttachFromFinderFlow = Notification.Name("FF.attachFromFinderFlow")
    static let ffOpenFilePalette     = Notification.Name("FF.openFilePalette")
    static let ffOpenPaletteURL      = Notification.Name("FF.openPaletteURL")
    static let ffShowPanelAssistant = Notification.Name("FF.showPanelAssistant")
    static let ffGoBack          = Notification.Name("FF.goBack")
    static let ffGoForward       = Notification.Name("FF.goForward")
    static let ffGoUp            = Notification.Name("FF.goUp")
    static let ffGoToFolder      = Notification.Name("FF.goToFolder")
    static let ffRefresh         = Notification.Name("FF.refresh")
    static let ffAIOrganize      = Notification.Name("FF.aiOrganize")
    static let ffGitDiffCurrent    = Notification.Name("FF.gitDiffCurrent")
    static let ffGitHistoryCurrent = Notification.Name("FF.gitHistoryCurrent")
    static let ffGitRepoCurrent    = Notification.Name("FF.gitRepoCurrent")
    static let ffNewTab          = Notification.Name("FF.newTab")
    static let ffCloseTab        = Notification.Name("FF.closeTab")
    static let ffNextTab         = Notification.Name("FF.nextTab")
    static let ffPrevTab         = Notification.Name("FF.prevTab")
    static let ffOpenInNewTab    = Notification.Name("FF.openInNewTab")
    /// Objavljuje svako mesto koje pise STRING u pasteboard (Copy Path,
    /// Copy diagnostics…) — ponistava i cut i kes URL-ova, pa FileOperations
    /// osvezava kes da Paste ne bi zalepio ustajale fajlove.
    static let ffExternalPasteboardWrite = Notification.Name("FF.externalPasteboardWrite")
    static let ffFileURLsPasteboardWrite = Notification.Name("FF.fileURLsPasteboardWrite")
}
