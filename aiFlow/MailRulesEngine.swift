import Foundation
import Combine

// MARK: - Rules + AI (MAIL-03)
//
// User writes plain language ("Sve račune sa @bhtelecom.ba stavi u Finance →
// Telecom"), Finder turns it into a MailRule. Deterministic parser handles the
// documented patterns offline; the AI fallback (AIService, opt-in) handles
// free phrasing — rule NL only, never file bytes. Matching is pure.

struct MailRulePredicate: Codable, Equatable {
    /// fromDomain | toAddress | subjectContains | bodyContains |
    /// filenameContains | contentContains | docType | hasAttachment
    var field: String
    var contains: String
    /// When true the predicate is negated ("osim faktura").
    var negated: Bool = false
}

struct MailRuleAction: Codable, Equatable {
    /// folder | category | company | client | project | reminder | markReview
    var kind: String
    var value: String
}

struct MailRule: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    /// Original natural-language source (shown in UI, re-parseable).
    var source: String = ""
    var predicates: [MailRulePredicate] = []
    var actions: [MailRuleAction] = []
    var enabled: Bool = true
}

enum MailRulesEngine {
    // MARK: NL → rule (deterministic, offline)

    /// Covers the spec patterns + generic "stavi u / poveži sa" fallback.
    /// Returns nil when nothing actionable was found (caller may ask AI).
    static func rule(fromNL nl: String) -> MailRule? {
        let text = nl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        var predicates: [MailRulePredicate] = []
        var actions: [MailRuleAction] = []

        // Sender domain: "@bhtelecom.ba" / "sa @x" / "od @x".
        for token in tokens(lower) where token.hasPrefix("@") && token.contains(".") {
            predicates.append(MailRulePredicate(field: "fromDomain", contains: String(token.dropFirst())))
        }
        // Recipient address: "na jobs@valens.dev" / "za jobs@…".
        if let mail = firstEmail(in: text) {
            if lower.contains("na \(mail.lowercased())") || lower.contains("za \(mail.lowercased())")
                || lower.contains("jobs@") {
                predicates.append(MailRulePredicate(field: "toAddress", contains: mail.lowercased()))
            }
        }
        // Doc-type hints: "račune/fakture" → invoice, "cv" → cv, "nda" → nda…
        // A type named in an "osim X" (except) clause only negates — it must
        // not also add the positive predicate ("osim faktura" ≠ invoice mail).
        let afterOsim: String = {
            guard let r = lower.range(of: "osim") else { return "" }
            return String(lower[r.upperBound...])
        }()
        if (lower.contains("račun") || lower.contains("racun") || lower.contains("faktur") || lower.contains("invoice"))
            && !afterOsim.contains("račun") && !afterOsim.contains("racun")
            && !afterOsim.contains("faktur") && !afterOsim.contains("invoice") {
            predicates.append(MailRulePredicate(field: "docType", contains: "invoice"))
        }
        if lower.contains("cv") || lower.contains("biografij") || lower.contains("resume") {
            predicates.append(MailRulePredicate(field: "docType", contains: "cv"))
        }
        if lower.contains("nda") {
            predicates.append(MailRulePredicate(field: "docType", contains: "nda"))
        }
        if lower.contains("ugovor") || lower.contains("contract") {
            predicates.append(MailRulePredicate(field: "docType", contains: "contract"))
        }
        // "koji u nazivu ili sadržaju imaju X" → contentContains (matcher
        // covers filename + subject + excerpt, i.e. OR semantics).
        if let keyword = quotedOrCapitalized(in: text), !keyword.isEmpty,
           lower.contains("naziv") || lower.contains("sadrž") || lower.contains("sadrz") || lower.contains("sadrzaj") {
            predicates.append(MailRulePredicate(field: "contentContains", contains: keyword))
            let company = keyword.prefix(1).uppercased() + keyword.dropFirst()
            if !actions.contains(where: { $0.kind == "company" }) {
                actions.append(MailRuleAction(kind: "company", value: company))
            }
        }
        // "osim faktura" → negated invoice predicate.
        if lower.contains("osim faktura") || lower.contains("osim racuna") || lower.contains("osim računa") {
            predicates.append(MailRulePredicate(field: "docType", contains: "invoice", negated: true))
        }
        // Target: "stavi u Finance → Telecom" / "poveži sa Recruitment".
        if let folder = folderAfter(in: text, markers: ["stavi u", "stavi u:", "prebaci u", "arhiviraj u"]) {
            actions.append(MailRuleAction(kind: "folder", value: folder))
        } else if let entity = folderAfter(in: text, markers: ["poveži sa", "povezi sa", "poveži s", "linkuj"]) {
            if entity.lowercased().contains("recruit") {
                actions.append(MailRuleAction(kind: "project", value: "Recruitment"))
            } else if entity.lowercased().contains("account") || entity.lowercased().contains("klijent") {
                actions.append(MailRuleAction(kind: "company", value: entityAfterDashEntity(entity) ?? entity))
            } else {
                actions.append(MailRuleAction(kind: "company", value: entity))
            }
        }
        guard !predicates.isEmpty, !actions.isEmpty else { return nil }
        // Same action from two clauses (keyword + "poveži sa X") — keep once.
        var seen: [MailRuleAction] = []
        for a in actions where !seen.contains(a) { seen.append(a) }
        let name = String(text.prefix(60))
        return MailRule(name: name, source: text, predicates: predicates, actions: seen)
    }

    /// Prompt for the AI fallback: converts free-phrased NL into the same
    /// JSON rule shape (rule text only — privacy-safe). Caller sends this via
    /// AIService.requestPlan with a small model and parses with JSONDecoder.
    static func rulePrompt(nl: String) -> String {
        """
        You convert a mail filing rule written in plain language (Serbian or English) into JSON.
        Reply with ONLY this JSON, no commentary:
        {"predicates":[{"field":"fromDomain|toAddress|subjectContains|bodyContains|filenameContains|contentContains|docType","contains":"...","negated":false}],"actions":[{"kind":"folder|category|company|client|project|markReview","value":"..."}]}
        Rule: \(nl)
        """
    }

    // MARK: Matching (pure)

    static func matches(_ rule: MailRule, mail: EmailMessage,
                        suggestion: MailFilingSuggestion, excerptText: String = "") -> Bool {
        guard rule.enabled else { return false }
        for p in rule.predicates {
            let hit: Bool
            switch p.field {
            case "fromDomain": hit = mail.from.lowercased().contains(p.contains.lowercased())
            case "toAddress": hit = mail.to.contains { $0.lowercased().contains(p.contains.lowercased()) }
            case "subjectContains": hit = mail.subject.lowercased().contains(p.contains.lowercased())
            case "bodyContains": hit = mail.body.lowercased().contains(p.contains.lowercased())
            case "filenameContains":
                hit = mail.attachments.contains { $0.filename.lowercased().contains(p.contains.lowercased()) }
            case "contentContains":
                hit = excerptText.lowercased().contains(p.contains.lowercased())
                    || mail.attachments.contains { $0.filename.lowercased().contains(p.contains.lowercased()) }
                    || mail.subject.lowercased().contains(p.contains.lowercased())
            case "docType": hit = suggestion.documentType.lowercased() == p.contains.lowercased()
            case "hasAttachment": hit = !mail.attachments.isEmpty
            default: hit = false
            }
            if p.negated ? hit : !hit { return false }
        }
        return !rule.predicates.isEmpty
    }

    /// Applies matching rules over a suggestion. Returns the updated
    /// suggestion + whether any rule fired (confidence +0.10 on hit).
    static func apply(rules: [MailRule], mail: EmailMessage,
                      suggestion: MailFilingSuggestion, excerptText: String = "") -> (MailFilingSuggestion, Bool) {
        var s = suggestion
        var fired = false
        for r in rules where matches(r, mail: mail, suggestion: s, excerptText: excerptText) {
            fired = true
            for a in r.actions {
                switch a.kind {
                case "folder": s.targetFolder = a.value; s.note = "Rule: \(r.name)"
                case "category": s.category = a.value
                case "company": s.company = a.value
                case "client": s.client = a.value
                case "project": s.project = a.value
                case "markReview": s.confidence = min(s.confidence, 0.9)
                default: break
                }
            }
        }
        if fired {
            s.confidence = min(0.99, s.confidence + 0.10)
            if s.targetFolder.isEmpty {
                s.targetFolder = MailClassifier.targetFolder(category: s.category, entity: s.client.isEmpty ? s.company : s.client)
            }
        }
        return (s, fired)
    }

    // MARK: Built-in automations (spec list — deterministic, offline)

    /// Expiry / invoice-due reminders from suggestion facts.
    static func reminders(for mail: EmailMessage, suggestion: MailFilingSuggestion) -> [MailReminder] {
        var out: [MailReminder] = []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        if let exp = suggestion.facts["expiry"], let d = fmt.date(from: exp) {
            out.append(MailReminder(id: "\(mail.id)-expiry", mailID: mail.id, kind: "expiry",
                                    dueDate: d, note: "Expires: \(suggestion.entity) — \(suggestion.documentType)"))
        }
        if let due = suggestion.facts["due_date"], suggestion.documentType == "invoice",
           let d = fmt.date(from: due) {
            let warn = Calendar.current.date(byAdding: .day, value: -3, to: d) ?? d
            out.append(MailReminder(id: "\(mail.id)-due", mailID: mail.id, kind: "invoice_due",
                                    dueDate: warn, note: "Invoice due: \(suggestion.facts["amount"] ?? "") \(suggestion.facts["currency"] ?? "")"))
        }
        return out
    }

    // MARK: Helpers

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "(" || $0 == ")" }).map(String.init)
    }

    private static func firstEmail(in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    private static func quotedOrCapitalized(in s: String) -> String? {
        if let re = try? NSRegularExpression(pattern: #""([^"]+)"|“([^”]+)”"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            for idx in [1, 2] where m.range(at: idx).location != NSNotFound {
                if let r = Range(m.range(at: idx), in: s) { return String(s[r]) }
            }
        }
        // "imaju CyberArrow" → CyberArrow.
        if let re = try? NSRegularExpression(pattern: #"(?:imaju|contains?|sa imenom)\s+([A-ZČĆŽŠĐ][\wčćžšđČĆŽŠĐ.-]+)"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range(at: 1), in: s) {
            return String(s[r])
        }
        return nil
    }

    private static func folderAfter(in s: String, markers: [String]) -> String? {
        let lower = s.lowercased()
        for marker in markers {
            guard let r = lower.range(of: marker) else { continue }
            var tail = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            if tail.hasSuffix(".") { tail = String(tail.dropLast()) }
            let clean = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    private static func entityAfterDashEntity(_ s: String) -> String? {
        let parts = s.split(separator: " ").map(String.init)
        return parts.first { $0.prefix(1) == $0.prefix(1).uppercased() && $0.count > 2 }
    }
}

// MARK: - Rule store (UserDefaults JSON, like AI settings)

final class MailRuleStore: ObservableObject {
    static let shared = MailRuleStore()
    @Published private(set) var rules: [MailRule] = [] {
        didSet { persist() }
    }
    private let key = UserPreferences.mailRulesKey

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MailRule].self, from: data) {
            rules = decoded
        }
    }

    func add(_ rule: MailRule) {
        rules.append(rule)
        objectWillChange.send()
    }

    func addFromNL(_ nl: String) -> MailRule? {
        guard let r = MailRulesEngine.rule(fromNL: nl) else { return nil }
        add(r)
        return r
    }

    func remove(id: String) {
        rules.removeAll { $0.id == id }
        objectWillChange.send()
    }

    func toggle(id: String) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled.toggle()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
