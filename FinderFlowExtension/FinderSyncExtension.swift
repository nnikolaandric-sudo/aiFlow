import Cocoa
import FinderSync

class FinderSyncExtension: FIFinderSync {

    override init() {
        super.init()
        let fm = FileManager.default
        FIFinderSyncController.default().directoryURLs = Set([
            fm.homeDirectoryForCurrentUser,
            fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
        ].compactMap { $0 })
    }

    // MARK: - Toolbar

    override var toolbarItemName: String { "aiFlow" }

    override var toolbarItemToolTip: String { "aiFlow: Enhanced file management" }

    override var toolbarItemImage: NSImage {
        // Cached: Finder queries this per redraw; avoid allocating per access.
        Self.cachedToolbarImage
    }

    private static let cachedToolbarImage: NSImage = {
        NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "aiFlow")
            ?? NSImage(named: NSImage.folderName)!
    }()

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: "New Folder Here",  action: #selector(createFolderHere), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path",         action: #selector(copyPath),         keyEquivalent: "")
        menu.addItem(withTitle: "Open in Terminal",  action: #selector(openInTerminal),   keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open in aiFlow", action: #selector(openInFinderFlow), keyEquivalent: "")
        menu.addItem(.separator())
        // Workspace Mode: Moj Workspace dugme u pravom Finderu.
        // Extension ne zna da li je folder vec workspace (poseban proces),
        // pa nudi oba: Enable pali projekat, Disable ga gasi i vraca
        // normalan preview. Glavna app resava idempotentno.
        menu.addItem(withTitle: "Enable Workspace",  action: #selector(enableWorkspace),  keyEquivalent: "")
        menu.addItem(withTitle: "Disable Workspace", action: #selector(disableWorkspace), keyEquivalent: "")
        return menu
    }

    @objc private func createFolderHere() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        let folder = uniqueURL(for: target.appendingPathComponent("New Folder"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @objc private func copyPath() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.path, forType: .string)
    }

    @objc private func openInTerminal() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        // Off the extension main thread: AppleScript launch can block on
        // Terminal activation, which would beachball Finder on slow volumes.
        let path = target.path
        // Fail-closed on control chars (newline in a filename would break the
        // one-line AppleScript string literal and allow injection).
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let shellQuoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let cmd = "cd \(shellQuoted)"
            let cmdLiteral = "\"" + cmd.replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            let script = """
            tell application "Terminal"
                activate
                do script \(cmdLiteral)
            end tell
            """
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    @objc private func openInFinderFlow() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        // queryItems escapes "&", "=" and "#", which .urlQueryAllowed leaves as-is:
        // a folder named "Tom & Jerry" used to arrive as the path "…/Tom ".
        var components = URLComponents()
        components.scheme = "finderflow"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: target.path)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func enableWorkspace() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        var components = URLComponents()
        components.scheme = "finderflow"
        components.host = "enable-workspace"
        components.queryItems = [URLQueryItem(name: "path", value: target.path)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func disableWorkspace() {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        var components = URLComponents()
        components.scheme = "finderflow"
        components.host = "disable-workspace"
        components.queryItems = [URLQueryItem(name: "path", value: target.path)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func uniqueURL(for base: URL) -> URL {
        var url = base
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent) \(counter)")
            counter += 1
        }
        return url
    }
}
