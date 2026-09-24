import Foundation
import AppKit
import Security

// MARK: - Google Drive nativni nalozi (više naloga, bez Drive aplikacije)
//
// Arhitektura: svaki Google nalog dobija LOKALNI mirror folder:
//   ~/Library/Application Support/FinderFlow/GoogleDrive/<sanitized-email>/My Drive/...
//
// Zašto mirror, a ne virtuelni `gdrive://` scheme?
// - FileItem, ContentView, List/Icons/Columns, preview, editor, Quick Look,
//   tags, search, drag&drop — SVE radi bez izmena jer su fajlovi obični lokalni fajlovi.
// - "Nativno" znači: dupli klik otvara, ⌘S čuva, preview radi, copy-path radi.
// - Sync engine održava mirror svežim preko Drive API v3 (OAuth + PKCE, tokeni u Keychainu).
//
// Privatnost (ista filozofija kao ostatak app-a):
// - OFF dok ne povežeš nalog. Nema telemetrije, nema releja — Mac priča direktno
//   sa googleapis.com samo kad ti stisneš Sync / otvoriš Drive folder.
// - Refresh tokeni su u Keychainu (kSecClassGenericPassword), nikad u UserDefaults/plist.
// - U UserDefaults je samo metadata (email, ime, lastSync) — bez tajni.

// MARK: - Model

struct GoogleDriveAccount: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var email: String = ""
    var displayName: String = ""
    var pictureURL: String? = nil
    var addedDate: Date = Date()
    var lastSync: Date? = nil
    var lastSyncError: String? = nil

    var shortLabel: String {
        if !displayName.isEmpty { return displayName }
        if !email.isEmpty { return email }
        return "Google Drive"
    }

    /// Folder-safe deo putanje: "nikola.andric@gmail.com" -> "nikola_andric_gmail_com"
    var folderSafeEmail: String {
        let base = email.isEmpty ? id : email
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var out = ""
        out.reserveCapacity(base.count)
        for scalar in base.unicodeScalars {
            if allowed.contains(scalar) {
                out.append(Character(scalar))
            } else if scalar == "@" {
                out.append("_at_")
            } else if scalar == "." {
                out.append("_")
            } else {
                out.append("_")
            }
        }
        // Skrati predugačke (email + UUID fallback može biti dugačak)
        if out.count > 64 { out = String(out.prefix(64)) }
        return out.isEmpty ? id : out
    }

    /// Lokalni mirror root: .../GoogleDrive/<email>/My Drive
    func mirrorRoot() -> URL {
        GoogleDrivePaths.accountRoot(for: self).appendingPathComponent("My Drive", isDirectory: true)
    }
}

enum GoogleDriveSyncPhase: String, Codable {
    case idle
    case syncing
    case error
    case needsAuth
}

// MARK: - Putanje

enum GoogleDrivePaths {
    static var base: URL {
        // Test-izolacija: harness `tools/gdrive-test/run.sh` postavlja
        // FF_GDRIVE_BASE na temp folder, pa reconcile/sidecari/bedževi nikad
        // ne diraju pravi ~/Library/... mirror korisnika. Bez env vara —
        // standardna app putanja, nepromenjeno ponašanje.
        if let overrideDir = ProcessInfo.processInfo.environment["FF_GDRIVE_BASE"],
           !overrideDir.isEmpty {
            return URL(fileURLWithPath: overrideDir, isDirectory: true)
        }
        let fm = FileManager.default
        // Application Support je pravo mesto za app-owned mirror (ne roaming dokumenti,
        // ne keš koji sistem sme da obriše). FinderFlow nije sandboxed pa je putanja direktna.
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("FinderFlow", isDirectory: true)
            .appendingPathComponent("GoogleDrive", isDirectory: true)
    }

    static func accountRoot(for account: GoogleDriveAccount) -> URL {
        base.appendingPathComponent(account.folderSafeEmail, isDirectory: true)
    }

    static let sidecarSuffix = ".gdrive.json"

    /// Metadata sidecar po mirror fajlu: ".<ime>.gdrive.json" pored fajla,
    /// za foldere: "<folder>/.gdrive.json". Čuva driveId + modifiedTime + md5.
    ///
    /// Tačka na početku je namerna: bez nje bi svaki sinhronizovan fajl dobio
    /// vidljivog "blizanca" u listingu (i u Finderu i u FinderFlow-u).
    static func sidecar(for localURL: URL, isDirectory: Bool) -> URL {
        if isDirectory {
            return localURL.appendingPathComponent(sidecarSuffix, isDirectory: false)
        } else {
            return localURL.deletingLastPathComponent()
                .appendingPathComponent("." + localURL.lastPathComponent + sidecarSuffix, isDirectory: false)
        }
    }

    /// Stari, vidljivi format ("<ime>.gdrive.json") — čita se radi migracije
    /// mirrora napravljenih pre skrivanja sidecara.
    static func legacySidecar(for localURL: URL, isDirectory: Bool) -> URL? {
        guard !isDirectory else { return nil }
        return localURL.deletingLastPathComponent()
            .appendingPathComponent(localURL.lastPathComponent + sidecarSuffix, isDirectory: false)
    }

    /// Sadržaj sidecara (novi format, pa stari).
    static func sidecarData(for localURL: URL, isDirectory: Bool) -> Data? {
        if let d = try? Data(contentsOf: sidecar(for: localURL, isDirectory: isDirectory)) { return d }
        if let legacy = legacySidecar(for: localURL, isDirectory: isDirectory) {
            return try? Data(contentsOf: legacy)
        }
        return nil
    }

    /// Ime fajla kome sidecar pripada, iz imena stavke u listingu foldera.
    /// ".Izveštaj.docx.gdrive.json" -> "Izveštaj.docx" (i stari oblik bez tačke).
    /// Za sam folderski sidecar (".gdrive.json") vraća nil.
    static func ownerName(ofSidecar name: String) -> String? {
        guard name.hasSuffix(sidecarSuffix), name != sidecarSuffix else { return nil }
        var owner = String(name.dropLast(sidecarSuffix.count))
        if owner.hasPrefix(".") { owner.removeFirst() }
        return owner.isEmpty ? nil : owner
    }

    /// Da li je ime iz listinga naš sidecar (skriveni ili stari vidljivi)?
    static func isSidecarName(_ name: String) -> Bool { name.hasSuffix(sidecarSuffix) }

    static func ensureBaseExists() {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
}

// MARK: - Account store (metadata u UserDefaults, tajne u Keychainu)

final class GoogleDriveAccountStore {
    static let accountsKey = "ffGoogleDriveAccounts.v1"
    static let clientIDKey = "ffGoogleClientID"
    static let autoSyncKey = "ffGoogleDriveAutoSync"

    static func loadAccounts() -> [GoogleDriveAccount] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let list = try? JSONDecoder().decode([GoogleDriveAccount].self, from: data)
        else { return [] }
        return list
    }

    static func saveAccounts(_ accounts: [GoogleDriveAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    static var clientID: String {
        get { UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey) }
    }

    static var autoSyncEnabled: Bool {
        get {
            // Default ON jednom kad postoji nalog — korisnik je eksplicitno povezao Drive.
            if UserDefaults.standard.object(forKey: autoSyncKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoSyncKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoSyncKey) }
    }
}

// MARK: - Keychain (refresh tokeni, per-account)

enum GoogleDriveKeychain {
    private static func service(for accountID: String) -> String {
        "FinderFlow.googleDrive.\(accountID)"
    }
    private static let refreshAccount = "refresh-token"
    private static let accessAccount = "access-token-json" // JSON: {token, expiry}

    struct AccessBlob: Codable {
        var token: String
        var expiry: Date
    }

    static func loadRefreshToken(accountID: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: accountID),
            kSecAttrAccount as String: refreshAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
    }

    static func saveRefreshToken(_ token: String, accountID: String) {
        let data = Data(token.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: accountID),
            kSecAttrAccount as String: refreshAccount,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        } else {
            var add = q
            add[kSecValueData as String] = data
            // Keychain item koji druge app ne mogu da čitaju bez unlocka.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deleteTokens(accountID: String) {
        for account in [refreshAccount, accessAccount] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service(for: accountID),
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(q as CFDictionary)
        }
    }

    static func loadAccess(accountID: String) -> AccessBlob? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: accountID),
            kSecAttrAccount as String: accessAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let blob = try? JSONDecoder().decode(AccessBlob.self, from: data),
              !blob.token.isEmpty
        else { return nil }
        return blob
    }

    static func saveAccess(token: String, expiry: Date, accountID: String) {
        guard let data = try? JSONEncoder().encode(AccessBlob(token: token, expiry: expiry)) else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: accountID),
            kSecAttrAccount as String: accessAccount,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        } else {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Lokalni Drive-detektor (Drive for Desktop, ako postoji pored API naloga)
//
// Postojeći SidebarView.detectedCloudFolders() već pokriva ~/Library/CloudStorage.
// Ovo dodaje: koji email nalog stoji iza kog foldera + da li je File Provider online,
// + otvaranje .gdoc/.gsheet stubova u browseru (to su bookmark fajlovi, ne pravi dokumenti).

enum GoogleLocalDrive {
    struct LocalMount: Hashable {
        var url: URL
        var email: String?
        var isFileProvider: Bool
    }

    /// "GoogleDrive-moj@gmail.com" -> "moj@gmail.com"
    static func email(from url: URL) -> String? {
        let last = url.lastPathComponent
        guard last.lowercased().hasPrefix("googledrive") else { return nil }
        // Formati: "GoogleDrive-user@gmail.com", "GoogleDrive_user@gmail.com", "My Drive"
        let stripped = last
            .replacingOccurrences(of: "GoogleDrive-", with: "")
            .replacingOccurrences(of: "GoogleDrive_", with: "")
            .replacingOccurrences(of: "GoogleDrive", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        if stripped.contains("@") { return stripped }
        return nil
    }

    static func localMounts() -> [LocalMount] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var out: [LocalMount] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let key = url.resolvingSymlinksInPath().path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            let isFP = url.path.contains("/Library/CloudStorage/")
            out.append(LocalMount(url: url, email: email(from: url), isFileProvider: isFP))
        }

        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in children where url.lastPathComponent.lowercased().hasPrefix("googledrive") {
                add(url)
            }
        }
        for name in ["Google Drive", "GoogleDrive", "My Drive"] {
            add(home.appendingPathComponent(name, isDirectory: true))
        }
        return out.sorted { ($0.email ?? $0.url.lastPathComponent) < ($1.email ?? $1.url.lastPathComponent) }
    }

    /// Google Docs stub fajlovi koje pravi Drive for Desktop (.gdoc/.gsheet/.gslides/.gdraw…):
    /// JSON sa {"url": "https://docs.google.com/..."} — otvaraju se u browseru, ne u editoru.
    static func docsStubURL(at fileURL: URL) -> URL? {
        let ext = fileURL.pathExtension.lowercased()
        guard ["gdoc", "gsheet", "gslides", "gdraw", "gform", "gsite", "gmap"].contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else { return nil }
        return url
    }

    static func isDocsStub(_ fileURL: URL) -> Bool { docsStubURL(at: fileURL) != nil }
}

// MARK: - Google Docs stub otvaranje (.gdoc/.gsheet/… + exportovani Docs)

enum GoogleDocsOpener {
    /// Ako je URL Google Docs stub ili exportovan Docs iz mirror-a (sidecar sa exportExt),
    /// otvori original u browseru i vrati true. Inače false (normalno otvaranje).
    @discardableResult
    static func openIfGoogleDoc(_ url: URL) -> Bool {
        // 1. Drive for Desktop stubovi (.gdoc/.gsheet/…)
        if let webURL = GoogleLocalDrive.docsStubURL(at: url) {
            NSWorkspace.shared.open(webURL)
            return true
        }
        // 2. Naš mirror: exportovani Docs ima sidecar sa webViewLink
        if let data = GoogleDrivePaths.sidecarData(for: url, isDirectory: false),
           let side = try? JSONDecoder().decode(GoogleDriveSidecar.self, from: data),
           side.exportExt != nil,
           let link = side.webViewLink,
           let webURL = URL(string: link) {
            // ⌥-klik otvara lokalni export, običan klik ide na web (Google Docs se
            // najbolje edituje u browseru; lokalni docx je offline kopija).
            if NSEvent.modifierFlags.contains(.option) {
                return false
            }
            NSWorkspace.shared.open(webURL)
            return true
        }
        return false
    }
}
