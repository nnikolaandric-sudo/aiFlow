import SwiftUI
import AppKit

// MARK: - Folder rules UI
//
// Tri ulaza:
//   • desni klik na folder (ili na prazno mjesto u folderu) → „Auto-Sort This
//     Folder" sa kvačicom + „Folder Rules…";
//   • prozor sa pravilima tog foldera (pisanje običnim jezikom, gotovi
//     šabloni, pregled na postojećim fajlovima, dnevnik sa Undo);
//   • Settings ▸ Folder Rules: glavni prekidač, AI prekidač (isključen =
//     ništa ne ide na mrežu), dnevni AI limit i spisak praćenih foldera.

// MARK: Context menu items

struct FolderRulesMenuItems: View {
    let folder: URL
    @ObservedObject private var service = FolderRulesService.shared

    var body: some View {
        let watched = service.isWatched(folder)
        let hasRules = !(service.folder(for: folder)?.rules.isEmpty ?? true)
        Toggle(isOn: Binding(
            get: { watched },
            set: { on in
                if on {
                    if let why = FolderRulesService.refusal(for: folder) {
                        FolderRulesWindowManager.alert(why)
                        return
                    }
                    service.setWatched(folder, true)
                    // Bez pravila nema šta da se radi — odmah otvori prozor.
                    if !hasRules { FolderRulesWindowManager.shared.open(folder) }
                } else {
                    service.setWatched(folder, false)
                }
            }
        )) {
            Label("Auto-Sort This Folder", systemImage: "wand.and.stars")
        }
        Button { FolderRulesWindowManager.shared.open(folder) } label: {
            Label(hasRules ? "Folder Rules…" : "Set Up Folder Rules…", systemImage: "list.bullet.rectangle")
        }
    }
}

// MARK: Window

final class FolderRulesWindowManager: NSObject, NSWindowDelegate {
    static let shared = FolderRulesWindowManager()
    private var windows: [String: NSWindow] = [:]

    func open(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if let existing = windows[path] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if FolderRulesService.shared.folder(for: folder) == nil {
            if let why = FolderRulesService.refusal(for: folder) { Self.alert(why); return }
            // Nov folder je uključen: bez pravila ionako ništa ne radi, a čim
            // korisnik doda pravilo, ono važi. Prekidač u prozoru ga gasi.
            FolderRulesService.shared.setWatched(folder, true)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: FolderRulesEditor(path: path)))
        window.title = "Folder Rules — \(folder.lastPathComponent)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 640))
        window.minSize = NSSize(width: 520, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[path] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
    }

    static func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Can't auto-sort this folder"
        a.informativeText = text
        a.runModal()
    }
}

// MARK: Editor

struct FolderRulesEditor: View {
    let path: String
    @ObservedObject private var service = FolderRulesService.shared
    @AppStorage(FolderRulesSettings.enabledKey) private var masterOn = true
    @AppStorage(FolderRulesSettings.useAIKey) private var useAI = false

    @State private var draft = ""
    @State private var parsing = false
    @State private var parseMessage: String?
    @State private var editing: FolderRule?
    @State private var preview: [FolderRulePlanItem]?
    @State private var previewNote: String?
    @State private var previewing = false
    @State private var applyMessage: String?

    private var folder: WatchedFolder? { service.folders.first { $0.path == path } }
    private var base: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !masterOn { pausedBanner }
                    rulesSection
                    addSection
                    existingSection
                    activitySection
                }
                .padding(18)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .sheet(item: $editing) { rule in
            FolderRuleEditorSheet(rule: rule, base: base) { saved in
                service.setRule(path, saved)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(base.lastPathComponent).font(.system(size: 15, weight: .semibold))
                Text(FolderRuleDestination.display(base))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if service.running.contains(path) { ProgressView().controlSize(.small) }
            Toggle("Auto-sort", isOn: Binding(
                get: { folder?.enabled ?? false },
                set: { service.setWatched(base, $0) }
            ))
            .toggleStyle(.switch)
            .help("Sort new files that land in this folder. Files already here wait for “Sort existing files”.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text("Auto-sorting is paused for all folders in Settings ▸ Folder Rules.")
                .font(.callout)
            Spacer()
            Button("Resume") {
                masterOn = true
                service.settingsChanged()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: FFTheme.cardShape)
    }

    // MARK: Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Rules", detail: "The first rule that fits a file wins.")
            let rules = folder?.rules ?? []
            if rules.isEmpty {
                Text("No rules yet — write one below or pick a starter.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: FFTheme.cardShape)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        ruleRow(rule, index: index, count: rules.count)
                        if index < rules.count - 1 { Divider().padding(.leading, 36) }
                    }
                }
                .background(Color.primary.opacity(0.04), in: FFTheme.cardShape)
            }
            if let note = service.notes[path] {
                Label(note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func ruleRow(_ rule: FolderRule, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { var r = rule; r.enabled = $0; service.setRule(path, r) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.summary(base: base))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !rule.source.isEmpty {
                    Text("“\(rule.source)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if rule.needsAI {
                Text(useAI ? "AI" : "AI off")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(useAI ? FFTheme.ai : .orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill((useAI ? FFTheme.ai : .orange).opacity(0.14)))
                    .help(useAI ? "Uses AI (counts toward today's AI limit)"
                                : "Needs AI, which is off in Settings — this rule is skipped")
            }
            Menu {
                Button("Edit…") { editing = rule }
                Button("Move Up") { service.moveRule(path, id: rule.id, by: -1) }.disabled(index == 0)
                Button("Move Down") { service.moveRule(path, id: rule.id, by: 1) }.disabled(index == count - 1)
                Divider()
                Button("Delete", role: .destructive) { service.deleteRule(path, id: rule.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Add

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Add a rule", detail: "Write it the way you'd say it.")
            HStack(spacing: 8) {
                TextField("e.g. PDF račune stavi u Documents/Računi", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addFromText)
                if parsing { ProgressView().controlSize(.small) }
                Button("Add", action: addFromText)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || parsing)
                    .keyboardShortcut(.defaultAction)
            }
            if let parseMessage {
                Text(parseMessage).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Starters:").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.starters, id: \.0) { title, text in
                    Button(title) { add(FolderRuleParser.parse(text)) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Button("Build a rule step by step…") {
                editing = FolderRule(conditions: [FolderRuleCondition(field: .kind, value: FolderRuleKind.pdf.rawValue)],
                                     action: FolderRuleAction(kind: .move, value: ""))
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    static let starters: [(String, String)] = [
        ("Screenshots", "screenshotove premjesti u Screenshots"),
        ("Invoices", "PDF račune stavi u Documents/Računi po godinama"),
        ("Old installers", "instalacije starije od 14 dana baci u smeće"),
        ("Archives", "arhive stavi u Archives"),
    ]

    private func add(_ rule: FolderRule?) {
        guard let rule else { return }
        service.setRule(path, rule)
    }

    private func addFromText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        parseMessage = nil
        if let rule = FolderRuleParser.parse(text) {
            add(rule)
            draft = ""
            return
        }
        guard useAI else {
            parseMessage = "Couldn't read that rule. Try e.g. “slike premjesti u Slike” or “zip starije od 30 dana baci u smeće” — or build it step by step. (AI could read free phrasing, but it is off in Settings ▸ Folder Rules.)"
            return
        }
        parsing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<FolderRule?, Error> = Result {
                let reply = try FolderRulesAI.complete(system: FolderRuleParser.aiSystemPrompt(), user: text, maxTokens: 400)
                return FolderRuleParser.decodeAI(reply, source: text)
            }
            DispatchQueue.main.async {
                parsing = false
                switch result {
                case .success(let rule?):
                    // AI-jevo čitanje se ne usvaja naslijepo: korisnik ga vidi i potvrdi.
                    editing = rule
                    draft = ""
                case .success(nil):
                    parseMessage = "Even AI couldn't turn that into a rule — try building it step by step."
                case .failure(let error):
                    parseMessage = "AI couldn't help: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Existing files

    private var existingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Files already here",
                         detail: "Auto-sort only touches new files. Check what the rules would do with the rest first.")
            HStack {
                Button(previewing ? "Checking…" : "Preview") {
                    previewing = true
                    applyMessage = nil
                    service.preview(path) { plan, note in
                        preview = plan
                        previewNote = note
                        previewing = false
                    }
                }
                .disabled(previewing || (folder?.rules.isEmpty ?? true))
                if let preview, !preview.isEmpty {
                    Button("Sort \(preview.count) \(preview.count == 1 ? "File" : "Files")") {
                        let plan = preview
                        self.preview = nil
                        service.apply(plan, in: path) { count, errors in
                            applyMessage = errors.isEmpty
                                ? "Sorted \(count) \(count == 1 ? "file" : "files"). Undo is below."
                                : "Sorted \(count); \(errors.count) failed — \(errors[0])"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            if let applyMessage {
                Text(applyMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let preview {
                if preview.isEmpty {
                    Text("Nothing here matches the rules.").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.prefix(60)) { item in
                            HStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.file.path))
                                    .resizable().frame(width: 16, height: 16)
                                Text(item.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(target(of: item)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            .font(.caption)
                        }
                        if preview.count > 60 {
                            Text("…and \(preview.count - 60) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: FFTheme.cardShape)
                }
                if let previewNote {
                    Label(previewNote, systemImage: "sparkles").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func target(of item: FolderRulePlanItem) -> String {
        switch item.action {
        case .move:  return item.destination.map { FolderRuleDestination.display($0, base: base) } ?? "—"
        case .trash: return "Trash"
        case .tag:   return "tag “\(item.tag ?? "")”"
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        let entries = service.activity.filter { $0.folder == path }.prefix(25)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent activity", detail: entries.isEmpty ? "Nothing sorted yet." : nil)
            if !entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(entries)) { e in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: e.kind))
                                .foregroundStyle(e.undone ? Color.secondary : Color.accentColor)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.fileName).font(.system(size: 12, weight: .medium))
                                    .strikethrough(e.undone).lineLimit(1).truncationMode(.middle)
                                Text(line(for: e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if e.undone {
                                Text("Undone").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Undo") { service.undo(e.id) }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(Color.primary.opacity(0.04), in: FFTheme.cardShape)
            }
        }
    }

    private func icon(for kind: FolderRuleAction.Kind) -> String {
        switch kind {
        case .move:  return "folder.fill"
        case .trash: return "trash.fill"
        case .tag:   return "tag.fill"
        }
    }

    private func line(for e: FolderRuleActivity) -> String {
        let when = e.date.formatted(date: .abbreviated, time: .shortened)
        switch e.kind {
        case .move:
            let dir = e.to.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            return "\(when) → \(dir.map { FolderRuleDestination.display($0, base: base) } ?? "")"
        case .trash: return "\(when) → Trash"
        case .tag:   return "\(when) → tag “\(e.tag ?? "")”"
        }
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Step-by-step rule editor

struct FolderRuleEditorSheet: View {
    @State var rule: FolderRule
    let base: URL
    let onSave: (FolderRule) -> Void
    let onCancel: () -> Void
    @AppStorage(FolderRulesSettings.useAIKey) private var useAI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rule").font(.headline)
            if !rule.source.isEmpty {
                Text("“\(rule.source)”").font(.caption).foregroundStyle(.secondary)
            }

            Text("When a new file…").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rule.conditions) { c in
                    let b = binding(c.id)
                    HStack(spacing: 6) {
                        Picker("", selection: b.field) {
                            ForEach(FolderRuleCondition.Field.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 170)
                        valueField(b)
                            .frame(width: 200, alignment: .leading)
                        Toggle("Not", isOn: b.negated)
                            .toggleStyle(.checkbox)
                            .help("Match files for which this is NOT true")
                        Button {
                            let id = c.id
                            rule.conditions.removeAll { $0.id == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button {
                        rule.conditions.append(FolderRuleCondition(field: .nameContains, value: ""))
                    } label: { Label("Add condition", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            if rule.needsAI && !useAI {
                Label("This rule uses AI, which is off in Settings ▸ Folder Rules — it will be skipped until AI is on.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Text("…then").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Picker("", selection: $rule.action.kind) {
                    ForEach(FolderRuleAction.Kind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                switch rule.action.kind {
                case .move:
                    TextField("Folder (e.g. Screenshots or ~/Documents/Računi/{year})", text: $rule.action.value)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                case .tag:
                    Picker("", selection: $rule.action.value) {
                        ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                case .trash:
                    Text("Only ever the Trash — never deleted permanently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rule.action.kind == .move, let dest = FolderRuleDestination.resolve(rule.action.value, base: base) {
                Text("Goes to \(FolderRuleDestination.display(dest))").font(.caption).foregroundStyle(.secondary)
                if rule.action.value.contains("{") {
                    Text("{year} and {month} come from the date printed in the document, else from when the file arrived.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 560)
        .frame(minHeight: 340)
        .onChange(of: rule.action.kind) { _, kind in
            if kind == .tag, !["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"].contains(rule.action.value) {
                rule.action.value = "Red"
            }
        }
    }

    /// Binding po id-u, ne po indeksu: brisanje uslova usred prikaza ne smije
    /// da gađa indeks koji više ne postoji.
    private func binding(_ id: String) -> Binding<FolderRuleCondition> {
        Binding(
            get: { rule.conditions.first { $0.id == id } ?? FolderRuleCondition(field: .nameContains, value: "") },
            set: { new in
                if let i = rule.conditions.firstIndex(where: { $0.id == id }) { rule.conditions[i] = new }
            }
        )
    }

    private var isValid: Bool {
        let conditionsOK = rule.conditions.allSatisfy { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let actionOK = rule.action.kind == .trash || !rule.action.value.trimmingCharacters(in: .whitespaces).isEmpty
        return conditionsOK && actionOK && !rule.conditions.isEmpty
    }

    @ViewBuilder
    private func valueField(_ c: Binding<FolderRuleCondition>) -> some View {
        switch c.wrappedValue.field {
        case .kind:
            Picker("", selection: c.value) {
                ForEach(FolderRuleKind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .onAppear {
                if FolderRuleKind(rawValue: c.wrappedValue.value) == nil { c.wrappedValue.value = FolderRuleKind.pdf.rawValue }
            }
        case .docType:
            Picker("", selection: c.value) {
                ForEach(FolderRuleDocType.all, id: \.self) { Text(FolderRuleDocType.label($0)).tag($0) }
            }
            .labelsHidden()
            .onAppear {
                if !FolderRuleDocType.all.contains(c.wrappedValue.value) { c.wrappedValue.value = "invoice" }
            }
        case .olderThanDays, .largerThanMB:
            TextField("number", text: c.value).textFieldStyle(.roundedBorder).frame(width: 90)
        case .ext:
            TextField("pdf, docx", text: c.value).textFieldStyle(.roundedBorder)
        case .ai:
            TextField("e.g. a travel booking or boarding pass", text: c.value).textFieldStyle(.roundedBorder)
        case .nameContains, .contentContains:
            TextField("text", text: c.value).textFieldStyle(.roundedBorder)
        case .issuer:
            TextField("e.g. Telekom", text: c.value).textFieldStyle(.roundedBorder)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = base
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            rule.action.value = FolderRuleDestination.display(url)
        }
    }
}

// MARK: Settings section

struct FolderRulesSettingsSection: View {
    @ObservedObject private var service = FolderRulesService.shared
    @ObservedObject private var ai = AIService.shared
    @AppStorage(FolderRulesSettings.enabledKey) private var masterOn = true
    @AppStorage(FolderRulesSettings.useAIKey) private var useAI = false
    @AppStorage(FolderRulesSettings.aiDailyLimitKey) private var dailyLimit = FolderRulesSettings.defaultDailyLimit
    @AppStorage(FolderRulesSettings.aiSendExcerptKey) private var sendExcerpt = false
    /// Osvježava brojač „danas" kad se sekcija pokaže.
    @State private var usedToday = FolderRulesSettings.aiUsedToday()

    var body: some View {
        Section {
            Text("Right-click a folder ▸ Auto-Sort This Folder, then write rules like “PDF račune stavi u Documents/Računi”. New files are sorted as they arrive; nothing is ever deleted permanently, and every move can be undone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Auto-sort watched folders", isOn: $masterOn)
                .onChange(of: masterOn) { _, _ in service.settingsChanged() }

            Toggle(isOn: $useAI) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use AI for folder rules")
                    Text(useAI
                         ? "AI reads free-form rules and answers “AI thinks it is …” conditions. Each check counts toward the daily limit and the AI Organizer's monthly cap."
                         : "Off: rules run entirely on this Mac — nothing is sent anywhere and no AI credits are used. Rules that need AI are skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if useAI {
                if ai.apiKeys.isEmpty {
                    Label("Add an OpenRouter key in the AI Organizer section above — until then AI rules are skipped.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Stepper(value: $dailyLimit, in: 1...500, step: 5) {
                    LabeledContent("Daily AI limit") {
                        Text("\(usedToday) of \(dailyLimit) used today").monospacedDigit()
                    }
                }
                Toggle("Send a short text excerpt, not only the file name", isOn: $sendExcerpt)
                    .help("Off: the model sees only the file name, kind and size. On: also up to 1,500 characters of text read locally from the file.")
            }

            if service.folders.isEmpty {
                Text("No folders yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(service.folders) { f in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.path))
                            .resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).lineLimit(1)
                            Text("\(f.rules.count) \(f.rules.count == 1 ? "rule" : "rules") · \(FolderRuleDestination.display(f.url))")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Edit…") { FolderRulesWindowManager.shared.open(f.url) }
                            .buttonStyle(.link)
                        Toggle("", isOn: Binding(get: { f.enabled }, set: { service.setWatched(f.url, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button {
                            service.removeFolder(f.path)
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Stop watching and forget this folder's rules")
                    }
                }
            }
        } header: {
            FFSectionHeader(title: "Folder Rules", symbol: "wand.and.stars", tint: .mint)
        }
        .onAppear { usedToday = FolderRulesSettings.aiUsedToday() }
    }
}

// MARK: Status bar badge

/// „Auto-sort · 3 today" u statusnoj traci dok gledaš praćeni folder.
struct FolderRulesStatusBadge: View {
    let currentPath: URL
    @ObservedObject private var service = FolderRulesService.shared

    var body: some View {
        if let f = service.folder(for: currentPath), f.enabled, !f.rules.isEmpty {
            let today = service.sortedToday(in: f.path)
            Button { FolderRulesWindowManager.shared.open(currentPath) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text(today > 0 ? "Auto-sort · \(today) today" : "Auto-sort on")
                }
                .font(.system(size: 11))
                .foregroundStyle(FolderRulesSettings.isEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(FolderRulesSettings.isEnabled
                  ? "This folder sorts new files by \(f.rules.count) \(f.rules.count == 1 ? "rule" : "rules") — click to edit"
                  : "Auto-sorting is paused in Settings — click to edit this folder's rules")
        }
    }
}
