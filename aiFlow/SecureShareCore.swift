import Foundation
import CryptoKit
import Security
import SQLite3
import UniformTypeIdentifiers

// Shared by the desktop app and the embedded, outbound-only share agent.
enum SecureShareError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
struct SecureShareConfiguration: Codable {
    var origin: String
    var deviceId: String
    var enabled: Bool
    var mode: String? = nil // nil: existing managed server, quick: account-free Cloudflare
}
struct SecureShareRecord: Codable, Identifiable {
    var id: String
    var filename: String
    var mimeType: String
    var size: Int64
    var fileHash: String
    var bookmark: Data
    var createdAt: Double
    var expiresAt: Double?
    var allowPreview: Bool
    var allowDownload: Bool
    var maxDownloads: Int?
    var status: String // pending, active, revoked (local deny always precedes remote revoke)
    // Potpis preko linka: owner uključi per-link (default OFF), primalac crta
    // potpis + upiše ime, Mac preimenuje logički filename u
    // "Ugovor (signed by Marko).pdf" i čuva approval metadata.
    var requireSignature: Bool = false
    var approvalName: String? = nil
    var approvalAt: Double? = nil
    var sealedAt: Double? = nil
    var sealError: String? = nil

    var signatureStatus: String {
        guard approvalName != nil else { return "awaiting_signature" }
        guard mimeType == "application/pdf" else { return "signature_saved" }
        if sealedAt != nil { return "sealed" }
        if let sealError, !sealError.isEmpty { return "signature_failed" }
        return "sealing"
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, size, fileHash, bookmark, createdAt, expiresAt
        case allowPreview, allowDownload, maxDownloads, status
        case requireSignature, approvalName, approvalAt, sealedAt, sealError
    }
    init(id: String, filename: String, mimeType: String, size: Int64, fileHash: String, bookmark: Data, createdAt: Double, expiresAt: Double?, allowPreview: Bool, allowDownload: Bool, maxDownloads: Int?, status: String, requireSignature: Bool = false, approvalName: String? = nil, approvalAt: Double? = nil, sealedAt: Double? = nil, sealError: String? = nil) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.size = size
        self.fileHash = fileHash; self.bookmark = bookmark; self.createdAt = createdAt
        self.expiresAt = expiresAt; self.allowPreview = allowPreview; self.allowDownload = allowDownload
        self.maxDownloads = maxDownloads; self.status = status
        self.requireSignature = requireSignature; self.approvalName = approvalName; self.approvalAt = approvalAt
        self.sealedAt = sealedAt; self.sealError = sealError
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        size = try c.decode(Int64.self, forKey: .size)
        fileHash = try c.decode(String.self, forKey: .fileHash)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        allowPreview = try c.decode(Bool.self, forKey: .allowPreview)
        allowDownload = try c.decode(Bool.self, forKey: .allowDownload)
        maxDownloads = try c.decodeIfPresent(Int.self, forKey: .maxDownloads)
        status = try c.decode(String.self, forKey: .status)
        requireSignature = try c.decodeIfPresent(Bool.self, forKey: .requireSignature) ?? false
        approvalName = try c.decodeIfPresent(String.self, forKey: .approvalName)
        approvalAt = try c.decodeIfPresent(Double.self, forKey: .approvalAt)
        sealedAt = try c.decodeIfPresent(Double.self, forKey: .sealedAt)
        sealError = try c.decodeIfPresent(String.self, forKey: .sealError)
    }
    /// "Ugovor.pdf" + "Marko" → "Ugovor (signed by Marko).pdf".
    /// Čuva ekstenziju, skida kontrolne karaktere i / \ : * ? " < > |,
    /// seče ime potpisnika na 60 znakova da filename ostane <255.
    static func approvedFilename(original: String, signer: String) -> String {
        let clean = signer.replacingOccurrences(of: "[\\x00-\\x1f\\x7f/\\\\:*?\"<>|]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(clean.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? "signed" : "signed by \(name)"
        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        var base = url.deletingPathExtension().lastPathComponent
        // Ne stack-uj suffix ako je već approved.
        if let r = base.range(of: #" \(signed( by .*)?\)$"#, options: .regularExpression) { base.removeSubrange(r) }
        if base.count > 180 { base = String(base.prefix(180)) }
        return ext.isEmpty ? "\(base) (\(display))" : "\(base) (\(display)).\(ext)"
    }
}
enum SecureSharePaths {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["FF_SHARE_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FinderFlow/SecureShares", isDirectory: true)
    }
    static var snapshots: URL { root.appendingPathComponent("Snapshots", isDirectory: true) }
    static func prepare() throws {
        for url in [root, snapshots] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
}
final class SecureShareDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    init() throws {
        try SecureSharePaths.prepare()
        let path = SecureSharePaths.root.appendingPathComponent("shares.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SecureShareError.message("Unable to open the local share registry.") }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS quick_access(id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, salt TEXT, password_hash TEXT, views INTEGER NOT NULL DEFAULT 0, downloads INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS quick_events(id INTEGER PRIMARY KEY, share_id TEXT NOT NULL, kind TEXT NOT NULL, created_at REAL NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw SecureShareError.message("Unable to initialize the share registry.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    deinit { sqlite3_close(db) }
    private func put<T: Encodable>(_ value: T, id: String, table: String) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO \(table)(id,data) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", -1, &stmt, nil) == SQLITE_OK else { throw SecureShareError.message("Unable to save share.") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SecureShareError.message("Unable to save share.") }
    }
    private func read<T: Decodable>(_ type: T.Type, table: String) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { throw SecureShareError.message("Unable to read share registry.") }
        defer { sqlite3_finalize(stmt) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let ptr = sqlite3_column_blob(stmt, 0) else { throw SecureShareError.message("Unable to read share registry.") }
            values.append(try JSONDecoder().decode(type, from: Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, 0)))))
        }
        return values
    }
    func save(_ record: SecureShareRecord) throws { try put(record, id: record.id, table: "records") }
    func shares() throws -> [SecureShareRecord] { try read(SecureShareRecord.self, table: "records").sorted { $0.createdAt > $1.createdAt } }
    func share(_ id: String) throws -> SecureShareRecord? { try shares().first { $0.id == id } }
    func configuration() throws -> SecureShareConfiguration? { try read(SecureShareConfiguration.self, table: "settings").first }
    func configure(_ value: SecureShareConfiguration) throws { try put(value, id: "configuration", table: "settings") }
    // Each query has bound values; only generated share IDs reach the registry.
    private func quickQuery(_ sql: String, _ values: [Any?] = []) throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SecureShareError.message("Unable to read share data.") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, position, number)
            default: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw SecureShareError.message("Unable to save share data.") }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
    }
    func quickCreate(id: String, tokenHash: String, salt: String?, passwordHash: String?) throws {
        _ = try quickQuery("INSERT INTO quick_access(id,token_hash,salt,password_hash) VALUES(?,?,?,?)", [id,tokenHash,salt,passwordHash])
        try quickEvent(id, "created")
    }
    func quickAccess(id: String) throws -> [String: Any]? { try quickQuery("SELECT * FROM quick_access WHERE id=?", [id]).first }
    func quickAccess(tokenHash: String) throws -> [String: Any]? { try quickQuery("SELECT * FROM quick_access WHERE token_hash=?", [tokenHash]).first }
    func quickView(_ id: String) throws { _ = try quickQuery("UPDATE quick_access SET views=views+1 WHERE id=?", [id]); try quickEvent(id, "opened") }
    func quickReserve(_ id: String, limit: Int?) throws -> Bool {
        let result = try quickQuery("UPDATE quick_access SET downloads=downloads+1 WHERE id=? AND (? IS NULL OR downloads<?) RETURNING id", [id,limit,limit])
        if !result.isEmpty { try quickEvent(id, "download_started") }
        return !result.isEmpty
    }
    func quickEvent(_ id: String, _ kind: String) throws {
        _ = try quickQuery("INSERT INTO quick_events(share_id,kind,created_at) VALUES(?,?,?)", [id,kind,Date().timeIntervalSince1970*1000])
        _ = try quickQuery("DELETE FROM quick_events WHERE share_id=? AND id NOT IN (SELECT id FROM quick_events WHERE share_id=? ORDER BY id DESC LIMIT 100)", [id,id])
    }
    func quickEvents(_ id: String) throws -> [[String: Any]] { try quickQuery("SELECT kind,created_at FROM quick_events WHERE share_id=? ORDER BY id DESC LIMIT 100", [id]) }
    func delete(id: String) throws {
        // Potpuno uklanjanje share-a: zapis + token/salt + eventi + snapshot + potpis.
        // ID dolazi iz našeg registry-ja (UUID), vezan je kao parametar.
        _ = try quickQuery("DELETE FROM records WHERE id=?", [id])
        _ = try quickQuery("DELETE FROM quick_access WHERE id=?", [id])
        _ = try quickQuery("DELETE FROM quick_events WHERE share_id=?", [id])
        if UUID(uuidString: id) != nil {
            try? FileManager.default.removeItem(at: SecureSharePaths.snapshots.appendingPathComponent(id))
            try? FileManager.default.removeItem(at: SecureSharePaths.snapshots.appendingPathComponent("\(id).approval.png"))
            try? FileManager.default.removeItem(at: SecureSharePaths.snapshots.appendingPathComponent("\(id).sealed"))
        }
    }
    func cleanupSnapshots() throws {
        // Hold a cross-process SQLite write lock through the unlink. Otherwise an
        // expiry sweep could delete a snapshot concurrently being renewed by the UI.
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw SecureShareError.message("Share registry is busy.") }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM records", -1, &stmt, nil) == SQLITE_OK else { throw SecureShareError.message("Unable to read share registry.") }
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970 * 1000
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let ptr = sqlite3_column_blob(stmt, 0) else { throw SecureShareError.message("Unable to read share registry.") }
            let share = try JSONDecoder().decode(SecureShareRecord.self, from: Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, 0))))
            if share.status == "revoked" || (share.expiresAt.map { $0 <= now } ?? false) {
                if UUID(uuidString: share.id) != nil {
                    try? FileManager.default.removeItem(at: SecureSharePaths.snapshots.appendingPathComponent(share.id))
                    try? FileManager.default.removeItem(at: SecureSharePaths.snapshots.appendingPathComponent("\(share.id).approval.png"))
                }
            }
        }
    }

}
enum SecureShareCrypto {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SecureShareError.message("Secure random generation failed.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func fileHash(_ handle: FileHandle) throws -> String {
        try handle.seek(toOffset: 0); var digest = SHA256()
        while let chunk = try handle.read(upToCount: 256*1024), !chunk.isEmpty { try Task.checkCancellation(); digest.update(data: chunk) }
        try handle.seek(toOffset: 0)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func previewSupported(_ mime: String) -> Bool {
        // Inline preview only for types browsers render natively without script
        // execution. HTML/SVG/JS stay download-only: opened directly in a new
        // tab they would run in the share origin and could abuse the session.
        ["application/pdf",
         "image/png","image/jpeg","image/gif","image/webp","image/avif","image/bmp","image/x-icon","image/vnd.microsoft.icon",
         "text/plain","text/markdown","text/csv","text/tab-separated-values",
         "application/json","text/xml","application/xml","text/yaml","application/yaml","application/x-yaml","application/toml",
         "audio/mpeg","audio/mp4","audio/x-m4a","audio/ogg","audio/wav","audio/x-wav","audio/vnd.wave","audio/webm","audio/flac","audio/x-flac","audio/aac","audio/opus",
         "video/mp4","video/x-m4v","video/webm","video/ogg","video/quicktime"].contains(mime)
    }
    // Text-like types are served with an explicit charset so browsers render
    // UTF-8 correctly instead of sniffing or downloading.
    static func previewContentType(_ mime: String) -> String {
        if mime.hasPrefix("text/") || ["application/json","application/xml","application/yaml","application/x-yaml","application/toml"].contains(mime) {
            return mime + "; charset=utf-8"
        }
        return mime
    }
}
enum SecureShareKeychain {
    // Synthetic GUI tests must never touch the login Keychain.
    private static func isolatedTestURL(_ account: String) -> URL? {
        guard ProcessInfo.processInfo.environment["FF_SHARE_TEST_MODE"] == "1", ProcessInfo.processInfo.environment["FF_SHARE_DIR"] != nil else { return nil }
        return SecureSharePaths.root.appendingPathComponent("test-secret-" + SecureShareCrypto.hash(Data(account.utf8)))
    }
    static func read(_ account: String) throws -> Data? {
        if let url = isolatedTestURL(account) { return FileManager.default.fileExists(atPath:url.path) ? try Data(contentsOf:url) : nil }
        var output: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.finderflow.secure-share", kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureShareError.message("Keychain access is unavailable (\(status)).") }
        return output as? Data
    }
    static func save(_ data: Data, account: String) throws {
        if let url = isolatedTestURL(account) {
            try SecureSharePaths.prepare(); try data.write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path); return
        }
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.finderflow.secure-share", kSecAttrAccount: account] as CFDictionary
        let result = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw SecureShareError.message("Unable to update Keychain (\(result)).") }
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.finderflow.secure-share", kSecAttrAccount: account, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureShareError.message("Unable to save in Keychain (\(status)).") }
    }
    static func delete(_ account: String) {
        // Best-effort: obrisan link ne sme ostaviti token u Keychain-u.
        if let url = isolatedTestURL(account) { try? FileManager.default.removeItem(at: url); return }
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "com.finderflow.secure-share", kSecAttrAccount: account] as CFDictionary)
    }
    static func identity(origin: String) throws -> Curve25519.Signing.PrivateKey {
        // The isolated integration harness injects a key; normal app/agent runs use Keychain.
        if ProcessInfo.processInfo.environment["FF_SHARE_TEST_MODE"] == "1", ProcessInfo.processInfo.environment["FF_SHARE_DIR"] != nil,
           let path = ProcessInfo.processInfo.environment["FF_SHARE_TEST_KEY"] {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let account = "device:" + SecureShareCrypto.hash(Data(origin.utf8))
        if let data = try read(account) { return try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        let key = Curve25519.Signing.PrivateKey(); try save(key.rawRepresentation, account: account); return key
    }
}
// Refuse redirects so device credentials never follow a server-controlled redirect.
final class SecureShareSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct SecureShareAPI: @unchecked Sendable {
    let origin: String
    private static let session = URLSession(configuration: .ephemeral, delegate: SecureShareSessionDelegate(), delegateQueue: nil)
    static func validatedOrigin(_ text: String) throws -> String {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost","127.0.0.1","::1"].contains(host)) else { throw SecureShareError.message("Enter an HTTPS server address. HTTP is allowed only on localhost for testing.") }
        return String(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
    func request(_ path: String, method: String = "POST", body: [String: Any]? = nil, token: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: origin + path) else { throw SecureShareError.message("Invalid server address.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count < 2*1024*1024 else { throw SecureShareError.message("Invalid server response.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else { throw SecureShareError.message(json["error"] as? String ?? "Server request failed (\(http.statusCode)).") }
        return json
    }
    func register(code: String, name: String) async throws -> String {
        let key = try SecureShareKeychain.identity(origin: origin)
        let prefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00])
        let result = try await request("/v1/devices/register", body: ["publicKey": (prefix + key.publicKey.rawRepresentation).base64EncodedString(), "enrollmentCode": code, "name": name])
        guard let id = result["deviceId"] as? String, UUID(uuidString: id) != nil else { throw SecureShareError.message("Invalid device registration.") }; return id
    }
    func authenticate(deviceId: String) async throws -> String {
        let challenge = try await request("/v1/devices/challenge", body: ["deviceId": deviceId])
        guard let id = challenge["challengeId"] as? String, let nonce = challenge["nonce"] as? String else { throw SecureShareError.message("Invalid device challenge.") }
        let signature = try SecureShareKeychain.identity(origin: origin).signature(for: Data("finderflow-share-v1:\(id):\(nonce)".utf8)).base64EncodedString()
        let result = try await request("/v1/devices/auth", body: ["challengeId": id, "signature": signature])
        guard let token = result["accessToken"] as? String else { throw SecureShareError.message("Device authentication failed.") }; return token
    }
}
enum SecureShareLimits {
    /// Više fajlova/foldera deli se kao jedan .zip — ali ne previše,
    /// da se ne opterete privremeni tunel, disk i primalac.
    static let maxItems = 10
    static let maxFiles = 1000
    static let maxTotalBytes: Int64 = 500 * 1024 * 1024
    static func summary() -> String {
        "Up to \(maxItems) items · \(maxFiles) files inside · \(format(maxTotalBytes)) total · shared as one .zip"
    }
    static func format(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1024 * 1024 { return String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}

/// Više datoteka / foldera → jedan .zip snapshot. Single-file put ostaje
/// netaknut (bez zip-a); sve ostalo prolazi limit-check + staging + zip,
/// pa postojeći snapshot/server protokol radi nepromenjen (jedan zapis,
/// jedan token, download-only pošto zip nema inline preview).
enum SecureShareBundle {
    struct Plan {
        let displayName: String
        let totalBytes: Int64
        let fileCount: Int
        let isSingleFile: Bool
    }

    static func plan(urls: [URL]) throws -> Plan {
        guard !urls.isEmpty else { throw SecureShareError.message("Select at least one file or folder first.") }
        guard urls.count <= SecureShareLimits.maxItems else {
            throw SecureShareError.message("Select up to \(SecureShareLimits.maxItems) items (you selected \(urls.count)). Sharing more would overload the temporary link — split it into smaller shares.")
        }
        var total: Int64 = 0
        var count = 0
        var singleRegular: URL?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey])
            if v?.isSymbolicLink == true { throw SecureShareError.message("“\(url.lastPathComponent)” is a link, not a file — links can't be shared.") }
            if v?.isPackage == true { throw SecureShareError.message("“\(url.lastPathComponent)” is an app/package and can't be shared directly. Share files inside it instead.") }
            if v?.ubiquitousItemDownloadingStatus == .notDownloaded {
                throw SecureShareError.message("“\(url.lastPathComponent)” isn't downloaded (online-only). Download it first, then share.")
            }
            if v?.isRegularFile == true {
                singleRegular = urls.count == 1 ? url : nil
                total += Int64(v?.fileSize ?? 0)
                count += 1
            } else if v?.isDirectory == true {
                let found = try scanFolder(url)
                total += found.bytes
                count += found.files
            } else {
                throw SecureShareError.message("“\(url.lastPathComponent)” can't be shared. Select regular files or folders.")
            }
            if count > SecureShareLimits.maxFiles {
                throw SecureShareError.message("Too many files inside (\(count) so far, max \(SecureShareLimits.maxFiles)). Share a smaller folder or fewer items.")
            }
            if total > SecureShareLimits.maxTotalBytes {
                throw SecureShareError.message("Total size exceeds \(SecureShareLimits.format(SecureShareLimits.maxTotalBytes)) (currently \(SecureShareLimits.format(total))). Split it into smaller shares.")
            }
            try Task.checkCancellation()
        }
        guard count > 0 else { throw SecureShareError.message("No shareable files found (empty folder?).") }
        if let single = singleRegular {
            return Plan(displayName: single.lastPathComponent, totalBytes: total, fileCount: 1, isSingleFile: true)
        }
        let name: String
        if urls.count == 1 {
            name = sanitizedZipName(urls[0].lastPathComponent)
        } else {
            name = "\(urls.count) items.zip"
        }
        return Plan(displayName: name, totalBytes: total, fileCount: count, isSingleFile: false)
    }

    private static func scanFolder(_ root: URL) throws -> (bytes: Int64, files: Int) {
        var bytes: Int64 = 0
        var files = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else {
            throw SecureShareError.message("Can't read “\(root.lastPathComponent)” — check permissions and retry.")
        }
        for case let item as URL in enumerator {
            // Dubinska zaštita: patološki duboka gnežđenja se ne prate dalje.
            if enumerator.level > 25 { enumerator.skipDescendents(); continue }
            let v = try? item.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }
            if v?.isDirectory == true { continue }
            guard v?.isRegularFile == true else { continue }
            bytes += Int64(v?.fileSize ?? 0)
            files += 1
            if files > SecureShareLimits.maxFiles {
                throw SecureShareError.message("“\(root.lastPathComponent)” holds more than \(SecureShareLimits.maxFiles) files. Share a smaller part of it.")
            }
            if bytes > SecureShareLimits.maxTotalBytes {
                throw SecureShareError.message("“\(root.lastPathComponent)” exceeds \(SecureShareLimits.format(SecureShareLimits.maxTotalBytes)). Share a smaller part of it.")
            }
            if files % 200 == 0 { try Task.checkCancellation() }
        }
        return (bytes, files)
    }

    static func sanitizedZipName(_ base: String) -> String {
        var name = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "shared" }
        name = name.replacingOccurrences(of: "/", with: "-")
        if name.count > 80 { name = String(name.prefix(80)) }
        return name.hasSuffix(".zip") ? name : name + ".zip"
    }

    /// Pravi privremeni .zip u striktno privatnom temp folderu. Vrati zip +
    /// display ime; pozivalac briše zip posle snapshot-a (snapshot kopira).
    static func makeZip(urls: [URL]) throws -> (zipURL: URL, displayName: String, totalBytes: Int64, fileCount: Int) {
        let plan = try plan(urls: urls)
        guard !plan.isSingleFile else {
            throw SecureShareError.message("Internal error: single file should not be zipped.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("FinderFlow-share-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Brisanje staging-a uvek; zip ostaje pozivaocu (briše ga posle snapshot-a).
        let staging = work.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var usedNames = Set<String>()
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var leaf = url.lastPathComponent
                if usedNames.contains(leaf) {
                    let ext = url.pathExtension
                    let stem = url.deletingPathExtension().lastPathComponent
                    var i = 2
                    repeat {
                        leaf = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
                        i += 1
                    } while usedNames.contains(leaf)
                }
                usedNames.insert(leaf)
                try fm.copyItem(at: url, to: staging.appendingPathComponent(leaf))
                try Task.checkCancellation()
            }
            // Symlink escape zaštita: zip -y bi linkove sačuvao kao linkove —
            // primalac bi dobio pokazivače van arhive. Ukloni ih iz staging-a.
            if let cleaner = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
                var links: [URL] = []
                for case let item as URL in cleaner {
                    if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { links.append(item) }
                }
                for link in links { try? fm.removeItem(at: link) }
            }
            let zipURL = work.appendingPathComponent(plan.displayName)
            try runZip(zip: zipURL, cwd: staging)
            let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size > 0 else { throw SecureShareError.message("Couldn't pack the selected items into a .zip. Try fewer or smaller items.") }
            // Kompresovani zip retko pređe nekompresovani total; ostavi 50MB lufta.
            if size > SecureShareLimits.maxTotalBytes + 50 * 1024 * 1024 {
                try? fm.removeItem(at: work)
                throw SecureShareError.message("Packed .zip (\(SecureShareLimits.format(size))) is larger than the \(SecureShareLimits.format(SecureShareLimits.maxTotalBytes)) limit. Split it into smaller shares.")
            }
            // Preživi samo zip: staging se briše, work ostaje do snapshot-a.
            try? fm.removeItem(at: staging)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zipURL.path)
            return (zipURL, plan.displayName, plan.totalBytes, plan.fileCount)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private static func runZip(zip: URL, cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "-y", zip.path, "."]
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Isprazni pipe-ove da veliki listing ne blokira alat.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            var message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.count > 500 { message = "…" + message.suffix(500) }
            throw SecureShareError.message(message.isEmpty ? "Couldn't create the .zip archive." : "Couldn't create the .zip archive: \(message)")
        }
    }

    /// Jedan zapis za 1 fajl (direktno) ili više/folder (zip). Temp zip se
    /// briše posle kopije u Snapshots.
    static func createRecord(urls: [URL], expiry: Double?, preview: Bool, download: Bool, limit: Int?, requireSignature: Bool = false) throws -> SecureShareRecord {
        let cleaned = urls.filter { !$0.path.isEmpty }
        guard !cleaned.isEmpty else { throw SecureShareError.message("Select at least one file or folder first.") }
        let plan = try plan(urls: cleaned)
        if plan.isSingleFile, let only = cleaned.first {
            return try SecureShareSnapshot.create(url: only, expiry: expiry, preview: preview, download: download, limit: limit, requireSignature: requireSignature)
        }
        guard download else {
            throw SecureShareError.message("A multi-item share is a .zip archive — enable Download to share it. (Preview works for single PDF/image/text files.)")
        }
        let built = try makeZip(urls: cleaned)
        defer { try? FileManager.default.removeItem(at: built.zipURL.deletingLastPathComponent()) }
        var record = try SecureShareSnapshot.create(url: built.zipURL, expiry: expiry, preview: false, download: download, limit: limit, requireSignature: false)
        // Lepo ime umesto temp imena: "3 items.zip" / "Folder.zip".
        record.filename = built.displayName
        // application/zip nema inline preview na share origin-u (namerno).
        record.mimeType = "application/zip"
        record.allowPreview = false
        return record
    }
}
enum SecureShareSnapshot {
    static func create(url: URL, expiry: Double?, preview: Bool, download: Bool, limit: Int?, requireSignature: Bool = false) throws -> SecureShareRecord {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isPackage != true else { throw SecureShareError.message("Select one regular file. Folders, packages and symbolic links cannot be shared.") }
        try SecureSharePaths.prepare()
        let id = UUID().uuidString.lowercased(), destination = SecureSharePaths.snapshots.appendingPathComponent(id)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            let handle = try FileHandle(forReadingFrom: destination); defer { try? handle.close() }
            let hash = try SecureShareCrypto.fileHash(handle)
            let size = try handle.seekToEnd()
            guard size <= UInt64(Int64.max) else { throw SecureShareError.message("File is too large.") }
            // Main app and helper are unsandboxed. A persistent bookmark stays entirely local.
            let bookmark = try destination.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            // UTType misses a few common extensions; map them explicitly so they
            // get a previewable MIME type instead of octet-stream.
            let extFallback = ["toml": "application/toml", "weba": "audio/webm", "opus": "audio/ogg", "zip": "application/zip"]
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType.flatMap { $0 == "application/octet-stream" ? nil : $0 }
                ?? extFallback[url.pathExtension.lowercased()] ?? "application/octet-stream"
            return SecureShareRecord(id: id, filename: url.lastPathComponent, mimeType: mime, size: Int64(size), fileHash: hash, bookmark: bookmark, createdAt: Date().timeIntervalSince1970*1000, expiresAt: expiry, allowPreview: preview && SecureShareCrypto.previewSupported(mime), allowDownload: download, maxDownloads: limit, status: "pending", requireSignature: requireSignature)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func open(_ share: SecureShareRecord) throws -> FileHandle {
        guard UUID(uuidString: share.id) != nil else { throw SecureShareError.message("FILE_MISSING") }
        let expected = SecureSharePaths.snapshots.appendingPathComponent(share.id).standardizedFileURL
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: share.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), resolved.standardizedFileURL == expected else { throw SecureShareError.message("FILE_MISSING") }
        // O_NOFOLLOW and fstat protect against replacing a snapshot with a symlink/device.
        let fd = Darwin.open(expected.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SecureShareError.message("FILE_MISSING") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var statBuffer = stat()
            guard fstat(fd, &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFREG, statBuffer.st_size == share.size else { throw SecureShareError.message("FILE_CHANGED") }
            guard try SecureShareCrypto.fileHash(handle) == share.fileHash else { throw SecureShareError.message("FILE_CHANGED") }
            return handle
        } catch { try? handle.close(); throw error }
    }
}
