import Combine
import Foundation
import Security

// MARK: - Send to Discord (FinderFlow+ power tool)
//
// Sends files to a Discord channel (project) or a person (DM) through the
// user's own bot — the same bot that powers discord-bot. No server relay:
// the Mac app talks to the Discord REST API directly with URLSession.
//
// Setup (once, in Settings → Discord):
//   1. Paste the bot token (stored in Keychain, never in UserDefaults/plist).
//   2. Add targets: channel ID for a project channel, user ID for a person.
//      (Discord → Settings → Advanced → Developer Mode → right-click → Copy ID)
//   3. The bot must be on that server with permission to post in the channel.
//      DMs work only for users who share a server with the bot.
//
// Limits (Discord-side, standard plan): 25 MB per file, 10 files per message
// (larger selections are sent as multiple messages automatically).
// Folders can't be sent as-is in v1 — compress them first (clear error).

// MARK: - Target model

struct DiscordTarget: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case channel = "Channel"
        case user    = "Person (DM)"
        var id: String { rawValue }
    }

    /// Local id (stable across renames / ID edits).
    var id: String = UUID().uuidString
    /// Display name shown in the picker ("backend-tim", "Jovan").
    var name: String = ""
    /// Discord snowflake: channel ID for `.channel`, user ID for `.user`.
    var discordID: String = ""
    var kind: Kind = .channel

    var trimmedDiscordID: String {
        discordID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors (user-facing)

enum DiscordSendError: LocalizedError {
    case noToken
    case noValidFiles(reason: String)
    case invalidTarget
    case dmChannelFailed(status: Int)
    case api(status: Int, message: String)
    case network(Error)
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Discord bot token isn't set. Add it in Settings → Discord."
        case .noValidFiles(let reason):
            return reason
        case .invalidTarget:
            return "Invalid channel/user ID — Discord IDs are numbers (Developer Mode → Copy ID)."
        case .dmChannelFailed(let status):
            if status == 401 { return "Invalid bot token (DM open failed: 401)." }
            if status == 403 { return "Can't DM this person — you must share a server and they must allow DMs from server members." }
            return "Couldn't open a DM with this person (HTTP \(status))."
        case .api(let status, let message):
            if status == 401 { return "Invalid bot token (HTTP 401). Check Settings → Discord." }
            if status == 403 { return "Bot can't post there (HTTP 403). Check channel access and permissions." }
            if status == 404 { return "Target not found (HTTP 404). Check the channel/user ID." }
            if status == 413 { return "File too large for Discord (HTTP 413). Max 25 MB per file." }
            if status == 429 { return "Rate limited by Discord (HTTP 429). Wait a minute and try again." }
            return message.isEmpty ? "Discord rejected the send (HTTP \(status))." : message
        case .network(let e):
            return "Network error: \(e.localizedDescription)"
        case .invalidResponse:
            return "Unexpected response from Discord."
        case .cancelled:
            return "Send cancelled."
        }
    }
}

// MARK: - Service

/// Owns the Discord share configuration (token in Keychain, targets in
/// UserDefaults) and performs the REST sends. Use the shared instance so
/// ContentView and SettingsView observe the same @Published targets.
final class DiscordShareService: ObservableObject {
    static let shared = DiscordShareService()
    /// Discord standard-plan caps.
    static let maxFilesPerMessage = 10
    static let maxFileBytes: Int64 = 25 * 1024 * 1024

    private static let targetsKey = "FF.discordTargets.v1"
    private static let apiBase = "https://discord.com/api/v10"

    @Published var targets: [DiscordTarget] = []

    /// In-flight upload (set per chunk). Cancel from the sheet so a slow
    /// network can't wedge the UI with Cancel disabled.
    private var currentTask: URLSessionTask?

    /// Cancel the running upload, if any. Completion reports .cancelled.
    func cancelSend() { currentTask?.cancel() }

    init() { loadTargets() }

    // MARK: Configuration

    var isTokenSet: Bool { (token() ?? "").isEmpty == false }

    func token() -> String? { KeychainStore.load() }

    func setToken(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { KeychainStore.delete() } else { KeychainStore.save(t) }
        objectWillChange.send()
    }

    func addTarget(name: String, discordID: String, kind: DiscordTarget.Kind) {
        let t = DiscordTarget(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                              discordID: discordID.trimmingCharacters(in: .whitespacesAndNewlines),
                              kind: kind)
        guard !t.name.isEmpty, !t.trimmedDiscordID.isEmpty else { return }
        targets.append(t)
        saveTargets()
    }

    func removeTargets(at offsets: IndexSet) {
        targets.remove(atOffsets: offsets)
        saveTargets()
    }

    /// Removes one target by its local id (used by Settings rows, where
    /// IndexSet-based onDelete isn't available inside a Form).
    func removeTarget(id: String) {
        targets.removeAll { $0.id == id }
        saveTargets()
    }

    private func loadTargets() {
        guard let data = UserDefaults.standard.data(forKey: Self.targetsKey),
              let list = try? JSONDecoder().decode([DiscordTarget].self, from: data)
        else { return }
        targets = list
    }

    private func saveTargets() {
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: Self.targetsKey)
        }
    }

    // MARK: Validation (v1: flat files only, folders must be compressed first)

    struct Partition {
        var files: [(url: URL, size: Int64)] = []
        var folders: [String] = []
        var oversized: [(name: String, size: Int64)] = []
        /// Vanished or stat-unreadable (moved, deleted, no permission):
        /// fail closed instead of passing a size-0 ghost through the limit
        /// check and failing late mid-upload (or staging gigabytes to /tmp
        /// for a file whose real size was unknown).
        var unreadable: [String] = []
    }

    /// Splits URLs into sendable files vs. problems, without touching the network.
    func partition(urls: [URL]) -> Partition {
        var out = Partition()
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else { out.unreadable.append(url.lastPathComponent); continue }
            if isDir.boolValue {
                out.folders.append(url.lastPathComponent)
                continue
            }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
                out.unreadable.append(url.lastPathComponent)
                continue
            }
            if size > Self.maxFileBytes {
                out.oversized.append((url.lastPathComponent, size))
            } else {
                out.files.append((url, size))
            }
        }
        return out
    }

    // MARK: Send

    /// Sends `urls` + `message` to `target`, chunked into ≤10-file messages.
    /// `progress` reports (sentFiles, totalFiles) on main; `completion` on main.
    func send(urls: [URL], message: String, to target: DiscordTarget,
              progress: @escaping (Int, Int) -> Void = { _, _ in },
              completion: @escaping (Result<Int, DiscordSendError>) -> Void) {
        guard let token = token(), !token.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.noToken)) }
            return
        }
        let part = partition(urls: urls)
        guard !part.files.isEmpty else {
            let reason: String
            if !part.unreadable.isEmpty {
                let names = part.unreadable.joined(separator: ", ")
                reason = "Couldn't read \(part.unreadable.count == 1 ? "“\(part.unreadable[0])”" : "\(part.unreadable.count) files: \(names)") — moved, deleted, or no permission."
            } else if !part.folders.isEmpty && part.oversized.isEmpty {
                reason = "Folders can't be sent directly — compress \(part.folders.count == 1 ? "“\(part.folders[0])”" : "\(part.folders.count) folders") first, then send the archive."
            } else if part.oversized.isEmpty {
                reason = "Nothing to send."
            } else {
                let names = part.oversized.map(\.name).joined(separator: ", ")
                reason = "File\(part.oversized.count == 1 ? "" : "s") over Discord's 25 MB limit: \(names)."
            }
            DispatchQueue.main.async { completion(.failure(.noValidFiles(reason: reason))) }
            return
        }
        let trimmedTarget = target.trimmedDiscordID
        // Discord snowflakeovi su cifre — sve ostalo bi razbilo URL (nil +
        // force-unwrap = crash) ili pogodilo pogresan endpoint. Validiraj pre mreze.
        guard !trimmedTarget.isEmpty, trimmedTarget.allSatisfy(\.isNumber) else {
            DispatchQueue.main.async { completion(.failure(.invalidTarget)) }
            return
        }
        if target.kind == .channel {
            sendChunks(files: part.files, message: message, channelID: trimmedTarget,
                       token: token, progress: progress, completion: completion)
        } else {
            openDMChannel(userID: trimmedTarget, token: token) { result in
                switch result {
                case .failure(let e):
                    DispatchQueue.main.async { completion(.failure(e)) }
                case .success(let channelID):
                    self.sendChunks(files: part.files, message: message, channelID: channelID,
                                    token: token, progress: progress, completion: completion)
                }
            }
        }
    }

    // MARK: REST primitives

    private func openDMChannel(userID: String, token: String,
                               completion: @escaping (Result<String, DiscordSendError>) -> Void) {
        guard let url = URL(string: "\(Self.apiBase)/users/@me/channels") else {
            completion(.failure(.invalidResponse))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["recipient_id": userID])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(.network(err))); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String, !id.isEmpty
            else {
                completion(.failure(status == -1 ? .invalidResponse : .dmChannelFailed(status: status)))
                return
            }
            completion(.success(id))
        }.resume()
    }

    /// Sends serially in ≤10-file chunks (message text only on the first one).
    private func sendChunks(files: [(url: URL, size: Int64)], message: String,
                            channelID: String, token: String,
                            progress: @escaping (Int, Int) -> Void,
                            completion: @escaping (Result<Int, DiscordSendError>) -> Void) {
        let chunks = stride(from: 0, to: files.count, by: Self.maxFilesPerMessage).map {
            Array(files[$0..<min($0 + Self.maxFilesPerMessage, files.count)])
        }
        let total = files.count
        var sent = 0
        var chunkIndex = 0

        func sendNext() {
            guard chunkIndex < chunks.count else {
                let done = sent
                DispatchQueue.main.async { completion(.success(done)) }
                return
            }
            let chunk = chunks[chunkIndex]
            // Message text rides on the first chunk only.
            let text = chunkIndex == 0 ? message : ""
            self.postMessage(files: chunk, content: text, channelID: channelID, token: token) { result in
                switch result {
                case .failure(let e):
                    DispatchQueue.main.async { completion(.failure(e)) }
                case .success:
                    sent += chunk.count
                    chunkIndex += 1
                    let s = sent
                    DispatchQueue.main.async { progress(s, total) }
                    sendNext()
                }
            }
        }
        sendNext()
    }

    private func postMessage(files: [(url: URL, size: Int64)], content: String,
                             channelID: String, token: String,
                             completion: @escaping (Result<Void, DiscordSendError>) -> Void) {
        guard let url = URL(string: "\(Self.apiBase)/channels/\(channelID)/messages") else {
            completion(.failure(.invalidTarget))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "FinderFlow-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let bodyFile: URL
        do {
            bodyFile = try multipartBodyFile(files: files, content: content, boundary: boundary)
        } catch {
            completion(.failure(.network(error)))
            return
        }
        // uploadTask(fromFile:) strimuje telo sa diska: 10 fajlova po 25MB vise
        // ne drzi 250MB u RAM-u. Temp fajl se brise na svim izlazima.
        let task = URLSession.shared.uploadTask(with: req, fromFile: bodyFile) { [weak self] data, resp, err in
            self?.currentTask = nil
            try? FileManager.default.removeItem(at: bodyFile)
            if let err {
                // Cancel iz sheet-a nije mrezna greska — prijavi otkazivanje.
                if (err as NSError).code == NSURLErrorCancelled {
                    completion(.failure(.cancelled)); return
                }
                completion(.failure(.network(err))); return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                completion(.failure(.api(status: status, message: Self.apiErrorMessage(data: data))))
                return
            }
            completion(.success(()))
        }
        currentTask = task
        task.resume()
    }

    /// Multipart telo pisano u temp fajl u 1MB chunkovima umesto jednog Data
    /// bloba u memoriji. Imena fajlova se ciste od `"` i kontrolnih znakova da
    /// ne razbiju Content-Disposition header.
    private func multipartBodyFile(files: [(url: URL, size: Int64)], content: String,
                                   boundary: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFlow-discord-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let out = try? FileHandle(forWritingTo: tmp) else {
            throw DiscordSendError.network(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
        }
        // Staged telo u /tmp sa default 0644 bi drugi user na shared Mac-u mogao
        // da cita pre slanja — zakljucaj na 0600 (cleanup vec postoji na izlazima).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        do {
            func append(_ s: String) throws {
                guard let d = s.data(using: .utf8) else { return }
                try out.write(contentsOf: d)
            }
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let payload = try JSONSerialization.data(
                    withJSONObject: ["content": content],
                    options: [.withoutEscapingSlashes])
                try append("--\(boundary)\r\n")
                try append("Content-Disposition: form-data; name=\"payload_json\"\r\n")
                try append("Content-Type: application/json\r\n\r\n")
                try out.write(contentsOf: payload)
                try append("\r\n")
            }
            for (i, f) in files.enumerated() {
                let safeName = Self.headerSafeFilename(f.url.lastPathComponent)
                try append("--\(boundary)\r\n")
                try append("Content-Disposition: form-data; name=\"files[\(i)]\"; filename=\"\(safeName)\"\r\n")
                try append("Content-Type: application/octet-stream\r\n\r\n")
                let fh = try FileHandle(forReadingFrom: f.url)
                defer { try? fh.close() }
                while true {
                    let chunk = fh.readData(ofLength: 1 << 20)
                    if chunk.isEmpty { break }
                    try out.write(contentsOf: chunk)
                }
                try append("\r\n")
            }
            try append("--\(boundary)--\r\n")
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        return tmp
    }

    /// Ime fajla bezbedno za HTTP header: `"` bi zatvorilo filename vrednost,
    /// CR/LF bi ubacili lazne headere. macOS ih dozvoljava u imenima.
    private static func headerSafeFilename(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "\"", with: "_")
        out = out.components(separatedBy: .newlines).joined(separator: "_")
        out = out.replacingOccurrences(of: "\r", with: "_")
        return out.isEmpty ? "file" : out
    }

    private static func apiErrorMessage(data: Data?) -> String {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? String
        else { return "" }
        return msg
    }
}

// MARK: - Keychain (bot token)

private enum KeychainStore {
    private static let service = "FinderFlow.discordBotToken"
    private static let account = "bot-token"

    static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        } else {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
