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
    /// Drop support: fajlovi se mogu spustiti na tab da se premjeste/
    /// kopiraju u njegov folder (ista Finder semantika kao sidebar).
    /// Optional da stari call site-ovi ostanu kompajlirani.
    var fileOps: FileOperationsService? = nil
    var onReload: (() -> Void)? = nil

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
                            onDuplicate: { onDuplicate(tab) },
                            fileOps: fileOps,
                            onReload: onReload
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
    /// Drop support (vidi BrowserTabBar): kad su postavljeni, tab je i
    /// drop target — fajlovi se spustaju u njegov folder.
    var fileOps: FileOperationsService? = nil
    var onReload: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isTargeted = false
    @State private var dropIsCopy = false
    @State private var dropIsForbidden = false
    @State private var dropSources: [URL] = []
    @State private var springWork: DispatchWorkItem?

    private var canDrop: Bool { fileOps != nil && onReload != nil }

    var body: some View {
        chipContent
            .contentShape(FFTheme.controlShape)
            .onTapGesture { onSelect() }
            .onHover { isHovering = $0 }
            // Drag-out: tab je proxy svog foldera (kao sidebar/breadcrumb) —
            // povuci tab u Finder ili u drugi pane za copy/move.
            .fileDragOutURLs([tab.path])
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
            .help("\(tab.path.path) — ⌘T novi tab, ⇧⌘W zatvori · prevuci fajlove ovde za premještanje")
            .onChange(of: isTargeted) { _, targeted in
                springWork?.cancel()
                springWork = nil
                // Spring-open kao folderi: zadrzi hover 0.8 s i tab se
                // aktivira usred draga pa drop moze i dublje.
                if targeted, !isActive {
                    let select = onSelect
                    let work = DispatchWorkItem { select() }
                    springWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                }
            }
    }

    @ViewBuilder
    private var chipContent: some View {
        let label = HStack(spacing: 5) {
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
        if canDrop, let fileOps, let onReload {
            DropHighlight(isTargeted: isTargeted, isCopy: dropIsCopy,
                          isForbidden: dropIsForbidden) { label }
                .onDrop(of: [.fileURL, .text],
                        delegate: TabDropDelegate(destination: tab.path,
                                                  fileOps: fileOps,
                                                  onReload: onReload,
                                                  isTargeted: $isTargeted,
                                                  dropIsCopy: $dropIsCopy,
                                                  dropIsForbidden: $dropIsForbidden,
                                                  sources: $dropSources))
        } else {
            label
        }
    }
}

/// Struct delegate (vidi RowDropDelegate): zero cost dok drag ne hoveruje.
/// Ista Finder semantika — isti volumen → move, drugi → copy, Option → copy.
private struct TabDropDelegate: DropDelegate {
    let destination: URL
    let fileOps: FileOperationsService
    let onReload: () -> Void
    @Binding var isTargeted: Bool
    @Binding var dropIsCopy: Bool
    @Binding var dropIsForbidden: Bool
    @Binding var sources: [URL]

    func validateDrop(info: DropInfo) -> Bool {
        FileDropSupport.carriesFiles(info.itemProviders(for: [.fileURL, .text]))
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        sources = []
        dropIsForbidden = false
        dropIsCopy = NSEvent.modifierFlags.contains(.option)
        FileDropSupport.hoverCursor(valid: true)
        let dest = destination
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { return }
            sources = urls
            dropIsForbidden = FileDropSupport.isForbidden(sources: urls, destination: dest)
            dropIsCopy = !FileDropSupport.shouldMove(sources: urls, destination: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !sources.isEmpty && FileDropSupport.isForbidden(sources: sources, destination: destination) {
            dropIsForbidden = true
            return DropProposal(operation: .forbidden)
        }
        dropIsForbidden = false
        let copy: Bool
        if sources.isEmpty {
            copy = NSEvent.modifierFlags.contains(.option)
        } else {
            copy = !FileDropSupport.shouldMove(sources: sources, destination: destination)
        }
        dropIsCopy = copy
        return DropProposal(operation: copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dropIsForbidden = false
        sources = []
        FileDropSupport.hoverCursor(valid: false)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        dropIsForbidden = false
        FileDropSupport.hoverCursor(valid: false)
        let dest = destination
        let ops = fileOps
        let reload = onReload
        if !sources.isEmpty {
            let urls = sources
            sources = []
            guard !FileDropSupport.isForbidden(sources: urls, destination: dest) else {
                NSSound.beep()
                return false
            }
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
            return true
        }
        sources = []
        FileDropSupport.urls(from: info.itemProviders(for: [.fileURL, .text])) { urls in
            guard !urls.isEmpty else { NSSound.beep(); return }
            guard !FileDropSupport.isForbidden(sources: urls, destination: dest) else {
                NSSound.beep()
                return
            }
            ops.importURLs(urls, to: dest,
                           shouldMove: FileDropSupport.shouldMove(sources: urls, destination: dest),
                           reload: reload)
        }
        return true
    }
}
