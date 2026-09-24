import Foundation

// MARK: - Mail classifier (MAIL-02)
//
// Reuses the existing AI organizer instead of inventing a new one:
// attachments are read with AIContentReader.describe (PDFInspector + Vision
// OCR inside), AI facts come back as AIDocFacts (Jev decisions + generative
// extractor via AIService), names/folders are sanitized with AINameRules.
// This file adds only the mail-specific layer: local heuristics (no network),
// AI merge, and the 98/70 confidence gating from the spec.

enum MailClassifier {
    // MARK: Local suggestion (no network — pure, testable)

    /// Heuristic pass over headers + excerpts. `excerpts` maps attachment
    /// filename → short text (AIContentReader.describe output). `thread` is
    /// the thread's last filed suggestion for inheritance.
    static func localSuggestion(from mail: EmailMessage,
                                excerpts: [String: String] = [:],
                                thread: MailFilingSuggestion? = nil) -> MailFilingSuggestion {
        var s = MailFilingSuggestion()
        let subject = mail.subject
        let combined = ([subject, mail.body] + excerpts.values).joined(separator: " ")
        let lower = combined.lowercased()
        let fileNames = mail.attachments.map(\.filename).joined(separator: " ").lowercased()

        // Document type first — drives category + confidence.
        s.documentType = detectType(subject: subject, body: mail.body, filenames: fileNames, text: lower)
        s.category = category(for: s.documentType)

        // Entities: sender domain is a weak signal; subject "– Entity" and
        // thread inheritance are stronger.
        let domainOrg = organization(from: mail.from)
        if let t = thread {
            // "Attachment iz postojećeg threada → automatski poveži s istim predmetom."
            s.company = t.company; s.client = t.client; s.project = t.project
            if s.category.isEmpty { s.category = t.category }
            if s.documentType.isEmpty { s.documentType = t.documentType }
            s.note = "Thread inheritance"
        }
        if s.company.isEmpty { s.company = domainOrg }
        if let dashEntity = entityAfterDash(subject), s.client.isEmpty {
            // A dash tail repeating the company ("Faktura - BH Telecom" from
            // bhtelecom.ba) is not a client — compare spaceless.
            let norm = { (s: String) in s.lowercased().replacingOccurrences(of: " ", with: "") }
            if norm(dashEntity) != norm(s.company) {
                s.client = dashEntity
            }
        }
        if s.project.isEmpty { s.project = projectHint(subject: subject, text: combined) }

        // Dates / money / flags for reminders and review display.
        var facts: [String: String] = [:]
        if let due = findDate(labeled: ["due", "dosp", "rok pla", "valuta", "payment due"], in: combined) { facts["due_date"] = due }
        // Effective falls back to the document's first date; due/expiry stay
        // empty without a label (a guessed reminder is worse than none).
        if let eff = findDate(labeled: ["effective", "stup", "važi od", "vazi od", "potpisan"], in: combined, allowFallback: true) { facts["effective"] = eff }
        if let exp = findDate(labeled: ["expir", "ističe", "istice", "valid until", "važi do", "vazi do"], in: combined) { facts["expiry"] = exp }
        if let money = findMoney(in: combined) { facts["amount"] = money.0; facts["currency"] = money.1 }
        if isSigned(subject: subject, text: lower, filenames: fileNames) { facts["signed"] = "yes" }
        if isApproval(subject: subject, body: mail.body) { facts["approval"] = "yes" }
        s.facts = facts

        s.targetFolder = targetFolder(category: s.category, entity: s.client.isEmpty ? s.company : s.client)
        s.confidence = confidence(subject: subject, body: mail.body, type: s.documentType,
                                  hasThread: thread != nil, hasDates: !facts.isEmpty,
                                  attachmentCount: mail.attachments.count, aiAgrees: false)
        return s
    }

    // MARK: AI merge (Jev + extractor facts — pure, testable)

    /// Folds organizer facts over the heuristic suggestion. A confident AI
    /// type that matches the heuristic boosts confidence; a mismatch lowers
    /// it into the review band instead of auto-filing. `senderDomainOrg` lets
    /// a strong AI issuer override the weak domain guess ("Abc" → "CyberArrow")
    /// while a thread/user-set company always wins.
    static func mergeAI(_ suggestion: MailFilingSuggestion, facts: AIDocFacts,
                        senderDomainOrg: String = "") -> MailFilingSuggestion {
        var s = suggestion
        var agree = false
        if !facts.type.isEmpty {
            agree = facts.type.lowercased() == s.documentType.lowercased() || s.documentType.isEmpty
            if s.documentType.isEmpty { s.documentType = facts.type.lowercased(); agree = true }
            s.category = category(for: s.documentType)
        }
        if !facts.issuer.isEmpty,
           s.company.isEmpty || (!senderDomainOrg.isEmpty && s.company == senderDomainOrg && s.note != "Thread inheritance") {
            s.company = facts.issuer
        }
        // Invoice numbers feed strong names ("Faktura 09-2026 - ...").
        if !facts.number.isEmpty { s.facts["number"] = facts.number }
        if !facts.buyer.isEmpty && s.client.isEmpty { s.client = facts.buyer }
        if !facts.title.isEmpty && s.project.isEmpty { s.project = facts.title }
        if !facts.dueDate.isEmpty { s.facts["due_date"] = facts.dueDate }
        if !facts.date.isEmpty { s.facts["effective"] = s.facts["effective"] ?? facts.date }
        if !facts.amount.isEmpty { s.facts["amount"] = facts.amount }
        if !facts.currency.isEmpty { s.facts["currency"] = facts.currency }
        s.targetFolder = targetFolder(category: s.category, entity: s.client.isEmpty ? s.company : s.client)
        // Recompute with AI agreement signal (dates may have grown).
        s.confidence = confidence(subject: "", body: "", type: s.documentType,
                                  hasThread: !(s.note.isEmpty && s.company.isEmpty),
                                  hasDates: !s.facts.isEmpty,
                                  attachmentCount: max(1, s.facts.count),
                                  aiAgrees: agree)
        if !agree && !facts.type.isEmpty { s.note = "AI type “\(facts.type)” vs heuristic “\(suggestion.documentType)” — review" }
        return s
    }

    // MARK: Attachment excerpts (Document Processor — reuses organizer)

    /// Writes attachment bytes to temp and reads organizer-grade excerpts
    /// (PDFInspector text/mixed + Vision OCR for scans/images, DOCX/RTF,
    /// plain text). Call off-main. Returns filename → excerpt.
    static func excerpts(for attachments: [ParsedAttachment], maxChars: Int = 4000) -> [String: String] {
        var out: [String: String] = [:]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FinderFlow-mail-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for a in attachments {
            if a.filename.lowercased().hasSuffix(".zip") { continue } // unpacked in filing, not excerpted
            let url = dir.appendingPathComponent(MailEmlParser.sanitizeFilename(a.filename))
            do {
                try a.data.write(to: url)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(a.data.count)
                let desc = AIContentReader.describe(url, size: size, modified: nil,
                                                    maxChars: maxChars, includeContent: true)
                var parts = desc.details
                if let p = desc.preview, !p.isEmpty { parts.append(p) }
                if !parts.isEmpty { out[a.filename] = parts.joined(separator: " | ") }
                try? FileManager.default.removeItem(at: url)
            } catch { continue }
        }
        return out
    }

    /// Builds organizer inventory entries for attachments (for AIService
    /// requestPlan / requestDecisions). Caller materializes temp files.
    static func inventoryEntries(for attachments: [ParsedAttachment], maxChars: Int = 4000) -> [AIFileEntry] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FinderFlow-mail-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var entries: [AIFileEntry] = []
        for a in attachments {
            let url = dir.appendingPathComponent(MailEmlParser.sanitizeFilename(a.filename))
            try? a.data.write(to: url)
            let size = Int64(a.data.count)
            let desc = AIContentReader.describe(url, size: size, modified: nil,
                                                maxChars: maxChars, includeContent: true)
            let ext = (a.filename as NSString).pathExtension.lowercased()
            entries.append(AIFileEntry(url: url, name: a.filename,
                                       kind: ext.isEmpty ? "file" : ext.uppercased(),
                                       size: size, preview: desc.preview, details: desc.details))
        }
        return entries.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: Type detection

    static func detectType(subject: String, body: String, filenames: String, text: String) -> String {
        let hay = (subject + " " + filenames).lowercased()
        let bodyLower = (body + " " + text).lowercased()
        // Word-boundary matching: "štanda" is not an NDA, "obračun" (statement)
        // is not a "račun" (invoice). Proforma before invoice ("profaktura").
        if hasWord(hay, ["nda"]) || bodyLower.contains("non-disclosure") || bodyLower.contains("poverljivost") { return "nda" }
        if hasWord(hay, ["cv"]) || hay.contains("biografija") || hay.contains("resume") || filenames.contains("cv") { return "cv" }
        if hay.contains("predračun") || hay.contains("predracun") || hay.contains("proforma") || hay.contains("profaktura") { return "proforma" }
        if hay.contains("faktura") || hay.contains("invoice") || hasWord(hay, ["račun", "racun"]) { return "invoice" }
        if hay.contains("ponuda") || hay.contains("offer") || hay.contains("proposal") { return "offer" }
        if hay.contains("aneks") || hay.contains("annex") || hay.contains("amendment") { return "annex" }
        if hay.contains("ugovor") || hay.contains("contract") || hay.contains("agreement") || hasWord(hay, ["msa"]) { return "contract" }
        if hay.contains("izvod") || hay.contains("statement") { return "statement" }
        if hay.contains("priznanica") || hay.contains("receipt") || hay.contains("potvrda o uplati") { return "receipt" }
        if hay.contains("scope") || subject.lowercased().hasPrefix("re:") && filenames.isEmpty { return "correspondence" }
        // Content fallback.
        if bodyLower.contains("service agreement") || bodyLower.contains("ugovor o") { return "contract" }
        if bodyLower.contains("ukupno za plaćanje") || bodyLower.contains("poziv na broj") { return "invoice" }
        // Zero-attachment thread mail = correspondence, not a document.
        return filenames.trimmingCharacters(in: .whitespaces).isEmpty ? "correspondence" : "other"
    }

    /// Whole-word match (case-insensitive). Plain `contains` misfires on
    /// substrings ("štanda"→nda, "obračun"→račun).
    static func hasWord(_ text: String, _ words: [String]) -> Bool {
        for w in words {
            guard let re = try? NSRegularExpression(
                pattern: "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b",
                options: .caseInsensitive) else { continue }
            if re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        }
        return false
    }

    /// Built-in automations → default DMS category (rules can override).
    static func category(for type: String) -> String {
        switch type.lowercased() {
        case "invoice", "proforma", "receipt", "statement": return "Finance"
        case "contract", "annex": return "Contracts"
        case "nda": return "Legal"
        case "cv": return "HR / Candidates"
        case "offer": return "Offers"
        case "correspondence": return "Correspondence"
        default: return ""
        }
    }

    static func targetFolder(category: String, entity: String) -> String {
        let cat = AINameRules.sanitizeFolder(category)
        let ent = AINameRules.sanitizeFolder(entity)
        if !cat.isEmpty, !ent.isEmpty { return "\(cat) / \(ent)" }
        return cat.isEmpty ? ent : cat
    }

    // MARK: Entities

    static func organization(from sender: String) -> String {
        guard let at = sender.firstIndex(of: "@") else { return "" }
        var domain = String(sender[sender.index(after: at)...]).lowercased()
        domain = domain.split(separator: ">").first.map(String.init) ?? domain
        let parts = domain.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        // Skip public providers — they identify a person, not a company.
        let publicProviders: Set<String> = ["gmail", "yahoo", "hotmail", "outlook", "icloud", "protonmail", "proton", "aol", "zoho"]
        let sld = String(parts[parts.count - 2])
        if publicProviders.contains(sld) { return "" }
        return sld.prefix(1).uppercased() + sld.dropFirst()
    }

    /// "Potpisani ugovor – Valens" → "Valens". Uses the LAST separator and
    /// rejects filename-like tails ("..._Non-Critical_VALENS doo" → nil, not
    /// "Critical_VALENS doo") plus trailing dates.
    static func entityAfterDash(_ subject: String) -> String? {
        // Separators latest-first ("A | B – March 2026" tries "–", then "|").
        var positions: [String.Index] = []
        for sep in ["–", "—", "-", "|", ":"] {
            var search = subject.startIndex
            while let r = subject.range(of: sep, range: search..<subject.endIndex) {
                positions.append(r.lowerBound)
                search = subject.index(after: r.lowerBound)
                if search >= subject.endIndex { break }
            }
        }
        for pos in positions.sorted(by: >) {
            var tail = String(subject[subject.index(after: pos)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
            // Strip trailing dates ("Valens d.o.o. – March 2026" → "Valens d.o.o." —
            // the month may sit at the very start, so ^ counts as boundary).
            for pattern in [#"(?:^|\s+)\d{1,2}[./]\d{1,2}[./]\d{2,4}\.?\s*$"#, #"(?:^|\s+)(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}\s*$"#] {
                if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let m = re.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                   let rr = Range(m.range, in: tail) {
                    tail = String(tail[..<rr.lowerBound])
                }
            }
            tail = cleanTail(tail)
            // Never a filename ("Valens (1).pdf" made a folder once).
            let tailExt = (tail as NSString).pathExtension.lowercased()
            if ["pdf", "doc", "docx", "xls", "xlsx", "jpg", "jpeg", "png", "zip", "eml", "txt"].contains(tailExt) { continue }
            if tail.count >= 2, tail.count <= 40,
               !tail.contains("@"), !tail.contains("_"), !tail.contains("|") {
                return tail
            }
        }
        return nil
    }

    /// Trailing separators left after date stripping ("Valens d.o.o. –").
    private static func cleanTail(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”–—-|:;,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func projectHint(subject: String, text: String) -> String {
        let lower = subject.lowercased()
        if lower.contains("security assessment") { return "Security Assessment" }
        if lower.contains("penetration") || lower.contains("pentest") { return "Penetration Test" }
        if lower.contains("recruitment") || lower.contains("zapošljavanje") { return "Recruitment" }
        if text.lowercased().contains("liability cap") { return "Liability" }
        return ""
    }

    // MARK: Dates / money / flags

    static func findDate(labeled keywords: [String], in text: String, allowFallback: Bool = false) -> String? {
        let lower = text.lowercased()
        // Prefer a date right after the label ("Expiry 22.09.2027") — the old
        // first-date-in-text fallback smeared one date over all three fields.
        for kw in keywords {
            var search = lower.startIndex
            while let r = lower.range(of: kw, range: search..<lower.endIndex) {
                let end = lower.index(r.upperBound, offsetBy: 160, limitedBy: lower.endIndex) ?? lower.endIndex
                if let d = firstDate(in: String(text[r.lowerBound..<end])) { return d }
                search = r.upperBound
            }
        }
        return allowFallback ? firstDate(in: text) : nil
    }

    private static func firstDate(in text: String) -> String? {
        let patterns = [#"\b(\d{1,2})[./](\d{1,2})[./](\d{4})\b"#, #"\b(\d{4})-(\d{2})-(\d{2})\b"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text) else { continue }
            let raw = String(text[r])
            let norm = AIPlanParser.normalizedDate(raw)
            return norm.isEmpty ? raw : norm
        }
        return nil
    }

    static func findMoney(in text: String) -> (String, String)? {
        // Cents optional: "3,000 USD" and "12.500 RSD" have none.
        let patterns = [
            #"(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?)\s*(USD|EUR|RSD|BAM|CHF|GBP|\$|€|KM)"#,
            #"(USD|EUR|RSD|BAM|CHF|GBP)\s*(\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{2})?)"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let amount = Range(m.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let curr = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            if p.hasPrefix("(USD") { return (curr, AIPlanParser.normalizedCurrency(amount)) }
            return (amount, AIPlanParser.normalizedCurrency(curr))
        }
        return nil
    }

    static func isSigned(subject: String, text: String, filenames: String) -> Bool {
        let hay = (subject + " " + text + " " + filenames).lowercased()
        return hay.contains("signed") || hay.contains("potpisan") || hay.contains("potpisani")
            || hay.contains("docusign") || hay.contains("signature")
    }

    /// Reply containing approval → status/approval flag.
    static func isApproval(subject: String, body: String) -> Bool {
        let hay = (subject + " " + body).lowercased()
        return hay.contains("approved") || hay.contains("approve") || hay.contains("odobreno")
            || hay.contains("potvrđujem") || hay.contains("potvrdjujem") || hay.contains("saglasan")
            || hay.contains("lgtm") || hay.contains("agree")
    }

    // MARK: Confidence

    /// Combines weak signals; AI agreement and thread continuity weigh most.
    /// Thresholds live in MailFilingPolicy (0.98 auto / 0.70 review).
    static func confidence(subject: String, body: String, type: String,
                           hasThread: Bool, hasDates: Bool,
                           attachmentCount: Int, aiAgrees: Bool) -> Double {
        if type == "correspondence" && attachmentCount == 0 { return hasThread ? 0.85 : 0.75 }
        var c = 0.45
        if !type.isEmpty, type != "other" { c += 0.15 }
        if hasThread { c += 0.15 }
        if aiAgrees { c += 0.15 }
        if hasDates { c += 0.08 }
        if attachmentCount > 0 { c += 0.05 }
        if !subject.isEmpty, !body.isEmpty { c += 0.02 }
        return min(0.99, c)
    }
}
