import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Mail Inbox (MAIL-01..03 UI)
//
// Spec screen: Mail | AI classification | Entity | Documents | Status, with an
// AI suggestion pane (Company → / Project → / Document → / Category →) and
// [Accept] [Change]. Review pattern mirrors AIOrganizerSheet: nothing moves
// without Accept, except ≥98% which auto-filed on ingest (still undoable via
// Trash/one ⌘Z in the DMS).

struct MailInboxView: View {
    /// DMS root attachments + .eml evidence are filed under — always read
    /// live (Settings ▸ Mail Inbox can move it while this view is open).
    private var dmsRoot: URL { MailFilingService.emailRoot() }

    @ObservedObject private var store = MailStore.shared
    @ObservedObject private var ruleStore = MailRuleStore.shared
    @State private var query = ""
    @State private var selection: String?
    @State private var ruleNL = ""
    @State private var ruleMessage: String?
    @State private var draft = MailFilingSuggestion()
    @State private var editing = false
    /// Checked once per window (reading the Keychain on every redraw is slow).
    @State private var aiAvailable = false
    /// Non-nil while an AI pass or a Mail import runs — shown in the toolbar.
    @State private var busy: String?
    @State private var pendingAI: PendingAI?
    @State private var confirmReorganizeAll = false
    /// The last reorganize, so it can be put back with one click.
    @State private var lastReorganize: [(previous: MailInboxRecord, result: MailFilingService.ReorganizeResult)] = []

    /// AI work waiting for the user's OK — attachment text leaves the Mac.
    private enum PendingAI: Identifiable {
        case one(MailInboxRecord)
        case all([MailInboxRecord])
        var id: String {
            switch self {
            case .one(let r): return "one-" + r.id
            case .all(let rs): return "all-\(rs.count)"
            }
        }
        var mailCount: Int {
            switch self {
            case .one: return 1
            case .all(let rs): return rs.count
            }
        }
    }

    /// Mails the AI pass can read — ones with documents that aren't duplicates.
    private var enrichable: [MailInboxRecord] {
        store.records.filter { $0.status != .duplicate && !$0.mail.attachments.isEmpty }
    }

    /// Mails whose documents would move under the category layout.
    private var reorganizable: [MailInboxRecord] {
        store.records.filter {
            $0.status != .duplicate
                && !MailFilingService.reorganizeFolder(for: $0.suggestion, sender: $0.mail.from).isEmpty
        }
    }

    private var visible: [MailInboxRecord] {
        store.search(query).sorted { $0.mail.date > $1.mail.date }
    }

    private var selected: MailInboxRecord? {
        selection.flatMap { id in store.records.first(where: { $0.id == id }) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                List(visible, selection: $selection) { record in
                    row(record)
                        .tag(record.id)
                }
                .listStyle(.inset)
                Divider()
                ruleBar
            }
            .frame(minWidth: 420)
            detail
                .frame(minWidth: 300)
        }
        .frame(width: 900, height: 560)
        .onChange(of: selection) {
            editing = false
            if let s = selected { draft = s.suggestion }
        }
        .onAppear { aiAvailable = AIService.shared.isKeySet }
        .alert((pendingAI?.mailCount ?? 1) == 1 ? "Improve this mail with AI?" : "Improve \(pendingAI?.mailCount ?? 0) mails with AI?",
               isPresented: Binding(get: { pendingAI != nil }, set: { if !$0 { pendingAI = nil } }),
               presenting: pendingAI) { pending in
            Button("Send to AI") { runAI(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Attachment names and the text read from them (PDF text and on-device OCR) go to OpenRouter (\(AIService.shared.modelID)) with your key, the same as AI Organizer. Mail bodies and addresses are not sent. Files move only for mails still waiting in the Inbox.")
        }
        .alert("Reorganize \(reorganizable.count) mails?", isPresented: $confirmReorganizeAll) {
            Button("Reorganize") { reorganize(reorganizable) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Documents move into Finance / Invoices (Inbound, Outbound), Contracts, Legal, HR - Candidates, Offers… under the Email folder and get names built from their facts. The mail evidence moves with them. Nothing is overwritten, and Undo puts everything back.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.secondary)
                TextField("Search mail + documents (e.g. CyberArrow liability cap)", text: $query)
                    .textFieldStyle(.roundedBorder)
                if let busy {
                    ProgressView().controlSize(.small)
                        .help(busy)
                }
                Button { syncInbox() } label: { Label("Sync", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
                    .disabled(busy != nil)
                Menu {
                    Button("Selected Messages in Mail") { importFromMail() }
                    Button(".eml Files…") { importEml() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .disabled(busy != nil)
                .help("Import the messages selected in Mail.app, or .eml files")
                Menu {
                    Button("Improve All with AI (\(enrichable.count))…") { pendingAI = .all(enrichable) }
                        .disabled(!aiAvailable || enrichable.isEmpty)
                    Button("Reorganize All (\(reorganizable.count))…") { confirmReorganizeAll = true }
                        .disabled(reorganizable.isEmpty)
                    if !lastReorganize.isEmpty {
                        Divider()
                        Button("Undo Reorganize") { undoReorganize() }
                    }
                } label: {
                    Label("Organize", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .disabled(busy != nil)
                .help(aiAvailable ? "AI facts and category folders for the whole inbox"
                                  : "Reorganize the inbox — AI needs an OpenRouter key (Settings ▸ AI Organizer)")
            }
            HStack(spacing: 6) {
                Text("Email folder: \(dmsRoot.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Reveal") { NSWorkspace.shared.open(dmsRoot) }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Text(busy ?? "\(store.inbox.count) inbox · \(store.review.count) review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var ruleBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Rule in plain words — e.g. Sve račune sa @bhtelecom.ba stavi u Finance → Telecom", text: $ruleNL, axis: .vertical)
                    .lineLimit(1...2)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Add rule") { addRule() }
                    .controlSize(.small)
                    .disabled(ruleNL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let msg = ruleMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            } else if !ruleStore.rules.isEmpty {
                Text("\(ruleStore.rules.count) automation \(ruleStore.rules.count == 1 ? "rule" : "rules") active")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Rows

    private func row(_ r: MailInboxRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.mail.subject.isEmpty ? "(no subject)" : r.mail.subject)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(r.mail.from) · \(shortDate(r.mail.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(r.suggestion.documentType.isEmpty ? "—" : r.suggestion.documentType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(r.suggestion.entity.isEmpty ? "—" : r.suggestion.entity)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .trailing)
            Text(r.mail.attachments.isEmpty ? "0" : "\(r.mail.attachments.count)")
                .font(.caption.monospacedDigit())
                .frame(width: 20)
                .foregroundStyle(.secondary)
            statusBadge(r.status)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ s: MailFilingStatus) -> some View {
        let (text, color): (String, Color) = {
            switch s {
            case .needsClassification: return ("Inbox", .orange)
            case .reviewSuggested: return ("Review", .yellow)
            case .filed: return ("✓ Filed", .green)
            case .linked: return ("✓ Linked", .blue)
            case .duplicate: return ("Duplicate", .gray)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .frame(width: 70)
    }

    // MARK: Detail

    private var detail: some View {
        Group {
            if let r = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(r.mail.subject.isEmpty ? "(no subject)" : r.mail.subject)
                            .font(.headline)
                        Text("From: \(r.mail.from)\nTo: \(r.mail.to.joined(separator: ", "))\(r.mail.cc.isEmpty ? "" : "\nCc: \(r.mail.cc.joined(separator: ", "))")\nDate: \(longDate(r.mail.date))\nMessage-ID: \(r.mail.messageID.isEmpty ? "—" : r.mail.messageID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !r.mail.body.isEmpty {
                            Text(r.mail.body.prefix(1200))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !r.mail.attachments.isEmpty {
                            Text("Documents (\(r.mail.attachments.count))")
                                .font(.subheadline.weight(.semibold))
                            ForEach(r.mail.attachments) { a in
                                HStack {
                                    Image(systemName: "doc.fill")
                                    Text(a.filename).font(.callout).lineLimit(1)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                        Text("AI suggestion")
                            .font(.subheadline.weight(.semibold))
                        if editing {
                            suggestionEditor
                        } else {
                            suggestionRows(r.suggestion)
                        }
                        HStack {
                            Text(String(format: "Confidence %.0f%%", r.suggestion.confidence * 100))
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: r.suggestion.confidence)
                                .frame(width: 120)
                        }
                        HStack(spacing: 8) {
                            if editing {
                                Button("Save") { saveEdit(r) }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                Button("Cancel") { editing = false; draft = r.suggestion }
                                    .controlSize(.small)
                            } else {
                                Button("Accept") { accept(r) }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                Button("Change") { editing = true; draft = r.suggestion }
                                    .controlSize(.small)
                                Spacer()
                                Button {
                                    pendingAI = .one(r)
                                } label: { Label("Improve with AI", systemImage: "sparkles") }
                                    .controlSize(.small)
                                    .disabled(!aiAvailable || r.mail.attachments.isEmpty || busy != nil)
                                    .help(!aiAvailable ? "Add an OpenRouter key in Settings ▸ AI Organizer"
                                          : r.mail.attachments.isEmpty ? "This mail has no documents to read"
                                          : "Read the documents with AI and refine company, type, dates and amounts")
                                Button("Reorganize") { reorganize([r]) }
                                    .controlSize(.small)
                                    .disabled(busy != nil
                                              || MailFilingService.reorganizeFolder(for: r.suggestion, sender: r.mail.from).isEmpty)
                                    .help("Move this mail's documents into its category folder with a name built from its facts")
                            }
                        }
                        if !r.filedPaths.isEmpty {
                            Text("Filed: \(r.filedPaths.count) \(r.filedPaths.count == 1 ? "file" : "files")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !r.reminders.isEmpty {
                            Text("Reminders: " + r.reminders.map { "\($0.kind) \($0.dueDate.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !r.suggestion.note.isEmpty {
                            Text(r.suggestion.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Select a mail to review its AI suggestion.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func suggestionRows(_ s: MailFilingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            suggestionRow("Company", s.company)
            suggestionRow("Client", s.client)
            suggestionRow("Project", s.project)
            suggestionRow("Document", s.documentType)
            // targetFolder already starts with the category ("Finance / Acme").
            suggestionRow("Category", s.targetFolder.isEmpty ? s.category : s.targetFolder)
        }
        .font(.callout)
    }

    private func suggestionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value.isEmpty ? "—" : value).fontWeight(.medium)
        }
    }

    private var suggestionEditor: some View {
        VStack(spacing: 6) {
            editorField("Company", $draft.company)
            editorField("Client", $draft.client)
            editorField("Project", $draft.project)
            editorField("Document", $draft.documentType)
            editorField("Category", $draft.category)
            editorField("Folder", $draft.targetFolder)
        }
    }

    private func editorField(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.callout).frame(width: 80, alignment: .leading)
            TextField("—", text: binding).textFieldStyle(.roundedBorder).font(.callout)
        }
    }

    private func fileEditedSuggestion(_ record: MailInboxRecord, suggestion: MailFilingSuggestion) -> (MailInboxRecord, String?) {
        var updated = record
        updated.suggestion = suggestion
        let existingPaths = record.filedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if record.mail.attachments.isEmpty {
            updated.status = .linked
            updated.filedPaths = existingPaths
            return (updated, nil)
        }

        let existingAttachments = existingPaths.filter {
            URL(fileURLWithPath: $0).pathExtension.lowercased() != "eml"
        }
        if existingAttachments.count >= record.mail.attachments.count {
            updated.filedPaths = existingPaths
            updated.status = record.status == .reviewSuggested ? .reviewSuggested : .filed
            return (updated, nil)
        }

        let staged = record.mail.attachments.compactMap { meta -> ParsedAttachment? in
            guard let data = MailFilingService.stagedData(sha: meta.sha256) else { return nil }
            return ParsedAttachment(filename: meta.filename, mimeType: meta.mimeType, data: data)
        }
        guard !staged.isEmpty else {
            updated.filedPaths = existingPaths
            updated.status = .reviewSuggested
            return (updated, "Couldn't read the staged attachments. Import the mail again, then retry.")
        }

        let filed = MailFilingService.shared.fileAttachments(
            staged, email: nil, record: record, suggestion: suggestion, dmsRoot: dmsRoot)
        var paths = existingPaths
        for path in filed where !paths.contains(path) { paths.append(path) }
        updated.filedPaths = paths
        let filedAttachments = paths.filter {
            URL(fileURLWithPath: $0).pathExtension.lowercased() != "eml"
        }
        if filedAttachments.count >= record.mail.attachments.count {
            updated.status = .filed
            return (updated, nil)
        }
        updated.status = .reviewSuggested
        return (updated, "Filed \(filedAttachments.count) of \(record.mail.attachments.count) attachments. The mail stays in Review until every document is written.")
    }

    // MARK: Actions

    private func accept(_ r: MailInboxRecord) {
        var suggestion = r.suggestion
        suggestion.confidence = max(suggestion.confidence, MailFilingPolicy.autoFileThreshold)
        let result = fileEditedSuggestion(r, suggestion: suggestion)
        store.update(result.0)
        ruleMessage = result.1
        editing = false
    }

    private func saveEdit(_ r: MailInboxRecord) {
        draft.confidence = max(draft.confidence, MailFilingPolicy.autoFileThreshold)
        draft.targetFolder = draft.targetFolder.isEmpty
            ? MailClassifier.targetFolder(category: draft.category, entity: draft.client.isEmpty ? draft.company : draft.client)
            : draft.targetFolder
        let result = fileEditedSuggestion(r, suggestion: draft)
        store.update(result.0)
        ruleMessage = result.1
        editing = false
    }

    private func addRule() {
        let nl = ruleNL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nl.isEmpty else { return }
        if let r = MailRuleStore.shared.addFromNL(nl) {
            ruleMessage = "Rule added: \(r.name)"
            ruleNL = ""
        } else {
            ruleMessage = "Couldn't parse that as a rule — try “Sve račune sa @domain stavi u Folder” or “Sve CV-e na jobs@x poveži sa Recruitment”."
        }
    }

    /// Syncs Email/Inbox → pipeline → Email root (source .eml archived to Done).
    private func syncInbox(importSummary: String? = nil) {
        guard busy == nil else { return }
        busy = "Syncing mail…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MailFilingService.shared.sync()
            DispatchQueue.main.async {
                busy = nil
                let message: String
                if result.ingested == 0 && result.duplicates == 0 && result.failed == 0 {
                    message = "Inbox is empty — drop .eml files into \(MailFilingService.inboxDir().path)"
                } else {
                    var summary = ["\(result.ingested) new", "\(result.duplicates) duplicates"]
                    if result.failed > 0 { summary.append("\(result.failed) failed") }
                    message = "Sync: " + summary.joined(separator: ", ")
                }
                ruleMessage = [importSummary, message].compactMap { $0 }.joined(separator: " ")
                if let first = result.outcomes.compactMap(\.record).first {
                    selection = first.id
                }
            }
        }
    }

    // MARK: AI + reorganize

    private func runAI(_ pending: PendingAI) {
        let service = MailFilingService.shared
        switch pending {
        case .one(let r):
            let atts = service.attachments(for: r)
            guard !atts.isEmpty else {
                ruleMessage = "Couldn't read this mail's documents — the stored .eml is missing."
                return
            }
            busy = "Asking AI about “\(r.mail.subject)”…"
            service.upgradeWithAI(record: r, attachments: atts, dmsRoot: dmsRoot) { updated in
                busy = nil
                if updated.suggestion == r.suggestion {
                    ruleMessage = "AI had nothing to add (or the request failed) — \(AIService.shared.lastReplySummary)"
                } else {
                    ruleMessage = "AI updated “\(r.mail.subject)” — \(updated.suggestion.documentType) · \(updated.suggestion.entity)"
                    if selection == updated.id { draft = updated.suggestion }
                }
            }
        case .all(let records):
            let items = records.compactMap { r -> MailFilingService.EnrichBatchItem? in
                let atts = service.attachments(for: r)
                return atts.isEmpty ? nil : MailFilingService.EnrichBatchItem(record: r, attachments: atts)
            }
            guard !items.isEmpty else { ruleMessage = "No stored documents to send."; return }
            busy = "AI: preparing \(items.count) mails…"
            let ai = AIService.shared
            let model = ai.modelID, extraction = ai.extractionModel, keys = ai.apiKeys
            DispatchQueue.global(qos: .userInitiated).async {
                let updated = service.enrichBatch(items: items, model: model, extractionModel: extraction,
                                                  keys: keys, store: .shared) { batch, total in
                    DispatchQueue.main.async { busy = "AI: batch \(batch) of \(total)…" }
                }
                let before = Dictionary(items.map { ($0.record.id, $0.record.suggestion) }, uniquingKeysWith: { a, _ in a })
                let changed = updated.filter { before[$0.id] != $0.suggestion }.count
                DispatchQueue.main.async {
                    busy = nil
                    ruleMessage = "AI refined \(changed) of \(items.count) mails. Use Organize ▸ Reorganize All to move them into category folders."
                }
            }
        }
    }

    private func reorganize(_ records: [MailInboxRecord]) {
        let service = MailFilingService.shared
        var undo: [(previous: MailInboxRecord, result: MailFilingService.ReorganizeResult)] = []
        var moved = 0, renamed = 0, skipped = 0
        for r in records {
            // Documents already on disk move; mails still held in the Inbox
            // are written out from the stored .eml.
            let onDisk = r.filedPaths.contains { !$0.hasSuffix(".eml") && FileManager.default.fileExists(atPath: $0) }
            let atts = onDisk ? [] : service.attachments(for: r)
            let (_, res) = service.reorganize(r, attachments: atts, dmsRoot: dmsRoot, store: store)
            moved += res.moved; renamed += res.renamed; skipped += res.skipped
            if !res.moves.isEmpty || !res.created.isEmpty { undo.append((r, res)) }
        }
        lastReorganize = undo
        ruleMessage = "Reorganized: \(moved) moved, \(renamed) renamed\(skipped > 0 ? ", \(skipped) skipped" : "")."
            + (undo.isEmpty ? "" : " Organize ▸ Undo Reorganize puts them back.")
    }

    private func undoReorganize() {
        let service = MailFilingService.shared
        var failed = 0
        for entry in lastReorganize.reversed() {
            failed += service.undoReorganize(previous: entry.previous, result: entry.result, store: store)
        }
        ruleMessage = failed == 0 ? "Reorganize undone." : "Undone, but \(failed) files had moved since and stayed where they are."
        lastReorganize = []
    }

    private func importFromMail() {
        busy = "Reading the selection in Mail…"
        MailAppImporter.importSelection { result in
            busy = nil
            if let error = result.error {
                ruleMessage = error
            } else {
                syncInbox()
            }
        }
    }

    private func importEml() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eml")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        busy = "Copying .eml files…"
        let urls = panel.urls
        DispatchQueue.global(qos: .userInitiated).async {
            MailFilingService.ensureEmailDirs()
            let inbox = MailFilingService.inboxDir()
            var copied = 0
            var failed = 0
            for url in urls {
                let dest = MailFilingService.uniqueDestination(for: url, in: inbox)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    copied += 1
                } else {
                    failed += 1
                }
            }
            DispatchQueue.main.async {
                busy = nil
                let importSummary = failed > 0 ? "Imported \(copied) files; \(failed) could not be copied." : nil
                syncInbox(importSummary: importSummary)
            }
        }
    }

    // MARK: Dates

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: d)
    }

    private func longDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
