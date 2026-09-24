import Foundation
import AppKit

// Offline harness za Google Drive engine: pravi Drive API se zamenjuje
// URLProtocol mockom, mirror ide u temp folder. Nema mreže, nema Keychaina,
// nema pravog naloga.

extension Notification.Name {
    static let refreshDirectory = Notification.Name("FinderFlow.refreshDirectory")
}

// MARK: - Mock mreže

final class MockProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [(match: (URLRequest) -> Bool, respond: (URLRequest) -> (Int, Data))] = []
    nonisolated(unsafe) static var seen: [String] = []
    nonisolated(unsafe) static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let req = request
        Self.lock.lock()
        Self.seen.append("\(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "")")
        let route = Self.routes.first { $0.match(req) }
        Self.lock.unlock()
        let (status, body) = route?.respond(req) ?? (404, Data("{}".utf8))
        let resp = HTTPURLResponse(url: req.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Test scaffolding

var failures: [String] = []
var checks = 0
func check(_ cond: Bool, _ what: String) {
    checks += 1
    if cond { print("  ✓ \(what)") } else { print("  ✗ \(what)"); failures.append(what) }
}
func checkEq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    check(a == b, "\(what) (dobijeno: \(a), očekivano: \(b))")
}

let fm = FileManager.default
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ff-gdrive-test-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
// (bez top-level defer-a: cleanup je eksplicitan na kraju fajla)

// MARK: - Drive sadržaj koji mock servira
//
//  /                      (root)
//    Projekti/            (folder)
//      plan.md            (običan fajl)
//      Beleške            (Google Doc -> export .docx)
//    slika.png            (običan fajl)

let driveJSON = """
{"files":[
 {"id":"F1","name":"Projekti","mimeType":"application/vnd.google-apps.folder","modifiedTime":"2026-09-10T10:00:00.000Z"},
 {"id":"D1","name":"plan.md","mimeType":"text/markdown","parents":["F1"],"modifiedTime":"2026-09-10T10:05:00.000Z","size":"12","md5Checksum":"abc"},
 {"id":"D2","name":"Beleške","mimeType":"application/vnd.google-apps.document","parents":["F1"],"modifiedTime":"2026-09-10T10:06:00.000Z","webViewLink":"https://docs.google.com/document/d/D2/edit"},
 {"id":"D3","name":"slika.png","mimeType":"image/png","modifiedTime":"2026-09-10T10:07:00.000Z","size":"5","md5Checksum":"def"},
 {"id":"D4","name":"na-vrhu.txt","mimeType":"text/plain","parents":["root"],"modifiedTime":"2026-09-10T10:08:00.000Z","size":"3","md5Checksum":"ghi"}
]}
"""

MockProtocol.routes = [
    (match: { ($0.url?.path ?? "").hasSuffix("/drive/v3/files") && $0.httpMethod == "GET" },
     respond: { _ in (200, Data(driveJSON.utf8)) }),
    (match: { ($0.url?.absoluteString ?? "").contains("/export") },
     respond: { _ in (200, Data("DOCX-EXPORT-BYTES".utf8)) }),
    (match: { ($0.url?.absoluteString ?? "").contains("alt=media") },
     respond: { req in (200, Data("SADRŽAJ:\(req.url!.lastPathComponent)".utf8)) }),
    (match: { $0.httpMethod == "POST" && ($0.url?.absoluteString ?? "").contains("upload") },
     respond: { _ in (200, Data(#"{"id":"NEW1"}"#.utf8)) }),
    (match: { $0.httpMethod == "POST" },
     respond: { _ in (200, Data(#"{"id":"NEWFOLDER"}"#.utf8)) }),
    (match: { $0.httpMethod == "PATCH" },
     respond: { _ in (200, Data(#"{"id":"D1"}"#.utf8)) }),
]
URLProtocol.registerClass(MockProtocol.self)

// MARK: - Testovi

print("\n== 1. Sidecar putanje ==")
let f = tmp.appendingPathComponent("Izveštaj.docx")
let side = GoogleDrivePaths.sidecar(for: f, isDirectory: false)
check(side.lastPathComponent == ".Izveštaj.docx.gdrive.json", "sidecar je skriven: \(side.lastPathComponent)")
checkEq(GoogleDrivePaths.ownerName(ofSidecar: ".Izveštaj.docx.gdrive.json"), "Izveštaj.docx", "ownerName (novi format)")
checkEq(GoogleDrivePaths.ownerName(ofSidecar: "Izveštaj.docx.gdrive.json"), "Izveštaj.docx", "ownerName (stari format)")
checkEq(GoogleDrivePaths.ownerName(ofSidecar: ".gdrive.json"), nil, "folderski sidecar nema owner-a")
check(GoogleDrivePaths.isSidecarName(".x.gdrive.json") && !GoogleDrivePaths.isSidecarName("x.docx"), "prepoznavanje sidecar imena")

// legacy fallback: upiši stari format pa čitaj
let legacy = GoogleDrivePaths.legacySidecar(for: f, isDirectory: false)!
try! Data(#"{"driveID":"L1","lastSynced":0}"#.utf8).write(to: legacy)
check(GoogleDrivePaths.sidecarData(for: f, isDirectory: false) != nil, "čita se stari (vidljivi) sidecar")
try? fm.removeItem(at: legacy)

print("\n== 2. Google Docs stubovi ==")
let stub = tmp.appendingPathComponent("Ugovor.gdoc")
try! Data(#"{"url":"https://docs.google.com/document/d/XYZ/edit","doc_id":"XYZ"}"#.utf8).write(to: stub)
checkEq(GoogleLocalDrive.docsStubURL(at: stub)?.host, "docs.google.com", "stub -> web URL")
check(GoogleLocalDrive.isDocsStub(stub), "isDocsStub prepoznaje .gdoc")
check(!GoogleLocalDrive.isDocsStub(tmp.appendingPathComponent("a.txt")), "obican fajl nije stub")
checkEq(GoogleLocalDrive.email(from: URL(fileURLWithPath: "/x/GoogleDrive-neko@gmail.com")), "neko@gmail.com", "email iz imena mount-a")

print("\n== 3. Reconcile (download + export) ==")
let svc = await GoogleDriveSyncService.shared
var acc = GoogleDriveAccount()
acc.email = "finderflow-harness@example.invalid"
let api = GoogleDriveAPI(tokenProvider: { "fake-token" })
let listed = try await api.listAllFiles()
checkEq(listed.count, 5, "listAllFiles vraća sve fajlove")

let root = tmp.appendingPathComponent("mirror", isDirectory: true)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)

// reconcile piše u account.mirrorRoot() — baza je izolovana preko
// FF_GDRIVE_BASE env vara (vidi GoogleDrivePaths.base + run.sh), pa je
// mirror uvek unutar tmp i nikad pravi korisnički ~/Library mirror.
let result = try await svc.reconcile(account: acc, api: api, driveFiles: listed, progress: { _ in })
let mirror = acc.mirrorRoot()

let planMD = mirror.appendingPathComponent("Projekti/plan.md")
let beleske = mirror.appendingPathComponent("Projekti/Beleške.docx")
let slika = mirror.appendingPathComponent("slika.png")
check(fm.fileExists(atPath: planMD.path), "skinut Projekti/plan.md")
check(fm.fileExists(atPath: beleske.path), "Google Doc exportovan kao Beleške.docx")
check(fm.fileExists(atPath: slika.path), "skinut slika.png")
check(fm.fileExists(atPath: mirror.appendingPathComponent("na-vrhu.txt").path),
      "fajl sa parents=[\"root\"] je završio u korenu mirrora")
checkEq((try? String(contentsOf: beleske, encoding: .utf8)) ?? "", "DOCX-EXPORT-BYTES", "export sadržaj")
checkEq(result.downloaded, 4, "broj preuzetih")

print("\n== 4. Sidecari su nevidljivi u listingu ==")
let visible = (try! fm.contentsOfDirectory(atPath: mirror.appendingPathComponent("Projekti").path))
    .filter { !$0.hasPrefix(".") }.sorted()
checkEq(visible, ["Beleške.docx", "plan.md"], "listing bez sidecara")
check(fm.fileExists(atPath: mirror.appendingPathComponent("Projekti/.plan.md.gdrive.json").path), "sidecar upisan skriven")

print("\n== 5. Idempotentnost (drugi sync ne skida ponovo) ==")
let again = try await svc.reconcile(account: acc, api: api, driveFiles: listed, progress: { _ in })
checkEq(again.downloaded, 0, "drugi prolaz ne preuzima ništa")
checkEq(again.orphaned, 0, "nema orphan fajlova")

print("\n== 6. Bedž indeks ==")
let idx = await GoogleDriveBadgeIndex.shared
await idx.invalidate(folder: nil)
_ = await idx.kind(for: planMD)            // pokreće async scan
try await Task.sleep(nanoseconds: 600_000_000)
let kPlan = await idx.kind(for: planMD)
let kDoc = await idx.kind(for: beleske)
check(kPlan == .synced, "plan.md -> synced (dobijeno: \(String(describing: kPlan)))")
if case .googleDoc(let link)? = kDoc {
    check(link?.contains("docs.google.com") == true, "Beleške.docx -> googleDoc + webViewLink")
} else {
    check(false, "Beleške.docx -> googleDoc (dobijeno: \(String(describing: kDoc)))")
}
let novi = mirror.appendingPathComponent("Projekti/moj-novi.txt")
try! Data("lokalno".utf8).write(to: novi)
await idx.invalidate(folder: mirror.appendingPathComponent("Projekti"))
_ = await idx.kind(for: novi)
try await Task.sleep(nanoseconds: 600_000_000)
let kNovi = await idx.kind(for: novi)
check(kNovi == .pending, "novi lokalni fajl -> pending (dobijeno: \(String(describing: kNovi)))")
check(await idx.kind(for: stub) == .stub, "stub -> .stub bedž")
let outsideMirror = tmp.appendingPathComponent("nesto.txt")
check(await idx.kind(for: outsideMirror) == nil, "van mirrora nema bedža")

print("\n== 7. Upload novog lokalnog fajla ==")
MockProtocol.seen.removeAll()
var byID: [String: GoogleDriveFile] = [:]
for file in listed { byID[file.id] = file }
var folderPath: [String: URL] = ["F1": mirror.appendingPathComponent("Projekti", isDirectory: true)]
var idToLocal: [String: URL] = ["D1": planMD, "D2": beleske, "D3": slika]
let up = try await svc.uploadNewAndChanged(root: mirror, api: api, folderPath: folderPath,
                                           driveIDToLocal: idToLocal, byID: byID)
checkEq(up, 1, "uploadovan tačno 1 novi fajl")
check(GoogleDrivePaths.sidecarData(for: novi, isDirectory: false) != nil, "novi fajl je dobio sidecar")
check(MockProtocol.seen.contains { $0.contains("upload") }, "upload je stvarno pozvan")

print("\n== 8. Orphan detekcija ==")
// Orphan = sve sa sidecarom čiji driveID više ne postoji na Drive-u:
// plan.md (D1) + na-vrhu.txt (D4) + moj-novi.txt (NEW1) + sam folder Projekti (F1) = 4.
let orph = svc.countOrphaned(root: mirror, knownIDs: Set(["D2", "D3"]))
checkEq(orph, 4, "orphan = plan.md + na-vrhu.txt + novi fajl + folder Projekti")
checkEq(svc.countOrphaned(root: mirror, knownIDs: Set(["D1", "D2", "D3", "D4", "F1", "NEW1"])), 0,
        "ništa nije orphan kad su svi ID-evi poznati")

try? fm.removeItem(at: tmp)
try? fm.removeItem(at: mirror)

print("\n———")
if failures.isEmpty {
    print("SVE PROŠLO: \(checks) provera")
    exit(0)
} else {
    print("PALO \(failures.count)/\(checks):")
    for f in failures { print("  • \(f)") }
    exit(1)
}
