import Foundation

// MARK: - Google Drive API v3 klijent (URLSession, async/await, bez zavisnosti)
//
// Pokriva tačno ono što sync engine-u treba: listanje, download, export
// Google Docs formata, upload, folderi, trash. Sve ostalo je van opsega v1.
//
// Docs: https://developers.google.com/drive/api/v3/reference

struct GoogleDriveFile: Codable, Hashable {
    var id: String
    var name: String
    var mimeType: String
    var parents: [String]?
    var modifiedTime: String? // RFC3339
    var createdTime: String?
    var size: String? // string-broj, nil za foldere i Google Docs
    var trashed: Bool?
    var webViewLink: String?
    var md5Checksum: String?
    var kind: String?

    var isFolder: Bool { mimeType == GoogleDriveAPI.folderMime }
    var isTrashed: Bool { trashed == true }
    var byteSize: Int64 { Int64(size ?? "") ?? 0 }

    var modifiedDate: Date {
        guard let s = modifiedTime else { return .distantPast }
        return ISO8601DateFormatter.drive.date(from: s) ?? .distantPast
    }
}

extension ISO8601DateFormatter {
    static let drive: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let drivePlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum GoogleDriveAPIError: LocalizedError {
    case noAuth
    case network(Error)
    case http(status: Int, message: String)
    case badJSON
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAuth: return "Account not connected — go to Settings → Google Drive → Connect."
        case .network(let e): return "Network error (Drive): \(e.localizedDescription)"
        case .http(let s, let m):
            if s == 401 || s == 403 { return "Google rejected access (HTTP \(s)). Reconnect the account." }
            if s == 404 { return "File no longer exists on Drive (HTTP 404)." }
            if s == 429 { return "Google throttling (429) — wait a minute, then Sync again." }
            return m.isEmpty ? "Drive error (HTTP \(s))." : "Drive error (HTTP \(s)): \(m)"
        case .badJSON: return "Unexpected Drive API response."
        case .cancelled: return "Sync cancelled."
        }
    }
}

final class GoogleDriveAPI {
    static let folderMime = "application/vnd.google-apps.folder"
    /// Google Docs tipovi → export format za nativno čuvanje u mirroru
    /// (da fajl može da se otvori/duplim klikom i edituje).
    static let exportMap: [String: (ext: String, mime: String)] = [
        "application/vnd.google-apps.document":     ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        "application/vnd.google-apps.spreadsheet":  ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        "application/vnd.google-apps.presentation": ("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        "application/vnd.google-apps.drawing":      ("pdf",  "application/pdf"),
    ]

    static func isGoogleDoc(mime: String) -> Bool { exportMap[mime] != nil }
    static func isGoogleDoc(_ file: GoogleDriveFile) -> Bool { isGoogleDoc(mime: file.mimeType) }

    private let tokenProvider: () async throws -> String

    /// - Parameter tokenProvider: vraća važeći access token (osvežen po potrebi).
    init(tokenProvider: @escaping () async throws -> String) {
        self.tokenProvider = tokenProvider
    }

    // MARK: - Listanje

    struct FileList: Codable {
        var files: [GoogleDriveFile]?
        var nextPageToken: String?
    }

    /// Svi netrashed fajlovi (paginacija interno). Za tipičan nalog (<10k fajlova) je OK.
    /// fields bira samo potrebno da odgovori budu mali i brzi.
    func listAllFiles() async throws -> [GoogleDriveFile] {
        var all: [GoogleDriveFile] = []
        var pageToken: String? = nil
        repeat {
            let page = try await listPage(pageToken: pageToken)
            all.append(contentsOf: page.files ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    private func listPage(pageToken: String?) async throws -> FileList {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: "trashed = false"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,parents,modifiedTime,createdTime,size,trashed,webViewLink,md5Checksum)"),
            URLQueryItem(name: "orderBy", value: "folder,name"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "false"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        let data = try await get(url: comps.url!)
        guard let list = try? JSONDecoder().decode(FileList.self, from: data) else {
            throw GoogleDriveAPIError.badJSON
        }
        return list
    }

    // MARK: - Download / Export

    /// Skida binarni fajl (ne Google Docs) na temp pa atomski premešta na `destination`.
    func downloadFile(id: String, to destination: URL) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-gdrive-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await download(url: url, to: tmp)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    /// Export Google Docs/Sheets/Slides u Office/PDF format.
    func exportFile(id: String, exportMime: String, to destination: URL) async throws {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)/export")!
        comps.queryItems = [URLQueryItem(name: "mimeType", value: exportMime)]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-gdrive-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await download(url: comps.url!, to: tmp)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    // MARK: - Upload / Folderi / Trash

    struct CreatedFile: Codable { var id: String? }

    func createFolder(name: String, parentID: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!
        let body: [String: Any] = ["name": name, "mimeType": Self.folderMime, "parents": [parentID]]
        let data = try await postJSON(url: url, body: body)
        guard let created = try? JSONDecoder().decode(CreatedFile.self, from: data),
              let id = created.id else { throw GoogleDriveAPIError.badJSON }
        return id
    }

    /// Upload novog fajla (multipart). Vraća drive file id.
    func uploadFile(localURL: URL, name: String, parentID: String, mimeType: String) async throws -> String {
        let meta = ["name": name, "parents": [parentID]] as [String: Any]
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        let fileData = try Data(contentsOf: localURL)
        let boundary = "ff-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metaData)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw GoogleDriveAPIError.http(status: status, message: Self.apiMessage(data: data))
        }
        guard let created = try? JSONDecoder().decode(CreatedFile.self, from: data),
              let id = created.id else { throw GoogleDriveAPIError.badJSON }
        return id
    }

    /// Update sadržaja postojećeg fajla (media-only upload).
    func updateFileContent(driveID: String, localURL: URL, mimeType: String) async throws {
        let fileData = try Data(contentsOf: localURL)
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(driveID)?uploadType=media")!)
        req.httpMethod = "PATCH"
        req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        req.httpBody = fileData
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw GoogleDriveAPIError.http(status: status, message: Self.apiMessage(data: data))
        }
    }

    func trashFile(id: String) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        _ = try await patchJSON(url: url, body: ["trashed": true])
    }

    func fetchFile(id: String) async throws -> GoogleDriveFile {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        comps.queryItems = [URLQueryItem(name: "fields", value: "id,name,mimeType,parents,modifiedTime,createdTime,size,trashed,webViewLink,md5Checksum")]
        let data = try await get(url: comps.url!)
        guard let file = try? JSONDecoder().decode(GoogleDriveFile.self, from: data) else {
            throw GoogleDriveAPIError.badJSON
        }
        return file
    }

    // MARK: - HTTP primitives

    private func authorized(_ url: URL) async throws -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        return req
    }

    private func get(url: URL) async throws -> Data {
        let req = try await authorized(url)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                throw GoogleDriveAPIError.http(status: status, message: Self.apiMessage(data: data))
            }
            return data
        } catch let e as GoogleDriveAPIError {
            throw e
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw GoogleDriveAPIError.cancelled
            }
            throw GoogleDriveAPIError.network(error)
        }
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        var req = try await authorized(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw GoogleDriveAPIError.http(status: status, message: Self.apiMessage(data: data))
        }
        return data
    }

    private func patchJSON(url: URL, body: [String: Any]) async throws -> Data {
        var req = try await authorized(url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw GoogleDriveAPIError.http(status: status, message: Self.apiMessage(data: data))
        }
        return data
    }

    private func download(url: URL, to destination: URL) async throws {
        let req = try await authorized(url)
        do {
            let (tmpURL, response) = try await URLSession.shared.download(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                let msg = (try? String(contentsOf: tmpURL)) ?? ""
                throw GoogleDriveAPIError.http(status: status, message: msg)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmpURL, to: destination)
        } catch let e as GoogleDriveAPIError {
            throw e
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw GoogleDriveAPIError.cancelled
            }
            throw GoogleDriveAPIError.network(error)
        }
    }

    static func apiMessage(data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let msg = err["message"] as? String else { return "" }
        return msg
    }

    // MARK: - MIME pomoći

    /// Pogodi upload MIME iz ekstenzije (dovoljno za sync; Drive ionako sniffuje).
    static func mimeForLocalFile(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "md", "markdown": return "text/plain"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}
