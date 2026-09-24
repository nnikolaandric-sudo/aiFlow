import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CryptoKit

// MARK: - AI Organizer engine (planning only — no network, no UI)
//
// AIService talks to the model and AIOrganizerSheet shows the plan. What sits
// in between lives here so it stays testable without either: reading local
// content for the prompt, splitting a folder into requests, digging the plan
// out of whatever the model replied, and turning it into safe proposals that
// never clash with each other or with files already on disk.

/// What the user asked the organizer to do.
struct AIOrganizeOptions: Equatable {
    var renameFiles = true
    var useSubfolders = true
    /// When on, the model may flag duplicates for deletion (moved to Trash on apply).
    var deleteDuplicates = false
    /// Free-form guidance ("English names, dates first"), added to the prompt.
    var instructions = ""
}

/// Folder facts sent with every request so batches stay consistent.
struct AIPromptContext {
    var folderName = ""
    /// Subfolders already on disk plus folders proposed by earlier batches.
    var knownFolders: [String] = []
}

/// Progress from a running request (delivered off-main).
enum AIRequestEvent {
    case retrying(reason: String, wait: Double, attempt: Int, of: Int)
    case repairing
    /// The current key hit a limit (or was rejected) and the next saved
    /// key is tried. `index` is the 1-based number of the new key.
    case switchedKey(reason: String, index: Int, total: Int)
}

/// Thread-safe stop switch: checked between steps, and it cancels the
/// in-flight request so Stop never waits for a slow model.
final class AICancelToken {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    /// Remembers the request to cancel; one started after cancel() stops at once.
    func track(_ newTask: URLSessionTask?) {
        lock.lock()
        task = newTask
        let stop = cancelled
        lock.unlock()
        if stop { newTask?.cancel() }
    }

    /// Sleeps in short slices so Stop doesn't sit out a long backoff.
    /// Returns false when cancelled.
    func sleep(_ seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isCancelled { return false }
            Thread.sleep(forTimeInterval: min(0.2, max(0, end.timeIntervalSinceNow)))
        }
        return !isCancelled
    }
}

/// One reviewed change to apply.
struct AIPlanChange {
    let source: URL
    /// New bare filename.
    let name: String
    /// Subfolder of the organized folder, or "" to stay.
    let folder: String
    /// When true, the file is moved to Trash instead of renamed/moved.
    var isDelete = false
    /// Name of the file that is kept (shown in review / toast).
    var duplicateOf = ""
}

/// What `FileOperationsService.applyAIPlan` did.
struct AIApplyResult {
    var changed = 0
    var renamed = 0
    var moved = 0
    var deleted = 0
    var numbered = 0
    var skipped = 0
    var createdFolders = 0
    var firstError: String?

    var summary: String {
        var parts: [String] = []
        if renamed > 0 { parts.append("\(renamed) renamed") }
        if moved > 0 { parts.append("\(moved) moved") }
        if deleted > 0 { parts.append("\(deleted) \(deleted == 1 ? "duplicate" : "duplicates") to Trash") }
        if createdFolders > 0 { parts.append("\(createdFolders) new \(createdFolders == 1 ? "folder" : "folders")") }
        var text = "AI organized \(changed) \(changed == 1 ? "file" : "files")"
        if !parts.isEmpty { text += " — " + parts.joined(separator: ", ") }
        if skipped > 0 { text += ", \(skipped) skipped" }
        return text + " · ⌘Z to undo"
    }
}

/// What the model read out of a document, shown under its suggestion.
///
/// Nova arhitektura činjenica (tzv. bogati model dokumenta): umesto samo
/// 4 polja (type/issuer/number/date) klasifikuje se što više podataka sa
/// dokumenta — broj, valuta, datum izdavanja, datum dospeća, vrsta, naziv/
/// predmet, jezik, iznos i kupac. Sva polja su opcioni stringovi ("" = nije
/// nađeno) da starije verzije i manji modeli i dalje rade.
struct AIDocFacts: Equatable {
    /// One lowercase English word: invoice, receipt, proforma, offer,
    /// contract, annex, statement, report, letter, photo, screenshot or other.
    var type = ""
    /// Who issued it (Dobavljač / Prodavac / Izdavalac — NOT Kupac).
    var issuer = ""
    /// Broj dokumenta (Broj fakture / Broj računa / Poziv na broj).
    var number = ""
    /// The document's own issue date (Datum izdavanja), YYYY-MM-DD when recognizable.
    var date = ""
    /// Datum dospeća / Rok plaćanja / Valuta (due date), YYYY-MM-DD.
    var dueDate = ""
    /// Valuta (currency): RSD, EUR, USD, … — ISO kod, velikim slovima.
    var currency = ""
    /// Iznos (ukupno za plaćanje) kako piše na dokumentu, npr. "12.500,00".
    var amount = ""
    /// Naziv / predmet dokumenta (npr. "Usluge interneta — mart").
    var title = ""
    /// Jezik dokumenta: sr, en, de, … (ISO 639-1, malim slovima).
    var language = ""
    /// Kupac / klijent (samo za razlikovanje od issuer-a, ne ide u ime).
    var buyer = ""

    var isEmpty: Bool {
        type.isEmpty && issuer.isEmpty && number.isEmpty && date.isEmpty
            && dueDate.isEmpty && currency.isEmpty && amount.isEmpty
            && title.isEmpty && language.isEmpty && buyer.isEmpty
    }

    /// "Invoice · Primjer d.o.o. · No. 2024-0317 · 2024-03-12 · due 2024-03-20 · 12.500 RSD · sr"
    var summary: String {
        var parts: [String] = []
        if !type.isEmpty { parts.append(type.prefix(1).uppercased() + type.dropFirst()) }
        if !issuer.isEmpty { parts.append(issuer) }
        if !number.isEmpty { parts.append("No. \(number)") }
        if !date.isEmpty { parts.append(date) }
        if !dueDate.isEmpty { parts.append("due \(dueDate)") }
        if !amount.isEmpty || !currency.isEmpty {
            let money = [amount, currency].filter { !$0.isEmpty }.joined(separator: " ")
            parts.append(money)
        }
        if !title.isEmpty { parts.append(title) }
        if !language.isEmpty { parts.append(language) }
        return parts.joined(separator: " · ")
    }
}

/// One suggestion as shown for review.
struct AIProposal: Identifiable, Equatable {
    /// Source path — unique per file.
    let id: String
    let source: URL
    let original: String
    var name: String
    var folder: String
    var include = true
    /// The folder doesn't exist yet; applying creates it.
    var isNewFolder = false
    /// Why the suggestion was adjusted ("Name already taken — numbered").
    var note: String?
    /// What the model read out of the document.
    var facts = AIDocFacts()
    /// When true, applying moves the file to Trash instead of renaming/moving.
    var isDelete = false
    /// Name of the file that is kept (shown next to the delete suggestion).
    var duplicateOf = ""
    /// Why the model thinks it's a duplicate ("Same invoice number…").
    var deleteReason = ""

    var isRename: Bool { !isDelete && name != original }
    var isMove: Bool { !isDelete && !folder.isEmpty }
}

// MARK: - Reply parsing

enum AIPlanParser {
    struct Result {
        var items: [AIPlanItem] = []
        /// Rows that looked like plan entries, usable or not.
        var rawCount = 0
        /// A JSON plan was found (possibly an empty one: nothing to change).
        var foundJSON = false
        /// The reply stopped mid-list; `items` holds the complete rows before the cut.
        var truncated = false
    }

    private static let fromKeys = ["from", "original", "old", "old_name", "oldName", "file", "filename", "source", "current"]
    private static let nameKeys = ["name", "new_name", "newName", "new", "to", "rename", "new_filename"]
    private static let folderKeys = ["folder", "subfolder", "category", "directory", "dir", "group"]
    private static let listKeys = ["files", "renames", "plan", "items", "changes", "results", "result", "data", "operations"]
    private static let typeKeys = ["type", "doc_type", "document_type", "kind", "vrsta", "vrsta_dokumenta"]
    private static let issuerKeys = ["issuer", "vendor", "company", "supplier", "supplier_name", "seller", "issued_by", "sender", "party", "firm", "dobavljac", "dobavljač", "prodavac", "prodavač", "izdavalac", "izdavač", "isporucilac", "naziv_dobavljaca"]
    private static let numberKeys = ["number", "invoice_number", "invoice_no", "document_number", "doc_number", "no", "reference", "broj", "broj_fakture", "broj_racuna", "broj_dokumenta", "faktura_broj", "poziv_na_broj"]
    private static let dateKeys = ["date", "issue_date", "document_date", "invoice_date", "doc_date", "datum", "datum_izdavanja", "datum_fakture", "datum_racuna", "datum_prometa"]
    private static let dueDateKeys = ["due_date", "dueDate", "due", "payment_due", "maturity", "datum_dospeca", "datum_dospeća", "rok", "rok_placanja", "valuta_datum", "datum_valute", "dospijece", "dospjeće"]
    private static let currencyKeys = ["currency", "currency_code", "valuta", "valute", "oznaka_valute"]
    private static let amountKeys = ["amount", "total", "total_amount", "grand_total", "sum", "iznos", "ukupan_iznos", "ukupno", "ukupno_za_placanje", "za_uplatu", "bruto", "neto"]
    private static let titleKeys = ["title", "subject", "naziv", "predmet", "opis", "naslov", "usluga"]
    private static let languageKeys = ["language", "lang", "jezik", "locale"]
    private static let buyerKeys = ["buyer", "customer", "client", "kupac", "kupca", "klijent", "primalac", "bill_to"]
    private static let factsKeys = ["doc", "facts", "document", "metadata", "extracted"]
    private static let deleteKeys = ["delete", "remove", "trash", "is_duplicate", "duplicate"]
    private static let duplicateOfKeys = ["duplicate_of", "duplicateOf", "keep", "kept", "original_file", "keep_file"]
    private static let reasonKeys = ["reason", "why", "explanation", "duplicate_reason"]

    /// Digs the plan out of a model reply: drops inline reasoning and markdown
    /// fences, accepts a bare array or an object wrapping one, tolerates prose
    /// around the JSON, and keeps the complete rows of a reply that was cut off.
    static func extract(from reply: String, validNames: Set<String>) -> Result {
        let text = cleaned(reply)
        let scan = scan(text)
        var result = Result()
        var rows: [[String: Any]]?
        for span in scan.top where span.closed {
            guard let data = String(text[span.range]).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let found = planRows(in: value) else { continue }
            if rows == nil || found.count > rows!.count { rows = found }
        }
        let unclosed = scan.top.contains { !$0.closed }
        if rows == nil {
            // Cut off (max tokens) or broken: keep every complete row object.
            let salvaged = scan.objects.compactMap { range -> [String: Any]? in
                guard let data = String(text[range]).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      string(object, fromKeys) != nil else { return nil }
                return object
            }
            if !salvaged.isEmpty { rows = salvaged }
            result.truncated = unclosed
        }
        guard let rows else { return result }
        result.foundJSON = true

        let lowercased = Dictionary(validNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for row in rows {
            guard let rawFrom = string(row, fromKeys) else { continue }
            result.rawCount += 1
            let trimmed = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
            // Exact name first, then without a "./" or path prefix, then ignoring case.
            let from = [trimmed, (trimmed as NSString).lastPathComponent].lazy
                .compactMap { validNames.contains($0) ? $0 : lowercased[$0.lowercased()] }
                .first
            guard let from, !seen.contains(from) else { continue }
            seen.insert(from)
            let name = (string(row, nameKeys) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = (string(row, folderKeys) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isDelete = bool(row, deleteKeys)
            let duplicateOf = (string(row, duplicateOfKeys) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = (string(row, reasonKeys) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result.items.append(AIPlanItem(from: from, name: name.isEmpty ? from : name, folder: folder, facts: facts(in: row),
                                           isDelete: isDelete, duplicateOf: duplicateOf, deleteReason: reason))
        }
        return result
    }

    private static func cleaned(_ reply: String) -> String {
        var text = reply
        // Reasoning models sometimes inline their thinking — brackets in there
        // would otherwise look like JSON.
        for tag in ["think", "thinking", "reasoning"] {
            if let re = try? NSRegularExpression(pattern: "<\(tag)>[\\s\\S]*?</\(tag)>", options: [.caseInsensitive]) {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }
        text = text.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "```", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Span { let range: Range<String.Index>; let closed: Bool }

    /// One string-aware pass: top-level `[…]`/`{…}` spans (the last one may be
    /// unclosed) plus every closed `{…}` at any depth, for salvaging.
    private static func scan(_ text: String) -> (top: [Span], objects: [Range<String.Index>]) {
        var top: [Span] = []
        var objects: [Range<String.Index>] = []
        var stack: [(char: Character, index: String.Index)] = []
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                // Quotes in prose outside any JSON don't start a string.
                if !stack.isEmpty { inString = true }
            } else if c == "{" || c == "[" {
                stack.append((c, i))
            } else if c == "}" || c == "]" {
                if let open = stack.last, (open.char == "{") == (c == "}") {
                    stack.removeLast()
                    let range = open.index..<text.index(after: i)
                    if c == "}" { objects.append(range) }
                    if stack.isEmpty { top.append(Span(range: range, closed: true)) }
                } else {
                    stack.removeAll()
                }
            }
            i = text.index(after: i)
        }
        if let first = stack.first {
            top.append(Span(range: first.index..<text.endIndex, closed: false))
        }
        return (top, objects)
    }

    /// The plan rows in a decoded reply, [] for an empty plan, nil when it isn't plan-shaped.
    private static func planRows(in value: Any) -> [[String: Any]]? {
        if let array = value as? [Any] {
            if array.isEmpty { return [] }
            let rows = array.compactMap { $0 as? [String: Any] }
            guard rows.count == array.count, rows.contains(where: { string($0, fromKeys) != nil }) else { return nil }
            return rows
        }
        guard let object = value as? [String: Any] else { return nil }
        if string(object, fromKeys) != nil,
           string(object, nameKeys) != nil || string(object, folderKeys) != nil || bool(object, deleteKeys) {
            return [object]
        }
        for key in listKeys {
            if let inner = object[key], let rows = planRows(in: inner) { return rows }
        }
        for inner in object.values where inner is [Any] {
            if let rows = planRows(in: inner) { return rows }
        }
        return nil
    }

    private static func string(_ row: [String: Any], _ keys: [String]) -> String? {
        func text(_ value: Any?) -> String? {
            if let s = value as? String { return s }
            return (value as? NSNumber)?.stringValue   // "number": 17
        }
        for key in keys { if let s = text(row[key]) { return s } }
        for (key, value) in row where keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            if let s = text(value) { return s }
        }
        return nil
    }

    /// True when any of `keys` is a JSON true / 1 / "true" / "yes" / "delete".
    private static func bool(_ row: [String: Any], _ keys: [String]) -> Bool {
        func isTrue(_ value: Any?) -> Bool {
            if let b = value as? Bool { return b }
            if let n = value as? NSNumber { return n.intValue != 0 }
            if let s = value as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return ["true", "yes", "1", "delete", "trash", "remove", "duplicate"].contains(t)
            }
            return false
        }
        for key in keys { if isTrue(row[key]) { return true } }
        for (key, value) in row where keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            if isTrue(value) { return true }
        }
        // "action": "delete" also counts.
        if let action = string(row, ["action", "op", "operation"])?.lowercased(),
           ["delete", "trash", "remove"].contains(action) { return true }
        return false
    }

    /// Document facts from a row — flat keys or a nested "doc"/"facts" object.
    /// Stara 4 polja i dalje rade; nova (due_date, currency, amount, title,
    /// language, buyer) se čitaju kad ih model vrati, "" kad ih nema.
    private static func facts(in row: [String: Any]) -> AIDocFacts {
        var source = row
        for key in factsKeys {
            if let nested = row[key] as? [String: Any] { source.merge(nested) { current, _ in current } }
        }
        func value(_ keys: [String]) -> String {
            (string(source, keys) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AIDocFacts(type: normalizedType(value(typeKeys)), issuer: value(issuerKeys),
                          number: value(numberKeys), date: normalizedDate(value(dateKeys)),
                          dueDate: normalizedDate(value(dueDateKeys)),
                          currency: normalizedCurrency(value(currencyKeys)),
                          amount: value(amountKeys),
                          title: value(titleKeys),
                          language: normalizedLanguage(value(languageKeys)),
                          buyer: value(buyerKeys))
    }

    /// Serbian labels → English type used in review ("faktura"/"račun" → "invoice").
    static func normalizedType(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "faktura", "fakutura", "racun", "račun", "račun-otpremnica", "otpremnica-racun": return "invoice"
        case "predracun", "predračun", "proforma", "pro-forma", "profaktura": return "proforma"
        case "ponuda": return "offer"
        case "ugovor": return "contract"
        case "aneks", "annex": return "annex"
        case "izvod": return "statement"
        case "priznanica", "potvrda": return "receipt"
        default: return t
        }
    }

    /// "12.03.2024." or "12/3/2024" → "2024-03-12"; anything else stays as written.
    static func normalizedDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let parts = trimmed.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "-" }).map(String.init)
        guard parts.count == 3, parts[2].count == 4,
              let day = Int(parts[0]), let month = Int(parts[1]), let year = Int(parts[2]),
              (1...31).contains(day), (1...12).contains(month) else { return trimmed }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// "rsd", "Rsd.", "din", "dinara", "€", "$" → ISO kod ("RSD", "EUR", "USD"); ostalo velikim slovima.
    static func normalizedCurrency(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        switch t {
        case "rsd", "din", "din.", "dinara", "rsd.", "дin": return "RSD"
        case "eur", "eur.", "€", "evro", "euro": return "EUR"
        case "usd", "usd.", "$", "dolar", "dollar": return "USD"
        case "chf", "chf.", "franak": return "CHF"
        case "gbp", "gbp.", "£", "funta": return "GBP"
        case "bam", "km": return "BAM"
        case "hrk", "kn": return "HRK"
        case "": return ""
        default: return t.uppercased().prefix(5).trimmingCharacters(in: .whitespaces)
        }
    }

    /// "Srpski", "SR", "srpski", "srb" → "sr"; "English/EN" → "en"; ostalo prva 2 slova malo.
    static func normalizedLanguage(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "srpski", "sr", "srb", "serbian", "srp": return "sr"
        case "english", "engleski", "en", "eng": return "en"
        case "nemački", "nemacki", "german", "de", "ger", "deutsch": return "de"
        case "francuski", "french", "fr": return "fr"
        case "italijanski", "italian", "it": return "it"
        case "hrvatski", "croatian", "hr": return "hr"
        case "bosanski", "bosnian", "bs": return "bs"
        case "": return ""
        default: return String(t.prefix(2))
        }
    }
}

// MARK: - Name rules

enum AINameRules {
    /// Longest stem kept — readable, and far below the 255-byte limit.
    static let maxStemCharacters = 120

    /// A safe filename from the model's suggestion, or nil when nothing usable
    /// is left. The original extension always survives: "scan.pdf" stays a PDF
    /// even when the model wrote "Invoice.txt" or dropped the extension.
    static func sanitizeName(_ proposed: String, original: String) -> String? {
        let ext = splitItemName(original, isFolder: false).ext
        var stem = cleanComponent(proposed)
        if !ext.isEmpty, stem.lowercased().hasSuffix("." + ext.lowercased()) {
            stem = String(stem.dropLast(ext.count + 1))
        } else if let other = realExtension(of: stem) {
            stem = String(stem.dropLast(other.count + 1))
        }
        stem = stem.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-_")))
        if stem.count > maxStemCharacters {
            stem = String(stem.prefix(maxStemCharacters)).trimmingCharacters(in: .whitespaces)
        }
        while !stem.isEmpty, (ext.isEmpty ? stem : "\(stem).\(ext)").utf8.count > 255 {
            stem.removeLast()
        }
        guard !stem.isEmpty else { return nil }
        let name = ext.isEmpty ? stem : "\(stem).\(ext)"
        return invalidNameReason(name) == nil ? name : nil
    }

    /// One folder name, or "" for "stays where it is".
    static func sanitizeFolder(_ proposed: String) -> String {
        var name = cleanComponent(proposed)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-_")))
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, invalidNameReason(name) == nil else { return "" }
        return name
    }

    /// One path component: no slashes, colons or control characters, single
    /// spaces, no leading dot (a hidden file would vanish from the listing).
    static func cleanComponent(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            scalars.append(CharacterSet.controlCharacters.contains(u) || CharacterSet.newlines.contains(u) ? " " : u)
        }
        s = String(scalars)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        while s.hasPrefix(".") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A trailing extension the system knows ("txt", "jpg") — not just any
    /// dotted word, so "St.Louis" or "v2.1" stay intact.
    private static func realExtension(of stem: String) -> String? {
        guard let dot = stem.lastIndex(of: "."), dot != stem.startIndex else { return nil }
        let ext = String(stem[stem.index(after: dot)...])
        guard (1...5).contains(ext.count),
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
        return ext
    }
}

// MARK: - Deterministic naming from classified facts (Jev path)

/// Composes filenames from facts Jev classified — no LLM prose involved.
/// "<Tip> <broj> - <dobavljač> - <datum>", parts dropped when absent.
/// Returns nil when the facts are too thin (caller keeps the file as-is).
enum AINameComposer {
    static func compose(facts: AIDocFacts, original: String) -> String? {
        let label = displayLabel(type: facts.type, language: facts.language)
        let number = facts.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuer = facts.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = facts.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = facts.date.trimmingCharacters(in: .whitespacesAndNewlines)
        var head = label
        if !number.isEmpty { head += head.isEmpty ? number : " \(number)" }
        var parts: [String] = []
        if !head.isEmpty { parts.append(head) }
        let subject = !issuer.isEmpty ? issuer : title
        if !subject.isEmpty { parts.append(subject) }
        if !date.isEmpty { parts.append(date) }
        // Never date-only or label-only: need who/what + something.
        guard parts.count >= 2, !issuer.isEmpty || !number.isEmpty || !title.isEmpty else { return nil }
        return AINameRules.sanitizeName(parts.joined(separator: " - "), original: original)
    }

    /// Serbian labels for Serbian documents, capitalized English otherwise.
    static func displayLabel(type: String, language: String) -> String {
        let t = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sr") {
            switch t {
            case "invoice": return "Faktura"
            case "receipt": return "Priznanica"
            case "proforma": return "Predračun"
            case "offer": return "Ponuda"
            case "order": return "Narudžbina"
            case "contract": return "Ugovor"
            case "annex": return "Aneks"
            case "statement": return "Izvod"
            case "report": return "Izveštaj"
            case "letter": return "Pismo"
            case "photo": return "Fotografija"
            case "screenshot": return "Screenshot"
            case "", "other": return ""
            default: return t.prefix(1).uppercased() + t.dropFirst()
            }
        }
        guard !t.isEmpty, t != "other" else { return "" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

// MARK: - Jev classification (System One decisions)
//
// Jev answers only typed decisions (choice/noul/score) via OpenRouter's
// POST /api/v1/systemone — never free text. So it decides exactly what is
// decidable: document type, language and currency. Strings (issuer, numbers,
// dates, titles) come from the generative extractor; names are composed in
// code (AINameComposer). One decisions call per batch (fan-out), then merge.

/// Jev's per-file verdict. "" = not confident / not present.
struct JevClassFacts: Equatable {
    var type = ""
    var typeConfidence = 0.0
    var language = ""
    var languageConfidence = 0.0
    var currency = ""
    var currencyConfidence = 0.0

    var isEmpty: Bool { type.isEmpty && language.isEmpty && currency.isEmpty }
}

enum JevClassifier {
    /// Minimum confidence to accept a Jev answer (below it the generative
    /// facts stand). Calibrated probabilities: 0.55 accepts a lean-yes.
    static let minConfidence = 0.55
    /// Excerpt chars per file in decisions state — classification needs less
    /// than extraction, and it keeps big batches under payload limits.
    static let stateExcerptChars = 2000
    /// Encoded bodies above this split into halves before sending (413 guard).
    static let maxBodyBytes = 180_000

    /// Stable per-batch file id used as question prefix ("f0::type").
    static func fileID(_ index: Int) -> String { "f\(index)" }

    /// The `state` object for the System One request: folder + one entry per
    /// file (name, local facts, short excerpt). Pure — testable.
    static func state(entries: [AIFileEntry], folderName: String) -> [String: Any] {
        var files: [[String: Any]] = []
        for (i, e) in entries.enumerated() {
            var file: [String: Any] = ["id": fileID(i), "name": e.name]
            let details = ([e.kind] + e.details).filter { !$0.isEmpty }.joined(separator: " | ")
            if !details.isEmpty { file["details"] = details }
            if let p = e.preview, !p.isEmpty { file["excerpt"] = String(p.prefix(stateExcerptChars)) }
            files.append(file)
        }
        var state: [String: Any] = ["files": files]
        if !folderName.isEmpty { state["folder"] = folderName }
        return state
    }

    /// One type/language/currency Choice per file, asked together (fan-out).
    /// Pure — testable.
    static func questions(entries: [AIFileEntry]) -> [String: [String: Any]] {
        let typeCriteria = [
            "invoice": "Invoice / Faktura / Račun — a bill asking for payment (Broj fakture, Dobavljač, Datum izdavanja, iznos).",
            "receipt": "Receipt / Priznanica / Potvrda — proof a payment was already made.",
            "proforma": "Pro-forma invoice / Predračun / Profaktura — a preliminary bill, not yet payable.",
            "offer": "Offer / Ponuda — proposed goods or services with prices.",
            "order": "Order / Narudžbina — a purchase order.",
            "contract": "Contract / Ugovor — a signed agreement.",
            "annex": "Annex / Aneks — an amendment to a contract.",
            "statement": "Statement / Izvod — a bank or card account statement.",
            "report": "Report / Izveštaj — a summary or analysis.",
            "letter": "Letter / Pismo / Dopis — correspondence.",
            "photo": "A photograph with no readable document in it.",
            "screenshot": "A screenshot — a screen capture, UI.",
            "other": "None of the above.",
        ]
        let languageCriteria = [
            "sr": "Serbian / Srpski (latinica ili ćirilica).",
            "en": "English.",
            "de": "German / Nemački.",
            "fr": "French / Francuski.",
            "it": "Italian / Italijanski.",
            "hr": "Croatian / Hrvatski.",
            "bs": "Bosnian / Bosanski.",
            "other": "Another language, or cannot tell.",
        ]
        let currencyCriteria = [
            "RSD": "Serbian dinar (RSD, din, dinara).",
            "EUR": "Euro (EUR, €, evro).",
            "USD": "US dollar (USD, $, dolar).",
            "CHF": "Swiss franc (CHF, franak).",
            "GBP": "British pound (GBP, £).",
            "BAM": "Convertible mark (BAM, KM).",
            "none": "No amount or currency on the document.",
        ]
        var out: [String: [String: Any]] = [:]
        for (i, e) in entries.enumerated() {
            let fid = fileID(i)
            out["\(fid)::type"] = choice(
                instructions: "For file \(fid) (“\(e.name)”): what kind of document is it?",
                criteria: typeCriteria)
            out["\(fid)::language"] = choice(
                instructions: "For file \(fid) (“\(e.name)”): what language is the document written in?",
                criteria: languageCriteria)
            out["\(fid)::currency"] = choice(
                instructions: "For file \(fid) (“\(e.name)”): what currency are the amounts in?",
                criteria: currencyCriteria)
        }
        return out
    }

    static func choice(instructions: String, criteria: [String: String]) -> [String: Any] {
        ["type": "choice", "instructions": instructions, "criteria": criteria]
    }

    /// Typed answers → per-file verdicts keyed by entry name. Unknown
    /// question ids are ignored; "none"/"other" map to "". Confidences travel
    /// along — `merged` applies the threshold. Pure — testable.
    static func apply(answers: [String: [String: Any]], entries: [AIFileEntry]) -> [String: JevClassFacts] {
        var out: [String: JevClassFacts] = [:]
        for (qid, ans) in answers {
            let parts = qid.split(separator: ":").map(String.init).filter { !$0.isEmpty }
            guard parts.count == 2, parts[0].hasPrefix("f"),
                  let index = Int(parts[0].dropFirst()),
                  entries.indices.contains(index),
                  let picked = (ans["choice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !picked.isEmpty else { continue }
            let confidence = (ans["confidence"] as? NSNumber)?.doubleValue ?? 1.0
            let name = entries[index].name
            var facts = out[name] ?? JevClassFacts()
            switch parts[1] {
            case "type":
                facts.type = picked.lowercased() == "other" ? "" : AIPlanParser.normalizedType(picked)
                facts.typeConfidence = confidence
            case "language":
                facts.language = picked.lowercased() == "other" ? "" : AIPlanParser.normalizedLanguage(picked)
                facts.languageConfidence = confidence
            case "currency":
                facts.currency = picked.lowercased() == "none" ? "" : AIPlanParser.normalizedCurrency(picked)
                facts.currencyConfidence = confidence
            default:
                continue
            }
            out[name] = facts
        }
        return out
    }

    /// Jev verdicts merged over generative plan rows: a confident Jev value
    /// wins for type/language/currency, everything else stays generative.
    /// Pure — testable.
    static func merged(items: [AIPlanItem], jev: [String: JevClassFacts]) -> [AIPlanItem] {
        items.map { item in
            guard let j = jev[item.from] else { return item }
            var facts = item.facts
            if j.typeConfidence >= minConfidence { facts.type = j.type }
            if j.languageConfidence >= minConfidence { facts.language = j.language }
            if j.currencyConfidence >= minConfidence { facts.currency = j.currency }
            return AIPlanItem(from: item.from, name: item.name, folder: item.folder, facts: facts,
                              isDelete: item.isDelete, duplicateOf: item.duplicateOf,
                              deleteReason: item.deleteReason)
        }
    }

    /// Encoded request bytes for the 413 guard (state + questions as sent).
    static func encodedSize(entries: [AIFileEntry], folderName: String) -> Int {
        let body: [String: Any] = ["model": "typesafe/jev-1.13",
                                   "state": state(entries: entries, folderName: folderName),
                                   "questions": questions(entries: entries)]
        return (try? JSONSerialization.data(withJSONObject: body))?.count ?? 0
    }

    /// Rough pre-call cost for the budget gate (~3 chars per token).
    static func estimatedCost(entries: [AIFileEntry], folderName: String, promptPricePerToken: Double) -> Double {
        Double(encodedSize(entries: entries, folderName: folderName)) / 3 * promptPricePerToken
    }
}

// MARK: - Planning

enum AIPlanner {
    /// Lowercased names of everything in `folder` (hidden items too — they
    /// still block a name) and its visible subfolders.
    static func listing(of folder: URL) -> (names: Set<String>, folders: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let folders = names
            .filter { !$0.hasPrefix(".") && isPlainFolder(folder.appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (Set(names.map { $0.lowercased() }), folders)
    }

    /// Model rows → reviewable proposals for files in `folder`: cleans names
    /// and folders, drops no-ops, reuses an existing folder's spelling
    /// ("invoices" → "Invoices") and numbers every name that would clash with
    /// a file on disk or with another proposal, so applying never overwrites.
    /// When `options.deleteDuplicates` is on, rows with `delete: true` become
    /// Trash proposals instead of renames/moves.
    /// When `composeFromFacts` is on (Jev path — the model only classifies),
    /// names are composed deterministically from facts (AINameComposer) and
    /// same-document rows (identical issuer + number + date) become Trash
    /// proposals in code instead of asking the model.
    static func proposals(from items: [AIPlanItem], entries: [AIFileEntry], folder: URL,
                           options: AIOrganizeOptions, composeFromFacts: Bool = false) -> [AIProposal] {
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let lowercased = Dictionary(entries.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        let here = listing(of: folder)
        var spelling = Dictionary(here.folders.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var newFolders = Set<String>()
        var taken: [String: Set<String>] = ["": here.names]
        let ownName = folder.lastPathComponent.lowercased()
        var handled = Set<String>()
        var slatedForDelete = Set<String>()
        var out: [AIProposal] = []
        // Jev path: deterministic same-document map, computed up front so a
        // row trashed by hash earlier still resolves its keeper's note below.
        let docDupes = (composeFromFacts && options.deleteDuplicates) ? sameDocumentDupes(items: items) : [:]

        for item in items {
            guard let entry = byName[item.from], !handled.contains(entry.name) else { continue }
            handled.insert(entry.name)
            // MARK: Same document by facts (Jev path) → Trash
            if let keeper = docDupes[entry.name] {
                var note: String?
                if slatedForDelete.contains(keeper.lowercased()) {
                    note = "“\(keeper)” is also marked for deletion — keep one of them"
                }
                slatedForDelete.insert(entry.name.lowercased())
                out.append(AIProposal(id: entry.url.path, source: entry.url, original: entry.name,
                                      name: entry.name, folder: "",
                                      isNewFolder: false, note: note, facts: item.facts,
                                      isDelete: true, duplicateOf: keeper,
                                      deleteReason: "Isti dokument — isti broj, izdavalac i datum"))
                continue
            }
            // MARK: Duplicates → Trash (only when the option is on)
            if item.isDelete, options.deleteDuplicates {
                let keptRaw = item.duplicateOf.trimmingCharacters(in: .whitespacesAndNewlines)
                let kept = byName[keptRaw]?.name ?? lowercased[keptRaw.lowercased()] ?? keptRaw
                var note: String?
                if kept.isEmpty {
                    note = "AI thinks this is a duplicate — check before deleting"
                } else if kept.lowercased() == entry.name.lowercased() {
                    // Points to itself: still a delete, but flag it.
                    note = "AI marked this as a duplicate of itself — check before deleting"
                } else if slatedForDelete.contains(kept.lowercased()) {
                    note = "“\(kept)” is also marked for deletion — keep one of them"
                } else if byName[kept] == nil, lowercased[kept.lowercased()] == nil {
                    note = "Keeps “\(kept)” which is not in this folder — check before deleting"
                }
                slatedForDelete.insert(entry.name.lowercased())
                out.append(AIProposal(id: entry.url.path, source: entry.url, original: entry.name,
                                      name: entry.name, folder: "",
                                      isNewFolder: false, note: note, facts: item.facts,
                                      isDelete: true, duplicateOf: kept, deleteReason: item.deleteReason))
                continue
            }
            var name = options.renameFiles
                ? (AINameRules.sanitizeName(item.name, original: entry.name) ?? entry.name)
                : entry.name
            // Jev path: the model returns "name" == "from" — compose from facts.
            if composeFromFacts, options.renameFiles, name == entry.name, !item.facts.isEmpty,
               let composed = AINameComposer.compose(facts: item.facts, original: entry.name),
               composed != entry.name {
                name = composed
            }
            var folderName = options.useSubfolders ? AINameRules.sanitizeFolder(item.folder) : ""
            var note: String?
            if folderName.lowercased() == ownName { folderName = "" }
            if !folderName.isEmpty {
                let key = folderName.lowercased()
                if let existing = spelling[key] {
                    folderName = existing
                } else if here.names.contains(key) {
                    note = "A file named “\(folderName)” is in the way, so it stays here"
                    folderName = ""
                } else {
                    spelling[key] = folderName
                    newFolders.insert(key)
                }
            }
            if folderName.isEmpty && name == entry.name { continue }

            let key = folderName.lowercased()
            if taken[key] == nil {
                taken[key] = newFolders.contains(key) ? [] : listing(of: folder.appendingPathComponent(folderName)).names
            }
            var blocked = taken[key] ?? []
            // Its own current name doesn't block a file (e.g. a case-only rename).
            if folderName.isEmpty { blocked.remove(entry.name.lowercased()) }
            if blocked.contains(name.lowercased()) {
                name = numbered(name, avoiding: blocked)
                note = note ?? "Name already taken — numbered"
            }
            taken[key, default: []].insert(name.lowercased())
            out.append(AIProposal(id: entry.url.path, source: entry.url, original: entry.name,
                                  name: name, folder: folderName,
                                  isNewFolder: newFolders.contains(key), note: note, facts: item.facts))
        }
        return out
    }

    /// Rows with identical (issuer, number, date) — the same document twice.
    /// Returns [dupeFrom: keeperFrom]. Conservative: number AND issuer must be
    /// present; date participates as-is (empty matches empty — a missed date
    /// just misses a duplicate, never invents one).
    static func sameDocumentDupes(items: [AIPlanItem]) -> [String: String] {
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for item in items where !item.isDelete {
            let issuer = item.facts.issuer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let number = item.facts.number.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !issuer.isEmpty, !number.isEmpty else { continue }
            let date = item.facts.date.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(issuer)\u{1F}\(number)\u{1F}\(date)"
            if groups[key] == nil { order.append(key) }
            if !(groups[key]?.contains(item.from) ?? false) { groups[key, default: []].append(item.from) }
        }
        var out: [String: String] = [:]
        for key in order {
            let members = groups[key] ?? []
            guard members.count > 1 else { continue }
            let sorted = members.sorted { LocalDuplicates.preferKeeper($0, over: $1) }
            guard let keeper = sorted.first else { continue }
            for dupe in sorted.dropFirst() { out[dupe] = keeper }
        }
        return out
    }

    /// "Report.pdf" → "Report 2.pdf", "Report 3.pdf", … — the first free name (ignoring case).
    static func numbered(_ name: String, avoiding taken: Set<String>) -> String {
        let (stem, ext) = splitItemName(name, isFolder: false)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// Rough prompt tokens for one inventory line (~3 characters per token
    /// keeps non-Latin names on the safe side).
    static func estimatedTokens(_ entry: AIFileEntry) -> Int {
        (entry.name.count + (entry.preview?.count ?? 0) + entry.details.reduce(0) { $0 + $1.count + 3 } + 30) / 3
    }

    /// Splits the inventory into requests of at most `maxFiles` files and
    /// `tokenBudget` estimated prompt tokens — small-context models get
    /// smaller batches instead of an error.
    static func batches(_ entries: [AIFileEntry], maxFiles: Int, tokenBudget: Int) -> [[AIFileEntry]] {
        var out: [[AIFileEntry]] = []
        var current: [AIFileEntry] = []
        var tokens = 0
        for entry in entries {
            let t = estimatedTokens(entry)
            if !current.isEmpty && (current.count >= max(1, maxFiles) || tokens + t > tokenBudget) {
                out.append(current)
                current = []
                tokens = 0
            }
            current.append(entry)
            tokens += t
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

// MARK: - Local exact duplicates (no AI — byte-identical files)

/// Finds files with identical content by size + SHA-256, so "the same file
/// twice" is always caught even when the model ignores the duplicate rule or
/// is rate-limited. Runs off-main. Never triggers a cloud download.
enum LocalDuplicates {
    /// Exact-duplicate rows (isDelete) for files in `entries`. Keeps one per
    /// content group — the cleanest name ("Invoice.pdf" beats "Invoice copy.pdf").
    static func find(in entries: [AIFileEntry], cancel: AICancelToken? = nil,
                     progress: ((Int, Int) -> Void)? = nil) -> [AIPlanItem] {
        // Same size first — hashing only runs on real candidates.
        var bySize: [Int64: [AIFileEntry]] = [:]
        for e in entries { bySize[e.size, default: []].append(e) }
        var out: [AIPlanItem] = []
        var done = 0
        let total = entries.count
        for (_, group) in bySize where group.count > 1 {
            if cancel?.isCancelled == true { return [] }
            var byHash: [String: [AIFileEntry]] = [:]
            for e in group {
                if cancel?.isCancelled == true { return [] }
                done += 1
                progress?(done, total)
                guard !FileItem.isNotDownloaded(e.url),
                      let hash = sha256(of: e.url) else { continue }
                byHash[hash, default: []].append(e)
            }
            for (_, same) in byHash where same.count > 1 {
                let sorted = same.sorted { preferKeeper($0.name, over: $1.name) }
                guard let keeper = sorted.first else { continue }
                let sizeLabel = ByteCountFormatter.string(fromByteCount: keeper.size, countStyle: .file)
                for dupe in sorted.dropFirst() {
                    out.append(AIPlanItem(
                        from: dupe.name, name: dupe.name, folder: "",
                        isDelete: true, duplicateOf: keeper.name,
                        deleteReason: "Identical content to “\(keeper.name)” (\(sizeLabel))"))
                }
            }
        }
        return out
    }

    /// Keeper first: a clean name beats "copy", "(1)", " 2", "kopija".
    /// Falls back to alphabetical so the result is deterministic.
    static func preferKeeper(_ a: String, over b: String) -> Bool {
        let sa = copyScore(a), sb = copyScore(b)
        if sa != sb { return sa < sb }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    private static func copyScore(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("copy") || lower.contains("kopija") { return 2 }
        if lower.contains("(1)") || lower.contains("(2)") { return 2 }
        // "Invoice 2.pdf", "scan 3.jpg" — trailing number usually means a duplicate.
        if (try? NSRegularExpression(pattern: " \\d+(\\.[a-z0-9]+)?$", options: .caseInsensitive)
            .firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))) != nil { return 1 }
        return 0
    }

    /// SHA-256 streamed in 1 MB chunks — no big memory spike on large PDFs.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Local content for the prompt

enum AIContentReader {
    private static let richTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument,
    ]
    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "webp", "gif",
    ]

    /// A short excerpt plus naming facts for one file. Reads only files that
    /// are already on this Mac (never triggers a cloud download) and only a
    /// small part of them. Call off-main.
    static func describe(_ url: URL, size: Int64, modified: Date?, maxChars: Int,
                         includeContent: Bool) -> (preview: String?, details: [String]) {
        var details: [String] = []
        if let modified { details.append("modified " + day(modified)) }
        guard includeContent, !FileItem.isNotDownloaded(url) else { return (nil, details) }
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            // PDFInspector (portska ideja firecrawl/pdf-inspector): dokument se
            // učita JEDNOM, klasifikuje (text/scanned/mixed) uzorkovanjem, pa
            // se tekst vadi sa svih prvih strana + selektivni on-device OCR
            // samo za stranice bez tekstualnog sloja. Jev i chat modeli dobiju
            // isti čist Markdown izvod; detalji nose tip za prompt.
            if size <= 80 * 1024 * 1024 {
                let pdf = PDFInspector.describe(url: url, size: size, maxChars: maxChars)
                details += pdf.details
                if let p = pdf.preview, !p.isEmpty {
                    return (p, details)
                }
                return (nil, details)
            }
        } else if let type = richTypes[ext] {
            if size <= 20 * 1024 * 1024,
               let doc = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) {
                text = doc.string
            }
        } else if photoExtensions.contains(ext) {
            details += photoFacts(url)
            // Photographed receipts, scans and screenshots: a quick pass finds
            // out whether there's text at all, the accurate pass then reads it.
            if size <= 50 * 1024 * 1024, let image = downscaledImage(url, maxPixel: 2400),
               recognizeText(in: image, level: .fast).filter({ $0.isLetter || $0.isNumber }).count >= 20 {
                text = recognizeText(in: image)
                details.append("text read by OCR")
            }
        } else if size <= 256 * 1024, TextFileDetector.isEditableText(url),
                  let handle = try? FileHandle(forReadingFrom: url) {
            let data = handle.readData(ofLength: max(256, maxChars * 2))
            try? handle.close()
            text = String(decoding: data, as: UTF8.self)
        }
        guard let raw = text else { return (nil, details) }
        // One line per source line ("Datum: 12.03.2024. | Kupac: …") keeps
        // labels next to their values without wasting tokens on whitespace.
        let collapsed = raw.prefix(maxChars * 3)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return (collapsed.isEmpty ? nil : String(collapsed.prefix(maxChars)), details)
    }

    /// Text in an image, recognized on this Mac with Vision — nothing is uploaded for this step.
    static func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// A PDF page render helper now lives in PDFInspector.pageImage (single
    /// place for PDF raster + Vision OCR, shared by the app and the CLI).

    private static func downscaledImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Date taken, pixel size, camera and the screenshot marker — metadata only.
    private static func photoFacts(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any] else { return [] }
        var facts: [String] = []
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, taken.count >= 16 {
            // "2024:03:01 14:22:05" → "taken 2024-03-01 14:22"
            facts.append("taken \(taken.prefix(10).replacingOccurrences(of: ":", with: "-")) \(taken.dropFirst(11).prefix(5))")
        }
        if let comment = exif?[kCGImagePropertyExifUserComment] as? String,
           comment.localizedCaseInsensitiveContains("screenshot") {
            facts.append("screenshot")
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            facts.append("\(w)×\(h)")
        }
        if let camera = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces), !camera.isEmpty {
            facts.append(camera)
        }
        return facts
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
