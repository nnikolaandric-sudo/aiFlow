import SwiftUI

// MARK: - Send to Discord sheet
//
// Picker for the recipient (channel = project, person = DM) + an optional
// message + the file list. Folders and >25 MB files can't go through
// Discord — they're listed as warnings instead of failing the whole send.

struct SendToDiscordSheet: View {
    let files: [FileItem]
    @ObservedObject var discord: DiscordShareService
    /// Called with the toast message on success (parent shows + dismisses).
    var onSent: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTargetID: String?
    @State private var message: String = ""
    @State private var sending = false
    @State private var sentCount = 0
    @State private var totalCount = 0
    @State private var errorText: String?

    private var urls: [URL] { files.map(\.url) }

    /// Particija se racuna jednom po otvaranju/promeni fajlova, ne na svaki
    /// body eval: fileExists + stat po fajlu na svako slovo u message polju
    /// bi seckalo kucanje na vecim selekcijama.
    @State private var part: DiscordShareService.Partition = .init()

    private var selectedTarget: DiscordTarget? {
        discord.targets.first(where: { $0.id == selectedTargetID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.discordGradient)
                        .frame(width: 30, height: 30)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send to Discord")
                        .font(.system(size: 13, weight: .semibold))
                    if part.files.count > 0 {
                        Text("\(part.files.count) file\(part.files.count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .ffBadge()
                    }
                }
            }

            if !discord.isTokenSet {
                missingTokenView
            } else if discord.targets.isEmpty {
                missingTargetsView
            } else {
                sendForm
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 460)
        .onAppear {
            if selectedTargetID == nil { selectedTargetID = discord.targets.first?.id }
            part = discord.partition(urls: urls)
        }
    }

    // MARK: - Form

    private var sendForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Send to", selection: $selectedTargetID) {
                ForEach(discord.targets) { t in
                    Text("\(t.name) — \(t.kind == .channel ? "channel" : "DM")")
                        .tag(Optional(t.id))
                }
            }
            .pickerStyle(.menu)

            Text("Message (optional)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .frame(height: 64)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(FFTheme.cardShape)
                .overlay(FFTheme.cardShape
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
                .disabled(sending)

            fileList

            if let errorText {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.callout)
                    Text(errorText)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
            }

            if sending {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Sending \(sentCount)/\(totalCount)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack {
                Spacer()
                // Cancel stays live during send — it cancels the upload
                // instead of dismissing (previously disabled, wedging the
                // sheet on slow networks).
                Button("Cancel") { sending ? discord.cancelSend() : dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sendLabel) { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(part.files.count) file\(part.files.count == 1 ? "" : "s") to send")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(part.files.enumerated()), id: \.offset) { _, f in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(f.url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    ForEach(Array(part.folders.enumerated()), id: \.offset) { _, name in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.hierarchical)
                            Text("“\(name)” is a folder — compress it first (folders can't be sent).")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    ForEach(Array(part.oversized.enumerated()), id: \.offset) { _, o in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.hierarchical)
                            Text("“\(o.name)” is over Discord's 25 MB limit.")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    ForEach(Array(part.unreadable.enumerated()), id: \.offset) { _, name in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.hierarchical)
                            Text("“\(name)” can't be read — moved, deleted, or no permission.")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - Empty states

    private var missingTokenView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.softGradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "key.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text("No Discord bot token set.")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("Add your bot token in Settings → Discord, then add the channels (projects) and people you want to send files to.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var missingTargetsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.softGradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text("No recipients yet.")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("Add channels (projects) and people in Settings → Discord. You'll need the channel ID or user ID (Discord → Settings → Advanced → Developer Mode → right-click → Copy ID).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Send

    private var canSend: Bool {
        !sending && discord.isTokenSet && selectedTarget != nil && !part.files.isEmpty
    }

    private var sendLabel: String {
        if sending { return "Sending…" }
        let n = part.files.count
        if let t = selectedTarget {
            return "Send \(n) file\(n == 1 ? "" : "s") to \(t.name)"
        }
        return "Send"
    }

    private func send() {
        guard let target = selectedTarget, !part.files.isEmpty else { return }
        sending = true
        errorText = nil
        totalCount = part.files.count
        sentCount = 0
        discord.send(urls: urls, message: message, to: target, progress: { sent, total in
            sentCount = sent
            totalCount = total
        }, completion: { result in
            sending = false
            switch result {
            case .success(let n):
                let label = n == 1 ? "1 file" : "\(n) files"
                onSent("Sent \(label) to \(target.name) on Discord")
                dismiss()
            case .failure(let e):
                // Chunks before the failing one already landed on Discord —
                // say how far it got so a retry doesn't blindly duplicate.
                errorText = (sentCount > 0 ? "Sent \(sentCount)/\(totalCount) before the error. " : "")
                    + e.localizedDescription
            }
        })
    }
}
