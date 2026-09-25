import Foundation
import Combine
import UserNotifications
import AppKit
import os

// MARK: - WorkspaceStore (PRD §17 MVP: model 1–11 without chat/kanban/calendar)
//
// Local JSON persistence under Application Support/FinderFlow/Workspaces,
// following the MailStore pattern:
// - `FF_WORKSPACE_DIR` env override keeps tests/harness out of the user's
//   real store (same idea as FF_MAIL_DIR / FF_FOLDER_RULES_DIR / FF_ESIGN_DIR).
// - File references are relative to the workspace root.
// - Every mutation bumps `version` so badge-carrying rows (GroupedRow,
//   IconCell) repaint without hashing the folder.
// - macOS notifications (PRD §3: "NOTIFIKACIJE NA MACU") are scheduled via
//   UNUserNotificationCenter for: task due dates, document expiry reminders
//   and upcoming review dates.

final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    private static let wsLog = Logger(subsystem: "com.finderflow.app", category: "workspace")

    @Published private(set) var workspaces: [Workspace] = []
    /// Bumped on every mutation; badge views observe it via `workspaceVersion`.
    @Published private(set) var version: UInt = 0

    private let queue = DispatchQueue(label: "FinderFlow.workspaceStore", qos: .utility)
    /// Share-link presence per absolute file path. Populated lazily when the
    /// file panel resolves SecureShare bookmarks (resolving per row for a
    /// 8k folder would be far too heavy — PRD §13 🔗 badge therefore shows
    /// in the list only after the file was seen shared).
    private var sharePresence: [String: Bool] = [:]
    private let ioQueue = DispatchQueue(label: "FinderFlow.workspaceStoreIO", qos: .utility)

    // MARK: Paths

    var storeDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FF_WORKSPACE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FinderFlow/Workspaces", isDirectory: true)
    }

    private var storeFile: URL { storeDir.appendingPathComponent("workspaces.json") }

    init() { load() }

    // MARK: - Lookup

    /// Canonical absolute path (resolves symlinks, ~, ..).
    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func isWorkspace(_ url: URL) -> Bool {
        let path = Self.canonical(url)
        return workspaces.contains { $0.rootPath == path }
    }

    func workspace(at root: URL) -> Workspace? {
        let path = Self.canonical(root)
        return workspaces.first { $0.rootPath == path }
    }

    /// Nearest enclosing workspace root for a file or folder URL (walks up
    /// ancestors). Returns (workspace, rootURL).
    func enclosingWorkspace(for url: URL) -> (workspace: Workspace, root: URL)? {
        var cursor = URL(fileURLWithPath: Self.canonical(url))
        // If url is a file, start from its parent.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDir), !isDir.boolValue {
            cursor = cursor.deletingLastPathComponent()
        }
        while true {
            let path = cursor.path
            if let ws = workspaces.first(where: { $0.rootPath == path }) {
                return (ws, cursor)
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }
            cursor = parent
        }
    }

    /// Path of `url` relative to workspace `root` (nil when outside).
    func relativePath(of url: URL, to root: URL) -> String? {
        let rootPath = Self.canonical(root)
        let filePath = Self.canonical(url)
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else { return nil }
        if filePath == rootPath { return "" }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    func absoluteURL(relative: String, in root: URL) -> URL {
        root.appendingPathComponent(relative)
    }

    // MARK: - Workspace lifecycle

    @discardableResult
    func enableWorkspace(at folder: URL, name: String? = nil, owner: String? = nil) -> Workspace {
        let root = URL(fileURLWithPath: Self.canonical(folder), isDirectory: true)
        if let existing = workspace(at: root) { return existing }
        var ws = Workspace(rootPath: root.path,
                            name: name ?? root.lastPathComponent,
                            owner: owner)
        ws.activity.append(WorkspaceActivity(message: "Workspace enabled"))
        workspaces.append(ws)
        saveAndBump()
        requestNotificationAuthIfNeeded()
        rescheduleNotifications()
        return ws
    }

    func disableWorkspace(at root: URL) {
        let path = Self.canonical(root)
        workspaces.removeAll { $0.rootPath == path }
        saveAndBump()
        rescheduleNotifications()
    }

    func updateWorkspace(_ ws: Workspace, activity: String? = nil, fileRelative: String? = nil) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        var next = ws
        if let msg = activity {
            next.activity.insert(WorkspaceActivity(message: msg, fileRelative: fileRelative), at: 0)
            next.activity = Array(next.activity.prefix(200))
        }
        workspaces[i] = next
        saveAndBump()
        rescheduleNotifications()
    }

    // MARK: - Tasks (§4, §6, §14)

    func addTask(to workspaceID: String, _ task: WorkspaceTask) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        ws.tasks.append(task)
        let whereText = task.linkedFile.map { " for \($0)" } ?? ""
        updateWorkspace(ws, activity: "Task added: \(task.title)\(whereText)", fileRelative: task.linkedFile)
    }

    func updateTask(workspaceID: String, _ task: WorkspaceTask) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }),
              let i = ws.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let was = ws.tasks[i]
        var next = task
        if task.status == .done && was.status != .done { next.doneAt = Date() }
        if task.status != .done { next.doneAt = nil }
        ws.tasks[i] = next
        var msg: String?
        if was.status != next.status {
            msg = next.status == .done ? "Completed task: \(next.title)" : "Task \(next.status.title.lowercased()): \(next.title)"
        } else {
            msg = "Updated task: \(next.title)"
        }
        updateWorkspace(ws, activity: msg, fileRelative: next.linkedFile)
    }

    func deleteTask(workspaceID: String, taskID: String) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }),
              let i = ws.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let removed = ws.tasks.remove(at: i)
        updateWorkspace(ws, activity: "Removed task: \(removed.title)", fileRelative: removed.linkedFile)
    }

    // MARK: - Reminders (exact-time Mac notifications, §3)

    func addReminder(to workspaceID: String, _ reminder: WorkspaceReminder) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        ws.reminders.append(reminder)
        let whereText = reminder.linkedFile.map { " for \($0)" } ?? ""
        updateWorkspace(ws, activity: "Reminder set: \(reminder.title)\(whereText)", fileRelative: reminder.linkedFile)
    }

    func updateReminder(workspaceID: String, _ reminder: WorkspaceReminder) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }),
              let i = ws.reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        let was = ws.reminders[i]
        ws.reminders[i] = reminder
        var msg: String?
        if was.done != reminder.done {
            msg = reminder.done ? "Reminder done: \(reminder.title)" : "Reminder reopened: \(reminder.title)"
        } else {
            msg = "Reminder updated: \(reminder.title)"
        }
        updateWorkspace(ws, activity: msg, fileRelative: reminder.linkedFile)
    }

    func deleteReminder(workspaceID: String, reminderID: String) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }),
              let i = ws.reminders.firstIndex(where: { $0.id == reminderID }) else { return }
        let removed = ws.reminders.remove(at: i)
        updateWorkspace(ws, activity: "Removed reminder: \(removed.title)", fileRelative: removed.linkedFile)
    }

    // MARK: - Per-file metadata (§7–§11)

    func meta(workspaceID: String, relative: String) -> WorkspaceFileMeta? {
        workspaces.first(where: { $0.id == workspaceID })?.files[relative]
    }

    func setMeta(workspaceID: String, relative: String, _ meta: WorkspaceFileMeta, activity: String?) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        if meta.isEmpty {
            ws.files.removeValue(forKey: relative)
        } else {
            ws.files[relative] = meta
        }
        updateWorkspace(ws, activity: activity, fileRelative: relative)
    }

    func mutateMeta(workspaceID: String, relative: String, activity: String?,
                    _ block: (inout WorkspaceFileMeta) -> Void) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        var meta = ws.files[relative] ?? WorkspaceFileMeta()
        block(&meta)
        if meta.isEmpty {
            ws.files.removeValue(forKey: relative)
        } else {
            ws.files[relative] = meta
        }
        updateWorkspace(ws, activity: activity, fileRelative: relative)
    }

    // MARK: - File requests (§2, §15)

    func addFileRequest(workspaceID: String, _ req: WorkspaceFileRequest) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        ws.fileRequests.append(req)
        updateWorkspace(ws, activity: "Requested file: \(req.fileName)")
    }

    func setFileRequestReceived(workspaceID: String, requestID: String, received: Bool) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }),
              let i = ws.fileRequests.firstIndex(where: { $0.id == requestID }) else { return }
        ws.fileRequests[i].received = received
        let name = ws.fileRequests[i].fileName
        updateWorkspace(ws, activity: received ? "Received file: \(name)" : "Reopened request: \(name)")
    }

    func deleteFileRequest(workspaceID: String, requestID: String) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }),
              let i = ws.fileRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let removed = ws.fileRequests.remove(at: i)
        updateWorkspace(ws, activity: "Removed request: \(removed.fileName)")
    }

    // MARK: - Badges (§13)

    struct Badge: Equatable {
        var openTasks: Int = 0
        var endorsed: Bool = false
        var expiresInDays: Int?
        var hasShare: Bool = false
        /// Active (not done) reminder on the file.
        var hasReminder: Bool = false
        /// Version History label ("v4", "v3.2"), from VersionStore.
        var versionLabel: String? = nil

        var isEmpty: Bool {
            openTasks == 0 && !endorsed && expiresInDays == nil && !hasShare && !hasReminder
                && versionLabel == nil
        }
    }

    /// Set by VersionStore.start() — keeps this store free of the versions
    /// engine (and headless-testable without it).
    static var versionLabelProvider: ((URL) -> String?)?

    /// Another store changed what the badges show (Version History labels).
    func refreshBadges() {
        version &+= 1
        objectWillChange.send()
    }

    /// Cheap badge for list rows: tasks + review + expiry from JSON, share
    /// from the lazily-populated cache (see `noteSharePresence`).
    func badge(for fileURL: URL) -> Badge? {
        let versionLabel = Self.versionLabelProvider?(fileURL)
        guard let (ws, root) = enclosingWorkspace(for: fileURL),
              let rel = relativePath(of: fileURL, to: root), !rel.isEmpty else {
            return versionLabel.map { Badge(versionLabel: $0) }
        }
        let open = ws.openTasksForFile(relative: rel).count
        let meta = ws.files[rel]
        let endorsed = meta?.review?.status.isEndorsed ?? false
        var days: Int? = nil
        if let v = meta?.validity, !v.noLongerRequired {
            days = v.daysUntil()
        }
        let share = sharePresence[Self.canonical(fileURL)] ?? false
        let reminder = ws.activeReminders.contains { $0.linkedFile == rel }
        let b = Badge(openTasks: open, endorsed: endorsed, expiresInDays: days,
                      hasShare: share, hasReminder: reminder, versionLabel: versionLabel)
        return b.isEmpty ? nil : b
    }

    func noteSharePresence(fileURL: URL, hasShare: Bool) {
        let key = Self.canonical(fileURL)
        queue.sync { sharePresence[key] = hasShare }
        DispatchQueue.main.async { [weak self] in
            self?.version &+= 1
            self?.objectWillChange.send()
        }
    }

    func cachedSharePresence(fileURL: URL) -> Bool? {
        queue.sync { sharePresence[Self.canonical(fileURL)] }
    }

    // MARK: - Share lookup (read-only integration with SecureShare, §9)

    /// Active SecureShare records whose snapshot resolves to this file.
    /// Synchronous and best-effort: bookmark resolution can hit disk, so
    /// callers must invoke it only for the selected file (preview panel),
    /// never per list row.
    func activeShares(for fileURL: URL) -> [SecureShareRecord] {
        let target: String
        do {
            target = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
        } catch {
            target = fileURL.path
        }
        let canonTarget = URL(fileURLWithPath: target).standardizedFileURL.resolvingSymlinksInPath().path
        let fileName = fileURL.lastPathComponent
        guard let db = try? SecureShareDatabase() else { return [] }
        guard let records = try? db.shares() else { return [] }
        var out: [SecureShareRecord] = []
        for r in records {
            guard r.status == "active" else { continue }
            if let resolved = Self.resolveBookmark(r.bookmark) {
                if resolved == canonTarget {
                    out.append(r)
                    continue
                }
            }
            // Fallback: bookmark stale (moved file) — filename match keeps
            // the panel informative instead of blank.
            if r.filename == fileName, !out.contains(where: { $0.id == r.id }) {
                out.append(r)
            }
        }
        noteSharePresence(fileURL: fileURL, hasShare: !out.isEmpty)
        return out
    }

    private static func resolveBookmark(_ data: Data) -> String? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Overview queries (§3, §15)

    struct Attention {
        var overdueTasks: [WorkspaceTask] = []
        var expiringFiles: [(relative: String, days: Int)] = []
        var pendingReviews: [(relative: String, review: WorkspaceFileReview)] = []
        var pendingRequests: [WorkspaceFileRequest] = []
        /// Overdue or due-today reminders (not done).
        var dueReminders: [WorkspaceReminder] = []

        var isEmpty: Bool {
            overdueTasks.isEmpty && expiringFiles.isEmpty
                && pendingReviews.isEmpty && pendingRequests.isEmpty
                && dueReminders.isEmpty
        }

        var count: Int {
            overdueTasks.count + expiringFiles.count + pendingReviews.count
                + pendingRequests.count + dueReminders.count
        }
    }
    func attention(for ws: Workspace) -> Attention {
        var a = Attention()
        a.overdueTasks = ws.overdueTasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        for (rel, meta) in ws.files {
            if let v = meta.validity, !v.noLongerRequired,
               let days = v.daysUntil(), days <= 30 {
                a.expiringFiles.append((rel, days))
            }
            if let r = meta.review, r.status == .review {
                a.pendingReviews.append((rel, r))
            }
        }
        a.expiringFiles.sort { $0.days < $1.days }
        a.pendingRequests = ws.pendingRequests
        let tomorrowStart = Calendar.current.date(byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: Date())) ?? Date()
        a.dueReminders = ws.activeReminders
            .filter { $0.fireAt < tomorrowStart }
            .sorted { $0.fireAt < $1.fireAt }
        return a
    }

    /// Reviews needing attention: explicitly requested (status == review)
    /// plus dated ones due within the next 30 days (§3 "upcoming reviews").
    func upcomingReviews(for ws: Workspace, withinDays: Int = 30) -> [(relative: String, date: Date?)] {
        let horizon = Calendar.current.date(byAdding: .day, value: withinDays, to: Date()) ?? Date()
        var out: [(String, Date?)] = []
        for (rel, meta) in ws.files {
            guard let r = meta.review else { continue }
            if r.status == .review {
                out.append((rel, r.nextReviewDate))
            } else if let n = r.nextReviewDate, n <= horizon {
                out.append((rel, n))
            }
        }
        return out.sorted {
            ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture)
        }
    }

    /// Active share links across the workspace's top-level files (§3
    /// "Active share links"). Shallow + capped like `recentlyChanged`:
    /// bookmark resolution hits disk, so this never walks recursively.
    /// Populates the share-presence cache as a side effect (list 🔗 badges).
    func workspaceShareSummary(root: URL, maxFiles: Int = 60) -> (total: Int, files: [(relative: String, count: Int)]) {
        let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: opts) else {
            return (0, [])
        }
        var rows: [(String, Int)] = []
        var total = 0
        for u in urls.prefix(maxFiles) {
            guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey]),
                  v.isDirectory != true else { continue }
            let found = activeShares(for: u)
            if !found.isEmpty {
                guard let rel = relativePath(of: u, to: root) else { continue }
                rows.append((rel, found.count))
                total += found.count
            }
        }
        return (total, rows.sorted { $0.0 < $1.0 })
    }

    /// A requested document counts as received the moment a same-named file
    /// shows up in the workspace root (shallow check, case-insensitive).
    /// Called when the overview appears — the user never ticks this manually.
    func checkReceivedRequests(workspaceID: String, root: URL) {
        guard var ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        guard ws.pendingRequests.contains(where: { !$0.received }) else { return }
        let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: opts) else { return }
        let names = Set(urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }.map { $0.lastPathComponent.lowercased() })
        var changed = false
        var newlyReceived: [String] = []
        for i in ws.fileRequests.indices where !ws.fileRequests[i].received {
            if names.contains(ws.fileRequests[i].fileName.lowercased()) {
                ws.fileRequests[i].received = true
                newlyReceived.append(ws.fileRequests[i].fileName)
                changed = true
            }
        }
        guard changed else { return }
        updateWorkspace(ws, activity: "Received file\(newlyReceived.count == 1 ? "" : "s"): \(newlyReceived.joined(separator: ", "))")
    }

    /// Most recently modified files directly inside the workspace root
    /// (§3 "Recently changed documents"). Shallow + capped: keeps the
    /// overview instant even for large project folders.
    func recentlyChanged(in root: URL, limit: Int = 5) -> [(name: String, date: Date)] {
        let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: opts) else { return [] }
        var rows: [(String, Date)] = []
        for u in urls.prefix(400) {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  v.isDirectory != true, let d = v.contentModificationDate else { continue }
            rows.append((u.lastPathComponent, d))
        }
        return rows.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    // MARK: - Notifications (macOS, PRD §3)

    private var notifAuthChecked = false

    /// Tests set FF_WORKSPACE_DISABLE_NOTIF=1 so enabling/updating a
    /// workspace never touches UNUserNotificationCenter (no auth prompt).
    private var notificationsDisabled: Bool {
        ProcessInfo.processInfo.environment["FF_WORKSPACE_DISABLE_NOTIF"] == "1"
    }

    func requestNotificationAuthIfNeeded() {
        guard !notifAuthChecked, !notificationsDisabled else { return }
        notifAuthChecked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Current Mac notification permission, for status UI ("Notifications
    /// are off → Open Settings"). Nil when the check itself fails.
    static func notificationStatus() async -> UNAuthorizationStatus? {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings {
                cont.resume(returning: $0.authorizationStatus)
            }
        }
    }

    /// Asks the system for permission, but only from `.notDetermined`
    /// (the OS shows its prompt once ever — afterwards only Settings helps).
    /// Returns the resulting status.
    static func ensureNotificationAuth() async -> UNAuthorizationStatus? {
        let center = UNUserNotificationCenter.current()
        let current = await withCheckedContinuation { (cont: CheckedContinuation<UNAuthorizationStatus?, Never>) in
            center.getNotificationSettings { cont.resume(returning: $0.authorizationStatus) }
        }
        guard current == .notDetermined else { return current }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await withCheckedContinuation { (cont: CheckedContinuation<UNAuthorizationStatus?, Never>) in
            center.getNotificationSettings { cont.resume(returning: $0.authorizationStatus) }
        }
    }

    /// Opens System Settings at this app's Notifications page.
    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Rebuilds all FinderFlow workspace notifications. Stable identifiers
    /// (`ff-ws-*`) replace previous ones so rescheduling never duplicates.
    func rescheduleNotifications() {
        guard !notificationsDisabled else { return }
        requestNotificationAuthIfNeeded()
        let center = UNUserNotificationCenter.current()
        let snapshot = workspaces
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Self.wsLog.info("Skipping workspace notifications (permission: \(String(describing: settings.authorizationStatus)))")
                return
            }
            center.removePendingNotificationRequests(withIdentifiers: [])
            center.getPendingNotificationRequests { pending in
                let stale = pending.map(\.identifier).filter { $0.hasPrefix("ff-ws-") }
                center.removePendingNotificationRequests(withIdentifiers: stale)
                var reqs: [UNNotificationRequest] = []
                let now = Date()
                for ws in snapshot {
                    for t in ws.tasks where t.status.isOpen {
                        if let due = t.dueDate {
                            // Due-date reminder: 9:00 on the day, plus an
                            // immediate overdue nudge (stable id → no spam).
                            if due >= now,
                               let fire = Self.nineAM(on: due) {
                                reqs.append(Self.request(
                                    id: "ff-ws-task-\(t.id)",
                                    title: "Due: \(t.title)",
                                    body: "\(ws.name) · \(Self.dateString(due))",
                                    date: fire))
                            } else if t.isOverdue {
                                reqs.append(Self.request(
                                    id: "ff-ws-task-\(t.id)",
                                    title: "Overdue: \(t.title)",
                                    body: ws.name,
                                    date: now.addingTimeInterval(5)))
                            }
                        }
                    }
                    for (rel, meta) in ws.files {
                        if let v = meta.validity, !v.noLongerRequired,
                           let exp = v.expiresAt {
                            for days in v.remindDaysBefore {
                                guard let fire = Calendar.current.date(
                                    byAdding: .day, value: -days, to: exp),
                                      fire >= now,
                                      let nine = Self.nineAM(on: fire) else { continue }
                                reqs.append(Self.request(
                                    id: "ff-ws-exp-\(ws.id)-\(rel.hashValue)-\(days)",
                                    title: "\(URL(fileURLWithPath: rel).lastPathComponent) expires in \(days) day\(days == 1 ? "" : "s")",
                                    body: ws.name,
                                    date: nine))
                            }
                        }
                        if let next = meta.review?.nextReviewDate, next >= now,
                           let nine = Self.nineAM(on: next) {
                            reqs.append(Self.request(
                                id: "ff-ws-rev-\(ws.id)-\(rel.hashValue)",
                                title: "Review due: \(URL(fileURLWithPath: rel).lastPathComponent)",
                                body: ws.name,
                                date: nine))
                        }
                    }
                    if let dl = ws.deadline, dl >= now,
                       let nine = Self.nineAM(on: dl) {
                        reqs.append(Self.request(
                            id: "ff-ws-deadline-\(ws.id)",
                            title: "Deadline: \(ws.name)",
                            body: Self.dateString(dl),
                            date: nine))
                    }
                    for req in ws.pendingRequests {
                        guard let due = req.dueDate else { continue }
                        let who = req.requestedFrom.map { " · \($0)" } ?? ""
                        if due >= now, let nine = Self.nineAM(on: due) {
                            reqs.append(Self.request(
                                id: "ff-ws-req-\(req.id)",
                                title: "Expected: \(req.fileName)",
                                body: "\(ws.name)\(who) · \(Self.dateString(due))",
                                date: nine))
                        } else if due < Calendar.current.startOfDay(for: now) {
                            reqs.append(Self.request(
                                id: "ff-ws-req-\(req.id)",
                                title: "Still missing: \(req.fileName)",
                                body: "\(ws.name)\(who)",
                                date: now.addingTimeInterval(5)))
                        }
                    }
                    // Reminders fire at their exact time (§3: Mac notifications),
                    // even when FinderFlow sits in the background.
                    for rem in ws.activeReminders {
                        let doc = rem.linkedFile.map { " · \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
                        if rem.fireAt >= now {
                            reqs.append(Self.request(
                                id: "ff-ws-rem-\(rem.id)",
                                title: "Reminder: \(rem.title)",
                                body: "\(ws.name)\(doc)",
                                date: rem.fireAt,
                                exactTime: true))
                        } else {
                            reqs.append(Self.request(
                                id: "ff-ws-rem-\(rem.id)",
                                title: "Missed reminder: \(rem.title)",
                                body: "\(ws.name)\(doc)",
                                date: now.addingTimeInterval(5)))
                        }
                    }
                }
                for r in reqs.prefix(80) { center.add(r) }
                Self.wsLog.info("Scheduled \(reqs.count) workspace notifications")
            }
        }
    }

    private static func nineAM(on day: Date) -> Date? {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        var c = DateComponents()
        c.year = comps.year; c.month = comps.month; c.day = comps.day; c.hour = 9
        return Calendar.current.date(from: c)
    }

    private static func request(id: String, title: String, body: String,
                                date: Date, exactTime: Bool = false) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Reminders fire at the exact chosen time; everything else lands at 9:00.
        // Seconds are always explicit: a calendar trigger with missing fields
        // can resolve to "next matching minute" instead of firing once.
        let comps: DateComponents
        if exactTime {
            var c = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            if c.second == nil { c.second = 0 }
            comps = c
        } else {
            var c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            c.second = 0
            comps = c
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var workspaces: [Workspace]
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeFile),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        workspaces = p.workspaces
    }

    private func save() {
        let snapshot = workspaces
        let url = storeFile
        ioQueue.async {
            let p = Persisted(workspaces: snapshot)
            guard let data = try? JSONEncoder().encode(p) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveAndBump() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { self.saveAndBump() }
            return
        }
        save()
        version &+= 1
        objectWillChange.send()
    }

    /// For tests: clears in-memory + disk store.
    func resetForTests() {
        queue.sync { sharePresence = [:] }
        workspaces = []
        try? FileManager.default.removeItem(at: storeFile)
        version &+= 1
        objectWillChange.send()
    }
}

// MARK: - Quick capture (right-click on any file → linked task/reminder)

/// Sheet request for the task/reminder composer. `relative` nil means a
/// workspace-level entry; otherwise the entry is auto-linked to the file.
struct WorkspaceComposeRequest: Identifiable {
    let id = UUID()
    let workspaceID: String
    let rootURL: URL
    let relative: String?
    let fileName: String

    init?(notification n: Notification) {
        guard let info = n.userInfo,
              let workspaceID = info["workspaceID"] as? String,
              let root = info["root"] as? String,
              let fileName = info["name"] as? String else { return nil }
        self.workspaceID = workspaceID
        self.rootURL = URL(fileURLWithPath: root, isDirectory: true)
        self.relative = info["relative"] as? String
        self.fileName = fileName
    }

    init(workspaceID: String, rootURL: URL, relative: String?, fileName: String) {
        self.workspaceID = workspaceID; self.rootURL = rootURL
        self.relative = relative; self.fileName = fileName
    }
}

enum WorkspaceComposer {
    /// Resolves where a task/reminder for `url` belongs. Inside a workspace
    /// the file link is automatic; outside, the parent folder (or the folder
    /// itself) is enabled first so the work always has a home.
    static func resolve(for url: URL) -> WorkspaceComposeRequest? {
        let store = WorkspaceStore.shared
        if let found = store.enclosingWorkspace(for: url) {
            let rel = store.relativePath(of: url, to: found.root)
            let link = (rel?.isEmpty == false) ? rel : nil
            return WorkspaceComposeRequest(workspaceID: found.workspace.id,
                                            rootURL: found.root,
                                            relative: link,
                                            fileName: url.lastPathComponent)
        }
        let isFolder = Self.isBrowsableFolder(url)
        let root = isFolder ? url : url.deletingLastPathComponent()
        let ws = store.enableWorkspace(at: root)
        let rootURL = URL(fileURLWithPath: ws.rootPath, isDirectory: true)
        if isFolder {
            return WorkspaceComposeRequest(workspaceID: ws.id, rootURL: rootURL,
                                            relative: nil, fileName: url.lastPathComponent)
        }
        let rel = store.relativePath(of: url, to: rootURL)
        return WorkspaceComposeRequest(workspaceID: ws.id, rootURL: rootURL,
                                        relative: rel, fileName: url.lastPathComponent)
    }

    /// Finder parity with FileItem.isBrowsableFolder, without the AppKit
    /// dependency (keeps the composer testable headless).
    private static func isBrowsableFolder(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "app" { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        if let v = try? url.resourceValues(forKeys: [.isPackageKey]),
           v.isPackage == true { return false }
        return true
    }

    static func requestTask(for url: URL) {
        guard let r = resolve(for: url) else { return }
        NotificationCenter.default.post(name: .ffComposeTask, object: nil, userInfo: [
            "workspaceID": r.workspaceID, "root": r.rootURL.path,
            "relative": r.relative as Any, "name": r.fileName])
    }

    static func requestReminder(for url: URL) {
        guard let r = resolve(for: url) else { return }
        NotificationCenter.default.post(name: .ffComposeReminder, object: nil, userInfo: [
            "workspaceID": r.workspaceID, "root": r.rootURL.path,
            "relative": r.relative as Any, "name": r.fileName])
    }
}
