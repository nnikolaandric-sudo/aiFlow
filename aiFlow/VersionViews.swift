import AppKit
import PDFKit
import SwiftUI

// MARK: - Version History (UI)
//
// The tree from VersionStore, drawn the way a person reads it:
//
//   ● v4          Current
//   ● v3
//   │ └─● v3.1    Ugovor - Klijent.docx
//   │    ● v3.2
//   ● v2
//   ● v1
//
// Shown in the preview panel (Versions tab of a workspace file, a one-line
// summary for other tracked files), in its own window (right-click ▸
// Version History…), with Preview · Restore · Duplicate · Compare for the
// selected version. Settings ▸ Browse ▸ Version History holds the switch,
// tracked folders and the storage used.

// MARK: Rows

struct VersionTreeRow: Identifiable {
    let id: String
    let version: DocVersion
    let lineIndex: Int
    let indent: Int
    /// First row of a branch: the branch's file name.
    let branchName: String?
    /// Latest version of its line (that file's current content).
    let isLineCurrent: Bool
    let lineMissing: Bool
    // Drawing: the main spine above/below this row, the branch chain.
    let spineAbove: Bool
    let spineBelow: Bool
    let branchContinues: Bool

    static func build(_ fam: VersionFamily) -> [VersionTreeRow] {
        var rows: [VersionTreeRow] = []
        func children(of label: String) -> [Int] {
            fam.lines.indices.filter { fam.lines[$0].base == label }
                .sorted { (fam.lines[$0].versions.first?.capturedAt ?? .distantPast) < (fam.lines[$1].versions.first?.capturedAt ?? .distantPast) }
        }
        func emitBranch(_ li: Int, indent: Int, spine: Bool) {
            let line = fam.lines[li]
            for (vi, v) in line.versions.enumerated() {
                let last = vi == line.versions.count - 1
                rows.append(VersionTreeRow(id: v.id, version: v, lineIndex: li, indent: indent,
                                           branchName: vi == 0 ? line.name : nil, isLineCurrent: last,
                                           lineMissing: line.missingSince != nil,
                                           spineAbove: spine, spineBelow: spine, branchContinues: !last))
                for c in children(of: v.label) { emitBranch(c, indent: indent + 1, spine: spine) }
            }
        }
        let main = fam.lines[0]
        for (i, v) in main.versions.enumerated().reversed() {
            rows.append(VersionTreeRow(id: v.id, version: v, lineIndex: 0, indent: 0, branchName: nil,
                                       isLineCurrent: i == main.versions.count - 1,
                                       lineMissing: main.missingSince != nil,
                                       spineAbove: i < main.versions.count - 1, spineBelow: i > 0,
                                       branchContinues: false))
            for c in children(of: v.label) { emitBranch(c, indent: 1, spine: i > 0) }
        }
        return rows
    }
}

/// The tree lines of one row: main spine, branch elbow, branch chain, dot.
struct VersionGutter: View {
    let row: VersionTreeRow
    let highlighted: Bool
    static let step: CGFloat = 16
    static let mainX: CGFloat = 5

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let line = GraphicsContext.Shading.color(Color.secondary.opacity(0.45))
            let dotX = Self.mainX + CGFloat(row.indent) * Self.step
            func stroke(_ path: Path) { ctx.stroke(path, with: line, lineWidth: 1.5) }
            if row.indent == 0 {
                if row.spineAbove { stroke(Path { $0.move(to: .init(x: Self.mainX, y: 0)); $0.addLine(to: .init(x: Self.mainX, y: midY)) }) }
                if row.spineBelow { stroke(Path { $0.move(to: .init(x: Self.mainX, y: midY)); $0.addLine(to: .init(x: Self.mainX, y: size.height)) }) }
            } else {
                if row.spineAbove { stroke(Path { $0.move(to: .init(x: Self.mainX, y: 0)); $0.addLine(to: .init(x: Self.mainX, y: size.height)) }) }
                let parentX = dotX - Self.step
                if row.branchName != nil {
                    // Elbow from the version it branched from.
                    stroke(Path { p in
                        p.move(to: .init(x: parentX, y: 0))
                        p.addLine(to: .init(x: parentX, y: midY - 4))
                        p.addQuadCurve(to: .init(x: parentX + 4, y: midY), control: .init(x: parentX, y: midY))
                        p.addLine(to: .init(x: dotX, y: midY))
                    })
                } else {
                    stroke(Path { $0.move(to: .init(x: dotX, y: 0)); $0.addLine(to: .init(x: dotX, y: midY)) })
                }
                if row.branchContinues {
                    stroke(Path { $0.move(to: .init(x: dotX, y: midY)); $0.addLine(to: .init(x: dotX, y: size.height)) })
                }
            }
            let r: CGFloat = row.indent == 0 ? 5 : 4.5
            let dot = Path(ellipseIn: CGRect(x: dotX - r, y: midY - r, width: r * 2, height: r * 2))
            if row.version.isKept {
                ctx.fill(dot, with: .color(highlighted ? Color.accentColor : Color.primary.opacity(0.7)))
            } else {
                ctx.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(dot, with: .color(.secondary), lineWidth: 1)
            }
        }
        .frame(width: Self.mainX + CGFloat(row.indent) * Self.step + 8)
    }
}

// MARK: Panel

struct VersionPanel: View {
    let url: URL
    /// Preview panel (narrow) vs. its own window.
    var compact = true
    @ObservedObject private var store = VersionStore.shared
    @State private var selectedID: String?
    @State private var confirmRestore: DocVersion?
    @State private var message: String?

    var body: some View {
        let found = store.family(for: url)
        VStack(alignment: .leading, spacing: 10) {
            if let s = store.suggestion(for: url) { suggestionCard(s) }
            if let (fam, li) = found {
                header(fam, li)
                VersionGuide()
                tree(fam, currentLine: li)
                if let row = VersionTreeRow.build(fam).first(where: { $0.id == selectedID }) {
                    actions(row, fam)
                } else {
                    Text("Click a version to preview, restore, duplicate or compare it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if store.isTracked(url) {
                emptyState("No versions yet", "The first version is saved in a moment — or now:",
                           button: ("Save Version Now", { store.captureNow(url) }))
            } else {
                emptyState("Version history is off here",
                           "Turn it on for this folder and every save becomes v2, v3… — Save As makes v3.1.",
                           button: ("Track Versions in “\(url.deletingLastPathComponent().lastPathComponent)”", {
                               store.setFolderTracked(url.deletingLastPathComponent(), true)
                           }))
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { preselect(found) }
        .onChange(of: url) { _, _ in selectedID = nil; preselect(store.family(for: url)) }
        .alert("Restore \(confirmRestore?.label ?? "")?", isPresented: Binding(
            get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore") { if let v = confirmRestore, let f = found { restore(v, fam: f.family) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(url.lastPathComponent)” gets the content of \(confirmRestore?.label ?? ""). What it has now is kept in the history, so nothing is lost.")
        }
    }

    /// The version before the current one is what people come to restore
    /// or compare — select it so the actions are right there.
    private func preselect(_ found: (family: VersionFamily, line: Int)?) {
        guard selectedID == nil, let (fam, li) = found else { return }
        let versions = fam.lines[li].versions
        selectedID = (versions.count >= 2 ? versions[versions.count - 2] : versions.last)?.id
    }

    // MARK: Parts

    private func header(_ fam: VersionFamily, _ li: Int) -> some View {
        let line = fam.lines[li]
        let mainCount = fam.main.versions.count
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
                Text("Current: \(line.current?.label ?? "–")").font(.headline)
                Spacer()
                Button { store.captureNow(url) { l in message = l.map { "Saved as \($0)" } } } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Save a version now")
            }
            Text("\(mainCount) saved version\(mainCount == 1 ? "" : "s")\(fam.branchCount > 0 ? " · \(fam.branchCount) branch\(fam.branchCount == 1 ? "" : "es") (Save As / Duplicate)" : "") · \(line.name)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func tree(_ fam: VersionFamily, currentLine: Int) -> some View {
        let rows = VersionTreeRow.build(fam)
        return VStack(alignment: .leading, spacing: 0) {
            Text("VERSION HISTORY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                treeRow(row, fam: fam, viewedLine: currentLine)
            }
        }
    }

    private func treeRow(_ row: VersionTreeRow, fam: VersionFamily, viewedLine: Int) -> some View {
        let selected = row.id == selectedID
        let isViewedCurrent = row.lineIndex == viewedLine && row.isLineCurrent
        let gutter = VersionGutter.mainX + CGFloat(row.indent) * VersionGutter.step + 8
        return HStack(alignment: .center, spacing: 6) {
            Color.clear.frame(width: gutter, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.version.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(row.version.isKept ? Color.primary : Color.secondary)
                    if isViewedCurrent {
                        Text("Current").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    } else if row.isLineCurrent && row.lineIndex != 0 && !compact {
                        Text("latest").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let name = row.branchName {
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if row.lineMissing && row.isLineCurrent {
                        Text("deleted").font(.caption2).foregroundStyle(.red)
                    }
                }
                if let note = row.version.note, !compact || selected {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if !row.version.isKept {
                    Text("Not kept (over 5 GB)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Text(Self.when(row.version.date))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 5).padding(.trailing, 4)
        .background(alignment: .leading) { VersionGutter(row: row, highlighted: isViewedCurrent).padding(.leading, 4) }
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = selected ? nil : row.id }
        .onTapGesture(count: 2) { preview(row.version, fam: fam, line: row.lineIndex) }
        .help("\(row.version.label) · \(ByteCountFormatter.string(fromByteCount: row.version.size, countStyle: .file)) · \(row.version.date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func actions(_ row: VersionTreeRow, _ fam: VersionFamily) -> some View {
        let v = row.version
        let line = fam.lines[row.lineIndex]
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text(v.label).font(.system(size: 12, weight: .bold, design: .rounded))
                Text(line.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Button("Preview") { preview(v, fam: fam, line: row.lineIndex) }
                Button("Restore") { confirmRestore = v }
                    .disabled(row.isLineCurrent && !row.lineMissing)
                    .help(row.isLineCurrent ? "This is already the file's content" : "Put this version back into the file")
                Button("Duplicate") { duplicate(v, fam: fam, line: row.lineIndex) }
                Menu("Compare") {
                    if let cur = line.current, cur.id != v.id {
                        Button("With Current (\(cur.label))") { compare(v, with: cur, fam: fam, line: row.lineIndex) }
                    }
                    if let prev = previous(of: v, in: fam, line: row.lineIndex) {
                        Button("With Previous (\(prev.label))") { compare(prev, with: v, fam: fam, line: row.lineIndex) }
                    }
                }
                .fixedSize()
            }
            .controlSize(.small)
            .disabled(!v.isKept)
        }
    }

    private func suggestionCard(_ s: ForkSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("New version?", systemImage: "arrow.triangle.branch")
                .font(.callout.weight(.semibold))
            Text("This file appears to be a new version of \(s.baseName) \(s.baseLabel).")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Create Branch \(VersionFamily.childLabel(of: s.baseLabel, in: store.index.families.first { $0.id == s.familyID }))") {
                    store.acceptSuggestion(s.id)
                }
                .buttonStyle(.borderedProminent)
                Button("Keep Separate") { store.dismissSuggestion(s.id) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState(_ title: String, _ text: String, button: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "clock.arrow.circlepath").font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(button.0, action: button.1).controlSize(.small)
        }
    }

    // MARK: Actions

    private func previous(of v: DocVersion, in fam: VersionFamily, line li: Int) -> DocVersion? {
        let line = fam.lines[li]
        if let i = line.versions.firstIndex(where: { $0.id == v.id }), i > 0 { return line.versions[i - 1] }
        // First version of a branch: its base.
        if let base = line.base, let hit = fam.version(labeled: base) { return fam.lines[hit.line].versions[hit.version] }
        return nil
    }

    private func preview(_ v: DocVersion, fam: VersionFamily, line li: Int) {
        guard let u = store.exportForPreview(v, name: fam.lines[li].name) else {
            message = "\(v.label) isn't stored anymore."
            return
        }
        QuickLookController.shared.show([u])
    }

    private func restore(_ v: DocVersion, fam: VersionFamily) {
        guard let row = VersionTreeRow.build(fam).first(where: { $0.id == v.id }) else { return }
        let line = fam.lines[row.lineIndex]
        store.restore(v, lineID: line.id, familyID: fam.id) { r in
            switch r {
            case .success(let label): message = "Restored \(v.label) — the file is now \(label)."
            case .failure(let e): message = e.localizedDescription
            }
        }
    }

    private func duplicate(_ v: DocVersion, fam: VersionFamily, line li: Int) {
        store.duplicate(v, lineID: fam.lines[li].id, familyID: fam.id) { r in
            switch r {
            case .success(let u):
                message = "Saved “\(u.lastPathComponent)”."
                NotificationCenter.default.post(name: .ffRevealFile, object: u)
            case .failure(let e): message = e.localizedDescription
            }
        }
    }

    private func compare(_ old: DocVersion, with new: DocVersion, fam: VersionFamily, line li: Int) {
        let name = fam.lines[li].name
        // A branch's base lives on another line; any stored copy will do.
        guard let a = store.exportForPreview(old, name: name), let b = store.exportForPreview(new, name: name) else {
            message = "One of the versions isn't stored anymore."
            return
        }
        VersionCompareWindowManager.shared.open(old: a, oldLabel: old.label, new: b, newLabel: new.label, name: name)
    }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today " + d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Preview panel card

/// A small card under the file info: is history on, which version this is,
/// when it was saved, and the way in (History…). Plain words, no jargon.
struct VersionInfoRow: View {
    let url: URL
    @ObservedObject private var store = VersionStore.shared

    var body: some View {
        if let s = store.suggestion(for: url) {
            card(symbol: "arrow.triangle.branch", tint: .purple,
                 title: "Copy of \(s.baseName)?",
                 detail: "It looks like a Save As of \(s.baseLabel). Open History to keep it as a branch, or separate.",
                 button: "Review…")
        } else if let (fam, li) = store.family(for: url), let cur = fam.lines[li].current {
            let saves = fam.lines[li].versions.count
            let branches = fam.branchCount
            if saves <= 1 && branches == 0 && fam.lines[li].base == nil {
                card(symbol: "clock.arrow.circlepath", tint: .accentColor,
                     title: "Version history is on",
                     detail: "Saved \(VersionPanel.when(cur.date).lowercased()). From now on every save is kept — you can go back to any of them.",
                     button: "History…")
            } else {
                card(symbol: "clock.arrow.circlepath", tint: .accentColor,
                     title: "Version \(cur.label)",
                     detail: "\(saves) saved version\(saves == 1 ? "" : "s")\(branches > 0 ? " · \(branches) branch\(branches == 1 ? "" : "es")" : "") · last saved \(VersionPanel.when(cur.date).lowercased())",
                     button: "History…")
            }
        }
    }

    private func card(symbol: String, tint: Color, title: String, detail: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.6)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(button) { VersionHistoryWindowManager.shared.open(url) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - How it works (shown until dismissed)

struct VersionGuide: View {
    @AppStorage("ffVersionsGuideSeen") private var seen = false
    @State private var open = false

    var body: some View {
        if !seen || open {
            VStack(alignment: .leading, spacing: 8) {
                Label("How version history works", systemImage: "info.circle")
                    .font(.callout.weight(.semibold))
                step("1", "Save as usual (⌘S). Each save becomes the next version — v2, v3, v4.")
                step("2", "Save As or Duplicate makes a branch: a copy of v3 becomes v3.1, and its saves v3.2, v3.3.")
                step("3", "Click a version to Preview, Restore, Duplicate or Compare it. Restore keeps what you have now as a version too, so nothing is lost.")
                HStack {
                    Spacer()
                    Button(seen ? "Hide" : "Got it") { seen = true; open = false }
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Button { open = true } label: { Label("How it works", systemImage: "info.circle") }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Window

final class VersionHistoryWindowManager: NSObject, NSWindowDelegate {
    static let shared = VersionHistoryWindowManager()
    private var windows: [URL: NSWindow] = [:]

    func open(_ url: URL) {
        if let w = windows[url] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = ScrollView {
            VersionPanel(url: url, compact: false).padding(16)
        }
        .frame(minWidth: 380, minHeight: 360)
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        w.title = "Version History — \(url.lastPathComponent)"
        w.representedURL = url
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.tabbingMode = .disallowed
        w.setContentSize(NSSize(width: 460, height: 560))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        windows[url] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
    }
}

// MARK: - Right-click

struct VersionMenuItems: View {
    let urls: [URL]

    var body: some View {
        if urls.count == 1, let url = urls.first {
            let store = VersionStore.shared
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists && isDir.boolValue && url.pathExtension.isEmpty {
                if WorkspaceStore.shared.isWorkspace(url) {
                    Button {} label: { Label("Versions: On (Workspace)", systemImage: "clock.arrow.circlepath") }
                        .disabled(true)
                } else {
                    let on = store.isUserFolder(url)
                    Button { store.setFolderTracked(url, !on) } label: {
                        Label(on ? "Stop Tracking Versions" : "Track Versions", systemImage: "clock.arrow.circlepath")
                    }
                }
            } else if exists, store.family(for: url) != nil || store.isTracked(url) || store.suggestion(for: url) != nil {
                Button { VersionHistoryWindowManager.shared.open(url) } label: {
                    Label(store.label(for: url).map { "Version History (\($0))…" } ?? "Version History…",
                          systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }
}

// MARK: - Settings ▸ Browse

struct VersionSettingsSection: View {
    @ObservedObject private var store = VersionStore.shared
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @State private var confirmClear = false

    var body: some View {
        Section {
            Toggle("Keep a version history of documents", isOn: Binding(
                get: { store.index.enabled }, set: { store.setEnabled($0) }))
            Text("Every save in a tracked folder becomes a new version (v2, v3…); Save As or Duplicate becomes a branch (v3.1). Workspace folders are always tracked; add others with right-click ▸ Track Versions. Everything stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let used = store.historyBytes
            LabeledContent("History storage") {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: min(Double(used), Double(VersionStore.capBytes)), total: Double(VersionStore.capBytes))
                        .frame(width: 180)
                    Text("\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: VersionStore.capBytes, countStyle: .file)) — oldest copies go first; each file keeps its last 3")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Tracked") {
                Text("\(workspaces.workspaces.count) workspace\(workspaces.workspaces.count == 1 ? "" : "s") · \(store.index.folders.count) folder\(store.index.folders.count == 1 ? "" : "s") · \(store.index.families.count) document\(store.index.families.count == 1 ? "" : "s")")
                    .font(.caption)
            }
            ForEach(store.index.folders, id: \.self) { p in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text((p as NSString).abbreviatingWithTildeInPath).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { store.setFolderTracked(URL(fileURLWithPath: p), false) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Button("Clear All History…", role: .destructive) { confirmClear = true }
                .controlSize(.small)
                .confirmationDialog("Delete every stored version?", isPresented: $confirmClear) {
                    Button("Delete History", role: .destructive) { store.clearAll() }
                } message: {
                    Text("Your files stay exactly as they are; only aiFlow's saved copies of earlier versions are removed.")
                }
        } header: {
            FFSectionHeader(title: "Version History", symbol: "clock.arrow.circlepath", tint: .purple)
        }
    }
}

// MARK: - Compare

enum VersionText {
    /// Plain text of a document for comparing, when there is a way to read it.
    static func extract(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return PDFDocument(url: url)?.string
        case "docx", "doc", "rtf", "odt", "html", "htm", "webarchive", "wordml":
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        case "xlsx":
            return zipText(url, parts: ["xl/sharedStrings.xml", "xl/worksheets/sheet*.xml"], tags: ["t", "v"])
        case "pptx":
            return zipText(url, parts: ["ppt/slides/slide*.xml"], tags: ["a:t"])
        default:
            guard let data = try? Data(contentsOf: url), data.count < 20 << 20,
                  !data.contains(0), let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
    }

    /// Text nodes from Office XML parts (unzip ships with macOS).
    private static func zipText(_ url: URL, parts: [String], tags: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path] + parts
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else { return nil }
        var out: [String] = []
        for tag in tags {
            let pattern = "<\(tag)(?: [^>]*)?>([^<]*)</\(tag)>"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                if let r = Range(m.range(at: 1), in: xml) { out.append(String(xml[r])) }
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}

struct VersionDiffLine: Identifiable {
    enum Kind { case same, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String

    /// Line diff (Swift's CollectionDifference, Myers).
    static func diff(old: String, new: String) -> [VersionDiffLine] {
        let a = old.components(separatedBy: .newlines)
        let b = new.components(separatedBy: .newlines)
        let d = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [VersionDiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append(.init(kind: .removed, text: a[i])); i += 1; continue }
            if j < b.count, inserted.contains(j) { out.append(.init(kind: .added, text: b[j])); j += 1; continue }
            if i < a.count, j < b.count { out.append(.init(kind: .same, text: b[j])); i += 1; j += 1; continue }
            if i < a.count { out.append(.init(kind: .removed, text: a[i])); i += 1 }
            else if j < b.count { out.append(.init(kind: .added, text: b[j])); j += 1 }
        }
        return out
    }
}

final class VersionCompareWindowManager: NSObject, NSWindowDelegate {
    static let shared = VersionCompareWindowManager()
    private var windows: [NSWindow] = []

    func open(old: URL, oldLabel: String, new: URL, newLabel: String, name: String) {
        let view = VersionCompareView(old: old, oldLabel: oldLabel, new: new, newLabel: newLabel, name: name)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "\(name) — \(oldLabel) → \(newLabel)"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.tabbingMode = .disallowed
        w.setContentSize(NSSize(width: 720, height: 620))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === w }
    }
}

struct VersionCompareView: View {
    let old: URL, oldLabel: String
    let new: URL, newLabel: String
    let name: String
    @State private var lines: [VersionDiffLine]?
    @State private var unsupported = false
    @State private var changesOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(oldLabel).font(.system(.headline, design: .rounded))
                Image(systemName: "arrow.right")
                Text(newLabel).font(.system(.headline, design: .rounded))
                if let lines {
                    let add = lines.filter { $0.kind == .added }.count
                    let del = lines.filter { $0.kind == .removed }.count
                    Text("+\(add)").foregroundStyle(.green).monospacedDigit()
                    Text("−\(del)").foregroundStyle(.red).monospacedDigit()
                }
                Spacer()
                Toggle("Changes only", isOn: $changesOnly).toggleStyle(.checkbox)
                Button("Quick Look Both") { QuickLookController.shared.show([old, new]) }
            }
            .padding(12)
            Divider()
            if unsupported {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("aiFlow can't read the text of this file type.").foregroundStyle(.secondary)
                    Button("Quick Look Both") { QuickLookController.shared.show([old, new]) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lines {
                let shown = changesOnly ? context(lines) : lines
                if shown.isEmpty {
                    Text("The text is the same — only formatting or metadata changed.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { l in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(l.kind == .added ? "+" : l.kind == .removed ? "−" : " ")
                                        .foregroundStyle(l.kind == .added ? .green : l.kind == .removed ? .red : .secondary)
                                        .frame(width: 10)
                                    Text(l.text.isEmpty ? " " : l.text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 1.5)
                                .background(l.kind == .added ? Color.green.opacity(0.12)
                                            : l.kind == .removed ? Color.red.opacity(0.12) : .clear)
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task {
            let (o, n) = await Task.detached { (VersionText.extract(old), VersionText.extract(new)) }.value
            if let o, let n { lines = VersionDiffLine.diff(old: o, new: n) } else { unsupported = true }
        }
    }

    /// Changed lines with two lines of context, "…" between hunks.
    private func context(_ all: [VersionDiffLine]) -> [VersionDiffLine] {
        var keep = Set<Int>()
        for (i, l) in all.enumerated() where l.kind != .same {
            for k in max(0, i - 2)...min(all.count - 1, i + 2) { keep.insert(k) }
        }
        var out: [VersionDiffLine] = []
        var last = -1
        for i in keep.sorted() {
            if last >= 0, i > last + 1 { out.append(VersionDiffLine(kind: .same, text: "…")) }
            out.append(all[i])
            last = i
        }
        return out
    }
}
