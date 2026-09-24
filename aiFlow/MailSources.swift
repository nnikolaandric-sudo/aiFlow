import Foundation
import AppKit
import CryptoKit

// MARK: - Mail sources (how mail reaches Email/Inbox)
//
// Three local ways in, no OAuth and no passwords — everything goes through
// Mail.app, which already has the user's Gmail / Outlook / iCloud / IMAP
// accounts:
//   1. Import from Mail — the messages selected in Mail.app are saved as .eml
//      into Email/Inbox and synced (Apple Events, Automation prompt once).
//   2. Mail rule — a Run AppleScript rule saves every matching incoming mail
//      into Email/Inbox. FinderFlow installs the script with the current
//      Email folder baked in; the user adds the rule in Mail ▸ Settings ▸ Rules.
//   3. Auto-sync — while FinderFlow runs it watches Email/Inbox and syncs new
//      .eml files on its own (Settings ▸ Mail Inbox, off by default).
// File names are the MD5 of the Message-ID, the same as the rule script, so
// importing a mail the rule already saved never creates a second file; the
// store dedups by Message-ID anyway.

// MARK: Import from Mail.app

enum MailAppImporter {
    struct Result {
        var saved = 0
        var error: String?
    }

    /// Most messages taken from one selection — a stray ⌘A in Mail must not
    /// pull a whole mailbox.
    static let maxMessages = 200

    /// Saves the messages selected in Mail.app into Email/Inbox. Runs the
    /// Apple Event off-main (Mail can take seconds to hand over sources);
    /// `completion` runs on main.
    static func importSelection(completion: @escaping (Result) -> Void) {
        MailFilingService.ensureEmailDirs()
        let inbox = MailFilingService.inboxDir()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(inbox: inbox)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(inbox: URL) -> Result {
        let src = """
        tell application "Mail"
            set sel to selection
            set out to {}
            set n to 0
            repeat with m in sel
                set n to n + 1
                if n > \(maxMessages) then exit repeat
                try
                    set end of out to {message id of m, source of m}
                end try
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let desc = NSAppleScript(source: src)?.executeAndReturnError(&err) else {
            let num = err?["NSAppleScriptErrorNumber"] as? Int ?? 0
            if num == -1743 {
                return Result(error: "aiFlow isn't allowed to control Mail. Turn it on in System Settings ▸ Privacy & Security ▸ Automation ▸ aiFlow ▸ Mail, then try again.")
            }
            let msg = err?["NSAppleScriptErrorMessage"] as? String ?? "error \(num)"
            return Result(error: "Mail didn't answer: \(msg)")
        }
        var result = Result()
        guard desc.numberOfItems > 0 else {
            result.error = "Select one or more messages in Mail first."
            return result
        }
        for i in 1...desc.numberOfItems {
            guard let pair = desc.atIndex(i), pair.numberOfItems == 2,
                  let id = pair.atIndex(1)?.stringValue,
                  let source = pair.atIndex(2)?.stringValue, !source.isEmpty else { continue }
            let url = inbox.appendingPathComponent(fileName(messageID: id))
            if FileManager.default.fileExists(atPath: url.path) { result.saved += 1; continue }
            if (try? Data(source.utf8).write(to: url, options: .atomic)) != nil { result.saved += 1 }
        }
        return result
    }

    /// `md5 -q -s <Message-ID>` + ".eml" — the rule script's naming.
    static func fileName(messageID: String) -> String {
        Insecure.MD5.hash(data: Data(messageID.utf8)).map { String(format: "%02x", $0) }.joined() + ".eml"
    }
}

// MARK: Mail rule script

enum MailRuleInstaller {
    static let scriptName = "aiFlowSave"

    static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Scripts/com.apple.mail", isDirectory: true)
            .appendingPathComponent(scriptName + ".scpt")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: scriptURL.path) }

    /// Same logic as tools/mail-rule/aiFlowSave.applescript, with the
    /// current Email folder baked in and the source written as UTF-8.
    static func scriptSource(inbox: URL) -> String {
        let inboxPath = inbox.path.hasSuffix("/") ? inbox.path : inbox.path + "/"
        let logPath = MailFilingService.emailRoot().appendingPathComponent("mailrule.log").path
        func lit(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        -- aiFlowSave — installed by aiFlow (Settings ▸ Mail Inbox).
        -- Mail rule action "Run AppleScript": saves each message as .eml into
        -- aiFlow's Email/Inbox; aiFlow files it on the next Sync.
        using terms from application "Mail"
            on perform mail action with messages theMessages for rule theRule
                set inboxPath to \(lit(inboxPath))
                set logPath to \(lit(logPath))
                do shell script "mkdir -p " & quoted form of inboxPath
                repeat with theMessage in theMessages
                    set filePath to ""
                    try
                        set rawSource to source of theMessage
                        set msgID to message id of theMessage
                        set hashName to do shell script "md5 -q -s " & quoted form of msgID
                        set filePath to inboxPath & hashName & ".eml"
                        set f to open for access POSIX file filePath with write permission
                        set eof of f to 0
                        write rawSource to f as «class utf8»
                        close access f
                        do shell script "echo \\"$(date '+%F %T') saved \\" " & quoted form of filePath & " >> " & quoted form of logPath
                    on error errMsg number errNum
                        do shell script "echo \\"$(date '+%F %T') ERROR " & errNum & "\\" " & quoted form of errMsg & " >> " & quoted form of logPath
                        try
                            if filePath is not "" then close access POSIX file filePath
                        end try
                    end try
                end repeat
            end perform mail action with messages
        end using terms from
        """
    }

    /// Compiles the script into Mail's scripts folder. Returns nil on success
    /// or the error text.
    static func install() -> String? {
        MailFilingService.ensureEmailDirs()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("aiFlowSave-\(UUID().uuidString).applescript")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try scriptSource(inbox: MailFilingService.inboxDir()).write(to: tmp, atomically: true, encoding: .utf8)
            try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        p.arguments = ["-o", scriptURL.path, tmp.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return msg.isEmpty ? "osacompile failed (\(p.terminationStatus))" : msg
        }
        return nil
    }
}

// MARK: Auto-sync

/// Watches Email/Inbox while the app runs and syncs new .eml files (the Mail
/// rule or a drag from Mail drops them there). Off unless the user turns it on.
final class MailInboxWatcher: ObservableObject {
    static let shared = MailInboxWatcher()
    static let enabledKey = "ffMailAutoSync"

    @Published private(set) var lastMessage: String?

    private let workQueue = DispatchQueue(label: "FinderFlow.mailInboxWatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var pending: DispatchWorkItem?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Starts, restarts (Email folder moved) or stops watching to match
    /// Settings. The source and all sync work stay off the main thread.
    func refresh() {
        guard Self.isEnabled else { stop(); return }
        let path = MailFilingService.inboxDir().path
        workQueue.async { [weak self] in
            guard let self, Self.isEnabled else { return }
            MailFilingService.ensureEmailDirs()
            self.refreshOnQueue(path: path)
        }
    }

    private func refreshOnQueue(path: String) {
        if watchedPath == path, source != nil { return }
        stopOnQueue()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend],
                                                            queue: workQueue)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watchedPath = path
        schedule()
    }

    func stop() {
        workQueue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        watchedPath = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncIfNeeded() }
        pending = work
        workQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func syncIfNeeded() {
        guard Self.isEnabled else { return }
        let inbox = MailFilingService.inboxDir()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        guard files.contains(where: { $0.lowercased().hasSuffix(".eml") }) else { return }
        let r = MailFilingService.shared.sync()
        if r.ingested > 0 || r.failed > 0 {
            let message = r.failed > 0
                ? "Auto-sync \(Date().formatted(date: .omitted, time: .shortened)): \(r.ingested) new, \(r.failed) failed"
                : "Auto-sync \(Date().formatted(date: .omitted, time: .shortened)): \(r.ingested) new"
            DispatchQueue.main.async { [weak self] in self?.lastMessage = message }
        }
    }
}
