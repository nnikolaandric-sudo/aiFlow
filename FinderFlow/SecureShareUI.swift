import SwiftUI
import AppKit
import ServiceManagement
import CryptoKit

@MainActor
final class SecureShareManager: ObservableObject {
    static let shared = SecureShareManager()
    @Published var shares: [SecureShareRecord] = []
    @Published var remote: [String: [String: Any]] = [:]
    @Published var configuration: SecureShareConfiguration?
    @Published var busy = false
    @Published var message: String?
    @Published var backgroundEnabled = false
    private let quick = QuickShareRuntime(appFallback: true)
    @Published var tunnelStatus = "A temporary Cloudflare link starts when you share a file."
    private let relay = SecureShareRelayClient(appFallback: true)
    private let service = SMAppService.agent(plistName: "com.finderflow.share-agent.plist")
    private var sealing = Set<String>()
    private init() {
        do { let db = try SecureShareDatabase(); configuration = try db.configuration(); shares = try db.shares() }
        catch { message = error.localizedDescription }
        backgroundEnabled = service.status == .enabled
        if configuration == nil {
            configuration = SecureShareConfiguration(origin: "", deviceId: UUID().uuidString.lowercased(), enabled: true, mode: "quick")
            try? SecureShareDatabase().configure(configuration!)
        }
        Task { [weak self] in
            while let self {
                await self.updateAgent()
                if self.configuration?.mode == "quick" { await self.refresh() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    static func resumeIfConfigured() {
        if FileManager.default.fileExists(atPath: SecureSharePaths.root.appendingPathComponent("shares.sqlite").path) { _ = shared }
    }
    private func updateAgent() async {
        if configuration?.mode == "quick" {
            await relay.stop()
            if configuration?.enabled == true { await quick.start() } else { await quick.stop() }
        } else {
            await quick.stop()
            if configuration?.enabled == true && !backgroundEnabled { await relay.start() } else { await relay.stop() }
        }
    }
    private func readTunnelStatus() {
        guard configuration?.mode == "quick" else { return }
        let status = QuickShareStatus.read()
        configuration?.origin = status?.origin ?? ""
        tunnelStatus = configuration?.enabled == true ? (status?.message ?? "The temporary link will start when a file is shared.") : "Internet sharing is off."
    }
    private func readyOrigin() async throws -> String {
        await updateAgent()
        for _ in 0..<90 {
            guard configuration?.enabled == true else { throw SecureShareError.message("Internet sharing is off.") }
            readTunnelStatus()
            if let origin = configuration?.origin, !origin.isEmpty { return origin }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw SecureShareError.message("Cloudflare could not connect yet. Check your internet connection, then use Copy Link in Your links.")
    }
    func connect(origin: String, code: String) async {
        busy = true; message = nil; defer { busy = false }
        do {
            let canonical = try SecureShareAPI.validatedOrigin(origin)
            if let old = configuration, old.origin != canonical, !shares.isEmpty { throw SecureShareError.message("This share registry belongs to a different server. Keep that server configured to manage its existing links.") }
            let id = try await SecureShareAPI(origin: canonical).register(code: code, name: Host.current().localizedName ?? "Mac")
            let config = SecureShareConfiguration(origin: canonical, deviceId: id, enabled: true)
            try SecureShareDatabase().configure(config); configuration = config; await updateAgent(); await refresh()
        } catch { message = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool) async {
        guard var config = configuration else { return }
        do { config.enabled = enabled; try SecureShareDatabase().configure(config); configuration = config; await updateAgent() }
        catch { message = error.localizedDescription }
    }
    func setBackground(_ enabled: Bool) async {
        do {
            if enabled { try service.register() } else { try await service.unregister() }
            backgroundEnabled = service.status == .enabled
            if enabled && !backgroundEnabled { message = "Allow aiFlow in System Settings → General → Login Items & Extensions. Sharing continues while aiFlow is running." }
            await updateAgent()
        } catch { message = "Background agent: \(error.localizedDescription). Sharing continues while aiFlow is running." }
    }
    func refresh() async {
        do {
            let db = try SecureShareDatabase(); shares = try db.shares()
            guard let config = configuration else { return }
            if config.mode == "quick" {
                readTunnelStatus()
                remote = Dictionary(uniqueKeysWithValues: try shares.map { share in
                    let counts = try db.quickAccess(id: share.id) ?? [:]
                    let status = share.status != "active" ? "REVOKED" : ((share.expiresAt.map { $0 <= Date().timeIntervalSince1970*1000 } ?? false) ? "EXPIRED" : ((configuration?.origin.isEmpty ?? true) ? "OFFLINE" : "ONLINE"))
                    return (share.id, ["status": status, "viewCount": counts["views"] ?? 0, "downloadCount": counts["downloads"] ?? 0, "expiresAt": share.expiresAt as Any? ?? NSNull()] as [String:Any])
                })
                return
            }
            let api = SecureShareAPI(origin: config.origin), token = try await api.authenticate(deviceId: config.deviceId)
            let result = try await api.request("/v1/shares", method: "GET", token: token)
            let entries = result["shares"] as? [[String: Any]] ?? []
            remote = Dictionary(uniqueKeysWithValues: entries.compactMap { row in (row["id"] as? String).map { ($0,row) } })
            // Sync potpisa sa servera: ako je primalac potpisao, preimenuj
            // lokalni filename u "… (signed by Ime).ext" da vlasnik vidi u listi.
            // PDF se zatim urezuje lokalno (sealApprovedShare) i hash se gura
            // nazad na server da sledeći download nosi zapečaćenu kopiju.
            var changed = false
            var newlyApproved: [String] = []
            for row in entries {
                guard let id = row["id"] as? String,
                      let approval = row["approvalName"] as? String,
                      !approval.isEmpty,
                      var local = try db.share(id),
                      local.approvalName == nil else { continue }
                local.approvalName = approval
                local.approvalAt = row["approvalAt"] as? Double
                if let serverName = row["filename"] as? String, !serverName.isEmpty {
                    local.filename = serverName
                } else {
                    local.filename = SecureShareRecord.approvedFilename(original: local.filename, signer: approval)
                }
                try db.save(local); changed = true
                newlyApproved.append(id)
            }
            if changed { shares = try db.shares() }
            for id in newlyApproved { Task { await self.sealApprovedShare(id) } }
        } catch { message = error.localizedDescription }
    }
    func create(url: URL, hours: Int, customExpiry: Date?, preview: Bool, download: Bool, password: String, maxDownloads: Int?, requireSignature: Bool = false) async -> String? {
        await create(urls: [url], hours: hours, customExpiry: customExpiry, preview: preview, download: download, password: password, maxDownloads: maxDownloads, requireSignature: requireSignature)
    }
    /// Deljenje više datoteka/foldera: pakuje se u jedan .zip (vidi
    /// SecureShareBundle) pa ide istim protokolom kao jedan fajl.
    /// Limiti protiv preopterećenja: max 10 stavki, 1000 fajlova unutra,
    /// 500 MB ukupno — prekoračenje javlja jasnu grešku umesto tihog pucanja.
    func create(urls: [URL], hours: Int, customExpiry: Date?, preview: Bool, download: Bool, password: String, maxDownloads: Int?, requireSignature: Bool = false) async -> String? {
        guard let config = configuration, config.enabled else { message = "Enable internet sharing first."; return nil }
        busy = true; message = nil; defer { busy = false }
        var pending: SecureShareRecord?
        do {
            guard preview || download else { throw SecureShareError.message("Enable Preview or Download.") }
            guard password.isEmpty || (password.count >= 8 && password.count <= 256) else { throw SecureShareError.message("Use a password between 8 and 256 characters.") }
            let expiry = customExpiry.map { $0.timeIntervalSince1970 * 1000 } ?? (hours == 0 ? nil : Date().addingTimeInterval(Double(hours)*3600).timeIntervalSince1970*1000)
            let expiresAt = expiry.map { $0.rounded(.down) }
            let inputs = urls.filter { !$0.path.isEmpty }
            guard !inputs.isEmpty else { throw SecureShareError.message("Select at least one file or folder first.") }
            guard inputs.count <= SecureShareLimits.maxItems else { throw SecureShareError.message("Select up to \(SecureShareLimits.maxItems) items (you selected \(inputs.count)). Split it into smaller shares.") }
            var record = try await Task.detached(priority: .userInitiated) { try SecureShareBundle.createRecord(urls: inputs, expiry: expiresAt, preview: preview, download: download, limit: maxDownloads, requireSignature: requireSignature) }.value
            guard record.allowPreview || record.allowDownload else { try? FileManager.default.removeItem(at: SecureSharePaths.snapshots.appendingPathComponent(record.id)); throw SecureShareError.message("This format supports download only. Enable Download to share it.") }
            pending = record
            let db = try SecureShareDatabase(), rawToken = try SecureShareCrypto.token()
            try db.save(record)
            try SecureShareKeychain.save(Data(rawToken.utf8), account: "share:\(record.id)")
            if config.mode == "quick" {
                let salt = Data((try SecureShareCrypto.token()).utf8)
                let hash = password.isEmpty ? nil : try await Task.detached { try QuickSharePassword.digest(password, salt: salt) }.value
                try db.quickCreate(id: record.id, tokenHash: SecureShareCrypto.hash(Data(rawToken.utf8)), salt: hash == nil ? nil : salt.base64EncodedString(), passwordHash: hash)
                record.status = "active"; try db.save(record); pending = nil
                try reloadLocal()
                let origin = try await readyOrigin()
                await refresh()
                return origin + "/s#" + rawToken
            }
            let api = SecureShareAPI(origin: config.origin), access = try await api.authenticate(deviceId: config.deviceId)
            var payload: [String: Any] = ["id":record.id,"tokenHash":SecureShareCrypto.hash(Data(rawToken.utf8)),"filename":record.filename,"mimeType":record.mimeType,"size":record.size,"fileHash":record.fileHash,"allowPreview":record.allowPreview,"allowDownload":record.allowDownload,"expiresAt":record.expiresAt as Any? ?? NSNull(),"maxDownloads":record.maxDownloads as Any? ?? NSNull(),"requireSignature":record.requireSignature]
            if !password.isEmpty { payload["password"] = password }
            _ = try await api.request("/v1/shares", body: payload, token: access)
            record.status = "active"; try db.save(record); pending = nil
            await updateAgent(); await refresh()
            return config.origin + "/s#" + rawToken
        } catch {
            // An ambiguous server response never exposes a link to an uncommitted local share.
            if var record = pending { record.status = "revoked"; try? SecureShareDatabase().save(record); try? SecureShareDatabase().cleanupSnapshots() }
            message = error.localizedDescription; try? reloadLocal(); return nil
        }
    }
    private func reloadLocal() throws { shares = try SecureShareDatabase().shares() }
    /// 1-klik deljenje: fiksni 24h link (preview + download, bez lozinke),
    /// odmah kopiran u clipboard, bez otvaranja prozora. Baca toast preko
    /// `.ffQuickLinkFeedback` — uspeh ("Link copied — valid 24h") ili greška.
    /// Koriste ga desni klik, toolbar, selection bar i File ▸ Quick Link.
    /// Radi i za više stavki/foldere: pakuje u jedan .zip (limiti iz
    /// SecureShareLimits — detaljna provera veličine tek u pozadini).
    static func canQuickLink(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, urls.count <= SecureShareLimits.maxItems else { return false }
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isSymbolicLink == true || values?.isPackage == true { return false }
            if values?.ubiquitousItemDownloadingStatus == .notDownloaded { return false }
            guard values?.isRegularFile == true || values?.isDirectory == true else { return false }
        }
        return true
    }
    /// Naslov za menije: "Create Secure Link…" / "Share 3 Items…".
    static func shareMenuTitle(for urls: [URL]) -> String {
        if urls.count <= 1 { return "Create Secure Link…" }
        return "Share \(urls.count) Items…"
    }
    func quickLink(for url: URL) async {
        await quickLink(for: [url])
    }
    func quickLink(for urls: [URL]) async {
        NotificationCenter.default.post(name: .ffQuickLinkStarted, object: nil)
        guard configuration?.enabled != false else {
            NotificationCenter.default.post(name: .ffQuickLinkFeedback, object: nil,
                userInfo: ["message": "Enable internet sharing first.", "success": false])
            return
        }
        guard let link = await create(urls: urls, hours: 24, customExpiry: nil,
                                      preview: true, download: true,
                                      password: "", maxDownloads: nil) else {
            NotificationCenter.default.post(name: .ffQuickLinkFeedback, object: nil,
                userInfo: ["message": message ?? "Couldn't create link.", "success": false])
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        NotificationCenter.default.post(name: .ffExternalPasteboardWrite, object: nil)
        NotificationCenter.default.post(name: .ffQuickLinkFeedback, object: nil,
            userInfo: ["message": "Link copied — valid 24h", "success": true])
    }
    func copyLink(_ record: SecureShareRecord) async {
        busy = true; message = nil; defer { busy = false }
        do {
            guard configuration?.enabled == true else { throw SecureShareError.message("Enable internet sharing first.") }
            if configuration?.mode == "quick" { _ = try await readyOrigin() }
            guard record.status == "active", let origin = configuration?.origin, let data = try SecureShareKeychain.read("share:\(record.id)"), let token = String(data: data, encoding: .utf8) else { throw SecureShareError.message("This link is not available in Keychain.") }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(origin + "/s#" + token, forType: .string)
        } catch { message = error.localizedDescription }
    }
    func revoke(_ record: SecureShareRecord) async {
        busy = true; message = nil; defer { busy = false }
        do {
            let db = try SecureShareDatabase(); var local = record; local.status = "revoked"
            try db.save(local); try reloadLocal() // Deny locally even if the server is unreachable.
            guard let config = configuration else { return }
            if config.mode == "quick" { try db.cleanupSnapshots(); await refresh(); return }
            let api = SecureShareAPI(origin: config.origin), token = try await api.authenticate(deviceId: config.deviceId)
            _ = try await api.request("/v1/shares/\(record.id)/revoke", token: token)
            try db.cleanupSnapshots(); await refresh()
        } catch { message = "Blocked on this Mac. Server revocation still needs retry: \(error.localizedDescription)" }
    }
    func deleteShares(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            let db = try SecureShareDatabase()
            let byId = Dictionary(uniqueKeysWithValues: shares.map { ($0.id, $0) })
            // Managed server: best-effort revoke pre lokalnog brisanja.
            // Quick mod nema server — dovoljan je lokalni delete.
            if let config = configuration, config.mode != "quick", !config.origin.isEmpty {
                for id in ids {
                    guard let rec = byId[id], rec.status == "active" else { continue }
                    do {
                        let api = SecureShareAPI(origin: config.origin)
                        let token = try await api.authenticate(deviceId: config.deviceId)
                        _ = try await api.request("/v1/shares/\(rec.id)/revoke", token: token)
                    } catch {
                        // Lokalno brisanje je primarno — link umire na ovom Mac-u
                        // čak i kad server nije dostupan (isti princip kao revoke).
                        continue
                    }
                }
            }
            for id in ids {
                try? db.delete(id: id)
                SecureShareKeychain.delete("share:\(id)")
            }
            try reloadLocal()
            try? db.cleanupSnapshots()
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func renew(_ record: SecureShareRecord) async {
        busy = true; message = nil; defer { busy = false }
        do {
            guard record.status == "active", FileManager.default.fileExists(atPath: SecureSharePaths.snapshots.appendingPathComponent(record.id).path), let config = configuration else { throw SecureShareError.message("The snapshot is no longer available. Create a new link from the original file.") }
            let expiry = (Date().addingTimeInterval(86400).timeIntervalSince1970*1000).rounded(.down)
            // Retain the snapshot before waiting on the network. Cloud expiry still
            // controls access if the renewal response is lost or the server rejects it.
            var local = record; local.expiresAt = expiry; try SecureShareDatabase().save(local)
            guard FileManager.default.fileExists(atPath: SecureSharePaths.snapshots.appendingPathComponent(record.id).path) else { throw SecureShareError.message("Snapshot expired during renewal. Create a new link.") }
            if config.mode == "quick" { await refresh(); return }
            let api = SecureShareAPI(origin: config.origin), token = try await api.authenticate(deviceId: config.deviceId)
            _ = try await api.request("/v1/shares/\(record.id)/renew", body: ["expiresAt":expiry], token: token)
            await refresh()
        } catch { message = "Server extension is not confirmed. Retry or create a new link: \(error.localizedDescription)" }
    }
    func audit(_ record: SecureShareRecord) async -> String {
        do {
            guard let config = configuration else { return "No server configured." }
            if config.mode == "quick" {
                return try SecureShareDatabase().quickEvents(record.id).map { row in
                    Date(timeIntervalSince1970: ((row["created_at"] as? Double) ?? 0)/1000).formatted() + " — " + (row["kind"] as? String ?? "event").replacingOccurrences(of:"_",with:" ")
                }.joined(separator:"\n")
            }
            let api = SecureShareAPI(origin: config.origin), token = try await api.authenticate(deviceId: config.deviceId)
            let result = try await api.request("/v1/shares/\(record.id)/events", method: "GET", token: token)
            return (result["events"] as? [[String: Any]] ?? []).map { row in
                let stamp = (row["created_at"] as? NSNumber)?.doubleValue ?? Double(row["created_at"] as? String ?? "") ?? 0
                return Date(timeIntervalSince1970: stamp/1000).formatted() + " — " + (row["kind"] as? String ?? "event").replacingOccurrences(of: "_", with: " ")
            }.joined(separator: "\n")
        } catch { return error.localizedDescription }
    }
    /// PNG potpisa za prikaz vlasniku (sheet u listi). Quick: lokalni sidecar;
    /// managed: approval endpoint na serveru. Vraća dataURL ili nil.
    func approvalImage(_ record: SecureShareRecord) async -> String? {
        do {
            if configuration?.mode == "quick" {
                let url = SecureSharePaths.snapshots.appendingPathComponent("\(record.id).approval.png")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return "data:image/png;base64," + data.base64EncodedString()
            }
            guard let config = configuration, !config.origin.isEmpty else { return nil }
            let api = SecureShareAPI(origin: config.origin), token = try await api.authenticate(deviceId: config.deviceId)
            let result = try await api.request("/v1/shares/\(record.id)/approval", method: "GET", token: token)
            return result["approvalSignature"] as? String
        } catch { return nil }
    }
    /// Managed lazy seal: posle refresh-synca approvala ureži potpis u lokalni
    /// PDF snapshot i gurni novi hash/size na server (/sealed). Samo PDF;
    /// ostalo ostaje sidecar + rename. Marker `.sealed` sprečava retry petlju.
    private func sealApprovedShare(_ id: String) async {
        guard !sealing.contains(id) else { return }
        sealing.insert(id); defer { sealing.remove(id) }
        do {
            guard let config = configuration, config.mode != "quick", !config.origin.isEmpty else { return }
            guard var local = try SecureShareDatabase().share(id),
                  let signer = local.approvalName, !signer.isEmpty,
                  local.status == "active",
                  local.mimeType == "application/pdf" else { return }
            let marker = SecureSharePaths.snapshots.appendingPathComponent("\(id).sealed")
            if FileManager.default.fileExists(atPath: marker.path) { return }
            let snapURL = SecureSharePaths.snapshots.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: snapURL.path) else { return }
            let api = SecureShareAPI(origin: config.origin)
            let token = try await api.authenticate(deviceId: config.deviceId)
            let approval = try await api.request("/v1/shares/\(id)/approval", method: "GET", token: token)
            guard let dataURL = approval["approvalSignature"] as? String,
                  dataURL.hasPrefix("data:image/png;base64,"),
                  let png = Data(base64Encoded: String(dataURL.dropFirst(22))) else {
                try? "missing".write(to: marker, atomically: true, encoding: .utf8)
                return
            }
            let approvalDate = local.approvalAt.map { Date(timeIntervalSince1970: $0/1000) } ?? Date()
            let signerCopy = signer, fileCopy = local.filename
            let burned: Data
            do {
                burned = try await Task.detached(priority: .userInitiated) {
                    let pdf = try Data(contentsOf: snapURL)
                    return try RemoteApprovalBurn.burn(pdfData: pdf, signaturePNG: png, signerName: signerCopy, date: approvalDate, sourceFilename: fileCopy)
                }.value
            } catch {
                // Zaključan ili nečitljiv PDF: ne retry-uj, ostaje sidecar + rename.
                try? "unburnable".write(to: marker, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                return
            }
            try burned.write(to: snapURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: snapURL.path)
            local.size = Int64(burned.count)
            local.fileHash = RemoteApprovalBurn.sha256Hex(burned)
            try SecureShareDatabase().save(local)
            _ = try await api.request("/v1/shares/\(id)/sealed", body: ["fileHash": local.fileHash, "size": local.size], token: token)
            try? "sealed".write(to: marker, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            try? reloadLocal()
            await refresh()
        } catch { /* mrežna greška → retry na sledeći refresh, bez markera */ }
    }
}

@MainActor
final class SecureShareWindowManager: NSObject, NSWindowDelegate {
    static let shared = SecureShareWindowManager()
    private var windows: [NSWindow] = []
    func open(_ url: URL? = nil) {
        open(urls: url.map { [$0] } ?? [])
    }
    func open(urls: [URL]) {
        let view = SecureShareView(urls: urls)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = urls.isEmpty ? "Shared Files" : (urls.count == 1 ? "Share — \(urls[0].lastPathComponent)" : "Share \(urls.count) Items")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 680)); window.minSize = NSSize(width: 540, height: 540)
        window.isReleasedWhenClosed = false; window.delegate = self; windows.append(window); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { if let window = notification.object as? NSWindow { windows.removeAll { $0 === window } } }
}

struct SecureShareView: View {
    let files: [URL]
    init(file: URL? = nil) { self.files = file.map { [$0] } ?? [] }
    init(urls: [URL]) { self.files = urls }
    @ObservedObject private var manager = SecureShareManager.shared
    @State private var origin = ""
    @State private var enrollment = ""
    @State private var hours = 24
    @State private var customExpiry = Date().addingTimeInterval(86400)
    @State private var preview = true
    @State private var download = true
    @State private var password = ""
    @State private var limit = 0
    @State private var requireSignature = false
    @State private var link: String?
    @State private var auditText: String?
    @State private var signatureDataURL: String?
    @State private var signatureTitle = ""
    @State private var selection = Set<String>()
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteIds: [String] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "link.badge.plus").font(.largeTitle).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(files.isEmpty ? "Shared Files" : "Create secure link").font(.title2.bold())
                        Text("Local snapshot · Available while this Mac is awake and online").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if manager.configuration == nil { connectionForm }
                else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manager.configuration?.mode == "quick" ? manager.tunnelStatus : (manager.configuration?.origin ?? "")).font(.caption).foregroundStyle(.secondary)
                        Toggle("Enable internet sharing", isOn: Binding(get: { manager.configuration?.enabled ?? false }, set: { value in Task { await manager.setEnabled(value) } }))
                        Toggle("Keep sharing after quitting aiFlow", isOn: Binding(get: { manager.backgroundEnabled }, set: { value in Task { await manager.setBackground(value) } }))
                        Text(manager.configuration?.mode == "quick" ? "No account or setup required. Cloudflare provides a temporary address. After a restart or reconnection, copy and send the new link. Keep this Mac awake and online. File content passes through Cloudflare over an encrypted connection." : "Only files you explicitly share are sent. File bytes pass through your configured relay; they are not stored there. This is transport encryption, not end-to-end encryption.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !files.isEmpty { createForm(files) }
                    Divider()
                    linksHeader
                    if manager.shares.isEmpty { Text("No files shared yet.").foregroundStyle(.secondary) }
                    ForEach(manager.shares) { share in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { selection.contains(share.id) },
                                set: { checked in
                                    if checked { selection.insert(share.id) }
                                    else { selection.remove(share.id) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help("Select for bulk delete")
                            .padding(.top, 12)
                            shareRow(share)
                        }
                    }
                }
                if manager.busy { ProgressView("Working…") }
                if let message = manager.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(24)
        }
        .disabled(manager.busy)
        .task { await manager.refresh() }
        .onChange(of: manager.configuration?.origin) { _, value in
            if manager.configuration?.mode == "quick", let old = link, let secret = old.split(separator: "#").last {
                link = (value?.isEmpty == false) ? value! + "/s#" + secret : nil
            }
        }
        .onChange(of: manager.shares.map(\.id)) { _, ids in
            // Po refresh-u odbaci selekciju koja više ne postoji (obrisano).
            selection = selection.intersection(ids)
        }
        .alert("Delete \(pendingDeleteIds.count) shared file\(pendingDeleteIds.count == 1 ? "" : "s")?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                let ids = pendingDeleteIds
                pendingDeleteIds = []
                for id in ids { selection.remove(id) }
                Task { await manager.deleteShares(ids) }
            }
            Button("Cancel", role: .cancel) { pendingDeleteIds = [] }
        } message: {
            Text("Links stop working immediately and snapshots are removed from this Mac. Original files stay untouched.")
        }
        .sheet(isPresented: Binding(get: { auditText != nil }, set: { if !$0 { auditText = nil } })) {
            VStack(alignment: .leading, spacing: 16) { Text("Share activity").font(.headline); ScrollView { Text(auditText ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }; Button("Done") { auditText = nil } }.padding(24).frame(width: 520, height: 360)
        }
        .sheet(isPresented: Binding(get: { signatureDataURL != nil }, set: { if !$0 { signatureDataURL = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Signature").font(.headline)
                Text(signatureTitle).font(.caption).foregroundStyle(.secondary)
                SignatureImageView(dataURL: signatureDataURL)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button("Done") { signatureDataURL = nil }
            }.padding(24).frame(width: 520, height: 400)
        }
    }
    private var linksHeader: some View {
        HStack {
            Text("Your links").font(.headline)
            Spacer()
            if !manager.shares.isEmpty {
                Button(selection.count == manager.shares.count ? "Deselect All" : "Select All") {
                    if selection.count == manager.shares.count { selection.removeAll() }
                    else { selection = Set(manager.shares.map(\.id)) }
                }
                .controlSize(.small)
                Button("Delete Selected\(selection.isEmpty ? "" : " (\(selection.count))")", role: .destructive) {
                    pendingDeleteIds = Array(selection)
                    showDeleteConfirm = true
                }
                .controlSize(.small)
                .disabled(selection.isEmpty)
            }
            Button("Refresh") { Task { await manager.refresh() } }.controlSize(.small)
        }
    }
    private var connectionForm: some View {
        GroupBox("Connect your share server") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter the HTTPS address and enrollment code supplied by your server administrator.").font(.callout)
                TextField("https://share.example.com", text: $origin)
                SecureField("Enrollment code", text: $enrollment)
                Button("Connect this Mac") { Task { await manager.connect(origin: origin, code: enrollment); if manager.configuration != nil { enrollment = "" } } }.buttonStyle(.borderedProminent).disabled(origin.isEmpty || enrollment.isEmpty)
            }.padding(8)
        }
    }
    private func createForm(_ files: [URL]) -> some View {
        // Više stavki ili jedan folder → jedan .zip (download-only).
        // Jedan običan fajl → direktno, sa preview opcijom kao pre.
        let isBundle: Bool = {
            if files.count != 1 { return true }
            guard let url = files.first else { return true }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true
        }()
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if files.count == 1, let only = files.first {
                    Label(only.lastPathComponent, systemImage: isBundle ? "folder" : "doc").font(.headline).lineLimit(2)
                } else {
                    Label("\(files.count) items → one .zip", systemImage: "archivebox").font(.headline).lineLimit(2)
                    Text(files.prefix(6).map(\.lastPathComponent).joined(separator: ", ") + (files.count > 6 ? " …" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("The link shares a fixed local copy. Later edits to the original are not shared.").font(.caption).foregroundStyle(.secondary)
                if isBundle {
                    Text("Multiple files/folders are packed into a single .zip (download only). \(SecureShareLimits.summary()).").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Expires", selection: $hours) { Text("24 hours").tag(24); Text("7 days").tag(168); Text("Custom").tag(-1); Text("Never").tag(0) }
                if hours == -1 { DatePicker("Available until", selection: $customExpiry, in: Date()...) }
                Toggle("Allow preview", isOn: $preview)
                    .disabled(isBundle)
                Toggle("Allow download", isOn: $download)
                    .disabled(isBundle)
                Text(isBundle ? "ZIP archives are download-only — the recipient gets one .zip file." : "Preview also sends file content to the recipient and cannot prevent saving. DOCX and other unsupported preview formats require Download.").font(.caption).foregroundStyle(.secondary)
                SecureField("Optional password (8+ characters)", text: $password)
                Picker("Download limit", selection: $limit) { Text("Unlimited").tag(0); Text("1").tag(1); Text("5").tag(5); Text("10").tag(10); Text("100").tag(100) }
                Text("A download session allows retries and Range requests for 15 minutes and counts once. Failed attempts may consume a slot.").font(.caption2).foregroundStyle(.secondary)
                Toggle("Require signature to complete", isOn: $requireSignature)
                    .disabled(isBundle)
                Text(isBundle ? "Signatures are available for single PDF shares, not for .zip bundles." : "Recipient draws a signature and types their name. PDFs are sealed — the signature becomes the last page. The file is renamed to “(signed by Name)” and the approval is logged.").font(.caption2).foregroundStyle(.secondary)
                if let link {
                    TextField("Share link", text: .constant(link)).textFieldStyle(.roundedBorder)
                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
                } else {
                    HStack {
                        Button("Create Link") { Task { link = await manager.create(urls: files, hours: hours, customExpiry: hours == -1 ? customExpiry : nil, preview: isBundle ? false : preview, download: isBundle ? true : download, password: password, maxDownloads: limit == 0 ? nil : limit, requireSignature: isBundle ? false : requireSignature); if link != nil { password = "" } } }.buttonStyle(.borderedProminent).disabled((isBundle ? false : (!preview && !download)) || manager.configuration?.enabled != true || !SecureShareManager.canQuickLink(files))
                        Button("Quick Link (24h)") { Task { await manager.quickLink(for: files) } }.disabled(manager.configuration?.enabled != true || !SecureShareManager.canQuickLink(files))
                            .help("24h link, no dialog — created and copied immediately")
                    }
                }
            }.padding(8)
        }
    }
    private func shareRow(_ share: SecureShareRecord) -> some View {
        let data = manager.remote[share.id]
        let status = share.status == "revoked" ? "Blocked on this Mac" : (data?["status"] as? String ?? "Status unavailable")
        let approval = share.approvalName ?? (data?["approvalName"] as? String)
        let approvalAt = share.approvalAt ?? (data?["approvalAt"] as? Double)
        let wantsSign = share.requireSignature || (data?["requireSignature"] as? Bool ?? false)
        let sealedNote: String? = {
            guard let approval, !approval.isEmpty else { return nil }
            if share.mimeType == "application/pdf" { return "sealed in PDF" }
            return "signature saved"
        }()
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(share.filename).fontWeight(.medium).lineLimit(1); Spacer(); Text(status).font(.caption).foregroundStyle(.secondary) }
                Text("\(data?["viewCount"] as? Int ?? 0) views · \(data?["downloadCount"] as? Int ?? 0) download sessions").font(.caption).foregroundStyle(.secondary)
                if wantsSign {
                    if let approval, !approval.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Signed by \(approval)").font(.caption).foregroundStyle(.green)
                            if let sealedNote { Text("· \(sealedNote)").font(.caption).foregroundStyle(.secondary) }
                            if let approvalAt { Text("· \(Date(timeIntervalSince1970: approvalAt/1000).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "hourglass").foregroundStyle(.orange)
                            Text("Waiting for signature…").font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else if let approval, !approval.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Signed by \(approval)").font(.caption).foregroundStyle(.green)
                        if let sealedNote { Text("· \(sealedNote)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let expiry = (data?["expiresAt"] as? Double) ?? (data == nil ? share.expiresAt : nil) { Text("Expires \(Date(timeIntervalSince1970: expiry/1000).formatted())").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Copy Link") { Task { await manager.copyLink(share) } }.disabled(share.status != "active")
                    Button("Activity") { Task { auditText = await manager.audit(share) } }
                    if let approval, !approval.isEmpty {
                        Button("View signature") {
                            let title = "Signed by \(approval)" + (approvalAt.map { " · \(Date(timeIntervalSince1970: $0/1000).formatted(date: .abbreviated, time: .shortened))" } ?? "")
                            signatureTitle = title
                            Task {
                                if let url = await manager.approvalImage(share) { signatureDataURL = url }
                                else { auditText = "No signature image saved for this approval." }
                            }
                        }
                    }
                    Button("Extend 24h") { Task { await manager.renew(share) } }.disabled(share.status != "active")
                    Spacer()
                    Button(data?["status"] as? String == "REVOKED" ? "Revoked" : "Revoke", role: .destructive) { Task { await manager.revoke(share) } }.disabled(data?["status"] as? String == "REVOKED")
                    Button("Delete", role: .destructive) {
                        pendingDeleteIds = [share.id]
                        showDeleteConfirm = true
                    }
                }.controlSize(.small)
            }.padding(6)
        }
    }
}

/// Prikaz nacrtanog potpisa iz dataURL-a (vlasnikov sheet).
private struct SignatureImageView: View {
    let dataURL: String?
    var body: some View {
        if let image = Self.decode(dataURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
        } else {
            Text("Signature image unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }
    private static func decode(_ url: String?) -> NSImage? {
        guard let url, let range = url.range(of: "base64,") else { return nil }
        guard let data = Data(base64Encoded: String(url[range.upperBound...])) else { return nil }
        return NSImage(data: data)
    }
}
