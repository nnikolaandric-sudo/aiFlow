import SwiftUI
import AppKit

// MARK: - Browser tabs (FinderFlow+ UX: tabovi kao u browseru)
//
// Jedan prozor, vise foldera: svaki tab pamti svoju putanju. Istorija
// (Back/Forward), search i selekcija ostaju vezani za aktivni tab preko
// ContentView-a: promena taba postavlja currentPath, a navigacija upisuje
// putanju nazad u aktivni tab. Per-tab istorija je namerna sledeca faza —
// zasad je globalna (Back moze da predje preko tabova), sto je dokumentovano
// ogranicenje v1.

struct BrowserTab: Identifiable, Hashable {
    let id: UUID
    var path: URL

    init(id: UUID = UUID(), path: URL) {
        self.id = id
        self.path = path
    }

    var title: String {
        let last = path.lastPathComponent
        return last.isEmpty ? "/" : last
    }
}

// MARK: - Persistencija

enum BrowserTabsStore {
    static let tabsKey = "ffOpenTabs"
    static let activeKey = "ffActiveTabIndex"

    /// Sacuvane putanje tabova; samo postojece browsable foldere.
    static func load() -> (paths: [URL], active: Int)? {
        guard let raw = UserDefaults.standard.stringArray(forKey: tabsKey),
              !raw.isEmpty else { return nil }
        let urls = raw.compactMap { URL(fileURLWithPath: $0) }
            .filter { FileItem.isBrowsableFolder($0) }
        guard !urls.isEmpty else { return nil }
        let active = UserDefaults.standard.integer(forKey: activeKey)
        let clamped = min(max(0, active), urls.count - 1)
        return (urls, clamped)
    }

    static func save(paths: [URL], active: Int) {
        UserDefaults.standard.set(paths.map(\.path), forKey: tabsKey)
        UserDefaults.standard.set(active, forKey: activeKey)
    }

    /// Pocetno stanje za prvi frejm (bez treperenja prazne trake):
    /// sacuvani tabovi ili jedan Home tab. UUID-ovi su sesijski —
    /// persistuju se samo putanje + aktivni indeks.
    static func initial() -> (tabs: [BrowserTab], activeID: UUID?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let saved = load() else {
            let tab = BrowserTab(path: home)
            return ([tab], tab.id)
        }
        let tabs = saved.paths.map { BrowserTab(path: $0) }
        let idx = min(max(0, saved.active), tabs.count - 1)
        return (tabs, tabs[idx].id)
    }
}

// MARK: - Tab bar

/// Traka tabova iznad path/search reda: scrollabilni tabovi + "+" dugme.
/// Compact visina (~30pt) da ne jede prostor za fajlove.
struct BrowserTabBar: View {
    @Binding var tabs: [BrowserTab]
    @Binding var activeID: UUID?
    var onSelect: (BrowserTab) -> Void = { _ in }
    var onNewTab: () -> Void = {}
    var onClose: (BrowserTab) -> Void = { _ in }
    var onCloseOthers: (BrowserTab) -> Void = { _ in }
    var onDuplicate: (BrowserTab) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        BrowserTabChip(
                            tab: tab,
                            isActive: tab.id == activeID,
                            canClose: tabs.count > 1,
                            onSelect: { onSelect(tab) },
                            onClose: { onClose(tab) },
                            onCloseOthers: { onCloseOthers(tab) },
                            onDuplicate: { onDuplicate(tab) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

private struct BrowserTabChip: View {
    let tab: BrowserTab
    let isActive: Bool
    let canClose: Bool
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onCloseOthers: () -> Void = {}
    var onDuplicate: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            URLIconView(url: tab.path, isDirectory: true, isPackage: false, size: 14)
                .frame(width: 18, height: 18)

            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
                .help(tab.path.path)

            if canClose, isActive || isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab (⇧⌘W)")
                .accessibilityLabel("Close Tab \(tab.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            FFTheme.controlShape.fill(isActive ? Color.accentColor.opacity(0.13) : Color.clear)
        )
        .overlay(
            FFTheme.controlShape
                .strokeBorder(Color.accentColor.opacity(isActive ? 0.35 : 0), lineWidth: 1)
        )
        .contentShape(FFTheme.controlShape)
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Duplicate Tab") { onDuplicate() }
            Divider()
            Button("Close Tab", role: .destructive) { onClose() }
                .disabled(!canClose)
            Button("Close Other Tabs") { onCloseOthers() }
                .disabled(!canClose)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path.path, forType: .string)
                NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
            }
            Button("Reveal in Finder") {
                FinderReveal.reveal(path: tab.path.path)
            }
        }
        .help("\(tab.path.path) — ⌘T novi tab, ⇧⌘W zatvori")
    }
}
