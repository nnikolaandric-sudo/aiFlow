import SwiftUI

// MARK: - AI category detail

/// AI detail pane: AI Organizer (OpenRouter keys, models, caps) + Folder Rules.
struct AISettingsDetail: View {
    var body: some View {
        Form {
            AIOrganizerSettingsSection()
            FolderRulesSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Organizer

struct AIOrganizerSettingsSection: View {
    @ObservedObject private var ai = AIService.shared
    @State private var aiKeyDraft = ""
    @State private var aiKeyNote: String?
    @State private var aiCapDraft = ""

    var body: some View {
        Section {
            Text("Suggests better names by content for the current folder or the selected files, via OpenRouter (toolbar ✨ or File → Organize with AI… ⌥⌘O). You review the plan before anything moves; one ⌘Z undoes a whole run. Off until you paste a key below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("API keys") {
                HStack(spacing: 5) {
                    Image(systemName: ai.apiKeys.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(ai.apiKeys.isEmpty ? .orange : .green)
                    Text(ai.apiKeys.isEmpty ? "Not set" : "\(ai.apiKeys.count) saved in Keychain")
                        .foregroundStyle(ai.apiKeys.isEmpty ? .secondary : .primary)
                }
                .font(.caption)
                .fontWeight(.medium)
            }
            if !ai.apiKeys.isEmpty {
                ForEach(Array(ai.apiKeys.enumerated()), id: \.offset) { index, key in
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(index == 0 ? "Key 1 (primary)" : "Key \(index + 1) (fallback)")
                                .fontWeight(.medium)
                            Text(AIService.maskedKey(key))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }
                        Spacer()
                        Button {
                            ai.removeKey(at: index)
                            aiKeyNote = ai.apiKeys.isEmpty ? "All keys removed." : "Key \(index + 1) removed."
                        } label: {
                            Label("Remove Key \(index + 1)", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .help("Remove Key \(index + 1)")
                    }
                }
            }
            SecureField("Paste OpenRouter key (sk-or-…)", text: $aiKeyDraft)
            HStack {
                Button(ai.apiKeys.isEmpty ? "Save Key" : "Add Fallback Key") {
                    let draft = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if ai.apiKeys.isEmpty {
                        ai.setKey(draft)
                        aiKeyNote = "Key saved in Keychain."
                    } else if ai.addFallbackKey(draft) {
                        aiKeyNote = "Fallback Key \(ai.apiKeys.count) saved — tried automatically when an earlier key hits its limit."
                    } else {
                        aiKeyNote = ai.apiKeys.contains(draft) ? "That key is already saved." : "Paste a key first."
                    }
                    aiKeyDraft = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if ai.isKeySet {
                    Button(ai.apiKeys.count > 1 ? "Clear All" : "Clear Key", role: .destructive) {
                        ai.clearKeys()
                        aiKeyDraft = ""
                        aiKeyNote = "Keys removed."
                    }
                    .controlSize(.small)
                }
            }
            if let aiKeyNote {
                Text(aiKeyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Keys are tried in order — when Key 1 is rate-limited (429), out of credits (402) or rejected (401), Key 2 takes over automatically, then Key 3, and so on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Model", text: $ai.modelID)
                .fontDesign(.monospaced)
                .help("Any OpenRouter model slug. :free models cost $0.")
            AIModelPicker(title: "Choose model", selection: $ai.modelID, models: AIService.suggestedModels)
            TextField("Extraction model (Jev cascade)", text: $ai.extractionModelID)
                .fontDesign(.monospaced)
                .help("Chat model that extracts names, numbers and dates when Jev is selected (Jev itself only returns typed decisions). Default is the free tier — paste a paid slug if :free models throttle you.")
            AIModelPicker(title: "Choose extraction", selection: $ai.extractionModelID,
                          models: AIService.suggestedModels.filter { !AIService.isJevModel($0) })
            Text("Jev classifies (type, language, currency); this model extracts the strings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(":free models have strict limits even on paid accounts — a cheap paid slug avoids 429s and still costs fractions of a cent per run.")

            HStack {
                Text("Monthly cap")
                Spacer()
                TextField("$", text: $aiCapDraft)
                    .frame(width: 92)
                    .multilineTextAlignment(.trailing)
                    .fontDesign(.monospaced)
                    .onAppear { aiCapDraft = String(format: "%.2f", ai.monthlyCapUSD) }
                Button("Set") {
                    if let v = Double(aiCapDraft.replacingOccurrences(of: ",", with: ".")), v > 0 {
                        ai.monthlyCapUSD = v
                        aiCapDraft = String(format: "%.2f", v)
                    }
                }
                .disabled(Double(aiCapDraft.replacingOccurrences(of: ",", with: ".")) == nil)
            }
            Stepper("Files per request: \(ai.maxFiles)", value: $ai.maxFiles, in: 10...500, step: 10)
                .help("Big folders are processed batch by batch, one request per batch, all under a single Undo. Lower it if a model's replies get cut off.")
            Stepper("Reply budget: \(ai.maxReplyTokens / 1000)k tokens", value: $ai.maxReplyTokens, in: 4_000...128_000, step: 4_000)
                .help("Most tokens a model may use per request, thinking included. Free models cost nothing; paid models are charged only for what they use. Each model's own limit still applies.")
            Toggle(isOn: $ai.reviewBeforeApply) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review changes before applying")
                    Text("Shows every suggested name and folder first — untick or edit any of them. When off, the plan is applied as soon as it arrives (still one ⌘Z).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $ai.sendPreviews) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read file contents")
                    Text("Reads documents so names say what's inside — an invoice gets its number, issuer and date. Scanned PDFs and photos are read on this Mac with OCR; the text excerpts go to the model. When off, only names, sizes and dates are sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text("Spent this month: \(String(format: "$%.4f", ai.monthSpend())) / \(String(format: "$%.2f", ai.monthlyCapUSD))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { ai.resetSpend() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text("Free (:free) models cost $0 but are rate-limited. Paid models stop before the cap.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            FFSectionHeader(title: "AI Organizer", symbol: "sparkles", tint: FFTheme.ai)
        }
    }
}

// MARK: - AI model dropdown

/// Dropdown over curated OpenRouter slugs (free, cheap paid, Jev classifier).
/// The text field next to it stays for custom slugs; a custom value appears
/// as its own row so the picker never goes blank.
struct AIModelPicker: View {
    let title: String
    @Binding var selection: String
    let models: [String]

    /// Input $/M prices, verified against openrouter.ai (Sep 2026).
    private static let priceTags: [String: String] = [
        "qwen/qwen3.7-flash": "$0.03/M",
        "inclusionai/ling-3.0-flash": "$0.02/M",
        "deepseek/deepseek-v4-flash-0731": "$0.04/M",
        "z-ai/glm-4.7-flash": "$0.06/M",
        "meta/muse-spark-1.3-contributor": "$0.10/M",
        "google/gemini-2.5-flash-lite": "$0.10/M",
        "xiaomi/mimo-v2.6-flash": "$0.14/M",
        "z-ai/glm-5.3-flash": "$0.15/M",
    ]

    private var rows: [String] {
        models.contains(selection) ? models : models + [selection]
    }

    private static func label(_ id: String) -> String {
        let short = id.split(separator: "/").last.map(String.init) ?? id
        if id.hasSuffix(":free") { return "\(short) · free" }
        if id.lowercased().contains("jev") { return "\(short) · classifier $0.042/M" }
        if let p = priceTags[id] { return "\(short) · \(p) in" }
        return short
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(rows, id: \.self) { id in
                Text(Self.label(id)).tag(id)
            }
        }
        .pickerStyle(.menu)
    }
}
