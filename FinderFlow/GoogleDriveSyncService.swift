import Foundation
import AppKit
import Combine
import os

// MARK: - Google Drive sync engine (nativni mirror + Drive API v3)
//
// Svaki nalog -> lokalni mirror folder koji FinderFlow browse-uje kao običan folder.
// Sync je dvosmeran, ali konzervativan (nikad ne briše bez traga):
//
//  DOWNLOAD (Drive -> Mac):
//   - listAllFiles, izgradi stablo iz parents veza, root = fajlovi bez roditelja / sa "root".
//   - kreiraj foldere koji fale, skini nove/izmenjene fajlove (modifiedTime + md5/size check).
//   - Google Docs/Sheets/Slides se EXPORTUJU u docx/xlsx/pptx (+ sidecar sa webViewLink).
//   - fajlovi kojih više nema na Drive-u NE brišu se automatski (da ne izgubiš lokalne
//     izmene) — broje se kao `orphaned` i nude na review u Settings.
//  UPLOAD (Mac -> Drive):
//   - novi lokalni fajlovi (bez sidecara) uploaduju se u odgovarajući Drive folder.
//   - izmenjeni lokalni fajlovi (mtime noviji od sidecar zapisa) update-uju Drive sadržaj.
//   - lokalno obrisani fajlovi se NE trashuju na Drive-u automatski u v1 (sigurnost).
//
// Tokeni: access token se kešira u memoriji + Keychain blob, refresh po isteku.
// Stanje po nalogu je @Published pa sidebar i settings žive prate sync.

struct GoogleDriveSidecar: Codable {
    var driveID: String
    var driveModified: Date?
    var md5: String?
    var size: Int64?
    var webViewLink: String?
    var exportExt: String? // za Google Docs: "docx"/"xlsx"/...
    var lastSynced: Date
}

enum GoogleDriveSyncStatus: Equatable {
    case idle
    case syncing(String) // poruka faze
    case done(Date)
    case error(String)
    case needsAuth

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .idle: return "Ready"
        case .syncing(let m): return m.isEmpty ? "Syncing…" : m
        case .done(let d):
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "Sync " + f.localizedString(for: d, relativeTo: Date())
        case .error(let m): return m
        case .needsAuth: return "Sign-in required"
        }
    }
}

@MainActor
final class GoogleDriveSyncService: ObservableObject {
    static let shared = GoogleDriveSyncService()

    nonisolated static let log = Logger(subsystem: "com.finderflow.app", category: "GoogleDrive")

    @Published var accounts: [GoogleDriveAccount] = []
    @Published var statuses: [String: GoogleDriveSyncStatus] = [:] // accountID -> status
    @Published var isConnecting = false
    @Published var connectError: String?
    @Published var orphanedCount: [String: Int] = [:]

    private var accessCache: [String: (token: String, expiry: Date)] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private var autoTimer: Timer?

    init() {
        GoogleDrivePaths.ensureBaseExists()
        accounts = GoogleDriveAccountStore.loadAccounts()
        for a in accounts { statuses[a.id] = .idle }
        startAutoTimer()
    }

    // MARK: - Nalozi

    var hasAccounts: Bool { !accounts.isEmpty }

    nonisolated func mirrorRoot(for account: GoogleDriveAccount) -> URL {
        let root = account.mirrorRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func account(id: String) -> GoogleDriveAccount? {
        accounts.first(where: { $0.id == id })
    }

    func status(for id: String) -> GoogleDriveSyncStatus {
        statuses[id] ?? .idle
    }

    /// Poveži novi nalog (browser OAuth). Poziva se iz Settings.
    func connect(clientID: String) async {
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else {
            connectError = "Enter a Google Client ID first (see the instructions in Settings → Google Drive)."
            return
        }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            let tokens = try await GoogleOAuthService.connectAccount(clientID: client)
            // Duplikat: isti email već povezan → samo osveži token
            if let existing = accounts.first(where: {
                !$0.email.isEmpty && !$0.email.isEmpty && $0.email.lowercased() == tokens.email.lowercased()
            }) {
                if let refresh = tokens.refreshToken {
                    GoogleDriveKeychain.saveRefreshToken(refresh, accountID: existing.id)
                }
                accessCache[existing.id] = (tokens.accessToken, tokens.accessExpiry)
                GoogleDriveKeychain.saveAccess(token: tokens.accessToken, expiry: tokens.accessExpiry, accountID: existing.id)
                statuses[existing.id] = .idle
                Self.log.info("gdrive: refreshed existing account \(tokens.email, privacy: .private)")
                // Odmah sync
                sync(accountID: existing.id)
                return
            }
            var acc = GoogleDriveAccount()
            acc.email = tokens.email.isEmpty ? "account-\(accounts.count + 1)" : tokens.email
            acc.displayName = tokens.displayName
            if let refresh = tokens.refreshToken {
                GoogleDriveKeychain.saveRefreshToken(refresh, accountID: acc.id)
            } else {
                // Bez refresh tokena (retko, ako consent već dat) — access keširamo pa će
                // sledeći connect sa prompt=consent dati refresh. Svejedno dodaj nalog.
                Self.log.info("gdrive: no refresh token on first connect (will re-consent later)")
            }
            accessCache[acc.id] = (tokens.accessToken, tokens.accessExpiry)
            GoogleDriveKeychain.saveAccess(token: tokens.accessToken, expiry: tokens.accessExpiry, accountID: acc.id)
            accounts.append(acc)
            GoogleDriveAccountStore.saveAccounts(accounts)
            statuses[acc.id] = .idle
            _ = mirrorRoot(for: acc)
            Self.log.info("gdrive: connected \(acc.email, privacy: .private)")
            sync(accountID: acc.id)
        } catch let e as GoogleOAuthError {
            connectError = e.localizedDescription
        } catch {
            connectError = error.localizedDescription
        }
    }

    func disconnect(accountID: String) {
        syncTasks[accountID]?.cancel()
        syncTasks[accountID] = nil
        GoogleDriveKeychain.deleteTokens(accountID: accountID)
        accessCache.removeValue(forKey: accountID)
        accounts.removeAll { $0.id == accountID }
        GoogleDriveAccountStore.saveAccounts(accounts)
        statuses.removeValue(forKey: accountID)
        orphanedCount.removeValue(forKey: accountID)
        // Mirror ostaje na disku (da ne izgubiš fajlove) — korisnik ga može obrisati ručno.
        // Ponudi reveal u Finderu preko Settings akcije.
    }

    func openMirror(accountID: String) {
        guard let acc = account(id: accountID) else { return }
        NSWorkspace.shared.open(mirrorRoot(for: acc))
    }

    func openInBrowser(accountID: String) {
        NSWorkspace.shared.open(URL(string: "https://drive.google.com/drive/my-drive")!)
    }

    // MARK: - Access tokeni (auto-refresh)

    func validAccessToken(accountID: String) async throws -> String {
        if let cached = accessCache[accountID], cached.expiry > Date().addingTimeInterval(60) {
            return cached.token
        }
        if let blob = GoogleDriveKeychain.loadAccess(accountID: accountID),
           blob.expiry > Date().addingTimeInterval(60) {
            accessCache[accountID] = (blob.token, blob.expiry)
            return blob.token
        }
        let clientID = GoogleDriveAccountStore.clientID
        guard !clientID.isEmpty else { throw GoogleDriveAPIError.noAuth }
        guard let refresh = GoogleDriveKeychain.loadRefreshToken(accountID: accountID) else {
            throw GoogleDriveAPIError.noAuth
        }
        do {
            let (token, expiry) = try await GoogleOAuthService.refreshAccessToken(clientID: clientID, refreshToken: refresh)
            accessCache[accountID] = (token, expiry)
            GoogleDriveKeychain.saveAccess(token: token, expiry: expiry, accountID: accountID)
            return token
        } catch {
            // invalid_grant i sl. → nalog mora ponovo na Connect
            await MainActor.run { self.statuses[accountID] = .needsAuth }
            throw GoogleDriveAPIError.noAuth
        }
    }

    private func makeAPI(accountID: String) -> GoogleDriveAPI {
        GoogleDriveAPI(tokenProvider: { [weak self] in
            guard let self else { throw GoogleDriveAPIError.noAuth }
            return try await self.validAccessToken(accountID: accountID)
        })
    }

    // MARK: - Sync

    func sync(accountID: String) {
        guard account(id: accountID) != nil else { return }
        if syncTasks[accountID] != nil { return } // već traje
        statuses[accountID] = .syncing("Connecting…")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSync(accountID: accountID)
            await MainActor.run { self.syncTasks[accountID] = nil }
        }
        syncTasks[accountID] = task
    }

    func syncAll() {
        for a in accounts { sync(accountID: a.id) }
    }

    func cancelSync(accountID: String) {
        syncTasks[accountID]?.cancel()
        syncTasks[accountID] = nil
        statuses[accountID] = .idle
    }

    private func setStatus(_ s: GoogleDriveSyncStatus, for id: String) {
        statuses[id] = s
    }

    private func runSync(accountID: String) async {
        guard let acc = account(id: accountID) else { return }
        let api = makeAPI(accountID: accountID)
        do {
            setStatus(.syncing("Reading Drive…"), for: accountID)
            let files = try await api.listAllFiles()
            if Task.isCancelled { setStatus(.idle, for: accountID); return }

            setStatus(.syncing("Syncing \(files.count) files…"), for: accountID)
            // reconcile je nonisolated → radi van main actora; napredak se vraća
            // kroz progress callback koji skače nazad na main.
            let result = try await reconcile(account: acc, api: api, driveFiles: files, progress: { [weak self] message in
                Task { @MainActor in self?.statuses[accountID] = .syncing(message) }
            })
            if Task.isCancelled { setStatus(.idle, for: accountID); return }

            // Snimi lastSync
            if let idx = accounts.firstIndex(where: { $0.id == accountID }) {
                accounts[idx].lastSync = Date()
                accounts[idx].lastSyncError = nil
                GoogleDriveAccountStore.saveAccounts(accounts)
            }
            orphanedCount[accountID] = result.orphaned
            setStatus(.done(Date()), for: accountID)
            Self.log.info("gdrive sync done: down=\(result.downloaded) up=\(result.uploaded) orph=\(result.orphaned)")
            // Osveži FinderFlow prikaze koji gledaju mirror + bedž indeks
            GoogleDriveBadgeIndex.shared.invalidate(folder: nil)
            NotificationCenter.default.post(name: .refreshDirectory, object: mirrorRoot(for: acc))
        } catch let e as GoogleDriveAPIError {
            if Task.isCancelled { setStatus(.idle, for: accountID); return }
            if case .noAuth = e {
                setStatus(.needsAuth, for: accountID)
                return
            }
            if case .cancelled = e {
                setStatus(.idle, for: accountID)
                return
            }
            let msg = e.localizedDescription
            setStatus(.error(msg), for: accountID)
            if let idx = accounts.firstIndex(where: { $0.id == accountID }) {
                accounts[idx].lastSyncError = msg
                GoogleDriveAccountStore.saveAccounts(accounts)
            }
        } catch {
            if Task.isCancelled { setStatus(.idle, for: accountID); return }
            if (error as NSError).code == NSURLErrorCancelled {
                setStatus(.idle, for: accountID)
            } else {
                setStatus(.error(error.localizedDescription), for: accountID)
            }
        }
    }

    struct ReconcileResult {
        var downloaded = 0
        var uploaded = 0
        var orphaned = 0
    }

    /// Glavna reconcile petlja. `nonisolated` → izvršava se na cooperative pool-u,
    /// ne na main actoru (file IO + hashovanje ne smeju da blokiraju UI).
    /// NE diraj @Published odavde — napredak ide isključivo kroz `progress`.
    /// `internal` (ne private) da offline harness može da pozove reconcile bez
    /// pravog naloga — vidi docs/google-drive.md.
    nonisolated func reconcile(account: GoogleDriveAccount,
                                       api: GoogleDriveAPI,
                                       driveFiles: [GoogleDriveFile],
                                       progress: @escaping @Sendable (String) -> Void) async throws -> ReconcileResult {
        var result = ReconcileResult()
        let fm = FileManager.default
        let root = mirrorRoot(for: account)

        // 1. Indeksi
        var byID: [String: GoogleDriveFile] = [:]
        for f in driveFiles where !f.isTrashed { byID[f.id] = f }

        // children mapa: parentID -> [file]. Root deca = bez roditelja ili parent "root".
        var children: [String: [GoogleDriveFile]] = [:]
        var roots: [GoogleDriveFile] = []
        for f in byID.values {
            // Veza se pravi SAMO ka folderu koji je i sam u listi. Sve ostalo
            // (pravi root folder, literal "root", folder van vidokruga) znači
            // "vrh My Drive-a" — inače bi ta grana ostala nepohodana u BFS-u.
            let knownParents = (f.parents ?? []).filter { byID[$0] != nil }
            if knownParents.isEmpty {
                roots.append(f)
            } else {
                for p in knownParents {
                    children[p, default: []].append(f)
                }
            }
        }

        // folderID -> lokalna putanja (popunjava se hodom)
        var folderPath: [String: URL] = [:]

        // 2. Hod kroz stablo (BFS): prvo folderi, pa fajlovi
        // Da imena budu stabilna i bez sudara: ako dva fajla imaju isto ime u istom
        // folderu (moguće na Drive-u), drugom dodajemo " (2)" sufiks.
        func localName(for driveFile: GoogleDriveFile) -> String {
            if GoogleDriveAPI.isGoogleDoc(mime: driveFile.mimeType),
               let map = GoogleDriveAPI.exportMap[driveFile.mimeType] {
                let base = (driveFile.name as NSString).deletingPathExtension
                let clean = base.isEmpty ? driveFile.name : base
                return clean + "." + map.ext
            }
            return driveFile.name
        }

        // BFS red: (driveFolder | nil za root, localURL)
        var queue: [(GoogleDriveFile?, URL)] = [(nil, root)]
        // driveID -> localURL za sve (foldere + fajlove), za orphan detekciju
        var driveIDToLocal: [String: URL] = [:]
        // folder driveID -> parent driveID (za upload mapiranje)
        var folderParent: [String: String?] = [:]

        // Prvo obradi root decu
        let sortedRoots = roots.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        // Pomoćna: upiši folder + decu u red
        func enqueueChildren(of folderID: String?, localDir: URL, files: [GoogleDriveFile]) async {
            // Razdvoji foldere i fajlove; folderi prvi (da putanje postoje pre downloada)
            let folders = files.filter { $0.isFolder }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            let docs = files.filter { !$0.isFolder }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            var usedNames = Set<String>()
            for folder in folders {
                if Task.isCancelled { return }
                var name = folder.name.isEmpty ? "Untitled" : folder.name
                name = unique(name: name, used: &usedNames)
                let dir = localDir.appendingPathComponent(name, isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                writeSidecar(dir: dir, isDirectory: true, driveFile: folder, webLink: folder.webViewLink, exportExt: nil)
                folderPath[folder.id] = dir
                driveIDToLocal[folder.id] = dir
                folderParent[folder.id] = folderID
                queue.append((folder, dir))
            }
            // Fajlovi se skidaju ODMAH (ne u drugom prolazu) da redosled bude predvidiv
            // i da prekid ostavi konzistentno stanje.
            for file in docs {
                if Task.isCancelled { return }
                var name = localName(for: file)
                name = unique(name: name, used: &usedNames)
                // Sanitize: Drive dozvoljava "/" i ":" u imenima — macOS ne.
                name = name.replacingOccurrences(of: "/", with: ":")
                let dest = localDir.appendingPathComponent(name, isDirectory: false)
                driveIDToLocal[file.id] = dest
                // Treba li download? Uporedi sidecar (id + modified + md5/size).
                if needsDownload(driveFile: file, localURL: dest) {
                    progress("Downloading \(file.name)…")
                    do {
                        if GoogleDriveAPI.isGoogleDoc(mime: file.mimeType),
                           let map = GoogleDriveAPI.exportMap[file.mimeType] {
                            try await api.exportFile(id: file.id, exportMime: map.mime, to: dest)
                            writeSidecar(dir: dest, isDirectory: false, driveFile: file, webLink: file.webViewLink, exportExt: map.ext)
                        } else {
                            try await api.downloadFile(id: file.id, to: dest)
                            writeSidecar(dir: dest, isDirectory: false, driveFile: file, webLink: file.webViewLink, exportExt: nil)
                        }
                        if let mod = driveFileDate(file) {
                            try? fm.setAttributes([.modificationDate: mod], ofItemAtPath: dest.path)
                        }
                        result.downloaded += 1
                    } catch {
                        Self.log.error("gdrive download failed \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        // Nastavi sa ostalima — jedan pao fajl ne ruši ceo sync.
                    }
                }
            }
        }

        func unique(name: String, used: inout Set<String>) -> String {
            guard !used.contains(name) else {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var i = 2
                while true {
                    let cand = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
                    if !used.contains(cand) { used.insert(cand); return cand }
                    i += 1
                }
            }
            used.insert(name)
            return name
        }

        await enqueueChildren(of: nil, localDir: root, files: sortedRoots)
        var head = 0
        while head < queue.count {
            if Task.isCancelled { break }
            let (folderOpt, dir) = queue[head]
            head += 1
            guard let folder = folderOpt else { continue }
            let kids = (children[folder.id] ?? []).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            await enqueueChildren(of: folder.id, localDir: dir, files: kids)
        }

        // 3. UPLOAD: lokalni fajlovi bez sidecara (novi) + izmenjeni (mtime > sidecar.lastSynced)
        // Hod kroz mirror (bez .gdrive.json i bez hidden fajlova).
        if !Task.isCancelled {
            let uploaded = try await uploadNewAndChanged(root: root, api: api, folderPath: folderPath, driveIDToLocal: driveIDToLocal, byID: byID)
            result.uploaded = uploaded
        }

        // 4. ORPHANED: lokalni fajlovi sa sidecarom čiji driveID više ne postoji na Drive-u.
        if !Task.isCancelled {
            result.orphaned = countOrphaned(root: root, knownIDs: Set(byID.keys))
        }

        return result
    }

    // MARK: - Download odluka

    nonisolated func needsDownload(driveFile: GoogleDriveFile, localURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localURL.path) else { return true }
        guard let sideData = GoogleDrivePaths.sidecarData(for: localURL, isDirectory: false),
              let side = try? JSONDecoder().decode(GoogleDriveSidecar.self, from: sideData),
              side.driveID == driveFile.id else {
            // Postoji fajl istog imena ali nije naš mirror zapis (korisnik ga je
            // napravio ručno) — NE gazi ga downloadom; upload faza će ga poslati kao novi
            // samo ako ime nije zauzeto... Za sigurnost: preskoči download, ostavi lokalno.
            // (Ako je baš Drive fajl bez sidecara jer je sync prekinut — sledeći sync
            // sa istim imenom ga neće dirati, ali orphan/upload logika ga pokriva.)
            // Heuristika: ako se veličina i vreme poklapaju, tretiraj kao sinhronizovan.
            return !looksSameAsLocal(driveFile: driveFile, localURL: localURL)
        }
        // Uporedi modifiedTime
        if let driveMod = driveFileDate(driveFile), let sideMod = side.driveModified {
            // Drive preciznost je ms; toleriši 2s + dozvoli da lokalni noviji mtime
            // (korisnik editovao posle sync-a) NE pokrene download — to rešava upload faza.
            if abs(driveMod.timeIntervalSince(sideMod)) < 2 { return false }
            // Ako je lokalni fajl noviji od Drive verzije, ne skidaj (čuvaj lokalne izmene).
            if let localMod = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               localMod > driveMod.addingTimeInterval(2),
               localMod > side.lastSynced {
                return false
            }
            return true
        }
        // Fallback: md5/size
        if let md5 = driveFile.md5Checksum, let sideMD5 = side.md5, !md5.isEmpty {
            return md5 != sideMD5
        }
        if driveFile.byteSize > 0, let s = side.size {
            return driveFile.byteSize != s
        }
        return true
    }

    nonisolated private func looksSameAsLocal(driveFile: GoogleDriveFile, localURL: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path) else { return false }
        let localSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        if driveFile.byteSize > 0 && localSize == driveFile.byteSize { return true }
        return false
    }

    nonisolated private func driveFileDate(_ f: GoogleDriveFile) -> Date? {
        guard let s = f.modifiedTime else { return nil }
        return ISO8601DateFormatter.drive.date(from: s) ?? ISO8601DateFormatter.drivePlain.date(from: s)
    }

    nonisolated private func writeSidecar(dir localURL: URL, isDirectory: Bool, driveFile: GoogleDriveFile, webLink: String?, exportExt: String?) {
        let side = GoogleDriveSidecar(
            driveID: driveFile.id,
            driveModified: driveFileDate(driveFile),
            md5: driveFile.md5Checksum,
            size: driveFile.byteSize > 0 ? driveFile.byteSize : nil,
            webViewLink: webLink,
            exportExt: exportExt,
            lastSynced: Date()
        )
        guard let data = try? JSONEncoder().encode(side) else { return }
        try? data.write(to: GoogleDrivePaths.sidecar(for: localURL, isDirectory: isDirectory))
        // Migracija: stari vidljivi sidecar više ne treba (i smetao je u listingu).
        if let legacy = GoogleDrivePaths.legacySidecar(for: localURL, isDirectory: isDirectory),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    // MARK: - Enumeracija (sync helper)

    /// NSEnumerator.makeIterator() nije dostupan iz async konteksta — skupi URL-ove
    /// u sinhronoj funkciji pa iteriraj po nizu.
    nonisolated private static func enumerateURLs(at root: URL, keys: [URLResourceKey]) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e { out.append(url) }
        return out
    }

    // MARK: - Upload faza

    nonisolated func uploadNewAndChanged(root: URL, api: GoogleDriveAPI, folderPath: [String: URL], driveIDToLocal: [String: URL], byID: [String: GoogleDriveFile]) async throws -> Int {
        let fm = FileManager.default
        let localURLs = Self.enumerateURLs(at: root, keys: [.isDirectoryKey, .contentModificationDateKey])
        // localDir.path -> driveFolderID (inverz folderPath + root=nil→ "root")
        var dirToFolderID: [String: String] = [:]
        for (fid, url) in folderPath { dirToFolderID[url.standardizedFileURL.path] = fid }

        // Putanje koje su već mirror fajlovi — Set, ne linearna pretraga po
        // svakom lokalnom fajlu (na 10k fajlova to je bilo O(n²)).
        let mirroredPaths = Set(driveIDToLocal.values.map { $0.standardizedFileURL.path })
        var uploaded = 0
        var createdFolderIDs: [String: String] = [:] // localDir.path -> newDriveID (lokalno napravljeni folderi)

        func driveFolderID(forDirectory dir: URL) async throws -> String {
            let key = dir.standardizedFileURL.path
            if let fid = dirToFolderID[key] { return fid }
            if let created = createdFolderIDs[key] { return created }
            // Novi lokalni folder → napravi ga na Drive-u (rekurzivno roditelje)
            let parent = dir.deletingLastPathComponent()
            let parentID: String
            if parent.standardizedFileURL.path == root.standardizedFileURL.path {
                parentID = "root"
            } else {
                parentID = try await driveFolderID(forDirectory: parent)
            }
            let newID = try await api.createFolder(name: dir.lastPathComponent, parentID: parentID)
            createdFolderIDs[key] = newID
            return newID
        }

        for url in localURLs {
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            // Preskoči sidecare i sistemske fajlove
            if GoogleDrivePaths.isSidecarName(name) { continue }
            if name == ".DS_Store" { continue }
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if vals?.isDirectory == true { continue } // foldere pravimo po potrebi
            // Da li ima sidecar sa poznatim driveID?
            if let sideData = GoogleDrivePaths.sidecarData(for: url, isDirectory: false),
               let side = try? JSONDecoder().decode(GoogleDriveSidecar.self, from: sideData),
               byID[side.driveID] != nil {
                // Poznat fajl: da li je lokalno izmenjen posle sync-a?
                if let localMod = vals?.contentModificationDate, localMod > side.lastSynced.addingTimeInterval(2) {
                    // Google Docs exporti se ne uploaduju nazad u v1 (export je jednosmeran) —
                    // preskoči da ne pregaziš Docs dokument binarnim docx-om.
                    if side.exportExt != nil { continue }
                    do {
                        try await api.updateFileContent(driveID: side.driveID, localURL: url, mimeType: GoogleDriveAPI.mimeForLocalFile(url))
                        // Osveži sidecar lastSynced + size
                        var updated = side
                        updated.lastSynced = Date()
                        updated.size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                        if let data = try? JSONEncoder().encode(updated) {
                            try? data.write(to: GoogleDrivePaths.sidecar(for: url, isDirectory: false))
                        }
                        uploaded += 1
                    } catch {
                        Self.log.error("gdrive upload (update) failed \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                continue
            }
            // Novi lokalni fajl → upload u roditeljski Drive folder
            // (ali ne i fajlove koji su Drive fajlovi bez sidecara zbog sudara imena —
            // oni imaju isto ime kao driveIDToLocal vrednost; preskoči da ne dupliraš)
            if mirroredPaths.contains(url.standardizedFileURL.path) { continue }
            // Exportovani Google Docs (.docx iz Docs-a) bez sidecara? Ne uploaduj — to je
            // verovatno korisnikov novi fajl sa istim imenom. Uploaduj ga normalno (novi fajl).
            do {
                let parentDir = url.deletingLastPathComponent()
                let parentID = try await driveFolderID(forDirectory: parentDir)
                let newID = try await api.uploadFile(localURL: url, name: name, parentID: parentID, mimeType: GoogleDriveAPI.mimeForLocalFile(url))
                // Zapiši sidecar da sledeći sync zna da je sinhronizovan
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                let side = GoogleDriveSidecar(driveID: newID, driveModified: vals?.contentModificationDate, md5: nil, size: size, webViewLink: nil, exportExt: nil, lastSynced: Date())
                if let data = try? JSONEncoder().encode(side) {
                    try? data.write(to: GoogleDrivePaths.sidecar(for: url, isDirectory: false))
                }
                uploaded += 1
            } catch {
                Self.log.error("gdrive upload (new) failed \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return uploaded
    }

    nonisolated func countOrphaned(root: URL, knownIDs: Set<String>) -> Int {
        var count = 0
        for url in Self.enumerateURLs(at: root, keys: [.isDirectoryKey]) {
            let name = url.lastPathComponent
            if GoogleDrivePaths.isSidecarName(name) || name == ".DS_Store" { continue }
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = vals?.isDirectory ?? false
            if let sideData = GoogleDrivePaths.sidecarData(for: url, isDirectory: isDir),
               let side = try? JSONDecoder().decode(GoogleDriveSidecar.self, from: sideData),
               !knownIDs.contains(side.driveID) {
                count += 1
            }
        }
        return count
    }

    // MARK: - Auto-sync

    private func startAutoTimer() {
        autoTimer?.invalidate()
        // Na svakih 10 min, ako je autoSync ON i ima naloga i nije u toku sync.
        autoTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard GoogleDriveAccountStore.autoSyncEnabled else { return }
                for a in self.accounts where !(self.statuses[a.id]?.isSyncing ?? false) {
                    // Sync samo ako je prošlo >10 min od poslednjeg
                    if let last = a.lastSync, Date().timeIntervalSince(last) < 600 { continue }
                    self.sync(accountID: a.id)
                }
            }
        }
    }
}
