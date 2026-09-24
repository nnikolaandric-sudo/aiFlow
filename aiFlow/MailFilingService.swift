import Foundation

// MARK: - Filing orchestrator (MAIL-01..03 pipeline)
//
// Gmail / Outlook                    (MailConnector — incremental, unseen IDs only)
//        │
//        ▼
// Email Queue = the single Email folder (EmlDirectoryConnector on Email/Inbox;
//                             Graph/IMAP later; drop .eml, Sync, source → Done)
//        │
//        ├── Store email (.eml evidence object, Message-ID dedup)
//        ├── Extract attachments (+ ZIP unpack, one level)
//        ├── Safety gate (executable/size block — delegates to quarantine on open)
//        ├── SHA-256 duplicate check (MailStore + LocalDuplicates pattern)
//        │
//        ▼
// Document Processor (MailClassifier.excerpts → AIContentReader/PDFInspector + OCR)
//        │
//        ▼
// AI Classification (local heuristics → +Jev/extractor merge when key is set)
//        │
//        ▼
// Rules Engine (user Rules + built-in automations)
//        │
//        ▼
// Finder DMS (attachments + .eml evidence filed under targetFolder, reminders)
//
// Privacy: local-first. Network (AI) only when the user pasted an OpenRouter
// key — same opt-in as AI Organizer. Connectors fetch only unseen Message-IDs
// after the first sync (incremental, no full-mailbox pulls).

// MARK: Connectors

/// A mail source. First sync may list everything; afterwards only unseen IDs
/// (webhook/push/IMAP UIDNext/historyId map to `seenIDs` + `since` here).
/// `source` is the local file behind the message (.eml drop) so sync can
/// archive it to Done after ingest; network connectors pass nil.
protocol MailConnector {
    func fetchNew(since: Date?, seenIDs: Set<String>) throws -> [(email: ParsedEmail, attachments: [ParsedAttachment], source: URL?)]
}

/// Local .eml folder (manual export, Mail.app drag&drop staging). The offline
/// path that works without OAuth; Gmail/Graph/IMAP connectors implement the
/// same protocol later and reuse the whole pipeline below. Defaults to the
/// single Email folder's Inbox (`MailFilingService.inboxDir()`).
struct EmlDirectoryConnector: MailConnector {
    var directory: URL = MailFilingService.inboxDir()

    func fetchNew(since: Date?, seenIDs: Set<String>) throws -> [(email: ParsedEmail, attachments: [ParsedAttachment], source: URL?)] {
        // NOTE: no mtime `since` filter here — file drops can carry any mtime
        // (bulk exports, re-drops) and older-than-last-sync files would become
        // invisible forever. Message-ID set is the dedup mechanism; listing +
        // parsing ~2k small files per sync is cheap enough to always be exact.
        _ = since
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let emls = files.filter { $0.pathExtension.lowercased() == "eml" }
            .sorted { (a, b) -> Bool in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
        var out: [(ParsedEmail, [ParsedAttachment], URL?)] = []
        for url in emls {
            guard let parsed = try? MailEmlParser.parse(url: url) else { continue }
            if seenIDs.contains(parsed.dedupID) { continue }
            out.append((parsed, parsed.attachments, url))
        }
        return out
    }
}

// MARK: Service

final class MailFilingService {
    static let shared = MailFilingService()
    private let workQueue = DispatchQueue(label: "FinderFlow.mailFiling", qos: .userInitiated)

    struct FilingOutcome {
        var record: MailInboxRecord?
        var duplicate: Bool = false
        var skippedReason: String?
    }

    /// Blocked before any filing (executables, absurd sizes). Real malware
    /// scanning stays with the OS (quarantine/XProtect on open); this gate
    /// only stops obviously unsafe or unmanageable payloads.
    static let blockedExtensions: Set<String> = ["exe", "bat", "cmd", "com", "scr", "msi", "ps1", "vbs", "js", "jse", "wsh", "wsf",
        "dmg", "pkg", "mpkg", "app", "command", "term", "terminal", "scpt", "scptd", "workflow", "action", "appex",
        "kext", "bundle", "plugin", "deb", "rpm"]
    static let maxAttachmentBytes: Int64 = 200 * 1024 * 1024

    // MARK: The single Email folder
    //
    // Sve preko maila je tu: `emailRoot()` is the one canonical place.
    // Drop raw .eml into Inbox, sync files content + evidence under the root
    // and archives the source .eml to Done — nothing mail-related lives
    // anywhere else. Overridable in UserDefaults (UserPreferences.mailRootKey).

    static func emailRoot() -> URL {
        if let custom = UserDefaults.standard.string(forKey: UserPreferences.mailRootKey), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FinderFlow/Email", isDirectory: true)
    }

    /// Dropzone: .eml files (Mail.app drag&drop, exports) waiting for sync.
    static func inboxDir() -> URL {
        emailRoot().appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Already-ingested source files — kept, never re-ingested.
    static func doneDir() -> URL {
        emailRoot().appendingPathComponent("Done", isDirectory: true)
    }

    static func ensureEmailDirs() {
        for dir in [emailRoot(), inboxDir(), doneDir()] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Sync (one folder in, everything filed)

    struct SyncResult {
        var ingested = 0
        var duplicates = 0
        var failed = 0
        var outcomes: [FilingOutcome] = []
    }

    /// Pulls unseen mail from `connector` (default: Email/Inbox), ingests each
    /// through the local pipeline into the Email root, and archives the source
    /// .eml to Done. Incremental: Message-IDs already in the store are skipped
    /// before any AI work.
    func sync(connector: MailConnector = EmlDirectoryConnector(),
              rules: [MailRule] = MailRuleStore.shared.rules,
              store: MailStore = .shared) -> SyncResult {
        Self.ensureEmailDirs()
        var result = SyncResult()
        let fetched: [(email: ParsedEmail, attachments: [ParsedAttachment], source: URL?)]
        do {
            fetched = try connector.fetchNew(since: store.lastSyncDate, seenIDs: store.allSeenMessageIDs())
        } catch {
            result.failed += 1
            return result
        }
        for item in fetched {
            let outcome = ingest(email: item.email, attachments: item.attachments,
                                 dmsRoot: Self.emailRoot(), rules: rules, store: store)
            result.outcomes.append(outcome)
            if outcome.duplicate { result.duplicates += 1 } else { result.ingested += 1 }
            if let src = item.source {
                archive(source: src)
            }
        }
        if !fetched.isEmpty {
            NotificationCenter.default.post(name: .refreshDirectory, object: Self.emailRoot())
        }
        // Sweep: .eml files whose Message-ID is already known (re-dropped,
        // re-sent) are archived to Done too, so Inbox never clogs with
        // files sync will always skip.
        if let dirConn = connector as? EmlDirectoryConnector {
            result.duplicates += sweepInbox(dirConn.directory, store: store)
        }
        Self.purgeStaging(store: store)
        return result
    }

    /// Archives already-seen .eml files out of the dropzone. Returns count.
    private func sweepInbox(_ dir: URL, store: MailStore) -> Int {
        let seen = store.allSeenMessageIDs()
        guard !seen.isEmpty else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [])) ?? []
        var swept = 0
        for url in files where url.pathExtension.lowercased() == "eml" {
            guard let parsed = try? MailEmlParser.parse(url: url),
                  seen.contains(parsed.dedupID) else { continue }
            archive(source: url)
            swept += 1
        }
        return swept
    }

    private func archive(source: URL) {
        let dest = Self.doneDir().appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: source)
            return
        }
        try? FileManager.default.moveItem(at: source, to: dest)
    }

    // MARK: Local pipeline (offline, synchronous)

    /// Full local pass: unpack → gate → dedup → classify → rules → store →
    /// file + reminders. AI upgrade (if key set) runs after via `upgradeWithAI`.
    func ingest(email: ParsedEmail, attachments: [ParsedAttachment],
                dmsRoot: URL = MailFilingService.emailRoot(), rules: [MailRule] = MailRuleStore.shared.rules,
                store: MailStore = .shared) -> FilingOutcome {
        // Unpack ZIPs one level ("ZIP → raspakuj i klasificiraj svaki dokument").
        var flat: [ParsedAttachment] = []
        for a in attachments {
            if a.filename.lowercased().hasSuffix(".zip"), let inner = Self.unpackZip(data: a.data) {
                flat += inner
            } else {
                flat.append(a)
            }
        }
        // Safety gate.
        flat = flat.filter { a in
            !Self.blockedExtensions.contains((a.filename as NSString).pathExtension.lowercased())
                && Int64(a.data.count) <= Self.maxAttachmentBytes
        }
        // Duplicate attachments → no new copy (keeps one inbox record anyway).
        let fresh = flat.filter { !store.hasHash($0.meta.sha256) }
        let excerptMap = MailClassifier.excerpts(for: fresh)
        let excerptText = excerptMap.values.joined(separator: " ")
        let thread = store.threadEntity(threadID: email.threadID)
        let mailMeta = EmailMessage(messageID: email.messageID, threadID: email.threadID,
                                    from: email.from, to: email.to, cc: email.cc,
                                    subject: email.subject, body: email.body, date: email.date,
                                    attachments: flat.map(\.meta), rawFilename: "")
        var suggestion = MailClassifier.localSuggestion(from: mailMeta, excerpts: excerptMap, thread: thread)
        let applied = MailRulesEngine.apply(rules: rules, mail: mailMeta, suggestion: suggestion, excerptText: excerptText)
        suggestion = applied.0

        var status = suggestion.status
        if mailMeta.attachments.isEmpty {
            // No documents: mail itself is the evidence ("Project correspondence → Linked").
            status = .linked
            suggestion.confidence = max(suggestion.confidence, 0.8)
            if suggestion.category.isEmpty { suggestion.category = "Correspondence" }
        }
        // Stage bytes only for mails that wait in the Inbox (<70%): filed /
        // reviewed / linked mails already live on disk, staging them would
        // duplicate every attachment byte in the store.
        if status == .needsClassification {
            for a in fresh { Self.stage(data: a.data, sha: a.meta.sha256) }
        }
        let result = store.ingest(email, suggestion: suggestion, status: status)
        guard let record = result.stored else {
            return FilingOutcome(record: nil, duplicate: true)
        }
        // File high-confidence mails now; <70% waits in Inbox until Accept.
        var mutable = record
        if status == .filed || status == .reviewSuggested || status == .linked {
            let filed = fileAttachments(fresh, email: email, record: record, suggestion: suggestion, dmsRoot: dmsRoot)
            mutable.filedPaths = filed
        }
        mutable.reminders = MailRulesEngine.reminders(for: mutable.mail, suggestion: suggestion)
        store.update(mutable)
        return FilingOutcome(record: mutable, duplicate: false)
    }

    // MARK: AI upgrade (opt-in, off-main)

    /// Re-runs classification through the organizer's models and refreshes the
    /// record. Uses Jev decisions + extractor when a Jev model is selected,
    /// else a single chat plan — same cascade as AIOrganizerModel.
    func upgradeWithAI(record: MailInboxRecord, attachments: [ParsedAttachment],
                       dmsRoot: URL, store: MailStore = .shared,
                       done: @escaping (MailInboxRecord) -> Void = { _ in }) {
        let ai = AIService.shared
        // `done` always fires (on main) — with the unchanged record when there
        // is nothing to send or the request fails — so callers can stop a spinner.
        guard ai.isKeySet else { done(record); return }
        workQueue.async {
            let entries = MailClassifier.inventoryEntries(for: attachments)
            guard !entries.isEmpty else { DispatchQueue.main.async { done(record) }; return }
            let keys = ai.apiKeys
            let model = ai.modelID
            var aiFacts: [AIDocFacts] = []
            var jevHints: [String: JevClassFacts] = [:]
            do {
                if AIService.isJevModel(model) {
                    let decisions = try ai.requestDecisions(entries: entries, keys: keys, model: model, folderName: "")
                    jevHints = decisions.facts
                    let plan = try ai.requestPlan(entries: entries, keys: keys, model: ai.extractionModel,
                                                  options: AIOrganizeOptions(renameFiles: false, useSubfolders: false),
                                                  jevHints: jevHints, nameByCode: true)
                    aiFacts = JevClassifier.merged(items: plan.items, jev: jevHints).map(\.facts)
                } else {
                    let plan = try ai.requestPlan(entries: entries, keys: keys, model: model,
                                                  options: AIOrganizeOptions(renameFiles: false, useSubfolders: false))
                    aiFacts = plan.items.map(\.facts)
                }
            } catch {
                for e in entries { try? FileManager.default.removeItem(at: e.url) }
                DispatchQueue.main.async { done(record) }
                return
            }
            var suggestion = record.suggestion
            for facts in aiFacts where !facts.isEmpty {
                suggestion = MailClassifier.mergeAI(suggestion, facts: facts,
                                                    senderDomainOrg: MailClassifier.organization(from: record.mail.from))
            }
            let excerptText = entries.compactMap(\.preview).joined(separator: " ")
            let applied = MailRulesEngine.apply(rules: MailRuleStore.shared.rules, mail: record.mail,
                                                suggestion: suggestion, excerptText: excerptText)
            suggestion = applied.0
            var updated = record
            updated.suggestion = suggestion
            if record.status == .needsClassification, suggestion.status != .needsClassification {
                updated.status = suggestion.status
                let filed = self.fileAttachments(attachments, email: nil, record: record, suggestion: suggestion, dmsRoot: dmsRoot)
                updated.filedPaths = filed
            }
            updated.reminders = MailRulesEngine.reminders(for: updated.mail, suggestion: suggestion)
            let frozen = updated
            DispatchQueue.main.async { store.update(frozen); done(frozen) }
            for e in entries { try? FileManager.default.removeItem(at: e.url) }
        }
    }

    // MARK: Batch enrichment + reorganization (Jev pass over the inbox)
    //
    // Local heuristics file first; Jev then enriches facts (issuer/buyer for
    // invoice direction, counterparties for contracts) and everything is
    // renamed + moved: invoices split Inbound (Valens plaća) / Outbound
    // (Valens naplaćuje), contracts all in one folder with strong names,
    // the rest by category. Sync, off-main for the network part.

    struct EnrichBatchItem {
        var record: MailInboxRecord
        var attachments: [ParsedAttachment]
    }

    /// Outbound = Valens naplaćuje (issuer), Inbound = Valens plaća (buyer),
    /// Unsorted = Valens-internal mail without clear facts.
    static func invoiceDirection(company: String, client: String, sender: String) -> String {
        if company.lowercased().contains("valens") { return "Outbound" }
        if client.lowercased().contains("valens") { return "Inbound" }
        if MailClassifier.organization(from: sender) == "Valens"
            || sender.lowercased().contains("valens.dev") { return "Unsorted" }
        return "Inbound"
    }

    static func reorganizeFolder(for s: MailFilingSuggestion, sender: String) -> String {
        switch s.documentType.lowercased() {
        case "invoice":
            return "Finance / Invoices / \(invoiceDirection(company: s.company, client: s.client, sender: sender))"
        case "proforma": return "Finance / Proforma"
        case "receipt": return "Finance / Receipts"
        case "statement": return "Finance / Statements"
        case "contract", "annex": return "Contracts"
        case "nda": return "Legal"
        case "cv": return "HR - Candidates"
        case "offer": return "Offers"
        case "correspondence": return "Correspondence"
        default: return ""
        }
    }

    /// Organizer facts for deterministic strong names. Contracts lead with
    /// the counterparty ("Ugovor - CyberArrow - 2026-09-22"), never Valens.
    static func namingFacts(for s: MailFilingSuggestion) -> AIDocFacts {
        var issuer = s.company, buyer = s.client
        if ["contract", "annex"].contains(s.documentType.lowercased()),
           issuer.lowercased().contains("valens"), !buyer.isEmpty {
            issuer = buyer
            buyer = s.company
        }
        return AIDocFacts(type: s.documentType, issuer: issuer,
                          number: s.facts["number"] ?? "",
                          date: s.facts["effective"] ?? "",
                          dueDate: s.facts["due_date"] ?? "",
                          currency: s.facts["currency"] ?? "",
                          amount: s.facts["amount"] ?? "",
                          title: s.project,
                          language: s.facts["language"] ?? "",
                          buyer: buyer)
    }

    /// Runs Jev decisions + extractor over many records in shared batches
    /// (one calls set per ~40 files, not per mail), merges facts into each
    /// record's suggestion and refreshes reminders. Persists per batch, so a
    /// killed run loses at most one batch. Synchronous — call off-main.
    @discardableResult
    func enrichBatch(items: [EnrichBatchItem], model: String, extractionModel: String,
                     keys: [String], store: MailStore,
                     progress: ((Int, Int) -> Void)? = nil) -> [MailInboxRecord] {
        let ai = AIService.shared
        var updated: [MailInboxRecord] = []
        var mergedIdx = Set<Int>()
        // Flatten with unique entry names (two mails may attach "scan.pdf").
        // Plain names, numbered on clash — models echo `from` verbatim, so no
        // prefixes that a small model might "clean" (that silently drops facts).
        var flat: [AIFileEntry] = []
        var keyByName: [String: (recordIdx: Int, filename: String)] = [:]
        var usedNames = Set<String>()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderFlow-enrich-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (ri, item) in items.enumerated() {
            for a in item.attachments {
                var name = a.filename
                if usedNames.contains(name.lowercased()) {
                    let (stem, ext) = splitItemName(name, isFolder: false)
                    var n = 2
                    while usedNames.contains((ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)").lowercased()) { n += 1 }
                    name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                }
                usedNames.insert(name.lowercased())
                keyByName[name] = (ri, a.filename)
                let url = tmp.appendingPathComponent(MailEmlParser.sanitizeFilename(name))
                try? a.data.write(to: url)
                let desc = AIContentReader.describe(url, size: Int64(a.data.count), modified: nil,
                                                    maxChars: 4000, includeContent: true)
                let ext = (a.filename as NSString).pathExtension.lowercased()
                flat.append(AIFileEntry(url: url, name: name,
                                        kind: ext.isEmpty ? "file" : ext.uppercased(),
                                        size: Int64(a.data.count),
                                        preview: desc.preview, details: desc.details))
            }
        }
        let jevPath = AIService.isJevModel(model)
        let batches = stride(from: 0, to: flat.count, by: 40).map { Array(flat[$0..<min($0 + 40, flat.count)]) }
        var factsByEntry: [String: AIDocFacts] = [:]
        func mergeRecord(_ ri: Int) {
            guard !mergedIdx.contains(ri) else { return }
            mergedIdx.insert(ri)
            let item = items[ri]
            var suggestion = item.record.suggestion
            let org = MailClassifier.organization(from: item.record.mail.from)
            for (name, loc) in keyByName where loc.recordIdx == ri {
                if let facts = factsByEntry[name], !facts.isEmpty {
                    suggestion = MailClassifier.mergeAI(suggestion, facts: facts, senderDomainOrg: org)
                }
            }
            var rec = item.record
            rec.suggestion = suggestion
            if rec.status == .needsClassification, suggestion.status != .needsClassification {
                rec.status = suggestion.status
            }
            rec.reminders = MailRulesEngine.reminders(for: rec.mail, suggestion: suggestion)
            store.update(rec)
            updated.append(rec)
        }
        for (bi, batch) in batches.enumerated() {
            progress?(bi + 1, batches.count)
            do {
                if jevPath {
                    let decisions = try ai.requestDecisions(entries: batch, keys: keys, model: model, folderName: "")
                    let plan = try ai.requestPlan(entries: batch, keys: keys, model: extractionModel,
                                                  options: AIOrganizeOptions(renameFiles: false, useSubfolders: false),
                                                  jevHints: decisions.facts, nameByCode: true)
                    for item in JevClassifier.merged(items: plan.items, jev: decisions.facts) {
                        factsByEntry[item.from] = item.facts
                    }
                } else {
                    let plan = try ai.requestPlan(entries: batch, keys: keys, model: model,
                                                  options: AIOrganizeOptions(renameFiles: false, useSubfolders: false))
                    for item in plan.items { factsByEntry[item.from] = item.facts }
                }
            } catch {
                continue // batch failed — local suggestions stand, never blocks the rest
            }
            // Persist records fully covered so far; a kill loses ≤1 batch.
            let have = Set(factsByEntry.keys)
            for (ri, item) in items.enumerated() where !mergedIdx.contains(ri) {
                let keys = keyByName.compactMap { $0.value.recordIdx == ri ? $0.key : nil }
                _ = item
                if !keys.isEmpty, keys.allSatisfy(have.contains) { mergeRecord(ri) }
            }
        }
        // Final sweep: merge the rest (failed batches keep local suggestions).
        for ri in items.indices { mergeRecord(ri) }
        try? FileManager.default.removeItem(at: tmp)
        return updated
    }

    struct ReorganizeResult {
        var moved = 0
        var renamed = 0
        var skipped = 0
        /// Every move made (from → to) and every file written from staged
        /// bytes — exactly what `undoReorganize` needs to put things back.
        var moves: [(from: String, to: String)] = []
        var created: [String] = []
    }

    /// Reverses one `reorganize`: moves files back where they were (in reverse
    /// order), sends files it created to the Trash (never deletes) and restores
    /// the record. Returns how many files could not be put back.
    @discardableResult
    func undoReorganize(previous: MailInboxRecord, result: ReorganizeResult, store: MailStore) -> Int {
        let fm = FileManager.default
        var failed = 0
        for m in result.moves.reversed() where m.from != m.to {
            guard fm.fileExists(atPath: m.to), !fm.fileExists(atPath: m.from) else { failed += 1; continue }
            try? fm.createDirectory(at: URL(fileURLWithPath: m.from).deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if (try? fm.moveItem(atPath: m.to, toPath: m.from)) == nil { failed += 1 }
        }
        for path in result.created where fm.fileExists(atPath: path) {
            if (try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) == nil { failed += 1 }
        }
        store.update(previous)
        NotificationCenter.default.post(name: .refreshDirectory, object: Self.emailRoot())
        return failed
    }

    /// Attachment bytes for a stored record, for the AI and reorganize passes:
    /// re-parsed from the .eml evidence kept in the store (ZIPs unpacked and
    /// the safety gate applied, like ingest), else from staged bytes.
    func attachments(for record: MailInboxRecord, store: MailStore = .shared) -> [ParsedAttachment] {
        var out: [ParsedAttachment] = []
        let raw = store.storeDir.appendingPathComponent("raw").appendingPathComponent(record.mail.rawFilename)
        if !record.mail.rawFilename.isEmpty, let parsed = try? MailEmlParser.parse(url: raw) {
            for a in parsed.attachments {
                if a.filename.lowercased().hasSuffix(".zip"), let inner = Self.unpackZip(data: a.data) {
                    out += inner
                } else {
                    out.append(a)
                }
            }
            out = out.filter { a in
                !Self.blockedExtensions.contains((a.filename as NSString).pathExtension.lowercased())
                    && Int64(a.data.count) <= Self.maxAttachmentBytes
            }
        }
        if out.isEmpty {
            out = record.mail.attachments.compactMap { meta in
                Self.stagedData(sha: meta.sha256).map {
                    ParsedAttachment(filename: meta.filename, mimeType: meta.mimeType, data: $0)
                }
            }
        }
        return out
    }

    /// Moves a record's files to its reorganize folder with strong names
    /// (never overwrites — clashes are numbered). Evidence .eml travels with
    /// its documents. Returns updated record + counts.
    func reorganize(_ record: MailInboxRecord, attachments: [ParsedAttachment],
                    dmsRoot: URL, store: MailStore) -> (record: MailInboxRecord, result: ReorganizeResult) {
        var res = ReorganizeResult()
        var rec = record
        // Repair entities baked before the filename-entity guard
        // ("Critical_VALENS doo" as client) — drop filename-like values.
        let docExts = ["pdf", "doc", "docx", "xls", "xlsx", "jpg", "jpeg", "png", "zip", "eml", "txt"]
        func repaired(_ s: String) -> String {
            if s.contains("_") { return "" }
            if docExts.contains((s as NSString).pathExtension.lowercased()) { return "" }
            return s
        }
        rec.suggestion.company = repaired(rec.suggestion.company)
        rec.suggestion.client = repaired(rec.suggestion.client)
        rec.suggestion.project = repaired(rec.suggestion.project)
        let folder = Self.reorganizeFolder(for: rec.suggestion, sender: rec.mail.from)
        guard !folder.isEmpty else { return (rec, res) }
        var dest = dmsRoot
        for component in folder.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let clean = AINameRules.sanitizeFolder(component)
            guard !clean.isEmpty else { continue }
            dest = dest.appendingPathComponent(clean, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.map { $0.lowercased() } ?? [])
        var paths: [String] = []
        let facts = Self.namingFacts(for: rec.suggestion)
        // Existing filed files: move + rename.
        let existing = rec.filedPaths.filter { !$0.hasSuffix(".eml") && FileManager.default.fileExists(atPath: $0) }
        for old in existing {
            let url = URL(fileURLWithPath: old)
            let strong = AINameComposer.compose(facts: facts, original: url.lastPathComponent)
                ?? url.lastPathComponent
            let safe = AINameRules.sanitizeName(strong, original: url.lastPathComponent) ?? url.lastPathComponent
            taken.remove(url.lastPathComponent.lowercased())
            let target = unique(name: safe, taken: &taken, dir: dest)
            do {
                if target.path != old {
                    try FileManager.default.moveItem(atPath: old, toPath: target.path)
                    res.moves.append((from: old, to: target.path))
                }
                taken.insert(target.lastPathComponent.lowercased())
                paths.append(target.path)
                res.moved += 1
                if target.lastPathComponent != url.lastPathComponent { res.renamed += 1 }
            } catch { res.skipped += 1 }
        }
        // Staged bytes (inbox-held): write with strong names.
        for a in attachments {
            let strong = AINameComposer.compose(facts: facts, original: a.filename) ?? a.filename
            let safe = AINameRules.sanitizeName(strong, original: a.filename) ?? a.filename
            let target = unique(name: safe, taken: &taken, dir: dest)
            do {
                try a.data.write(to: target)
                res.created.append(target.path)
                taken.insert(target.lastPathComponent.lowercased())
                paths.append(target.path)
                res.moved += 1
                if target.lastPathComponent != a.filename { res.renamed += 1 }
            } catch { res.skipped += 1 }
        }
        // Evidence .eml travels with its documents.
        let evidence = rec.filedPaths.filter { $0.hasSuffix(".eml") && FileManager.default.fileExists(atPath: $0) }
        for old in evidence {
            let url = URL(fileURLWithPath: old)
            taken.remove(url.lastPathComponent.lowercased())
            let target = unique(name: url.lastPathComponent, taken: &taken, dir: dest)
            do {
                if target.path != old {
                    try FileManager.default.moveItem(atPath: old, toPath: target.path)
                    res.moves.append((from: old, to: target.path))
                }
                taken.insert(target.lastPathComponent.lowercased())
                paths.append(target.path)
            } catch { continue }
        }
        if paths.isEmpty { res.skipped += 1; return (rec, res) }
        rec.filedPaths = paths
        rec.suggestion.targetFolder = folder
        if rec.status == .needsClassification { rec.status = .filed }
        store.update(rec)
        // Remove source parents left empty (legacy per-entity folders collapse
        // into the single target). Only inside the DMS root, never the root.
        var parents = Set<String>()
        for old in existing.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            + evidence.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().path }) {
            let std = URL(fileURLWithPath: old).standardizedFileURL.path
            if std.hasPrefix(dmsRoot.standardizedFileURL.path + "/") && std != dest.standardizedFileURL.path {
                parents.insert(std)
            }
        }
        for p in parents {
            if (try? FileManager.default.contentsOfDirectory(atPath: p))?.isEmpty == true {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
        NotificationCenter.default.post(name: .refreshDirectory, object: dest)
        return (rec, res)
    }

    // MARK: Filing writes

    /// Writes attachments + .eml evidence copy under dmsRoot/targetFolder.
    /// Names go through AINameRules (extension kept); AI-composed names arrive
    /// via suggestion when the AI upgrade ran first. Never overwrites: taken
    /// names are numbered like AIPlanner.
    @discardableResult
    func fileAttachments(_ attachments: [ParsedAttachment], email: ParsedEmail?,
                         record: MailInboxRecord, suggestion: MailFilingSuggestion,
                         dmsRoot: URL) -> [String] {
        var folder = dmsRoot
        if !suggestion.targetFolder.isEmpty {
            for component in suggestion.targetFolder.split(separator: "/").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let clean = AINameRules.sanitizeFolder(component)
                guard !clean.isEmpty else { continue }
                folder = folder.appendingPathComponent(clean, isDirectory: true)
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.map { $0.lowercased() } ?? [])
        var paths: [String] = []
        // Evidence object first: the mail itself.
        if let email {
            let base = "MAIL - \(MailEmlParser.sanitizeFilename(email.subject.isEmpty ? email.messageID : email.subject)).eml"
            let dest = unique(name: base, taken: &taken, dir: folder)
            if (try? email.rawData.write(to: dest)) != nil {
                taken.insert(dest.lastPathComponent.lowercased())
                paths.append(dest.path)
            }
        }
        for a in attachments {
            let proposed = Self.composeName(original: a.filename, suggestion: suggestion)
            let safe = AINameRules.sanitizeName(proposed, original: a.filename) ?? a.filename
            let dest = unique(name: safe, taken: &taken, dir: folder)
            do {
                try a.data.write(to: dest)
                taken.insert(dest.lastPathComponent.lowercased())
                paths.append(dest.path)
            } catch { continue }
        }
        if !paths.isEmpty {
            NotificationCenter.default.post(name: .refreshDirectory, object: folder)
        }
        return paths
    }

    /// "Signed document → zamijeni draft finalnom verzijom": flags when the
    /// target folder already holds a draft-like sibling (never deletes).
    func draftReplacementNote(for filename: String, in folder: URL) -> String? {
        let stem = ((filename as NSString).deletingPathExtension).lowercased()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for s in siblings where s.lowercased() != filename.lowercased() {
            let ls = s.lowercased()
            if ls.contains("draft") || ls.contains("nacrt"),
               stem.split(separator: " ").first.map({ ls.contains($0) }) ?? false {
                return "Signed version replaces draft “\(s)” — review before removing the draft"
            }
        }
        return nil
    }

    // MARK: Staging (bytes for later Accept)

    static func stagingDir() -> URL {
        MailStore.shared.storeDir.appendingPathComponent("staging", isDirectory: true)
    }

    static func stage(data: Data, sha: String) {
        guard !sha.isEmpty else { return }
        let dir = stagingDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(sha)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
    }

    static func stagedData(sha: String) -> Data? {
        guard !sha.isEmpty else { return nil }
        return try? Data(contentsOf: stagingDir().appendingPathComponent(sha))
    }

    /// Deletes staged bytes no inbox-bound record needs anymore (their files
    /// are already in the DMS). Returns reclaimed bytes.
    @discardableResult
    static func purgeStaging(store: MailStore = .shared) -> Int64 {
        let needed = Set(store.records.filter { $0.status == .needsClassification }
            .flatMap(\.mail.attachments).map(\.sha256).filter { !$0.isEmpty })
        let dir = stagingDir()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var freed: Int64 = 0
        for url in files where !needed.contains(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += Int64(size) }
        }
        return freed
    }

    // MARK: Reminders query

    func dueReminders(store: MailStore = .shared, withinDays days: Int = 14) -> [MailReminder] {
        let horizon = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return store.records.flatMap(\.reminders).filter { !$0.done && $0.dueDate <= horizon }
            .sorted { $0.dueDate < $1.dueDate }
    }

    // MARK: Helpers (pure)

    static func composeName(original: String, suggestion: MailFilingSuggestion) -> String {
        // Prefer deterministic organizer naming when facts exist; else keep.
        let facts = AIDocFacts(type: suggestion.documentType, issuer: suggestion.company,
                               date: suggestion.facts["effective"] ?? "",
                               dueDate: suggestion.facts["due_date"] ?? "",
                               currency: suggestion.facts["currency"] ?? "",
                               amount: suggestion.facts["amount"] ?? "",
                               title: suggestion.project, buyer: suggestion.client)
        if let composed = AINameComposer.compose(facts: facts, original: original), composed != original {
            return composed
        }
        return original
    }

    private func unique(name: String, taken: inout Set<String>, dir: URL) -> URL {
        if !taken.contains(name.lowercased()) { return dir.appendingPathComponent(name) }
        let (stem, ext) = splitItemName(name, isFolder: false)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return dir.appendingPathComponent(candidate) }
            n += 1
        }
    }

    /// One-level ZIP unpack via /usr/bin/unzip (present on macOS). Returns nil
    /// when unzip is unavailable — caller keeps the .zip as a single file.
    static func unpackZip(data: Data) -> [ParsedAttachment]? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("FinderFlow-zip-\(UUID().uuidString)")
        let zipURL = tmp.appendingPathComponent("in.zip")
        let outDir = tmp.appendingPathComponent("out")
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: zipURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zipURL.path)
            // Pre-validate listing: reject absolute paths and ".." escapes before
            // unzip writes anything (unzip would otherwise write outside outDir).
            if let entries = zipListing(zipURL: zipURL), !zipEntriesSafe(entries) {
                return nil
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-q", "-o", zipURL.path, "-d", outDir.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            // Post-extract containment (same barrier as ArchiveService): everything
            // must stay inside outDir, symlinks are never followed.
            let outRoot = outDir.standardizedFileURL.path
            var out: [ParsedAttachment] = []
            var totalBytes = 0
            if let enumerator = FileManager.default.enumerator(at: outDir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                for case let url as URL in enumerator {
                    let p = url.standardizedFileURL.path
                    guard p.hasPrefix(outRoot + "/") else { return nil }
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                    // A symlink swapped in between check and read (TOCTOU): re-check.
                    if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { continue }
                    guard let d = try? Data(contentsOf: url), !d.isEmpty else { continue }
                    totalBytes += d.count
                    // Zip-bomb guard: 500 files / 500MB total per archive.
                    guard out.count < 500, totalBytes <= 500 * 1024 * 1024 else { return nil }
                    let name = MailEmlParser.sanitizeFilename(url.lastPathComponent)
                    guard !Self.blockedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                    out.append(ParsedAttachment(filename: name, mimeType: "application/octet-stream", data: d))
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            return out.isEmpty ? nil : out
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }

    private static func zipListing(zipURL: URL) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", zipURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.components(separatedBy: .newlines)
    }

    private static func zipEntriesSafe(_ entries: [String]) -> Bool {
        for raw in entries {
            let e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.isEmpty { continue }
            if e.hasPrefix("/") || e.hasPrefix("\\") { return false }
            if e.contains("\0") || e.rangeOfCharacter(from: .controlCharacters) != nil { return false }
            let parts = e.split(separator: "/").map(String.init)
            if parts.contains("..") || parts.contains(".") && parts.count == 1 && parts[0] == "." { return false }
            // Windows drive / UNC prefixes.
            if e.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return false }
            if e.hasPrefix("\\\\") { return false }
        }
        return true
    }
}
