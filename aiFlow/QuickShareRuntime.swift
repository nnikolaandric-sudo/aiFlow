import Foundation
import Darwin
import ServiceManagement

struct QuickShareStatus: Codable {
    var origin: String
    var message: String
    var updatedAt: Double
    var pid: Int32 = getpid()
    static var url: URL { SecureSharePaths.root.appendingPathComponent("quick-status.json") }
    static func read() -> Self? {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data), Date().timeIntervalSince1970 - value.updatedAt < 8, kill(value.pid, 0) == 0 else { return nil }
        return value
    }
}

actor QuickShareRuntime {
    private let appFallback: Bool
    private var task: Task<Void,Never>?
    private var generation = UUID()
    private var tunnelID = UUID()
    private var server: QuickShareServer?
    private var process: Process?
    private var control: Pipe?
    private var logPipe: Pipe?
    private var lockFD: Int32 = -1
    private var origin = ""
    private var tail = ""
    private var ready = false
    private var launchedAt = Date.distantPast
    private var state = "Connecting to Cloudflare…"
    init(appFallback: Bool = false) { self.appFallback = appFallback }
    static var contents: URL {
        // Both executables live inside Contents/MacOS.
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    }
    func start() {
        guard task == nil else { return }
        let id = UUID(); generation = id
        task = Task { await loop(id) }
    }
    func stop() async {
        generation = UUID(); task?.cancel(); task = nil
        await disconnect()
    }
    private func publish() {
        guard lockFD >= 0 else { return }
        let value = QuickShareStatus(origin: ready ? origin : "", message: state, updatedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: QuickShareStatus.url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:QuickShareStatus.url.path) }
    }
    private func disconnect() async {
        tunnelID = UUID(); origin = ""; ready = false; state = "Sharing is offline"; publish()
        try? control?.fileHandleForWriting.close(); control = nil
        logPipe?.fileHandleForReading.readabilityHandler = nil; logPipe = nil
        process = nil // Supervisor kills its child on control-pipe EOF, including a crashed parent.
        let old = server; server = nil; await old?.stop()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    private func log(_ data: Data, id: UUID) async {
        guard tunnelID == id, process != nil else { return }
        tail += String(decoding:data,as:UTF8.self); tail = String(tail.suffix(8192))
        if origin.isEmpty, let range = tail.range(of: "https://[a-z0-9]+(?:-[a-z0-9]+)*\\.trycloudflare\\.com", options:.regularExpression) {
            origin = String(tail[range]); await server?.setOrigin(origin)
        }
        if !origin.isEmpty && tail.contains("Registered tunnel connection") { ready = true; state = "Temporary Cloudflare link ready" }
        publish()
    }
    private func loop(_ id: UUID) async {
        var retryAt = Date.distantPast
        while !Task.isCancelled && generation == id {
            do {
                let db = try SecureShareDatabase(); try db.cleanupSnapshots()
                let helperOwns = appFallback && SMAppService.agent(plistName:"com.finderflow.share-agent.plist").status == .enabled
                let config = try db.configuration()
                let active = try db.shares().contains { $0.status == "active" && ($0.expiresAt.map { $0 > Date().timeIntervalSince1970*1000 } ?? true) }
                if helperOwns || config?.mode != "quick" || config?.enabled != true || !active {
                    if lockFD >= 0 { await disconnect() }
                } else if process == nil && Date() >= retryAt {
                    try SecureSharePaths.prepare()
                    let fd = open(SecureSharePaths.root.appendingPathComponent("quick-runtime.lock").path, O_CREAT|O_RDWR|O_CLOEXEC, 0o600)
                    if fd >= 0, flock(fd, LOCK_EX|LOCK_NB) == 0 {
                        lockFD = fd; state = "Connecting to Cloudflare…"; origin = ""; tail = ""; ready = false; launchedAt = Date(); publish()
                        let service = QuickShareServer(resources:Self.contents.appendingPathComponent("Resources/SecureShareWeb")); server = service
                        let port = try await service.start()
                        if Task.isCancelled || generation != id { await service.stop(); return }
                        #if arch(arm64)
                        let arch = "arm64"
                        #else
                        let arch = "x86_64"
                        #endif
                        let binary = Self.contents.appendingPathComponent("Helpers/cloudflared-\(arch)")
                        guard FileManager.default.isExecutableFile(atPath:binary.path) else { throw SecureShareError.message("Cloudflare helper is missing. Reinstall aiFlow.") }
                        let child = Process(), output = Pipe(), input = Pipe()
                        child.executableURL = Self.contents.appendingPathComponent("MacOS/FinderFlowShareAgent")
                        child.arguments = ["--quick-tunnel",binary.path,String(port)]
                        child.standardInput = input; child.standardOutput = output; child.standardError = output
                        child.environment = ["PATH":"/usr/bin:/bin", "HOME":SecureSharePaths.root.path]
                        let connectionID = UUID(); tunnelID = connectionID
                        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                            let data = handle.availableData
                            if !data.isEmpty { Task { await self?.log(data,id:connectionID) } }
                        }
                        process = child; control = input; logPipe = output
                        try child.run()
                    } else if fd >= 0 { close(fd) }
                }
                if let process {
                    if !ready && Date().timeIntervalSince(launchedAt) > 75 { throw SecureShareError.message("Cloudflare connection timed out. Retrying…") }
                    if !process.isRunning { throw SecureShareError.message("Cloudflare disconnected. Reconnecting…") }
                    await server?.sweep(); publish()
                }
            } catch {
                guard generation == id else { return }
                await disconnect(); retryAt = Date().addingTimeInterval(5)
                // Status only contains a fixed/local error, never tunnel logs or secrets.
                if generation == id {
                    let value = QuickShareStatus(origin:"",message:error.localizedDescription,updatedAt:Date().timeIntervalSince1970)
                    if let data = try? JSONEncoder().encode(value) { try? data.write(to:QuickShareStatus.url,options:.atomic) }
                }
            }
            try? await Task.sleep(nanoseconds:1_000_000_000)
        }
    }
}
