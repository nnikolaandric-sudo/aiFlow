import AppKit
import CoreServices
import Foundation

// MARK: - OpenWithService (shared "Open With programs" logic)
//
// Jedno mesto za sve "otvori sa programima" akcije koje koriste i desni klik
// (FileContextMenu) i gornja traka (SelectionActionBar), a postojeći
// QuickActionsToolbar ih i dalje koristi za foldere.
//
// - Sistemski default + recommended apps preko NSWorkspace (macOS 12+,
//   projekat traži macOS 14+ pa je bezbedno bez fallback-a).
// - Terminal / VS Code / Cursor / Claude Code / Codex specijali.
// - "Other..." biranje aplikacije preko NSOpenPanel-a.

enum OpenWithService {

    // MARK: - System apps

    /// Default aplikacija za dati fajl (nil ako sistem ne zna).
    static func defaultApp(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    /// Preporučene aplikacije sortirane po prikladnosti (najbolja prva).
    /// Isključuje sam FinderFlow da ne nudi samog sebe.
    static func recommendedApps(for url: URL, limit: Int = 6) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let selfBundle = Bundle.main.bundleURL.standardizedFileURL
        var seen = Set<String>()
        var out: [URL] = []
        for app in all {
            let std = app.standardizedFileURL
            if std == selfBundle { continue }
            if seen.insert(std.path).inserted {
                out.append(app)
            }
            if out.count >= limit { break }
        }
        return out
    }

    static func appName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    static func appIcon(for appURL: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: appURL.path)
    }

    static func open(_ fileURLs: [URL], with appURL: URL) {
        guard !fileURLs.isEmpty else { return }
        NSWorkspace.shared.open(
            fileURLs,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func openWithDefault(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        if let def = defaultApp(for: fileURLs[0]) {
            open(fileURLs, with: def)
        } else {
            for url in fileURLs { NSWorkspace.shared.open(url) }
        }
    }

    /// "Other..." — korisnik izabere .app, pa otvorimo selekciju u njoj.
    static func openWithOther(_ fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            // allowedContentTypes is a UI filter only (⇧⌘G can bypass it) —
            // refuse anything that isn't an application bundle before it gets
            // launched with the user's files as arguments. Links resolved:
            // system apps (e.g. /Applications/Safari.app) are symlinks whose
            // isDirectory reads false unresolved.
            let resolved = app.resolvingSymlinksInPath()
            guard resolved.pathExtension.lowercased() == "app",
                  (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
            open(fileURLs, with: app)
        }
    }

    // MARK: - IDE / Terminal specijali (rade i za fajl i za folder)

    /// Folder u kome se otvara terminal/IDE: za fajl to je parent folder,
    /// za folder sam folder.
    static func terminalTarget(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if FileItem.isBrowsableFolder(url) { return url }
        }
        return url.deletingLastPathComponent()
    }

    static func openInTerminal(_ url: URL) {
        let target = terminalTarget(for: url)
        guard !containsAppleScriptUnsafeChars(target.path) else { return }
        let cmd = "cd \(shellQuoted(target.path))"
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptStringLiteral(cmd))
        end tell
        """
        runAppleScript(script)
    }

    static func openInVSCode(_ url: URL) {
        guard let appPath = ideAppURL(
            bundleIDs: ["com.microsoft.VSCode"],
            paths: ["/Applications/Visual Studio Code.app"]
        ) else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appPath,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func openInCursor(_ url: URL) {
        if let appPath = ideAppURL(
            bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.cursor.macos", "com.cursor.cursor"],
            paths: ["/Applications/Cursor.app"]
        ) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appPath,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }
        let cliCandidates = [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        ]
        if let cli = cliCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [url.path]
            try? p.run()
        }
    }

    static func openInClaudeCode(_ url: URL) {
        let target = terminalTarget(for: url)
        guard !containsAppleScriptUnsafeChars(target.path) else { return }
        guard let cli = fixedCLI([
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.volta/bin/claude",
        ]) else {
            // Bez PATH fallback-a: hijackovan `claude` u PATH-u bi izvrsio
            // proizvoljan kod. Kao Cursor/Codex — samo fiksne putanje.
            return
        }
        guard !containsAppleScriptUnsafeChars(cli) else { return }
        let effective = "cd \(shellQuoted(target.path)) && \(shellQuoted(cli)) ."
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptStringLiteral(effective))
        end tell
        """
        runAppleScript(script)
    }

    static func openInCodex(_ url: URL) {
        if let appPath = ideAppURL(
            bundleIDs: ["com.openai.codex", "com.openai.codex-desktop"],
            paths: ["/Applications/Codex.app", "/Applications/OpenAI Codex.app"]
        ) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appPath,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return
        }
        let cliCandidates = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        if let cli = cliCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let target = terminalTarget(for: url)
            guard !containsAppleScriptUnsafeChars(target.path), !containsAppleScriptUnsafeChars(cli) else { return }
            let cmd = "cd \(shellQuoted(target.path)) && \(shellQuoted(cli))"
            let script = """
            tell application "Terminal"
                activate
                do script \(appleScriptStringLiteral(cmd))
            end tell
            """
            runAppleScript(script)
        }
    }

    // MARK: - Availability checks (za uslovno prikazivanje u meniju)

    /// Cached availability so context-menu rendering never does
    /// `urlForApplication` + `fileExists` IPC synchronously while the menu opens.
    /// Refreshed in background (TTL 10 min) via `refreshAvailability()`.
    private static let availabilityQueue = DispatchQueue(label: "FinderFlow.openWithAvailability", qos: .utility)
    private static let availabilityLock = NSLock()
    private static var cachedAvailability: (vscode: Bool, cursor: Bool, claude: Bool, codex: Bool)?
    private static var lastAvailabilityCheck = Date.distantPast
    private static let availabilityTTL: TimeInterval = 600

    static func refreshAvailability() {
        availabilityQueue.async {
            let v = OpenWithService.isVSCodeInstalledUncached()
            let c = OpenWithService.isCursorInstalledUncached()
            let l = OpenWithService.isClaudeInstalledUncached()
            let x = OpenWithService.isCodexInstalledUncached()
            availabilityLock.lock()
            cachedAvailability = (v, c, l, x)
            lastAvailabilityCheck = Date()
            availabilityLock.unlock()
        }
    }

    private static func availability() -> (vscode: Bool, cursor: Bool, claude: Bool, codex: Bool) {
        availabilityLock.lock()
        let cached = cachedAvailability
        let lastCheck = lastAvailabilityCheck
        availabilityLock.unlock()
        if let c = cached,
           Date().timeIntervalSince(lastCheck) < availabilityTTL {
            return c
        }
        refreshAvailability()
        // Stale-while-revalidate: fall back to cheap fixed-path checks only
        // (no NSWorkspace IPC) until the background refresh lands.
        return (
            vscode: fixedCLI(["/Applications/Visual Studio Code.app"]) != nil,
            cursor: fixedCLI(["/Applications/Cursor.app"]) != nil,
            claude: fixedCLI([
                "/usr/local/bin/claude", "/opt/homebrew/bin/claude",
                "\(NSHomeDirectory())/.local/bin/claude",
            ]) != nil,
            codex: fixedCLI([
                "/Applications/Codex.app", "/Applications/OpenAI Codex.app",
                "/usr/local/bin/codex", "/opt/homebrew/bin/codex",
            ]) != nil
        )
    }

    static func isVSCodeInstalled() -> Bool { availability().vscode }
    static func isCursorInstalled() -> Bool { availability().cursor }
    static func isClaudeInstalled() -> Bool { availability().claude }
    static func isCodexInstalled() -> Bool { availability().codex }

    static func isVSCodeInstalledUncached() -> Bool {
        ideAppURL(bundleIDs: ["com.microsoft.VSCode"],
                  paths: ["/Applications/Visual Studio Code.app"]) != nil
    }

    static func isCursorInstalledUncached() -> Bool {
        ideAppURL(bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.cursor.macos", "com.cursor.cursor"],
                  paths: ["/Applications/Cursor.app"]) != nil
    }

    static func isClaudeInstalledUncached() -> Bool {
        fixedCLI([
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.volta/bin/claude",
        ]) != nil
    }

    static func isCodexInstalledUncached() -> Bool {
        ideAppURL(bundleIDs: ["com.openai.codex", "com.openai.codex-desktop"],
                  paths: ["/Applications/Codex.app", "/Applications/OpenAI Codex.app"]) != nil
            || fixedCLI(["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]) != nil
    }

    // MARK: - Private helpers

    private static func ideAppURL(bundleIDs: [String], paths: [String]) -> URL? {
        // File paths first: no IPC, no thread hop. Most installs live at the
        // well-known /Applications path, so this usually decides immediately.
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard !bundleIDs.isEmpty else { return nil }
        // Bundle-ID lookup via LaunchServices: thread-safe (unlike the old
        // NSWorkspace call, which forced a DispatchQueue.main.sync from
        // background queues — a deadlock whenever main was busy, profiled
        // hanging in __DISPATCH_WAIT_FOR_QUEUE__ at every cold launch).
        for bid in bundleIDs {
            if let url = launchServicesAppURL(bundleID: bid) { return url }
        }
        return nil
    }

    /// Thread-safe app lookup by bundle ID. `LSCopyApplicationURLsForBundleIdentifier`
    /// is a pure LaunchServices call — safe from any queue, no main-thread hop.
    private static func launchServicesAppURL(bundleID: String) -> URL? {
        guard let arr = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL],
              let first = arr.first else { return nil }
        return first
    }

    private static func fixedCLI(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAppleScript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try? p.run()
    }
}
