import SwiftUI

// MARK: - Browse category detail

/// Browse detail pane: browse defaults (view, sort, grouping) + text editor.
struct BrowseSettingsDetail: View {
    var body: some View {
        Form {
            BrowseDefaultsSettingsSection()
            TextEditorSettingsSection()
            VersionSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Browse defaults

struct BrowseDefaultsSettingsSection: View {
    @AppStorage(UserPreferences.viewModeKey)       private var viewModeRaw    = UserPreferences.defaultViewMode.rawValue
    @AppStorage(UserPreferences.sortFieldKey)      private var sortFieldRaw   = UserPreferences.defaultSortField.rawValue
    @AppStorage(UserPreferences.sortAscendingKey)  private var sortAscending  = UserPreferences.defaultSortAscending
    @AppStorage(UserPreferences.groupByKey)        private var groupByRaw     = UserPreferences.defaultGroupBy.rawValue
    @AppStorage(UserPreferences.folderOrderKey)    private var folderOrderRaw = UserPreferences.defaultFolderOrder.rawValue
    @AppStorage(UserPreferences.showFolderSizesKey) private var showFolderSizes = false

    var body: some View {
        Section {
            Text("New installs start with Finder-like settings: list view, date-modified groups sorted newest first, folders on top. Reset restores those defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $showFolderSizes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calculate folder sizes")
                    Text("Shows each folder's recursive size in the Size column, totals and Get Info — computed in the background and cached. Cloud files that aren't downloaded are skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Reset to Finder defaults") {
                UserPreferences.applyFactoryBrowseDefaults()
                viewModeRaw    = UserPreferences.defaultViewMode.rawValue
                sortFieldRaw   = UserPreferences.defaultSortField.rawValue
                sortAscending  = UserPreferences.defaultSortAscending
                groupByRaw     = UserPreferences.defaultGroupBy.rawValue
                folderOrderRaw = UserPreferences.defaultFolderOrder.rawValue
            }
        } header: {
            FFSectionHeader(title: "Browse defaults", symbol: "folder.fill", tint: .indigo)
        }
    }
}

// MARK: - Text editor

struct TextEditorSettingsSection: View {
    @AppStorage("ffEditorSniffUnknown") private var sniffUnknown = true

    var body: some View {
        Section {
            Toggle(isOn: $sniffUnknown) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open unknown file types in the editor")
                    Text("When on, files without a known code extension open in aiFlow’s editor if they look like text. When off, only known text/code files do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            FFSectionHeader(title: "Text editor", symbol: "doc.text.fill", tint: .orange)
        }
    }
}
