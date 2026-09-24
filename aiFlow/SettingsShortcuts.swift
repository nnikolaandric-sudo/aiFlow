import SwiftUI

// MARK: - Shortcuts category detail

/// Shortcuts detail pane: inline reference grouped by area.
/// The full reference also opens in its own window (⇧⌘/).
struct ShortcutsSettingsDetail: View {
    var body: some View {
        Form {
            ShortcutsSettingsSection()
        }
        .formStyle(.grouped)
    }
}
