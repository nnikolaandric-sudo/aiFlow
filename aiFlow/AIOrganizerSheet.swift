import SwiftUI
import AppKit

// MARK: - AI Organizer sheet
//
// Setup → working (progress, Stop) → review (untick or edit any suggestion)
// → apply under one Undo. With "Review changes before applying" off in
// Settings the plan is applied as soon as it arrives — except plans with
// duplicates for Trash, which always wait for review. Planning lives in
// AIOrganizerEngine.swift, the network in AIService.swift.

final class AIOrganizerModel: ObservableObject {
    enum Phase: Equatable {
        case setup
        case working
        case review
        case applying
        case failed(String)
    }

    @Published var phase: Phase = .setup
    @Published var status = ""
    @Published var progress = 0.0
    @Published var batchCount = 1
    @Published var startedAt = Date()
    @Published var proposals: [AIProposal] = []
    /// Run-level notes shown with the plan ("Stopped after batch 2 of 3: …").
    @Published var notes: [String] = []
    @Published var costUSD = 0.0

    private var token: AICancelToken?
    private let workQueue = DispatchQueue(label: "FinderFlow.aiOrganizer", qos: .userInitiated)

    var includedCount: Int { proposals.filter(\.include).count }

    /// Stops a running plan; late results from it are ignored.
    func cancel() {
        token?.cancel()
        token = nil
    }

    func stop() {
        cancel()
        phase = .setup
        status = ""
    }

    /// Offline duplicate scan — no API key, no network, just size + SHA-256.
    /// Used when only "delete duplicates" is on. Ends in `.review`.
    func startLocalOnly(folder: URL, files: [URL], onPlanned: @escaping () -> Void) {
        cancel()
        let run = AICancelToken()
        token = run
        phase = .working
        status = "Checking for identical files…"
        progress = 0
        batchCount = 1
        startedAt = Date()
        proposals = []
        notes = []
        costUSD = 0
        workQueue.async { [weak self] in
            var entries: [AIFileEntry] = []
            for (i, url) in files.enumerated() {
                if run.isCancelled { return }
                self?.update(run) { $0.status = "Checking \(i + 1) of \(files.count)…" }
                let name = url.lastPathComponent
                guard !name.hasPrefix("."),
                      let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey]),
                      v.isDirectory != true, v.isPackage != true, v.isSymbolicLink != true else { continue }
                entries.append(AIFileEntry(url: url, name: name, kind: url.pathExtension.lowercased(),
                                           size: Int64(v.fileSize ?? 0), preview: nil))
            }
            if run.isCancelled { return }
            guard !entries.isEmpty else {
                self?.finish(run) { $0.phase = .failed("Nothing to check here — folders, apps, aliases and hidden files are left alone.") }
                return
            }
            let localItems = LocalDuplicates.find(in: entries, cancel: run) { index, total in
                self?.update(run) { $0.status = "Hashing \(index) of \(total)…" }
            }
            if run.isCancelled { return }
            let options = AIOrganizeOptions(renameFiles: false, useSubfolders: false, deleteDuplicates: true)
            let proposals = AIPlanner.proposals(from: localItems, entries: entries, folder: folder, options: options)
            self?.finish(run) {
                $0.proposals = proposals
                $0.notes = localItems.isEmpty ? [] : ["\(localItems.count) identical \(localItems.count == 1 ? "file" : "files") found by content — no AI needed."]
                $0.progress = 1
                $0.phase = .review
                onPlanned()
            }
        }
    }

    /// Plans `files` (regular files directly inside `folder`) off-main and
    /// ends in `.review` (then calls `onPlanned`) or `.failed`.
    /// When `options.deleteDuplicates` is on, byte-identical files are always
    /// added via local hash — even if the model ignores them or fails.
    /// Keys are tried in order: when one hits its limit (429/402) or is
    /// rejected (401), the next saved key takes over automatically.
    func start(folder: URL, files: [URL], options: AIOrganizeOptions, key: String, model: String,
               onPlanned: @escaping () -> Void) {
        start(folder: folder, files: files, options: options, keys: [key], model: model, onPlanned: onPlanned)
    }

    func start(folder: URL, files: [URL], options: AIOrganizeOptions, keys: [String], model: String,
               onPlanned: @escaping () -> Void) {
        cancel()
        let run = AICancelToken()
        token = run
        phase = .working
        status = "Reading \(files.count) \(files.count == 1 ? "file" : "files")…"
        progress = 0
        batchCount = 1
        startedAt = Date()
        proposals = []
        notes = []
        costUSD = 0
        let ai = AIService.shared
        let shortModel = model.split(separator: "/").last.map(String.init) ?? model

        workQueue.async { [weak self] in
            let entries = ai.buildInventory(urls: files, cancel: run) { index, total in
                // Reading documents (OCR for scans) takes a moment per file.
                self?.update(run) { $0.status = "Reading \(index) of \(total) \(total == 1 ? "file" : "files")…" }
            }
            if run.isCancelled { return }
            guard !entries.isEmpty else {
                self?.finish(run) { $0.phase = .failed("Nothing to organize here — folders, apps, aliases and hidden files are left alone.") }
                return
            }
            // Local exact duplicates first — guaranteed, no model needed.
            var localItems: [AIPlanItem] = []
            if options.deleteDuplicates {
                self?.update(run) { $0.status = "Checking for identical files…" }
                localItems = LocalDuplicates.find(in: entries, cancel: run) { index, total in
                    self?.update(run) { $0.status = "Hashing \(index) of \(total)…" }
                }
                if run.isCancelled { return }
            }
            ai.refreshModelTableIfNeeded()
            // Jev cascade: Jev classifies (System One decisions — type, language,
            // currency) and a free chat model extracts the strings (issuer,
            // numbers, dates); names are composed in code. Jev answers 400 on
            // chat/completions, so requestPlan must never see a Jev slug.
            let jevPath = AIService.isJevModel(model)
            let extractionModel = jevPath ? ai.extractionModel : model
            let askingName = jevPath
                ? (ai.extractionModel.split(separator: "/").last.map(String.init) ?? ai.extractionModel)
                : shortModel
            // Prompts use under half the model's context, leaving room for the reply.
            let budget = ai.modelInfo(model).contextLength.map { max(3_000, $0 * 45 / 100) } ?? 40_000
            var pending = AIPlanner.batches(entries, maxFiles: ai.maxFiles, tokenBudget: budget).map { (files: $0, depth: 0) }
            var context = AIPromptContext(folderName: folder.lastPathComponent,
                                          knownFolders: options.useSubfolders ? AIPlanner.listing(of: folder).folders : [])
            var items: [AIPlanItem] = []
            var notes: [String] = []
            var cost = 0.0
            var done = 0
            let report: (AIRequestEvent) -> Void = { event in
                let text: String
                switch event {
                case .retrying(let reason, let wait, let attempt, let of):
                    text = "\(reason) — retrying in \(Int(wait.rounded()))s (\(attempt) of \(of))…"
                case .repairing:
                    text = "The reply wasn't a clean list — asking \(askingName) again…"
                case .switchedKey(let reason, let index, let total):
                    text = "Key \(index - 1) \(reason) — trying Key \(index) of \(total)…"
                }
                self?.update(run) { $0.status = text }
            }

            batches: while !pending.isEmpty {
                if run.isCancelled { return }
                let (batch, depth) = pending.removeFirst()
                let total = done + pending.count + 1
                self?.update(run) {
                    $0.batchCount = total
                    $0.progress = Double(done) / Double(total)
                    $0.status = total > 1 ? "Asking \(askingName) — batch \(done + 1) of \(total)…" : "Asking \(askingName)…"
                }
                do {
                    var hints: [String: JevClassFacts] = [:]
                    if jevPath {
                        self?.update(run) {
                            $0.status = total > 1 ? "Classifying with Jev — batch \(done + 1) of \(total)…" : "Classifying with Jev…"
                        }
                        let decisions = try ai.requestDecisions(entries: batch, keys: keys, model: model,
                                                                folderName: folder.lastPathComponent,
                                                                cancel: run, onEvent: report)
                        cost += decisions.costUSD
                        hints = decisions.facts
                    }
                    let plan = try ai.requestPlan(entries: batch, keys: keys, model: extractionModel, options: options,
                                                  context: context, jevHints: hints, nameByCode: jevPath,
                                                  cancel: run, onEvent: report)
                    cost += plan.costUSD
                    items += jevPath ? JevClassifier.merged(items: plan.items, jev: hints) : plan.items
                    // Later batches reuse the folders earlier ones invented.
                    for f in plan.items.map(\.folder) where !f.isEmpty
                        && !context.knownFolders.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) {
                        context.knownFolders.append(f)
                    }
                    if plan.truncated && depth < 2 {
                        // Cut off: ask again, in halves, for the files the reply never reached.
                        let mentioned = Set(plan.items.map(\.from))
                        let rest = batch.filter { !mentioned.contains($0.name) }
                        if !rest.isEmpty { pending += Self.halves(rest).map { (files: $0, depth: depth + 1) } }
                    }
                } catch AIError.cancelled {
                    return
                } catch AIError.truncated where depth < 2 && batch.count > 8 {
                    pending += Self.halves(batch).map { (files: $0, depth: depth + 1) }
                } catch {
                    if run.isCancelled { return }
                    AIService.log.error("organize failed: \(error.localizedDescription, privacy: .public)")
                    let details = ai.lastReplySummary
                    let message = error.localizedDescription + (details.isEmpty ? "" : "\n\nLast reply: \(details)")
                    guard !items.isEmpty || !localItems.isEmpty else {
                        self?.finish(run) { $0.phase = .failed(message) }
                        return
                    }
                    notes.append("Stopped after batch \(done) of \(total): \(message)")
                    break batches
                }
                done += 1
            }
            if run.isCancelled { return }
            // Local exact matches first — AI rows for the same files are skipped.
            let allItems = localItems + items
            if options.deleteDuplicates, !localItems.isEmpty {
                notes.append("\(localItems.count) identical \(localItems.count == 1 ? "file" : "files") found by content — no AI needed.")
            }
            // Jev cascade: Jev classified, the chat model extracted strings,
            // names are composed from facts in code.
            let composeFromFacts = AIService.isJevModel(model)
            let proposals = AIPlanner.proposals(from: allItems, entries: entries, folder: folder,
                                                options: options, composeFromFacts: composeFromFacts)
            if composeFromFacts {
                let extractionName = ai.extractionModel.split(separator: "/").last.map(String.init)
                    ?? ai.extractionModel
                let classified = allItems.filter { !$0.facts.isEmpty }.count
                if !proposals.isEmpty {
                    notes.append("Jev classified type, language and currency — strings extracted with \(extractionName) (free), names composed in code.")
                } else if classified > 0 {
                    notes.append("Jev classified \(classified) of \(entries.count) files — the names are already clear, nothing to change.")
                }
            }
            self?.finish(run) {
                $0.proposals = proposals
                $0.notes = notes
                $0.costUSD = cost
                $0.progress = 1
                $0.phase = .review
                onPlanned()
            }
        }
    }

    /// Applies the ticked proposals; `done` runs when something changed,
    /// otherwise the sheet shows why.
    func apply(in folder: URL, fileOps: FileOperationsService, reload: @escaping () -> Void,
               done: @escaping () -> Void) {
        let changes = proposals.filter(\.include).compactMap { p -> AIPlanChange? in
            if p.isDelete {
                return AIPlanChange(source: p.source, name: p.original, folder: "", isDelete: true, duplicateOf: p.duplicateOf)
            }
            // Edited names get the same rules as the model's (extension kept).
            guard let name = p.name == p.original ? p.original : AINameRules.sanitizeName(p.name, original: p.original),
                  name != p.original || !p.folder.isEmpty else { return nil }
            return AIPlanChange(source: p.source, name: name, folder: p.folder)
        }
        guard !changes.isEmpty else {
            phase = .failed("Nothing to apply — every ticked suggestion keeps the file as it is.")
            return
        }
        phase = .applying
        fileOps.applyAIPlan(changes, in: folder, reload: reload) { [weak self] result in
            if result.changed > 0 {
                done()
            } else {
                self?.phase = .failed(result.firstError.map { "Nothing could be changed: \($0)" }
                    ?? "Nothing could be changed — the files may have been moved or renamed meanwhile.")
            }
        }
    }

    private static func halves(_ entries: [AIFileEntry]) -> [[AIFileEntry]] {
        guard entries.count > 1 else { return [entries] }
        let mid = entries.count / 2
        return [Array(entries[..<mid]), Array(entries[mid...])]
    }

    /// Publishes on main unless this run was stopped or replaced meanwhile.
    private func update(_ run: AICancelToken, _ change: @escaping (AIOrganizerModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token === run, !run.isCancelled else { return }
            change(self)
        }
    }

    private func finish(_ run: AICancelToken, _ change: @escaping (AIOrganizerModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token === run, !run.isCancelled else { return }
            self.token = nil
            change(self)
        }
    }
}

struct AIOrganizerSheet: View {
    let folder: URL
    /// Listing of `folder` (never search results, which can span folders).
    let folderFiles: [FileItem]
    /// Current selection; only regular files directly inside `folder` count.
    let selectedFiles: [FileItem]
    @ObservedObject var fileOps: FileOperationsService
    var onApplied: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ai = AIService.shared
    @StateObject private var model = AIOrganizerModel()
    @State private var useSelection = false
    /// Read once per appearance / window activation — each check is a Keychain lookup.
    @State private var hasKey = true
    @State private var showPayload = false

    private static let instructionChips = ["Invoices: number - supplier - date", "Dates first (YYYY-MM-DD)", "English names", "Group by year", "Short names"]

    /// `organizer` lets a caller (tests, previews) hand in a prepared model.
    init(folder: URL, folderFiles: [FileItem], selectedFiles: [FileItem], fileOps: FileOperationsService,
         onApplied: @escaping () -> Void = {}, organizer: AIOrganizerModel? = nil) {
        self.folder = folder
        self.folderFiles = folderFiles
        self.selectedFiles = selectedFiles
        self.fileOps = fileOps
        self.onApplied = onApplied
        _model = StateObject(wrappedValue: organizer ?? AIOrganizerModel())
    }

    private var folderCandidates: [FileItem] {
        folderFiles.filter { !$0.isDirectory && !$0.isPackage && !$0.name.hasPrefix(".") }
    }

    private var selectionCandidates: [FileItem] {
        let parent = folder.standardizedFileURL.path
        return selectedFiles.filter {
            !$0.isDirectory && !$0.isPackage && !$0.name.hasPrefix(".")
                && $0.url.deletingLastPathComponent().standardizedFileURL.path == parent
        }
    }

    private var targets: [FileItem] {
        useSelection && !selectionCandidates.isEmpty ? selectionCandidates : folderCandidates
    }

    private var isLocalOnly: Bool {
        ai.deleteDuplicates && !ai.renameFiles && !ai.useSubfolders
    }

    private var canAnalyze: Bool {
        guard !targets.isEmpty, (ai.renameFiles || ai.useSubfolders || ai.deleteDuplicates) else { return false }
        // Finding identical files works offline — no API key needed.
        if isLocalOnly { return true }
        return hasKey
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.phase {
                case .setup: setupView
                case .working: workingView
                case .review: reviewView
                case .applying: busyView("Applying changes…")
                case .failed(let message): failedView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .onAppear {
            hasKey = ai.isKeySet
            useSelection = !selectionCandidates.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Back from Settings with a freshly pasted key.
            if !hasKey { hasKey = ai.isKeySet }
        }
        .onDisappear { model.cancel() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(FFTheme.aiGradient)
                    .frame(width: 36, height: 36)
                    .shadow(color: FFTheme.ai.opacity(0.30), radius: 8, y: 2)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Organize “\(folder.lastPathComponent)” with AI")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(modelLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if ai.modelID.hasSuffix(":free") {
                        Text("FREE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .ffBadge()
                    }
                    if AIService.isJevModel(ai.modelID) {
                        Text("JEV")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.purple)
                            .ffBadge()
                            .help("TypeSafe Jev — fast classifier (type, language, currency). Strings come from a free chat model, names are composed in code.")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var modelLine: String {
        if ai.modelID.hasSuffix(":free") { return "\(ai.modelID) · free model" }
        return "\(ai.modelID) · " + String(format: "$%.2f of $%.2f spent this month", ai.monthSpend(), ai.monthlyCapUSD)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .setup:
                SettingsLink { Text("AI Settings…") }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button { analyze() } label: { Label("Analyze", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAnalyze)
            case .working:
                Spacer()
                Button("Stop") { model.stop() }
                    .keyboardShortcut(.cancelAction)
            case .review:
                Button { model.phase = .setup } label: { Label("Back", systemImage: "chevron.left") }
                Spacer()
                if model.proposals.isEmpty {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text(applyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    // ⌘↩, not ↩: Return confirms a name being edited in the list.
                    Button(applyButtonTitle) { apply() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.includedCount == 0)
                }
            case .applying:
                Spacer()
            case .failed:
                Button { model.phase = .setup } label: { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { analyze() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAnalyze)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Setup

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !hasKey {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Add your OpenRouter API key first")
                                .font(.callout.weight(.semibold))
                            Text("Paste it in Settings → AI Organizer. Models ending in :free cost nothing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: FFTheme.cardShape)
                }

                section("Files") {
                    if !selectionCandidates.isEmpty {
                        Picker("Files", selection: $useSelection) {
                            Text("Selected (\(selectionCandidates.count))").tag(true)
                            Text("Whole folder (\(folderCandidates.count))").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Label(targets.isEmpty
                          ? "No files to organize here — folders, apps and hidden files are left alone."
                          : "\(targets.count) \(targets.count == 1 ? "file" : "files") · folders, apps and hidden files are left alone",
                          systemImage: "doc.on.doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                section("What should it do?") {
                    Toggle("Rename by what's inside (invoices: number, supplier, date, due date, currency/amount, language)", isOn: $ai.renameFiles)
                    Toggle("Sort into subfolders (reuses existing ones)", isOn: $ai.useSubfolders)
                    Toggle(isOn: $ai.deleteDuplicates) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete duplicates (to Trash)")
                            Text("Identical files are found on this Mac by content and ticked for Trash — works even without AI. AI also flags same-document copies (same invoice, scans). You review each one before anything is deleted — one ⌘Z brings it back.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                section("Instructions (optional)") {
                    TextField("e.g. English names, dates first, group by client", text: $ai.instructions, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(FFTheme.cardShape)
                        .overlay(
                            FFTheme.cardShape
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    HStack(spacing: 6) {
                        ForEach(Self.instructionChips, id: \.self) { chip in
                            Button(chip) { appendInstruction(chip) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }

                DisclosureGroup("Review what will be sent", isExpanded: $showPayload) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ai.sendPreviews ? "Document text excerpts are included when available." : "Only file names, sizes and dates are included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(targets.prefix(20), id: \.id) { item in
                            HStack(spacing: 5) {
                                Image(systemName: "doc")
                                Text(item.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        if targets.count > 20 {
                            Text("+ \(targets.count - 20) more files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if ai.redactPersonalData {
                            Label("Personal data redaction is on", systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout.weight(.semibold))

                Label(privacyLine, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private var privacyLine: String {
        if isLocalOnly {
            return "Duplicate check runs on this Mac (size + content hash) — nothing is sent anywhere. You review each duplicate before anything goes to Trash."
        }
        var text = "Sends file names, sizes and dates"
        if ai.sendPreviews { text += " plus the text of documents (PDF, Word, text; scans and photos are read on this Mac with OCR)" }
        if ai.sendPreviews && ai.redactPersonalData { text += "; emails, phone numbers and account-looking values are redacted first" }
        if AIService.isJevModel(ai.modelID) {
            text += " to Jev (System One decisions) plus \(ai.extractionModel) (string extraction) via OpenRouter."
        } else {
            text += " to \(ai.modelID) via OpenRouter."
        }
        text += " Identical files are also found on this Mac by hash, so duplicates show up even if the model misses them. "
        if ai.reviewBeforeApply {
            text += "Nothing on disk changes until you apply."
        } else if ai.deleteDuplicates {
            text += "Review is off in Settings, but plans with duplicates still wait for your review — nothing is trashed automatically."
        } else {
            text += "Review is off in Settings, so the plan is applied as soon as it arrives."
        }
        return text
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func appendInstruction(_ chip: String) {
        let current = ai.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.localizedCaseInsensitiveContains(chip) else { return }
        ai.instructions = current.isEmpty ? chip : current + ", " + chip
    }

    // MARK: Working

    private var workingView: some View {
        VStack(spacing: 14) {
            if model.batchCount > 1 {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 340)
            }
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(model.status)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 480)
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                Text(Self.elapsed(from: model.startedAt, to: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(AIService.isJevModel(ai.modelID)
                  ? "Jev classifies in seconds — most of this time is reading files on your Mac (OCR for scans). Nothing changes on disk yet."
                  : "Free models can take a minute when they're busy. Nothing changes on disk yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Review

    private struct ProposalGroup {
        let folder: String
        let indices: [Int]
        let isNew: Bool
    }

    private var groups: [ProposalGroup] {
        var order: [String] = []
        var members: [String: [Int]] = [:]
        for (i, p) in model.proposals.enumerated() where !p.isDelete {
            if members[p.folder] == nil { order.append(p.folder) }
            members[p.folder, default: []].append(i)
        }
        order.sort { a, b in a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }
        return order.map { f in
            let indices = members[f] ?? []
            return ProposalGroup(folder: f, indices: indices,
                                 isNew: indices.first.map { model.proposals[$0].isNewFolder } ?? false)
        }
    }

    private var duplicateIndices: [Int] {
        model.proposals.indices.filter { model.proposals[$0].isDelete }
    }

    private var summaryLine: String {
        let ps = model.proposals
        let renames = ps.filter(\.isRename).count
        let moves = ps.filter(\.isMove).count
        let deletes = ps.filter(\.isDelete).count
        let newFolders = Set(ps.filter(\.isNewFolder).map { $0.folder.lowercased() }).count
        var parts = ["\(ps.count) \(ps.count == 1 ? "suggestion" : "suggestions")"]
        if renames > 0 { parts.append("\(renames) \(renames == 1 ? "rename" : "renames")") }
        if moves > 0 { parts.append("\(moves) \(moves == 1 ? "move" : "moves")") }
        if deletes > 0 { parts.append("\(deletes) to Trash") }
        if newFolders > 0 { parts.append("\(newFolders) new \(newFolders == 1 ? "folder" : "folders")") }
        return parts.joined(separator: " · ")
    }

    private var allIncluded: Binding<Bool> {
        Binding(
            get: { model.proposals.allSatisfy(\.include) },
            set: { value in
                var updated = model.proposals
                for i in updated.indices { updated[i].include = value }
                model.proposals = updated
            }
        )
    }

    private var includedDeletes: Int {
        model.proposals.filter { $0.isDelete && $0.include }.count
    }

    private var applyButtonTitle: String {
        let n = model.includedCount
        let base = "Apply \(n) \(n == 1 ? "Change" : "Changes")"
        guard includedDeletes > 0 else { return base }
        return "\(base) (\(includedDeletes) to Trash)"
    }

    private var applyHint: String {
        includedDeletes > 0
            ? "Untick to keep a duplicate · Trash is recoverable · one ⌘Z undoes it all"
            : "Click a name to edit it · one ⌘Z undoes it all"
    }

    @ViewBuilder
    private var reviewView: some View {
        if model.proposals.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text("Nothing to change")
                    .font(.headline)
                Text("The model found these names and places already clear. Go back and add instructions for another take.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                ForEach(model.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(note.hasPrefix("Stopped") ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
            .padding(24)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Toggle(isOn: allIncluded) {
                        Text(summaryLine)
                            .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    if model.costUSD > 0 {
                        Text(String(format: "$%.4f", model.costUSD))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                ForEach(model.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                List {
                    if !duplicateIndices.isEmpty {
                        Section {
                            ForEach(duplicateIndices, id: \.self) { i in row(i) }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash.fill")
                                    .foregroundStyle(.red)
                                Text("Duplicates — to Trash")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.red)
                                Spacer()
                                Text("\(duplicateIndices.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } footer: {
                            Text("Deleted files go to Trash and can be restored — one ⌘Z brings them back.")
                                .font(.caption)
                        }
                    }
                    ForEach(groups, id: \.folder) { group in
                        Section {
                            ForEach(group.indices, id: \.self) { i in row(i) }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func groupHeader(_ group: ProposalGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.folder.isEmpty ? "folder" : (group.isNew ? "folder.badge.plus" : "folder.fill"))
                .foregroundStyle(group.folder.isEmpty ? Color.secondary : Color.accentColor)
            Text(group.folder.isEmpty ? "Stays in “\(folder.lastPathComponent)”" : group.folder)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if group.isNew {
                Text("NEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text("\(group.indices.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ i: Int) -> some View {
        let p = model.proposals[i]
        if p.isDelete {
            return AnyView(deleteRow(i, p))
        }
        return AnyView(HStack(spacing: 10) {
            Toggle("Include", isOn: $model.proposals[i].include)
                .toggleStyle(.checkbox)
                .labelsHidden()
            URLIconView(url: p.source, isDirectory: false, isPackage: false, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                TextField("New name", text: $model.proposals[i].name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                if p.name == p.original {
                    Text("Name unchanged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(p.original)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(true, color: .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !p.facts.isEmpty {
                    Label(p.facts.summary, systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(2)
                        .help(factsHelp(p.facts))
                    HStack(spacing: 6) {
                        if !p.facts.confidenceSummary.isEmpty {
                            Label(p.facts.confidenceSummary, systemImage: "checkmark.shield")
                        }
                        if !p.facts.pageSummary.isEmpty {
                            Label(p.facts.pageSummary, systemImage: "doc.on.doc")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if !p.facts.warnings.isEmpty {
                    Label(p.facts.warnings.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let note = p.note {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(note)
            }
        }
        .padding(.vertical, 2)
        .opacity(p.include ? 1 : 0.5))
    }

    private func deleteRow(_ i: Int, _ p: AIProposal) -> some View {
        HStack(spacing: 10) {
            Toggle("Delete", isOn: $model.proposals[i].include)
                .toggleStyle(.checkbox)
                .labelsHidden()
            URLIconView(url: p.source, isDirectory: false, isPackage: false, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.original)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(true, color: .red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(deleteSubtitle(p))
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
                if !p.deleteReason.isEmpty {
                    Text("“\(p.deleteReason)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "trash")
                .foregroundStyle(.red)
            if let note = p.note {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(note)
            }
        }
        .padding(.vertical, 2)
        .opacity(p.include ? 1 : 0.5)
    }

    private func deleteSubtitle(_ p: AIProposal) -> String {
        if p.duplicateOf.isEmpty {
            return "Duplicate → Trash"
        }
        return "Duplicate of “\(p.duplicateOf)” → Trash"
    }

    /// Tooltip sa svim izvučenim podacima (uključuje i kupca koga nema u kratkom redu).
    private func factsHelp(_ f: AIDocFacts) -> String {
        var lines: [String] = ["Read from the document:"]
        if !f.type.isEmpty { lines.append("Type: \(f.type)") }
        if !f.issuer.isEmpty { lines.append("Issuer: \(f.issuer)") }
        if !f.buyer.isEmpty { lines.append("Buyer: \(f.buyer)") }
        if !f.number.isEmpty { lines.append("Number: \(f.number)") }
        if !f.date.isEmpty { lines.append("Date: \(f.date)") }
        if !f.dueDate.isEmpty { lines.append("Due date: \(f.dueDate)") }
        if !f.amount.isEmpty || !f.currency.isEmpty {
            lines.append("Amount: \([f.amount, f.currency].filter { !$0.isEmpty }.joined(separator: " "))")
        }
        if !f.title.isEmpty { lines.append("Title: \(f.title)") }
        if !f.language.isEmpty { lines.append("Language: \(f.language)") }
        if !f.confidenceSummary.isEmpty { lines.append(f.confidenceSummary) }
        if !f.pageSummary.isEmpty { lines.append(f.pageSummary) }
        if !f.warnings.isEmpty { lines.append("Warnings: " + f.warnings.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Busy / failed

    private func busyView(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Couldn't finish")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
        }
        .padding(24)
    }

    // MARK: Actions

    private func analyze() {
        // Offline path: only duplicates → no key, no network.
        if isLocalOnly {
            model.startLocalOnly(folder: folder, files: targets.map(\.url)) {}
            return
        }
        guard !ai.apiKeys.isEmpty else {
            hasKey = false
            return
        }
        let options = AIOrganizeOptions(renameFiles: ai.renameFiles, useSubfolders: ai.useSubfolders,
                                        deleteDuplicates: ai.deleteDuplicates,
                                        instructions: ai.instructions)
        model.start(folder: folder, files: targets.map(\.url), options: options, keys: ai.apiKeys, model: ai.modelID) {
            // Deletes always need a review — even with "Review off", a Trash plan stays on screen.
            let hasDeletes = model.proposals.contains(where: { $0.isDelete && $0.include })
            if !ai.reviewBeforeApply && !model.proposals.isEmpty && !hasDeletes { apply() }
        }
    }

    private func apply() {
        model.apply(in: folder, fileOps: fileOps, reload: onApplied) { dismiss() }
    }
}
