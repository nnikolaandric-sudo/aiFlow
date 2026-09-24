import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers
import ImageIO

// MARK: - Folder rules (automatsko sređivanje foldera, kao Hazel)
//
// Korisnik desnim klikom označi folder („Auto-Sort This Folder") i napiše
// pravila običnim jezikom: „PDF račune stavi u ~/Documents/Računi",
// „screenshotove premjesti u Screenshots", „instalacije starije od 7 dana baci
// u smeće". FinderFlow prati folder i novim fajlovima radi ono što kaže prvo
// pravilo koje odgovara.
//
// Pravila bezbjednosti:
//   • samo novi fajlovi — ono što je bilo u folderu prije označavanja čeka
//     eksplicitno „Sort existing files" nakon pregleda;
//   • nikad trajno brisanje, samo Trash; svaki potez ide u dnevnik sa Undo;
//   • gleda se samo prvi nivo foldera (podfolderi se ne diraju), fajlovi koji
//     se još pišu (preuzimanje u toku) čekaju, a fajl koji smo upravo
//     premjestili ne vraćamo nazad (nema ping-ponga između dva foldera);
//   • AI je isključen dok ga korisnik ne uključi u Settings ▸ Folder Rules.
//     Isključen AI znači: ništa ne ide na mrežu i ništa se ne troši — pravila
//     kojima treba AI se tada preskaču. Uključen AI ima dnevni limit, dijeli
//     mjesečni limit potrošnje sa AI Organizerom i pamti presude po fajlu, pa
//     isti fajl nikad ne plaća dvaput.

// MARK: - Model

enum FolderRuleKind: String, Codable, CaseIterable, Identifiable {
    case image, pdf, document, archive, audio, video, installer, screenshot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .image:      return "Images"
        case .pdf:        return "PDFs"
        case .document:   return "Documents"
        case .archive:    return "Archives"
        case .audio:      return "Audio"
        case .video:      return "Videos"
        case .installer:  return "Installers"
        case .screenshot: return "Screenshots"
        }
    }

    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "odt", "rtf", "txt", "md", "xls", "xlsx", "numbers",
        "ods", "csv", "ppt", "pptx", "key", "odp", "epub",
    ]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "tbz", "txz"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
}

struct FolderRuleCondition: Codable, Equatable, Identifiable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case kind, ext, nameContains, contentContains, docType, issuer, olderThanDays, largerThanMB, ai
        var id: String { rawValue }
        var label: String {
            switch self {
            case .kind:            return "Kind is"
            case .ext:             return "Extension is"
            case .nameContains:    return "Name contains"
            case .contentContains: return "Text inside contains"
            case .docType:         return "Document type is"
            case .issuer:          return "From (issuer)"
            case .olderThanDays:   return "Older than (days)"
            case .largerThanMB:    return "Larger than (MB)"
            case .ai:              return "AI thinks it is"
            }
        }
    }

    var id: String = UUID().uuidString
    var field: Field
    /// Kind raw value / "pdf,docx" / tekst / broj dana / MB / opis za AI.
    var value: String
    /// „osim …" — uslov je ispunjen kad NE važi.
    var negated: Bool = false

    var summary: String {
        let v = value.trimmingCharacters(in: .whitespaces)
        let body: String
        switch field {
        case .kind:            body = FolderRuleKind(rawValue: v)?.label ?? v
        case .ext:             body = v.split(separator: ",").map { "." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        case .nameContains:    body = "name contains “\(v)”"
        case .contentContains: body = "text contains “\(v)”"
        case .docType:         body = FolderRuleDocType.label(v)
        case .issuer:          body = "from “\(v)”"
        case .olderThanDays:   body = "older than \(v) days"
        case .largerThanMB:    body = "larger than \(v) MB"
        case .ai:              body = "AI: “\(v)”"
        }
        return negated ? "not " + body : body
    }
}

enum FolderRuleDocType {
    /// Tipovi koje lokalno prepoznaje MailClassifier.detectType (bez AI-ja).
    static let all = ["invoice", "proforma", "receipt", "statement", "contract", "annex", "offer", "cv", "nda"]
    static func label(_ raw: String) -> String {
        switch raw.lowercased() {
        case "invoice":   return "invoices"
        case "proforma":  return "proforma invoices"
        case "receipt":   return "receipts"
        case "statement": return "statements"
        case "contract":  return "contracts"
        case "annex":     return "annexes"
        case "offer":     return "offers"
        case "cv":        return "CVs"
        case "nda":       return "NDAs"
        default:          return raw
        }
    }
}

struct FolderRuleAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case move, trash, tag
        var id: String { rawValue }
        var label: String {
            switch self {
            case .move:  return "Move to folder"
            case .trash: return "Move to Trash"
            case .tag:   return "Add tag"
            }
        }
    }
    var kind: Kind
    /// Odredište (apsolutno, `~/…` ili relativno na praćeni folder) ili ime taga.
    var value: String = ""
}

struct FolderRule: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var enabled: Bool = true
    /// Originalni tekst korisnika (prikazuje se i može se ponovo parsirati).
    var source: String = ""
    var conditions: [FolderRuleCondition]
    var action: FolderRuleAction

    var needsAI: Bool { conditions.contains { $0.field == .ai } }

    func summary(base: URL) -> String {
        let what = conditions.isEmpty ? "Every file" : conditions.map(\.summary).joined(separator: " + ")
        switch action.kind {
        case .move:
            let dest = FolderRuleDestination.resolve(action.value, base: base)
                .map { FolderRuleDestination.display($0, base: base) } ?? action.value
            return "\(what) → \(dest)"
        case .trash: return "\(what) → Trash"
        case .tag:   return "\(what) → tag “\(action.value)”"
        }
    }
}

struct WatchedFolder: Codable, Equatable, Identifiable {
    var path: String
    var enabled: Bool = true
    var rules: [FolderRule] = []
    /// Automatski se sređuju samo fajlovi dodati posle ovog trenutka.
    var since: Date = Date()

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }
}

struct FolderRuleActivity: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var date: Date
    var folder: String
    var fileName: String
    var from: String
    /// Novo mjesto (premješteno ili u Trash); nil za tag.
    var to: String?
    var kind: FolderRuleAction.Kind
    var tag: String?
    var ruleSummary: String
    var undone: Bool = false
}

// MARK: - Settings

enum FolderRulesSettings {
    static let enabledKey       = "ffFolderRulesEnabled"
    static let useAIKey         = "ffFolderRulesUseAI"
    static let aiDailyLimitKey  = "ffFolderRulesAIDailyLimit"
    static let aiSendExcerptKey = "ffFolderRulesAISendExcerpt"
    static let aiUsageKey       = "ffFolderRulesAIUsage"
    static let defaultDailyLimit = 30

    /// Glavni prekidač: false = nijedan folder se ne prati (pravila ostaju).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// AI je isključen dok ga korisnik ne uključi.
    static var useAI: Bool { UserDefaults.standard.bool(forKey: useAIKey) }
    static var aiDailyLimit: Int {
        let v = UserDefaults.standard.integer(forKey: aiDailyLimitKey)
        return v > 0 ? v : defaultDailyLimit
    }
    /// Uz ime fajla šalje i kratak lokalni izvod teksta (default: samo ime).
    static var aiSendExcerpt: Bool { UserDefaults.standard.bool(forKey: aiSendExcerptKey) }

    private static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func aiUsedToday() -> Int {
        (UserDefaults.standard.dictionary(forKey: aiUsageKey) as? [String: Int])?[dayKey()] ?? 0
    }

    static func recordAIUse() {
        var d = (UserDefaults.standard.dictionary(forKey: aiUsageKey) as? [String: Int]) ?? [:]
        let today = dayKey()
        d = d.filter { $0.key >= dayKey(Date().addingTimeInterval(-30 * 86_400)) }
        d[today, default: 0] += 1
        UserDefaults.standard.set(d, forKey: aiUsageKey)
    }

    /// Da li AI smije da se koristi baš sad — i zašto ne, ako ne smije.
    static func aiBlockReason() -> String? {
        guard useAI else { return "AI is off in Settings ▸ Folder Rules" }
        guard !AIService.keysProvider().isEmpty else { return "No OpenRouter key (Settings ▸ AI Organizer)" }
        guard aiUsedToday() < aiDailyLimit else { return "Today's AI limit (\(aiDailyLimit)) is used up" }
        return nil
    }
}

// MARK: - Destination

enum FolderRuleDestination {
    /// Lokalizovana imena standardnih foldera → pravo ime u home-u.
    private static let homeFolders: [String: String] = [
        "desktop": "Desktop", "radna površina": "Desktop", "radna povrsina": "Desktop",
        "documents": "Documents", "dokumenti": "Documents", "dokumente": "Documents",
        "downloads": "Downloads", "preuzimanja": "Downloads", "preuzeto": "Downloads",
        "pictures": "Pictures", "slike": "Pictures",
        "movies": "Movies", "filmovi": "Movies", "videi": "Movies",
        "music": "Music", "muzika": "Music", "glazba": "Music",
    ]

    /// `/abs`, `~/x`, „Documents/Računi" (home) ili „Screenshots" (unutar
    /// praćenog foldera).
    static func resolve(_ raw: String, base: URL) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„«».,:;"))
        for arrow in [" → ", "→", " -> ", "->", " > "] { s = s.replacingOccurrences(of: arrow, with: "/") }
        s = s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "/")
        guard !s.isEmpty else { return nil }
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
            return URL(fileURLWithPath: "/" + s, isDirectory: true).standardizedFileURL
        }
        if s.hasPrefix("~") {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let parts = s.split(separator: "/").map(String.init)
        if let first = parts.first, let real = homeFolders[first.lowercased()] {
            var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(real, isDirectory: true)
            for p in parts.dropFirst() { url.appendPathComponent(p, isDirectory: true) }
            return url.standardizedFileURL
        }
        var url = base
        for p in parts { url.appendPathComponent(p, isDirectory: true) }
        return url.standardizedFileURL
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Po godinama / mjesecima

    private static let yearTokens = ["{year}", "{godina}"]
    private static let monthTokens = ["{month}", "{mjesec}", "{mesec}"]

    /// „… stavi u Računi po godinama" → „Računi/{year}"; „po mjesecima" →
    /// „Računi/{year}/{month}". Fraza se skida iz odredišta ako je tamo.
    static func grouped(_ dest: String, source lower: String) -> String {
        let hasToken = (yearTokens + monthTokens).contains { dest.lowercased().contains($0) }
        let monthly = ["po mjesec", "po mesec", "by month", "per month"]
        let yearly = ["po godin", "by year", "per year"]
        let wantsMonth = monthly.contains { lower.contains($0) }
        let wantsYear = wantsMonth || yearly.contains { lower.contains($0) }
        guard wantsYear, !hasToken else { return dest }
        var d = dest
        for phrase in monthly + yearly {
            if let r = d.range(of: phrase, options: .caseInsensitive) {
                // Odreži frazu do kraja riječi („po godinama" cijelo).
                let end = d[r.upperBound...].firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? d.endIndex
                d.removeSubrange(r.lowerBound..<end)
            }
        }
        d = d.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/,")))
        guard !d.isEmpty else { return dest }
        return d + (wantsMonth ? "/{year}/{month}" : "/{year}")
    }

    /// Zamjenjuje {year}/{month} datumom dokumenta (iz teksta), a kad ga
    /// nema — datumom kad je fajl stigao u folder.
    static func expand(_ raw: String, file: FolderRuleFile) -> String {
        let lower = raw.lowercased()
        guard (yearTokens + monthTokens).contains(where: { lower.contains($0) }) else { return raw }
        let fallbackDate = file.added == .distantPast ? file.modified : file.added
        let cal = Calendar.current
        let ym = file.documentDate
            ?? (cal.component(.year, from: fallbackDate), cal.component(.month, from: fallbackDate))
        var out = raw
        for t in yearTokens { out = out.replacingOccurrences(of: t, with: String(ym.year), options: .caseInsensitive) }
        for t in monthTokens {
            out = out.replacingOccurrences(of: t, with: String(format: "%02d", ym.month), options: .caseInsensitive)
        }
        return out
    }

    /// Kao `display`, ali odredište unutar praćenog foldera piše se kratko
    /// („Downloads/Screenshots") umjesto pune putanje.
    static func display(_ url: URL, base: URL) -> String {
        let p = url.standardizedFileURL.path
        let b = base.standardizedFileURL.path
        if p.hasPrefix(b + "/") { return base.lastPathComponent + "/" + p.dropFirst(b.count + 1) }
        return display(url)
    }
}

// MARK: - Plain-language parser (offline)

enum FolderRuleParser {
    /// Pravilo iz običnog teksta (bosanski/hrvatski/srpski/engleski), ili nil
    /// kad nije jasno šta se traži — tada pozivalac može pitati AI.
    static func parse(_ text: String) -> FolderRule? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let lower = source.lowercased()
        var conditions: [FolderRuleCondition] = []

        // Akcija + ostatak teksta (uslovi su u dijelu prije markera).
        guard let (parsedAction, head) = action(in: source) else { return nil }
        var action = parsedAction
        if action.kind == .move {
            action.value = FolderRuleDestination.grouped(action.value, source: lower)
        }
        let headLower = head.lowercased()

        // Vrste fajlova.
        let kindWords: [(FolderRuleKind, [String])] = [
            (.screenshot, ["screenshot", "screen shot", "snimak ekrana", "snimke ekrana", "snimci ekrana",
                           "snimka zaslona", "snimke zaslona"]),
            (.installer, ["instalacij", "installer", "instaler"]),
            (.archive, ["arhiv", "archive", "zip"]),
            (.image, ["slik", "fotografij", "fotk", "image", "photo", "picture"]),
            (.video, ["video", "film", "movie", "snimke kamere"]),
            (.audio, ["muzik", "pjesm", "pesm", "audio", "song", "glazb", "podcast"]),
            (.pdf, ["pdf"]),
            (.document, ["dokument", "document", "word", "excel"]),
        ]
        var foundKinds: [FolderRuleKind] = []
        for (kind, words) in kindWords where words.contains(where: { headLower.contains($0) }) {
            // „screenshot" je i slika — ne dodaj oba.
            if kind == .image, foundKinds.contains(.screenshot) { continue }
            // „.zip" je ekstenzija; ne dupliraj arhive ako je navedena eksplicitno.
            foundKinds.append(kind)
        }

        // Ekstenzije: „.heic", „docx", „dmg".
        let known = FolderRuleKind.documentExtensions
            .union(FolderRuleKind.archiveExtensions)
            .union(FolderRuleKind.installerExtensions)
            .union(["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "svg", "mp3", "m4a", "wav",
                    "flac", "aac", "mov", "mp4", "m4v", "avi", "mkv", "psd", "ai", "sketch", "fig"])
        var exts: [String] = []
        for token in tokens(headLower) {
            let t = token.hasPrefix(".") ? String(token.dropFirst()) : token
            guard known.contains(t), !exts.contains(t) else { continue }
            // „pdf" i „zip" su već pokriveni vrstom.
            if (t == "pdf" && foundKinds.contains(.pdf)) || (t == "zip" && foundKinds.contains(.archive)) { continue }
            exts.append(t)
        }

        // Tipovi dokumenata (lokalno prepoznavanje, bez AI-ja).
        let docWords: [(String, [String])] = [
            ("proforma", ["predračun", "predracun", "proform", "profaktur"]),
            ("invoice", ["račun", "racun", "faktur", "invoice", "bill"]),
            ("contract", ["ugovor", "contract", "agreement"]),
            ("receipt", ["priznanic", "receipt", "potvrd"]),
            ("statement", ["izvod", "statement"]),
            ("offer", ["ponud", "offer", "proposal"]),
            ("cv", [" cv", "cv ", "biografij", "resume"]),
            ("nda", ["nda"]),
        ]
        var docTypes: [String] = []
        for (type, words) in docWords where words.contains(where: { (" " + headLower + " ").contains($0) }) {
            if type == "invoice", docTypes.contains("proforma") { continue }
            docTypes.append(type)
        }

        // Izdavalac: „račune od Telekoma", „invoices from „BH Telecom"".
        let issuer = issuer(in: head)
        if let issuer {
            conditions.append(FolderRuleCondition(field: .issuer, value: issuer))
        }

        // Tekst pod navodnicima: „ime sadrži" ili „tekst sadrži".
        for quoted in quotedStrings(in: head) {
            let q = quoted.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, q != issuer else { continue }
            if headLower.contains("sadrž") || headLower.contains("sadrz") || headLower.contains("unutra")
                || headLower.contains("text") || headLower.contains("tekst") || headLower.contains("content") {
                conditions.append(FolderRuleCondition(field: .contentContains, value: q))
            } else {
                conditions.append(FolderRuleCondition(field: .nameContains, value: q))
            }
        }

        // Starost: „starije od 7 dana", „older than 2 weeks".
        if let days = age(in: lower) {
            conditions.append(FolderRuleCondition(field: .olderThanDays, value: String(days)))
        }
        // Veličina: „veće od 100 MB", „larger than 1 GB".
        if let mb = size(in: lower) {
            conditions.append(FolderRuleCondition(field: .largerThanMB, value: String(mb)))
        }

        // Vrste → jedan uslov po vrsti (više vrsta: pravilo ih spaja kao „bilo
        // koja od" preko ext liste nije moguće, pa uzimamo prvu + ekstenzije).
        if let kind = foundKinds.first, docTypes.isEmpty || kind != .document {
            // „PDF račune" → docType invoice je dovoljno specifičan; PDF ostaje kao vrsta.
            conditions.insert(FolderRuleCondition(field: .kind, value: kind.rawValue), at: 0)
        }
        if !exts.isEmpty {
            conditions.append(FolderRuleCondition(field: .ext, value: exts.joined(separator: ",")))
        }
        if let type = docTypes.first {
            conditions.append(FolderRuleCondition(field: .docType, value: type))
        }

        // Pravilo bez ijednog uslova važi samo uz eksplicitno „sve / all".
        if conditions.isEmpty {
            let everything = ["sve ", "svi ", "svaki", "all ", "every", "everything"]
            guard everything.contains(where: { (headLower + " ").contains($0) }) else { return nil }
        }
        return FolderRule(source: source, conditions: conditions, action: action)
    }

    /// Nalazi akciju („stavi u X", „obriši", „označi crvenom") i vraća tekst
    /// PRIJE markera (u njemu su uslovi).
    private static func action(in text: String) -> (FolderRuleAction, String)? {
        // Svi rasponi se traže u ORIGINALNOM tekstu (case-insensitive), pa se
        // indeksi nikad ne miješaju između `text` i `text.lowercased()`.
        func find(_ needle: String, in s: String) -> Range<String.Index>? {
            s.range(of: needle, options: .caseInsensitive)
        }
        let trashWords = ["baci u smeće", "baci u smece", "u smeće", "u smece", "u kantu", "u koš",
                          "u trash", "to trash", "move to trash", "obriši", "obrisi", "izbriši", "izbrisi",
                          "delete", "trash"]
        for w in trashWords {
            if let r = find(w, in: text) {
                return (FolderRuleAction(kind: .trash), String(text[..<r.lowerBound]))
            }
        }
        let tagMarkers = ["označi ", "oznaci ", "tagiraj ", "tag ", "label "]
        for m in tagMarkers {
            guard let r = find(m, in: text) else { continue }
            let tail = String(text[r.upperBound...])
            let colors: [(String, [String])] = [
                ("Red", ["crven", "red"]), ("Orange", ["narandž", "narandz", "orange"]),
                ("Yellow", ["žut", "zut", "yellow"]), ("Green", ["zelen", "green"]),
                ("Blue", ["plav", "blue"]), ("Purple", ["ljubičast", "ljubicast", "purple"]),
                ("Gray", ["siv", "gray", "grey"]),
            ]
            if let color = colors.first(where: { c in c.1.contains { find($0, in: tail) != nil } }) {
                // Uslovi mogu biti i iza markera („označi PDF-ove crvenom").
                return (FolderRuleAction(kind: .tag, value: color.0), String(text[..<r.lowerBound]) + " " + tail)
            }
            if let q = quotedStrings(in: tail).first {
                return (FolderRuleAction(kind: .tag, value: q), String(text[..<r.lowerBound]))
            }
        }
        let moveMarkers = ["premjesti u", "premesti u", "premjesti na", "prebaci u", "prebaci na", "pomjeri u",
                           "pomeri u", "stavi u", "stavi na", "spremi u", "sačuvaj u", "sacuvaj u",
                           "arhiviraj u", "move to", "move into", "put in", "put into", "file into",
                           "sort into", " → ", " -> ", "→", "->"]
        // Najraniji marker pobjeđuje.
        var best: Range<String.Index>?
        for m in moveMarkers {
            if let r = find(m, in: text), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        if best == nil, let (verbRange, destStart) = verbFirst(in: text) {
            // „premjesti screenshotove u Screenshots" / „Move images to X":
            // glagol, pa uslovi, pa odredište.
            var dest = String(text[destStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            dest = dest.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'“”„"))
            guard !dest.isEmpty else { return nil }
            let middle = String(text[verbRange.upperBound..<destStart])
            return (FolderRuleAction(kind: .move, value: dest), String(text[..<verbRange.lowerBound]) + " " + middle)
        }
        guard let r = best else { return nil }
        var dest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // „… stavi u Arhiva ako su starije od 30 dana" — uslov iza odredišta.
        var trailing = ""
        for cut in [" ako ", " kad ", " kada ", " if ", " when ", " osim ", ", "] {
            if let cr = find(cut, in: dest) {
                trailing = String(dest[cr.lowerBound...])
                dest = String(dest[..<cr.lowerBound])
                break
            }
        }
        dest = dest.trimmingCharacters(in: CharacterSet(charactersIn: " .\"'“”„"))
        guard !dest.isEmpty else { return nil }
        return (FolderRuleAction(kind: .move, value: dest), String(text[..<r.lowerBound]) + " " + trailing)
    }

    /// „premjesti/prebaci/stavi … u X", „move/put/file … to/into X": raspon
    /// glagola i početak odredišta.
    private static func verbFirst(in text: String) -> (Range<String.Index>, String.Index)? {
        let pattern = #"(?i)\b(premjesti|premesti|prebaci|pomjeri|pomeri|stavi|spremi|sačuvaj|sacuvaj|arhiviraj|move|put|file|send|sort)\b(.*?)\s(u|na|to|into|in)\s+(\S.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let verb = Range(m.range(at: 1), in: text),
              let dest = Range(m.range(at: 4), in: text) else { return nil }
        return (verb, dest.lowerBound)
    }

    /// „od Telekoma", „from BH Telecom", „od „Elektroprivreda BiH"" → ime
    /// izdavaoca. Bez navodnika ime mora počinjati velikim slovom, da se
    /// „starije od 7 dana" ili „od prošle sedmice" ne pročitaju kao firma.
    static func issuer(in head: String) -> String? {
        let pattern = #"(?:^|\s)(?:od|from|izdavač\w*|izdavaoc\w*|issued by)\s+(?:[„“"«]([^“”"»]+)[“”"»]|(\p{Lu}[\p{L}\p{N}&.\-]*(?:\s+(?:\p{Lu}|\d)[\p{L}\p{N}&.\-]*)*))"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) else { return nil }
        for i in 1...2 {
            if let r = Range(m.range(at: i), in: head) {
                let v = head[r].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;:")))
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    private static func age(in lower: String) -> Int? {
        let pattern = #"(?:starij\w*|stariji|older)\s+(?:od|than)\s+(\d+)\s*(dan\w*|day\w*|sedmic\w*|tjed\w*|nedelj\w*|week\w*|mjesec\w*|mesec\w*|month\w*)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let nr = Range(m.range(at: 1), in: lower), let n = Int(lower[nr]),
              let ur = Range(m.range(at: 2), in: lower) else { return nil }
        let unit = String(lower[ur])
        if unit.hasPrefix("sedmic") || unit.hasPrefix("tjed") || unit.hasPrefix("nedelj") || unit.hasPrefix("week") { return n * 7 }
        if unit.hasPrefix("mjesec") || unit.hasPrefix("mesec") || unit.hasPrefix("month") { return n * 30 }
        return n
    }

    private static func size(in lower: String) -> Int? {
        let pattern = #"(?:već\w*|vec\w*|larger|bigger|over|preko)\s+(?:od|than)?\s*(\d+(?:[.,]\d+)?)\s*(kb|mb|gb)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let nr = Range(m.range(at: 1), in: lower),
              let n = Double(lower[nr].replacingOccurrences(of: ",", with: ".")),
              let ur = Range(m.range(at: 2), in: lower) else { return nil }
        switch lower[ur] {
        case "gb": return Int(n * 1024)
        case "kb": return max(1, Int(n / 1024))
        default:   return Int(n)
        }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || ",;()".contains($0) }).map(String.init)
    }

    static func quotedStrings(in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #""([^"]+)"|“([^”]+)”|„([^“”]+)[“”]|'([^']+)'"#) else { return [] }
        var out: [String] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            for i in 1...4 where m.range(at: i).location != NSNotFound {
                if let r = Range(m.range(at: i), in: s) { out.append(String(s[r])) }
            }
        }
        return out
    }

    // MARK: AI fallback (samo tekst pravila — nikad sadržaj fajlova)

    static func aiSystemPrompt() -> String {
        """
        You turn a file-sorting rule written in plain language (Bosnian, Croatian, Serbian or English) into JSON for a Mac file manager.
        Reply with ONLY one JSON object, no commentary:
        {"conditions":[{"field":"kind|ext|nameContains|contentContains|docType|issuer|olderThanDays|largerThanMB|ai","value":"...","negated":false}],"action":{"kind":"move|trash|tag","value":"..."}}
        issuer: the company or person that issued the document (e.g. "invoices from Telekom" → issuer "Telekom"), in its base form.
        A destination may end with {year} or {year}/{month} when the user asks to sort by year or month.
        kind values: image, pdf, document, archive, audio, video, installer, screenshot.
        ext: comma-separated extensions without dots. docType values: invoice, proforma, receipt, statement, contract, annex, offer, cv, nda.
        olderThanDays / largerThanMB: whole numbers. Use "ai" only for meaning no other field can express, with a short English description as value.
        action move: value is the destination folder exactly as the user wrote it. tag: a color name (Red, Orange, Yellow, Green, Blue, Purple, Gray) or a word.
        Never invent conditions the rule does not state. If the text is not a file-sorting rule, reply {"conditions":[],"action":{"kind":"none","value":""}}.
        """
    }

    static func decodeAI(_ reply: String, source: String) -> FolderRule? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else { return nil }
        let json = String(reply[start...end])
        struct Wire: Decodable {
            struct C: Decodable { var field: String; var value: String?; var negated: Bool? }
            struct A: Decodable { var kind: String; var value: String? }
            var conditions: [C]?
            var action: A?
        }
        guard let data = json.data(using: .utf8), let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let a = wire.action, let kind = FolderRuleAction.Kind(rawValue: a.kind) else { return nil }
        var conditions: [FolderRuleCondition] = []
        for c in wire.conditions ?? [] {
            guard let f = FolderRuleCondition.Field(rawValue: c.field) else { continue }
            let v = (c.value ?? "").trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            conditions.append(FolderRuleCondition(field: f, value: v, negated: c.negated ?? false))
        }
        let value = (a.value ?? "").trimmingCharacters(in: .whitespaces)
        if kind == .move, value.isEmpty { return nil }
        if conditions.isEmpty { return nil }
        return FolderRule(source: source, conditions: conditions, action: FolderRuleAction(kind: kind, value: value))
    }
}

// MARK: - File under evaluation

/// Jedan fajl u praćenom folderu, sa lijenim (i keširanim) sadržajem.
final class FolderRuleFile {
    let url: URL
    let name: String
    let ext: String
    let size: Int64
    let added: Date
    let modified: Date

    init(url: URL, size: Int64, added: Date, modified: Date) {
        self.url = url
        self.name = url.lastPathComponent
        self.ext = url.pathExtension.lowercased()
        self.size = size
        self.added = added
        self.modified = modified
    }

    /// Identitet za keš presuda: putanja + veličina + vrijeme izmjene.
    var identity: String { "\(url.path)|\(size)|\(Int(modified.timeIntervalSince1970))" }

    var type: UTType? { UTType(filenameExtension: ext) }

    /// Slike veće od ovoga se ne OCR-uju (fotografije računa su daleko manje).
    static let maxOCRImageBytes: Int64 = 15 * 1024 * 1024

    private var loadedText: String?
    /// Lokalni tekst (PDF tekstualni sloj, OCR skeniranih strana i slika, ili
    /// početak tekstualnog fajla) — čita se samo kad ga neko pravilo traži.
    /// OCR je Vision na uređaju: ništa ne ide na mrežu.
    var text: String {
        if let loadedText { return loadedText }
        var result = ""
        if ext == "pdf" {
            // Tekstualni PDF ide bez OCR-a; skenirane strane (prve dvije)
            // čita Vision — dovoljno za zaglavlje računa ili ugovora.
            var opts = PDFInspectorOptions.default
            opts.ocrMissingPages = true
            opts.ocrMaxPages = 2
            opts.maxFileBytes = 40 * 1024 * 1024
            result = PDFInspector.processPDF(url: url, options: opts)?.excerpt(maxChars: 6000) ?? ""
        } else if let t = type, t.conforms(to: .image), !["svg", "gif", "ico", "icns"].contains(ext),
                  size > 0, size < Self.maxOCRImageBytes, !isScreenshot,
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2400,
                  ] as CFDictionary) {
            // Fotografija računa / skenirani dokument kao slika.
            result = String(PDFInspector.recognizeText(in: image).prefix(6000))
        } else if let t = type, t.conforms(to: .text) || ["md", "csv", "json", "txt"].contains(ext),
                  size < 5 * 1024 * 1024,
                  let h = try? FileHandle(forReadingFrom: url) {
            let data = (try? h.read(upToCount: 16_384)) ?? Data()
            try? h.close()
            result = String(decoding: data, as: UTF8.self)
        }
        loadedText = result
        return result
    }

    /// Da li dokument pominje `name` (izdavaoca) — bez obzira na velika
    /// slova i kvačice, i sa padežom („Telekoma" nalazi „Telekom").
    func mentions(_ name: String) -> Bool {
        let needle = Self.fold(name)
        guard !needle.isEmpty else { return false }
        let hay = Self.fold(self.name) + " " + Self.fold(text)
        if hay.contains(needle) { return true }
        // Padežni nastavak na zadnjoj riječi: Telekoma/Telekomu → telekom.
        for suffix in ["om", "a", "e", "u", "i"] where needle.count > suffix.count + 3 && needle.hasSuffix(suffix) {
            if hay.contains(String(needle.dropLast(suffix.count))) { return true }
        }
        return false
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var loadedDocumentDate: (year: Int, month: Int)??
    /// Datum dokumenta (datum računa/izdavanja) iz teksta, ako ga ima.
    var documentDate: (year: Int, month: Int)? {
        if let loadedDocumentDate { return loadedDocumentDate }
        var found: (Int, Int)?
        let labels = ["datum računa", "datum racuna", "datum izdavanja", "datum dokumenta", "invoice date",
                      "date of issue", "issue date", "issued", "datum", "date"]
        if let d = MailClassifier.findDate(labeled: labels, in: text) {
            let parts = d.split(separator: "-").compactMap { Int($0) }
            let thisYear = Calendar.current.component(.year, from: Date())
            if parts.count == 3, (1990...thisYear + 1).contains(parts[0]), (1...12).contains(parts[1]) {
                found = (parts[0], parts[1])
            }
        }
        loadedDocumentDate = .some(found)
        return found
    }

    private var loadedDocType: String?
    var docType: String {
        if let loadedDocType { return loadedDocType }
        var t = MailClassifier.detectType(subject: "", body: "", filenames: name, text: text)
        if t == "other" || t == "correspondence" {
            // „scan001.pdf" koji u zaglavlju piše „RAČUN br. …": naslov
            // dokumenta vrijedi koliko i ime fajla.
            let header = String(text.prefix(500))
            let fromHeader = MailClassifier.detectType(subject: header, body: "", filenames: name, text: text)
            if fromHeader != "correspondence" { t = fromHeader }
        }
        loadedDocType = t
        return t
    }

    func isKind(_ kind: FolderRuleKind) -> Bool {
        let t = type
        switch kind {
        case .pdf:        return ext == "pdf"
        case .image:      return t?.conforms(to: .image) ?? false
        case .audio:      return t?.conforms(to: .audio) ?? false
        case .video:      return (t?.conforms(to: .movie) ?? false) || (t?.conforms(to: .video) ?? false)
        case .archive:    return FolderRuleKind.archiveExtensions.contains(ext)
        case .installer:  return FolderRuleKind.installerExtensions.contains(ext)
        case .document:   return FolderRuleKind.documentExtensions.contains(ext)
        case .screenshot: return isScreenshot
        }
    }

    /// Spotlight zna za snimke ekrana bez obzira na jezik imena; za svjež
    /// fajl koji još nije indeksiran vrijede i uobičajena imena.
    var isScreenshot: Bool {
        guard type?.conforms(to: .image) ?? false else { return false }
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool, v {
            return true
        }
        let lower = name.lowercased()
        let prefixes = ["screenshot", "screen shot", "snimka zaslona", "snimak ekrana", "snimak zaslona",
                        "bildschirmfoto", "capture d’écran", "capture d'écran", "captura de pantalla",
                        "istantanea", "zrzut ekranu", "snímek obrazovky", "cleanshot"]
        return prefixes.contains { lower.hasPrefix($0) }
    }
}

// MARK: - AI gate (limit, keš presuda, bez mreže kad je isključeno)

final class FolderRuleAIGate {
    let blockReason: String?
    let sendExcerpt: Bool
    private var remaining: Int
    private(set) var skipped = 0
    private(set) var used = 0

    init() {
        blockReason = FolderRulesSettings.aiBlockReason()
        sendExcerpt = FolderRulesSettings.aiSendExcerpt
        remaining = max(0, FolderRulesSettings.aiDailyLimit - FolderRulesSettings.aiUsedToday())
    }

    var isOpen: Bool { blockReason == nil }

    /// true/false = presuda; nil = AI nije dostupan (pravilo se preskače).
    func check(description: String, file: FolderRuleFile) -> Bool? {
        let key = file.identity + "|" + description.lowercased()
        if let cached = FolderRuleAICache.shared.verdict(for: key) { return cached }
        guard isOpen, remaining > 0 else { skipped += 1; return nil }
        remaining -= 1
        used += 1
        let excerpt = sendExcerpt ? String(file.text.prefix(1500)) : ""
        var user = "File name: \(file.name)\nKind: \(file.type?.localizedDescription ?? file.ext)\nSize: \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))"
        if !excerpt.isEmpty { user += "\nText excerpt: \(excerpt)" }
        user += "\n\nQuestion: is this file \(description)? Reply with only the JSON {\"match\": true} or {\"match\": false}."
        guard let reply = try? FolderRulesAI.complete(
            system: "You classify files for a Mac file manager. Be strict: answer true only when the file clearly fits.",
            user: user, maxTokens: 20) else { return nil }
        let verdict = reply.lowercased().contains("true")
        FolderRuleAICache.shared.store(verdict, for: key)
        return verdict
    }
}

/// Presude AI-ja po fajlu, trajno — isti fajl se ne plaća dvaput.
final class FolderRuleAICache {
    static let shared = FolderRuleAICache()
    private let lock = NSLock()
    private var map: [String: Bool] = [:]
    private var loaded = false

    private var fileURL: URL { FolderRulesStorage.directory.appendingPathComponent("ai-verdicts.json") }

    func verdict(for key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return map[key]
    }

    func store(_ verdict: Bool, for key: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        map[key] = verdict
        if map.count > 4000 { map = Dictionary(uniqueKeysWithValues: map.suffix(3000).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) { map = decoded }
    }
}

// MARK: - AI transport (OpenRouter, isti ključevi i mjesečni limit kao AI Organizer)

enum FolderRulesAI {
    enum Failure: LocalizedError {
        case blocked(String), http(Int), badReply
        var errorDescription: String? {
            switch self {
            case .blocked(let why): return why
            case .http(let s):      return "OpenRouter answered HTTP \(s)"
            case .badReply:         return "The model gave no usable answer"
            }
        }
    }

    /// Testovi podmeću URLSession sa URLProtocol mock-om — pravi ključ i
    /// mreža se u testovima nikad ne diraju.
    static var session: URLSession = .shared

    /// Jedan sinhroni poziv (samo van glavne niti). Poštuje prekidač, dnevni
    /// limit i mjesečni limit AI Organizera; svaki poziv se broji.
    static func complete(system: String, user: String, maxTokens: Int) throws -> String {
        if let why = FolderRulesSettings.aiBlockReason() { throw Failure.blocked(why) }
        let (model, spent, cap) = onMain {
            (AIService.shared.extractionModelID, AIService.shared.monthSpend(), AIService.shared.monthlyCapUSD)
        }
        if cap > 0, spent >= cap { throw Failure.blocked("This month's AI spend cap is reached") }
        let keys = AIService.keysProvider()
        var lastError: Error = Failure.blocked("No OpenRouter key")
        for key in keys {
            var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("aiFlow", forHTTPHeaderField: "X-Title")
            req.timeoutInterval = 60
            let body: [String: Any] = [
                "model": model,
                "temperature": 0,
                "max_tokens": maxTokens,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "usage": ["include": true],
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            FolderRulesSettings.recordAIUse()
            let (data, status) = syncData(req)
            let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            if [401, 402, 429].contains(status) { lastError = Failure.http(status); continue }
            guard (200...299).contains(status), json?["error"] == nil else {
                lastError = Failure.http(status == 0 ? -1 : status)
                continue
            }
            if let usage = json?["usage"] as? [String: Any] {
                let pt = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
                let ct = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
                let charged = (usage["cost"] as? NSNumber)?.doubleValue
                DispatchQueue.main.async {
                    let ai = AIService.shared
                    ai.recordSpend(charged ?? ai.costUSD(promptTokens: pt, completionTokens: ct, model: model))
                }
            }
            let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            let content = (message?["content"] as? String) ?? ""
            guard !content.isEmpty else { throw Failure.badReply }
            return content
        }
        throw lastError
    }

    private static func syncData(_ req: URLRequest) -> (Data?, Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, Int) = (nil, 0)
        session.dataTask(with: req) { data, response, _ in
            out = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 70)
        return out
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}

// MARK: - Storage

enum FolderRulesStorage {
    /// Dnevnik i AI keš. Testovi postavljaju FF_FOLDER_RULES_DIR.
    static var directory: URL {
        let url: URL
        if let custom = ProcessInfo.processInfo.environment["FF_FOLDER_RULES_DIR"], !custom.isEmpty {
            url = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FinderFlow/FolderRules", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Engine (čisti dio: kandidati → plan → primjena)

struct FolderRulePlanItem: Identifiable, Equatable {
    var id: String { file.path }
    var file: URL
    var ruleID: String
    var ruleSummary: String
    var action: FolderRuleAction.Kind
    var destination: URL?
    var tag: String?
}

enum FolderRulesEngine {
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp",
                                                 "opdownload", "downloading", "!ut", "aria2"]
    /// Fajl mlađi od ovoga se možda još piše — čeka sljedeći prolaz.
    static let settleSeconds: TimeInterval = 4

    /// Fajlovi prvog nivoa koji dolaze u obzir, i kad treba ponovo pogledati
    /// (ako je neki fajl još „svjež").
    static func candidates(in folder: WatchedFolder, includeExisting: Bool,
                           skip: (URL) -> Bool = { _ in false }) -> (files: [FolderRuleFile], retryAfter: TimeInterval?) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .fileSizeKey,
                                      .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return ([], nil) }
        var out: [FolderRuleFile] = []
        var retry: TimeInterval?
        let now = Date()
        for url in items {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isHidden != true else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("~$") || name.hasPrefix(".") { continue }
            if partialExtensions.contains(url.pathExtension.lowercased()) { continue }
            if skip(url) { continue }
            let added = v.addedToDirectoryDate ?? v.creationDate ?? .distantPast
            let modified = v.contentModificationDate ?? added
            if !includeExisting, added < folder.since { continue }
            // „Još se piše" gleda samo vrijeme izmjene: fajl koji je upravo
            // premješten/kopiran u folder, a star je, gotov je i ne čeka.
            let age = now.timeIntervalSince(modified)
            if age < settleSeconds {
                retry = min(retry ?? .infinity, settleSeconds - age + 0.5)
                continue
            }
            out.append(FolderRuleFile(url: url, size: Int64(v.fileSize ?? 0), added: added, modified: modified))
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (out, retry)
    }

    static func matches(_ rule: FolderRule, _ file: FolderRuleFile, ai: FolderRuleAIGate?) -> Bool? {
        // Pravilo bez uslova („sve stavi u …") važi za svaki fajl.
        guard rule.enabled else { return false }
        // Lokalni uslovi prvo — AI se pita tek kad sve ostalo prođe.
        let ordered = rule.conditions.sorted { ($0.field == .ai ? 1 : 0) < ($1.field == .ai ? 1 : 0) }
        for c in ordered {
            let hit: Bool
            let v = c.value.trimmingCharacters(in: .whitespaces)
            switch c.field {
            case .kind:
                hit = FolderRuleKind(rawValue: v).map { file.isKind($0) } ?? false
            case .ext:
                let list = v.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ."))}
                hit = list.contains(file.ext)
            case .nameContains:
                hit = file.name.localizedCaseInsensitiveContains(v)
            case .contentContains:
                hit = file.text.localizedCaseInsensitiveContains(v)
            case .docType:
                hit = file.docType.lowercased() == v.lowercased()
            case .issuer:
                hit = file.mentions(v)
            case .olderThanDays:
                guard let days = Double(v) else { return false }
                hit = Date().timeIntervalSince(file.modified) > days * 86_400
            case .largerThanMB:
                guard let mb = Double(v.replacingOccurrences(of: ",", with: ".")) else { return false }
                hit = Double(file.size) > mb * 1_048_576
            case .ai:
                guard let ai, let verdict = ai.check(description: v, file: file) else { return nil }
                hit = verdict
            }
            if c.negated ? hit : !hit { return false }
        }
        return true
    }

    /// Prvo pravilo koje odgovara (redoslijed je bitan, kao u Hazelu).
    static func plan(folder: WatchedFolder, files: [FolderRuleFile], ai: FolderRuleAIGate?) -> [FolderRulePlanItem] {
        var out: [FolderRulePlanItem] = []
        for file in files {
            for rule in folder.rules where rule.enabled {
                guard matches(rule, file, ai: ai) == true else { continue }
                var item = FolderRulePlanItem(file: file.url, ruleID: rule.id,
                                              ruleSummary: rule.summary(base: folder.url),
                                              action: rule.action.kind)
                switch rule.action.kind {
                case .move:
                    let raw = FolderRuleDestination.expand(rule.action.value, file: file)
                    guard let dir = FolderRuleDestination.resolve(raw, base: folder.url),
                          dir.standardizedFileURL.path != folder.url.standardizedFileURL.path else { continue }
                    item.destination = dir
                case .trash:
                    break
                case .tag:
                    guard !rule.action.value.isEmpty else { continue }
                    item.tag = rule.action.value
                }
                out.append(item)
                break
            }
        }
        return out
    }

    /// Izvršava plan. Vraća dnevnik uspjelih poteza i poruke za neuspjele.
    static func apply(_ plan: [FolderRulePlanItem], folder: WatchedFolder) -> ([FolderRuleActivity], [String]) {
        let fm = FileManager.default
        var done: [FolderRuleActivity] = []
        var errors: [String] = []
        for item in plan {
            guard fm.fileExists(atPath: item.file.path) else { continue }
            var entry = FolderRuleActivity(date: Date(), folder: folder.path, fileName: item.file.lastPathComponent,
                                           from: item.file.path, to: nil, kind: item.action, tag: item.tag,
                                           ruleSummary: item.ruleSummary)
            do {
                switch item.action {
                case .move:
                    guard let dir = item.destination else { continue }
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let target = uniqueDestinationURL(for: dir.appendingPathComponent(item.file.lastPathComponent))
                    try fm.moveItem(at: item.file, to: target)
                    entry.to = target.path
                case .trash:
                    var resulting: NSURL?
                    try fm.trashItem(at: item.file, resultingItemURL: &resulting)
                    entry.to = (resulting as URL?)?.path
                case .tag:
                    guard let tag = item.tag else { continue }
                    var names = (try? item.file.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                    guard !names.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
                    names.append(tag)
                    writeTags(names, to: item.file)
                }
                done.append(entry)
            } catch {
                errors.append("\(item.file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (done, errors)
    }

    /// Kao FileOperationsService.writeTags: boje kao „Name\nNumber" da macOS
    /// upiše pravi obojeni tag, a ne bezbojni custom tag.
    static func writeTags(_ names: [String], to url: URL) {
        let encoded: [String] = names.map { name in
            if let num = FileItem.colorNameToLabel[name.lowercased()] {
                return "\(FileItem.labelToColorName[num] ?? name)\n\(num)"
            }
            return name
        }
        try? (url as NSURL).setResourceValue(encoded as NSArray, forKey: .tagNamesKey)
    }

    /// Vraća jedan potez. true = uspjelo.
    static func undo(_ entry: FolderRuleActivity) -> Bool {
        let fm = FileManager.default
        switch entry.kind {
        case .move, .trash:
            guard let to = entry.to, fm.fileExists(atPath: to) else { return false }
            let back = uniqueDestinationURL(for: URL(fileURLWithPath: entry.from))
            try? fm.createDirectory(at: back.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? fm.moveItem(at: URL(fileURLWithPath: to), to: back)) != nil
        case .tag:
            let url = URL(fileURLWithPath: entry.from)
            guard let tag = entry.tag, fm.fileExists(atPath: url.path) else { return false }
            let names = ((try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? [])
                .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            writeTags(names, to: url)
            return true
        }
    }
}

// MARK: - Directory watcher

/// Javlja kad se u folderu nešto doda, preimenuje ili obriše (prvi nivo).
final class FolderDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    init?(url: URL, onEvent: @escaping (_ folderGone: Bool) -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak src] in
            let flags = src?.data ?? []
            onEvent(flags.contains(.delete) || flags.contains(.rename))
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}

// MARK: - Service

/// Praćeni folderi, pravila, dnevnik. Sve javne metode — glavna nit;
/// posao sa fajlovima ide na pozadinski red, jedan folder u jednom trenutku.
final class FolderRulesService: ObservableObject {
    static let shared = FolderRulesService()

    @Published private(set) var folders: [WatchedFolder] = []
    @Published private(set) var activity: [FolderRuleActivity] = []
    /// Folderi koji se upravo obrađuju (spinner u UI-ju).
    @Published private(set) var running: Set<String> = []
    /// Zadnja greška ili preskok po folderu (npr. „AI is off …").
    @Published private(set) var notes: [String: String] = [:]

    private let storeKey = "ffFolderRules"
    private let queue = DispatchQueue(label: "com.finderflow.folder-rules", qos: .utility)
    private var watchers: [String: FolderDirectoryWatcher] = [:]
    private var scheduled: [String: DispatchWorkItem] = [:]
    private var rescanAfterRun: Set<String> = []
    /// Fajlovi koje smo sami premjestili (putanja → vrijeme): ne diraju se
    /// ponovo 10 minuta, pa dva praćena foldera ne mogu da se dodaju loptu.
    private var recentlyMoved: [String: Date] = [:]
    private let recentLock = NSLock()
    private var started = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            folders = decoded
        }
        activity = Self.loadActivity()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshWatchers()
        for f in folders where f.enabled { scheduleScan(f.path, after: 3) }
    }

    /// Glavni prekidač iz Settings-a.
    func settingsChanged() {
        refreshWatchers()
        if FolderRulesSettings.isEnabled {
            for f in folders where f.enabled { scheduleScan(f.path, after: 1) }
        }
    }

    private func refreshWatchers() {
        let wanted = FolderRulesSettings.isEnabled
            ? Set(folders.filter { $0.enabled && !$0.rules.isEmpty }.map(\.path)) : []
        for path in watchers.keys where !wanted.contains(path) { watchers[path] = nil }
        for path in wanted where watchers[path] == nil {
            watchers[path] = FolderDirectoryWatcher(url: URL(fileURLWithPath: path)) { [weak self] gone in
                guard let self else { return }
                if gone, !FileManager.default.fileExists(atPath: path) {
                    self.watchers[path] = nil
                    self.notes[path] = "Folder was moved or deleted — not watching"
                    return
                }
                self.scheduleScan(path, after: 1.5)
            }
        }
    }

    // MARK: Queries

    func folder(for url: URL) -> WatchedFolder? {
        let p = url.standardizedFileURL.path
        return folders.first { $0.path == p }
    }

    func isWatched(_ url: URL) -> Bool { folder(for: url)?.enabled ?? false }

    /// Razlog zašto se folder ne smije pratiti, ili nil.
    static func refusal(for url: URL) -> String? {
        let p = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin",
                         home, home + "/Library", home + "/.Trash"]
        if forbidden.contains(p) || p.hasPrefix(home + "/Library/") || p.hasPrefix("/System/") {
            return "aiFlow won't auto-sort \((p as NSString).abbreviatingWithTildeInPath) — pick a normal folder such as Downloads or Desktop."
        }
        return nil
    }

    // MARK: Editing

    /// Uključi/isključi praćenje (dodaje folder ako ga nema). Vraća folder.
    @discardableResult
    func setWatched(_ url: URL, _ on: Bool) -> WatchedFolder? {
        let p = url.standardizedFileURL.path
        if let i = folders.firstIndex(where: { $0.path == p }) {
            folders[i].enabled = on
            // Ponovno uključivanje ne smije da „pojede" sve što se nakupilo
            // dok je praćenje bilo ugašeno — i dalje samo novi fajlovi.
            if on { folders[i].since = Date() }
        } else if on {
            guard Self.refusal(for: url) == nil else { return nil }
            folders.append(WatchedFolder(path: p))
        } else {
            return nil
        }
        persistFolders()
        return folder(for: url)
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0.path == path }
        persistFolders()
    }

    func updateRules(_ path: String, _ rules: [FolderRule]) {
        guard let i = folders.firstIndex(where: { $0.path == path }) else { return }
        folders[i].rules = rules
        persistFolders()
    }

    func setRule(_ path: String, _ rule: FolderRule) {
        guard let i = folders.firstIndex(where: { $0.path == path }) else { return }
        if let j = folders[i].rules.firstIndex(where: { $0.id == rule.id }) {
            folders[i].rules[j] = rule
        } else {
            folders[i].rules.append(rule)
        }
        persistFolders()
    }

    func deleteRule(_ path: String, id: String) {
        guard let i = folders.firstIndex(where: { $0.path == path }) else { return }
        folders[i].rules.removeAll { $0.id == id }
        persistFolders()
    }

    func moveRule(_ path: String, id: String, by delta: Int) {
        guard let i = folders.firstIndex(where: { $0.path == path }),
              let j = folders[i].rules.firstIndex(where: { $0.id == id }) else { return }
        let k = j + delta
        guard folders[i].rules.indices.contains(k) else { return }
        folders[i].rules.swapAt(j, k)
        persistFolders()
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        refreshWatchers()
    }

    // MARK: Running

    func scheduleScan(_ path: String, after delay: TimeInterval) {
        scheduled[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runAutomatic(path) }
        scheduled[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runAutomatic(_ path: String) {
        guard FolderRulesSettings.isEnabled, let folder = folders.first(where: { $0.path == path }),
              folder.enabled, !folder.rules.isEmpty else { return }
        if running.contains(path) { rescanAfterRun.insert(path); return }
        running.insert(path)
        let skip = recentSkipper()
        queue.async { [weak self] in
            let (files, retry) = FolderRulesEngine.candidates(in: folder, includeExisting: false, skip: skip)
            let gate = folder.rules.contains(where: \.needsAI) ? FolderRuleAIGate() : nil
            let plan = FolderRulesEngine.plan(folder: folder, files: files, ai: gate)
            let (done, errors) = FolderRulesEngine.apply(plan, folder: folder)
            DispatchQueue.main.async {
                self?.finish(path, done: done, errors: errors, aiSkipped: gate?.skipped ?? 0,
                             aiReason: gate?.blockReason, retry: retry)
            }
        }
    }

    private func recentSkipper() -> (URL) -> Bool {
        recentLock.lock()
        let cutoff = Date().addingTimeInterval(-600)
        recentlyMoved = recentlyMoved.filter { $0.value > cutoff }
        let snapshot = recentlyMoved
        recentLock.unlock()
        return { url in snapshot[url.standardizedFileURL.path] != nil }
    }

    private func finish(_ path: String, done: [FolderRuleActivity], errors: [String],
                        aiSkipped: Int, aiReason: String?, retry: TimeInterval?) {
        running.remove(path)
        record(done)
        if !errors.isEmpty {
            notes[path] = errors.count == 1 ? errors[0] : "\(errors.count) files couldn't be sorted — \(errors[0])"
        } else if aiSkipped > 0, let aiReason {
            notes[path] = "\(aiSkipped) file(s) waited for an AI rule: \(aiReason)"
        } else if !done.isEmpty {
            notes[path] = nil
        }
        if rescanAfterRun.remove(path) != nil {
            scheduleScan(path, after: 0.5)
        } else if let retry {
            scheduleScan(path, after: retry)
        }
    }

    private func record(_ done: [FolderRuleActivity]) {
        guard !done.isEmpty else { return }
        recentLock.lock()
        for d in done { if let to = d.to { recentlyMoved[URL(fileURLWithPath: to).standardizedFileURL.path] = d.date } }
        recentLock.unlock()
        activity.insert(contentsOf: done.reversed(), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        saveActivity()
    }

    /// Pregled: šta bi pravila uradila sa fajlovima koji su već u folderu.
    /// AI pravila se u pregledu pitaju samo ako je AI uključen (i broje se).
    func preview(_ path: String, completion: @escaping ([FolderRulePlanItem], String?) -> Void) {
        guard let folder = folders.first(where: { $0.path == path }) else { completion([], nil); return }
        let skip = recentSkipper()
        queue.async {
            let (files, _) = FolderRulesEngine.candidates(in: folder, includeExisting: true, skip: skip)
            let gate = folder.rules.contains(where: \.needsAI) ? FolderRuleAIGate() : nil
            let plan = FolderRulesEngine.plan(folder: folder, files: files, ai: gate)
            let note = (gate?.skipped ?? 0) > 0 ? "\(gate!.skipped) file(s) not checked: \(gate?.blockReason ?? "AI limit")" : nil
            DispatchQueue.main.async { completion(plan, note) }
        }
    }

    /// Primijeni pregledani plan (ručno „Sort N files").
    func apply(_ plan: [FolderRulePlanItem], in path: String, completion: @escaping (Int, [String]) -> Void) {
        guard let folder = folders.first(where: { $0.path == path }) else { completion(0, []); return }
        running.insert(path)
        queue.async { [weak self] in
            let (done, errors) = FolderRulesEngine.apply(plan, folder: folder)
            DispatchQueue.main.async {
                self?.running.remove(path)
                self?.record(done)
                completion(done.count, errors)
            }
        }
    }

    func undo(_ id: String) {
        guard let i = activity.firstIndex(where: { $0.id == id }), !activity[i].undone else { return }
        let entry = activity[i]
        if let to = entry.to {
            recentLock.lock()
            // Vraćeni fajl je „naš" potez — ne smije ga pravilo odmah opet pomjeriti.
            recentlyMoved[URL(fileURLWithPath: entry.from).standardizedFileURL.path] = Date()
            recentlyMoved[to] = nil
            recentLock.unlock()
        }
        if FolderRulesEngine.undo(entry) {
            activity[i].undone = true
            saveActivity()
        } else {
            notes[entry.folder] = "Couldn't undo “\(entry.fileName)” — it was moved or deleted since."
        }
    }

    func clearActivity() {
        activity.removeAll()
        saveActivity()
    }

    // MARK: Activity persistence

    private static var activityURL: URL { FolderRulesStorage.directory.appendingPathComponent("activity.json") }

    private static func loadActivity() -> [FolderRuleActivity] {
        guard let data = try? Data(contentsOf: activityURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([FolderRuleActivity].self, from: data)) ?? []
    }

    private func saveActivity() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(activity) { try? data.write(to: Self.activityURL, options: .atomic) }
    }

    /// Koliko je fajlova danas sređeno u ovom folderu (za status bar).
    func sortedToday(in path: String) -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        return activity.filter { $0.folder == path && !$0.undone && $0.date >= start }.count
    }
}
