import SwiftUI
import ServiceManagement

// MARK: - General category detail

/// General detail pane: app updates, launch-at-login, default file manager.
struct GeneralSettingsDetail: View {
    var body: some View {
        Form {
            UpdatesSettingsSection()
            StartupSettingsSection()
            DefaultFileManagerSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

struct UpdatesSettingsSection: View {
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var updateStatusMessage: String?

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { updateManager.autoCheckEnabled },
            set: { updateManager.autoCheckEnabled = $0 }
        )
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: updateManager.currentVersion)
                .fontDesign(.monospaced)
            Toggle("Check for updates automatically", isOn: autoCheckBinding)
            Button("Check for Updates…") {
                updateStatusMessage = nil
                Task {
                    await updateManager.checkForUpdates(force: true)
                    switch updateManager.phase {
                    case .upToDate:
                        updateStatusMessage = "You're on the latest version."
                    case .available(let v, _, _, _):
                        updateStatusMessage = "Version \(v) is available — use the banner in the main window to install."
                    case .error(let m):
                        updateStatusMessage = m
                    default:
                        break
                    }
                }
            }
            if let updateStatusMessage {
                Text(updateStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            FFSectionHeader(title: "Updates", symbol: "arrow.down.circle.fill", tint: .blue)
        }
    }
}

// MARK: - Startup

/// Launch at Login — same `launchAtLogin` key and SMAppService registration
/// as the app-menu toggle, so both stay in sync.
struct StartupSettingsSection: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    if #available(macOS 13.0, *) {
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                    Text("aiFlow starts automatically when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            FFSectionHeader(title: "Startup", symbol: "power", tint: .green)
        }
    }
}
