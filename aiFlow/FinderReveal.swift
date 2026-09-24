import AppKit

// MARK: - "Show in Finder" that really opens Finder
//
// NSWorkspace.selectFile / activateFileViewerSelecting go to the app named by
// the global NSFileViewer preference. Once aiFlow is the default file manager
// that is aiFlow itself, so every "Show in Finder" button in the app would
// just bounce back here. When we are the file viewer, ask Finder directly
// (Apple Events, Automation prompt once); if that is refused, open the
// enclosing folder in Finder.

enum FinderReveal {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard DefaultFolderHandler.isFileViewer else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        }
        let items = urls.map { "POSIX file \(literal($0.path))" }.joined(separator: ", ")
        let source = """
        tell application "Finder"
            reveal {\(items)}
            activate
        end tell
        """
        // Off main: the first run waits on the Automation consent dialog.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard error != nil else { return }
            DispatchQueue.main.async { openEnclosingFolderInFinder(urls[0]) }
        }
    }

    static func reveal(path: String) {
        reveal([URL(fileURLWithPath: path)])
    }

    private static func openEnclosingFolderInFinder(_ url: URL) {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.open([url.deletingLastPathComponent()], withApplicationAt: finder,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
