import SwiftUI
import AppKit
import UserNotifications

// MARK: - Workspace Mode UI (PRD §2–§17)
//
// Lives inside the existing Preview/Inspector panel — never a separate
// screen (§16: "Folder → klik na fajl → radi sa fajlom").

// MARK: - Badges (§13)

/// Compact badges for file rows: `●2` open tasks, `✓` reviewed/approved,
/// `⚠ 7d` expiring soon, `🔗` active share link. Hover shows the detail.
struct WorkspaceBadgeView: View {
    let badge: WorkspaceStore.Badge

    var body: some View {
        HStack(spacing: 4) {
            if badge.openTasks > 0 {
                HStack(spacing: 2) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text("\(badge.openTasks)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .help("\(badge.openTasks) open task\(badge.openTasks == 1 ? "" : "s")")
            }
            if badge.endorsed {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .help("Reviewed / approved")
            }
            if let days = badge.expiresInDays {
                HStack(spacing: 2) {
                    Image(systemName: days < 0 ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                        .font(.system(size: 10))
                    Text(days < 0 ? "exp" : "\(days)d")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(days <= 7 ? .red : .orange)
                .help(days < 0 ? "Expired \(abs(days)) days ago" : "Expires in \(days) days")
            }
            if badge.hasShare {
                Image(systemName: "link")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                    .help("Has an active share link")
            }
            if badge.hasReminder {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Has a reminder")
            }
            // Version History (VersionViews.swift): current version of the file.
            if let v = badge.versionLabel {
                Text(v)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .foregroundStyle(.secondary)
                    .help("Version \(v) — right-click ▸ Version History")
            }
        }
    }
}

// MARK: - Enable prompt (§2)

/// One quiet row under plain folders — not a hero card. Workspaces are
/// discovered, not advertised: the row explains on hover and enables in
/// one click (§2, simplicity by design).
struct EnableWorkspacePrompt: View {
    let folder: URL
    @ObservedObject var store = WorkspaceStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "briefcase")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Workspace")
                    .font(.system(size: 11, weight: .medium))
                Text("Tasks, reviews & dates for this folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Enable") {
                store.enableWorkspace(at: folder)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Attach tasks, reviews, expiry dates and links to this folder — right inside the preview panel.")
    }
}

// MARK: - Overview (§3, §15)

struct WorkspaceOverviewView: View {
    let workspaceID: String
    let rootURL: URL
    var onRevealFile: (URL) -> Void = { _ in }
    var onEnterFolder: (URL) -> Void = { _ in }
    @ObservedObject var store = WorkspaceStore.shared

    @State private var tab: WsTab = .overview
    @State private var showTaskSheet = false
    @State private var showReminderSheet = false
    @State private var showRequestSheet = false
    @State private var showDisableConfirm = false
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var sharesTotal: Int? = nil
    @State private var sharesFiles: [(relative: String, count: Int)] = []
    @State private var sharesLoading = false
    /// True when Mac notifications are denied: active reminders can't ring,
    /// so the overview says so with a way out (instead of silent failure).
    @State private var notifDenied = false

    enum WsTab: String, CaseIterable, Identifiable {
        case overview = "Overview", tasks = "Tasks", activity = "Activity"
        var id: String { rawValue }
    }

    private var ws: Workspace? {
        store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        guard let ws else {
            return AnyView(Text("Workspace not found.")
                .font(.caption).foregroundStyle(.secondary).padding())
        }
        return AnyView(
            VStack(spacing: 0) {
                header(ws)
                Picker("", selection: $tab) {
                    ForEach(WsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider().opacity(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch tab {
                        case .overview: overviewBody(ws)
                        case .tasks:
                            WorkspaceTasksView(workspaceID: ws.id, rootURL: rootURL,
                                               onRevealFile: onRevealFile)
                        case .activity: activityBody(ws)
                        }
                    }
                    .padding(10)
                }
            }
        )
    }

    // MARK: Header

    private func header(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(FFTheme.softGradient).frame(width: 34, height: 34)
                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    WorkspaceStatusLine(workspaceID: ws.id, rootURL: rootURL,
                                        onRevealFile: onRevealFile)
                }
                Spacer()
                // Visible Disable counterpart to the Enable prompt (§2):
                // once a workspace exists the preview becomes the project
                // overview, so turning it off must be one click — not hidden
                // in the ⋯ menu. Still asks for confirmation (data is removed,
                // files are not touched) and returns to the normal preview.
                Button("Disable") { showDisableConfirm = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Turn off Workspace for this folder and return to the normal file preview (tasks, reviews and dates are removed, files are kept).")
                Menu {
                    Button("Open in Main View") { onEnterFolder(rootURL) }
                    Button("Show in Finder") { NSWorkspace.shared.open(rootURL) }
                    Button("Rename…") {
                        renameDraft = ws.name
                        showRename = true
                    }
                    Divider()
                    Button("Disable Workspace…", role: .destructive) { showDisableConfirm = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            if !FileManager.default.fileExists(atPath: rootURL.path) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Text("Folder missing or moved — data kept, relink by moving it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // Command center (§2): the two actions people reach for, big
            // enough to hit without hunting — task (work with a status) and
            // reminder (exact-time Mac ping). One click each, always on top.
            HStack(spacing: 8) {
                WsCommandButton(icon: "checklist", title: "+ Task",
                                subtitle: "To-do · due · assignee") { showTaskSheet = true }
                WsCommandButton(icon: "bell.fill", title: "+ Reminder",
                                subtitle: "Exact time · Mac ping") { showReminderSheet = true }
            }
            // Secondary: file requests and sharing stay one click away too,
            // but quiet — the command center belongs to Task + Reminder.
            HStack(spacing: 12) {
                Button("Request File") { showRequestSheet = true }
                Button("Share") { SecureShareWindowManager.shared.open(rootURL) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(10)
        .sheet(isPresented: $showTaskSheet) {
            TaskEditSheet(workspaceID: ws.id, rootURL: rootURL)
        }
        .sheet(isPresented: $showReminderSheet) {
            ReminderSheet(workspaceID: ws.id)
        }
        .sheet(isPresented: $showRequestSheet) {
            FileRequestSheet(workspaceID: ws.id)
        }
        .sheet(isPresented: $showRename) {
            VStack(spacing: 12) {
                Text("Rename workspace").font(.headline)
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showRename = false }
                    Button("Rename") {
                        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        var next = ws; next.name = name
                        store.updateWorkspace(next, activity: "Renamed to \(name)")
                        showRename = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(width: 280)
        }
        .confirmationDialog("Disable Workspace?", isPresented: $showDisableConfirm) {
            Button("Disable Workspace", role: .destructive) {
                store.disableWorkspace(at: rootURL)
            }
        } message: {
            Text("Tasks, reviews, expiry dates and links for this folder will be removed. Files are not touched.")
        }
    }

    // MARK: Overview tab

    private func overviewBody(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // First-run hint, shown once and never again: a fresh workspace
            // is empty by design, so say what to do instead of showing blanks.
            if ws.tasks.isEmpty && ws.files.isEmpty && ws.fileRequests.isEmpty
                && ws.activity.count <= 1 {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    Text("Select a file on the left to attach tasks, reviews and dates to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FFTheme.cardShape.fill(Color.accentColor.opacity(0.07)))
            }
            let att = store.attention(for: ws)
            if !att.isEmpty {                WsCard(title: "Needs Attention", symbol: "exclamationmark.triangle.fill") {
                    if !att.overdueTasks.isEmpty {
                        WsCountRow(symbol: "clock.badge.exclamationmark", tint: .red,
                                   text: "\(att.overdueTasks.count) overdue task\(att.overdueTasks.count == 1 ? "" : "s")") {
                            tab = .tasks
                        }
                    }
                    ForEach(att.dueReminders) { rem in
                        WsCountRow(symbol: "bell.fill", tint: .orange,
                                   text: rem.isOverdue ? "Missed: \(rem.title)" : "Today: \(rem.title)") {}
                    }
                    ForEach(att.expiringFiles, id: \.relative) { rel, days in
                        WsCountRow(symbol: "hourglass", tint: .orange,
                                   text: "\(URL(fileURLWithPath: rel).lastPathComponent) expires in \(days) day\(days == 1 ? "" : "s")") {
                            onRevealFile(store.absoluteURL(relative: rel, in: rootURL))
                        }
                    }
                    if !att.pendingReviews.isEmpty {
                        WsCountRow(symbol: "eye", tint: .blue,
                                   text: "\(att.pendingReviews.count) review\(att.pendingReviews.count == 1 ? "" : "s") pending") {
                            tab = .tasks
                        }
                    }
                    ForEach(att.pendingRequests) { req in
                        WsCountRow(symbol: "tray.and.arrow.down", tint: .purple,
                                   text: "\(req.fileName) not received") {}
                    }
                }
            }
            // Next up (§3 example block)
            let upcoming = nextUp(ws)
            if !upcoming.isEmpty {
                WsCard(title: "Next", symbol: "calendar") {
                    ForEach(Array(upcoming.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(WorkspaceStore.dateString(entry.0))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 86, alignment: .leading)
                            Text(entry.1).font(.caption).lineLimit(1)
                        }
                    }
                }
            }
            // Pending file requests
            if !ws.pendingRequests.isEmpty {
                WsCard(title: "Requested Files", symbol: "tray.and.arrow.down") {
                    ForEach(ws.pendingRequests) { req in
                        HStack {
                            Text(req.fileName).font(.caption).lineLimit(1)
                            if let from = req.requestedFrom {
                                Text("· \(from)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Received") {
                                store.setFileRequestReceived(workspaceID: ws.id, requestID: req.id, received: true)
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            // Reminders (exact-time Mac notifications)
            let upcomingReminders = ws.reminders.filter { !$0.done }.sorted { $0.fireAt < $1.fireAt }
            if !upcomingReminders.isEmpty {
                WsCard(title: "Reminders", symbol: "bell") {
                    if notifDenied {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                            Text("Notifications are off — reminders won't ring.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Settings") { WorkspaceStore.openNotificationSettings() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    ForEach(upcomingReminders.prefix(5)) { rem in
                        reminderOverviewRow(rem, ws: ws)
                    }
                    if upcomingReminders.count > 5 {
                        Text("\(upcomingReminders.count - 5) more…")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            // Active share links (§3, §9)
            if sharesTotal != nil || sharesLoading {
                WsCard(title: "Active Share Links", symbol: "link") {
                    if sharesLoading, sharesTotal == nil {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading links…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let total = sharesTotal {
                        if total == 0 {
                            Text("No active links. Select a file → Share to create one.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(total) active link\(total == 1 ? "" : "s")")
                                .font(.caption).fontWeight(.semibold)
                            ForEach(sharesFiles, id: \.relative) { rel, count in
                                HStack {
                                    Button(URL(fileURLWithPath: rel).lastPathComponent) {
                                        onRevealFile(store.absoluteURL(relative: rel, in: rootURL))
                                    }
                                    .buttonStyle(.link).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Refresh") { loadShares() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            // Recently changed (§3)
            let recent = store.recentlyChanged(in: rootURL)
            if !recent.isEmpty {
                WsCard(title: "Recently Changed", symbol: "clock.arrow.circlepath") {
                    ForEach(recent, id: \.name) { name, date in
                        HStack {
                            Text(name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // Recent activity (§15)
            if !ws.activity.isEmpty {
                WsCard(title: "Recent Activity", symbol: "list.bullet") {
                    ForEach(ws.activity.prefix(8)) { ev in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ev.message).font(.caption).lineLimit(2)
                            Text(RelativeDateTimeFormatter().localizedString(for: ev.date, relativeTo: Date()))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    if ws.activity.count > 8 {
                        Button("See all in Activity") { tab = .activity }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .onAppear {
            // Requested files that appeared on disk count as received (§15).
            store.checkReceivedRequests(workspaceID: ws.id, root: rootURL)
            if sharesTotal == nil { loadShares() }
        }
        .task {
            if let s = await WorkspaceStore.notificationStatus() {
                notifDenied = (s == .denied)
            }
        }
    }

    /// Share summary is disk-heavy (bookmark resolution), so it loads once
    /// per overview appearance on a background queue — never per row.
    /// Old values stay visible while a manual refresh runs.
    private func loadShares() {
        let root = rootURL
        sharesLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = store.workspaceShareSummary(root: root)
            DispatchQueue.main.async {
                sharesLoading = false
                sharesTotal = summary.total
                sharesFiles = summary.files
            }
        }
    }

    private func reminderOverviewRow(_ rem: WorkspaceReminder, ws: Workspace) -> some View {
        HStack(spacing: 6) {
            Button {
                var next = rem; next.done.toggle()
                store.updateReminder(workspaceID: ws.id, next)
            } label: {
                Image(systemName: rem.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(rem.isOverdue ? .red : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 0) {
                Text(rem.title).font(.caption).lineLimit(1)
                HStack(spacing: 4) {
                    Text(Self.reminderTime.string(from: rem.fireAt))
                        .font(.system(size: 10))
                        .foregroundStyle(rem.isOverdue ? .red : .secondary)
                    if let f = rem.linkedFile {
                        Button(URL(fileURLWithPath: f).lastPathComponent) {
                            onRevealFile(store.absoluteURL(relative: f, in: rootURL))
                        }
                        .buttonStyle(.link).font(.system(size: 10))
                    }
                }
            }
            Spacer()
        }
    }

    private static var reminderTime: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    private func nextUp(_ ws: Workspace) -> [(Date, String)] {
        var rows: [(Date, String)] = []
        for t in ws.openTasks {
            if let d = t.dueDate { rows.append((d, t.title)) }
        }
        for r in ws.activeReminders {
            rows.append((r.fireAt, "Remind: \(r.title)"))
        }
        for (rel, meta) in ws.files {
            if let n = meta.review?.nextReviewDate {
                rows.append((n, "Review \(URL(fileURLWithPath: rel).lastPathComponent)"))
            }
            if let e = meta.validity?.expiresAt {
                rows.append((e, "Renew \(URL(fileURLWithPath: rel).lastPathComponent)"))
            }
        }
        if let dl = ws.deadline { rows.append((dl, "Workspace deadline")) }
        return rows.sorted { $0.0 < $1.0 }.prefix(4).map { $0 }
    }

    private func activityBody(_ ws: Workspace) -> some View {
        WsCard(title: "Activity", symbol: "list.bullet") {
            if ws.activity.isEmpty {
                Text("No activity yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ws.activity) { ev in
                VStack(alignment: .leading, spacing: 1) {
                    Text(ev.message).font(.caption)
                    Text("\(WorkspaceStore.dateString(ev.date))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Divider().opacity(0.4)
            }
        }
    }
}

// MARK: - Status / owner / deadline line (§3: custom statuses, owner memory, Mac notifications)

struct WorkspaceStatusLine: View {
    let workspaceID: String
    let rootURL: URL
    var onRevealFile: (URL) -> Void = { _ in }
    @ObservedObject var store = WorkspaceStore.shared
    @State private var showAddStatus = false
    @State private var newStatus = ""
    @State private var editingOwner = false
    @State private var ownerDraft = ""

    private var ws: Workspace? {
        store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        guard let ws else { return AnyView(EmptyView()) }
        let openCount = ws.openTasks.count
        // Requested + dated reviews due within 30 days (§3 "upcoming reviews").
        let reviewCount = store.upcomingReviews(for: ws).count
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Menu(ws.status) {
                        ForEach(allStatuses, id: \.self) { s in
                            Button(s) { setStatus(s, ws: ws) }
                        }
                        Divider()
                        Button("Add new status…") { showAddStatus = true }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("· \(openCount) open task\(openCount == 1 ? "" : "s") · \(reviewCount) upcoming review\(reviewCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if editingOwner {
                        TextField("Owner", text: $ownerDraft, onCommit: {
                            var next = ws; next.owner = ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerDraft
                            store.updateWorkspace(next, activity: "Owner set to \(next.owner ?? "—")")
                            editingOwner = false
                        })
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 120)
                    } else {
                        Button(ws.owner ?? "Set owner") {
                            ownerDraft = ws.owner ?? ""
                            editingOwner = true
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    if let dl = ws.deadline {
                        Text("· \(WorkspaceStore.dateString(dl))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Menu("Deadline") {
                        Button("Clear deadline") {
                            var next = ws; next.deadline = nil
                            store.updateWorkspace(next)
                        }
                        Button("In 7 days") { setDeadline(days: 7, ws: ws) }
                        Button("In 30 days") { setDeadline(days: 30, ws: ws) }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                }
            }
            .sheet(isPresented: $showAddStatus) {
                VStack(spacing: 12) {
                    Text("New status").font(.headline)
                    TextField("e.g. Waiting on client", text: $newStatus)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel") { showAddStatus = false }
                        Button("Add") {
                            let s = newStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !s.isEmpty else { return }
                            setStatus(s, ws: ws)
                            showAddStatus = false
                            newStatus = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(width: 280)
            }
        )
    }

    private var allStatuses: [String] {
        var seen = Set(Workspace.defaultStatuses)
        var out = Workspace.defaultStatuses
        for w in store.workspaces where !w.status.isEmpty && !seen.contains(w.status) {
            seen.insert(w.status); out.append(w.status)
        }
        return out
    }

    private func setStatus(_ s: String, ws: Workspace) {
        var next = ws; next.status = s
        store.updateWorkspace(next, activity: "Status → \(s)")
    }

    private func setDeadline(days: Int, ws: Workspace) {
        var next = ws
        next.deadline = Calendar.current.date(byAdding: .day, value: days, to: Date())
        store.updateWorkspace(next, activity: "Deadline set to \(WorkspaceStore.dateString(next.deadline ?? Date()))")
    }
}

// MARK: - Small card primitives

struct WsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FFTheme.cardShape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        .overlay(FFTheme.cardShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct WsCountRow: View {
    let symbol: String
    let tint: Color
    let text: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(text).font(.caption).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tasks (§4, §6, §14)

enum WsTaskFilter: String, CaseIterable, Identifiable {
    case all = "All", mine = "Mine", dueSoon = "Due Soon", waiting = "Waiting", completed = "Completed"
    var id: String { rawValue }
}

struct WorkspaceTasksView: View {
    let workspaceID: String
    let rootURL: URL
    var fileRelative: String? = nil // nil = whole project (§14)
    var onRevealFile: (URL) -> Void = { _ in }
    @ObservedObject var store = WorkspaceStore.shared

    @State private var filter: WsTaskFilter = .all
    @State private var showAdd = false
    @State private var showAddReminder = false

    private var ws: Workspace? {
        store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        guard let ws else { return AnyView(EmptyView()) }
        var scoped = ws.tasks
        if let rel = fileRelative { scoped = scoped.filter { $0.linkedFile == rel } }
        let shown = applyFilter(scoped)
        let today = shown.filter { $0.status.isOpen && ($0.isOverdue || $0.isDueToday) }
        let upcoming = shown.filter { $0.status.isOpen && !$0.isOverdue && !$0.isDueToday && $0.dueDate != nil }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let nodate = shown.filter { $0.status.isOpen && $0.dueDate == nil && !$0.isOverdue }
        let done = shown.filter { !$0.status.isOpen }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("", selection: $filter) {
                        ForEach(WsTaskFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    Spacer()
                    Button("+ Add task") { showAdd = true }
                        .buttonStyle(.link).font(.caption)
                }
                if shown.isEmpty {
                    Text(fileRelative == nil ? "No tasks. Add the first one above." : "No tasks for this file yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !today.isEmpty {
                    Text("TODAY").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(today) { taskRow($0, ws: ws) }
                }
                if !upcoming.isEmpty {
                    Text("UPCOMING").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(upcoming) { taskRow($0, ws: ws) }
                }
                if !nodate.isEmpty {
                    Text("NO DATE").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(nodate) { taskRow($0, ws: ws) }
                }
                if !done.isEmpty && (filter == .all || filter == .completed) {
                    Text("COMPLETED").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(done) { taskRow($0, ws: ws) }
                }
                // Reminders live with tasks: one "work around this file" list.
                // The header always shows — otherwise reminders on a file
                // are invisible until the first one exists.
                let fileReminders = fileRelative.map { ws.remindersForFile(relative: $0) }
                    ?? ws.reminders.sorted { $0.fireAt < $1.fireAt }
                let activeRem = fileReminders.filter { !$0.done }
                let doneRem = fileReminders.filter(\.done)
                HStack {
                    Text("REMINDERS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("+ Add reminder") { showAddReminder = true }
                        .buttonStyle(.link).font(.caption)
                }
                ForEach(activeRem) { reminderRow($0, ws: ws) }
                if !doneRem.isEmpty && (filter == .all || filter == .completed) {
                    ForEach(doneRem) { reminderRow($0, ws: ws) }
                }
                if activeRem.isEmpty && doneRem.isEmpty {
                    Text("No reminders. Pin one to this \(fileRelative == nil ? "project" : "file") and macOS will notify you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showAdd) {
                TaskEditSheet(workspaceID: ws.id, rootURL: rootURL, linkedFile: fileRelative)
            }
            .sheet(isPresented: $showAddReminder) {
                ReminderSheet(workspaceID: ws.id, linkedFile: fileRelative)
            }
        )
    }

    private func applyFilter(_ tasks: [WorkspaceTask]) -> [WorkspaceTask] {
        switch filter {
        case .all: return tasks
        case .mine:
            let me = NSFullUserName().lowercased()
            return tasks.filter { ($0.assignee ?? "").lowercased() == me || ($0.assignee ?? "").lowercased() == NSUserName().lowercased() }
        case .dueSoon:
            let soon = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            return tasks.filter { $0.status.isOpen && ($0.isOverdue || ($0.dueDate ?? .distantFuture) <= soon) }
        case .waiting: return tasks.filter { $0.status == .waiting }
        case .completed: return tasks.filter { !$0.status.isOpen }
        }
    }

    private func taskRow(_ t: WorkspaceTask, ws: Workspace) -> some View {
        let linkedURL = t.linkedFile.map { store.absoluteURL(relative: $0, in: rootURL) }
        return TaskRow(task: t, showFile: fileRelative == nil,
                       linkedURL: linkedURL, rootURL: rootURL) {
            var next = t
            next.status = t.status == .done ? .todo : .done
            store.updateTask(workspaceID: ws.id, next)
        } onReveal: {
            if let url = linkedURL { onRevealFile(url) }
        } onDelete: {
            store.deleteTask(workspaceID: ws.id, taskID: t.id)
        } onEdit: { edited in
            store.updateTask(workspaceID: ws.id, edited)
        }
    }

    private func reminderRow(_ r: WorkspaceReminder, ws: Workspace) -> some View {
        let linkedURL = r.linkedFile.map { store.absoluteURL(relative: $0, in: rootURL) }
        return ReminderRow(reminder: r, showFile: fileRelative == nil,
                           linkedURL: linkedURL) {
            var next = r
            next.done.toggle()
            store.updateReminder(workspaceID: ws.id, next)
        } onReveal: {
            if let url = linkedURL { onRevealFile(url) }
        } onDelete: {
            store.deleteReminder(workspaceID: ws.id, reminderID: r.id)
        } onEdit: { edited in
            store.updateReminder(workspaceID: ws.id, edited)
        }
    }
}

struct TaskRow: View {
    let task: WorkspaceTask
    var showFile: Bool = true
    /// Absolute URL of the linked file (parent resolves it from the
    /// workspace root). Enables reveal + open straight from the row.
    var linkedURL: URL? = nil
    /// Workspace root for the attach picker in the edit sheet.
    var rootURL: URL? = nil
    var onToggle: () -> Void
    var onReveal: () -> Void = {}
    var onDelete: () -> Void = {}
    var onEdit: (WorkspaceTask) -> Void = { _ in }
    @State private var showEdit = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : task.status.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(task.status == .done ? .green : task.isOverdue ? .red : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(task.title)
                        .font(.caption)
                        .strikethrough(task.status == .done)
                        .foregroundStyle(task.status == .done ? .secondary : .primary)
                        .lineLimit(2)
                    if task.priority == .urgent || task.priority == .high {
                        Text(task.priority.title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(task.priority == .urgent ? .red : .orange)
                    }
                }
                HStack(spacing: 5) {
                    if let a = task.assignee, !a.isEmpty {
                        Text(a).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let d = task.dueDate {
                        Text(WorkspaceStore.dateString(d))
                            .font(.system(size: 10))
                            .foregroundStyle(task.isOverdue ? .red : .secondary)
                    }
                    if showFile, let f = task.linkedFile {
                        Button(URL(fileURLWithPath: f).lastPathComponent) { onReveal() }
                            .buttonStyle(.link).font(.system(size: 10))
                            .help("Show in file browser — Open File is in the ⋯ menu")
                    }
                    if task.status == .waiting {
                        Text("· waiting").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            // The checkbox already toggles done — the menu stays minimal.
            Menu {
                Button("Edit…") { showEdit = true }
                if let url = linkedURL {
                    Button("Open File") { NSWorkspace.shared.open(url) }
                }
                Button("Delete", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .sheet(isPresented: $showEdit) {
            TaskEditSheet(rootURL: rootURL, editing: task, onSave: onEdit)
        }
    }
}

// MARK: - Task editor sheet

struct TaskEditSheet: View {
    var workspaceID: String? = nil
    var rootURL: URL? = nil
    var linkedFile: String? = nil
    var editing: WorkspaceTask? = nil
    var onSave: ((WorkspaceTask) -> Void)? = nil
    @ObservedObject var store = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var assignee = ""
    @State private var priority: WorkspacePriority = .normal
    @State private var status: WorkspaceTaskStatus = .todo
    @State private var notes = ""
    /// Attached document (relative to the workspace root). Prefilled when
    /// the sheet opens for a file; changeable via the picker.
    @State private var fileDraft: String? = nil
    @State private var fileLoaded = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil ? (linkedFile == nil ? "New task" : "New task for \(URL(fileURLWithPath: linkedFile ?? "").lastPathComponent)") : "Edit task")
                .font(.headline)
            TextField("Title (e.g. Review Agreement.pdf)", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            Toggle("Due date", isOn: $hasDue)
                .font(.caption)
            if hasDue {
                DatePicker("", selection: $due, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
            TextField("Assignee (optional)", text: $assignee)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            HStack {
                Picker("Priority", selection: $priority) {
                    ForEach(WorkspacePriority.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).font(.caption)
                Picker("Status", selection: $status) {
                    ForEach(WorkspaceTaskStatus.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).font(.caption)
            }
            TextField("Notes (optional)", text: $notes)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            // Attach a document: the task then shows on the file too (§6).
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let f = fileDraft {
                    Text(URL(fileURLWithPath: f).lastPathComponent)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        fileDraft = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove attached file")
                } else {
                    Button("Attach file…") { pickFile() }
                        .buttonStyle(.link).font(.caption)
                        .disabled(rootURL == nil)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            if !fileLoaded {
                fileLoaded = true
                // Editing keeps its link; a fresh sheet takes the file it
                // was opened for (quick capture, file panel "+").
                fileDraft = editing?.linkedFile ?? linkedFile
            }
            if let e = editing {
                title = e.title; hasDue = e.dueDate != nil; due = e.dueDate ?? Date()
                assignee = e.assignee ?? ""; priority = e.priority; status = e.status
                notes = e.notes ?? ""
            }
            // Keyboard-first: the title field takes focus so typing starts
            // immediately (the sheet exists to capture a thought fast).
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    /// Attach picker je tvoj attacher (Recent/Downloads/Favorites/Search/
    /// Preview), ne sistemski Open panel. Linkovi moraju biti unutar
    /// workspace roota (cuvaju se relativno) — izbor napolju se odbija.
    private func pickFile() {
        guard let root = rootURL else { return }
        MailAttachWindowManager.shared.openForPick(
            title: "Choose the document for this task",
            allowsMultiple: false,
            initialDirectory: root
        ) { urls in
            guard let picked = urls.first else { return }
            if let rel = store.relativePath(of: picked, to: root), !rel.isEmpty {
                fileDraft = rel
            } else {
                NSSound.beep()
            }
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = editing {
            var next = e
            next.title = t; next.dueDate = hasDue ? due : nil
            next.assignee = assignee.trimmingCharacters(in: .whitespaces).isEmpty ? nil : assignee
            next.priority = priority; next.status = status
            next.notes = notes.isEmpty ? nil : notes
            next.linkedFile = fileDraft
            onSave?(next)
        } else if let wid = workspaceID {
            let task = WorkspaceTask(title: t, dueDate: hasDue ? due : nil,
                                      assignee: assignee.trimmingCharacters(in: .whitespaces).isEmpty ? nil : assignee,
                                      priority: priority, status: status,
                                      linkedFile: fileDraft,
                                      notes: notes.isEmpty ? nil : notes)
            store.addTask(to: wid, task)
        }
        dismiss()
    }
}

// MARK: - Reminders (exact-time Mac notification, optional document link)

struct ReminderRow: View {
    let reminder: WorkspaceReminder
    var showFile: Bool = true
    /// Absolute URL of the linked document, for reveal + open from the row.
    var linkedURL: URL? = nil
    var onToggle: () -> Void
    var onReveal: () -> Void = {}
    var onDelete: () -> Void = {}
    var onEdit: (WorkspaceReminder) -> Void = { _ in }
    @State private var showEdit = false

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) {
                Image(systemName: reminder.done ? "checkmark.circle.fill"
                                    : reminder.isOverdue ? "bell.badge.fill" : "bell")
                    .font(.system(size: 14))
                    .foregroundStyle(reminder.done ? .green : reminder.isOverdue ? .red : .orange)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .font(.caption)
                    .strikethrough(reminder.done)
                    .foregroundStyle(reminder.done ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(Self.timeFormatter.string(from: reminder.fireAt))
                        .font(.system(size: 10))
                        .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                    if showFile, let f = reminder.linkedFile {
                        Button(URL(fileURLWithPath: f).lastPathComponent) { onReveal() }
                            .buttonStyle(.link).font(.system(size: 10))
                            .help("Show in file browser — Open File is in the ⋯ menu")
                    }
                }
            }
            Spacer()
            Menu {
                Button("Edit…") { showEdit = true }
                if let url = linkedURL {
                    Button("Open File") { NSWorkspace.shared.open(url) }
                }
                Button("Delete", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
        .sheet(isPresented: $showEdit) {
            ReminderSheet(editing: reminder, onSave: onEdit)
        }
    }
}

struct ReminderSheet: View {
    var workspaceID: String? = nil
    var linkedFile: String? = nil
    var editing: WorkspaceReminder? = nil
    var onSave: ((WorkspaceReminder) -> Void)? = nil
    @ObservedObject var store = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var fireAt = Date().addingTimeInterval(3600)
    @State private var notes = ""
    /// Mac notification permission, checked at the point of need: the sheet
    /// is where the user asks for a notification, so a missing permission
    /// is explained here instead of failing silently later.
    @State private var notifStatus: UNAuthorizationStatus? = nil
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil
                 ? (linkedFile == nil ? "New reminder" : "Reminder for \(URL(fileURLWithPath: linkedFile ?? "").lastPathComponent)")
                 : "Edit reminder")
                .font(.headline)
            TextField("Title (e.g. Renew the certificate)", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
            // Date AND time: a reminder fires at the exact minute (§3),
            // unlike a task due date which lands at 9:00.
            DatePicker("Remind me", selection: $fireAt)
                .font(.caption)
            TextField("Notes (optional)", text: $notes)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            Text("macOS shows a notification at this time, even in the background.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if notifStatus == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Text("Notifications are off — reminders won't ring.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { WorkspaceStore.openNotificationSettings() }
                        .buttonStyle(.link).font(.system(size: 10))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            if let e = editing {
                title = e.title; fireAt = e.fireAt; notes = e.notes ?? ""
            }
            DispatchQueue.main.async { titleFocused = true }
        }
        .task {
            // Ask at the point of need (first time only — the OS prompts
            // once ever), then remember the answer for the warning above.
            notifStatus = await WorkspaceStore.ensureNotificationAuth()
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = editing {
            var next = e
            next.title = t; next.fireAt = fireAt
            next.notes = notes.isEmpty ? nil : notes
            onSave?(next)
        } else if let wid = workspaceID {
            store.addReminder(to: wid, WorkspaceReminder(
                title: t, fireAt: fireAt, linkedFile: linkedFile,
                notes: notes.isEmpty ? nil : notes))
        }
        dismiss()
    }
}

// MARK: - File request sheet (§2)

struct FileRequestSheet: View {
    let workspaceID: String
    @ObservedObject var store = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var fileName = ""
    @State private var from = ""
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Request file").font(.headline)
            TextField("File name (e.g. Signed NDA.pdf)", text: $fileName)
                .textFieldStyle(.roundedBorder)
            TextField("Requested from (optional)", text: $from)
                .textFieldStyle(.roundedBorder).font(.caption)
            Toggle("Due date", isOn: $hasDue).font(.caption)
            if hasDue {
                DatePicker("", selection: $due, displayedComponents: .date)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Request") {
                    store.addFileRequest(workspaceID: workspaceID,
                        WorkspaceFileRequest(fileName: fileName.trimmingCharacters(in: .whitespacesAndNewlines),
                                              requestedFrom: from.isEmpty ? nil : from,
                                              dueDate: hasDue ? due : nil))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - File panel (§5–§11)

enum WsFileTab: String, CaseIterable, Identifiable {
    case details = "Details", tasks = "Tasks", review = "Review", share = "Share", relations = "Relations"
    case versions = "Versions"
    var id: String { rawValue }
}

struct WorkspaceFilePanel: View {
    let workspaceID: String
    let rootURL: URL
    let fileURL: URL
    let relative: String
    var onRevealFile: (URL) -> Void = { _ in }
    @ObservedObject var store = WorkspaceStore.shared
    @State private var tab: WsFileTab = .details
    @State private var showTaskSheet = false

    private var ws: Workspace? {
        store.workspaces.first { $0.id == workspaceID }
    }

    var body: some View {
        guard ws != nil else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(spacing: 0) {
                // One row instead of an action bar stacked on a tab bar (§5+§12):
                // the tabs ARE the one-click actions, "+" adds a task anywhere.
                HStack(spacing: 2) {
                    ForEach(WsFileTab.allCases) { t in
                        WsTabButton(label: t.rawValue, selected: tab == t) { tab = t }
                    }
                    Spacer(minLength: 2)
                    Button {
                        showTaskSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add task for this file")
                    .padding(.trailing, 2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider().opacity(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch tab {
                        case .details:
                            WsFileDetailsTab(workspaceID: workspaceID, rootURL: rootURL,
                                             fileURL: fileURL, relative: relative)
                        case .tasks:
                            WorkspaceTasksView(workspaceID: workspaceID, rootURL: rootURL,
                                               fileRelative: relative, onRevealFile: onRevealFile)
                        case .review:
                            WsFileReviewTab(workspaceID: workspaceID, relative: relative)
                        case .share:
                            WsFileShareTab(fileURL: fileURL)
                        case .relations:
                            WsFileRelationsTab(workspaceID: workspaceID, rootURL: rootURL,
                                               relative: relative, onRevealFile: onRevealFile)
                        case .versions:
                            VersionPanel(url: fileURL)
                        }
                    }
                    .padding(10)
                }
            }
            .sheet(isPresented: $showTaskSheet) {
                TaskEditSheet(workspaceID: workspaceID, rootURL: rootURL, linkedFile: relative)
            }
        )
    }
}

/// Command-center button: icon + title + one-line subtitle in a card.
/// Big enough to find instantly, calm enough to live at the top.
struct WsCommandButton: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FFTheme.cardShape
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                FFTheme.cardShape
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(title) — \(subtitle)")
    }
}

/// One compact tab button: pill highlight when selected, plain label
/// otherwise. Fits five tabs + a "+" in a 260pt panel where a segmented
/// control would clip ("Relatio…").
struct WsTabButton: View {
    let label: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: Details tab: validity (§8) + note (§11)

struct WsFileDetailsTab: View {
    let workspaceID: String
    let rootURL: URL
    let fileURL: URL
    let relative: String
    @ObservedObject var store = WorkspaceStore.shared

    @State private var noteDraft = ""
    @State private var noteLoadedFor = ""
    @State private var fileInfo: FileItem? = nil
    @State private var showExpiryPicker = false

    private var meta: WorkspaceFileMeta? {
        store.meta(workspaceID: workspaceID, relative: relative)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The context the old info card provided (name/kind/size/dates)
            // stays visible — workspace tabs add work, they don't remove info.
            if let info = fileInfo {
                WsCard(title: "File", symbol: "doc") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name)
                            .font(.caption).fontWeight(.medium).lineLimit(2)
                        Text("\(info.kind) · \(info.formattedSize) · \(info.formattedDateModified)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            // Validity
            WsCard(title: "Validity", symbol: "hourglass") {
                validityBody
            }
            // Note
            WsCard(title: "Note", symbol: "note.text") {
                TextEditor(text: $noteDraft)
                    .font(.caption)
                    .frame(minHeight: 60, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                HStack {
                    if let updated = meta?.noteUpdatedAt, !(meta?.note ?? "").isEmpty {
                        Text("Last edited \(WorkspaceStore.dateString(updated))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if noteDraft != (meta?.note ?? "") {
                        Button("Save note") {
                            store.mutateMeta(workspaceID: workspaceID, relative: relative,
                                             activity: "Note updated on \(URL(fileURLWithPath: relative).lastPathComponent)") {
                                $0.note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : noteDraft
                                $0.noteUpdatedAt = Date()
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .onAppear {
            if noteLoadedFor != relative {
                noteDraft = meta?.note ?? ""
                noteLoadedFor = relative
            }
            fileInfo = FileItem.load(from: fileURL)
        }
        .onChange(of: relative) { _, _ in
            noteDraft = store.meta(workspaceID: workspaceID, relative: relative)?.note ?? ""
            noteLoadedFor = relative
            fileInfo = FileItem.load(from: fileURL)
            showExpiryPicker = false
        }
    }

    /// Progressive disclosure: the common case (a date + Renew) is one row;
    /// pickers, replace and opt-out live behind "Options" / one tap.
    @ViewBuilder
    private var validityBody: some View {
        let v = meta?.validity
        if v?.noLongerRequired == true {
            HStack {
                Text("No longer required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Re-enable") {
                    store.mutateMeta(workspaceID: workspaceID, relative: relative,
                                     activity: "Validity re-enabled for \(URL(fileURLWithPath: relative).lastPathComponent)") {
                        $0.validity?.noLongerRequired = false
                    }
                }.buttonStyle(.link).font(.caption)
            }
        } else if let exp = v?.expiresAt {
            let days = v?.daysUntil() ?? 0
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expires \(WorkspaceStore.dateString(exp))")
                        .font(.caption).fontWeight(.medium)
                    Text(days < 0 ? "Expired \(abs(days)) days ago" : "In \(days) day\(days == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(days <= 7 ? .red : .secondary)
                }
                Spacer()
                Button("Renew +1y") { renew() }
                    .buttonStyle(.link).font(.caption)
            }
            DisclosureGroup("Options") {
                VStack(alignment: .leading, spacing: 6) {
                    DatePicker("Expiry date", selection: Binding(
                        get: { v?.expiresAt ?? Date() },
                        set: { setExpiry($0) }
                    ), displayedComponents: .date)
                    .font(.caption)
                    remindRow(v)
                    HStack {
                        Button("Replace with new version…") { replaceWithNewVersion() }
                            .buttonStyle(.link).font(.caption)
                        Spacer()
                        Button("No longer required") {
                            store.mutateMeta(workspaceID: workspaceID, relative: relative,
                                             activity: "Marked no longer required: \(URL(fileURLWithPath: relative).lastPathComponent)") {
                                $0.validity?.noLongerRequired = true
                            }
                        }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        } else if showExpiryPicker {
            DatePicker("Expiry date", selection: Binding(
                get: { Date() },
                set: { setExpiry($0); showExpiryPicker = false }
            ), displayedComponents: .date)
            .font(.caption)
            Text("aiFlow reminds you before it expires.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            Button("Set expiry date…") { showExpiryPicker = true }
                .buttonStyle(.link).font(.caption)
                .help("Contracts, licences, certificates, insurance, permits…")
        }
    }

    @ViewBuilder
    private func remindRow(_ v: WorkspaceFileValidity?) -> some View {
        let days = v?.remindDaysBefore ?? [30, 7, 1]
        HStack(spacing: 6) {
            Text("Remind:").font(.caption).foregroundStyle(.secondary)
            ForEach([30, 7, 1], id: \.self) { d in
                Toggle("\(d)d", isOn: Binding(
                    get: { days.contains(d) },
                    set: { on in
                        store.mutateMeta(workspaceID: workspaceID, relative: relative, activity: nil) {
                            var cur = Set($0.validity?.remindDaysBefore ?? [30, 7, 1])
                            if on { cur.insert(d) } else { cur.remove(d) }
                            if $0.validity == nil { $0.validity = WorkspaceFileValidity() }
                            $0.validity?.remindDaysBefore = cur.sorted()
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }

    private func setExpiry(_ date: Date) {
        store.mutateMeta(workspaceID: workspaceID, relative: relative,
                         activity: "Expiry set for \(URL(fileURLWithPath: relative).lastPathComponent): \(WorkspaceStore.dateString(date))") {
            if $0.validity == nil { $0.validity = WorkspaceFileValidity() }
            $0.validity?.expiresAt = date
            $0.validity?.noLongerRequired = false
        }
    }

    private func renew() {
        let base = max(meta?.validity?.expiresAt ?? Date(), Date())
        let next = Calendar.current.date(byAdding: .year, value: 1, to: base) ?? base
        store.mutateMeta(workspaceID: workspaceID, relative: relative,
                         activity: "Renewed \(URL(fileURLWithPath: relative).lastPathComponent) until \(WorkspaceStore.dateString(next))") {
            if $0.validity == nil { $0.validity = WorkspaceFileValidity() }
            $0.validity?.expiresAt = next
            $0.validity?.noLongerRequired = false
        }
    }

    /// Safe replace: current file is kept as `Name (previous).ext`, the
    /// picked file is copied over it, and the event is logged.
    /// Fajl se bira kroz tvoj attacher (pocetni folder je workspace root,
    /// moze se otici bilo gde — kopija ne mora biti unutra).
    private func replaceWithNewVersion() {
        MailAttachWindowManager.shared.openForPick(
            title: "Choose the new version of \(fileURL.lastPathComponent)",
            allowsMultiple: false,
            initialDirectory: rootURL
        ) { urls in
            guard let picked = urls.first else { return }
            replaceWithPickedVersion(picked)
        }
    }

    private func replaceWithPickedVersion(_ picked: URL) {
        let ext = fileURL.pathExtension
        let base = fileURL.deletingPathExtension().lastPathComponent
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? "\(base) (previous)" : "\(base) (previous).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: fileURL, to: backup)
            try FileManager.default.removeItem(at: fileURL)
            try FileManager.default.copyItem(at: picked, to: fileURL)
            store.mutateMeta(workspaceID: workspaceID, relative: relative,
                              activity: "Replaced with new version: \(URL(fileURLWithPath: relative).lastPathComponent)",
                              { _ in })
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: Review tab (§7)

struct WsFileReviewTab: View {
    let workspaceID: String
    let relative: String
    @ObservedObject var store = WorkspaceStore.shared

    @State private var reviewer = ""
    @State private var comment = ""
    @State private var hasNext = false
    @State private var nextDate = Date()

    private var review: WorkspaceFileReview? {
        store.meta(workspaceID: workspaceID, relative: relative)?.review
    }

    var body: some View {
        WsCard(title: "Review", symbol: "eye") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Status", selection: Binding(
                    get: { review?.status ?? .draft },
                    set: { setStatus($0) }
                )) {
                    ForEach(WorkspaceReviewStatus.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .font(.caption)
                if let r = review {
                    if let by = r.reviewer {
                        Text("Reviewed by \(by)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = r.reviewDate {
                        Text("Reviewed \(WorkspaceStore.dateString(d))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let n = r.nextReviewDate {
                        Text("Next review \(WorkspaceStore.dateString(n))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No review yet — status is Draft.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Reviewer", text: $reviewer)
                    .textFieldStyle(.roundedBorder).font(.caption)
                TextField("Comment (optional)", text: $comment)
                    .textFieldStyle(.roundedBorder).font(.caption)
                Toggle("Next review date", isOn: $hasNext).font(.caption)
                if hasNext {
                    DatePicker("", selection: $nextDate, displayedComponents: .date)
                }
                HStack(spacing: 12) {
                    Button("Mark Reviewed") { markReviewed() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Request Review") { setStatus(.review) }
                        .buttonStyle(.link).font(.caption)
                        .disabled(review?.status == .review)
                    Spacer()
                }
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: relative) { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        reviewer = review?.reviewer ?? ""
        comment = review?.comment ?? ""
        hasNext = review?.nextReviewDate != nil
        nextDate = review?.nextReviewDate ?? Date()
    }

    private func setStatus(_ s: WorkspaceReviewStatus) {
        let name = URL(fileURLWithPath: relative).lastPathComponent
        let wasReview = review?.status == .review
        store.mutateMeta(workspaceID: workspaceID, relative: relative,
                         activity: s == .review ? "Review requested for \(name)" : "\(name): \(s.title)") {
            if $0.review == nil { $0.review = WorkspaceFileReview() }
            $0.review?.status = s
            if !reviewer.trimmingCharacters(in: .whitespaces).isEmpty { $0.review?.reviewer = reviewer }
            if !comment.trimmingCharacters(in: .whitespaces).isEmpty { $0.review?.comment = comment }
            $0.review?.nextReviewDate = hasNext ? nextDate : nil
        }
        // A fresh review request becomes a real task for the reviewer (§4+§7
        // stay one system: the work shows both on the file and in Tasks).
        if s == .review, !wasReview {
            let who = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
            store.addTask(to: workspaceID, WorkspaceTask(
                title: "Review \(name)",
                dueDate: hasNext ? nextDate : nil,
                assignee: who.isEmpty ? nil : who,
                linkedFile: relative))
        }
    }

    private func markReviewed() {
        let who = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(fileURLWithPath: relative).lastPathComponent
        store.mutateMeta(workspaceID: workspaceID, relative: relative,
                         activity: "\(who.isEmpty ? "Someone" : who) reviewed \(name)") {
            if $0.review == nil { $0.review = WorkspaceFileReview() }
            $0.review?.status = .approved
            $0.review?.reviewer = who.isEmpty ? nil : who
            $0.review?.reviewDate = Date()
            if !comment.trimmingCharacters(in: .whitespaces).isEmpty { $0.review?.comment = comment }
            $0.review?.nextReviewDate = hasNext ? nextDate : nil
        }
    }
}

// MARK: Share tab (§9 — read integration with SecureShare)

struct WsFileShareTab: View {
    let fileURL: URL
    @ObservedObject var store = WorkspaceStore.shared
    @ObservedObject var shareManager = SecureShareManager.shared
    @State private var shares: [SecureShareRecord]? = nil
    @State private var loadedFor = ""

    var body: some View {
        WsCard(title: "Sharing", symbol: "link") {
            VStack(alignment: .leading, spacing: 8) {
                if let shares {
                    if shares.isEmpty {
                        Text("No active links for this file.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Active links: \(shares.count)")
                            .font(.caption).fontWeight(.semibold)
                        ForEach(shares) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.filename).font(.caption).fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    Button("Copy") {
                                        Task { await shareManager.copyLink(r) }
                                    }.buttonStyle(.link).font(.caption)
                                    Button("Disable") {
                                        Task {
                                            await shareManager.revoke(r)
                                            refresh()
                                        }
                                    }.buttonStyle(.link).font(.caption)
                                }
                                HStack(spacing: 6) {
                                    if let exp = r.expiresAt {
                                        Text("Expires \(WorkspaceStore.dateString(Date(timeIntervalSince1970: exp / 1000)))")
                                    } else {
                                        Text("No expiry")
                                    }
                                    if !r.allowPreview { Text("· download only") }
                                }
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Divider().opacity(0.4)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading links…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button("Create Share Link") {
                        SecureShareWindowManager.shared.open(fileURL)
                    }
                    .buttonStyle(.link).font(.caption)
                    Button("Extend…") {
                        // Expiry editing lives in the share window (§9 Extend).
                        SecureShareWindowManager.shared.open(fileURL)
                    }
                    .buttonStyle(.link).font(.caption)
                    .help("Change link expiry in the share window")
                    Button("Manage all") {
                        SecureShareWindowManager.shared.open()
                    }
                    .buttonStyle(.link).font(.caption)
                }
                if let msg = shareManager.message, !msg.isEmpty {
                    Text(msg).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: fileURL.path) { _, _ in reload() }
    }

    private func reload() {
        guard loadedFor != fileURL.path else { return }
        loadedFor = fileURL.path
        shares = nil
        let url = fileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let found = store.activeShares(for: url)
            DispatchQueue.main.async {
                // Stale guard: selection moved while resolving bookmarks.
                guard loadedFor == url.path else { return }
                shares = found
            }
        }
    }

    /// Reload after a local change (revoke): bypasses the appear-guard so
    /// the list reflects what just happened instead of going stale.
    private func refresh() {
        loadedFor = ""
        reload()
    }
}

// MARK: Relations tab (§10)

struct WsFileRelationsTab: View {
    let workspaceID: String
    let rootURL: URL
    let relative: String
    var onRevealFile: (URL) -> Void = { _ in }
    @ObservedObject var store = WorkspaceStore.shared
    @State private var showKindPicker = false
    @State private var pendingTarget = ""
    @State private var pendingKind: WorkspaceRelationKind = .related

    private var relations: [WorkspaceRelation] {
        store.meta(workspaceID: workspaceID, relative: relative)?.relations ?? []
    }

    var body: some View {
        WsCard(title: "Connected Documents", symbol: "arrow.2.squarepath") {
            VStack(alignment: .leading, spacing: 6) {
                if relations.isEmpty {
                    Text("Not connected to anything yet. Link proposals, previous versions, signed copies…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(relations) { rel in
                    HStack(spacing: 6) {
                        Button(URL(fileURLWithPath: rel.target).lastPathComponent) {
                            onRevealFile(store.absoluteURL(relative: rel.target, in: rootURL))
                        }
                        .buttonStyle(.link).font(.caption).lineLimit(1)
                        Spacer()
                        Text("↳ \(rel.kind.title)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Button {
                            store.mutateMeta(workspaceID: workspaceID, relative: relative,
                                             activity: "Unlinked \(URL(fileURLWithPath: rel.target).lastPathComponent)") {
                                $0.relations.removeAll { $0.id == rel.id }
                            }
                        } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("+ Connect document…") { pickDocument() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .sheet(isPresented: $showKindPicker) {
            VStack(spacing: 12) {
                Text("Connect \(URL(fileURLWithPath: pendingTarget).lastPathComponent)").font(.headline)
                Picker("Relation", selection: $pendingKind) {
                    ForEach(WorkspaceRelationKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                HStack {
                    Button("Cancel") { showKindPicker = false }
                    Button("Connect") {
                        let target = pendingTarget
                        let kind = pendingKind
                        store.mutateMeta(workspaceID: workspaceID, relative: relative,
                                         activity: "Linked \(URL(fileURLWithPath: target).lastPathComponent) (\(kind.title.lowercased()))") {
                            guard !$0.relations.contains(where: { $0.target == target }) else { return }
                            $0.relations.append(WorkspaceRelation(target: target, kind: kind))
                        }
                        showKindPicker = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    /// Dokumenti se biraju kroz tvoj attacher (vise odjednom). Samo fajlovi
    /// unutar workspace roota mogu da se povezu (cuvaju se relativno).
    private func pickDocument() {
        MailAttachWindowManager.shared.openForPick(
            title: "Choose document(s) to connect with \(URL(fileURLWithPath: relative).lastPathComponent)",
            allowsMultiple: true,
            initialDirectory: rootURL
        ) { urls in
            var targets: [String] = []
            for url in urls {
                guard let rel = store.relativePath(of: url, to: rootURL), !rel.isEmpty, rel != relative else { continue }
                targets.append(rel)
            }
            guard let first = targets.first else { return }
            if targets.count == 1 {
                pendingTarget = first
                pendingKind = .related
                showKindPicker = true
            } else {
                store.mutateMeta(workspaceID: workspaceID, relative: relative,
                                  activity: "Linked \(targets.count) documents") {
                    for t in targets where !$0.relations.contains(where: { $0.target == t }) {
                        $0.relations.append(WorkspaceRelation(target: t))
                    }
                }
            }
        }
    }
}

// MARK: - Subfolder banner (folder inside a workspace, not the root)

struct WorkspaceSubfolderBanner: View {
    let workspaceID: String
    let rootURL: URL
    var onGoToWorkspace: () -> Void = {}
    @ObservedObject var store = WorkspaceStore.shared

    var body: some View {
        if let ws = store.workspaces.first(where: { $0.id == workspaceID }) {
            HStack(spacing: 6) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Text(ws.name).font(.caption).fontWeight(.medium).lineLimit(1)
                Text("· \(ws.openTasks.count) open")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Workspace") { onGoToWorkspace() }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        }
    }
}
