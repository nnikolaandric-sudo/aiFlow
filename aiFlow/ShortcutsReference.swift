import SwiftUI
import AppKit

// MARK: - Keyboard shortcuts reference
//
// Jedan izvor istine za spisak prečica: isti model koriste i prozor
// (Help ▸ Keyboard Shortcuts, ⇧⌘/) i Settings ▸ Shortcuts sekcija.
// Spisak je ručno usklađen sa keyboardShortcut-ovima u kodu (meni stavke u
// FinderFlowCommands + skriveni Button("") u ContentView/List/Icons/Columns).

struct ShortcutEntry: Identifiable {
    let id = UUID()
    let title: String
    let keys: String
}

struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let entries: [ShortcutEntry]
}

enum KeyboardShortcuts {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Files & editing", symbol: "doc.fill", entries: [
            ShortcutEntry(title: "New Folder", keys: "⇧⌘N"),
            ShortcutEntry(title: "New Text File", keys: "⌥⌘N"),
            ShortcutEntry(title: "Move to Trash", keys: "⌘⌫"),
            ShortcutEntry(title: "Get Info", keys: "⌘I"),
            ShortcutEntry(title: "Send via Mail…", keys: "⇧⌘M"),
            ShortcutEntry(title: "Attach from aiFlow…", keys: "⌥⌘A"),
            ShortcutEntry(title: "Organize with AI…", keys: "⌥⌘O"),
            ShortcutEntry(title: "Sign Document…", keys: "⌥⌘E"),
            ShortcutEntry(title: "Mail Inbox…", keys: "⌥⌘M"),
            ShortcutEntry(title: "Today", keys: "⌘0"),
            ShortcutEntry(title: "Undo / Redo", keys: "⌘Z / ⇧⌘Z"),
            ShortcutEntry(title: "Copy / Cut / Paste", keys: "⌘C / ⌘X / ⌘V"),
            ShortcutEntry(title: "Duplicate", keys: "⌘D"),
            ShortcutEntry(title: "Copy path", keys: "⌥⌘C"),
            ShortcutEntry(title: "Select all", keys: "⌘A"),
        ]),
        ShortcutGroup(title: "Navigation", symbol: "arrow.left.arrow.right", entries: [
            ShortcutEntry(title: "Command palette (actions, places, tasks)", keys: "⌘K"),
            ShortcutEntry(title: "Back / Forward", keys: "⌘[ / ⌘]"),
            ShortcutEntry(title: "Enclosing folder", keys: "⌘↑"),
            ShortcutEntry(title: "Go to Folder…", keys: "⇧⌘G"),
            ShortcutEntry(title: "Open selection", keys: "⌘↓"),
            ShortcutEntry(title: "Up one folder", keys: "⌫"),
            ShortcutEntry(title: "Clear selection", keys: "Esc"),
            ShortcutEntry(title: "Type a path", keys: "⌘L"),
            ShortcutEntry(title: "Open file palette", keys: "⇧⌘F"),
        ]),
        ShortcutGroup(title: "Preview & selection", symbol: "eye.fill", entries: [
            ShortcutEntry(title: "Quick Look", keys: "Space"),
            ShortcutEntry(title: "Move (icon view)", keys: "← → ↑ ↓"),
            ShortcutEntry(title: "Extend selection (icon view)", keys: "⇧← → ↑ ↓"),
            ShortcutEntry(title: "Parent column (column view)", keys: "←"),
        ]),
        ShortcutGroup(title: "Tabs", symbol: "square.on.square", entries: [
            ShortcutEntry(title: "New tab", keys: "⌘T"),
            ShortcutEntry(title: "Close tab", keys: "⇧⌘W"),
            ShortcutEntry(title: "Next / Previous tab", keys: "⌃Tab / ⌃⇧Tab"),
        ]),
        ShortcutGroup(title: "View", symbol: "list.bullet", entries: [
            ShortcutEntry(title: "As List / Icons / Columns", keys: "⌘1 / ⌘2 / ⌘3"),
            ShortcutEntry(title: "Show hidden files", keys: "⇧⌘."),
            ShortcutEntry(title: "Show preview", keys: "⌥⌘P"),
            ShortcutEntry(title: "Column filter bar", keys: "⌥⌘F"),
            ShortcutEntry(title: "Calculate folder sizes", keys: "⌥⌘S"),
            ShortcutEntry(title: "Dual pane", keys: "⌥⌘D"),
            ShortcutEntry(title: "Refresh", keys: "⌘R"),
        ]),
        ShortcutGroup(title: "Git", symbol: "arrow.triangle.branch", entries: [
            ShortcutEntry(title: "View changes (preview Diff)", keys: "⌥⌘G"),
            ShortcutEntry(title: "Repository status", keys: "⇧⌘G"),
            ShortcutEntry(title: "History", keys: "⌥⌘H"),
        ]),
        ShortcutGroup(title: "Dialogs", symbol: "macwindow", entries: [
            ShortcutEntry(title: "Confirm", keys: "⏎"),
            ShortcutEntry(title: "Apply (AI Organizer, Batch Rename)", keys: "⌘⏎"),
            ShortcutEntry(title: "Cancel / close", keys: "Esc"),
        ]),
        ShortcutGroup(title: "Code editor", symbol: "chevron.left.forwardslash.chevron.right", entries: [
            ShortcutEntry(title: "Save", keys: "⌘S"),
            ShortcutEntry(title: "Command palette", keys: "⌘⇧P"),
            ShortcutEntry(title: "Find / Replace", keys: "⌘F"),
            ShortcutEntry(title: "Go to line", keys: "⌘L"),
            ShortcutEntry(title: "Open file in new tab", keys: "⌘O"),
        ]),
        ShortcutGroup(title: "Markdown & E-Sign", symbol: "pencil.and.scribble", entries: [
            ShortcutEntry(title: "Save", keys: "⌘S"),
            ShortcutEntry(title: "Save signed copy (E-Sign)", keys: "⌘S"),
            ShortcutEntry(title: "Done / close", keys: "Esc"),
        ]),
        ShortcutGroup(title: "Help", symbol: "questionmark.circle", entries: [
            ShortcutEntry(title: "This reference", keys: "⇧⌘/"),
        ]),
    ]
}

// MARK: Keycap + rows (shared by window and Settings)

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ShortcutRow: View {
    let entry: ShortcutEntry

    var body: some View {
        HStack {
            Text(entry.title)
            Spacer()
            Keycap(text: entry.keys)
        }
    }
}

// MARK: Window

struct ShortcutsReferenceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(KeyboardShortcuts.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(group.title, systemImage: group.symbol)
                            .font(.headline)
                        ForEach(group.entries) { ShortcutRow(entry: $0) }
                    }
                }
            }
            .padding(18)
        }
        .frame(minWidth: 420, minHeight: 400)
    }
}

final class ShortcutsWindowManager: NSObject, NSWindowDelegate {
    static let shared = ShortcutsWindowManager()
    private var window: NSWindow?

    func open() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsReferenceView()))
        window.title = "Keyboard Shortcuts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 620))
        window.minSize = NSSize(width: 420, height: 400)
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

struct ShortcutsSettingsSection: View {
    var body: some View {
        Section {
            Text("Every shortcut in one place — press ⇧⌘/ anywhere to open this reference in its own window.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Keyboard Shortcuts") { ShortcutsWindowManager.shared.open() }
                .controlSize(.small)
            ForEach(KeyboardShortcuts.groups) { group in
                DisclosureGroup {
                    ForEach(group.entries) { ShortcutRow(entry: $0) }
                } label: {
                    Label(group.title, systemImage: group.symbol)
                }
            }
        } header: {
            FFSectionHeader(title: "Shortcuts", symbol: "keyboard.fill", tint: .purple)
        }
    }
}
