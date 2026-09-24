import SwiftUI
import AppKit

/// One Excel-style column filter shared by Table + Grouped list filter bars.
/// Kept internal (not private) so GroupedListView reuses the same columns,
/// placeholders and matchers — one filter language everywhere.
enum FilterColumn: String, CaseIterable, Identifiable {
    case name, kind, ext, size, modified, created
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .ext: return "Extension"
        case .size: return "Size"
        case .modified: return "Modified"
        case .created: return "Created"
        }
    }

    var placeholder: String {
        switch self {
        case .name: return "Filter by name…"
        case .kind: return "Filter by kind (e.g. PDF)…"
        case .ext: return "Filter by extension (e.g. pdf)…"
        case .size: return "Size: e.g. >10MB, <500KB, =2GB…"
        case .modified, .created: return "Date: e.g. 2026-09 or 2026-09-22…"
        }
    }

    func matches(_ item: FileItem, query: String) -> Bool {
        switch self {
        case .name:
            return item.name.localizedCaseInsensitiveContains(query)
        case .kind:
            return item.kind.localizedCaseInsensitiveContains(query)
        case .ext:
            return item.fileExtension.localizedCaseInsensitiveContains(query)
                || ("folder".hasPrefix(query.lowercased()) && item.isDirectory)
        case .size:
            return Self.matchSize(item.size, query: query)
        case .modified:
            return Self.matchDate(item.dateModified, query: query)
                || item.formattedDateModified.localizedCaseInsensitiveContains(query)
        case .created:
            return Self.matchDate(item.dateCreated, query: query)
                || item.formattedDateCreated.localizedCaseInsensitiveContains(query)
        }
    }

    /// `>10MB`, `<500KB`, `>=2GB`, `=100` (bare number = MB).
    private static func matchSize(_ bytes: Int64, query: String) -> Bool {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var op: (Int64, Int64) -> Bool = { $0 == $1 }
        if q.hasPrefix(">=") { op = (>=); q = String(q.dropFirst(2)) }
        else if q.hasPrefix("<=") { op = (<=); q = String(q.dropFirst(2)) }
        else if q.hasPrefix(">") { op = (>); q = String(q.dropFirst()) }
        else if q.hasPrefix("<") { op = (<); q = String(q.dropFirst()) }
        else if q.hasPrefix("=") { q = String(q.dropFirst()) }
        q = q.trimmingCharacters(in: .whitespaces)
        var mult: Double = 1024 * 1024 // bare number = MB
        for (suffix, m) in [("tb", 1024.0*1024*1024*1024), ("gb", 1024.0*1024*1024),
                            ("mb", 1024.0*1024), ("kb", 1024.0), ("b", 1.0)] {
            if q.hasSuffix(suffix) {
                mult = m
                q = String(q.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let num = Double(q.replacingOccurrences(of: ",", with: ".")),
              num.isFinite,
              num >= 0,
              num <= Double(Int64.max) / mult else { return false }
        return op(bytes, Int64(num * mult))
    }

    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Matches `2026`, `2026-09` or `2026-09-22` prefixes of the ISO date.
    private static func matchDate(_ date: Date, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.range(of: #"^\d{4}(-\d{1,2})?(-\d{1,2})?$"#, options: .regularExpression) != nil else { return false }
        return isoDate.string(from: date).lowercased().hasPrefix(q)
    }
}

struct ListView: View {
    let files:         [FileItem]
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    let currentPath:   URL
    @Binding var sortField:     SortField
    @Binding var sortAscending: Bool
    let groupBy:       GroupBy
    let onNavigate:    (FileItem) -> Void
    let onBrowseInto:  (URL) -> Void
    let onReload:      () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    /// Bedževi za Drive mirror (vidi GoogleDriveBadgeIndex).
    @ObservedObject var driveIndex = GoogleDriveBadgeIndex.shared
    /// Workspace bedževi (§13) i u flat tabeli: verzija ulazi u styleToken
    /// pa se vidljivi AppKit redovi preslikaju na promjenu.
    @ObservedObject var workspaces = WorkspaceStore.shared
    /// Git status bedževi (M/A/D/?/!): verzija ulazi u styleToken i spušta se
    /// Git status bedževi (M/A/D/?/!): verzija ulazi u styleToken pa se
    /// vidljivi AppKit redovi preslikaju; SwiftUI redovi (GroupedRow)
    /// posmatraju GitService direktno.
    @ObservedObject var git = GitService.shared
    var isSearching: Bool = false
    var isLoading: Bool = false
    var onBatchRename: (([FileItem]) -> Void)? = nil
    /// O(1) listing identitet od roditelja — grupisanje se memoizuje po njemu,
    /// pa klik na selekciju ne hešira ceo folder ponovo.
    var filesIdentity: UInt = 0
    var onSendToDiscord: (([FileItem]) -> Void)? = nil
    /// Show the plain list even without grouping. Search results use it: the
    /// Table hosts every cell in its own view, so each result update rebuilt
    /// hundreds of views (profiled: ~95% of main-thread time while typing).
    var showsFlatList: Bool = false
    /// While a folder-size run is in flight, unsized folders render "…"
    /// instead of "—" in Size cells.
    var sizingActive: Bool = false

    @State private var renamingID:      String?
    /// Excel-style column filter: one active column + text (Size accepts
    /// `>10MB`/`<500KB`, dates accept `2026-09` or full `2026-09-22`).
    @State private var filterColumn:    FilterColumn = .name
    @State private var filterText:      String = ""
    /// Column filter bar is opt-in (Display menu / ⌥⌘F) — a second search
    /// field right under the real one read as clutter. It stays while a
    /// filter is active, so a filtered list never hides why.
    @AppStorage("ffShowColumnFilter") private var showColumnFilter = false
    /// Callbacks for the native table, kept in one box per list.
    @State private var nativeActions = NativeFileTableActions()

    var body: some View {
        // Drops anywhere in the list land in the current folder; folder rows
        // are wrapped with FolderDropRow below for precise targets.
        DropCatcher(destination: currentPath,
                    folderName: currentPath.lastPathComponent,
                    fileOps: fileOps,
                    onReload: onReload) {
            listBody
        }
    }

    @ViewBuilder
    private var listBody: some View {
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
                    onCreateFile: {
                        NotificationCenter.default.post(name: .createNewFile, object: nil)
                    }
                )
            }
        } else if groupBy != .none || showsFlatList {
            GroupedListView(
                files:            files,
                selectedIDs:      $selectedIDs,
                pendingRenameURL: $pendingRenameURL,
                currentPath:      currentPath,
                groupBy:          groupBy,
                onNavigate:       onNavigate,
                onBrowseInto:     onBrowseInto,
                onReload:         onReload,
                fileOps:          fileOps,
                favorites:        favorites,
                onBatchRename:    onBatchRename,
                filesIdentity:    filesIdentity,
                onSendToDiscord:  onSendToDiscord,
                sortAscending:    sortAscending,
                isSearching:      isSearching || showsFlatList,
                sizingActive:     sizingActive
            )
            // Roditelj (ContentView) se evaluira na svaki klik i svaki put
            // pravi nove closure-e, pa bi SwiftUI bez ovoga uvijek smatrao da
            // se lista promijenila i ponovo prošao kroz SVE redove foldera.
            .equatable()
        } else {
            tableView
                .onChange(of: pendingRenameURL) { _, url in
                    // Clear first: a target that no longer exists (deleted
                    // mid-flight) must not linger and fire later if the same
                    // path reappears.
                    pendingRenameURL = nil
                    guard let url, let item = files.first(where: { $0.url == url }) else { return }
                    startRename(item: item)
                }
        }
    }

    // MARK: - Table (non-grouped)

    /// Column order: Name | Kind | Date Modified | Date Created | Size (right).
    /// Sorting is the native header click (arrow indicator); filtering is the
    /// slim bar above the table, Excel-style per-column.
    private var tableView: some View {
        // Jedan prolaz filtera po renderu: `visibleFiles` se prije računao
        // dvaput (provjera praznog + Table), a sad iz istog rezultata dolazi
        // i brojač pogodaka u traci.
        let visible = visibleFiles
        return VStack(spacing: 0) {
            if showColumnFilter || filterActive {
                filterBar(matchCount: visible.count)
                Divider()
            }
            if visible.isEmpty && filterActive {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No matches for this filter")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Clear filter") { filterText = "" }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tableContent(visible)
            }
        }
    }

    private var filterActive: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Filter traka iznad tabele. Polje je prije bilo golo — bez ivice, na
    /// `.bar` pozadini se nije vidjelo gdje se klika — i nije govorilo koliko
    /// je redova ostalo. Sada ima isti jezik kao polje pretrage: ivica koja
    /// posvijetli kad je filter aktivan, dugme za brisanje, Esc, i bedž
    /// „n of m".
    private func filterBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $filterColumn) {
                ForEach(FilterColumn.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 108)
            .help("Which column the filter applies to")

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(filterActive ? Color.accentColor : Color.secondary)
                TextField(filterColumn.placeholder, text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onExitCommand { filterText = "" }
                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: FFTheme.controlShape)
            .overlay(
                FFTheme.controlShape.strokeBorder(
                    filterActive ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.22),
                    lineWidth: 1)
            )
            .frame(maxWidth: 460)

            if filterActive {
                Text("\(matchCount) of \(files.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .ffBadge()
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var visibleFiles: [FileItem] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return files }
        return files.filter { filterColumn.matches($0, query: q) }
    }

    /// Native NSTableView (NativeFileTable.swift): a SwiftUI `Table` rebuilt
    /// every row on each folder switch — 250–350 ms per Downloads/Desktop/
    /// Documents hop. Same columns, sorting, selection, rename, menu and drag.
    private func tableContent(_ rows: [FileItem]) -> some View {
        let actions = nativeActions
        actions.onSort = { field, ascending in
            if field != sortField { sortField = field }
            if ascending != sortAscending { sortAscending = ascending }
        }
        actions.onOpen = { item in onNavigate(item) }
        actions.onReturn = { item in
            guard renamingID == nil else { return }
            startRename(item: item)
        }
        actions.onRenameEnd = { item, name in
            renamingID = nil
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name != item.name else { return }
            fileOps.rename(item.url, to: name, reload: onReload)
        }
        actions.onQuickLook = { ids in quickLook(ids: ids) }
        actions.menu = { ids in AnyView(contextMenu(for: ids)) }
        actions.driveKind = { item in driveIndex.kind(for: item) }
        actions.fileOps = fileOps
        actions.onReload = onReload
        actions.currentPath = currentPath

        var style = Hasher()
        style.combine(sizingActive)
        style.combine(fileOps.isCut)
        style.combine(fileOps.cutURLSet.count)
        style.combine(driveIndex.version)
        style.combine(workspaces.version)
        style.combine(git.version)
        return NativeFileTable(
            rows: rows,
            selectedIDs: $selectedIDs,
            sortField: sortField,
            sortAscending: sortAscending,
            styleToken: style.finalize(),
            sizingActive: sizingActive,
            cutPaths: fileOps.isCut ? fileOps.cutURLSet : [],
            renamingID: renamingID,
            actions: actions
        )
        .onChange(of: files) { _, newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
    }

    // MARK: - Inline rename helpers

    func startRename(item: FileItem) {
        renamingID = item.id
    }

    // MARK: - Full macOS context menu (ujedinjen: Copy do Unzip + programi)

    @ViewBuilder
    func contextMenu(for ids: Set<String>) -> some View {
        let sel = files.filter { ids.contains($0.id) }
        FileContextMenuContent(
            targets: sel,
            currentPath: currentPath,
            fileOps: fileOps,
            favorites: favorites,
            onNavigate: onNavigate,
            onBrowseInto: onBrowseInto,
            onRename: { pendingRenameURL = $0.url },
            onBatchRename: onBatchRename,
            onSendToDiscord: onSendToDiscord,
            onReload: onReload
        )
    }

    // MARK: - Helpers

    private func quickLook(ids: Set<String>) {
        let urls = files.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(urls)
    }

    private func showGetInfo(for items: [FileItem]) {
        showGetInfoInFinder(items.map(\.url))
    }
}

// MARK: - Date-grouped list view

struct GroupedListView: View {
    let files:       [FileItem]
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    let currentPath: URL
    let groupBy:     GroupBy
    let onNavigate:  (FileItem) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService
    /// Google Drive bedževi: indeks se puni po folderu u pozadini pa lista
    /// mora da ga posmatra da bi se bedževi pojavili kad podaci stignu.
    @ObservedObject var driveIndex = GoogleDriveBadgeIndex.shared
    /// Workspace bedževi (§13): ista pretplata — verzija se spušta redovima
    /// kao `workspaceVersion` (kao driveVersion) da `.equatable()` redovi
    /// preslikaju kad task/review/expiry/share stigne.
    @ObservedObject var workspaces = WorkspaceStore.shared
    var onBatchRename: (([FileItem]) -> Void)? = nil
    /// O(1) listing identitet — grupe se keširaju po njemu, selekcija ne
    /// re-bucketuje folder.
    var filesIdentity: UInt = 0
    var onSendToDiscord: (([FileItem]) -> Void)? = nil
    var sortAscending: Bool = true
    var isSearching: Bool = false
    /// While a folder-size run is in flight, unsized folders render "…"
    /// instead of "—" (Table cells via ListView, subtitles here).
    var sizingActive: Bool = false

    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    @FocusState private var renameActive: Bool
    /// Sidro Shift-raspona i dedupe dvoklika žive u referenci, ne u `@State`:
    /// upis u `@State` na svaki klik pregradi redove cijelog foldera.
    @State private var interaction = RowInteractionState()
    /// Akcije reda u referenci — vidi `RowActions`.
    @State private var actions = RowActions()
    /// Šta se povlači kad drag krene — drži se u klasi (stabilna referenca)
    /// umjesto da svaki red čuva `files` + `selectedIDs`. Vidi RowDragContext.
    @State private var dragContext = RowDragContext()
    /// Deterministički marker da je selekcija došla od korisničkog klika
    /// (red je već vidljiv → ne skroluj). Postavlja se SAMO kad se selekcija
    /// stvarno menja, onChange ga potroši — bez vremenskog prozora pa
    /// programski select (paste/new) nikad nije potisnut.
    @State private var userInitiatedSelection = false
    /// Excel filter — isti jezik kao Table (kolona + tekst). Ranije je filter
    /// postojao samo u Table modu pa je grupisana lista delovala kao drugi app.
    @State private var filterColumn: FilterColumn = .name
    @State private var filterText: String = ""
    @AppStorage("ffShowColumnFilter") private var showColumnFilter = false

    private var filterActive: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Listing nakon filtera — grupe se grade iz ovoga, pa filter važi i uz
    /// Group By i uz search/tag rezultate.
    private var filteredFiles: [FileItem] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return files }
        return files.filter { filterColumn.matches($0, query: q) }
    }

    private var groups: [FileGroup] {
        let src = filteredFiles
        // Search/tag rezultati dele filesIdentity sa folderom dok se ne bumpuje —
        // tada O(1) kljuc vraca stale grupe. Za pretragu zaobidji memo (tacan
        // contentSignature put, rezultati su ograniceni pa je O(n) prihvatljiv).
        if isSearching {
            return groupedItems(src, by: groupBy, ascending: sortAscending)
        }
        return groupedItems(src, by: groupBy, identity: filesIdentity, ascending: sortAscending)
    }

    /// Ista filter traka kao iznad Table-a (ivica, Esc, bedž n of m) — jedno
    /// mesto učenja, dva prikaza.
    private func groupedFilterBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $filterColumn) {
                ForEach(FilterColumn.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 108)
            .help("Which column the filter applies to")

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(filterActive ? Color.accentColor : Color.secondary)
                TextField(filterColumn.placeholder, text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onExitCommand { filterText = "" }
                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: FFTheme.controlShape)
            .overlay(
                FFTheme.controlShape.strokeBorder(
                    filterActive ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.22),
                    lineWidth: 1)
            )
            .frame(maxWidth: 460)

            if filterActive {
                Text("\(matchCount) of \(files.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .ffBadge()
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    var body: some View {
        // Tijelo liste NE čita selekciju: svako čitanje bi ga vezalo za nju, pa
        // bi svaki klik ponovo gradio ForEach za cijeli folder (izmjereno:
        // 8.043 poziva `row(for:)` + diff svih redova po kliku, ~150–300 ms na
        // 8k fajlova). Označavanje reda radi sam List preko `selection`
        // bindinga, a scroll na programsku selekciju prati `SelectionFollower`.
        // Drag čita selekciju tek kad krene.
        dragContext.update(files: files, selection: $selectedIDs)
        // Akcije se osvježavaju u referenci (ista adresa kroz cio život liste),
        // pa ulazi redova ostaju nepromijenjeni i kad se ovo tijelo evaluira.
        actions.update(onReload: onReload, onNavigate: onNavigate,
                       onTap: handleRowTap, onOpen: navigateOnce,
                       onRenameSubmit: commitGroupedRename(for:),
                       onRenameCancel: cancelGroupedRename)
        let visibleCount = filteredFiles.count
        return VStack(spacing: 0) {
            if showColumnFilter || filterActive {
                groupedFilterBar(matchCount: visibleCount)
                Divider()
            }
            if visibleCount == 0 && filterActive {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No matches for this filter")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Clear filter") { filterText = "" }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                groupedListReader
            }
        }
    }

    /// Izvučen reader da `body` ostane u type-checker budžetu (VStack wrapper
    /// iznad je dodao jedan nivo izraza).
    private var groupedListReader: some View {
        ScrollViewReader { proxy in
        List(selection: $selectedIDs) {
            // Redovi su zasebna vrijednost: ovo tijelo se evaluira na svaki
            // klik (List mora držati binding na selekciju da bi označavao red),
            // ali su ulazi ispod nepromijenjeni pa ih SwiftUI preskače.
            // NE umotavati u `.equatable()` — EquatableView unutar `List`
            // spljošti cijeli sadržaj u JEDAN red (provjereno).
            GroupedRowsContent(
                groups:        groups,
                filesIdentity: filesIdentity,
                groupBy:       groupBy,
                sizingActive:  sizingActive,
                renamingID:    renamingID,
                driveVersion:  driveIndex.version,
                workspaceVersion: workspaces.version,
                // U pretrazi redovi pokazuju i gdje pogodak živi; van pretrage
                // nema korijena pa ni lokacije (nema troška po redu).
                locationRoot:  isSearching ? currentPath.standardizedFileURL : nil,
                cutPaths:      fileOps.isCut ? fileOps.cutURLSet : [],
                dragContext:   dragContext,
                actions:       actions,
                fileOps:       fileOps,
                renameText:    $renameText,
                renameActive:  $renameActive
            )
        }
        .listStyle(.inset)
        // Promjena grupisanja mijenja i broj sekcija (Date Modified ima 6,
        // Kind u ~/Downloads 252). Bez novog identiteta SwiftUI pokušava da
        // postojeće redove PREMJESTI među sekcijama — izmjereno 7 s zamrznute
        // glavne niti na prelazu u Kind, naspram ~0,7 s kad listu izgradi
        // ispočetka. Identitet po načinu grupisanja bira jeftiniji put.
        .id(groupBy)
        .contextMenu(forSelectionType: String.self) { ids in contextMenu(for: ids) }
        primaryAction: { ids in
            guard renamingID == nil, let id = ids.first,
                  let item = files.first(where: { $0.id == id }) else { return }
            // Finder: Return renames, double-click opens (see ListView.table).
            if (NSApp.currentEvent?.clickCount ?? 0) >= 2 {
                navigateOnce(item)
            } else {
                startGroupedRename(item: item)
            }
        }
        .background(SelectionFollower(selectedIDs: $selectedIDs,
                                      userInitiated: $userInitiatedSelection,
                                      proxy: proxy))
        .onChange(of: files) { _, newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive) { _, active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitGroupedRename(for: item)
        }
        .onChange(of: pendingRenameURL) { _, url in
            pendingRenameURL = nil
            guard let url, let item = files.first(where: { $0.url == url }) else { return }
            startGroupedRename(item: item)
        }
        .background(
            Button("") {
                guard renamingID == nil, !isEditingText() else { return }
                let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
                if !urls.isEmpty { QuickLookController.shared.show(urls) }
            }
            .keyboardShortcut(.space, modifiers: []).hidden()
        )
        } // ScrollViewReader
    }

    // MARK: - Finder-style multi-select (Cmd-toggle, Shift-range, plain single)

    private func handleRowTap(_ item: FileItem) {
        // Markiraj korisnički klik SAMO ako se selekcija stvarno menja —
        // inače bi zastavica ostala visiti i potisnula sledeći programski
        // scroll (klik na već selektovani red ne pali onChange).
        let flags = NSEvent.modifierFlags.intersection([.command, .shift])
        if flags.contains(.command) {
            userInitiatedSelection = true
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
            interaction.anchorID = item.id
        } else if flags.contains(.shift) {
            // Range across the flat row order (groups concatenated as shown),
            // anchored on the last clicked row (Finder behaviour).
            let flat = groups.flatMap(\.items)
            guard let tappedIndex = flat.firstIndex(where: { $0.id == item.id }) else {
                if selectedIDs != [item.id] { userInitiatedSelection = true }
                selectedIDs = [item.id]; interaction.anchorID = item.id; return
            }
            if let anchor = interaction.anchorID,
               let anchorIndex = flat.firstIndex(where: { $0.id == anchor }) {
                let lo = min(anchorIndex, tappedIndex)
                let hi = max(anchorIndex, tappedIndex)
                let next = Set(flat[lo...hi].map(\.id))
                if next != selectedIDs { userInitiatedSelection = true }
                selectedIDs = next
            } else {
                if selectedIDs != [item.id] { userInitiatedSelection = true }
                selectedIDs = [item.id]
                interaction.anchorID = item.id
            }
        } else {
            if selectedIDs != [item.id] { userInitiatedSelection = true }
            selectedIDs = [item.id]
            interaction.anchorID = item.id
        }
    }

    /// Jedan open po dvokliku: tap handler i primaryAction mogu oba da opale.
    private func navigateOnce(_ item: FileItem) {
        guard renamingID == nil else { return }
        let now = Date()
        if interaction.lastNavID == item.id && now.timeIntervalSince(interaction.lastNavAt) < 0.5 { return }
        interaction.lastNavID = item.id
        interaction.lastNavAt = now
        onNavigate(item)
    }

    // MARK: - Grouped inline rename helpers

    func startGroupedRename(item: FileItem) {
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
    }

    private func commitGroupedRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelGroupedRename() {
        renameCancelled = true
        renamingID      = nil
    }

    /// Built only when the menu opens. `ids` is the clicked row, or the selection
    /// when the click lands on it; empty for the background menu.
    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        FileContextMenuContent(
            targets: files.filter { ids.contains($0.id) },
            currentPath: currentPath,
            fileOps: fileOps,
            favorites: favorites,
            onNavigate: onNavigate,
            onBrowseInto: onBrowseInto,
            onRename: { pendingRenameURL = $0.url },
            onBatchRename: onBatchRename,
            onSendToDiscord: onSendToDiscord,
            onReload: onReload
        )
    }
}

extension GroupedListView: Equatable {
    /// Samo ulazi koji mijenjaju prikaz. Closure-i i bindinzi se namjerno ne
    /// porede: pišu samo u @State roditelja, pa stara kopija radi isto.
    /// `files ==` je O(1) dok roditelj prosljeđuje isti niz (isti bafer).
    static func == (lhs: GroupedListView, rhs: GroupedListView) -> Bool {
        lhs.filesIdentity == rhs.filesIdentity
            && lhs.files == rhs.files
            && lhs.currentPath == rhs.currentPath
            && lhs.groupBy == rhs.groupBy
            && lhs.sortAscending == rhs.sortAscending
            && lhs.isSearching == rhs.isSearching
            && lhs.sizingActive == rhs.sizingActive
            && lhs.fileOps === rhs.fileOps
            && lhs.favorites === rhs.favorites
    }
}

/// Prati selekciju umjesto liste: samo ovaj mali view se ponovo evaluira na
/// svaki klik. Skroluje SAMO na programsku selekciju (paste, new folder,
/// reveal) — nikad na korisnički klik.
private struct SelectionFollower: View {
    @Binding var selectedIDs: Set<String>
    @Binding var userInitiated: Bool
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: selectedIDs) { _, ids in
                // Kliknuti red je po definiciji već vidljiv; scrollTo bi ga
                // re-centrirao i korisnik "odleće" sa dela koji gleda.
                // pressedMouseButtons sam ne razlikuje klik od koda (tap puca na
                // mouse-up kad je dugme već 0) pa se klik eksplicitno markira
                // zastavicom u handleRowTap; ovdje se potroši. Bez timestamp
                // prozora: brzi paste posle klika i dalje skroluje ispravno,
                // a multi-select (count != 1) nikad ne skroluje.
                if userInitiated {
                    userInitiated = false
                    return
                }
                guard ids.count == 1, let id = ids.first else { return }
                if NSEvent.pressedMouseButtons != 0 { return }
                proxy.scrollTo(id)
            }
    }
}

/// Redovi liste kao zasebna vrijednost.
///
/// Zašto: `List` mora da drži binding na selekciju da bi označavao red, a
/// SwiftUI invalidira SVAKI view koji drži binding čim se vrijednost promijeni
/// — i kad ga tijelo ne čita. Dok su redovi bili u tijelu liste, svaki klik je
/// značio ForEach preko cijelog foldera (izmjereno: 8.043 poziva `row(for:)`
/// i 115–330 ms zaključane glavne niti na folderu od 8k fajlova).
///
/// Ovdje nema nijednog closure-a koji hvata roditelja: takav closure je nova
/// heap adresa na svaku evaluaciju, pa bi SwiftUI vidio „promijenjeno" i opet
/// gradio sve redove. Sve što se mijenja po kliku putuje kroz reference
/// (`actions`, `dragContext`), a ostalo su vrijednosti koje SwiftUI poredi.
private struct GroupedRowsContent: View {
    let groups:        [FileGroup]
    let filesIdentity: UInt
    let groupBy:       GroupBy
    let sizingActive:  Bool
    let renamingID:    String?
    let driveVersion:  Int
    /// Workspace bedževi (§13) — verzija store-a; red se preslika kad se
    /// task/review/expiry/share promijeni (isto kao driveVersion).
    let workspaceVersion: UInt
    /// Korijen pretrage: kad nije nil, redovi ispisuju lokaciju pogotka.
    let locationRoot:  URL?
    /// Putanje isječenih fajlova (⌘X) — ti redovi se blijede.
    let cutPaths:      Set<String>
    let dragContext:   RowDragContext
    let actions:       RowActions
    let fileOps:       FileOperationsService
    @Binding var renameText: String
    @FocusState.Binding var renameActive: Bool

    var body: some View {
        ForEach(groups) { group in
            if group.title.isEmpty {
                // Ungrouped (search results): plain rows without a header row.
                ForEach(group.items) { item in row(for: item, groupID: group.id) }
            } else {
                Section {
                    ForEach(group.items) { item in row(for: item, groupID: group.id) }
                } header: {
                    DateSectionHeader(title: group.title, count: group.items.count)
                }
            }
        }
    }

    private func row(for item: FileItem, groupID: String) -> some View {
        // Samo polja — bez modifikatora, bez traženja Drive bedža, bez
        // interpolacije stringova. Vidi komentar iznad GroupedRowContainer.
        GroupedRowContainer(
            item:          item,
            groupID:       groupID,
            // `item.id` JE putanja fajla (FileItem.load: id = url.path), pa
            // ovdje nema `url.path` konverzije po redu.
            dimmed:        cutPaths.contains(item.id),
            sizingActive:  sizingActive,
            isRenaming:    renamingID == item.id,
            driveVersion:  driveVersion,
            workspaceVersion: workspaceVersion,
            locationRoot:  locationRoot,
            dragContext:   dragContext,
            actions:       actions,
            renameText:    $renameText,
            renameActive:  $renameActive,
            fileOps:       fileOps
        )
        // Bez ovoga SwiftUI smatra da se red promijenio kad god se lista
        // pregradi; `==` ispod gleda samo ono što se stvarno vidi.
        .equatable()
        .tag(item.id)
        .id(item.id)
    }
}

/// Akcije reda u referenci: closure koji hvata roditelja je nova heap adresa
/// na svaku evaluaciju, pa bi redovi izgledali „promijenjeno" na svaki klik.
final class RowActions {
    private(set) var onReload: () -> Void = {}
    private(set) var onNavigate: (FileItem) -> Void = { _ in }
    private(set) var onTap: (FileItem) -> Void = { _ in }
    private(set) var onOpen: (FileItem) -> Void = { _ in }
    private(set) var onRenameSubmit: (FileItem) -> Void = { _ in }
    private(set) var onRenameCancel: () -> Void = {}

    func update(onReload: @escaping () -> Void,
                onNavigate: @escaping (FileItem) -> Void,
                onTap: @escaping (FileItem) -> Void,
                onOpen: @escaping (FileItem) -> Void,
                onRenameSubmit: @escaping (FileItem) -> Void,
                onRenameCancel: @escaping () -> Void) {
        self.onReload = onReload
        self.onNavigate = onNavigate
        self.onTap = onTap
        self.onOpen = onOpen
        self.onRenameSubmit = onRenameSubmit
        self.onRenameCancel = onRenameCancel
    }
}

/// Stanje interakcije s redovima koje se mijenja na svaki klik — u referenci,
/// jer bi `@State` na svaku promjenu pregradio redove cijelog foldera.
final class RowInteractionState {
    /// Sidro za Shift-raspon: zadnji obični/Cmd klik.
    var anchorID: String?
    /// Dedupe dvostrukog open-a: dvoklik može da opali i row tap (clickCount>=2)
    /// i List primaryAction — isti item u <0.5s se ignoriše drugi put.
    var lastNavID: String?
    var lastNavAt: Date = .distantPast
}

/// Kontekst za drag-out: `files` + `selectedIDs` žive ovdje, a ne u svakom redu.
///
/// Zašto: dok je red čuvao selekciju kao svoje polje, svaka promjena selekcije
/// je mijenjala ulaze SVIH redova, pa je SwiftUI zvao `body` za svih 7.839
/// redova po kliku (izmjereno). Referenca je ista kroz cio život liste, pa red
/// ostaje „nepromijenjen", a drag i dalje nosi tačnu, trenutnu selekciju.
final class RowDragContext {
    private(set) var files: [FileItem] = []
    /// Binding, ne kopija: lista se više ne evaluira na promjenu selekcije,
    /// pa se tekuća selekcija čita tek kad drag krene.
    private var selection: Binding<Set<String>>?

    func update(files: [FileItem], selection: Binding<Set<String>>) {
        self.files = files
        self.selection = selection
    }

    func urls(for item: FileItem) -> [URL] {
        FileDragSupport.urlsForDrag(item: item, files: files,
                                    selectedIDs: selection?.wrappedValue ?? [])
    }
}

// MARK: - Red grupisane liste (jedan čvor u listi, stack tek pri crtanju)
//
// Zašto postoji: SwiftUI pregradi cijelu listu na svaku promjenu selekcije —
// izmjereno 7.839 poziva `row(for:)` po jednom kliku u ~/Downloads. Dok je
// svaki red nosio svoj stack modifikatora (drop meta, drag, tap, accessibility,
// rename overlay), taj obilazak je blokirao glavnu nit ~300 ms po kliku; profil
// (-O build) pokazuje ModifiedViewList.applyNodes i instanciranje generičkih
// metapodataka, dakle trošak same strukture, ne našeg koda u njoj.
//
// Ovako roditeljska lista ima jedan čvor po redu (+ tag/id), a cio stack
// nastaje u `body` — koji SwiftUI zove samo za redove koji se stvarno crtaju
// (mjereno: 1–2 po kliku umjesto 7.839).
struct GroupedRowContainer: View {
    let item:          FileItem
    /// Id grupe u kojoj red trenutno stoji. Ulazi u `==` da promjena
    /// grupisanja natjera SwiftUI da redove izgradi ispočetka umjesto da ih
    /// premješta između sekcija — mjereno je da je premještanje 10× skuplje.
    let groupID:       String
    let dimmed:        Bool
    let sizingActive:  Bool
    let isRenaming:    Bool
    /// Verzija Drive indeksa: bedž se čita u `body` (samo za nacrtane redove),
    /// a ovo polje je tu da se red preslika kad indeks stigne iz pozadine.
    let driveVersion:  Int
    /// Verzija Workspace store-a: bedž (§13) se čita u `body`, a ovo polje
    /// tjera preslikavanje kad task/review/expiry/share stigne.
    let workspaceVersion: UInt
    /// Korijen pretrage (nil van pretrage) — red iz njega računa lokaciju.
    let locationRoot:  URL?
    /// Stabilna referenca — šta drag nosi rješava se u trenutku drag-a.
    let dragContext:   RowDragContext
    /// Akcije u referenci (vidi `RowActions`): šest closure-a po redu je
    /// značilo i šest novih heap konteksta po redu na svaku pregradnju liste.
    let actions:       RowActions
    @Binding var renameText: String
    @FocusState.Binding var renameActive: Bool
    let fileOps:        FileOperationsService

    var body: some View {
        FolderDropRow(item: item, fileOps: fileOps, onReload: actions.onReload,
                      onSpringOpen: actions.onNavigate) {
            ZStack(alignment: .leading) {
                // .equatable(): GroupedRow ignoriše selekciju u svom telu pa
                // SwiftUI preskače nepromenjene redove — na klik se re-renderuju
                // samo stari + novi selektovani red, ne ceo folder.
                GroupedRow(item: item,
                           locationRoot: locationRoot,
                           sizingActive: sizingActive,
                           dimmed: dimmed,
                            driveBadge: GoogleDriveBadgeIndex.shared.kind(for: item),
                            workspaceVersion: workspaceVersion)
                    .equatable()
                    .opacity(isRenaming ? 0 : 1)
                if isRenaming { renameField }
            }
        }
        .onDrag { FileDragSupport.provider(for: dragContext.urls(for: item)) }
        // Explicit single-click selection: `onDrag` above swallows the click
        // that drives native List selection, so without this tap handler rows
        // never highlight. One tap handler only (no count:2 rival) so clicks
        // select instantly; double-click navigates via clickCount check
        // (Finder: each click selects first, second click opens).
        // A separate .onTapGesture(count: 2) would delay every single click
        // by the double-click interval — hence the NSApp.clickCount check.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                actions.onTap(item)
                actions.onOpen(item)
            } else {
                actions.onTap(item)
            }
        }
        // No per-row context menu: the right-click menu comes from
        // `contextMenu(forSelectionType:)` on the List — a menu built per row
        // filtered the whole folder once per row on every render.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.kind), \(GitService.shared.status(for: item.url)?.state.label ?? "clean")")
    }

    private var renameField: some View {
        HStack(spacing: 8) {
            FileIconView(item: item, size: 16)
                .frame(width: 24, height: 24)
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: FFTheme.controlShape
                )
                .overlay(
                    FFTheme.controlShape
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                )
                .resetsCursorOnExit()
                .focused($renameActive)
                .onSubmit { actions.onRenameSubmit(item) }
                .onExitCommand { actions.onRenameCancel() }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }
}

extension GroupedRowContainer: Equatable {
    /// Namjerno poredi samo ono što se vidi: closure-i (onTap, onOpen…) i
    /// binding-zi se mijenjaju na svaku evaluaciju roditelja i bez ovoga bi
    /// svaki red bio „promijenjen".
    static func == (lhs: GroupedRowContainer, rhs: GroupedRowContainer) -> Bool {
        lhs.item == rhs.item && lhs.item.folderSize == rhs.item.folderSize
            && lhs.groupID      == rhs.groupID
            && lhs.dimmed       == rhs.dimmed
            && lhs.sizingActive == rhs.sizingActive
            && lhs.isRenaming   == rhs.isRenaming
            && lhs.driveVersion == rhs.driveVersion
            && lhs.locationRoot == rhs.locationRoot
            && lhs.workspaceVersion == rhs.workspaceVersion
    }
}

struct GroupedRow: View {
    let item:       FileItem
    /// Korijen pretrage: kad nije nil, drugi red pokazuje i lokaciju pogotka.
    var locationRoot: URL? = nil
    /// While a folder-size run is in flight, unsized folders append "…" to
    /// the subtitle (they never show a Size column here).
    var sizingActive: Bool = false
    /// Finder-style cut feedback: the whole row fades while cut.
    var dimmed: Bool = false
    /// Google Drive status (nil van mirrora) — računa ga roditelj iz indeksa.
    var driveBadge: GoogleDriveBadgeKind? = nil
    /// Verzija Workspace store-a: bedž (§13) se računa u `body` (samo za
    /// nacrtane redove), a ovo polje je tu da se red preslika kad podaci
    /// stignu — roditelj nikad ne zove badge(for:) za svih N.
    var workspaceVersion: UInt = 0
    /// Git status bedž (M/A/D/?/!): red posmatra GitService direktno —
    /// `.equatable()` gasi samo parent-driven update-e, interna pretplata
    /// i dalje preslikava vidljive redove (isto kao @State hovering).
    @ObservedObject var git = GitService.shared
    @State private var hovering = false
    /// `.increased` dok je red selektovan — List ga postavlja sam, pa red ne
    /// mora znati selekciju (i lista se ne gradi ponovo na svaki klik).
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.ffCompactRows) private var compact
    var body: some View {
        // Workspace bedž (§13) se računa ovde, ne u roditelju: roditelj
        // instancira svih N redova po kliku, a body se izvršava samo za
        // vidljive/preslikane (isto kao driveBadge iznad).
        let wsBadge = WorkspaceStore.shared.badge(for: item.url)
        let gitStatus = git.status(for: item.url)
        return HStack(spacing: 8) {
            FileIconView(item: item, size: compact ? 14 : 16)
                .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let driveBadge {
                        GoogleDriveBadgeView(kind: driveBadge, size: 11)
                    }
                    if let wsBadge {
                        WorkspaceBadgeView(badge: wsBadge)
                    }
                    GitBadgeView(status: gitStatus, size: 10)
                    TagDotsView(colors: item.tagColors, size: 9)
                }
                if subtitle != nil || locationText != nil {
                    HStack(spacing: 6) {
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        if let locationText {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(locationText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                }
            }
            Spacer()
            Text(item.formattedDateModified)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, compact ? 1 : 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            FFTheme.controlShape
                .fill(prominence != .increased && hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { hovering = $0 }
        .opacity(dimmed ? 0.5 : 1)
    }

    /// Gdje pogodak živi — samo dok traje pretraga. Bez toga su rezultati iz
    /// podfoldera izgledali kao da su svi u tekućem folderu.
    private var locationText: String? {
        guard let locationRoot else { return nil }
        return ffSearchLocation(of: item.url, relativeTo: locationRoot)
    }

    /// Second line only when it says something new: files show
    /// "Kind • size", sized folders show just the size, plain folders show
    /// nothing (the icon already says "folder" — the old bare kind word was
    /// pure noise). Nil collapses the line, so folder rows go single-line.
    private var subtitle: String? {
        if item.isDirectory {
            if item.isBrowsableFolder, item.folderSize == nil, sizingActive {
                return item.kind + " • …"
            }
            if let fs = item.folderSize, fs > 0 {
                return ByteCountFormatter.string(fromByteCount: fs, countStyle: .file)
            }
            return nil
        }
        return item.kind + " • \(item.formattedSize)"
    }
}

extension GroupedRow: Equatable {
    // Rows re-render on every selection change (the parent List rebuilds);
    // skip rows whose content + selection state didn't change. FileItem is a
    // value type with content equality, so this is a cheap comparison.
    // NOTE: FileItem.== deliberately ignores folderSize (listing stability),
    // so the size channel is compared explicitly — otherwise a freshly
    // computed size (or a pending "…") would never repaint this row.
    static func == (lhs: GroupedRow, rhs: GroupedRow) -> Bool {
        lhs.item == rhs.item && lhs.item.folderSize == rhs.item.folderSize
            && lhs.sizingActive == rhs.sizingActive
            && lhs.dimmed == rhs.dimmed
            && lhs.driveBadge == rhs.driveBadge
            && lhs.locationRoot == rhs.locationRoot
            && lhs.workspaceVersion == rhs.workspaceVersion
    }
}

// MARK: - Date section header (Finder-style)

struct DateSectionHeader: View {
    let title: String
    let count: Int
    @Environment(\.ffCompactRows) private var compact

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
                .lineLimit(1)
            Spacer()
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}
