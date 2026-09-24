import Foundation
import CryptoKit

// Only synthetic data and an isolated registry are used by this harness.
guard ProcessInfo.processInfo.environment["FF_SHARE_TEST_MODE"] == "1", ProcessInfo.processInfo.environment["FF_SHARE_DIR"] != nil else { fatalError("Test isolation is required") }
let args = CommandLine.arguments
let db = try SecureShareDatabase()
if args[1] == "seed" {
    let config = SecureShareConfiguration(origin: args[2], deviceId: args[3], enabled: true)
    try db.configure(config)
    var record = try SecureShareSnapshot.create(url: URL(fileURLWithPath: args[4]), expiry: Date().addingTimeInterval(3600).timeIntervalSince1970*1000, preview: true, download: true, limit: nil)
    record.status = "active"; try db.save(record)
    let result: [String: Any] = ["id":record.id,"filename":record.filename,"size":record.size,"mimeType":record.mimeType,"fileHash":record.fileHash,"expiresAt":Int64(record.expiresAt!),"allowPreview":record.allowPreview,"allowDownload":true,"maxDownloads":NSNull()]
    print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
} else if args[1] == "enabled" {
    var config = try db.configuration()!; config.enabled = args[2] == "true"; try db.configure(config)
} else if args[1] == "revoke" {
    var record = try db.share(args[2])!; record.status = "revoked"; try db.save(record)
} else if args[1] == "snapshot-check" {
    let source = SecureSharePaths.root.appendingPathComponent("original.txt")
    try Data("original version".utf8).write(to: source)
    let record = try SecureShareSnapshot.create(url: source, expiry: nil, preview: true, download: true, limit: nil)
    try db.save(record)
    try Data("edited version".utf8).write(to: source)
    let handle = try SecureShareSnapshot.open(record); defer { try? handle.close() }
    let snapshotBytes = try handle.readToEnd()
    precondition(snapshotBytes == Data("original version".utf8))
    let snapshot = SecureSharePaths.snapshots.appendingPathComponent(record.id)
    try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:snapshot.path)
    try Data("tampered version".utf8).write(to:snapshot)
    do { let h = try SecureShareSnapshot.open(record); try h.close(); fatalError("Changed snapshot accepted") } catch { precondition(error.localizedDescription == "FILE_CHANGED") }
    try FileManager.default.removeItem(at:snapshot)
    try FileManager.default.createSymbolicLink(at:snapshot, withDestinationURL:source)
    do { let h = try SecureShareSnapshot.open(record); try h.close(); fatalError("Symlink accepted") } catch {}
    var expired = try SecureShareSnapshot.create(url: source, expiry: 1, preview: true, download: true, limit: nil)
    expired.status = "active"; try db.save(expired)
    try db.cleanupSnapshots()
    precondition(!FileManager.default.fileExists(atPath: SecureSharePaths.snapshots.appendingPathComponent(expired.id).path))
    precondition(FileManager.default.fileExists(atPath: source.path))
    var retained = try SecureShareSnapshot.create(url: source, expiry: 1, preview: true, download: true, limit: nil)
    retained.status = "active"; retained.expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970*1000; try db.save(retained)
    try db.cleanupSnapshots()
    precondition(FileManager.default.fileExists(atPath: SecureSharePaths.snapshots.appendingPathComponent(retained.id).path))
    print("Snapshot isolation, tamper detection, symlink rejection and expiry cleanup passed")
}
