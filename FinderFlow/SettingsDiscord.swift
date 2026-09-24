import SwiftUI

// MARK: - Discord category detail

/// Discord detail pane: bot token + recipients for "Send to Discord…".
struct DiscordSettingsDetail: View {
    var body: some View {
        Form {
            DiscordSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Discord

struct DiscordSettingsSection: View {
    @ObservedObject private var discord = DiscordShareService.shared
    @State private var tokenDraft = ""
    @State private var tokenNote: String?
    @State private var newTargetName = ""
    @State private var newTargetID = ""
    @State private var newTargetKind = DiscordTarget.Kind.channel

    var body: some View {
        Section {
            Text("Send files to a Discord channel (project) or a person (DM) via your bot — right-click → “Send to Discord…”. The bot must be on that server with permission to post; DMs need a shared server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Bot token") {
                HStack(spacing: 5) {
                    Image(systemName: discord.isTokenSet ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(discord.isTokenSet ? .green : .orange)
                    Text(discord.isTokenSet ? "Saved in Keychain" : "Not set")
                        .foregroundStyle(discord.isTokenSet ? .primary : .secondary)
                }
                .font(.caption)
                .fontWeight(.medium)
            }
            SecureField("Paste bot token", text: $tokenDraft)
            HStack {
                Button("Save Token") {
                    discord.setToken(tokenDraft)
                    tokenDraft = ""
                    tokenNote = "Token saved in Keychain."
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if discord.isTokenSet {
                    Button("Clear Token", role: .destructive) {
                        discord.setToken("")
                        tokenDraft = ""
                        tokenNote = "Token removed."
                    }
                    .controlSize(.small)
                }
            }
            if let tokenNote {
                Text(tokenNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Recipients")
                .font(.headline)
                .padding(.top, 4)
            if discord.targets.isEmpty {
                Text("No recipients yet. Add a channel or a person below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(discord.targets) { t in
                HStack(spacing: 8) {
                    Image(systemName: t.kind == .channel ? "number.circle.fill" : "person.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14))
                        .foregroundStyle(t.kind == .channel ? FFTheme.discord : .secondary)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name)
                            .fontWeight(.medium)
                        Text("\(t.kind.rawValue) • \(t.trimmedDiscordID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontDesign(.monospaced)
                    }
                    Spacer()
                    // Explicit button: Form rows have no swipe-to-delete on macOS.
                    Button {
                        discord.removeTarget(id: t.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .help("Remove recipient")
                }
            }

            TextField("Name (e.g. backend-tim, Jovan)", text: $newTargetName)
            TextField("Channel ID or User ID", text: $newTargetID)
                .fontDesign(.monospaced)
            Picker("Type", selection: $newTargetKind) {
                ForEach(DiscordTarget.Kind.allCases) { k in
                    Text(k.rawValue).tag(k)
                }
            }
            .pickerStyle(.segmented)
            Button("Add Recipient") {
                discord.addTarget(name: newTargetName, discordID: newTargetID, kind: newTargetKind)
                newTargetName = ""
                newTargetID = ""
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(newTargetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || newTargetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("IDs: Discord → Settings → Advanced → Developer Mode → right-click a channel/user → Copy ID. Files over 25 MB and folders can't be sent (compress folders first).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            FFSectionHeader(title: "Discord", symbol: "paperplane.fill", tint: FFTheme.discord)
        }
    }
}
