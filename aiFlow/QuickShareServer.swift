import Foundation
import Network
import CommonCrypto
import AppKit
import PDFKit
import CryptoKit

/// Urezivanje potpisa sa linka u PDF: dodaje vektorsku stranicu-zapisnik na
/// kraj dokumenta (ime + datum + nacrtani potpis). Samo za application/pdf;
/// ostali tipovi ostaju sidecar + rename. Baca — pozivalac čuva original.
enum RemoteApprovalBurnError: Error {
    case unreadable
    case locked
    case badImage
    case renderFailed
}
enum RemoteApprovalBurn {
    static func burn(pdfData: Data, signaturePNG: Data, signerName: String, date: Date, sourceFilename: String) throws -> Data {
        guard let doc = PDFDocument(data: pdfData) else { throw RemoteApprovalBurnError.unreadable }
        if doc.isLocked { throw RemoteApprovalBurnError.locked }
        guard doc.pageCount > 0 else { throw RemoteApprovalBurnError.unreadable }
        guard let sigImage = NSImage(data: signaturePNG), sigImage.isValid,
              sigImage.size.width > 4, sigImage.size.height > 4 else { throw RemoteApprovalBurnError.badImage }
        let pageData = try approvalPage(signature: sigImage, name: signerName, date: date, source: sourceFilename)
        guard let approvalDoc = PDFDocument(data: pageData),
              let page = approvalDoc.page(at: 0) else { throw RemoteApprovalBurnError.renderFailed }
        doc.insert(page, at: doc.pageCount)
        var attrs = doc.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.authorAttribute] = signerName
        attrs[PDFDocumentAttribute.modificationDateAttribute] = date
        attrs[PDFDocumentAttribute.creatorAttribute] = "aiFlow Secure Share"
        doc.documentAttributes = attrs
        guard let out = doc.dataRepresentation() else { throw RemoteApprovalBurnError.renderFailed }
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Vektorska A4 stranica: tekst ostaje selektabilan, potpis ugrađen u
    // originalnoj rezoluciji. Koordinate sa (0,0) gore-levo (flipped).
    private static func approvalPage(signature: NSImage, name: String, date: Date, source: String) throws -> Data {
        let w: CGFloat = 595, h: CGFloat = 842
        var media = CGRect(x: 0, y: 0, width: w, height: h)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RemoteApprovalBurnError.renderFailed
        }
        ctx.beginPDFPage(nil)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        do {
            let ink = NSColor(srgbRed: 0.09, green: 0.14, blue: 0.12, alpha: 1)
            let muted = NSColor(srgbRed: 0.42, green: 0.49, blue: 0.46, alpha: 1)
            let accent = NSColor(srgbRed: 0.14, green: 0.36, blue: 0.26, alpha: 1)
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: w, height: h).fill()
            // Zelena traka na vrhu.
            accent.setFill()
            CGRect(x: 0, y: 0, width: w, height: 6).fill()
            var y: CGFloat = 44
            y = draw("FINDERFLOW · SIGNATURE RECORD", font: .systemFont(ofSize: 10, weight: .semibold), color: muted, x: 56, y: y, width: w - 112)
            y += 6
            y = draw("Signed via link", font: .systemFont(ofSize: 24, weight: .bold), color: ink, x: 56, y: y, width: w - 112)
            y += 10
            muted.setFill()
            CGRect(x: 56, y: y, width: w - 112, height: 1).fill()
            y += 18
            let shown = source.count > 70 ? "…" + source.suffix(69) : source
            y = draw("Document: \(shown)", font: .systemFont(ofSize: 11), color: muted, x: 56, y: y, width: w - 112)
            y += 4
            y = draw("Signed by: \(name)", font: .systemFont(ofSize: 14, weight: .semibold), color: ink, x: 56, y: y, width: w - 112)
            y += 4
            let fmt = DateFormatter()
            fmt.dateStyle = .medium; fmt.timeStyle = .short
            y = draw("Date: \(fmt.string(from: date))", font: .systemFont(ofSize: 11), color: muted, x: 56, y: y, width: w - 112)
            y += 22
            y = draw("Signature", font: .systemFont(ofSize: 11, weight: .semibold), color: ink, x: 56, y: y, width: w - 112)
            y += 8
            // Ram + potpis aspect-fit (bela pozadina ispod transparentnog PNG-a).
            let box = CGRect(x: 56, y: y, width: w - 112, height: 150)
            NSColor.white.setFill(); box.fill()
            NSColor(srgbRed: 0.78, green: 0.83, blue: 0.79, alpha: 1).setStroke()
            let border = NSBezierPath(rect: box); border.lineWidth = 1; border.stroke()
            let inset = box.insetBy(dx: 12, dy: 12)
            let size = signature.size
            let scale = min(inset.width / max(size.width, 1), inset.height / max(size.height, 1))
            let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: inset.midX - drawSize.width / 2, y: inset.midY - drawSize.height / 2)
            signature.draw(in: CGRect(origin: origin, size: drawSize))
            y = box.maxY + 10
            y = draw(name, font: NSFont(name: "SnellRoundhand", size: 20) ?? .systemFont(ofSize: 16), color: ink, x: 56, y: y, width: w - 112)
            y += 18
            _ = draw("Drawn by the recipient on the share page. The file name carries “(signed by \(name))” and the approval is logged in share activity.",
                     font: .systemFont(ofSize: 9), color: muted, x: 56, y: y, width: w - 112)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    private static func draw(_ text: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = text as NSString
        let rect = str.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin], attributes: attrs)
        str.draw(with: CGRect(x: x, y: y, width: width, height: ceil(rect.height)), options: [.usesLineFragmentOrigin], attributes: attrs)
        return y + ceil(rect.height)
    }
}

struct QuickShareHTTPError: Error { let status: Int; let code: String }
enum QuickSharePassword {
    static func digest(_ password: String, salt: Data) throws -> String {
        let bytes = Array(password.utf8); var output = [UInt8](repeating: 0, count: 32)
        let result = salt.withUnsafeBytes { raw in
            bytes.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &output, output.count)
            }
        }
        guard result == kCCSuccess else { throw SecureShareError.message("Unable to protect this password.") }
        return Data(output).base64EncodedString()
    }
    static func equal(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
struct QuickShareRange {
    let offset: Int64
    let length: Int64
    let partial: Bool
    static func parse(_ header: String?, size: Int64) throws -> Self {
        guard let header else { return Self(offset: 0, length: size, partial: false) }
        guard header.hasPrefix("bytes="), size > 0 else { throw QuickShareHTTPError(status: 416, code: "INVALID_RANGE") }
        let pieces = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }), !pieces.allSatisfy({ $0.isEmpty }) else { throw QuickShareHTTPError(status: 416, code: "INVALID_RANGE") }
        let start: Int64, end: Int64
        if pieces[0].isEmpty {
            guard let suffix = Int64(pieces[1]), suffix > 0 else { throw QuickShareHTTPError(status: 416, code: "INVALID_RANGE") }
            start = max(0, size - suffix); end = size - 1
        } else {
            guard let first = Int64(pieces[0]), first < size else { throw QuickShareHTTPError(status: 416, code: "INVALID_RANGE") }
            start = first
            if pieces[1].isEmpty { end = size - 1 }
            else { guard let last = Int64(pieces[1]) else { throw QuickShareHTTPError(status: 416, code: "INVALID_RANGE") }; end = min(last, size - 1) }
        }
        guard start <= end else { throw QuickShareHTTPError(status: 416, code: "INVALID_RANGE") }
        return Self(offset: start, length: end - start + 1, partial: true)
    }
}
private struct QuickHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    static func read(_ connection: NWConnection) async throws -> Self {
        var bytes = Data(), boundary: Range<Data.Index>?
        while boundary == nil {
            bytes.append(try await receive(connection))
            boundary = bytes.range(of: Data("\r\n\r\n".utf8))
            if (boundary?.lowerBound ?? bytes.count) > 16_384 { throw QuickShareHTTPError(status: 431, code: "HEADERS_TOO_LARGE") }
        }
        let split = boundary!
        guard let head = String(data: bytes[..<split.lowerBound], encoding: .utf8) else { throw QuickShareHTTPError(status: 400, code: "INVALID_HTTP") }
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET","HEAD","POST"].contains(String(first[0])), first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw QuickShareHTTPError(status: 400, code: "INVALID_HTTP") }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw QuickShareHTTPError(status: 400, code: "INVALID_HTTP") }
            let name = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else { throw QuickShareHTTPError(status: 400, code: "DUPLICATE_HEADER") }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { throw QuickShareHTTPError(status: 400, code: "TRANSFER_ENCODING_UNSUPPORTED") }
        let length: Int
        if let value = headers["content-length"] {
            // Approve nosi PNG potpisa pa dozvoli do 1MB; ostali endpointi
            // se i dalje ograniče na 16KB u handle().
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(value), number <= 1_048_576 else { throw QuickShareHTTPError(status: 413, code: "BODY_TOO_LARGE") }
            length = number
        } else { length = 0 }
        var body = Data(bytes[split.upperBound...])
        while body.count < length { body.append(try await receive(connection)) }
        // No pipelining or request smuggling: one exact request per connection.
        guard body.count == length else { throw QuickShareHTTPError(status: 400, code: "EXTRA_BYTES") }
        return Self(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else { cont.resume(throwing: QuickShareHTTPError(status: 400, code: done ? "INCOMPLETE_HTTP" : "EMPTY_HTTP")) }
            }
        }
    }
}

actor QuickShareServer {
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var origin = ""
    private var tasks: [UUID: Task<Void,Never>] = [:]
    private var connections: [UUID:NWConnection] = [:]
    private var transferShares: [UUID:String] = [:]
    private struct Session { let share: String; let hash: String; let expiry: Date; var granted: Bool }
    private var sessions: [String:Session] = [:]
    private var attempts: [String:(Date,Int)] = [:]
    private var hashing = 0
    private let resources: URL
    init(resources: URL) { self.resources = resources }
    func start() async throws -> UInt16 {
        if port != 0 { return port }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        listener.start(queue: DispatchQueue(label: "FinderFlow.quickshare.listener"))
        for _ in 0..<100 {
            if let actual = listener.port?.rawValue, actual != 0 { port = actual; return actual }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        stop(); throw SecureShareError.message("Unable to start private share service.")
    }
    func setOrigin(_ value: String) { origin = value }
    func stop() {
        listener?.cancel(); listener = nil; port = 0; origin = ""
        for connection in connections.values { connection.cancel() }
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); connections.removeAll(); transferShares.removeAll(); sessions.removeAll()
    }
    func sweep() {
        sessions = sessions.filter { $0.value.expiry > Date() }
        attempts = attempts.filter { Date().timeIntervalSince($0.value.0) < 60 }
        do {
            let db = try SecureShareDatabase()
            guard let config = try db.configuration(), config.mode == "quick", config.enabled else { stop(); return }
            for (connectionID, shareID) in transferShares {
                if let share = try db.share(shareID), share.status == "active", share.expiresAt.map({ $0 > Date().timeIntervalSince1970*1000 }) ?? true { continue }
                connections[connectionID]?.cancel(); tasks[connectionID]?.cancel()
            }
        } catch { stop() }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: Task { await self?.cancel(id) }; default: break }
        }
        connection.start(queue: DispatchQueue(label: "FinderFlow.quickshare.connection"))
        tasks[id] = Task { await handle(connection, id: id) }
    }
    private func cancel(_ id: UUID) { tasks.removeValue(forKey: id)?.cancel(); connections.removeValue(forKey: id)?.cancel(); transferShares.removeValue(forKey: id) }
    private func rate(_ key: String, max: Int) throws {
        let now = Date(), old = attempts[key]
        let count = (old.map { now.timeIntervalSince($0.0) < 60 } ?? false) ? old!.1 + 1 : 1
        let start = (old.map { now.timeIntervalSince($0.0) < 60 } ?? false) ? old!.0 : now
        guard count <= max else { throw QuickShareHTTPError(status: 429, code: "RATE_LIMITED") }
        attempts[key] = (start,count)
    }
    private func status(_ share: SecureShareRecord) -> String {
        if share.status != "active" { return "REVOKED" }
        if let expiry = share.expiresAt, expiry <= Date().timeIntervalSince1970*1000 { return "EXPIRED" }
        return "ONLINE"
    }
    private func validate(_ share: SecureShareRecord) throws {
        let state = status(share)
        guard state == "ONLINE" else { throw QuickShareHTTPError(status: 410, code: state) }
    }
    private func metadata(_ share: SecureShareRecord, access: [String:Any], granted: Bool = false) -> [String:Any] {
        ["id":share.id,"filename":share.filename,"mimeType":share.mimeType,"size":share.size,"allowPreview":share.allowPreview,"allowDownload":share.allowDownload,"expiresAt":share.expiresAt as Any? ?? NSNull(),"status":status(share),"downloadCount":access["downloads"] ?? 0,"viewCount":access["views"] ?? 0,"maxDownloads":share.maxDownloads as Any? ?? NSNull(),"downloadGranted":granted,"requireSignature":share.requireSignature,"approvalName":share.approvalName as Any? ?? NSNull(),"approvalAt":share.approvalAt as Any? ?? NSNull()]
    }
    private func validApprovalName(_ raw: Any?) throws -> String {
        guard let text = raw as? String else { throw QuickShareHTTPError(status: 400, code: "INVALID_NAME") }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !name.isEmpty, name.count <= 100, name.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 && $0.value != 127 }) else {
            throw QuickShareHTTPError(status: 400, code: "INVALID_NAME")
        }
        return name
    }
    private func validApprovalSignature(_ raw: Any?) throws -> Data {
        guard let url = raw as? String, url.hasPrefix("data:image/png;base64,") else { throw QuickShareHTTPError(status: 400, code: "INVALID_SIGNATURE") }
        let b64 = String(url.dropFirst(22))
        guard b64.count >= 100, b64.count <= 700_000, let data = Data(base64Encoded: b64),
              data.count >= 200, data.count <= 500_000,
              data.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]) else {
            throw QuickShareHTTPError(status: 400, code: "INVALID_SIGNATURE")
        }
        return data
    }
    private func write(_ connection: NWConnection, _ data: Data) async throws {
        try Task.checkCancellation()
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now()+60, execute: timeout)
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func headers(status: Int, size: Int64, type: String, extra: [String:String] = [:]) -> Data {
        var values = ["Content-Type":type,"Content-Length":String(size),"Connection":"close","Cache-Control":"private, no-store","Referrer-Policy":"no-referrer","X-Content-Type-Options":"nosniff","X-Frame-Options":"SAMEORIGIN","Content-Security-Policy":"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-src 'self'; media-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'","Strict-Transport-Security":"max-age=31536000"]
        values.merge(extra) { _, new in new }
        return Data(("HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\n" + values.map { "\($0): \($1)\r\n" }.joined() + "\r\n").utf8)
    }
    private func json(_ connection: NWConnection, status: Int = 200, _ value: [String:Any], extra: [String:String] = [:], head: Bool = false) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await write(connection, headers(status: status, size: Int64(data.count), type: "application/json; charset=utf-8", extra: extra))
        if !head { try await write(connection,data) }
    }
    private func handle(_ connection: NWConnection, id: UUID) async {
        var started = false, extraErrorHeaders: [String:String] = [:], head = false
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now()+15, execute: timeout)
        defer { timeout.cancel(); cancel(id) }
        do {
            let request = try await QuickHTTPRequest.read(connection); timeout.cancel(); head = request.method == "HEAD"
            guard !origin.isEmpty, request.headers["host"] == "127.0.0.1:\(port)" else { throw QuickShareHTTPError(status: 400, code: "INVALID_HOST") }
            if let source = request.headers["origin"], source != origin { throw QuickShareHTTPError(status: 403, code: "INVALID_ORIGIN") }
            if request.method == "POST", request.headers["sec-fetch-site"] == "cross-site" { throw QuickShareHTTPError(status: 403, code: "INVALID_ORIGIN") }
            try rate("all",max:3000)
            guard let url = URLComponents(string: origin + request.target) else { throw QuickShareHTTPError(status:400,code:"INVALID_URL") }
            let db = try SecureShareDatabase()
            guard let config = try db.configuration(), config.mode == "quick", config.enabled else { throw QuickShareHTTPError(status:503,code:"OFFLINE") }
            if ["/s","/app.js","/style.css"].contains(url.path), request.method == "GET" || head {
                let file = url.path == "/s" ? "index.html" : String(url.path.dropFirst())
                let data = try Data(contentsOf: resources.appendingPathComponent(file))
                let type = file == "index.html" ? "text/html" : (file == "app.js" ? "text/javascript" : "text/css")
                started = true; try await write(connection, headers(status:200,size:Int64(data.count),type:type+"; charset=utf-8"))
                if !head { try await write(connection,data) }; return
            }
            if url.path == "/v1/share-session", request.method == "POST" {
                guard request.body.count <= 16_384,
                      request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                      let body = try JSONSerialization.jsonObject(with: request.body) as? [String:Any], let token = body["token"] as? String, token.utf8.count == 43 else { throw QuickShareHTTPError(status:400,code:"INVALID_REQUEST") }
                try rate("sessions",max:120)
                guard let access = try db.quickAccess(tokenHash: SecureShareCrypto.hash(Data(token.utf8))), let shareID = access["id"] as? String,
                      let share = try db.share(shareID) else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }
                try validate(share); try rate(shareID,max:20)
                if let expected = access["password_hash"] as? String, let saltText = access["salt"] as? String, let salt = Data(base64Encoded:saltText) {
                    guard let password = body["password"] as? String, !password.isEmpty else { throw QuickShareHTTPError(status:401,code:"PASSWORD_REQUIRED") }
                    guard password.utf8.count <= 1024, hashing < 2 else { throw QuickShareHTTPError(status:429,code:"BUSY") }
                    hashing += 1
                    do {
                        let actual = try await Task.detached { try QuickSharePassword.digest(password,salt:salt) }.value
                        hashing -= 1
                        guard QuickSharePassword.equal(expected,actual) else { throw QuickShareHTTPError(status:401,code:"INVALID_PASSWORD") }
                    } catch { if !(error is QuickShareHTTPError) { hashing -= 1 }; throw error }
                }
                guard let current = try db.share(shareID) else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }; try validate(current)
                sessions = sessions.filter { $0.value.expiry > Date() }
                guard sessions.count < 1000 else { throw QuickShareHTTPError(status:429,code:"BUSY") }
                let sessionID = UUID().uuidString.lowercased(), cookie = try SecureShareCrypto.token()
                sessions[sessionID] = Session(share:shareID,hash:SecureShareCrypto.hash(Data(cookie.utf8)),expiry:Date().addingTimeInterval(900),granted:false)
                try db.quickView(shareID)
                var result = metadata(current,access:try db.quickAccess(id:shareID) ?? access); result["sessionId"] = sessionID
                started = true
                try await json(connection,result,extra:["Set-Cookie":"ff_access=\(cookie); HttpOnly; SameSite=Strict; Path=/r/\(sessionID)/; Max-Age=900\(origin.hasPrefix("https:") ? "; Secure" : "")"]); return
            }
            let path = url.path.split(separator:"/")
            guard path.count == 3, path[0] == "r", UUID(uuidString:String(path[1])) != nil, ["GET","HEAD","POST"].contains(request.method) else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }
            let sessionID = String(path[1])
            let cookie = request.headers["cookie"]?.components(separatedBy:";").map { $0.trimmingCharacters(in:.whitespaces) }.first { $0.hasPrefix("ff_access=") }.map { String($0.dropFirst(10)) } ?? ""
            guard var session = sessions[sessionID], session.expiry > Date(), QuickSharePassword.equal(session.hash,SecureShareCrypto.hash(Data(cookie.utf8))) else { throw QuickShareHTTPError(status:401,code:"SESSION_EXPIRED") }
            guard let share = try db.share(session.share), let access = try db.quickAccess(id:share.id) else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }; try validate(share)
            if path[2] == "metadata" {
                guard request.method == "GET" || head else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }
                started = true; try await json(connection,metadata(share,access:access,granted:session.granted),head:head); return
            }
            if path[2] == "approve" {
                guard request.method == "POST" else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }
                try rate("approve:\(share.id)",max:20)
                guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
                      let payload = try JSONSerialization.jsonObject(with: request.body) as? [String:Any] else { throw QuickShareHTTPError(status:400,code:"INVALID_REQUEST") }
                var fresh = share
                guard fresh.approvalName == nil else { throw QuickShareHTTPError(status:409,code:"ALREADY_SIGNED") }
                let name = try validApprovalName(payload["name"])
                let png = try validApprovalSignature(payload["signature"])
                // Jednom: preimenuj logički filename u "… (signed by Ime).ext",
                // sačuvaj PNG potpisa pored snapshot-a za audit vlasnika.
                // PDF se urezuje: potpis postaje poslednja stranica kopije.
                fresh.approvalName = name
                fresh.approvalAt = (Date().timeIntervalSince1970*1000).rounded(.down)
                fresh.filename = SecureShareRecord.approvedFilename(original: fresh.filename, signer: name)
                var burnFailed = false
                if fresh.mimeType == "application/pdf" {
                    do {
                        let snapURL = SecureSharePaths.snapshots.appendingPathComponent(fresh.id)
                        let pdfData = try Data(contentsOf: snapURL)
                        let burned = try RemoteApprovalBurn.burn(pdfData: pdfData, signaturePNG: png, signerName: name, date: Date(timeIntervalSince1970: (fresh.approvalAt ?? Date().timeIntervalSince1970*1000)/1000), sourceFilename: share.filename)
                        try burned.write(to: snapURL, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: snapURL.path)
                        fresh.size = Int64(burned.count)
                        fresh.fileHash = RemoteApprovalBurn.sha256Hex(burned)
                    } catch { burnFailed = true }
                }
                try db.save(fresh)
                let sidecar = SecureSharePaths.snapshots.appendingPathComponent("\(fresh.id).approval.png")
                try? png.write(to: sidecar, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: sidecar.path)
                try? db.quickEvent(fresh.id, "approved")
                if burnFailed { try? db.quickEvent(fresh.id, "burn_failed") }
                guard let latest = try db.share(fresh.id), let latestAccess = try db.quickAccess(id:fresh.id) else { throw QuickShareHTTPError(status:404,code:"NOT_FOUND") }
                started = true; try await json(connection,metadata(latest,access:latestAccess,granted:session.granted)); return
            }
            guard path[2] == "content", let mode = url.queryItems?.first(where:{$0.name == "mode"})?.value, ["preview","download"].contains(mode) else { throw QuickShareHTTPError(status:400,code:"INVALID_MODE") }
            guard mode == "preview" ? share.allowPreview && SecureShareCrypto.previewSupported(share.mimeType) : share.allowDownload else { throw QuickShareHTTPError(status:403,code:"NOT_ALLOWED") }
            guard transferShares.count < 4 else { throw QuickShareHTTPError(status:429,code:"BUSY") }
            extraErrorHeaders["Content-Range"] = "bytes */\(share.size)"
            let etag = "\"\(share.fileHash)\""
            let range = try QuickShareRange.parse(request.headers["if-range"].map({ $0 != etag }) == true ? nil : request.headers["range"],size:share.size)
            extraErrorHeaders.removeAll()
            if mode == "download", !head, !session.granted {
                guard try db.quickReserve(share.id,limit:share.maxDownloads) else { throw QuickShareHTTPError(status:403,code:"DOWNLOAD_LIMIT_REACHED") }
                session.granted = true; sessions[sessionID] = session
            }
            transferShares[id] = share.id
            let activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"Sending a file through Cloudflare Quick Tunnel")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let preparation = Task.detached(priority:.utility) { try SecureShareSnapshot.open(share) }
            let handle = try await withTaskCancellationHandler(operation:{ try await preparation.value },onCancel:{ preparation.cancel() }); defer { try? handle.close() }
            guard let current = try db.share(share.id) else { throw QuickShareHTTPError(status:404,code:"FILE_MISSING") }; try validate(current)
            try handle.seek(toOffset:UInt64(range.offset))
            let filename = current.filename.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? "download"
            var extra = ["Accept-Ranges":"bytes","ETag":etag,"Content-Disposition":"\(mode == "preview" ? "inline" : "attachment"); filename=\"download\"; filename*=UTF-8''\(filename)"]
            if range.partial { extra["Content-Range"] = "bytes \(range.offset)-\(range.offset+range.length-1)/\(share.size)" }
            started = true; try await write(connection,headers(status:range.partial ? 206 : 200,size:range.length,type:SecureShareCrypto.previewContentType(share.mimeType),extra:extra))
            if head { return }
            var remaining = range.length
            while remaining > 0 {
                guard let latest = try db.share(share.id), try db.configuration()?.enabled == true else { throw QuickShareHTTPError(status:410,code:"REVOKED") }; try validate(latest)
                let count = Int(min(256*1024,remaining))
                guard let bytes = try handle.read(upToCount:count), bytes.count == count else { throw QuickShareHTTPError(status:409,code:"FILE_CHANGED") }
                try await write(connection,bytes); remaining -= Int64(bytes.count)
            }
            try? db.quickEvent(share.id,range.partial ? "range_completed" : (mode == "download" ? "download_completed" : "preview_completed"))
        } catch {
            if !started, !Task.isCancelled {
                let failure = error as? QuickShareHTTPError
                let code = failure?.code ?? (["FILE_MISSING","FILE_CHANGED"].contains(error.localizedDescription) ? error.localizedDescription : "FILE_UNAVAILABLE")
                try? await json(connection,status:failure?.status ?? 409,["error":code],extra:extraErrorHeaders,head:head)
            }
        }
    }
}
