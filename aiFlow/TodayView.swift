import AppKit
import SwiftUI

// MARK: - Today
//
// One screen for what needs the user now, across everything that already
// tracks work: Workspace tasks, reminders, deadlines, reviews, expiring
// documents and file requests; Mail Inbox mail waiting for a decision and
// its invoice/expiry reminders; what Folder Rules moved today (with Undo);
// Secure Share links about to expire or just signed.
//
// It owns no data: TodaySnapshot is computed from the existing stores, and
// the row actions (Done, Snooze, Undo) go through the same store APIs the
// Workspace panel, Mail Inbox and Folder Rules window use. Opened from the
// sidebar (row with badge), File ▸ Today (⌘0), the ⌘K palette and the
// Shortcuts action "Open Today".

struct TodayEntry: Identifiable {
    enum Kind {
        case task(WorkspaceTask)
        case reminder(WorkspaceReminder)
        case deadline
        case review(relative: String, review: WorkspaceFileReview)
        case expiry(relative: String, days: Int)
        case request(WorkspaceFileRequest)
        case mailReminder(record: MailInboxRecord, reminder: MailReminder)
    }

    let id: String
    let kind: Kind
    let workspaceID: String?
    let workspaceName: String
    let root: URL?
    let date: Date?

    var title: String {
        switch kind {
        case .task(let t): return t.title
        case .reminder(let r): return r.title
        case .deadline: return "Deadline — \(workspaceName)"
        case .review(let rel, _), .expiry(let rel, _): return (rel as NSString).lastPathComponent
        case .request(let r): return r.fileName
        case .mailReminder(let rec, let r):
            let subject = rec.mail.subject.isEmpty ? "(no subject)" : rec.mail.subject
            return r.kind == "invoice_due" ? "Invoice due — \(subject)" : "Expires — \(subject)"
        }
    }

    var symbol: String {
        switch kind {
        case .task: return "checklist"
        case .reminder: return "bell.fill"
        case .deadline: return "flag.fill"
        case .review: return "eye"
        case .expiry: return "hourglass"
        case .request: return "tray.and.arrow.down"
        case .mailReminder(_, let r): return r.kind == "invoice_due" ? "creditcard" : "hourglass"
        }
    }

    /// The document this entry is about, if any (reveal target).
    var fileURL: URL? {
        guard let root else { return nil }
        switch kind {
        case .task(let t): return t.linkedFile.map { root.appendingPathComponent($0) }
        case .reminder(let r): return r.linkedFile.map { root.appendingPathComponent($0) }
        case .review(let rel, _), .expiry(let rel, _): return root.appendingPathComponent(rel)
        default: return nil
        }
    }
}

struct TodaySnapshot {
    var overdue: [TodayEntry] = []
    var today: [TodayEntry] = []
    var upcoming: [TodayEntry] = []
    /// Review requested / review date this week / expiring within 30 days.
    var documents: [TodayEntry] = []
    var waiting: [TodayEntry] = []
    var mailToClassify = 0
    var mailToReview = 0
    var autoSorted: [FolderRuleActivity] = []

    /// Sidebar badge: dated things due by today, reviews asked for, and
    /// documents expiring within a week. Mail and auto-sorts are shown on
    /// the screen but don't nag.
    var badgeCount: Int {
        overdue.count + today.count + documents.filter { e in
            switch e.kind {
            case .review(_, let r): return r.status == .review
            case .expiry(_, let d): return d <= 7
            default: return false
            }
        }.count
    }

    var isEmpty: Bool {
        overdue.isEmpty && today.isEmpty && upcoming.isEmpty && documents.isEmpty
            && waiting.isEmpty && mailToClassify == 0 && mailToReview == 0 && autoSorted.isEmpty
    }

    static func build(workspaces: [Workspace], mail: [MailInboxRecord],
                      ruleActivity: [FolderRuleActivity], now: Date = Date()) -> TodaySnapshot {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? now
        let weekEnd = cal.date(byAdding: .day, value: 8, to: start) ?? now
        let reviewHorizon = cal.date(byAdding: .day, value: 7, to: start) ?? now
        var s = TodaySnapshot()

        func place(_ e: TodayEntry) {
            guard let d = e.date else { return }
            if d < start { s.overdue.append(e) }
            else if d < tomorrow { s.today.append(e) }
            else if d < weekEnd { s.upcoming.append(e) }
        }

        for ws in workspaces {
            let root = URL(fileURLWithPath: ws.rootPath, isDirectory: true)
            func entry(_ id: String, _ kind: TodayEntry.Kind, _ date: Date?) -> TodayEntry {
                TodayEntry(id: "\(ws.id)/\(id)", kind: kind, workspaceID: ws.id,
                           workspaceName: ws.name, root: root, date: date)
            }
            for t in ws.openTasks where t.dueDate != nil {
                place(entry("task-\(t.id)", .task(t), t.dueDate))
            }
            for r in ws.activeReminders {
                place(entry("rem-\(r.id)", .reminder(r), r.fireAt))
            }
            if let d = ws.deadline, ws.status != "Archived" {
                place(entry("deadline", .deadline, d))
            }
            for (rel, meta) in ws.files {
                if let r = meta.review {
                    if r.status == .review {
                        s.documents.append(entry("review-\(rel)", .review(relative: rel, review: r), r.nextReviewDate))
                    } else if let n = r.nextReviewDate, n < reviewHorizon, r.status != .archived {
                        s.documents.append(entry("review-\(rel)", .review(relative: rel, review: r), n))
                    }
                }
                if let v = meta.validity, !v.noLongerRequired, let days = v.daysUntil(now), days <= 30 {
                    s.documents.append(entry("exp-\(rel)", .expiry(relative: rel, days: days), v.expiresAt))
                }
            }
            for req in ws.pendingRequests {
                s.waiting.append(entry("req-\(req.id)", .request(req), req.dueDate))
            }
        }

        for rec in mail {
            switch rec.status {
            case .needsClassification: s.mailToClassify += 1
            case .reviewSuggested: s.mailToReview += 1
            default: break
            }
            for r in rec.reminders where !r.done {
                place(TodayEntry(id: "mail/\(r.id)", kind: .mailReminder(record: rec, reminder: r),
                                 workspaceID: nil, workspaceName: "Mail Inbox", root: nil, date: r.dueDate))
            }
        }

        s.autoSorted = ruleActivity.filter { $0.date >= start && $0.date < tomorrow }

        let byDate: (TodayEntry, TodayEntry) -> Bool = {
            ($0.date ?? .distantFuture, $0.title) < ($1.date ?? .distantFuture, $1.title)
        }
        s.overdue.sort(by: byDate)
        s.today.sort(by: byDate)
        s.upcoming.sort(by: byDate)
        s.waiting.sort(by: byDate)
        // Requested reviews first, then by how soon they (or the expiry) come.
        s.documents.sort { a, b in
            func rank(_ e: TodayEntry) -> Int {
                if case .review(_, let r) = e.kind, r.status == .review { return 0 }
                return 1
            }
            return (rank(a), a.date ?? .distantFuture) < (rank(b), b.date ?? .distantFuture)
        }
        return s
    }
}

/// Secure Share links worth a glance today (read from the local registry).
struct TodayShareItem: Identifiable {
    let id: String
    let filename: String
    let expiresAt: Date?
    let signedBy: String?
    let signedAt: Date?

    /// Active links expiring within 3 days + links signed in the last 7 days.
    static func load(now: Date = Date()) -> [TodayShareItem] {
        guard let db = try? SecureShareDatabase(), let records = try? db.shares() else { return [] }
        let soon = now.addingTimeInterval(3 * 86_400).timeIntervalSince1970
        let weekAgo = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        let nowT = now.timeIntervalSince1970
        var out: [TodayShareItem] = []
        for r in records where r.status == "active" || r.approvalName != nil {
            let signedRecently = r.approvalName != nil && (r.approvalAt ?? 0) >= weekAgo
            let expiringSoon = r.status == "active" && (r.expiresAt.map { $0 > nowT && $0 <= soon } ?? false)
            guard signedRecently || expiringSoon else { continue }
            out.append(TodayShareItem(id: r.id, filename: r.filename,
                                      expiresAt: expiringSoon ? r.expiresAt.map { Date(timeIntervalSince1970: $0) } : nil,
                                      signedBy: signedRecently ? r.approvalName : nil,
                                      signedAt: r.approvalAt.map { Date(timeIntervalSince1970: $0) }))
        }
        return out.sorted { ($0.signedAt ?? .distantPast) > ($1.signedAt ?? .distantPast) }
    }
}

// MARK: - Main window bridge

/// Talks to the browser window from tool windows (Today, palette): the
/// same notifications "Show in Finder" and E-Sign's "Show" use.
enum FFMainWindow {
    static func reveal(_ url: URL) {
        AppDelegate.pendingNavigationURL = url.deletingLastPathComponent()
        NotificationCenter.default.post(name: .ffRevealFile, object: url, userInfo: ["navigate": true])
        bringToFront(fallbackPath: url.deletingLastPathComponent())
    }

    static func open(folder: URL) {
        AppDelegate.pendingNavigationURL = folder
        NotificationCenter.default.post(name: .navigateToPath, object: folder)
        bringToFront(fallbackPath: folder)
    }

    /// The browser is a SwiftUI WindowGroup window; tool windows are plain
    /// NSWindow/NSPanel. With every browser window closed, a finderflow://
    /// link makes SwiftUI open a fresh one at the path.
    static func bringToFront(fallbackPath: URL? = nil) {
        let browser = NSApp.windows.first { w in
            let cls = type(of: w)
            let id = w.identifier?.rawValue ?? ""
            return cls != NSWindow.self && cls != NSPanel.self && w.canBecomeMain
                && !id.contains("Settings") && (w.isVisible || w.isMiniaturized)
        }
        if let browser {
            if browser.isMiniaturized { browser.deminiaturize(nil) }
            browser.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let path = fallbackPath?.path,
                  let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let link = URL(string: "finderflow://open?path=\(q)") {
            NSWorkspace.shared.open(link)
        }
    }
}

// MARK: - Window

final class TodayWindowManager: NSObject, NSWindowDelegate {
    static let shared = TodayWindowManager()
    private var window: NSWindow?

    func open() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: TodayView()))
        window.title = "Today"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 620, height: 720))
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("aiFlowToday")
        if !window.setFrameUsingName("aiFlowToday") { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        window = nil
    }
}

// MARK: - Sidebar row

/// "Today" at the top of the sidebar with the count of things due. Its own
/// view so store changes redraw this row only, never the sidebar list.
struct TodaySidebarRow: View {
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @ObservedObject private var mail = MailStore.shared

    var body: some View {
        let count = TodaySnapshot.build(workspaces: workspaces.workspaces, mail: mail.records,
                                        ruleActivity: []).badgeCount
        Button { TodayWindowManager.shared.open() } label: {
            Label("Today", systemImage: "sun.max")
        }
        .buttonStyle(.plain)
        .badge(count)
        .help(count == 0 ? "Nothing due — open Today (⌘0)" : "\(count) need\(count == 1 ? "s" : "") you today — open Today (⌘0)")
    }
}

// MARK: - View

struct TodayView: View {
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @ObservedObject private var mail = MailStore.shared
    @ObservedObject private var rules = FolderRulesService.shared
    @State private var shares: [TodayShareItem] = []
    @State private var showAllSorted = false
    /// Bumped by the refresh button / window focus so dates re-bucket after
    /// midnight without a store change.
    @State private var now = Date()

    private var snapshot: TodaySnapshot {
        TodaySnapshot.build(workspaces: workspaces.workspaces, mail: mail.records,
                            ruleActivity: rules.activity, now: now)
    }

    var body: some View {
        let s = snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(s)
                if s.isEmpty && shares.isEmpty {
                    allClear
                } else {
                    section("Overdue", symbol: "exclamationmark.circle.fill", tint: .red, s.overdue)
                    section("Today", symbol: "sun.max.fill", tint: .orange, s.today)
                    section("Next 7 Days", symbol: "calendar", tint: .blue, s.upcoming)
                    section("Documents", symbol: "doc.text.magnifyingglass", tint: .purple, s.documents)
                    section("Waiting for Files", symbol: "tray.and.arrow.down.fill", tint: .teal, s.waiting)
                    mailSection(s)
                    sortedSection(s)
                    shareSection
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard let w = n.object as? NSWindow, w.title == "Today" else { return }
            refresh()
        }
    }

    private func refresh() {
        now = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let items = TodayShareItem.load()
            DispatchQueue.main.async { shares = items }
        }
    }

    // MARK: Header

    private func header(_ s: TodaySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 26, weight: .bold))
                Text(summary(s)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
    }

    private func summary(_ s: TodaySnapshot) -> String {
        var parts: [String] = []
        if !s.overdue.isEmpty { parts.append("\(s.overdue.count) overdue") }
        if !s.today.isEmpty { parts.append("\(s.today.count) due today") }
        let docs = s.documents.count
        if docs > 0 { parts.append("\(docs) document\(docs == 1 ? "" : "s") to check") }
        let mailCount = s.mailToClassify + s.mailToReview
        if mailCount > 0 { parts.append("\(mailCount) mail\(mailCount == 1 ? "" : "s") waiting") }
        return parts.isEmpty ? "Nothing is due today." : parts.joined(separator: " · ")
    }

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.green)
            Text("You're all caught up").font(.title3.weight(.semibold))
            Text("Tasks, reminders, reviews and expiring documents from your workspaces show up here, together with mail waiting in the Mail Inbox and what Folder Rules sorted today.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ title: String, symbol: String, tint: Color, _ entries: [TodayEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title, symbol: symbol, tint: tint, count: entries.count)
                card {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, 40) }
                        TodayEntryRow(entry: e, now: now)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String, tint: Color, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).font(.headline)
            if let count { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func mailSection(_ s: TodaySnapshot) -> some View {
        if s.mailToClassify + s.mailToReview > 0 {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Mail Inbox", symbol: "envelope.fill", tint: .indigo)
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.badge")
                            .font(.title3).foregroundStyle(.indigo).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            if s.mailToReview > 0 {
                                Text("\(s.mailToReview) filed mail\(s.mailToReview == 1 ? "" : "s") to confirm")
                            }
                            if s.mailToClassify > 0 {
                                Text("\(s.mailToClassify) mail\(s.mailToClassify == 1 ? "" : "s") waiting to be classified")
                                    .foregroundStyle(s.mailToReview > 0 ? .secondary : .primary)
                            }
                        }
                        Spacer()
                        Button("Open Mail Inbox") { MailInboxWindowManager.shared.open() }
                    }
                    .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private func sortedSection(_ s: TodaySnapshot) -> some View {
        if !s.autoSorted.isEmpty {
            let shown = showAllSorted ? s.autoSorted : Array(s.autoSorted.prefix(6))
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Auto-Sorted Today", symbol: "wand.and.stars", tint: .green, count: s.autoSorted.count)
                card {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().padding(.leading, 40) }
                        sortedRow(a)
                    }
                    if s.autoSorted.count > shown.count || showAllSorted && s.autoSorted.count > 6 {
                        Divider()
                        Button(showAllSorted ? "Show fewer" : "Show all \(s.autoSorted.count)") {
                            showAllSorted.toggle()
                        }
                        .buttonStyle(.link)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func sortedRow(_ a: FolderRuleActivity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.kind == .trash ? "trash" : a.kind == .tag ? "tag" : "arrow.right.doc.on.clipboard")
                .foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.fileName).lineLimit(1).truncationMode(.middle)
                    .strikethrough(a.undone, color: .secondary)
                Text(sortedDetail(a)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(a.date.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            if a.undone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Undo") { rules.undo(a.id) }
                    .controlSize(.small)
                if let to = a.to, a.kind != .trash {
                    Button { FFMainWindow.reveal(URL(fileURLWithPath: to)) } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in aiFlow")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// "Downloads · PDF invoices → Documents/Računi" — the rule summary
    /// already says where the file went (or Trash / the tag).
    private func sortedDetail(_ a: FolderRuleActivity) -> String {
        "\((a.folder as NSString).lastPathComponent) · \(a.ruleSummary)"
    }

    @ViewBuilder
    private var shareSection: some View {
        if !shares.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Shared Links", symbol: "link", tint: .blue, count: shares.count)
                card {
                    ForEach(Array(shares.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 40) }
                        HStack(spacing: 12) {
                            Image(systemName: item.signedBy != nil ? "signature" : "clock.badge.exclamationmark")
                                .foregroundStyle(item.signedBy != nil ? .green : .orange).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename).lineLimit(1).truncationMode(.middle)
                                Text(shareDetail(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Manage") { SecureShareWindowManager.shared.open() }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func shareDetail(_ item: TodayShareItem) -> String {
        var parts: [String] = []
        if let who = item.signedBy {
            let when = item.signedAt.map { $0.formatted(.relative(presentation: .named)) } ?? ""
            parts.append("Signed by \(who) \(when)".trimmingCharacters(in: .whitespaces))
        }
        if let exp = item.expiresAt {
            parts.append("Link expires \(exp.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Row

private struct TodayEntryRow: View {
    let entry: TodayEntry
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let label = dateLabel {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isLate ? .red : .secondary)
            }
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { open() }
        .contextMenu { menu }
    }

    // MARK: Parts

    @ViewBuilder
    private var leading: some View {
        switch entry.kind {
        case .task(let t):
            Button { complete(t) } label: {
                Image(systemName: "circle").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Mark as done")
        case .reminder(let r):
            Button { done(r) } label: {
                Image(systemName: "bell.circle").font(.title3).foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Mark as done")
        case .mailReminder(let rec, let r):
            Button { doneMail(rec, r) } label: {
                Image(systemName: entry.symbol).foregroundStyle(.indigo)
            }
            .buttonStyle(.borderless)
            .help("Mark as done")
        default:
            Image(systemName: entry.symbol).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch entry.kind {
        case .reminder(let r):
            Menu {
                snoozeItems(r)
            } label: {
                Image(systemName: "moon.zzz")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Snooze")
        case .task(let t) where t.dueDate.map { $0 < Calendar.current.startOfDay(for: now) } ?? false:
            Button("Today") { moveTask(t, to: now) }
                .controlSize(.small)
                .help("Move the due date to today")
        default:
            EmptyView()
        }
        Button { open() } label: { Image(systemName: "arrow.right.circle") }
            .buttonStyle(.borderless)
            .help(entry.fileURL != nil ? "Show the document in aiFlow" : "Open in aiFlow")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Show in aiFlow") { open() }
        if let root = entry.root, entry.fileURL != nil {
            Button("Open Workspace Folder") { FFMainWindow.open(folder: root) }
        }
        switch entry.kind {
        case .task(let t):
            Divider()
            Button("Mark as Done") { complete(t) }
            Button("Due Today") { moveTask(t, to: now) }
            Button("Due Tomorrow") { moveTask(t, to: now.addingTimeInterval(86_400)) }
        case .reminder(let r):
            Divider()
            Button("Mark as Done") { done(r) }
            snoozeItems(r)
        case .mailReminder(let rec, let r):
            Divider()
            Button("Mark as Done") { doneMail(rec, r) }
            Button("Open Mail Inbox") { MailInboxWindowManager.shared.open() }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func snoozeItems(_ r: WorkspaceReminder) -> some View {
        Button("In 1 Hour") { snooze(r, to: Date().addingTimeInterval(3_600)) }
        Button("Tomorrow at 9:00") { snooze(r, to: Self.tomorrowMorning()) }
        Button("Next Week") {
            snooze(r, to: Calendar.current.date(byAdding: .day, value: 7, to: Self.tomorrowMorning())
                   ?? Date().addingTimeInterval(7 * 86_400))
        }
    }

    // MARK: Text

    private var detail: String {
        var parts: [String] = []
        switch entry.kind {
        case .task(let t):
            parts.append(entry.workspaceName)
            if let f = t.linkedFile { parts.append((f as NSString).lastPathComponent) }
            if let a = t.assignee, !a.isEmpty { parts.append(a) }
            if t.priority == .high || t.priority == .urgent { parts.append(t.priority.title) }
        case .reminder(let r):
            parts.append(entry.workspaceName)
            if let f = r.linkedFile { parts.append((f as NSString).lastPathComponent) }
        case .deadline:
            parts.append("Workspace deadline")
        case .review(let rel, let r):
            parts.append(r.status == .review ? "Review requested" : "Review due")
            if let who = r.reviewer, !who.isEmpty { parts.append(who) }
            parts.append(entry.workspaceName)
            let folder = (rel as NSString).deletingLastPathComponent
            if !folder.isEmpty { parts.append(folder) }
        case .expiry(_, let days):
            parts.append(days < 0 ? "Expired \(-days) day\(days == -1 ? "" : "s") ago"
                         : days == 0 ? "Expires today" : "Expires in \(days) day\(days == 1 ? "" : "s")")
            parts.append(entry.workspaceName)
        case .request(let r):
            if let from = r.requestedFrom, !from.isEmpty { parts.append("From \(from)") }
            parts.append(entry.workspaceName)
        case .mailReminder(let rec, _):
            let who = rec.suggestion.entity.isEmpty ? rec.mail.from : rec.suggestion.entity
            parts.append(who)
            if let amount = rec.suggestion.facts["amount"], !amount.isEmpty {
                parts.append([amount, rec.suggestion.facts["currency"] ?? ""].joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var isLate: Bool {
        guard let d = entry.date else { return false }
        if case .reminder = entry.kind { return d < now }
        return d < Calendar.current.startOfDay(for: now)
    }

    private var dateLabel: String? {
        guard let d = entry.date else { return nil }
        let cal = Calendar.current
        switch entry.kind {
        case .reminder:
            if cal.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened) }
            return d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        default:
            if cal.isDate(d, inSameDayAs: now) { return "Today" }
            if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
            if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow" }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
            if days < 0 { return "\(-days)d late" }
            if days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
            return d.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    // MARK: Actions

    private func open() {
        if let url = entry.fileURL, FileManager.default.fileExists(atPath: url.path) {
            FFMainWindow.reveal(url)
        } else if let root = entry.root {
            FFMainWindow.open(folder: root)
        } else if case .mailReminder = entry.kind {
            MailInboxWindowManager.shared.open()
        }
    }

    private func complete(_ t: WorkspaceTask) {
        guard let id = entry.workspaceID else { return }
        var next = t
        next.status = .done
        withAnimation { WorkspaceStore.shared.updateTask(workspaceID: id, next) }
    }

    private func moveTask(_ t: WorkspaceTask, to day: Date) {
        guard let id = entry.workspaceID else { return }
        var next = t
        // Keep the time of day the task had (end of day for date-only ones).
        let cal = Calendar.current
        let time = t.dueDate.map { cal.dateComponents([.hour, .minute], from: $0) } ?? DateComponents(hour: 17)
        next.dueDate = cal.date(bySettingHour: time.hour ?? 17, minute: time.minute ?? 0, second: 0, of: day) ?? day
        WorkspaceStore.shared.updateTask(workspaceID: id, next)
    }

    private func done(_ r: WorkspaceReminder) {
        guard let id = entry.workspaceID else { return }
        var next = r
        next.done = true
        withAnimation { WorkspaceStore.shared.updateReminder(workspaceID: id, next) }
    }

    private func snooze(_ r: WorkspaceReminder, to date: Date) {
        guard let id = entry.workspaceID else { return }
        var next = r
        next.fireAt = date
        WorkspaceStore.shared.updateReminder(workspaceID: id, next)
    }

    private func doneMail(_ rec: MailInboxRecord, _ r: MailReminder) {
        var next = rec
        guard let i = next.reminders.firstIndex(where: { $0.id == r.id }) else { return }
        next.reminders[i].done = true
        withAnimation { MailStore.shared.update(next) }
    }

    private static func tomorrowMorning() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
