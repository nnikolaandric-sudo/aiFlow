import Foundation
import ServiceManagement

actor SecureShareRelayClient {
    private var running: Task<Void, Never>?
    private var runID: UUID?
    private let appFallback: Bool
    init(appFallback: Bool = false) { self.appFallback = appFallback }
    private var helperOwnsConnection: Bool { appFallback && SMAppService.agent(plistName: "com.finderflow.share-agent.plist").status == .enabled }
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var generation = UUID()
    private var preparing: [String: Task<Void, Never>] = [:]
    private struct Transfer {
        let shareId: String
        let handle: FileHandle
        var remaining: Int64
        let activity: NSObjectProtocol
    }
    private var transfers: [String: Transfer] = [:]
    func start() { guard running == nil else { return }; let id = UUID(); runID = id; running = Task { await loop(id) } }
    func stop() {
        runID = nil; running?.cancel(); running = nil; disconnect()
    }
    private func disconnect() {
        generation = UUID(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        for task in preparing.values { task.cancel() }; preparing.removeAll()
        for id in Array(transfers.keys) { cancel(id) }
    }
    private func cancel(_ id: String) {
        preparing.removeValue(forKey: id)?.cancel()
        if let stream = transfers.removeValue(forKey: id) {
            try? stream.handle.close(); ProcessInfo.processInfo.endActivity(stream.activity)
        }
    }
    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)) }
    private func loop(_ id: UUID) async {
        var backoff: Double = 1
        while !Task.isCancelled && runID == id {
            do {
                if helperOwnsConnection { await pause(2); continue }
                let db = try SecureShareDatabase(); try db.cleanupSnapshots()
                guard let config = try db.configuration(), config.enabled, config.mode != "quick",
                      try db.shares().contains(where: { $0.status == "active" && ($0.expiresAt.map { $0 > Date().timeIntervalSince1970*1000 } ?? true) }) else { await pause(2); continue }
                let origin = try SecureShareAPI.validatedOrigin(config.origin)
                let token = try await SecureShareAPI(origin: origin).authenticate(deviceId: config.deviceId)
                try Task.checkCancellation()
                var parts = URLComponents(string: origin)!; parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/device"
                var request = URLRequest(url: parts.url!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let session = URLSession(configuration: .ephemeral, delegate: SecureShareSessionDelegate(), delegateQueue: nil)
                self.session = session
                let ws = session.webSocketTask(with: request); ws.maximumMessageSize = 8192; self.socket = ws; ws.resume()
                let connection = generation
                // Periodic cancellation checks let opt-out/expiry close an otherwise idle socket.
                let monitor = Task { [weak self] in
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); if Task.isCancelled { break }; await self?.checkConfiguration(connection) }
                }
                defer { monitor.cancel() }
                while !Task.isCancelled {
                    let message = try await ws.receive(); backoff = 1
                    guard case .string(let text) = message, let data = text.data(using: .utf8),
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SecureShareError.message("Invalid relay protocol.") }
                    try await receive(json, connection: connection)
                }
            } catch { /* No secrets, paths or document names are logged. Retry with bounded jitter. */ }
            if runID == id { disconnect() }
            if !Task.isCancelled { await pause(backoff + Double.random(in: 0...0.5)); backoff = min(60, backoff*2) }
        }
    }
    private func checkConfiguration(_ connection: UUID) {
        guard generation == connection else { return }
        if helperOwnsConnection { disconnect(); return }
        do {
            let db = try SecureShareDatabase()
            guard try db.configuration()?.enabled == true else { disconnect(); return }
            try db.cleanupSnapshots()
            let shares = try db.shares(), now = Date().timeIntervalSince1970*1000
            let active = Set(shares.filter { $0.status == "active" && ($0.expiresAt.map { $0 > now } ?? true) }.map(\.id))
            for (id, transfer) in transfers where !active.contains(transfer.shareId) { cancel(id) }
            for id in preparing.keys { Task { try? await self.send(["type":"preparing","requestId":id]) } }
            if active.isEmpty { disconnect() }
        } catch { disconnect() }
    }
    private func send(_ json: [String: Any]) async throws {
        guard let socket else { throw SecureShareError.message("Disconnected") }
        let text = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
        try await socket.send(.string(text))
    }
    private func allowed(_ share: SecureShareRecord, mode: String) throws {
        guard share.status == "active" else { throw SecureShareError.message("REVOKED") }
        if let expiry = share.expiresAt, expiry <= Date().timeIntervalSince1970*1000 { throw SecureShareError.message("EXPIRED") }
        guard (mode == "download" && share.allowDownload) || (mode == "preview" && share.allowPreview && SecureShareCrypto.previewSupported(share.mimeType)) else { throw SecureShareError.message("NOT_ALLOWED") }
    }
    private func receive(_ json: [String: Any], connection: UUID) async throws {
        guard generation == connection, let type = json["type"] as? String, let id = json["requestId"] as? String, id.utf8.count == 36, UUID(uuidString: id) != nil else { throw SecureShareError.message("Invalid relay request.") }
        switch type {
        case "cancel": cancel(id)
        case "fetch":
            guard transfers[id] == nil, preparing[id] == nil, transfers.count + preparing.count < 4,
                  let shareId = json["shareId"] as? String, UUID(uuidString: shareId) != nil,
                  let offset = json["offset"] as? Int64, let length = json["length"] as? Int64,
                  let mode = json["mode"] as? String, offset >= 0, length >= 0 else { try await send(["type":"error","requestId":id,"code":"BUSY"]); return }
            let head = json["head"] as? Bool ?? false
            preparing[id] = Task { await self.prepare(id, shareId: shareId, offset: offset, length: length, mode: mode, head: head, connection: connection) }
        case "pull":
            guard var stream = transfers[id], let amount = json["length"] as? Int, amount > 0, amount <= 256*1024, Int64(amount) <= stream.remaining else { throw SecureShareError.message("Invalid stream credit.") }
            do {
                let db = try SecureShareDatabase()
                guard let share = try db.share(stream.shareId), share.status == "active", share.expiresAt.map({ $0 > Date().timeIntervalSince1970*1000 }) ?? true else { throw SecureShareError.message("REVOKED") }
                guard let bytes = try stream.handle.read(upToCount: amount), bytes.count == amount else { throw SecureShareError.message("FILE_CHANGED") }
                stream.remaining -= Int64(amount); transfers[id] = stream
                guard let socket else { throw SecureShareError.message("Disconnected") }
                try await socket.send(.data(Data(id.utf8) + bytes))
                if stream.remaining == 0 { cancel(id) }
            } catch { cancel(id); try await send(["type":"error","requestId":id,"code":error.localizedDescription]) }
        default: throw SecureShareError.message("Unsupported relay message.")
        }
    }
    private func prepare(_ id: String, shareId: String, offset: Int64, length: Int64, mode: String, head: Bool, connection: UUID) async {
        do {
            let db = try SecureShareDatabase()
            guard let share = try db.share(shareId) else { throw SecureShareError.message("FILE_MISSING") }
            try allowed(share, mode: mode)
            guard offset <= share.size, length <= share.size-offset else { throw SecureShareError.message("INVALID_RANGE") }
            let preparation = Task.detached(priority: .utility) { try SecureShareSnapshot.open(share) }
            let handle = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
            guard !Task.isCancelled, generation == connection, preparing[id] != nil else { try? handle.close(); return }
            do {
                guard let fresh = try db.share(shareId) else { throw SecureShareError.message("FILE_MISSING") }
                try allowed(fresh, mode: mode); try handle.seek(toOffset: UInt64(offset))
            } catch { try? handle.close(); throw error }
            preparing.removeValue(forKey: id)
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Sending an explicitly shared file")
            transfers[id] = Transfer(shareId: shareId, handle: handle, remaining: length, activity: activity)
            try await send(["type":"headers","requestId":id,"size":share.size,"hash":share.fileHash])
            if head || length == 0 { cancel(id) }
        } catch {
            preparing.removeValue(forKey: id)
            if generation == connection { try? await send(["type":"error","requestId":id,"code":error.localizedDescription]) }
        }
    }
}
