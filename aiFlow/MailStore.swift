import Foundation
import Combine

// MARK: - Mail Inbox store (MAIL-01)
//
// Local JSON persistence under Application Support/FinderFlow/MailInbox.
// Dedup keys: Message-ID (mail) + SHA-256 (attachment bytes) — a re-sent mail
// or re-attached file never creates a second copy. Threads group by
// In-Reply-To/References, else normalized subject. Incremental sync: connectors
// report only Message-IDs newer than `lastSyncDate` / unseen IDs; `ingest`
// drops already-seen ones before any AI work happens.

final class MailStore: ObservableObject {
    static let shared = MailStore()

    @Published private(set) var records: [MailInboxRecord] = []
    @Published private(set) var lastSyncDate: Date?

    private let queue = DispatchQueue(label: "FinderFlow.mailStore", qos: .utility)
    private var seenMessageIDs = Set<String>()
    private var seenHashes = Set<String>()

    var storeDir: URL {
        // Tests/harness: FF_MAIL_DIR keeps the index, raw .eml and staging out
        // of the user's Application Support.
        if let dir = ProcessInfo.processInfo.environment["FF_MAIL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FinderFlow/MailInbox", isDirectory: true)
    }
    private var indexFile: URL { storeDir.appendingPathComponent("index.json") }
    private var rawDir: URL { storeDir.appendingPathComponent("raw") }

    init() { load() }

    // MARK: Queries

    var inbox: [MailInboxRecord] { records.filter { $0.status == .needsClassification } }
    var review: [MailInboxRecord] { records.filter { $0.status == .reviewSuggested } }
    var filed: [MailInboxRecord] { records.filter { $0.status == .filed || $0.status == .linked } }

    func threadSiblings(of record: MailInboxRecord) -> [MailInboxRecord] {
        records.filter { $0.mail.threadID == record.mail.threadID && $0.id != record.id }
    }

    /// Local evidence search over mail + attachment facts: "pokaži mi svu
    /// komunikaciju gdje je SCE potvrdio dug" / "svi mailovi za CyberArrow
    /// liability cap" — no network, mail body + subjects + suggestion fields.
    func search(_ query: String) -> [MailInboxRecord] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return records }
        let terms = q.split(separator: " ").map(String.init)
        return records.filter { r in
            let hay = ([r.mail.subject, r.mail.body, r.mail.from]
                       + r.mail.to + [r.suggestion.company, r.suggestion.client,
                                      r.suggestion.project, r.suggestion.category,
                                      r.suggestion.documentType]
                       + r.suggestion.facts.values).joined(separator: " ").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: Ingest

    struct IngestResult {
        var stored: MailInboxRecord?
        /// Message-ID or attachment hash already seen — no new copy.
        var duplicate: Bool = false
    }

    /// Stores a parsed mail + raw .eml bytes. Drops Message-ID replays and
    /// all-duplicate-attachment mails before any AI work (incremental-sync
    /// friendly: connectors call this only for unseen IDs).
    func ingest(_ parsed: ParsedEmail, suggestion: MailFilingSuggestion? = nil,
                status: MailFilingStatus = .needsClassification) -> IngestResult {
        if allSeenMessageIDs().contains(parsed.dedupID) {
            return IngestResult(stored: nil, duplicate: true)
        }
        try? FileManager.default.createDirectories(at: rawDir)
        let mid = parsed.messageID
        let stamp = ISO8601DateFormatter().string(from: parsed.date).replacingOccurrences(of: ":", with: "-")
        let safe = MailEmlParser.sanitizeFilename(parsed.subject.prefix(40).isEmpty ? "mail" : String(parsed.subject.prefix(40)))
        let rawName = "\(stamp)-\(abs(parsed.dedupID.hashValue) % 10000)-\(safe).eml"
        try? parsed.rawData.write(to: rawDir.appendingPathComponent(rawName))
        let metas = parsed.attachments.map(\.meta)
        let mail = EmailMessage(messageID: mid, threadID: parsed.threadID, from: parsed.from,
                                to: parsed.to, cc: parsed.cc, subject: parsed.subject,
                                body: parsed.body, date: parsed.date,
                                attachments: metas, rawFilename: rawName)
        let record = MailInboxRecord(mail: mail, suggestion: suggestion ?? MailFilingSuggestion(),
                                     status: status)
        queue.sync {
            seenMessageIDs.insert(parsed.dedupID)
            for m in metas where !m.sha256.isEmpty { seenHashes.insert(m.sha256) }
            records.insert(record, at: 0)
            lastSyncDate = Date()
        }
        save()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        return IngestResult(stored: record, duplicate: false)
    }

    func hasHash(_ sha: String) -> Bool {
        guard !sha.isEmpty else { return false }
        return queue.sync { seenHashes.contains(sha) }
    }

    /// Message-IDs already ingested — connectors skip these (incremental sync).
    func allSeenMessageIDs() -> Set<String> {
        queue.sync { seenMessageIDs }
    }

    func lastSyncDateSnapshot() -> Date? {
        queue.sync { lastSyncDate }
    }

    func update(_ record: MailInboxRecord) {
        // Batch AI passes run off-main; @Published state only changes on main.
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.update(record) }
            return
        }
        queue.sync {
            if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record }
        }
        save()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// Thread inheritance: a reply's attachments default to the same entity as
    /// the thread's last filed mail ("attachment iz postojećeg threada →
    /// automatski poveži s istim predmetom").
    func threadEntity(threadID: String) -> MailFilingSuggestion? {
        queue.sync {
            records.first(where: { $0.mail.threadID == threadID && ($0.status == .filed || $0.status == .linked) })?.suggestion
        }
    }

    func recordsSnapshot() -> [MailInboxRecord] {
        queue.sync { records }
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var records: [MailInboxRecord]
        var lastSyncDate: Date?
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexFile),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        records = p.records.sorted { $0.mail.date > $1.mail.date }
        lastSyncDate = p.lastSyncDate
        seenMessageIDs = Set(records.map { $0.mail.messageID.isEmpty ? $0.mail.fallbackID : $0.mail.messageID })
        seenHashes = Set(records.flatMap(\.mail.attachments).map(\.sha256).filter { !$0.isEmpty })
    }

    private func save() {
        let snapshot = queue.sync { (records, lastSyncDate) }
        let p = Persisted(records: snapshot.0, lastSyncDate: snapshot.1)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectories(at: storeDir)
        try? data.write(to: indexFile, options: .atomic)
    }

    /// For tests / re-import: clears in-memory + disk index (raw .eml kept).
    func resetForTests() {
        queue.sync { records = []; seenMessageIDs = []; seenHashes = []; lastSyncDate = nil }
        try? FileManager.default.removeItem(at: indexFile)
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
}

private extension FileManager {
    func createDirectories(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
}
