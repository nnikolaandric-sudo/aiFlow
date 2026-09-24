import SwiftUI
import AppKit

// MARK: - Mail Inbox window + Settings
//
// Wire-up za Mail DMS (MAIL-01..03): MailInboxView je samostalan, pa mu treba
// samo mesto za prikaz — jedan reusable prozor (obrazac FolderRulesWindowManager,
// bez path-ključa jer postoji samo jedan inbox) — plus Settings ▸ Mail Inbox
// sekcija za Email folder i pravila.

// MARK: Window

final class MailInboxWindowManager: NSObject, NSWindowDelegate {
    static let shared = MailInboxWindowManager()
    private var window: NSWindow?

    func open() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: MailInboxView()))
        window.title = "Mail Inbox"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 560))
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        window = nil
    }
}

// MARK: Settings section

struct MailInboxSettingsSection: View {
    @ObservedObject private var store = MailStore.shared
    @ObservedObject private var ruleStore = MailRuleStore.shared
    @AppStorage(UserPreferences.mailRootKey) private var mailRootOverride = ""
    @AppStorage(MailInboxWatcher.enabledKey) private var autoSync = false
    @ObservedObject private var watcher = MailInboxWatcher.shared
    @State private var ruleInstalled = MailRuleInstaller.isInstalled
    @State private var ruleStatus: String?

    private var emailRoot: URL { MailFilingService.emailRoot() }

    var body: some View {
        Section {
            Text("Drop .eml files (or a Mail.app rule) into the Email folder's Inbox, then Sync — attachments are filed by company, project and document type, with Accept/Change review. ≥98% confidence files itself on ingest; nothing is ever deleted, only filed to Trash-safe folders.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Email folder") {
                Text(emailRoot.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(emailRoot.path)
            }
            HStack {
                Button("Change…") { chooseRoot() }
                    .controlSize(.small)
                Button("Reveal") {
                    MailFilingService.ensureEmailDirs()
                    NSWorkspace.shared.open(emailRoot)
                }
                    .buttonStyle(.link)
                    .controlSize(.small)
                if !mailRootOverride.isEmpty {
                    Button("Reset to default") { mailRootOverride = ""; MailInboxWatcher.shared.refresh() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                Spacer()
                Button("Open Mail Inbox") { MailInboxWindowManager.shared.open() }
                    .controlSize(.small)
            }
            Toggle("Sync automatically while aiFlow runs", isOn: $autoSync)
                .onChange(of: autoSync) { MailInboxWatcher.shared.refresh() }
            if autoSync, let msg = watcher.lastMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Mail.app rule") {
                HStack(spacing: 8) {
                    Text(ruleInstalled ? "Script installed" : "Not installed")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(ruleInstalled ? "Reinstall" : "Install Script") { installRule() }
                        .controlSize(.small)
                }
            }
            Text(ruleStatus ?? "Saves incoming mail from any Mail.app account into the Email folder's Inbox. After installing: Mail ▸ Settings ▸ Rules ▸ Add Rule, pick your condition (start narrow, e.g. From contains @firma.ba), action “Run AppleScript” ▸ FinderFlowSave. Existing mail: select it ▸ Message ▸ Apply Rules.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Automation rules") {
                Text(ruleStore.rules.isEmpty
                     ? "None yet — add one in the inbox (“Sve račune sa @… stavi u …”)."
                     : "\(ruleStore.rules.count) active")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Filed mail") {
                Text("\(store.inbox.count) inbox · \(store.review.count) review · \(store.filed.count) filed")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } header: {
            FFSectionHeader(title: "Mail Inbox", symbol: "tray.full", tint: .blue)
        }
    }

    private func installRule() {
        if let error = MailRuleInstaller.install() {
            ruleStatus = "Couldn't install the script: \(error)"
            return
        }
        ruleInstalled = true
        // The rule only drops files; auto-sync is what files them.
        autoSync = true
        MailInboxWatcher.shared.refresh()
        ruleStatus = "Installed FinderFlowSave into Mail's scripts and turned on auto-sync. Restart Mail, then Mail ▸ Settings ▸ Rules ▸ Add Rule ▸ action “Run AppleScript” ▸ FinderFlowSave. If you change the Email folder, press Reinstall."
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "All mail content and evidence is filed under this folder."
        if panel.runModal() == .OK, let url = panel.url {
            mailRootOverride = url.path
            MailInboxWatcher.shared.refresh()
        }
    }
}
