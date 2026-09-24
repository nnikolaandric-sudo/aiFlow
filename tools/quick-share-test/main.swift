import Foundation

guard ProcessInfo.processInfo.environment["FF_SHARE_TEST_MODE"] == "1", ProcessInfo.processInfo.environment["FF_SHARE_DIR"] != nil else { fatalError("Test isolation required") }
let args = CommandLine.arguments
let db = try SecureShareDatabase()
if args[1] == "seed" {
    try db.configure(SecureShareConfiguration(origin:"",deviceId:"test",enabled:true,mode:"quick"))
    let source = SecureSharePaths.root.appendingPathComponent("Synthetic.txt")
    try Data(String(repeating:"FinderFlow synthetic Cloudflare test.\n",count:100_000).utf8).write(to:source)
    var share = try SecureShareSnapshot.create(url:source,expiry:Date().addingTimeInterval(3600).timeIntervalSince1970*1000,preview:true,download:true,limit:1)
    share.status = "active"; try db.save(share)
    let token = try SecureShareCrypto.token(), salt = Data("test-only-salt-32-random-not-needed".utf8)
    try db.quickCreate(id:share.id,tokenHash:SecureShareCrypto.hash(Data(token.utf8)),salt:salt.base64EncodedString(),passwordHash:QuickSharePassword.digest("test-password",salt:salt))
    print(String(data:try JSONSerialization.data(withJSONObject:["id":share.id,"token":token,"size":share.size,"hash":share.fileHash]),encoding:.utf8)!)
} else if args[1] == "serve" {
    let server = QuickShareServer(resources:QuickShareRuntime.contents.appendingPathComponent("Resources/SecureShareWeb"))
    Task {
        do {
            let port = try await server.start(); await server.setOrigin("http://127.0.0.1:\(port)")
            print("http://127.0.0.1:\(port)"); fflush(stdout)
            while true { await server.sweep(); try await Task.sleep(nanoseconds:250_000_000) }
        } catch { exit(1) }
    }
    RunLoop.main.run()
} else if args[1] == "runtime" {
    let quick = QuickShareRuntime(); Task { await quick.start() }; RunLoop.main.run()
} else if args[1] == "revoke" {
    var share = try db.share(args[2])!; share.status = "revoked"; try db.save(share)
} else if args[1] == "expire" {
    var share = try db.share(args[2])!; share.expiresAt = 1; try db.save(share)
} else if args[1] == "enabled" {
    var config = try db.configuration()!; config.enabled = args[2] == "true"; try db.configure(config)
}
