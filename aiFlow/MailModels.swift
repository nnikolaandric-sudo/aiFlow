import Foundation

// MARK: - Mail ingestion models (MAIL-01/02/03)
//
// Email → DMS ingestion built ON TOP of the existing AI organizer — no new AI
// backend. Attachments flow through the same pipeline as organized files:
//   LocalDuplicates.sha256 (dedup) → AIContentReader/PDFInspector (excerpt+OCR)
//   → Jev decisions + generative extractor (AIService) → AIDocFacts
//   → AINameComposer / AINameRules (safe names) → FileOperationsService.
// This file is only data + confidence gating; parsing lives in EmlParser,
// persistence in MailStore, classification in MailClassifier, rules in
// MailRulesEngine, orchestration in MailFilingService.

/// One attachment as stored from a parsed email.
struct MailAttachmentMeta: Codable, Equatable, Identifiable {
    var id: String { sha256.isEmpty ? filename : sha256 }
    /// Original filename from the MIME part.
    var filename: String
    var mimeType: String
    var size: Int64
    /// SHA-256 of the decoded bytes — duplicate check before saving.
    var sha256: String
    /// File extension lowercased, no dot.
    var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
    /// True for ZIPs — filing unpacks and classifies each entry.
    var isArchive: Bool { fileExtension == "zip" }
}

/// Email as evidence object: the mail itself is stored (.eml) next to filed
/// attachments so "pokaži mi svu komunikaciju gdje je X potvrdio dug" can
/// search mail + attachment together.
struct EmailMessage: Codable, Equatable, Identifiable {
    var id: String { messageID.isEmpty ? fallbackID : messageID }
    /// RFC5322 Message-ID (dedup key for incremental sync).
    var messageID: String
    var threadID: String
    var from: String
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    var date: Date
    /// Attachment descriptors (bytes live in the DMS after filing).
    var attachments: [MailAttachmentMeta]
    /// Raw .eml filename under the store dir (evidence object).
    var rawFilename: String

    var fallbackID: String { "\(from)|\(subject)|\(date.timeIntervalSince1970)" }
    var hasAttachments: Bool { !attachments.isEmpty }
}

/// Where a mail sits in the confidence pipeline.
enum MailFilingStatus: String, Codable, Equatable {
    /// <70% — stays in Inbox, waits for manual classification.
    case needsClassification = "inbox"
    /// 70–98% — filed but flagged for review.
    case reviewSuggested = "review"
    /// ≥98% or accepted by user — filed.
    case filed = "filed"
    /// No attachments: mail linked to an entity as correspondence.
    case linked = "linked"
    /// Exact duplicate (Message-ID or sha256 already seen) — no new copy.
    case duplicate = "duplicate"

    var label: String {
        switch self {
        case .needsClassification: return "Inbox"
        case .reviewSuggested: return "Review"
        case .filed: return "✓ Filed"
        case .linked: return "✓ Linked"
        case .duplicate: return "Duplicate"
        }
    }
}

/// AI suggestion for one mail — shown right of the Mail Inbox row.
struct MailFilingSuggestion: Codable, Equatable {
    var company: String = ""
    var client: String = ""
    var project: String = ""
    /// DMS category folder, e.g. "Contracts / Clients".
    var category: String = ""
    /// Document type in AIDocFacts vocabulary (contract, invoice, cv…).
    var documentType: String = ""
    /// 0…1 combined confidence (Jev + heuristics + rules).
    var confidence: Double = 0
    /// Target folder relative to the DMS root.
    var targetFolder: String = ""
    /// Per-attachment facts reused from the organizer (shown in review).
    var facts: [String: String] = [:]
    var note: String = ""

    /// Spec gating: 98% auto-file, 70–98% file+review flag, <70% inbox.
    var status: MailFilingStatus {
        if confidence >= MailFilingPolicy.autoFileThreshold { return .filed }
        if confidence >= MailFilingPolicy.reviewThreshold { return .reviewSuggested }
        return .needsClassification
    }

    var entity: String {
        [company, client, project].first(where: { !$0.isEmpty }) ?? ""
    }
}

enum MailFilingPolicy {
    static let autoFileThreshold = 0.98
    static let reviewThreshold = 0.70
}

/// A reminder derived from a document date (expiry, invoice due).
struct MailReminder: Codable, Equatable, Identifiable {
    var id: String
    var mailID: String
    var kind: String // "expiry" | "invoice_due"
    var dueDate: Date
    var note: String
    var done: Bool = false
}

/// One inbox record: mail + suggestion + status + linked entity.
struct MailInboxRecord: Codable, Equatable, Identifiable {
    var id: String { mail.id }
    var mail: EmailMessage
    var suggestion: MailFilingSuggestion
    var status: MailFilingStatus
    var filedPaths: [String] = []
    var reminders: [MailReminder] = []
    var receivedAt: Date = Date()
}
