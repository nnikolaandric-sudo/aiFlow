import SwiftUI

// MARK: - Default file manager

/// "Open folders in FinderFlow" toggle + status, plus the can/can't-do notes
/// folded into a DisclosureGroup so they don't occupy permanent space.
struct DefaultFileManagerSettingsSection: View {
    @State private var isDefault = DefaultFolderHandler.isDefault
    @State private var status = DefaultFolderHandler.status
    @State private var working = false
    @State private var statusMessage: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isDefault },
                set: { applyDefault($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open folders in aiFlow")
                        .font(.headline)
                    Text("Routes folder-open actions (the `open` command, other apps, and “Open With”) to aiFlow instead of Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(working)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status != .off {
                Label(status == .active
                      ? "Active — folders and “Show in Finder” from other apps open in aiFlow."
                      : "“Show in Finder” from other apps opens aiFlow now. Folders opened by other apps switch after you log out and back in — macOS applies the folder handler at login.",
                      systemImage: status == .active ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(status == .active ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("What this can and can't do") {
                VStack(alignment: .leading, spacing: 8) {
                    capabilityRow(symbol: "checkmark.circle.fill", tint: .green,
                                  text: "aiFlow opens when you open a folder from Terminal, other apps, or “Open With”.")
                    capabilityRow(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                  text: "Finder can't be fully replaced. The Desktop, drive mounting, Open/Save dialogs and the Dock’s Finder icon always stay Finder.")
                    capabilityRow(symbol: "arrow.clockwise.circle.fill", tint: .secondary,
                                  text: "Some changes only take effect after you log out and back in (or restart).")
                }
                .padding(.top, 4)
            }
            .font(.caption)
        } header: {
            FFSectionHeader(title: "Default file manager", symbol: "arrow.up.forward.app.fill", tint: .pink)
        }
        .onAppear {
            isDefault = DefaultFolderHandler.isDefault
            status = DefaultFolderHandler.status
        }
    }

    private func capabilityRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyDefault(_ enable: Bool) {
        working = true
        statusMessage = nil
        let onDone: (Error?) -> Void = { error in
            working = false
            isDefault = DefaultFolderHandler.isDefault
            status = DefaultFolderHandler.status
            if let error {
                statusMessage = "Couldn’t update the setting: \(error.localizedDescription)"
            } else if enable {
                statusMessage = status == .active
                    ? "aiFlow is now the default for folders and “Show in Finder”."
                    : "Done. “Show in Finder” from other apps opens aiFlow right away; folders opened by other apps switch after you log out and back in (macOS applies it at login)."
            } else {
                statusMessage = "Finder restored as the default for folders (fully after the next login)."
            }
        }
        if enable {
            DefaultFolderHandler.makeDefault(onDone)
        } else {
            DefaultFolderHandler.restoreFinder(onDone)
        }
    }
}
