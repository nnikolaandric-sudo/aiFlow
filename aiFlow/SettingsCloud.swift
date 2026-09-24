import SwiftUI

// MARK: - Cloud category detail

/// Cloud detail pane: sidebar cloud folders + native Google Drive sync.
struct CloudSettingsDetail: View {
    var body: some View {
        Form {
            CloudSidebarSettingsSection()
            GoogleDriveSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sidebar cloud folders

struct CloudSidebarSettingsSection: View {
    @EnvironmentObject var cloudFolders: CloudFoldersService
    @AppStorage("ffShowCloudFolders") private var showCloudFolders = true

    var body: some View {
        Section {
            Toggle(isOn: $showCloudFolders) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show cloud folders")
                    Text("Google Drive, iCloud Drive, OneDrive, Dropbox and other sync folders appear as regular folders in the sidebar (Cloud section).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Cloud accounts")
                .font(.headline)
                .padding(.top, 4)
            Text("Auto-detection covers ~/Library/CloudStorage and iCloud Drive. Add more accounts here — a second Google account, a custom OneDrive path, Dropbox…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if cloudFolders.customURLs.isEmpty {
                Text("No manually added accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(cloudFolders.customURLs, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SidebarRow.cloudDisplayName(for: url))
                            .fontWeight(.medium)
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        cloudFolders.remove(url)
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .help("Remove cloud account from the sidebar")
                }
            }
            Button {
                CloudFoldersService.pickFolder { picked in
                    if let picked { cloudFolders.add(picked) }
                }
            } label: {
                Label("Add Cloud Account…", systemImage: "plus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .fontWeight(.medium)
        } header: {
            FFSectionHeader(title: "Sidebar", symbol: "sidebar.left", tint: .teal)
        }
    }
}
