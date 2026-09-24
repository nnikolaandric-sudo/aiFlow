import Foundation
import AppKit
import SwiftUI
import Security
import os

// MARK: - AI Organizer (OpenRouter, opt-in, budget-first)
//
// Reads the files of the folder you're viewing (or the selected files) and
// lets an AI model propose better names (+ optional subfolders, + optional
// duplicate cleanup to Trash) by CONTENT, not just by the old filename. The
// plan is reviewed in AIOrganizerSheet before anything moves (unless turned
// off in Settings — duplicate deletions always wait for review); every run
// is a single Undo, taken names get numbered (never overwritten), and spend
// is tracked locally against a monthly cap.
//
// Privacy: OFF by default. Nothing leaves the Mac until you paste an
// OpenRouter key in Settings → AI Organizer. Then only the chosen files'
// names, sizes, dates and (optionally) short excerpts go to that model.

/// One file the model may rename.
struct AIFileEntry {
    let url: URL
    let name: String
    let kind: String
    let size: Int64
    /// Short content excerpt — text, PDF, Word/RTF (nil for other types,
    /// online-only files, or when excerpts are off in Settings).
    let preview: String?
    /// Local facts that help naming: modified date, photo date/camera/size,
    /// PDF pages and title (see AIContentReader).
    var details: [String] = []
}

/// One rename/move row from the model (cleaned up later by AIPlanner).
struct AIPlanItem: Equatable {
    /// Original filename (matches inventory exactly).
    let from: String
    /// New bare filename (extension included).
    let name: String
    /// Subfolder under the organized folder, or "" for no move.
    let folder: String
    /// What the model read out of the document (shown in the review).
    var facts = AIDocFacts()
    /// When true (and the delete-duplicates option is on), the file is trashed.
    var isDelete = false
    /// Name of the file that is kept.
    var duplicateOf = ""
    /// Why the model thinks it's a duplicate.
    var deleteReason = ""
}

enum AIError: LocalizedError {
    case noKey
    case noModel
    /// A decisions (System One) model sent to chat/completions — OpenRouter
    /// answers 400 and points at the System One endpoint instead.
    case jevNotChat(model: String)
    case network(Error)
    case http(status: Int, message: String)
    case badKey
    case noCredits
    case rateLimited
    case badJSON
    /// Prose (or nothing) instead of a plan; carries the start of the reply.
    case badReply(snippet: String)
    /// The reply hit the output limit before the list ended.
    case truncated
    case overBudget(estimate: Double, cap: Double)
    case unknownPrice(model: String)
    case empty
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Set your OpenRouter API key in Settings → AI Organizer first."
        case .noModel:
            return "Pick a model in Settings → AI Organizer first (tap a suggested model)."
        case .jevNotChat(let model):
            return "“\(model)” is a decisions model — it classifies via OpenRouter's System One endpoint, not chat. In the organizer this is automatic: pick Jev in Settings → AI Organizer and run Analyze."
        case .network(let e):
            return "AI request failed: \(e.localizedDescription)"
        case .http(let status, let message):
            return message.isEmpty ? "AI request failed (HTTP \(status))." : "AI request failed (HTTP \(status)): \(message)"
        case .badKey:
            return "OpenRouter rejected the API key (HTTP 401). Check Settings → AI Organizer — when several keys are saved, every one of them was rejected."
        case .noCredits:
            return "OpenRouter reports no credits left (HTTP 402) on all saved keys — free models need no credits, paid ones do. Add a fallback key in Settings → AI Organizer or wait for the limit to reset."
        case .rateLimited:
            return "OpenRouter is throttling this model (HTTP 429) on all saved keys, even after waiting it out. Wait a minute, pick another model, or add a fallback key in Settings → AI Organizer."
        case .badJSON:
            return "The model returned something that isn't a rename list. Try again, or pick another model in Settings → AI Organizer."
        case .badReply(let snippet):
            return snippet.isEmpty
                ? "The model sent an empty reply. Try again, or pick another model in Settings → AI Organizer."
                : "The model didn't return a rename list — it replied: “\(snippet)”. Try again, or pick another model in Settings → AI Organizer."
        case .truncated:
            return "The model used up its reply budget before finishing the list. Raise “Reply budget” or lower “Files per request” in Settings → AI Organizer, or pick another model."
        case .overBudget(let estimate, let cap):
            return String(format: "Estimated cost $%.4f would pass your $%.2f monthly cap. Raise it in Settings → AI Organizer.", estimate, cap)
        case .unknownPrice(let model):
            return "Couldn't verify the price for “\(model)” — the model list has no entry for that exact slug, so the run was blocked instead of spending blind. Check the slug in Settings → AI Organizer (tap a suggested model, e.g. typesafe/jev-1.13) and try again."
        case .empty:
            return "The model proposed no renames."
        case .cancelled:
            return "Stopped."
        }
    }
}

final class AIService: ObservableObject {
    static let shared = AIService()

    /// Default: free tier, JSON-friendly instruct model (fleet rotates —
    /// change any time in Settings, any OpenRouter slug works).
    static let defaultModel = "google/gemma-4-31b-it:free"
    static let suggestedModels = [
        // Free tier.
        "google/gemma-4-31b-it:free",
        "google/gemma-4-26b-a4b-it:free",
        "z-ai/glm-5.2:free",
        "dots-studio/dots-3-note-preview:free",
        // Cheap paid chat models (verified slugs + input $/M, Sep 2026 —
        // re-check openrouter.ai, prices move).
        "qwen/qwen3.7-flash",              // ≈$0.03/M
        "inclusionai/ling-3.0-flash",      // ≈$0.02/M
        "deepseek/deepseek-v4-flash-0731", // ≈$0.04/M
        "z-ai/glm-4.7-flash",              // ≈$0.06/M
        "meta/muse-spark-1.3-contributor", // ≈$0.10/M
        "google/gemini-2.5-flash-lite",    // ≈$0.10/M
        "xiaomi/mimo-v2.6-flash",          // ≈$0.14/M
        "z-ai/glm-5.3-flash",              // ≈$0.15/M
        // Jev (TypeSafe System One): decision model for classification/extraction.
        // Concrete slug — the website alias "~typesafe/jev-latest" isn't an API id.
        "typesafe/jev-1.13",
    ]
    /// Files per request. Small batches keep free models quick and their JSON
    /// complete; a big folder simply takes more requests.
    static let defaultMaxFiles = 40
    static let defaultPreviewBytes = 4000
    static let defaultMonthlyCapUSD = 2.0
    /// Most tokens one reply may use, thinking included.
    static let defaultMaxReplyTokens = 32_000

    // MARK: Jev (TypeSafe System One) — classifier/extractor stage
    //
    // Jev is a structured decision model (not a prose generator): it returns
    // typed choices rather than free text, which makes it ideal for document
    // classification (vrsta, jezik) and field extraction (broj, valuta, datum,
    // dospeće, iznos…). Naming is then composed deterministically in code
    // (AINameComposer) instead of asking the model to invent filenames.
    // Published rate: $0.042 / 1M input tokens, $0 output, 32K context.
    // The fallbacks below apply until OpenRouter's /models API lists Jev —
    // without them a paid model would fail closed (unknownPrice).

    /// True for TypeSafe Jev slugs ("typesafe/jev-1.13", future jev-x.y …).
    static func isJevModel(_ id: String) -> Bool {
        id.lowercased().contains("jev")
    }
    static let jevFallbackPricePerToken = (prompt: 0.042 / 1_000_000, completion: 0.0)
    static let jevFallbackContext = 32_000

    /// Where the keys come from: the Keychain in the app; tests swap
    /// `keysProvider` so they never touch the user's Keychain.
    /// Key 1 is the primary, the rest are fallbacks tried in order when a
    /// key hits its limit (429/402) or is rejected (401).
    private static var _keysProvider: () -> [String] = { AIKeychain.loadAll() }
    static var keysProvider: () -> [String] {
        get { _keysProvider }
        set { _keysProvider = newValue }
    }
    /// Legacy single-key injection (kept for existing callers/tests):
    /// getting returns the primary key, setting replaces all keys with one.
    static var keyProvider: () -> String? {
        get { { Self._keysProvider().first } }
        set {
            let single = newValue
            _keysProvider = {
                guard let k = single() else { return [] }
                let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? [] : [t]
            }
        }
    }

    static let log = Logger(subsystem: "com.finderflow.app", category: "AIOrganizer")

    /// One line about the latest model reply — HTTP status, finish reason,
    /// token and size counts, never the key or file names — shown with
    /// errors so a failing run can be reported and diagnosed.
    var lastReplySummary: String {
        summaryLock.lock(); defer { summaryLock.unlock() }
        return storedReplySummary
    }
    private let summaryLock = NSLock()
    private var storedReplySummary = ""

    private func setLastReplySummary(_ summary: String) {
        summaryLock.lock()
        storedReplySummary = summary
        summaryLock.unlock()
    }

    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "ffAIModel") }
    }
    /// Chat model that extracts strings in the Jev cascade (Jev itself only
    /// returns typed decisions). Default is the free tier; paste a paid slug
    /// when :free models throttle you — paid accounts still hit free-model
    /// limits. Empty (after trim) falls back to `defaultModel`.
    @Published var extractionModelID: String {
        didSet { UserDefaults.standard.set(extractionModelID, forKey: "ffAIExtractionModel") }
    }
    /// Effective extraction slug (trimmed, never empty, never a decisions
    /// model — Jev would answer 400 on chat, so it falls back to default).
    var extractionModel: String {
        let t = extractionModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !Self.isJevModel(t) else { return Self.defaultModel }
        return t
    }
    @Published var maxFiles: Int {
        didSet { UserDefaults.standard.set(maxFiles, forKey: "ffAIMaxFiles") }
    }
    @Published var previewBytes: Int {
        didSet { UserDefaults.standard.set(previewBytes, forKey: "ffAIPreviewBytes") }
    }
    @Published var monthlyCapUSD: Double {
        didSet { UserDefaults.standard.set(monthlyCapUSD, forKey: "ffAIMonthlyCap") }
    }
    @Published var maxReplyTokens: Int {
        didSet { UserDefaults.standard.set(maxReplyTokens, forKey: "ffAIMaxReplyTokens") }
    }
    /// Show the plan for review before anything moves.
    @Published var reviewBeforeApply: Bool {
        didSet { UserDefaults.standard.set(reviewBeforeApply, forKey: "ffAIReviewFirst") }
    }
    /// Send content excerpts and photo/PDF facts, not only names, sizes and dates.
    @Published var sendPreviews: Bool {
        didSet { UserDefaults.standard.set(sendPreviews, forKey: "ffAISendPreviews") }
    }
    @Published var redactPersonalData: Bool {
        didSet { UserDefaults.standard.set(redactPersonalData, forKey: "ffAIRedactPersonalData") }
    }
    // Last choices in the organizer sheet.
    @Published var renameFiles: Bool {
        didSet { UserDefaults.standard.set(renameFiles, forKey: "ffAIRenameFiles") }
    }
    @Published var useSubfolders: Bool {
        didSet { UserDefaults.standard.set(useSubfolders, forKey: "ffAIUseSubfolders") }
    }
    @Published var deleteDuplicates: Bool {
        didSet { UserDefaults.standard.set(deleteDuplicates, forKey: "ffAIDeleteDuplicates") }
    }
    @Published var instructions: String {
        didSet { UserDefaults.standard.set(instructions, forKey: "ffAIInstructions") }
    }

    init() {
        let d = UserDefaults.standard
        let savedModel = d.string(forKey: "ffAIModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelID = savedModel.isEmpty ? Self.defaultModel : savedModel
        extractionModelID = d.string(forKey: "ffAIExtractionModel") ?? Self.defaultModel
        let mf = d.integer(forKey: "ffAIMaxFiles")
        maxFiles = mf > 0 ? mf : Self.defaultMaxFiles
        let pb = d.integer(forKey: "ffAIPreviewBytes")
        previewBytes = pb > 0 ? pb : Self.defaultPreviewBytes
        let cap = d.double(forKey: "ffAIMonthlyCap")
        monthlyCapUSD = cap > 0 ? cap : Self.defaultMonthlyCapUSD
        let rt = d.integer(forKey: "ffAIMaxReplyTokens")
        maxReplyTokens = rt > 0 ? rt : Self.defaultMaxReplyTokens
        reviewBeforeApply = d.object(forKey: "ffAIReviewFirst") as? Bool ?? true
        sendPreviews = d.object(forKey: "ffAISendPreviews") as? Bool ?? true
        redactPersonalData = d.object(forKey: "ffAIRedactPersonalData") as? Bool ?? true
        renameFiles = d.object(forKey: "ffAIRenameFiles") as? Bool ?? true
        useSubfolders = d.object(forKey: "ffAIUseSubfolders") as? Bool ?? true
        deleteDuplicates = d.object(forKey: "ffAIDeleteDuplicates") as? Bool ?? false
        instructions = d.string(forKey: "ffAIInstructions") ?? ""
    }

    // MARK: Keys (Keychain, like the Discord bot token)

    /// All saved keys in order: primary first, then fallbacks.
    var apiKeys: [String] { Self.keysProvider() }
    /// The key actually sent first.
    var apiKey: String? { apiKeys.first }
    /// Fallback keys tried when the primary hits a limit.
    var fallbackKeys: [String] { Array(apiKeys.dropFirst()) }
    var isKeySet: Bool { !apiKeys.isEmpty }
    /// Number of saved keys (primary + fallbacks).
    var keyCount: Int { apiKeys.count }
    /// "••••abcd" — last 4 chars only, safe for the UI and logs.
    static func maskedKey(_ key: String) -> String {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "—" }
        return t.count <= 8 ? "••••••••" : "••••" + t.suffix(4)
    }
    func setKey(_ key: String) {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            AIKeychain.delete()
        } else {
            AIKeychain.save(t)
        }
        objectWillChange.send()
    }
    /// Replaces the whole ordered list (primary + fallbacks).
    func setKeys(_ keys: [String]) {
        AIKeychain.saveAll(keys)
        objectWillChange.send()
    }
    /// Appends one fallback key; returns false when empty/duplicate.
    @discardableResult
    func addFallbackKey(_ key: String) -> Bool {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !apiKeys.contains(t) else { return false }
        AIKeychain.saveAll(apiKeys + [t])
        objectWillChange.send()
        return true
    }
    func removeKey(at index: Int) {
        var keys = apiKeys
        guard keys.indices.contains(index) else { return }
        keys.remove(at: index)
        AIKeychain.saveAll(keys)
        objectWillChange.send()
    }
    func clearKeys() {
        AIKeychain.delete()
        objectWillChange.send()
    }

    // MARK: Spend tracking (local, per calendar month)

    private static func monthKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    func monthSpend() -> Double {
        (UserDefaults.standard.dictionary(forKey: "ffAISpend") as? [String: Double])?[Self.monthKey()] ?? 0
    }

    func recordSpend(_ usd: Double) {
        guard usd > 0 else { return }
        var d = (UserDefaults.standard.dictionary(forKey: "ffAISpend") as? [String: Double]) ?? [:]
        d[Self.monthKey(), default: 0] += usd
        UserDefaults.standard.set(d, forKey: "ffAISpend")
        objectWillChange.send()
    }

    func resetSpend() {
        var d = (UserDefaults.standard.dictionary(forKey: "ffAISpend") as? [String: Double]) ?? [:]
        d.removeValue(forKey: Self.monthKey())
        UserDefaults.standard.set(d, forKey: "ffAISpend")
        objectWillChange.send()
    }

    // MARK: Pricing + model limits (public /models endpoint, cached 24h)

    private struct CachedPricing: Codable {
        let fetched: Date
        /// model -> [prompt, completion] in USD per token (OpenRouter's unit).
        let prices: [String: [Double]]
        /// model -> [context length, max completion tokens]; 0 = unknown.
        var limits: [String: [Int]]? = nil
        /// Models that accept `response_format` (JSON mode).
        var jsonMode: [String]? = nil
        /// Reasoning models whose reasoning a request may switch off.
        var reasoningOptional: [String]? = nil
    }

    private func cachedTable() -> CachedPricing? {
        guard let data = UserDefaults.standard.data(forKey: "ffAIPricing"),
              let c = try? JSONDecoder().decode(CachedPricing.self, from: data),
              Date().timeIntervalSince(c.fetched) < 24 * 3600 else { return nil }
        return c
    }

    private func cachedPrices() -> [String: [Double]] { cachedTable()?.prices ?? [:] }

    /// Refresh prices and model limits. Throws on network failure (one retry —
    /// a blip must not surface as "unknown price"); bad payloads return
    /// silently and keep the previous cache. Unknown prices count as zero,
    /// unknown limits fall back to defaults.
    func refreshPricing() throws {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        let data: Data
        do {
            data = try syncGET(url: url)
        } catch {
            Thread.sleep(forTimeInterval: 2)
            data = try syncGET(url: url)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return }
        var prices: [String: [Double]] = [:]
        var limits: [String: [Int]] = [:]
        var jsonMode: [String] = []
        var reasoningOptional: [String] = []
        for m in list {
            guard let id = m["id"] as? String else { continue }
            if let p = m["pricing"] as? [String: Any] {
                let prompt = Double(p["prompt"] as? String ?? "") ?? 0
                let completion = Double(p["completion"] as? String ?? "") ?? 0
                prices[id] = [prompt, completion]
            }
            let context = (m["context_length"] as? NSNumber)?.intValue ?? 0
            let maxOut = ((m["top_provider"] as? [String: Any])?["max_completion_tokens"] as? NSNumber)?.intValue ?? 0
            limits[id] = [context, maxOut]
            let params = m["supported_parameters"] as? [String] ?? []
            if params.contains("response_format") { jsonMode.append(id) }
            if params.contains("reasoning"), (m["reasoning"] as? [String: Any])?["mandatory"] as? Bool == false {
                reasoningOptional.append(id)
            }
        }
        let table = CachedPricing(fetched: Date(), prices: prices, limits: limits, jsonMode: jsonMode,
                                  reasoningOptional: reasoningOptional)
        if let data = try? JSONEncoder().encode(table) {
            UserDefaults.standard.set(data, forKey: "ffAIPricing")
        }
    }

    /// Fetch the /models table when it's missing, stale, or from a build that
    /// didn't store limits yet. Call off-main.
    func refreshModelTableIfNeeded() {
        if let table = cachedTable(), table.limits != nil, table.reasoningOptional != nil { return }
        try? refreshPricing()
    }

    struct ModelInfo {
        var contextLength: Int?
        var maxOutput: Int?
        var supportsJSONMode = false
        var canDisableReasoning = false
    }

    /// Limits from the cached /models table (no network); Jev fallback when
    /// the table doesn't list it yet (nil fields = unknown).
    func modelInfo(_ id: String) -> ModelInfo {
        if let table = cachedTable(), let l = table.limits?[id], l.count == 2 {
            return ModelInfo(contextLength: l[0] > 0 ? l[0] : nil,
                             maxOutput: l[1] > 0 ? l[1] : nil,
                             supportsJSONMode: table.jsonMode?.contains(id) ?? false,
                             canDisableReasoning: table.reasoningOptional?.contains(id) ?? false)
        }
        if Self.isJevModel(id) {
            // No JSON-mode switch until the table confirms it — the prompt
            // asks for JSON-only and the parser tolerates prose anyway.
            return ModelInfo(contextLength: Self.jevFallbackContext, maxOutput: nil,
                             supportsJSONMode: false, canDisableReasoning: false)
        }
        guard let table = cachedTable() else { return ModelInfo() }
        let l = table.limits?[id] ?? []
        return ModelInfo(contextLength: l.count == 2 && l[0] > 0 ? l[0] : nil,
                         maxOutput: l.count == 2 && l[1] > 0 ? l[1] : nil,
                         supportsJSONMode: table.jsonMode?.contains(id) ?? false,
                         canDisableReasoning: table.reasoningOptional?.contains(id) ?? false)
    }

    /// USD per token. Unknown models return (0,0) — callers must check
    /// `hasKnownPrice` first for paid models (fail-closed, never spend blind).
    /// Jev falls back to its published rate until the /models table lists it.
    func priceForModel(_ id: String) -> (prompt: Double, completion: Double) {
        if let p = cachedPrices()[id], p.count == 2 { return (p[0], p[1]) }
        if Self.isJevModel(id) { return Self.jevFallbackPricePerToken }
        return (0, 0)
    }

    /// True when the pricing table knows this model (or it's a :free model,
    /// or Jev with its published fallback rate).
    func hasKnownPrice(_ id: String) -> Bool {
        if id.hasSuffix(":free") { return true }
        if Self.isJevModel(id) { return true }
        if let p = cachedPrices()[id], p.count == 2 { return true }
        return false
    }

    /// OpenRouter lists prices per token — dividing by a million on top made
    /// every paid request look free, so the monthly cap never kicked in.
    func costUSD(promptTokens: Int, completionTokens: Int, model: String) -> Double {
        let p = priceForModel(model)
        return Double(promptTokens) * p.prompt + Double(completionTokens) * p.completion
    }

    // MARK: Inventory (what the model sees)

    /// Files eligible for AI rename: regular files only — no folders (a
    /// folder's content defines it, renaming it blind is rude), no packages,
    /// no symlinks, no hidden dotfiles. Sorted by name for deterministic
    /// prompts. Reads small excerpts (AIContentReader) — call off-main.
    func buildInventory(urls: [URL], cancel: AICancelToken? = nil,
                        progress: ((Int, Int) -> Void)? = nil) -> [AIFileEntry] {
        // Room for an invoice's header block (issuer, number, date) and more.
        let maxChars = max(500, min(previewBytes, 6000))
        let includeContent = sendPreviews
        var out: [AIFileEntry] = []
        for (index, url) in urls.enumerated() {
            if cancel?.isCancelled == true { return [] }
            progress?(index + 1, urls.count)
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                                            .fileSizeKey, .contentModificationDateKey]),
                  v.isDirectory != true, v.isPackage != true, v.isSymbolicLink != true else { continue }
            let size = Int64(v.fileSize ?? 0)
            let content = AIContentReader.describe(url, size: size, modified: v.contentModificationDate,
                                                   maxChars: maxChars, includeContent: includeContent)
            let preview = content.preview.map { redactPersonalData ? AIPrivacy.redact($0) : $0 }
            let ext = url.pathExtension.lowercased()
            out.append(AIFileEntry(
                url: url,
                name: name,
                kind: ext.isEmpty ? "file" : ext.uppercased(),
                size: size,
                preview: preview,
                details: content.details
            ))
        }
        return out.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: Prompt (pure — testable)

    static func systemPrompt(options: AIOrganizeOptions = AIOrganizeOptions()) -> String {
        var rules = [
            "Read each excerpt the way a person would: work out what kind of document it is (invoice/faktura/račun, receipt, pro-forma/predračun, offer/ponuda, order, contract/ugovor, annex/aneks, statement/izvod, report, letter, CV, ticket, photo, screenshot…) and extract AS MUCH structured data as you can find. NUMBER = Broj fakture / Broj računa / Broj dokumenta / Faktura br. / Poziv na broj; SUPPLIER/ISSUER = Dobavljač / Prodavac / Izdavalac (the company that issued it — header/logo, NOT the Kupac/buyer); BUYER = Kupac / Klijent / Primalac (only to tell them apart); ISSUE DATE = Datum izdavanja / Datum fakture / Datum računa / Datum prometa (the date it was issued, YYYY-MM-DD); DUE DATE = Datum dospeća / Rok plaćanja / Valuta / Due date (YYYY-MM-DD, report it even when it equals the issue date); CURRENCY = Valuta / Oznaka valute (RSD, EUR, USD…); AMOUNT = Iznos / Ukupno za plaćanje (copy the total as written); TITLE = Naziv / Predmet / Opis usluge (short subject); LANGUAGE = Jezik dokumenta (sr, en, de…). For naming NEVER use due date or modified date — only the issue date. Excerpts marked \"text read by OCR\" may contain small recognition errors. Never invent facts that aren't in the name, excerpt or details.",
            "Keep every file extension exactly as it is.",
            "Build names from those facts. INVOICES FIRST: always \"<Tip> <broj> - <dobavljač> - <YYYY-MM-DD>\" when you have them, e.g. \"Faktura 123-45 - Telekom Srbija - 2024-03-12\" or \"Invoice 2024-0317 - Primjer d.o.o. - 2024-03-12\". Tip follows the document's language (Faktura / Račun / Predračun / Ponuda for Serbian, Invoice / Receipt / Pro-forma / Offer for English) unless the user's instructions say otherwise. If one part is missing keep the other two (\"Faktura 123 - Telekom Srbija\"). Contracts/annexes: \"<Contract> - <other party or subject> - <YYYY-MM-DD>\". Anything else: \"<what it is> - <who or what it's about> - <YYYY-MM-DD>\". Copy numbers, PIBs, IDs and company names exactly as written.",
            "Return every fact you found: \"type\" (one lowercase English word: invoice, receipt, proforma, offer, order, contract, annex, statement, report, letter, photo, screenshot or other — Serbian Faktura/Račun = invoice), \"issuer\" (= Dobavljač/supplier, NOT Kupac), \"number\" (= Broj fakture), \"date\" (= Datum izdavanja, YYYY-MM-DD, never due date), \"due_date\" (= Datum dospeća, YYYY-MM-DD), \"currency\" (RSD/EUR/USD…), \"amount\" (Ukupno kako piše), \"title\" (= Naziv/predmet), \"language\" (sr/en/de…), \"buyer\" (= Kupac, only when present); use \"\" for anything you couldn't find. Add \"confidence\" as an object with a 0..1 score for each extracted field and \"source_pages\" as an object with page numbers when the excerpt makes them knowable; do not invent page numbers.",
            "No emoji, no \"/\" or \":\" in names, and never start a name with \".\".",
            "List only files that change (new name, folder, or duplicate marked for deletion); leave every other file out.",
        ]
        if options.useSubfolders {
            rules.append("\"folder\" groups related files into one short category folder (1–3 words, Title Case, e.g. \"Invoices\", \"Screenshots\", \"Tax 2024\"). Reuse a known subfolder when one fits and spell a group's folder the same way every time. Only create a folder that gets at least 2 files; \"\" keeps a file where it is.")
        } else {
            rules.append("Never move files: \"folder\" is always \"\".")
        }
        if !options.renameFiles {
            rules.append("Don't rename: \"name\" is always the exact current filename; only choose folders.")
        }
        if options.deleteDuplicates {
            rules.append("Duplicates: when two or more files are the same document (identical size + identical excerpt, or the same number/issuer/date — also compare due_date, amount, currency and buyer when present — such as the same invoice, or names like \"copy\", \"(1)\", \" 2\"), keep ONE (the clearest name) and mark the rest with \"delete\": true, \"duplicate_of\": \"<kept filename exactly as listed>\" and a short \"reason\" (e.g. \"Same invoice 2024-0317, same size\"). Never mark ALL copies — always keep at least one per group. When in doubt, don't mark it.")
        } else {
            rules.append("Never delete: always omit \"delete\" (or set it to false) — duplicates are kept.")
        }
        let numbered = rules.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        You are FinderFlow's file organizer. You get the files of ONE folder and return a plan that makes it tidy and easy to search.
        Rules:
        \(numbered)
        Reply with ONLY this JSON — no markdown fences, no commentary:
        {"files":[{"from":"exact current filename","name":"new filename","folder":"","delete":false,"duplicate_of":"","reason":"","type":"","issuer":"","number":"","date":"","due_date":"","currency":"","amount":"","title":"","language":"","buyer":"","confidence":{},"source_pages":{}}]}
        """
    }

    /// Facts-only extractor for the Jev cascade (generative chat model): Jev
    /// already classified type/language/currency via System One, so this
    /// prompt extracts every string field and never invents filenames or
    /// deletions — naming and duplicate matching happen in code.
    static func extractionSystemPrompt(options: AIOrganizeOptions = AIOrganizeOptions()) -> String {
        var rules = [
            "Read each excerpt the way a person would and extract AS MUCH structured data as you can find. NUMBER = Broj fakture / Broj računa / Broj dokumenta / Poziv na broj; ISSUER = Dobavljač / Prodavac / Izdavalac (header/logo, NOT Kupac); BUYER = Kupac / Klijent; DATE = Datum izdavanja / Datum fakture / Datum prometa (YYYY-MM-DD); DUE_DATE = Datum dospeća / Rok plaćanja / Valuta (YYYY-MM-DD); CURRENCY = Valuta (RSD, EUR, USD…); AMOUNT = Iznos / Ukupno kako piše; TITLE = Naziv / Predmet; LANGUAGE = Jezik (sr, en, de…); TYPE = one lowercase English word (invoice, receipt, proforma, offer, order, contract, annex, statement, report, letter, photo, screenshot or other). A “Jev classification” block lists type/language/currency Jev already decided — trust it over your own guess for those three fields. Excerpts marked \"text read by OCR\" may contain small errors. Never invent a value — use \"\" when absent. Add \"confidence\" as an object with a 0..1 score for each extracted field and \"source_pages\" as an object with page numbers when the excerpt makes them knowable; do not invent page numbers.",
            "Do NOT invent filenames: \"name\" is always the exact current filename (copy of \"from\"). aiFlow composes the new name from the facts.",
            "Return one object per file where you found at least \"type\" or one other fact; leave files you couldn't read out. Use \"\" for every fact you couldn't find.",
            "No emoji. Keep every file extension exactly as it is (keep \"name\" == \"from\" untouched).",
        ]
        if options.useSubfolders {
            rules.append("\"folder\" groups related files into one short category folder (1–3 words, Title Case, e.g. \"Invoices\", \"Screenshots\", \"Tax 2024\"). Reuse a known subfolder when one fits and spell a group's folder the same way every time. Only create a folder that gets at least 2 files; \"\" keeps a file where it is.")
        } else {
            rules.append("Never move files: \"folder\" is always \"\".")
        }
        // Duplicates are matched in code on (issuer, number, date) — never flag deletes.
        rules.append("Never delete: always omit \"delete\" (or set it to false) — duplicates are matched in code.")
        let numbered = rules.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        You are FinderFlow's document reader. You get the files of ONE folder and return typed facts per file — no prose, no invented names.
        Rules:
        \(numbered)
        Reply with ONLY this JSON — no markdown fences, no commentary:
        {"files":[{"from":"exact current filename","name":"exact current filename","folder":"","type":"","issuer":"","number":"","date":"","due_date":"","currency":"","amount":"","title":"","language":"","buyer":"","confidence":{},"source_pages":{}}]}
        """
    }

    static func userPrompt(entries: [AIFileEntry], context: AIPromptContext = AIPromptContext(),
                           options: AIOrganizeOptions = AIOrganizeOptions(),
                           jevHints: [String: JevClassFacts] = [:], nameByCode: Bool = false) -> String {
        var lines: [String] = []
        if !context.folderName.isEmpty { lines.append("Folder: \(context.folderName)") }
        if options.useSubfolders {
            let known = context.knownFolders.prefix(60)
            lines.append("Known subfolders: " + (known.isEmpty ? "none" : known.joined(separator: ", ")))
        }
        let guidance = options.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidance.isEmpty {
            lines.append("User instructions (follow them unless they break a rule): \(guidance)")
        }
        if options.deleteDuplicates, !nameByCode {
            // Facts-only path: duplicates are matched in code, never flagged.
            lines.append("Find duplicates: yes — flag them with \"delete\": true for Trash (keep one per group).")
        }
        if !jevHints.isEmpty {
            lines.append("Jev classification (trust it over your own guess for these fields):")
            for e in entries {
                guard let j = jevHints[e.name], !j.isEmpty else { continue }
                var h: [String] = []
                if !j.type.isEmpty { h.append("type=\(j.type)") }
                if !j.language.isEmpty { h.append("language=\(j.language)") }
                if !j.currency.isEmpty { h.append("currency=\(j.currency)") }
                if !h.isEmpty { lines.append("- \(e.name): " + h.joined(separator: ", ")) }
            }
        }
        lines.append("Files (\(entries.count)):")
        let sizes = ByteCountFormatter()
        sizes.countStyle = .file
        for e in entries {
            var line = "- \(e.name) | " + ([e.kind, sizes.string(fromByteCount: e.size)] + e.details).joined(separator: " | ")
            if let p = e.preview, !p.isEmpty {
                line += "\n  excerpt: \(p.prefix(6000))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Plan request (sync — call off-main)

    struct PlanResult {
        let items: [AIPlanItem]
        let promptTokens: Int
        let completionTokens: Int
        let costUSD: Double
        /// The reply hit the output limit; `items` are the complete rows before the cut.
        var truncated = false
    }

    /// Asks the model for one batch's plan. Retries throttling (429) and busy
    /// providers (5xx) with backoff, asks once more when the reply isn't a
    /// usable list, and reports progress through `onEvent` (off-main). An
    /// empty plan — nothing to change — is a valid result, not an error.
    func requestPlan(entries: [AIFileEntry], key: String, model: String,
                     options: AIOrganizeOptions = AIOrganizeOptions(),
                     context: AIPromptContext = AIPromptContext(),
                     jevHints: [String: JevClassFacts] = [:], nameByCode: Bool = false,
                     cancel: AICancelToken? = nil,
                     onEvent: ((AIRequestEvent) -> Void)? = nil) throws -> PlanResult {
        try requestPlan(entries: entries, keys: [key], model: model, options: options,
                        context: context, jevHints: jevHints, nameByCode: nameByCode,
                        cancel: cancel, onEvent: onEvent)
    }

    /// Same as above, but with fallback keys: keys are tried in order and
    /// the next one takes over immediately when a key is rate-limited (429),
    /// out of credits (402) or rejected (401) — bez čekanja/retry-a na mrtvom
    /// ključu. Retry sa backoff-om samo za zauzet provider (5xx, isti ključ).
    /// Throws the last key's error when every key fails.
    /// `jevHints`/`nameByCode` drive the Jev cascade: a generative model
    /// extracts strings with Jev's verdicts as hints, names composed in code.
    func requestPlan(entries: [AIFileEntry], keys: [String], model: String,
                     options: AIOrganizeOptions = AIOrganizeOptions(),
                     context: AIPromptContext = AIPromptContext(),
                     jevHints: [String: JevClassFacts] = [:], nameByCode: Bool = false,
                     cancel: AICancelToken? = nil,
                     onEvent: ((AIRequestEvent) -> Void)? = nil) throws -> PlanResult {
        // Pasted slugs often carry a stray space — that broke price lookup
        // AND the API call with a confusing error. Clean it once, up front.
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.noModel }
        let clean = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw AIError.noKey }
        // Jev is a decisions model — chat/completions answers 400 telling us
        // to use the System One endpoint. The organizer's Jev cascade calls
        // requestDecisions instead; fail here with the reason, not HTTP 400.
        if Self.isJevModel(model) { throw AIError.jevNotChat(model: model) }
        let system = nameByCode ? Self.extractionSystemPrompt(options: options) : Self.systemPrompt(options: options)
        let user = Self.userPrompt(entries: entries, context: context, options: options,
                                   jevHints: jevHints, nameByCode: nameByCode)
        let info = modelInfo(model)
        // ~3 characters per token. The reply budget comes from Settings (32k
        // by default) so models that think before they write still have room
        // for the list; each model's own output and context limits cap it.
        let promptTokens = (system.count + user.count) / 3
        var maxTokens = max(1_024, maxReplyTokens)
        if let limit = info.maxOutput { maxTokens = min(maxTokens, limit) }
        if let window = info.contextLength { maxTokens = max(1_024, min(maxTokens, window - promptTokens - 256)) }
        // Paid models: fail BEFORE spending when the expected cost would break
        // the monthly cap. Replies rarely use the whole budget, and the real
        // charge is recorded afterwards. Free models skip this.
        if !model.hasSuffix(":free") {
            if hasKnownPrice(model) {
                // Cached price suffices — refresh opportunistically.
                try? refreshPricing()
            } else {
                // No cached price: must fetch. A network failure throws as
                // itself (offline) instead of masking as "unknown price".
                try refreshPricing()
            }
            // Fail-closed: bez cene se ne procenjuje 0 (cap se nikad ne bi
            // okino za placeni model kad /models padne) — blokiraj jasno.
            guard hasKnownPrice(model) else { throw AIError.unknownPrice(model: model) }
            let expectedReply = min(maxTokens, 2_000 + entries.count * 150)
            let est = costUSD(promptTokens: promptTokens, completionTokens: expectedReply, model: model)
            if monthSpend() + est > monthlyCapUSD {
                throw AIError.overBudget(estimate: est, cap: monthlyCapUSD)
            }
        }
        var lastError: Error = AIError.noKey
        var rateLimitWaits = 0
        for (keyIndex, key) in clean.enumerated() {
            while true {
                do {
                    return try requestPlanWithKey(entries: entries, key: key, keyIndex: keyIndex, keyTotal: clean.count,
                                                  model: model, options: options, system: system, user: user,
                                                  info: info, promptTokens: promptTokens, maxTokens: maxTokens,
                                                  cancel: cancel, onEvent: onEvent)
                } catch {
                    lastError = error
                    if cancel?.isCancelled == true { throw AIError.cancelled }
                    if keyIndex < clean.count - 1, let reason = Self.fallbackReason(for: error) {
                        Self.log.info("plan \(model, privacy: .public): key \(keyIndex + 1)/\(clean.count) \(reason, privacy: .public), switching to key \(keyIndex + 2)")
                        onEvent?(.switchedKey(reason: reason, index: keyIndex + 2, total: clean.count))
                        break  // next key
                    }
                    // No keys left: only a rate limit is worth waiting out
                    // (free-model throttles usually clear within a minute).
                    if case AIError.rateLimited = error,
                       Self.takeRateLimitWait(attempt: rateLimitWaits, cancel: cancel, onEvent: onEvent) {
                        rateLimitWaits += 1
                        continue  // same key again
                    }
                    if cancel?.isCancelled == true { throw AIError.cancelled }
                    throw error
                }
            }
        }
        throw lastError
    }

    /// Backoff for an exhausted-keys rate limit. Returns true when the caller
    /// should retry the same key, false when attempts are spent (or Stop was
    /// pressed — the caller then throws .cancelled). Emits .retrying so the
    /// status shows the countdown.
    private static func takeRateLimitWait(attempt: Int, cancel: AICancelToken?,
                                          onEvent: ((AIRequestEvent) -> Void)?) -> Bool {
        let schedule: [Double] = [10, 30, 60]
        guard attempt < schedule.count else { return false }
        let wait = schedule[attempt]
        Self.log.info("rate-limited on all keys, waiting \(Int(wait))s (attempt \(attempt + 1) of \(schedule.count))")
        onEvent?(.retrying(reason: "Rate limited — waiting for the limit to reset",
                           wait: wait, attempt: attempt + 1, of: schedule.count))
        if let cancel { return cancel.sleep(wait) }
        Thread.sleep(forTimeInterval: wait)
        return true
    }

    // MARK: System One decisions (Jev — sync, call off-main)

    /// Jev verdicts for one batch, keyed by entry name.
    struct JevDecisionsResult {
        let facts: [String: JevClassFacts]
        let costUSD: Double
        let inputTokens: Int
        let outputTokens: Int
    }

    /// Classifies a batch with Jev via OpenRouter's System One endpoint
    /// (POST /api/v1/systemone — decisions models answer 400 on
    /// chat/completions). One fan-out call per batch; oversized payloads
    /// split in halves automatically. Keys rotate like requestPlan.
    func requestDecisions(entries: [AIFileEntry], keys: [String], model: String,
                          folderName: String = "",
                          cancel: AICancelToken? = nil,
                          onEvent: ((AIRequestEvent) -> Void)? = nil) throws -> JevDecisionsResult {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.noModel }
        let clean = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw AIError.noKey }
        if JevClassifier.encodedSize(entries: entries, folderName: folderName) > JevClassifier.maxBodyBytes {
            guard entries.count > 1 else {
                throw AIError.http(status: 413, message: "Classification payload too large — lower “Files per request” in Settings → AI Organizer.")
            }
            let mid = entries.count / 2
            let a = try requestDecisions(entries: Array(entries[..<mid]), keys: clean, model: model,
                                         folderName: folderName, cancel: cancel, onEvent: onEvent)
            let b = try requestDecisions(entries: Array(entries[mid...]), keys: clean, model: model,
                                         folderName: folderName, cancel: cancel, onEvent: onEvent)
            return JevDecisionsResult(facts: a.facts.merging(b.facts) { current, _ in current },
                                      costUSD: a.costUSD + b.costUSD,
                                      inputTokens: a.inputTokens + b.inputTokens,
                                      outputTokens: a.outputTokens + b.outputTokens)
        }
        // Budget gate first (paid model): rough estimate, fail-closed.
        if !model.hasSuffix(":free") {
            guard hasKnownPrice(model) else { throw AIError.unknownPrice(model: model) }
            let est = JevClassifier.estimatedCost(entries: entries, folderName: folderName,
                                                  promptPricePerToken: priceForModel(model).prompt)
            if monthSpend() + est > monthlyCapUSD {
                throw AIError.overBudget(estimate: est, cap: monthlyCapUSD)
            }
        }
        var lastError: Error = AIError.noKey
        var rateLimitWaits = 0
        for (keyIndex, key) in clean.enumerated() {
            while true {
                do {
                    return try requestDecisionsWithKey(entries: entries, key: key, keyIndex: keyIndex, keyTotal: clean.count,
                                                       model: model, folderName: folderName, cancel: cancel, onEvent: onEvent)
                } catch {
                    lastError = error
                    if cancel?.isCancelled == true { throw AIError.cancelled }
                    if keyIndex < clean.count - 1, let reason = Self.fallbackReason(for: error) {
                        Self.log.info("decisions \(model, privacy: .public): key \(keyIndex + 1)/\(clean.count) \(reason, privacy: .public), switching to key \(keyIndex + 2)")
                        onEvent?(.switchedKey(reason: reason, index: keyIndex + 2, total: clean.count))
                        break  // next key
                    }
                    // No keys left: only a rate limit is worth waiting out.
                    if case AIError.rateLimited = error,
                       Self.takeRateLimitWait(attempt: rateLimitWaits, cancel: cancel, onEvent: onEvent) {
                        rateLimitWaits += 1
                        continue  // same key again
                    }
                    if cancel?.isCancelled == true { throw AIError.cancelled }
                    throw error
                }
            }
        }
        throw lastError
    }

    /// One System One call with a single key (no rotation — requestDecisions
    /// owns that). Sync — call off-main.
    private func requestDecisionsWithKey(entries: [AIFileEntry], key: String, keyIndex: Int, keyTotal: Int,
                                         model: String, folderName: String,
                                         cancel: AICancelToken? = nil,
                                         onEvent: ((AIRequestEvent) -> Void)? = nil) throws -> JevDecisionsResult {
        let questions = JevClassifier.questions(entries: entries)
        let body: [String: Any] = ["model": model,
                                   "state": JevClassifier.state(entries: entries, folderName: folderName),
                                   "questions": questions]
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/systemone")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("aiFlow", forHTTPHeaderField: "X-Title")
        req.timeoutInterval = 120
        var retries = 0
        var succeeded = false
        var outputChars = 0
        var trackedPrompt = 0
        var trackedCompletion = 0
        var trackedCost = 0.0
        let payloadText = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? model
        let startedAt = Date()
        defer {
            AIExecutionLog.shared.record(task: "jev", model: model, fileCount: entries.count,
                                         inputChars: payloadText.count, outputChars: outputChars,
                                         promptTokens: trackedPrompt > 0 ? trackedPrompt : questions.count * 20,
                                         completionTokens: trackedCompletion > 0 ? trackedCompletion : outputChars / 4,
                                         costUSD: trackedCost,
                                         latencyMS: Int(Date().timeIntervalSince(startedAt) * 1_000),
                                         success: succeeded, payload: payloadText)
        }

        while true {
            if cancel?.isCancelled == true { throw AIError.cancelled }
            let res = try syncPOST(request: req, body: try JSONSerialization.data(withJSONObject: body), cancel: cancel)
            let json = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any]
            let errorObject = json?["error"] as? [String: Any]
            let status = res.status
            if status == 429 {
                // Rate limit je po ključu — odmah sljedeći ključ.
                throw AIError.rateLimited
            }
            if (500...599).contains(status) || status == 524 {
                // Zauzet provider: retry isti ključ sa backoff-om.
                guard retries < 3 else {
                    throw AIError.http(status: status, message: errorObject?["message"] as? String ?? "")
                }
                let wait = Self.retryDelay(headers: res.headers, attempt: retries)
                retries += 1
                Self.log.info("decisions \(model, privacy: .public): HTTP \(status), retry \(retries) in \(wait)s")
                onEvent?(.retrying(reason: "Jev is busy (HTTP \(status))",
                                   wait: wait, attempt: retries, of: 3))
                if let cancel {
                    guard cancel.sleep(wait) else { throw AIError.cancelled }
                } else {
                    Thread.sleep(forTimeInterval: wait)
                }
                continue
            }
            guard (200...299).contains(status) else {
                switch status {
                case 401: throw AIError.badKey
                case 402: throw AIError.noCredits
                default: throw AIError.http(status: status, message: errorObject?["message"] as? String ?? "")
                }
            }
            let answers = (json?["answers"] as? [String: Any])?.compactMapValues { $0 as? [String: Any] } ?? [:]
            let usage = json?["usage"] as? [String: Any]
            let inTokens = (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0
            let outTokens = (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
            let charged = (usage?["cost"] as? NSNumber)?.doubleValue
                ?? costUSD(promptTokens: inTokens, completionTokens: outTokens, model: model)
            recordSpend(charged)
            trackedPrompt = inTokens
            trackedCompletion = outTokens
            trackedCost = charged
            let facts = JevClassifier.apply(answers: answers, entries: entries)

            let keyPrefix = keyTotal > 1 ? "key \(keyIndex + 1)/\(keyTotal), " : ""
            let summary = "\(keyPrefix)systemone \(model): HTTP \(status), questions \(questions.count), answers \(answers.count), tokens \(inTokens)+\(outTokens), cost \(String(format: "$%.6f", charged))"
            setLastReplySummary(summary)
            Self.log.info("decisions \(summary, privacy: .public)")
            succeeded = true
            outputChars = String(data: res.data, encoding: .utf8)?.count ?? 0
            return JevDecisionsResult(facts: facts, costUSD: charged,
                                      inputTokens: inTokens, outputTokens: outTokens)

        }
    }

    /// A limit/rejection that a fallback key should take over from, with a
    /// short human-readable reason — nil means "fail, don't switch keys".
    private static func fallbackReason(for error: Error) -> String? {        switch error {
        case AIError.rateLimited: return "rate-limited (429)"
        case AIError.noCredits: return "out of credits (402)"
        case AIError.badKey: return "rejected (401)"
        case AIError.http(let status, _):
            switch status {
            case 429: return "rate-limited (429)"
            case 402: return "out of credits (402)"
            case 401: return "rejected (401)"
            default: return nil
            }
        default: return nil
        }
    }

    /// One batch's plan with a single key (no fallback — the `keys:` variant
    /// above owns key rotation). Sync — call off-main.
    private func requestPlanWithKey(entries: [AIFileEntry], key: String, keyIndex: Int, keyTotal: Int,
                                    model: String, options: AIOrganizeOptions, system: String, user: String,
                                    info: ModelInfo, promptTokens: Int, maxTokens: Int,
                                    cancel: AICancelToken? = nil,
                                    onEvent: ((AIRequestEvent) -> Void)? = nil) throws -> PlanResult {
        var body: [String: Any] = [
            "model": model,
            // Jev makes calibrated decisions — deterministic, no creativity.
            "temperature": Self.isJevModel(model) ? 0 : 0.2,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "usage": ["include": true],
        ]
        if info.supportsJSONMode { body["response_format"] = ["type": "json_object"] }
        // Naming files needs no long thinking; reasoning models would otherwise
        // spend their output budget before writing the list.
        if info.canDisableReasoning { body["reasoning"] = ["enabled": false] }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("aiFlow", forHTTPHeaderField: "X-Title")
        // Free models can take a while on a full batch.
        req.timeoutInterval = 240

        let validNames = Set(entries.map(\.name))
        var retries = 0
        var repaired = false
        var relaxed = false
        var usedPrompt = 0, usedCompletion = 0
        var cost = 0.0
        var succeeded = false
        var outputChars = 0
        let startedAt = Date()
        let telemetryPayload = system + "\n" + user
        defer {
            AIExecutionLog.shared.record(task: "organizer_plan",
                                         model: model, fileCount: entries.count,
                                         inputChars: telemetryPayload.count, outputChars: outputChars,
                                         promptTokens: usedPrompt > 0 ? usedPrompt : promptTokens,
                                         completionTokens: usedCompletion, costUSD: cost,
                                         latencyMS: Int(Date().timeIntervalSince(startedAt) * 1_000),
                                         success: succeeded, payload: telemetryPayload)
        }
        while true {
            if cancel?.isCancelled == true { throw AIError.cancelled }
            let res = try syncPOST(request: req, body: try JSONSerialization.data(withJSONObject: body), cancel: cancel)
            let json = try? JSONSerialization.jsonObject(with: res.data) as? [String: Any]
            let errorObject = json?["error"] as? [String: Any]
            // OpenRouter can answer 200 with an error object when the provider failed.
            let status = (200...299).contains(res.status) && errorObject != nil
                ? ((errorObject?["code"] as? NSNumber)?.intValue ?? 502)
                : res.status
            if status == 429 {
                // Rate limit je po ključu — nema čekanja 5/15/30s, odmah sljedeći
                // ključ (outer loop hvata rateLimited i rotira). Ako je ovo zadnji
                // ključ, outer ga baca kao grešku bez vrtenja: dnevni limit se ne
                // resetuje za 50s pa čekanje samo drži spinner.
                throw AIError.rateLimited
            }
            if (500...599).contains(status) {
                // Zauzet provider: retry isti ključ sa backoff-om (drugi ključ
                // bi udario u istog providera, switch ne pomaže).
                guard retries < 3 else {
                    throw AIError.http(status: status, message: errorObject?["message"] as? String ?? "")
                }
                let wait = Self.retryDelay(headers: res.headers, attempt: retries)
                retries += 1
                Self.log.info("plan \(model, privacy: .public): HTTP \(status), retry \(retries) in \(wait)s")
                onEvent?(.retrying(reason: "The model's provider is busy (HTTP \(status))",
                                   wait: wait, attempt: retries, of: 3))
                if let cancel {
                    guard cancel.sleep(wait) else { throw AIError.cancelled }
                } else {
                    Thread.sleep(forTimeInterval: wait)
                }
                continue
            }
            if status == 400, !relaxed, body["reasoning"] != nil || body["response_format"] != nil {
                // A provider that rejects the reasoning switch or JSON mode: once without them.
                relaxed = true
                body["reasoning"] = nil
                body["response_format"] = nil
                Self.log.info("plan \(model, privacy: .public): HTTP 400 (\(errorObject?["message"] as? String ?? "", privacy: .public)), retrying without reasoning switch / JSON mode")
                continue
            }
            guard (200...299).contains(status) else {
                switch status {
                case 401: throw AIError.badKey
                case 402: throw AIError.noCredits
                default: throw AIError.http(status: status, message: errorObject?["message"] as? String ?? "")
                }
            }
            let choice = (json?["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            if let usage = json?["usage"] as? [String: Any] {
                let pt = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
                let ct = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
                usedPrompt += pt
                usedCompletion += ct
                // The exact charge when OpenRouter reports it, else our estimate.
                let charged = (usage["cost"] as? NSNumber)?.doubleValue
                    ?? costUSD(promptTokens: pt, completionTokens: ct, model: model)
                cost += charged
                recordSpend(charged)
            }
            let content = Self.messageText(message?["content"])
            let reasoning = message?["reasoning"] as? String ?? ""
            outputChars = content.count + reasoning.count
            var parsed = AIPlanParser.extract(from: content, validNames: validNames)
            if !parsed.foundJSON, !reasoning.isEmpty {
                // Some reasoning models leave the answer inside their thinking.
                let fromThinking = AIPlanParser.extract(from: reasoning, validNames: validNames)
                if !fromThinking.items.isEmpty { parsed = fromThinking }
            }
            let finish = choice?["finish_reason"] as? String ?? "?"
            let cutOff = finish == "length" || parsed.truncated
            // Counts only — never the key or file names — so a failing model can be diagnosed
            // with: log show --predicate 'subsystem == "com.finderflow.app"' --last 1h
            let keyPrefix = keyTotal > 1 ? "key \(keyIndex + 1)/\(keyTotal), " : ""
            let summary = "\(keyPrefix)\(model): HTTP \(status), finish \(finish), max_tokens \(body["max_tokens"] as? Int ?? maxTokens), tokens \(usedPrompt)+\(usedCompletion), reasoning \(reasoning.count) chars, reply \(content.count) chars, rows \(parsed.rawCount), usable \(parsed.items.count)"
            setLastReplySummary(summary)
            Self.log.info("plan \(summary, privacy: .public)")
             if parsed.foundJSON && (!parsed.items.isEmpty || parsed.rawCount == 0) {
                 succeeded = true
                 return PlanResult(items: parsed.items, promptTokens: usedPrompt, completionTokens: usedCompletion,

                                  costUSD: cost, truncated: cutOff)
            }
            if cutOff && !parsed.foundJSON { throw AIError.truncated }
            // Prose, an empty reply, or rows naming files that aren't here: ask once more.
            guard !repaired else {
                throw AIError.badReply(snippet: Self.snippet(content.isEmpty ? reasoning : content))
            }
            repaired = true
            onEvent?(.repairing)
            body["temperature"] = 0
            // Some providers return odd output in JSON mode; the reminder below does the job.
            body["response_format"] = nil
            body["messages"] = [
                ["role": "system", "content": system],
                ["role": "user", "content": user + "\n\nReply with the JSON object only — start with { and end with }, and copy each \"from\" filename exactly as listed."],
            ]
        }
    }

    /// `content` as text — some providers send a list of text parts.
    private static func messageText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    /// Parse a model reply into plan rows — fences, prose, reasoning blocks,
    /// wrapped or cut-off lists are tolerated (see AIPlanParser). Throws
    /// `.badJSON` when there's no plan in it. Pure — unit-testable.
    static func parsePlan(content: String, validNames: Set<String>) throws -> [AIPlanItem] {
        let parsed = AIPlanParser.extract(from: content, validNames: validNames)
        guard parsed.foundJSON else { throw AIError.badJSON }
        return parsed.items
    }

    /// Backoff for throttled attempts: server's Retry-After (seconds) when
    /// sane, otherwise 5s / 15s / 30s. Pure — unit-testable.
    static func retryDelay(headers: [AnyHashable: Any], attempt: Int) -> Double {
        let defaults: [Double] = [5, 15, 30]
        let fallback = attempt < defaults.count ? defaults[attempt] : 30
        for key in ["Retry-After", "retry-after"] {
            if let raw = headers[key] {
                let s = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
                if let secs = Double(s), secs > 0, secs <= 120 { return secs }
            }
        }
        return fallback
    }

    // MARK: Sync HTTP helpers (URLSession is async-only; semaphore is fine off-main)

    private func syncPOST(request: URLRequest, body: Data,
                           cancel: AICancelToken? = nil) throws -> (data: Data, status: Int, headers: [AnyHashable: Any]) {
        var out: Result<(Data, Int, [AnyHashable: Any]), Error>?
        let sem = DispatchSemaphore(value: 0)
        var req = request
        req.httpBody = body
        if req.timeoutInterval <= 0 || req.timeoutInterval > 120 { req.timeoutInterval = 60 }
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { out = .failure(err) }
            else {
                let http = resp as? HTTPURLResponse
                out = .success((data ?? Data(), http?.statusCode ?? -1, http?.allHeaderFields ?? [:]))
            }
            sem.signal()
        }
        // Stop cancels the request itself, not just the next step.
        cancel?.track(task)
        task.resume()
        // Bounded wait: callback koji nikad ne stigne ne sme da visi zauvek.
        let waited = sem.wait(timeout: .now() + req.timeoutInterval + 10)
        cancel?.track(nil)
        if cancel?.isCancelled == true { throw AIError.cancelled }
        if waited == .timedOut {
            task.cancel()
            throw AIError.network(URLError(.timedOut))
        }
        guard let finished = out else { throw AIError.network(URLError(.unknown)) }
        switch finished {
        case .failure(let e): throw AIError.network(e)
        case .success(let v): return v
        }
    }

    private func syncGET(url: URL, cancel: AICancelToken? = nil) throws -> Data {
        var out: Result<Data, Error>?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.timeoutInterval = 20
        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if let err { out = .failure(err) } else { out = .success(data ?? Data()) }
            sem.signal()
        }
        cancel?.track(task)
        task.resume()
        let waited = sem.wait(timeout: .now() + 30)
        cancel?.track(nil)
        if cancel?.isCancelled == true { throw AIError.cancelled }
        if waited == .timedOut {
            task.cancel()
            throw AIError.network(URLError(.timedOut))
        }
        guard let finished = out else { throw AIError.network(URLError(.unknown)) }
        switch finished {
        case .failure(let e): throw AIError.network(e)
        case .success(let v): return v
        }
    }
}

// MARK: - Keychain (OpenRouter keys; same shape as the Discord token store)

private enum AIKeychainStore {
    private static let service = "FinderFlow.openRouterKey"
    private static let account = "api-key"
    /// Multi-key store: JSON array of keys in order (primary + fallbacks).
    private static let listService = "FinderFlow.openRouterKeys"
    private static let listAccount = "keys"

    static func load() -> String? { loadAll().first }

    /// All keys in order. Reads the list store first; falls back to the
    /// legacy single-key entry (pre-fallback builds) so existing installs
    /// keep working without re-pasting the key.
    static func loadAll() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: listService,
            kSecAttrAccount as String: listAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let keys = try? JSONDecoder().decode([String].self, from: data) {
            return keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        // Legacy single key → migrate on read (without writing yet).
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var legacyItem: CFTypeRef?
        guard SecItemCopyMatching(legacy as CFDictionary, &legacyItem) == errSecSuccess,
              let data = legacyItem as? Data,
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return [] }
        return [s]
    }

    static func save(_ key: String) { saveAll([key]) }

    /// Saves the ordered list; empty clears everything (list + legacy).
    /// Duplicates and blanks are dropped, order is kept.
    static func saveAll(_ keys: [String]) {
        var seen = Set<String>()
        let clean = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        // Single source of truth going forward: drop the legacy entry.
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(legacy as CFDictionary)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: listService,
            kSecAttrAccount as String: listAccount,
        ]
        guard !clean.isEmpty else {
            SecItemDelete(q as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(clean) else { return }
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

    static func delete() { saveAll([]) }
}

private enum AIKeychain {
    static func load() -> String? { AIKeychainStore.load() }
    static func loadAll() -> [String] { AIKeychainStore.loadAll() }
    static func save(_ s: String) { AIKeychainStore.save(s) }
    static func saveAll(_ keys: [String]) { AIKeychainStore.saveAll(keys) }
    static func delete() { AIKeychainStore.delete() }
}
