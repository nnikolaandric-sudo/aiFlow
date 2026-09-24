import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Native flat file list (NSTableView)
//
// The ungrouped list used to be a SwiftUI `Table`. Every folder switch made it
// diff the old and new rows, visit ALL rows, and measure automatic row heights
// through one NSHostingView per cell — 250–350 ms of blocked main thread per
// switch between Downloads (8k) / Desktop / Documents, even when the new folder
// had 78 files (tearing down the old 8k rows was the cost). A plain
// view-based NSTableView only builds the rows on screen, reuses plain AppKit
// cells and has fixed row heights, so a switch is a `reloadData()`.
//
// Behaviour kept from the Table: sortable column headers (drive
// sortField/sortAscending — ContentView sorts), multi-selection bound to
// `selectedIDs`, double-click opens, Return renames inline, Space = Quick Look,
// the full SwiftUI context menu (via NSHostingMenu), Finder-style drag-out,
// drops onto folder rows (spring-open after 0.8 s) or onto the list (current
// folder), cut rows faded, tag dots and Drive badges.

/// Callbacks + context for the table. A reference box so a new closure per
/// ContentView render never counts as a change (see ListView/RowActions).
final class NativeFileTableActions {
    var onSort: (SortField, Bool) -> Void = { _, _ in }
    var onOpen: (FileItem) -> Void = { _ in }
    var onReturn: (FileItem) -> Void = { _ in }
    /// nil name = rename cancelled.
    var onRenameEnd: (FileItem, String?) -> Void = { _, _ in }
    var onQuickLook: (Set<String>) -> Void = { _ in }
    var menu: (Set<String>) -> AnyView = { _ in AnyView(EmptyView()) }
    var driveKind: (FileItem) -> GoogleDriveBadgeKind? = { _ in nil }
    var fileOps: FileOperationsService?
    var onReload: () -> Void = {}
    var currentPath: URL = FileManager.default.homeDirectoryForCurrentUser
}

struct NativeFileTable: NSViewRepresentable {
    let rows: [FileItem]
    @Binding var selectedIDs: Set<String>
    let sortField: SortField
    let sortAscending: Bool
    /// Anything that restyles cells without changing the rows (size column
    /// "…", cut fade, Drive badges).
    let styleToken: Int
    let sizingActive: Bool
    let cutPaths: Set<String>
    let renamingID: String?
    let actions: NativeFileTableActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FFFileTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        // Name flexuje, ostale kolone drže širinu: na uskom prozoru
        // horizontalni scroll guta desne (manje bitne) kolone, a Name
        // ostaje vidljiv levo — kao Finder.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.usesAutomaticRowHeights = false
        table.allowsTypeSelect = true
        table.focusRingType = .none

        for spec in Coordinator.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.field.rawValue))
            col.title = spec.field.rawValue
            col.minWidth = spec.min
            col.width = spec.ideal
            col.maxWidth = spec.max
            col.sortDescriptorPrototype = NSSortDescriptor(key: spec.field.rawValue, ascending: true)
            if spec.field == .size { col.headerCell.alignment = .right }
            col.isHidden = spec.hiddenByDefault
            table.addTableColumn(col)
        }
        // v2: new defaults (Extension hidden, Name fills) apply once even
        // where v1 widths were saved.
        table.autosaveName = "FFFlatListColumns2"
        table.autosaveTableColumns = true

        let c = context.coordinator
        // Right-click the header: show/hide columns, like Finder.
        let headerMenu = NSMenu()
        headerMenu.delegate = c
        table.headerView?.menu = headerMenu
        c.table = table
        table.coordinator = c
        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Name always takes the width the other columns leave (Finder).
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.clipResized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // SwiftUI can run this from inside a layout pass the table itself
        // started (asking its delegate for a cell); reloading right there is
        // a reentrant NSTableView operation, so finish that pass first.
        if c.inDelegateCall {
            DispatchQueue.main.async { c.apply(self) }
        } else {
            c.apply(self)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        struct ColumnSpec {
            let field: SortField; let min: CGFloat; let ideal: CGFloat; let max: CGFloat
            var hiddenByDefault = false
        }
        static let columns: [ColumnSpec] = [
            // Names stay readable; when the list is narrow the right-hand
            // columns scroll sideways instead (Finder does the same).
            .init(field: .name, min: 200, ideal: 260, max: 4000),
            .init(field: .kind, min: 60, ideal: 100, max: 200),
            .init(field: .dateModified, min: 80, ideal: 128, max: 220),
            .init(field: .dateCreated, min: 80, ideal: 128, max: 220),
            .init(field: .size, min: 50, ideal: 72, max: 140),
            // Kind already says "PDF File" — Extension is opt-in (header menu).
            .init(field: .ext, min: 30, ideal: 50, max: 120, hiddenByDefault: true),
        ]

        var parent: NativeFileTable?
        weak var table: FFFileTableView?
        private(set) var rows: [FileItem] = []
        private var indexByID: [String: Int] = [:]
        var styleToken = 0
        var applyingSort = false
        private var applyingSelection = false
        private var editingID: String?
        private var springWork: DispatchWorkItem?
        private var springRow = -1

        func setRows(_ new: [FileItem]) {
            rows = new
            var map = [String: Int](minimumCapacity: new.count)
            for (i, item) in new.enumerated() { map[item.id] = i }
            indexByID = map
        }

        func item(at row: Int) -> FileItem? { rows.indices.contains(row) ? rows[row] : nil }

        /// True while AppKit is inside one of our delegate/data-source calls.
        private(set) var inDelegateCall = false

        /// Runs a callback that may push state into SwiftUI; SwiftUI can apply
        /// it synchronously, and `apply` must not reload the table mid-callback.
        private func inCallback<T>(_ body: () -> T) -> T {
            let was = inDelegateCall
            inDelegateCall = true
            defer { inDelegateCall = was }
            return body()
        }

        func apply(_ view: NativeFileTable) {
            guard let table else { return }
            parent = view
            // Header arrow follows the current sort.
            if table.sortDescriptors.first?.key != view.sortField.rawValue
                || table.sortDescriptors.first?.ascending != view.sortAscending {
                applyingSort = true
                table.sortDescriptors = [NSSortDescriptor(key: view.sortField.rawValue, ascending: view.sortAscending)]
                applyingSort = false
            }
            // Rows: array == is O(1) when ContentView hands back the same storage.
            if view.rows != rows {
                let oldFolder = rows.first?.url.deletingLastPathComponent()
                setRows(view.rows)
                table.reloadData()
                // New folder: start at the top, like Finder.
                if oldFolder != view.rows.first?.url.deletingLastPathComponent() {
                    table.scroll(.zero)
                }
                styleToken = view.styleToken
            } else if view.styleToken != styleToken {
                styleToken = view.styleToken
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
            syncSelection(from: view.selectedIDs)
            syncRename(view.renamingID)
        }

        // MARK: Selection

        func syncSelection(from ids: Set<String>) {
            guard let table else { return }
            var wanted = IndexSet()
            for id in ids { if let i = indexByID[id] { wanted.insert(i) } }
            guard wanted != table.selectedRowIndexes else { return }
            applyingSelection = true
            table.selectRowIndexes(wanted, byExtendingSelection: false)
            applyingSelection = false
            // Selected from outside (reveal, "go up" to the parent): show it.
            if let first = wanted.first, wanted.count == 1 { table.scrollRowToVisible(first) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table, let parent else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { item(at: $0)?.id })
            if ids != parent.selectedIDs { inCallback { parent.selectedIDs = ids } }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn, let item = item(at: row), let parent else { return nil }
            let was = inDelegateCall
            inDelegateCall = true
            defer { inDelegateCall = was }
            let field = SortField(rawValue: col.identifier.rawValue) ?? .name
            let faded = parent.cutPaths.contains(item.url.path)
            if field == .name {
                let cell = (tableView.makeView(withIdentifier: FFNameCell.reuseID, owner: nil) as? FFNameCell) ?? FFNameCell()
                cell.configure(item: item, drive: parent.actions.driveKind(item))
                cell.alphaValue = faded ? 0.5 : 1
                cell.textField?.delegate = self
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: FFTextCell.reuseID, owner: nil) as? FFTextCell) ?? FFTextCell()
            let text: String
            switch field {
            case .kind:         text = item.kind
            case .dateModified: text = item.formattedDateModified
            case .dateCreated:  text = item.formattedDateCreated
            case .size:         text = item.displaySize(sizingActive: parent.sizingActive)
            case .ext:          text = item.fileExtension.isEmpty ? "—" : item.fileExtension.uppercased()
            case .name:         text = item.name
            }
            cell.configure(text, rightAligned: field == .size)
            cell.alphaValue = faded ? 0.5 : 1
            return cell
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSort, let d = tableView.sortDescriptors.first, let key = d.key,
                  let field = SortField(rawValue: key), let parent else { return }
            // Same column: AppKit already flipped `ascending`; a new column
            // starts ascending — both as the SwiftUI Table did.
            inCallback { parent.actions.onSort(field, d.ascending) }
        }

        // MARK: Column widths + header menu

        @objc func clipResized(_ note: Notification) { fitNameColumn() }

        /// Name = visible width minus every other visible column.
        func fitNameColumn() {
            guard let table, let clip = table.enclosingScrollView?.contentView,
                  let name = table.tableColumns.first(where: { $0.identifier.rawValue == SortField.name.rawValue }) else { return }
            let others = table.tableColumns.filter { !$0.isHidden && $0 !== name }
            let used = others.reduce(0) { $0 + $1.width } + table.intercellSpacing.width * CGFloat(others.count + 1) + 24
            let want = max(name.minWidth, clip.bounds.width - used)
            if abs(name.width - want) > 1 { name.width = want }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            // Another column was dragged wider/narrower: Name gives or takes.
            guard let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  col.identifier.rawValue != SortField.name.rawValue else { return }
            fitNameColumn()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            for col in table.tableColumns where col.identifier.rawValue != SortField.name.rawValue {
                let item = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = col
                item.state = col.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let col = sender.representedObject as? NSTableColumn else { return }
            col.isHidden.toggle()
            fitNameColumn()
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, let item = item(at: table.clickedRow) else { return }
            inCallback { parent?.actions.onOpen(item) }
        }

        func returnPressed() {
            guard let table, table.selectedRowIndexes.count == 1,
                  let item = item(at: table.selectedRow) else { return }
            parent?.actions.onReturn(item)
        }

        func spacePressed() {
            guard let parent else { return }
            parent.actions.onQuickLook(parent.selectedIDs)
        }

        /// Right click: select the clicked row first (unless it is already part
        /// of the selection, like Finder), then the SwiftUI menu for that selection.
        func menu(forRow row: Int) -> NSMenu? {
            guard let table, let parent else { return nil }
            var ids = parent.selectedIDs
            if row >= 0, let item = item(at: row) {
                if !table.selectedRowIndexes.contains(row) {
                    applyingSelection = true
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    applyingSelection = false
                    ids = [item.id]
                    inCallback { parent.selectedIDs = ids }
                }
            } else {
                // Empty area: the menu for the folder itself.
                ids = []
            }
            if #available(macOS 14.4, *) {
                return NSHostingMenu(rootView: parent.actions.menu(ids))
            }
            if #available(macOS 14.0, *) {
                let menu = NSMenu()
                let open = NSMenuItem(title: "Open", action: #selector(openMenuItem(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = ids
                menu.addItem(open)
                let quickLook = NSMenuItem(title: "Quick Look", action: #selector(quickLookMenuItem(_:)), keyEquivalent: "")
                quickLook.target = self
                quickLook.representedObject = ids
                menu.addItem(quickLook)
                return menu
            }
            return nil
        }

        @objc private func openMenuItem(_ sender: NSMenuItem) {
            guard let ids = sender.representedObject as? Set<String>, let first = ids.first,
                  let item = rows.first(where: { $0.id == first }) else { return }
            inCallback { parent?.actions.onOpen(item) }
        }

        @objc private func quickLookMenuItem(_ sender: NSMenuItem) {
            guard let ids = sender.representedObject as? Set<String> else { return }
            inCallback { parent?.actions.onQuickLook(ids) }
        }

        // MARK: Rename

        func syncRename(_ id: String?) {
            guard let table else { return }
            guard let id else { return }
            guard editingID != id, let row = indexByID[id] else { return }
            editingID = id
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FFNameCell,
                  let field = cell.textField else { editingID = nil; return }
            field.isEditable = true
            field.isSelectable = true
            table.window?.makeFirstResponder(field)
            // Select the name without its extension, like Finder.
            if let editor = field.currentEditor() {
                let name = field.stringValue as NSString
                let ext = name.pathExtension
                let stemLength = (rows[row].isDirectory || ext.isEmpty) ? name.length : name.length - ext.count - 1
                editor.selectedRange = NSRange(location: 0, length: max(0, stemLength))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishRename(control as? NSTextField, commit: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finishRename(obj.object as? NSTextField, commit: true)
        }

        private func finishRename(_ field: NSTextField?, commit: Bool) {
            guard let field, let id = editingID, let parent else { return }
            editingID = nil
            let newName = field.stringValue
            field.isEditable = false
            field.isSelectable = false
            guard let row = indexByID[id], let item = item(at: row) else { return }
            if !commit { field.stringValue = item.name }
            inCallback { parent.actions.onRenameEnd(item, commit ? newName : nil) }
            table?.window?.makeFirstResponder(table)
        }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            item(at: row)?.url as NSURL?
        }

        // MARK: Drop in (folder rows, else the current folder)

        private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
            (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let parent else { return [] }
            let sources = draggedURLs(info)
            guard !sources.isEmpty else { return [] }
            var dest = parent.actions.currentPath
            if dropOperation == .on, let target = item(at: row), target.isDirectory, !target.isPackage,
               !sources.contains(target.url) {
                dest = target.url
                scheduleSpring(row: row, item: target)
            } else {
                cancelSpring()
                tableView.setDropRow(-1, dropOperation: .on)
            }
            // Dragging within the folder onto empty space: nothing to do.
            if dest == parent.actions.currentPath,
               sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == dest.standardizedFileURL }) {
                return []
            }
            if FileDropSupport.isForbidden(sources: sources, destination: dest) { return [] }
            return FileDropSupport.shouldMove(sources: sources, destination: dest) ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            cancelSpring()
            guard let parent, let ops = parent.actions.fileOps else { return false }
            let sources = draggedURLs(info)
            guard !sources.isEmpty else { return false }
            var dest = parent.actions.currentPath
            if row >= 0, dropOperation == .on, let target = item(at: row), target.isDirectory, !target.isPackage {
                dest = target.url
            }
            guard !FileDropSupport.isForbidden(sources: sources, destination: dest) else { return false }
            inCallback {
                ops.importURLs(sources, to: dest,
                               shouldMove: FileDropSupport.shouldMove(sources: sources, destination: dest),
                               reload: parent.actions.onReload)
            }
            return true
        }

        func draggingEnded() { cancelSpring() }

        /// Finder spring-loaded folders: hovering a folder row opens it.
        private func scheduleSpring(row: Int, item: FileItem) {
            guard row != springRow else { return }
            cancelSpring()
            springRow = row
            let work = DispatchWorkItem { [weak self] in
                self?.springRow = -1
                self?.parent?.actions.onOpen(item)
            }
            springWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        private func cancelSpring() {
            springWork?.cancel()
            springWork = nil
            springRow = -1
        }
    }
}

// MARK: - Table view (keys, context menu)

final class FFFileTableView: NSTableView {
    weak var coordinator: NativeFileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter → rename (Finder)
            coordinator?.returnPressed()
        case 49 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty: // Space
            coordinator?.spacePressed()
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return coordinator?.menu(forRow: row) ?? super.menu(for: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        coordinator?.draggingEnded()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        coordinator?.draggingEnded()
    }
}

// MARK: - Cells

/// Icon + name + Drive badge + tag dots. Plain AppKit, reused across rows.
final class FFNameCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("FFNameCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    /// Workspace status glyphs (§13: `●2 ✓ ⚠7d 🔗`), hidden when the file
    /// carries no workspace context. Plain AppKit sibling of WorkspaceBadgeView.
    private let wsLabel = NSTextField(labelWithString: "")
    private let dots = FFTagDotsView()
    private var itemID: String?
    private var thumbnail: ThumbnailRequest?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.focusRingType = .none
        badge.imageScaling = .scaleProportionallyDown
        wsLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        wsLabel.lineBreakMode = .byTruncatingTail
        wsLabel.isEditable = false
        wsLabel.isSelectable = false
        wsLabel.drawsBackground = false
        wsLabel.isBordered = false
        wsLabel.focusRingType = .none
        textField = label
        imageView = icon
        let stack = NSStackView(views: [icon, label, wsLabel, badge, dots])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        wsLabel.setContentHuggingPriority(.required, for: .horizontal)
        wsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        dots.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(equalToConstant: 12),
            badge.heightAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail?.cancel()
        thumbnail = nil
        itemID = nil
        wsLabel.isHidden = true
    }

    func configure(item: FileItem, drive: GoogleDriveBadgeKind?) {
        if label.currentEditor() == nil { label.stringValue = item.name }
        label.isEditable = false
        label.isSelectable = false
        toolTip = nil
        if let drive {
            badge.image = NSImage(systemSymbolName: drive.symbol, accessibilityDescription: drive.label)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            badge.contentTintColor = NSColor(drive.tint)
            badge.toolTip = drive.help
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        let colors = item.tagColors.map { NSColor($0) }
        dots.colors = colors
        dots.isHidden = colors.isEmpty
        configureWorkspaceBadge(for: item)
        loadIcon(for: item)
    }

    /// Workspace glyphs for the flat table (Group By = None). Runs only for
    /// visible reused rows — same rule as the SwiftUI badge views.
    /// Git status slovo (M/A/D/?/!/R) dopisuje se na kraj istog labela.
    private func configureWorkspaceBadge(for item: FileItem) {
        let full = NSMutableAttributedString()
        var tips: [String] = []
        if let b = WorkspaceStore.shared.badge(for: item.url) {
            if b.openTasks > 0 {
                full.append(NSAttributedString(
                    string: "●\(b.openTasks) ",
                    attributes: [.foregroundColor: NSColor.controlAccentColor]))
                tips.append("\(b.openTasks) open task\(b.openTasks == 1 ? "" : "s")")
            }
            if b.endorsed {
                full.append(NSAttributedString(
                    string: "✓ ",
                    attributes: [.foregroundColor: NSColor.systemGreen]))
                tips.append("Reviewed / approved")
            }
            if let days = b.expiresInDays {
                let text = days < 0 ? "exp " : "⚠\(days)d "
                full.append(NSAttributedString(
                    string: text,
                    attributes: [.foregroundColor: days <= 7 ? NSColor.systemRed : NSColor.systemOrange]))
                tips.append(days < 0 ? "Expired \(abs(days)) days ago" : "Expires in \(days) days")
            }
            if b.hasShare {
                full.append(NSAttributedString(
                    string: "🔗",
                    attributes: [.foregroundColor: NSColor.systemBlue]))
                tips.append("Has an active share link")
            }
            if b.hasReminder {
                full.append(NSAttributedString(
                    string: " 🔔",
                    attributes: [.foregroundColor: NSColor.systemOrange]))
                tips.append("Has a reminder")
            }
        }
        if let g = GitService.shared.status(for: item.url) {
            if full.length > 0 { full.append(NSAttributedString(string: " ")) }
            full.append(NSAttributedString(
                string: g.state.rawValue,
                attributes: [.foregroundColor: g.state.nsColor]))
            if g.staged {
                full.append(NSAttributedString(
                    string: "●",
                    attributes: [.foregroundColor: NSColor.systemGreen]))
            }
            tips.append("Git: \(g.state.label)\(g.staged ? " • staged" : "")")
        }
        guard full.length > 0 else {
            wsLabel.isHidden = true
            return
        }
        wsLabel.attributedStringValue = full
        wsLabel.toolTip = tips.joined(separator: " · ")
        wsLabel.isHidden = false
    }

    /// Same pipeline as FileIconView: cache hit → thumbnail → type icon.
    private func loadIcon(for item: FileItem) {
        guard itemID != item.id else { return }
        thumbnail?.cancel()
        thumbnail = nil
        itemID = item.id
        if let hit = FileItem.cachedIcon(for: item.url) { icon.image = hit; return }
        icon.image = FileItem.placeholderIcon(isDirectory: item.isDirectory, isPackage: item.isPackage)
        let id = item.id
        if FileItem.wantsThumbnail(for: item) {
            thumbnail = FileItem.requestThumbnail(for: item) { [weak self] img in
                guard let self, self.itemID == id else { return }
                if let img { self.icon.image = img } else { self.requestTypeIcon(item) }
            }
            return
        }
        requestTypeIcon(item)
    }

    private func requestTypeIcon(_ item: FileItem) {
        let id = item.id
        FileItem.requestIcon(for: item) { [weak self] img in
            guard let self, self.itemID == id else { return }
            self.icon.image = img
        }
    }
}

/// One secondary-text column (Kind, dates, Size, Extension).
final class FFTextCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("FFTextCell")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ text: String, rightAligned: Bool) {
        label.stringValue = text
        label.alignment = rightAligned ? .right : .left
        label.font = rightAligned
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
    }
}

/// Finder tag dots.
final class FFTagDotsView: NSView {
    var colors: [NSColor] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private let size: CGFloat = 9

    override var intrinsicContentSize: NSSize {
        NSSize(width: colors.isEmpty ? 0 : CGFloat(colors.count) * (size + 2) - 2, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, color) in colors.enumerated() {
            let r = NSRect(x: CGFloat(i) * (size + 2), y: (bounds.height - size) / 2, width: size, height: size)
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            color.withAlphaComponent(0.4).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
        }
    }
}
