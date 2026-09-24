import SwiftUI

// MARK: - Mail category detail

/// Mail detail pane: Mail Inbox filing + ⌥⌘A attach integration.
/// (The section views themselves stay in MailInboxWindow.swift and
/// MailAttachPicker.swift, next to the code they configure.)
struct MailSettingsDetail: View {
    var body: some View {
        Form {
            MailInboxSettingsSection()
            MailAttachSettingsSection()
        }
        .formStyle(.grouped)
    }
}
