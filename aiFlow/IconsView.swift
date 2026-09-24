import SwiftUI
import AppKit

struct IconsView: View {
    let files:       [FileItem]
    @Binding var selectedIDs: Set<String>
    let currentPath: URL
    let groupBy:     GroupBy
    let onNavigate:  (FileItem) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    /// Bedževi za Drive mirror (indeks se puni u pozadini, vidi GoogleDriveBadgeIndex).
    @ObservedObject var driveIndex = GoogleDriveBadgeIndex.shared
    /// Workspace bedževi (§13): verzija se spušta ćelijama kao
    /// `workspaceVersion` da `.equatable()` ćelije preslikaju na promjenu.
    @ObservedObject var workspaces = WorkspaceStore.shared
    @ObservedObject var favorites: FavoritesService
    var isSearching: Bool = false
    var isLoading: Bool = false
    var onBatchRename: (([FileItem]) -> Void)? = nil
    /// O(1) listing identitet — grupe se keširaju po njemu, klik ne hešira folder.
    var filesIdentity: UInt = 0
    var onSendToDiscord: (([FileItem]) -> Void)? = nil
    var sortAscending: Bool = true
    /// Empty-state "New File" CTA (nil keeps older call sites compiling).
    var onCreateFile: (() -> Void)? = nil
    /// Arrow-key navigation. Disabled for the primary pane in dual-pane mode
    /// so both panes don't answer the same arrows (secondary keeps them).
    var arrowsEnabled = true

    @State private var iconSize: CGFloat = 64
    /// Anchor for Shift-range selection: the last plain/Cmd-clicked icon.
    @State private var anchorID: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: iconSize + 20, maximum: iconSize + 40), spacing: 8)]
    }

    private var groups: [FileGroup] {
        if isSearching {
            return groupedItems(files, by: groupBy, ascending: sortAscending)
        }
        return groupedItems(files, by: groupBy, identity: filesIdentity, ascending: sortAscending)
    }

    /// Selekcija kao FileItems — izračunato JEDNOM po body eval, ne jednom po
    /// ćeliji. Pre je svaka od N ćelija filtrirala ceo folder (O(n²) po kliku).
    private func selectedTargets(selected: Set<String>) -> [FileItem] {
        guard !selected.isEmpty else { return [] }
        if selected.count == 1, let id = selected.first {
            return files.first(where: { $0.id == id }).map { [$0] } ?? []
        }
        return files.filter { selected.contains($0.id) }
    }

    var body: some View {
        // Read the selection binding once instead of several times per cell.
        let selected = selectedIDs
        // Drops anywhere in the grid land in the current folder; folder icons
        // are wrapped with FolderDropRow below for precise targets.
        DropCatcher(destination: currentPath,
                    folderName: currentPath.lastPathComponent,
                    fileOps: fileOps,
                    onReload: onReload) {
            iconsBody(selected: selected)
        }
    }

    @ViewBuilder
    private func iconsBody(selected: Set<String>) -> some View {
        // Jedan O(n) prolaz za celu mrežu — prosleđuje se ćelijama da svaka
        // ne filtrira folder ponovo (bilo O(n²) po kliku).
        let selectedItems = selectedTargets(selected: selected)
        VStack(spacing: 0) {
            if files.isEmpty {
                if isLoading {
                    LoadingFolderView(folderName: currentPath.lastPathComponent)
                } else {
                    EmptyFolderView(
                        folderName: currentPath.lastPathComponent,
                        isSearching: isSearching,
                        onCreateFolder: {
                            NotificationCenter.default.post(name: .createNewFolder, object: nil)
                        },
                        onCreateFile: onCreateFile ?? {
                            NotificationCenter.default.post(name: .createNewFile, object: nil)
                        }
                    )
                }
            } else {
            // GeometryReader feeds the arrow-key handler the live grid width
            // (column count for ↑/↓); ScrollViewReader follows the selection.
            GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(group.items) { item in
                                    let isSel = selected.contains(item.id)
                                    FolderDropRow(item: item, fileOps: fileOps, onReload: onReload,
                                                  onSpringOpen: { onNavigate($0) }) {
                                        // .equatable(): nepromenjene ćelije se preskaču —
                                        // na klik se re-renderuju samo pogodjene, ne cela mreža.
                                        // Bedž se čita u telu ćelije (samo vidljive), a verzija
                                        // indeksa je tu da se ćelija preslika kad podaci stignu —
                                        // pre je roditelj zvao kind(for:) za SVIH N (7.8k string
                                        // operacija po kliku), sada je to O(vidljivih).
                                        IconCell(item: item, iconSize: iconSize, isSelected: isSel,
                                                 driveVersion: driveIndex.version,
                                                 workspaceVersion: workspaces.version)
                                            .equatable()
                                    }
                                        .fileDragOut(item: item, files: files, selectedIDs: selected)
                                        .contentShape(FFTheme.controlShape)
                                        // One tap handler: a separate double-tap gesture made every
                                        // single click wait out the double-click interval.
                                        // Finder: each click selects first, double-click opens.
                                        .onTapGesture {
                                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                                handleIconTap(item)
                                                onNavigate(item)
                                            } else {
                                                handleIconTap(item)
                                            }
                                        }
                                        .accessibilityElement(children: .ignore)
                                         .accessibilityLabel("\(item.name), \(item.kind), \(GitService.shared.status(for: item.url)?.state.label ?? "clean")")
                                        .accessibilityAddTraits(isSel ? [.isButton, .isSelected] : .isButton)
                                        .contextMenu { iconContextMenu(item: item, selectedItems: selectedItems) }
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 16)
                        } header: {
                            if groupBy != .none, !group.title.isEmpty {
                                DateSectionHeader(title: group.title, count: group.items.count)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .background(arrowKeyButtons(gridWidth: geo.size.width, proxy: proxy))
            // Programski reveal (paste/rename/extract…) → scroll do prvog
            // selektovanog. Klik već gleda vidljivu ikonu pa je scrollTo no-op;
            // zato je bezopasno slušati svaku promjenu selekcije.
            .onChange(of: selectedIDs) { _, new in
                guard !new.isEmpty else { return }
                let flat = groups.flatMap(\.items)
                guard let first = flat.first(where: { new.contains($0.id) }) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(first.id) }
            }
            } // ScrollViewReader
            } // GeometryReader
            } // files.isEmpty else

            HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                    Slider(value: $iconSize, in: 32...128, step: 8).frame(width: 140)
                        .help("Icon size")
                        .accessibilityLabel("Icon size")
                        .padding(.vertical, 2)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                    if selectedItems.count > 1 {
                        Text("\(selectedItems.count) selected")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .ffBadge()
                            .padding(.leading, 4)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }

    // MARK: - Finder-style multi-select (Cmd-toggle, Shift-range, plain single)

    private func handleIconTap(_ item: FileItem) {
        let flags = NSEvent.modifierFlags.intersection([.command, .shift])
        if flags.contains(.command) {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
            anchorID = item.id
        } else if flags.contains(.shift) {
            // Range across the flat display order (groups concatenated as
            // shown) — `files` order is wrong when grouped. Same as ListView.
            let flat = groups.flatMap(\.items)
            guard let tappedIndex = flat.firstIndex(where: { $0.id == item.id }) else {
                selectedIDs = [item.id]; anchorID = item.id; return
            }
            // Anchor on the last clicked item (Finder behaviour).
            if let anchor = anchorID,
               let anchorIndex = flat.firstIndex(where: { $0.id == anchor }) {
                let lo = min(anchorIndex, tappedIndex)
                let hi = max(anchorIndex, tappedIndex)
                selectedIDs = Set(flat[lo...hi].map(\.id))
            } else {
                selectedIDs = [item.id]
                anchorID = item.id
            }
        } else {
            selectedIDs = [item.id]
            anchorID = item.id
        }
    }

    @ViewBuilder
    private func iconContextMenu(item: FileItem, selectedItems: [FileItem]) -> some View {
        // Ista semantika kao pre: puna selekcija kad postoji, inače kliknuti
        // red — samo je O(n) filter hoistovan jednom po body eval, ne po ćeliji.
        // Finder semantika: desni klik na SELEKTOVANU ikonu → cijela selekcija,
        // na neselektovanu → samo ta ikona (prije je meni radio na staroj
        // selekciji, pa npr. "Sign…" nije bilo za kliknuti PDF).
        let targets = selectedItems.contains(where: { $0.id == item.id }) ? selectedItems : [item]
        FileContextMenuContent(
            targets: targets,
            currentPath: currentPath,
            fileOps: fileOps,
            favorites: favorites,
            onNavigate: onNavigate,
            onBrowseInto: onBrowseInto,
            onRename: { promptRename(item: $0) },
            onBatchRename: onBatchRename,
            onSendToDiscord: onSendToDiscord,
            onReload: onReload
        )
    }

    private func quickLook() {
        let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(urls)
    }

    // MARK: - Arrow-key navigation (Finder parity)

    /// Hidden shortcuts: Space lives here too (was a lone background button).
    /// Plain arrows move single selection; Shift extends the range from the
    /// anchor; selection is followed with scroll. List/Table have this
    /// natively — the grid never did, so keyboard users were mouse-bound.
    private func arrowKeyButtons(gridWidth: CGFloat, proxy: ScrollViewProxy) -> some View {
        Group {
            Button("") { guard !isEditingText() else { return }; quickLook() }
                .keyboardShortcut(.space, modifiers: []).hidden()
            Button("") { arrowMove(dx: -1, dy: 0, extend: false, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.leftArrow, modifiers: []).hidden()
            Button("") { arrowMove(dx: 1, dy: 0, extend: false, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.rightArrow, modifiers: []).hidden()
            Button("") { arrowMove(dx: 0, dy: -1, extend: false, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.upArrow, modifiers: []).hidden()
            Button("") { arrowMove(dx: 0, dy: 1, extend: false, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.downArrow, modifiers: []).hidden()
            Button("") { arrowMove(dx: -1, dy: 0, extend: true, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift]).hidden()
            Button("") { arrowMove(dx: 1, dy: 0, extend: true, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift]).hidden()
            Button("") { arrowMove(dx: 0, dy: -1, extend: true, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.upArrow, modifiers: [.shift]).hidden()
            Button("") { arrowMove(dx: 0, dy: 1, extend: true, gridWidth: gridWidth, proxy: proxy) }
                .keyboardShortcut(.downArrow, modifiers: [.shift]).hidden()
        }
    }

    private func arrowMove(dx: Int, dy: Int, extend: Bool, gridWidth: CGFloat,
                           proxy: ScrollViewProxy) {
        guard arrowsEnabled, !isEditingText(), !sliderFocused() else { return }
        let flat = groups.flatMap(\.items)
        guard !flat.isEmpty else { return }
        // Adaptive grid: cells stretch between min..max, so the column count
        // is approximate — good enough for ↑/↓ jumps.
        let cols = max(1, Int((gridWidth + 8) / (iconSize + 28)))
        let cur: Int?
        if let a = anchorID, let i = flat.firstIndex(where: { $0.id == a }) {
            cur = i
        } else if let id = selectedIDs.first, let i = flat.firstIndex(where: { $0.id == id }) {
            cur = i
        } else {
            cur = nil
        }
        let next: Int
        if let cur {
            next = min(max(cur + dx + dy * cols, 0), flat.count - 1)
        } else {
            // Nothing selected: start at the edge in the pressed direction.
            next = (dx + dy) < 0 ? flat.count - 1 : 0
        }
        if extend, let a = anchorID, let ai = flat.firstIndex(where: { $0.id == a }) {
            let lo = min(ai, next), hi = max(ai, next)
            selectedIDs = Set(flat[lo...hi].map(\.id))
        } else {
            selectedIDs = [flat[next].id]
            anchorID = flat[next].id
        }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(flat[next].id, anchor: .center) }
    }

    /// The icon-size slider eats arrow keys when focused — don't fight it.
    private func sliderFocused() -> Bool {
        guard let fr = NSApp.keyWindow?.firstResponder else { return false }
        return fr is NSSlider
    }

    private func promptRename(item: FileItem) {
        FileRenamePrompt.rename(item, fileOps: fileOps, reload: onReload)
    }

    private func showGetInfo(for items: [FileItem]) {
        showGetInfoInFinder(items.map(\.url))
    }
}

struct IconCell: View {
    let item: FileItem; let iconSize: CGFloat; let isSelected: Bool
    /// Verzija Drive indeksa: bedž se čita u `body` (samo za nacrtane ćelije),
    /// a ovo polje je tu da se ćelija preslika kad indeks stigne iz pozadine.
    /// (Isto kao GroupedRowContainer — roditelj nikad ne zove kind(for:) po ćeliji.)
    var driveVersion: Int = 0
    /// Verzija Workspace store-a (§13): bedž se čita u `body`, a ovo polje
    /// tjera preslikavanje kad task/review/expiry/share stigne.
    var workspaceVersion: UInt = 0
    /// Git status bedž (M/A/D/?/!): ćelija posmatra GitService direktno —
    /// `.equatable()` gasi samo parent-driven update-e (isto kao GroupedRow).
    @ObservedObject var git = GitService.shared
    @State private var hovering = false
    @Environment(\.ffCompactRows) private var compact
    var body: some View {
        // Bedž se računa ovde, ne u roditelju: roditelj instancira svih N
        // ćelija po kliku, a body se izvršava samo za vidljive/preslikane.
        let driveBadge = GoogleDriveBadgeIndex.shared.kind(for: item)
        let wsBadge = WorkspaceStore.shared.badge(for: item.url)
        let gitStatus = git.status(for: item.url)
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                FileIconView(item: item, size: iconSize)
                    .frame(minWidth: iconSize + 16, minHeight: iconSize + 8)
                if !item.tagColors.isEmpty {
                    TagDotsView(colors: item.tagColors, size: 9)
                        .padding(4)
                }
                if let driveBadge {
                    GoogleDriveBadgeView(kind: driveBadge, size: 12)
                        .padding(3)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            // Ime: dva reda, a preko toga skraćivanje po sredini (Finder) —
            // prije se lomilo gdje stigne pa je „interview.mp3" bio
            // „interview.mp" + „3". Bez dodatnog horizontalnog paddinga ima
            // ~8 pt više širine, taman da kratka imena stanu u jedan red.
            Text(item.name)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? .white : .primary)
                .help(item.name)
            if let wsBadge {
                WorkspaceBadgeView(badge: wsBadge)
            }
            GitBadgeView(status: gitStatus, size: 10)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 6 : 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            isSelected ? AnyShapeStyle(FFTheme.heroGradient)
            : (hovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Color.clear)),
            in: FFTheme.cardShape
        )
        .shadow(color: isSelected ? Color.accentColor.opacity(0.25) : Color.clear, radius: 6, y: 2)
        .onHover { hovering = $0 }
    }
}

extension IconCell: Equatable {
    // Same as GroupedRow: skip cells whose content + selection state is
    // unchanged when the grid rebuilds on selection change.
    static func == (lhs: IconCell, rhs: IconCell) -> Bool {
        lhs.item == rhs.item && lhs.iconSize == rhs.iconSize && lhs.isSelected == rhs.isSelected
            && lhs.driveVersion == rhs.driveVersion
            && lhs.workspaceVersion == rhs.workspaceVersion
    }
}
