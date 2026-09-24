import SwiftUI
import AppKit

// MARK: - Google Drive bedževi u listi fajlova i u preview panelu
//
// Cilj: dok browse-uješ mirror folder, odmah vidiš šta je šta —
//   • synced     — fajl je poznat Drive-u i lokalna kopija je aktuelna
//   • googleDoc  — lokalni .docx/.xlsx/.pptx je EXPORT Google dokumenta
//                  (original živi na webu; dupli klik otvara Docs u browseru)
//   • stub       — .gdoc/.gsheet bookmark iz Drive for Desktop aplikacije
//   • pending    — lokalno napravljen fajl koji još nije poslat na Drive
//
// Cena: jedan `contentsOfDirectory` po folderu (na background threadu) +
// čitanje sidecara. Rezultat se kešira po folderu i invalidira na
// `.refreshDirectory`, pa listanje ostaje brzo kao i do sada.

enum GoogleDriveBadgeKind: Equatable {
    case synced
    case googleDoc(String?)   // webViewLink, ako ga sidecar ima
    case stub
    case pending

    var symbol: String {
        switch self {
        case .synced:    return "checkmark.icloud.fill"
        case .googleDoc: return "doc.text.fill"
        case .stub:      return "arrow.up.forward.app.fill"
        case .pending:   return "arrow.up.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .synced:    return .green
        case .googleDoc: return Color(red: 0.26, green: 0.52, blue: 0.96) // Google plava
        case .stub:      return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .pending:   return .orange
        }
    }

    var help: String {
        switch self {
        case .synced:    return "Synced with Google Drive"
        case .googleDoc: return "Google document — original is on the web, this is a local export"
        case .stub:      return "Google Docs shortcut — opens in the browser"
        case .pending:   return "Not uploaded to Drive yet (next sync)"
        }
    }

    var label: String {
        switch self {
        case .synced:    return "Drive • synced"
        case .googleDoc: return "Google document (export)"
        case .stub:      return "Google Docs shortcut"
        case .pending:   return "Waiting for upload"
        }
    }

    var webLink: URL? {
        if case .googleDoc(let link) = self, let link, let url = URL(string: link) { return url }
        return nil
    }
}

// MARK: - Red koji nosi bedž (dekuplovano od FileItem)
//
// Harness `tools/gdrive-test` kompajlira ovaj fajl bez `FileItem.swift`,
// pa `kind(for:)` ne sme da traži konkretan `FileItem` tip. Protokol nosi
// tačno 4 polja koja bedž-put treba (id==path, name, lowercased ext, url).
// `FileItem` konformira u `FileItem.swift`; app pozivi `kind(for: item)`
// rade nepromenjeno.
protocol DriveBadgeRow {
    var id: String { get }
    var name: String { get }
    var fileExtension: String { get }
    var url: URL { get }
}

// MARK: - Indeks (po folderu, lazy, off-main)

/// Konstante mirrora, izdvojene iz @MainActor klase jer se čitaju u najtoplijem
/// putu u aplikaciji: `kind(for:)` se zove jednom po redu liste, a lista u
/// ~/Downloads ima 7.8k redova i SwiftUI je pregradi na svaki klik. Ranije je
/// svaki red radio `FileManager.urls(for:)` (GoogleDrivePaths.base je computed)
/// + dvije `standardizedFileURL` normalizacije + alokaciju niza ekstenzija —
/// izmjereno 7.839 poziva i ~0,2 s CPU-a po kliku. Sve je sada konstanta.
private enum GDMirror {
    static let basePath: String = GoogleDrivePaths.base.standardizedFileURL.path
    static let basePrefix: String = basePath + "/"
    static let stubExtensions: Set<String> = ["gdoc", "gsheet", "gslides", "gdraw", "gform", "gsite", "gmap"]
    /// Postoji li mirror uopšte. Bez Drive naloga ovo je `false` i cijeli
    /// bedž-put izlazi na prvoj liniji. Osvježava se na invalidaciju foldera
    /// (dakle kad se listing promijeni), nikad po redu.
    nonisolated(unsafe) static var exists: Bool = FileManager.default.fileExists(atPath: basePath)
    static func refreshExistence() { exists = FileManager.default.fileExists(atPath: basePath) }
}

@MainActor
final class GoogleDriveBadgeIndex: ObservableObject {
    static let shared = GoogleDriveBadgeIndex()

    /// Raste kad neki folder dobije svež indeks — poglediri koji crtaju bedževe
    /// posmatraju ovaj objekat pa se preslikaju tek kad podaci stignu.
    @Published private(set) var version: Int = 0

    private var folders: [String: [String: GoogleDriveBadgeKind]] = [:]
    private var loading: Set<String> = []
    /// Uzastopne ćelije liste dele isti folder: keš zadnje razrešene
    /// (dir → mapa) spušta cenu po redu sa standardizedFileURL (~11µs,
    /// izmereno) na string-poredjenje. Redovi se crtaju sekvencijalno pa je
    /// hit-rate ~100% — bez ovoga je svaki klik u mirroru plaćao N×11µs.
    private var lastDirKey: String?
    private var lastMap: [String: GoogleDriveBadgeKind]?
    /// Raw-dir ključ za kind(for: DriveBadgeRow) — sirovi roditelj (bez
    /// standardizacije) da se poredjenje po redu svede na string ==".
    private var lastRawDir: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .refreshDirectory, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.object as? URL
            Task { @MainActor in self?.invalidate(folder: url) }
        }
    }

    /// Da li putanja uopšte pripada našem mirroru? (poređenje stringova, bez diska)
    ///
    /// Putanje iz listinga su već normalizovane, pa se `standardizedFileURL`
    /// plaća samo ako jeftina provjera padne, a putanja stvarno sadrži „/." ili
    /// „//" — inače bi svaki red velike liste platio normalizaciju bez potrebe.
    ///
    /// Normalizovanost se proverava bajt-skenom, ne `String.contains`:
    /// `contains` sa String argumentom radi Unicode canonical pretragu
    /// (~10µs po putanji, izmereno — 50ms po kliku na 5k folder), bajt-sken
    /// ~1.5µs za istu putanju uz identičan rezultat (ASCII „/" i „." nemaju
    /// višebajtne oblike pa je bajt-poredjenje egzaktno).
    nonisolated static func isMirrorPath(_ url: URL) -> Bool {
        guard GDMirror.exists else { return false }
        let p = url.path
        if p == GDMirror.basePath || p.hasPrefix(GDMirror.basePrefix) { return true }
        guard p.utf8.count > GDMirror.basePath.utf8.count,
              hasDotOrDoubleSlash(p) else { return false }
        let s = url.standardizedFileURL.path
        return s == GDMirror.basePath || s.hasPrefix(GDMirror.basePrefix)
    }

    /// True ako putanja sadrži „/." ili „//" — samo ASCII bajtovi, bez Unicode
    /// canonical pretrage koju radi `String.contains` (6× sporije, izmereno).
    nonisolated private static func hasDotOrDoubleSlash(_ p: String) -> Bool {
        var prevSlash = false
        for b in p.utf8 {
            if b == 0x2F /* "/" */ {
                if prevSlash { return true }
                prevSlash = true
            } else {
                if prevSlash && b == 0x2E /* "." */ { return true }
                prevSlash = false
            }
        }
        return false
    }

    /// Sinhroni pogled u keš. Ako folder još nije indeksiran, pokreće se
    /// učitavanje u pozadini i vraća se nil (bedž se pojavi u sledećem prolazu).
    func kind(for url: URL) -> GoogleDriveBadgeKind? {
        // .gdoc/.gsheet stubovi rade svuda (i van mirrora) — samo po ekstenziji,
        // bez čitanja fajla, da listanje ostane besplatno. Case-sensitive prvo:
        // 99% ekstenzija je već lowercase pa se preskače lowercased() alokacija.
        let ext = url.pathExtension
        if !ext.isEmpty, ext.utf8.count <= 7 {
            if GDMirror.stubExtensions.contains(ext) { return .stub }
            let low = ext.lowercased()
            if low != ext, GDMirror.stubExtensions.contains(low) { return .stub }
        }
        guard Self.isMirrorPath(url) else { return nil }
        let dir = url.deletingLastPathComponent().standardizedFileURL.path
        if dir == lastDirKey, let m = lastMap { return m[url.lastPathComponent] ?? .pending }
        guard let map = folders[dir] else {
            load(folder: url.deletingLastPathComponent())
            return nil
        }
        lastDirKey = dir
        lastMap = map
        return map[url.lastPathComponent] ?? .pending
    }

    /// Brža varijanta za redove liste: koristi već-izračunata polja iz reda
    /// (lowercased ext, id==path, name) pa po redu ne alocira NIŠTA — ni
    /// pathExtension, ni url.path, ni lastPathComponent. Dir-ključ se izvodi
    /// string-sečenjem id-ja i standardizuje jednom po folderu (lastRawDir).
    /// Izmereno na 5.2k folderu sa mirrorom: kind(for: URL) 17ms → ovde ~5ms.
    func kind(for item: any DriveBadgeRow) -> GoogleDriveBadgeKind? {
        let ext = item.fileExtension // load() ga već drži lowercased
        if !ext.isEmpty, ext.utf8.count <= 7, GDMirror.stubExtensions.contains(ext) { return .stub }
        guard GDMirror.exists else { return nil }
        // item.id == url.path (FileItem.load) — bez url.path alokacije.
        let p = item.id
        // Dir kao string-sečak id-ja — bez deletingLastPathComponent URL alokacije.
        // Ime ne može sadržati „/", pa je roditelj sve do zadnjeg „/".
        let rawDir: String
        if let i = p.lastIndex(of: "/"), i != p.startIndex {
            rawDir = String(p[..<i])
        } else {
            rawDir = "/"
        }
        // Uzastopni redovi istog foldera: samo map-lookup po imenu.
        // lastMap==nil znači „nije mirror ili učitavanje u toku" → nil
        // (bedž stiže sa version bumpom); postojeća mapa + nepoznato ime = .pending.
        if rawDir == lastRawDir {
            guard let m = lastMap else { return nil }
            return m[item.name] ?? .pending
        }
        // Jednom po folderu: normalizuj ključ (samo ako treba), pa gate + lookup.
        // rawDir bez „/."/„//" se ne menja standardizacijom (samo leksička
        // normalizacija, symlinkovi se ne razrešavaju), pa je sam sebi ključ.
        let key = Self.hasDotOrDoubleSlash(rawDir)
            ? URL(fileURLWithPath: rawDir).standardizedFileURL.path
            : rawDir
        guard key == GDMirror.basePath || key.hasPrefix(GDMirror.basePrefix) else {
            lastRawDir = rawDir
            lastMap = nil
            return nil
        }
        guard let map = folders[key] else {
            lastRawDir = rawDir
            lastMap = nil
            load(folder: item.url.deletingLastPathComponent())
            return nil
        }
        lastRawDir = rawDir
        lastMap = map
        return map[item.name] ?? .pending
    }

    /// Pozovi kad otvoriš folder (npr. iz preview panela) da bedževi budu spremni.
    func prefetch(folder: URL) {
        guard Self.isMirrorPath(folder) else { return }
        if folders[folder.standardizedFileURL.path] == nil { load(folder: folder) }
    }

    func invalidate(folder: URL?) {
        // Mirror je mogao nastati (prvi Drive nalog) ili nestati od zadnjeg
        // listinga — provjeri ovdje, jednom po promjeni, ne u `kind(for:)`.
        GDMirror.refreshExistence()
        // lastDir/lastMap/lastRawDir bi inače držali ustajalu mapu obrisanog foldera.
        lastDirKey = nil
        lastMap = nil
        lastRawDir = nil
        guard let folder else { folders.removeAll(); version &+= 1; return }
        let p = folder.standardizedFileURL.path
        guard folders.removeValue(forKey: p) != nil else { return }
        version &+= 1
    }

    private func load(folder: URL) {
        let key = folder.standardizedFileURL.path
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task.detached(priority: .utility) {
            let map = Self.scan(folder: folder)
            await MainActor.run {
                self.folders[key] = map
                self.loading.remove(key)
                self.version &+= 1
            }
        }
    }

    /// Jedan listing foldera + čitanje sidecara. Radi van main actora.
    nonisolated private static func scan(folder: URL) -> [String: GoogleDriveBadgeKind] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var out: [String: GoogleDriveBadgeKind] = [:]
        for name in names {
            guard let owner = GoogleDrivePaths.ownerName(ofSidecar: name) else { continue }
            let data = try? Data(contentsOf: folder.appendingPathComponent(name, isDirectory: false))
            guard let data, let side = try? JSONDecoder().decode(GoogleDriveSidecar.self, from: data) else { continue }
            out[owner] = side.exportExt != nil ? .googleDoc(side.webViewLink) : .synced
        }
        return out
    }
}

// MARK: - Bedž u redu liste

struct GoogleDriveBadgeView: View {
    let kind: GoogleDriveBadgeKind
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind.tint)
            .font(.system(size: size))
            .help(kind.help)
            .accessibilityLabel(kind.label)
    }
}

// MARK: - Red u preview panelu (info o Drive statusu + dugme za web original)

struct GoogleDriveInfoRow: View {
    let url: URL
    @ObservedObject private var index = GoogleDriveBadgeIndex.shared

    var body: some View {
        if let kind = index.kind(for: url) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                GoogleDriveBadgeView(kind: kind, size: 10)
                Text(kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let web = webTarget(for: kind) {
                    Button("Open in Drive") { NSWorkspace.shared.open(web) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private func webTarget(for kind: GoogleDriveBadgeKind) -> URL? {
        if case .stub = kind { return GoogleLocalDrive.docsStubURL(at: url) }
        return kind.webLink
    }
}
