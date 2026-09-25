import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Today
//
// One screen for what needs the user now, across everything that already
// tracks work: Workspace tasks, reminders, deadlines, reviews, expiring
// documents and file requests; Mail Inbox mail waiting for a decision and
// its invoice/expiry reminders; what Folder Rules moved today (with Undo);
// Secure Share links about to expire or just signed.
//
// It owns no data: TodaySnapshot is computed from the existing stores, and
// every edit goes through WorkspaceStore / MailStore / FolderRulesService.
// Opened from the sidebar (row with badge), File ▸ Today (⌘0), the ⌘K
// palette and the Shortcuts action "Open Today".
//
// Interaction (a native List): ⌘/⇧-click and ⌘A select several rows;
// swipe right = delete (tasks, reminders, requests — documents are only
// dismissed, never deleted), swipe left = done / snooze; Space = done,
// ⌫ = delete, ⏎ = rename, ⌘C = copy as text; drop a file on a task to link
// it; every change can be undone (⌘Z or the banner).

struct TodayEntry: Identifiable {
    enum Kind {
        case task(WorkspaceTask)
        case reminder(WorkspaceReminder)
        case deadline
        case review(relative: String, review: WorkspaceFileReview)
        case expiry(relative: String, days: Int)
        case request(WorkspaceFileRequest)
        case mailReminder(record: MailInboxRecord, reminder: MailReminder)
        /// Version History: "this file looks like a new version of …".
        case versionFork(ForkSuggestion)
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
        case .versionFork(let s): return (s.newPath as NSString).lastPathComponent
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
        case .versionFork: return "arrow.triangle.branch"
        }
    }

    /// The document this entry is about, if any (reveal target).
    var fileURL: URL? {
        if case .versionFork(let s) = kind { return URL(fileURLWithPath: s.newPath) }
        guard let root else { return nil }
        switch kind {
        case .task(let t): return t.linkedFile.map { root.appendingPathComponent($0) }
        case .reminder(let r): return r.linkedFile.map { root.appendingPathComponent($0) }
        case .review(let rel, _), .expiry(let rel, _): return root.appendingPathComponent(rel)
        default: return nil
        }
    }

    var isDoneTask: Bool {
        if case .task(let t) = kind { return t.status == .done }
        return false
    }

    /// Tasks and reminders can carry a linked document.
    var isLinkable: Bool {
        switch kind {
        case .task, .reminder: return true
        default: return false
        }
    }

    var isRenamable: Bool { isLinkable }

    /// Rows whose date can be moved (Move To, Tomorrow).
    var isMovable: Bool {
        switch kind {
        case .task, .reminder, .deadline: return true
        default: return false
        }
    }

    /// What "done" means for this row (swipe left, Space, the circle).
    var doneLabel: String {
        switch kind {
        case .review: return "Approve"
        case .expiry: return "Renew +1 Year"
        case .request: return "Received"
        case .versionFork: return "Create Branch"
        default: return "Done"
        }
    }

    /// What "delete" means for this row (swipe right, ⌫). Documents are never
    /// deleted — only the reminder about them goes away.
    var deleteLabel: String {
        switch kind {
        case .task, .reminder, .request: return "Delete"
        case .deadline: return "Clear"
        case .review: return "Dismiss"
        case .expiry: return "Not Needed"
        case .mailReminder: return "Dismiss"
        case .versionFork: return "Keep Separate"
        }
    }

    /// One line for ⌘C / Copy: "☐ Poslati ponudu · Klijent Acme · 22 Sep".
    var copyLine: String {
        let box = isDoneTask ? "☑" : "☐"
        var parts = [title]
        if !workspaceName.isEmpty, !title.contains(workspaceName) { parts.append(workspaceName) }
        if let d = date { parts.append(d.formatted(.dateTime.day().month(.abbreviated))) }
        if let f = fileURL { parts.append(f.lastPathComponent) }
        return "\(box) " + parts.joined(separator: " · ")
    }
}

struct TodaySnapshot {
    var overdue: [TodayEntry] = []
    var today: [TodayEntry] = []
    var upcoming: [TodayEntry] = []
    /// Review requested / review date this week / expiring within 30 days.
    var documents: [TodayEntry] = []
    var waiting: [TodayEntry] = []
    /// Tasks finished today (so ticking one off doesn't make it vanish for good).
    var completed: [TodayEntry] = []
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
            && waiting.isEmpty && completed.isEmpty && mailToClassify == 0 && mailToReview == 0
            && autoSorted.isEmpty
    }

    var allEntries: [TodayEntry] { overdue + today + upcoming + documents + waiting + completed }

    func entries(_ ids: Set<String>) -> [TodayEntry] { allEntries.filter { ids.contains($0.id) } }

    static func build(workspaces: [Workspace], mail: [MailInboxRecord],
                      ruleActivity: [FolderRuleActivity], suggestions: [ForkSuggestion] = [],
                      now: Date = Date()) -> TodaySnapshot {
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
            for t in ws.tasks where t.status == .done {
                if let d = t.doneAt, d >= start, d < tomorrow {
                    s.completed.append(entry("task-\(t.id)", .task(t), t.dueDate))
                }
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

        for f in suggestions {
            s.documents.append(TodayEntry(id: "fork/\(f.id)", kind: .versionFork(f), workspaceID: nil,
                                          workspaceName: "", root: nil, date: f.date))
        }

        s.autoSorted = ruleActivity.filter { $0.date >= start && $0.date < tomorrow }

        let byDate: (TodayEntry, TodayEntry) -> Bool = {
            ($0.date ?? .distantFuture, $0.title) < ($1.date ?? .distantFuture, $1.title)
        }
        s.overdue.sort(by: byDate)
        s.today.sort(by: byDate)
        s.upcoming.sort(by: byDate)
        s.waiting.sort(by: byDate)
        s.completed.sort { $0.title < $1.title }
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

// MARK: - Quick add ("Nazvati Marka sutra u 15h")

enum TodayQuickAdd {
    /// Title + due date from a line typed in Today. Understands danas/today,
    /// sutra/tomorrow, prekosutra, sljedeće sedmice/next week, weekday names
    /// (bs/hr/sr + en) and a time such as "u 15h", "15:30", "3pm", "at 9".
    /// Date without time → 17:00; time alone → today.
    static func parse(_ text: String, now: Date = Date()) -> (title: String, due: Date?) {
        let cal = Calendar.current
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        func folded(_ w: String) -> String {
            w.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "đ", with: "d")
                .trimmingCharacters(in: .punctuationCharacters)
        }
        var day: Date?
        var hour: Int?, minute = 0
        let start = cal.startOfDay(for: now)
        let weekdays: [String: Int] = [
            "nedjelja": 1, "nedelja": 1, "nedjelju": 1, "nedelju": 1, "sunday": 1,
            "ponedjeljak": 2, "ponedeljak": 2, "monday": 2,
            "utorak": 3, "tuesday": 3,
            "srijeda": 4, "sreda": 4, "srijedu": 4, "sredu": 4, "wednesday": 4,
            "cetvrtak": 5, "thursday": 5,
            "petak": 6, "friday": 6,
            "subota": 7, "subotu": 7, "saturday": 7,
        ]
        var used = Set<Int>()
        var i = 0
        while i < words.count {
            let w = folded(words[i])
            let next = i + 1 < words.count ? folded(words[i + 1]) : ""
            switch w {
            case "danas", "today":
                day = start; used.insert(i)
            case "sutra", "tomorrow":
                day = cal.date(byAdding: .day, value: 1, to: start); used.insert(i)
            case "prekosutra":
                day = cal.date(byAdding: .day, value: 2, to: start); used.insert(i)
            case "sljedece", "sledece", "iduce", "next":
                if ["sedmice", "nedelje", "nedjelje", "tjedna", "week"].contains(next) {
                    day = cal.date(byAdding: .day, value: 7, to: start); used.formUnion([i, i + 1]); i += 1
                }
            default:
                if let wd = weekdays[w] {
                    let today = cal.component(.weekday, from: start)
                    var delta = (wd - today + 7) % 7
                    if delta == 0 { delta = 7 }
                    day = cal.date(byAdding: .day, value: delta, to: start); used.insert(i)
                    if i > 0, ["u", "on", "za"].contains(folded(words[i - 1])) { used.insert(i - 1) }
                } else if let (h, m) = time(w) {
                    hour = h; minute = m; used.insert(i)
                    if i > 0, ["u", "at", "oko"].contains(folded(words[i - 1])) { used.insert(i - 1) }
                } else if ["u", "at"].contains(w), let n = Int(next), (0...23).contains(n) {
                    hour = n; minute = 0; used.formUnion([i, i + 1]); i += 1
                }
            }
            i += 1
        }
        let kept = words.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        let title = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard day != nil || hour != nil else { return (text.trimmingCharacters(in: .whitespaces), nil) }
        let base = day ?? start
        let due = cal.date(bySettingHour: hour ?? 17, minute: hour == nil ? 0 : minute, second: 0, of: base)
        return (title.isEmpty ? text.trimmingCharacters(in: .whitespaces) : title, due)
    }

    /// "15h", "15:30", "9h30", "3pm".
    private static func time(_ w: String) -> (Int, Int)? {
        let s = w.lowercased()
        let patterns = ["^([01]?\\d|2[0-3])h(\\d{2})?$", "^([01]?\\d|2[0-3]):(\\d{2})$", "^(1[0-2]|[1-9])(am|pm)$"]
        for (n, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let hr = Range(m.range(at: 1), in: s), var h = Int(s[hr]) else { continue }
            var minute = 0
            if n < 2, m.range(at: 2).location != NSNotFound, let r = Range(m.range(at: 2), in: s) { minute = Int(s[r]) ?? 0 }
            if n == 2, let r = Range(m.range(at: 2), in: s) {
                if s[r] == "pm", h < 12 { h += 12 }
                if s[r] == "am", h == 12 { h = 0 }
            }
            return (h, minute)
        }
        return nil
    }
}

// MARK: - Edits (one place for every Today action, with undo)

enum TodayOp {
    case done, reopen, delete
    case due(Date)          // tasks / reminders / deadline: move to that day (time kept)
    case snooze(Date)       // reminders: exact time
    case link(URL), unlink
    case rename(String)
}

@MainActor
enum TodayEditor {
    struct Result {
        var changed = 0
        var skipped = 0
        var skipReason: String?
        var workspacesBefore: [Workspace] = []
        var mailBefore: [MailInboxRecord] = []
    }

    /// Applies `op` to every entry it fits: one store write per workspace,
    /// one activity line per item. Returns the "before" state for undo.
    static func apply(_ op: TodayOp, to entries: [TodayEntry],
                      store: WorkspaceStore = .shared, mail: MailStore = .shared,
                      now: Date = Date()) -> Result {
        var result = Result()
        let byWorkspace = Dictionary(grouping: entries.filter { $0.workspaceID != nil }, by: { $0.workspaceID! })
        for (wsID, items) in byWorkspace {
            guard let original = store.workspaces.first(where: { $0.id == wsID }) else { continue }
            var ws = original
            var log: [WorkspaceActivity] = []
            for e in items {
                if let line = applyOne(op, e, to: &ws, store: store, now: now, result: &result) {
                    log.append(WorkspaceActivity(message: line.message, fileRelative: line.file))
                    result.changed += 1
                }
            }
            guard !log.isEmpty else { continue }
            ws.activity.insert(contentsOf: log.reversed(), at: 0)
            ws.activity = Array(ws.activity.prefix(200))
            result.workspacesBefore.append(original)
            store.updateWorkspace(ws)
        }
        // Version History suggestions: branch or keep separate.
        for e in entries {
            guard case .versionFork(let s) = e.kind else { continue }
            switch op {
            case .done: VersionStore.shared.acceptSuggestion(s.id); result.changed += 1
            case .delete: VersionStore.shared.dismissSuggestion(s.id); result.changed += 1
            default: result.skipped += 1
            }
        }
        // Mail reminders: done or dismissed — mail itself is never deleted.
        for e in entries {
            guard case .mailReminder(let rec, let r) = e.kind else { continue }
            switch op {
            case .done, .delete:
                guard let current = mail.records.first(where: { $0.id == rec.id }),
                      let i = current.reminders.firstIndex(where: { $0.id == r.id }),
                      !current.reminders[i].done else { continue }
                var next = current
                next.reminders[i].done = true
                result.mailBefore.append(current)
                mail.update(next)
                result.changed += 1
            default:
                result.skipped += 1
            }
        }
        return result
    }

    private static func applyOne(_ op: TodayOp, _ e: TodayEntry, to ws: inout Workspace,
                                 store: WorkspaceStore, now: Date,
                                 result: inout Result) -> (message: String, file: String?)? {
        let cal = Calendar.current
        func moved(_ old: Date?, to day: Date) -> Date {
            let t = old.map { cal.dateComponents([.hour, .minute], from: $0) } ?? DateComponents(hour: 17, minute: 0)
            return cal.date(bySettingHour: t.hour ?? 17, minute: t.minute ?? 0, second: 0, of: day) ?? day
        }
        switch e.kind {
        case .task(let t):
            guard let i = ws.tasks.firstIndex(where: { $0.id == t.id }) else { return nil }
            switch op {
            case .done:
                guard ws.tasks[i].status != .done else { return nil }
                ws.tasks[i].status = .done; ws.tasks[i].doneAt = now
                return ("Completed task: \(t.title)", t.linkedFile)
            case .reopen:
                guard ws.tasks[i].status == .done else { return nil }
                ws.tasks[i].status = .todo; ws.tasks[i].doneAt = nil
                return ("Task reopened: \(t.title)", t.linkedFile)
            case .delete:
                ws.tasks.remove(at: i)
                return ("Removed task: \(t.title)", t.linkedFile)
            case .due(let day), .snooze(let day):
                ws.tasks[i].dueDate = moved(t.dueDate, to: day)
                return ("Task due \(WorkspaceStore.dateString(ws.tasks[i].dueDate!)): \(t.title)", t.linkedFile)
            case .link(let url):
                guard let rel = relative(url, in: ws, store: store, result: &result) else { return nil }
                ws.tasks[i].linkedFile = rel
                return ("Linked \(rel) to task: \(t.title)", rel)
            case .unlink:
                guard let old = t.linkedFile else { return nil }
                ws.tasks[i].linkedFile = nil
                return ("Unlinked \(old) from task: \(t.title)", nil)
            case .rename(let title):
                guard !title.isEmpty, title != t.title else { return nil }
                ws.tasks[i].title = title
                return ("Renamed task: \(t.title) → \(title)", t.linkedFile)
            }
        case .reminder(let r):
            guard let i = ws.reminders.firstIndex(where: { $0.id == r.id }) else { return nil }
            switch op {
            case .done:
                guard !ws.reminders[i].done else { return nil }
                ws.reminders[i].done = true
                return ("Reminder done: \(r.title)", r.linkedFile)
            case .reopen:
                guard ws.reminders[i].done else { return nil }
                ws.reminders[i].done = false
                return ("Reminder reopened: \(r.title)", r.linkedFile)
            case .delete:
                ws.reminders.remove(at: i)
                return ("Removed reminder: \(r.title)", r.linkedFile)
            case .due(let day):
                ws.reminders[i].fireAt = moved(r.fireAt, to: day)
                return ("Reminder moved: \(r.title)", r.linkedFile)
            case .snooze(let when):
                ws.reminders[i].fireAt = when
                return ("Reminder snoozed: \(r.title)", r.linkedFile)
            case .link(let url):
                guard let rel = relative(url, in: ws, store: store, result: &result) else { return nil }
                ws.reminders[i].linkedFile = rel
                return ("Linked \(rel) to reminder: \(r.title)", rel)
            case .unlink:
                guard let old = r.linkedFile else { return nil }
                ws.reminders[i].linkedFile = nil
                return ("Unlinked \(old) from reminder: \(r.title)", nil)
            case .rename(let title):
                guard !title.isEmpty, title != r.title else { return nil }
                ws.reminders[i].title = title
                return ("Renamed reminder: \(r.title) → \(title)", r.linkedFile)
            }
        case .deadline:
            switch op {
            case .done, .delete:
                guard ws.deadline != nil else { return nil }
                ws.deadline = nil
                return ("Deadline cleared", nil)
            case .due(let day), .snooze(let day):
                ws.deadline = moved(ws.deadline, to: day)
                return ("Deadline moved to \(WorkspaceStore.dateString(ws.deadline!))", nil)
            default: result.skipped += 1; return nil
            }
        case .review(let rel, _):
            guard var meta = ws.files[rel], var review = meta.review else { return nil }
            switch op {
            case .done:
                review.status = .approved; review.reviewDate = now
                meta.review = review; ws.files[rel] = meta
                return ("Approved \(rel)", rel)
            case .delete:
                review.status = .draft; review.nextReviewDate = nil
                meta.review = review; ws.files[rel] = meta
                return ("Review dismissed: \(rel)", rel)
            default: result.skipped += 1; return nil
            }
        case .expiry(let rel, _):
            guard var meta = ws.files[rel], var validity = meta.validity else { return nil }
            switch op {
            case .done:
                let base = validity.expiresAt.map { max($0, now) } ?? now
                validity.expiresAt = cal.date(byAdding: .year, value: 1, to: base)
                meta.validity = validity; ws.files[rel] = meta
                return ("Renewed \(rel) until \(WorkspaceStore.dateString(validity.expiresAt!))", rel)
            case .delete:
                validity.noLongerRequired = true
                meta.validity = validity; ws.files[rel] = meta
                return ("No longer required: \(rel)", rel)
            default: result.skipped += 1; return nil
            }
        case .request(let req):
            guard let i = ws.fileRequests.firstIndex(where: { $0.id == req.id }) else { return nil }
            switch op {
            case .done:
                ws.fileRequests[i].received = true
                return ("Received file: \(req.fileName)", nil)
            case .delete:
                ws.fileRequests.remove(at: i)
                return ("Removed request: \(req.fileName)", nil)
            default: result.skipped += 1; return nil
            }
        case .mailReminder, .versionFork:
            return nil
        }
    }

    /// Path of `url` inside the workspace, or nil (+ reason) when it lives
    /// elsewhere — links are stored relative to the workspace root.
    private static func relative(_ url: URL, in ws: Workspace, store: WorkspaceStore,
                                 result: inout Result) -> String? {
        let root = URL(fileURLWithPath: ws.rootPath, isDirectory: true)
        if let rel = store.relativePath(of: url, to: root), !rel.isEmpty { return rel }
        result.skipped += 1
        result.skipReason = "“\(url.lastPathComponent)” isn't inside “\(ws.name)”. Move it into the workspace folder to link it."
        return nil
    }

    /// Puts workspaces and mail records back as they were (undo/redo).
    static func restore(_ workspaces: [Workspace], mail records: [MailInboxRecord],
                        store: WorkspaceStore = .shared, mail: MailStore = .shared) {
        for ws in workspaces { store.updateWorkspace(ws) }
        for r in records { mail.update(r) }
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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 680, height: 780))
        window.minSize = NSSize(width: 520, height: 460)
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

// MARK: - Screen state

enum TodayFilter: String, CaseIterable, Identifiable {
    case all, tasks, reminders, documents, waiting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .tasks: return "Tasks"
        case .reminders: return "Reminders"
        case .documents: return "Documents"
        case .waiting: return "Waiting"
        }
    }

    func includes(_ e: TodayEntry) -> Bool {
        switch (self, e.kind) {
        case (.all, _): return true
        case (.tasks, .task), (.tasks, .deadline): return true
        case (.reminders, .reminder), (.reminders, .mailReminder): return true
        case (.documents, .review), (.documents, .expiry), (.documents, .versionFork): return true
        case (.waiting, .request): return true
        default: return false
        }
    }
}

struct TodayBanner: Equatable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}

@MainActor
final class TodayModel: ObservableObject {
    @Published var selection = Set<String>()
    @Published var filter: TodayFilter = .all
    @Published var collapsed: Set<String> = []
    @Published var editingID: String?
    @Published var editingText = ""
    @Published var banner: TodayBanner?
    /// Rows whose circle was just ticked (checkmark shows before they move).
    @Published var completing: Set<String> = []
    @Published var dropTargetID: String?

    // Quick add
    @Published var quickText = ""
    @Published var quickWorkspaceID: String? = UserDefaults.standard.string(forKey: "ffTodayWorkspace")
    @Published var quickFile: URL?
    @Published var quickDropTargeted = false

    weak var undoManager: UndoManager?
    private var bannerTask: Task<Void, Never>?

    // MARK: Running edits

    /// Every edit comes through here: apply, register undo, show banner.
    func perform(_ op: TodayOp, on entries: [TodayEntry], name: String, message: ((Int) -> String)? = nil) {
        guard !entries.isEmpty else { return }
        let r = withAnimation(.snappy) { TodayEditor.apply(op, to: entries) }
        if r.changed > 0 {
            let undoable = registerUndo(before: r.workspacesBefore, mail: r.mailBefore, name: name)
            let text = message?(r.changed) ?? "\(name) · \(r.changed) item\(r.changed == 1 ? "" : "s")"
            show(r.skipReason.map { "\(text). \($0)" } ?? text, undo: undoable)
        } else if let why = r.skipReason {
            show(why, undo: false)
        }
        if case .delete = op { selection.subtract(entries.map(\.id)) }
    }

    @discardableResult
    private func registerUndo(before ws: [Workspace], mail: [MailInboxRecord], name: String) -> Bool {
        guard let um = undoManager, !(ws.isEmpty && mail.isEmpty) else { return false }
        um.registerUndo(withTarget: self) { model in
            // Redo = the state right now, taken before restoring.
            let store = WorkspaceStore.shared
            let nowWS = ws.compactMap { old in store.workspaces.first { $0.id == old.id } }
            let nowMail = mail.compactMap { old in MailStore.shared.records.first { $0.id == old.id } }
            withAnimation(.snappy) { TodayEditor.restore(ws, mail: mail) }
            model.registerUndo(before: nowWS, mail: nowMail, name: name)
            model.show("Undone: \(name)", undo: false)
        }
        um.setActionName(name)
        return true
    }

    func undo() {
        undoManager?.undo()
    }

    func show(_ message: String, undo: Bool) {
        banner = TodayBanner(message: message, canUndo: undo && (undoManager?.canUndo ?? false))
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.banner = nil }
        }
    }

    /// Circle tick: checkmark first, then the row moves to Completed.
    func tick(_ e: TodayEntry) {
        if e.isDoneTask {
            perform(.reopen, on: [e], name: "Reopen")
            return
        }
        withAnimation(.spring(duration: 0.25)) { _ = completing.insert(e.id) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            completing.remove(e.id)
            perform(.done, on: [e], name: e.doneLabel)
        }
    }

    // MARK: Rename

    func beginRename(_ e: TodayEntry) {
        guard e.isRenamable else { return }
        editingText = e.title
        editingID = e.id
    }

    func commitRename(_ e: TodayEntry) {
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        guard !text.isEmpty, text != e.title else { return }
        perform(.rename(text), on: [e], name: "Rename", message: { _ in "Renamed to “\(text)”" })
    }

    // MARK: Linking

    func chooseFileToLink(for entries: [TodayEntry]) {
        let linkable = entries.filter(\.isLinkable)
        guard let first = linkable.first else { return }
        let panel = NSOpenPanel()
        panel.title = "Link a Document"
        panel.message = linkable.count == 1 ? "Choose the document for “\(first.title)”."
            : "Choose one document for \(linkable.count) items."
        panel.prompt = "Link"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = first.root
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        link(url, to: linkable)
    }

    func link(_ url: URL, to entries: [TodayEntry]) {
        perform(.link(url), on: entries.filter(\.isLinkable), name: "Link",
                message: { n in "Linked “\(url.lastPathComponent)” to \(n) item\(n == 1 ? "" : "s")" })
    }

    // MARK: Quick add

    func workspaceForQuickAdd(_ all: [Workspace]) -> Workspace? {
        if let id = quickWorkspaceID, let ws = all.first(where: { $0.id == id }) { return ws }
        return all.first
    }

    /// Creates the task. A dropped file decides the workspace (enabling one
    /// on its folder if needed) and becomes the task's linked document.
    @discardableResult
    func addQuickTask(workspaces all: [Workspace], now: Date = Date()) -> Bool {
        let (title, due) = TodayQuickAdd.parse(quickText, now: now)
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let store = WorkspaceStore.shared
        var wsID: String?
        var linked: String?
        var before: Workspace?
        if let file = quickFile {
            let existed = store.enclosingWorkspace(for: file) != nil
            guard let target = WorkspaceComposer.resolve(for: file) else { return false }
            wsID = target.workspaceID
            linked = target.relative
            if existed { before = store.workspaces.first { $0.id == target.workspaceID } }
        } else {
            wsID = workspaceForQuickAdd(all)?.id
            before = wsID.flatMap { id in store.workspaces.first { $0.id == id } }
        }
        guard let wsID else {
            show("Enable Workspace on a folder first (right-click a folder ▸ Enable Workspace), or drop a file here.", undo: false)
            return false
        }
        withAnimation(.snappy) {
            store.addTask(to: wsID, WorkspaceTask(title: title, dueDate: due, linkedFile: linked))
        }
        if let before { registerUndo(before: [before], mail: [], name: "Add Task") }
        quickWorkspaceID = wsID
        UserDefaults.standard.set(wsID, forKey: "ffTodayWorkspace")
        let when = due.map { " · " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) } ?? ""
        show("Added “\(title)”\(when)", undo: before != nil)
        quickText = ""
        quickFile = nil
        return true
    }
}

// MARK: - View

struct TodayView: View {
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @ObservedObject private var mail = MailStore.shared
    @ObservedObject private var rules = FolderRulesService.shared
    @ObservedObject private var versions = VersionStore.shared
    @StateObject private var model = TodayModel()
    @Environment(\.undoManager) private var undoManager
    @State private var shares: [TodayShareItem] = []
    @State private var showAllSorted = false
    /// Bumped by the refresh button / window focus so dates re-bucket after
    /// midnight without a store change.
    @State private var now = Date()
    @FocusState private var quickFocused: Bool

    /// `model` is for tests/snapshots (a preset selection or banner).
    init(model: TodayModel? = nil) {
        _model = StateObject(wrappedValue: model ?? TodayModel())
    }

    private var snapshot: TodaySnapshot {
        TodaySnapshot.build(workspaces: workspaces.workspaces, mail: mail.records,
                            ruleActivity: rules.activity, suggestions: versions.index.suggestions, now: now)
    }

    var body: some View {
        let s = snapshot
        VStack(spacing: 0) {
            header(s)
            list(s)
                .overlay(alignment: .bottom) { bottomBar(s) }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.undoManager = undoManager
            refresh()
        }
        .onChange(of: undoManager) { _, um in model.undoManager = um }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                progressRing(s)
                VStack(alignment: .leading, spacing: 3) {
                    Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(summary(s)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            quickAdd
            filterChips(s)
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    /// Done today vs. still due today (overdue + today).
    private func progressRing(_ s: TodaySnapshot) -> some View {
        let done = s.completed.count
        let total = done + s.overdue.count + s.today.count
        let fraction = total == 0 ? 1 : Double(done) / Double(total)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [.orange, .pink, .purple, .orange], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
            if total == 0 {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
            } else {
                Text("\(done)/\(total)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: 48, height: 48)
        .help(total == 0 ? "Nothing due today" : "\(done) of \(total) due today done")
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

    private var quickAdd: some View {
        let all = workspaces.workspaces
        let ws = model.workspaceForQuickAdd(all)
        let preview = TodayQuickAdd.parse(model.quickText, now: now).due
        return HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
            TextField("Add a task — “Nazvati Marka sutra u 15h”, or drop a file", text: $model.quickText)
                .textFieldStyle(.plain)
                .focused($quickFocused)
                .onSubmit { _ = model.addQuickTask(workspaces: all) }
            if let preview, !model.quickText.isEmpty {
                Text(preview.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
            if let file = model.quickFile {
                chip(file.lastPathComponent, symbol: "paperclip", tint: .accentColor) { model.quickFile = nil }
                    .help("The new task links this document (drop another to replace)")
            } else if !all.isEmpty {
                Menu {
                    ForEach(all) { w in
                        Button { model.quickWorkspaceID = w.id } label: {
                            if w.id == ws?.id { Label(w.name, systemImage: "checkmark") } else { Text(w.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(TodayColors.workspace(ws?.name ?? "")).frame(width: 7, height: 7)
                        Text(ws?.name ?? "Workspace").lineLimit(1)
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Workspace for new tasks")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(model.quickDropTargeted ? Color.accentColor : Color.primary.opacity(quickFocused ? 0.18 : 0.08),
                          lineWidth: model.quickDropTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.quickFile = url
            quickFocused = true
            return true
        } isTargeted: { model.quickDropTargeted = $0 }
        .animation(.snappy, value: model.quickText.isEmpty)
    }

    private func filterChips(_ s: TodaySnapshot) -> some View {
        let open = s.overdue + s.today + s.upcoming + s.documents + s.waiting
        return HStack(spacing: 6) {
            ForEach(TodayFilter.allCases) { f in
                let n = f == .all ? nil : open.filter(f.includes).count
                let on = model.filter == f
                Button {
                    withAnimation(.snappy) { model.filter = f }
                } label: {
                    HStack(spacing: 4) {
                        Text(f.title)
                        if let n, n > 0 { Text("\(n)").foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary) }
                    }
                    .font(.callout.weight(on ? .semibold : .regular))
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: List

    private func list(_ s: TodaySnapshot) -> some View {
        let f = model.filter
        return List(selection: $model.selection) {
            if s.isEmpty && shares.isEmpty {
                allClear.listRowSeparator(.hidden)
            }
            section("overdue", "Overdue", symbol: "exclamationmark.circle.fill", tint: .red,
                    s.overdue.filter(f.includes),
                    bulk: ("Move All to Today", { model.perform(.due(now), on: s.overdue.filter(\.isMovable), name: "Move to Today") }))
            section("today", "Today", symbol: "sun.max.fill", tint: .orange, s.today.filter(f.includes))
            section("upcoming", "Next 7 Days", symbol: "calendar", tint: .blue, s.upcoming.filter(f.includes))
            section("documents", "Documents", symbol: "doc.text.magnifyingglass", tint: .purple, s.documents.filter(f.includes))
            section("waiting", "Waiting for Files", symbol: "tray.and.arrow.down.fill", tint: .teal, s.waiting.filter(f.includes))
            if f == .all || f == .tasks {
                section("completed", "Completed Today", symbol: "checkmark.circle.fill", tint: .green, s.completed)
            }
            if f == .all {
                mailSection(s)
                sortedSection(s)
                shareSection
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            selectionMenu(snapshot.entries(ids))
        } primaryAction: { ids in
            if let e = snapshot.entries(ids).first { open(e) }
        }
        .onDeleteCommand { model.perform(.delete, on: selectedEntries, name: "Delete") }
        .onKeyPress(.space) {
            let sel = selectedEntries.filter { !$0.isDoneTask }
            guard !sel.isEmpty, model.editingID == nil else { return .ignored }
            model.perform(.done, on: sel, name: "Done")
            return .handled
        }
        .onKeyPress(.return) {
            let sel = selectedEntries
            guard sel.count == 1, model.editingID == nil else { return .ignored }
            if sel[0].isRenamable { model.beginRename(sel[0]) } else { open(sel[0]) }
            return .handled
        }
        .onExitCommand {
            if model.editingID != nil { model.editingID = nil } else { model.selection.removeAll() }
        }
        .onCopyCommand {
            let text = selectedEntries.map(\.copyLine).joined(separator: "\n")
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
    }

    private var selectedEntries: [TodayEntry] { snapshot.entries(model.selection) }

    @ViewBuilder
    private func section(_ key: String, _ title: String, symbol: String, tint: Color, _ entries: [TodayEntry],
                         bulk: (String, () -> Void)? = nil) -> some View {
        if !entries.isEmpty {
            Section {
                if !model.collapsed.contains(key) {
                    ForEach(entries) { e in
                        TodayRow(entry: e, now: now, model: model, open: { open(e) })
                            .tag(e.id)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button(role: e.deleteLabel == "Delete" ? .destructive : nil) {
                                    model.perform(.delete, on: [e], name: e.deleteLabel)
                                } label: {
                                    Label(e.deleteLabel, systemImage: e.deleteLabel == "Delete" ? "trash" : "xmark")
                                }
                                .tint(e.deleteLabel == "Delete" ? .red : .gray)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if e.isDoneTask {
                                    Button { model.tick(e) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                                        .tint(.blue)
                                } else {
                                    Button { model.tick(e) } label: { Label(e.doneLabel, systemImage: "checkmark") }
                                        .tint(.green)
                                }
                                if case .reminder = e.kind {
                                    Button { model.perform(.snooze(Date().addingTimeInterval(3_600)), on: [e], name: "Snooze") } label: {
                                        Label("1 Hour", systemImage: "moon.zzz")
                                    }
                                    .tint(.indigo)
                                } else if e.isMovable && !e.isDoneTask {
                                    Button { model.perform(.due(TodayDates.tomorrow(now)), on: [e], name: "Tomorrow") } label: {
                                        Label("Tomorrow", systemImage: "arrow.turn.up.right")
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                }
            } header: {
                sectionHeader(key, title, symbol: symbol, tint: tint, count: entries.count, bulk: bulk)
            }
        }
    }

    private func sectionHeader(_ key: String, _ title: String, symbol: String, tint: Color, count: Int,
                               bulk: (String, () -> Void)? = nil) -> some View {
        let isCollapsed = model.collapsed.contains(key)
        return HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    if isCollapsed { model.collapsed.remove(key) } else { model.collapsed.insert(key) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.tertiary)
                    Image(systemName: symbol).foregroundStyle(tint)
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(tint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show" : "Hide")
            Spacer()
            if let bulk, count > 0 {
                Button(bulk.0, action: bulk.1)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Context menu (one row or the whole selection)

    @ViewBuilder
    private func selectionMenu(_ entries: [TodayEntry]) -> some View {
        if !entries.isEmpty {
            let n = entries.count
            let suffix = n > 1 ? " (\(n))" : ""
            if n == 1, let e = entries.first {
                Button(e.fileURL != nil ? "Show Document in aiFlow" : "Open in aiFlow") { open(e) }
                if let root = e.root {
                    Button("Open Workspace Folder") { FFMainWindow.open(folder: root) }
                }
                if e.isRenamable { Button("Rename") { model.beginRename(e) } }
                Divider()
            }
            let pending = entries.filter { !$0.isDoneTask }
            if !pending.isEmpty {
                Button("\(pending.count == 1 ? pending[0].doneLabel : "Done")\(suffix)") { model.perform(.done, on: pending, name: "Done") }
            }
            let done = entries.filter(\.isDoneTask)
            if !done.isEmpty { Button("Reopen\(suffix)") { model.perform(.reopen, on: done, name: "Reopen") } }
            let movable = entries.filter { $0.isMovable && !$0.isDoneTask }
            if !movable.isEmpty {
                Menu("Move To") {
                    Button("Today") { model.perform(.due(now), on: movable, name: "Move to Today") }
                    Button("Tomorrow") { model.perform(.due(TodayDates.tomorrow(now)), on: movable, name: "Move to Tomorrow") }
                    Button("Next Week") { model.perform(.due(TodayDates.nextWeek(now)), on: movable, name: "Move to Next Week") }
                }
            }
            let reminders = entries.filter { if case .reminder = $0.kind { return true }; return false }
            if !reminders.isEmpty {
                Menu("Snooze") {
                    Button("1 Hour") { model.perform(.snooze(Date().addingTimeInterval(3_600)), on: reminders, name: "Snooze") }
                    Button("Tomorrow at 9:00") { model.perform(.snooze(TodayDates.tomorrowMorning(now)), on: reminders, name: "Snooze") }
                    Button("Next Week") { model.perform(.snooze(TodayDates.nextWeekMorning(now)), on: reminders, name: "Snooze") }
                }
            }
            let linkable = entries.filter(\.isLinkable)
            if !linkable.isEmpty {
                Divider()
                Button("Link to File…\(suffix)") { model.chooseFileToLink(for: linkable) }
                if linkable.contains(where: { $0.fileURL != nil }) {
                    Button("Unlink File\(suffix)") { model.perform(.unlink, on: linkable, name: "Unlink") }
                }
            }
            let files = entries.compactMap(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
            if !files.isEmpty {
                Button("Share with Secure Link…") { SecureShareWindowManager.shared.open(urls: files) }
            }
            Divider()
            Button("Copy as Text\(suffix)") { copy(entries) }
            Divider()
            Button(n == 1 ? entries[0].deleteLabel : "Delete / Dismiss\(suffix)", role: .destructive) {
                model.perform(.delete, on: entries, name: n == 1 ? entries[0].deleteLabel : "Delete")
            }
        }
    }

    private func copy(_ entries: [TodayEntry]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entries.map(\.copyLine).joined(separator: "\n"), forType: .string)
        NotificationCenter.default.post(name: .ffExternalPasteboardWrite, object: nil)
        model.show("Copied \(entries.count) item\(entries.count == 1 ? "" : "s") as text", undo: false)
    }

    // MARK: Other sections

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 46))
                .foregroundStyle(LinearGradient(colors: [.green, .teal], startPoint: .top, endPoint: .bottom))
            Text("You're all caught up").font(.title3.weight(.semibold))
            Text("Tasks, reminders, reviews and expiring documents from your workspaces show up here, together with mail waiting in the Mail Inbox and what Folder Rules sorted today. Type above to add a task.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    @ViewBuilder
    private func mailSection(_ s: TodaySnapshot) -> some View {
        if s.mailToClassify + s.mailToReview > 0 {
            Section {
                if !model.collapsed.contains("mail") {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.title3).foregroundStyle(.indigo).frame(width: 26)
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
                    .padding(.vertical, 4)
                    .tag("mail-summary")
                }
            } header: {
                sectionHeader("mail", "Mail Inbox", symbol: "envelope.fill", tint: .indigo,
                              count: s.mailToClassify + s.mailToReview)
            }
        }
    }

    @ViewBuilder
    private func sortedSection(_ s: TodaySnapshot) -> some View {
        if !s.autoSorted.isEmpty {
            let shown = showAllSorted ? s.autoSorted : Array(s.autoSorted.prefix(6))
            Section {
                if !model.collapsed.contains("sorted") {
                    ForEach(shown) { a in
                        sortedRow(a)
                            .tag("sorted/\(a.id)")
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !a.undone {
                                    Button { rules.undo(a.id) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                                        .tint(.orange)
                                }
                            }
                    }
                    if s.autoSorted.count > 6 {
                        Button(showAllSorted ? "Show fewer" : "Show all \(s.autoSorted.count)") {
                            withAnimation(.snappy) { showAllSorted.toggle() }
                        }
                        .buttonStyle(.link)
                        .tag("sorted-more")
                    }
                }
            } header: {
                sectionHeader("sorted", "Auto-Sorted Today", symbol: "wand.and.stars", tint: .green, count: s.autoSorted.count)
            }
        }
    }

    private func sortedRow(_ a: FolderRuleActivity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.kind == .trash ? "trash" : a.kind == .tag ? "tag" : "arrow.right.doc.on.clipboard")
                .foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.fileName).lineLimit(1).truncationMode(.middle)
                    .strikethrough(a.undone, color: .secondary)
                Text("\((a.folder as NSString).lastPathComponent) · \(a.ruleSummary)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var shareSection: some View {
        if !shares.isEmpty {
            Section {
                if !model.collapsed.contains("shares") {
                    ForEach(shares) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.signedBy != nil ? "signature" : "clock.badge.exclamationmark")
                                .foregroundStyle(item.signedBy != nil ? .green : .orange).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename).lineLimit(1).truncationMode(.middle)
                                Text(shareDetail(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Manage") { SecureShareWindowManager.shared.open() }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                        .tag("share/\(item.id)")
                    }
                }
            } header: {
                sectionHeader("shares", "Shared Links", symbol: "link", tint: .blue, count: shares.count)
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

    // MARK: Bottom: selection bar + undo banner

    @ViewBuilder
    private func bottomBar(_ s: TodaySnapshot) -> some View {
        VStack(spacing: 8) {
            if let banner = model.banner {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(banner.message).lineLimit(2)
                    if banner.canUndo {
                        Button("Undo") { model.undo() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                            .fontWeight(.semibold)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(banner.id)
            }
            let sel = s.entries(model.selection)
            if sel.count > 1 {
                selectionBar(sel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 14)
        .animation(.snappy, value: model.banner)
        .animation(.snappy, value: model.selection.count > 1)
    }

    private func selectionBar(_ sel: [TodayEntry]) -> some View {
        HStack(spacing: 4) {
            Text("\(sel.count) selected")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
            Divider().frame(height: 18)
            barButton("Done", "checkmark.circle") { model.perform(.done, on: sel.filter { !$0.isDoneTask }, name: "Done") }
                .help("Done / approve / received (Space)")
            if sel.contains(where: \.isMovable) {
                Menu {
                    Button("Today") { model.perform(.due(now), on: sel.filter(\.isMovable), name: "Move to Today") }
                    Button("Tomorrow") { model.perform(.due(TodayDates.tomorrow(now)), on: sel.filter(\.isMovable), name: "Move to Tomorrow") }
                    Button("Next Week") { model.perform(.due(TodayDates.nextWeek(now)), on: sel.filter(\.isMovable), name: "Move to Next Week") }
                } label: {
                    Label("Move", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 6)
            }
            if sel.contains(where: \.isLinkable) {
                barButton("Link File", "paperclip") { model.chooseFileToLink(for: sel) }
            }
            barButton("Copy", "doc.on.doc") { copy(sel) }
            barButton("Delete", "trash", role: .destructive) { model.perform(.delete, on: sel, name: "Delete") }
                .help("Delete tasks, reminders and requests; dismiss documents (⌫)")
            Divider().frame(height: 18)
            Button { model.selection.removeAll() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Clear selection (Esc)")
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func barButton(_ title: String, _ symbol: String, role: ButtonRole? = nil, _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
    }

    // MARK: Helpers

    private func chip(_ text: String, symbol: String, tint: Color, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func open(_ e: TodayEntry) {
        if let url = e.fileURL, FileManager.default.fileExists(atPath: url.path) {
            FFMainWindow.reveal(url)
        } else if let root = e.root {
            FFMainWindow.open(folder: root)
        } else if case .mailReminder = e.kind {
            MailInboxWindowManager.shared.open()
        }
    }
}

// MARK: - Row

private struct TodayRow: View {
    let entry: TodayEntry
    let now: Date
    @ObservedObject var model: TodayModel
    let open: () -> Void
    @State private var hovering = false
    @FocusState private var editFocused: Bool

    private var isCompleting: Bool { model.completing.contains(entry.id) }
    private var isEditing: Bool { model.editingID == entry.id }

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                titleView
                HStack(spacing: 6) {
                    if !entry.workspaceName.isEmpty, !entry.title.contains(entry.workspaceName) {
                        workspaceTag
                    }
                    if let file = entry.fileURL, entry.isLinkable {
                        fileChip(file)
                    }
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if hovering && !isEditing { hoverActions }
            if let label = dateLabel { datePill(label) }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .opacity(isCompleting ? 0.55 : 1)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: model.dropTargetID == entry.id ? 2 : 0)
                .padding(-3)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard entry.isLinkable, let url = urls.first(where: \.isFileURL) else { return false }
            model.link(url, to: [entry])
            return true
        } isTargeted: { t in
            guard entry.isLinkable else { return }
            if t { model.dropTargetID = entry.id } else if model.dropTargetID == entry.id { model.dropTargetID = nil }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var leading: some View {
        switch entry.kind {
        case .task(let t):
            let done = t.status == .done || isCompleting
            Button { model.tick(entry) } label: {
                ZStack {
                    Circle()
                        .strokeBorder(done ? Color.green : priorityColor(t), lineWidth: 1.6)
                        .background(Circle().fill(done ? Color.green : .clear))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .transition(.scale)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(done ? "Reopen" : "Mark as done (Space)")
        case .reminder:
            Button { model.tick(entry) } label: {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "bell.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(isCompleting ? .green : .orange)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Mark as done (Space)")
        case .mailReminder:
            Button { model.tick(entry) } label: {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : entry.symbol)
                    .foregroundStyle(isCompleting ? .green : .indigo)
            }
            .buttonStyle(.plain)
            .help("Mark as done (Space)")
        default:
            Image(systemName: entry.symbol)
                .foregroundStyle(symbolTint)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditing {
            TextField("Title", text: $model.editingText)
                .textFieldStyle(.plain)
                .focused($editFocused)
                .onAppear { editFocused = true }
                .onSubmit { model.commitRename(entry) }
                .onExitCommand { model.editingID = nil }
        } else {
            HStack(spacing: 5) {
                if case .task(let t) = entry.kind, t.priority == .high || t.priority == .urgent {
                    Text(t.priority == .urgent ? "!!!" : "!!")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(t.priority == .urgent ? .red : .orange)
                }
                Text(entry.title)
                    .lineLimit(1).truncationMode(.middle)
                    .strikethrough(entry.isDoneTask, color: .secondary)
                    .foregroundStyle(entry.isDoneTask ? .secondary : .primary)
            }
        }
    }

    private var workspaceTag: some View {
        HStack(spacing: 4) {
            Circle().fill(TodayColors.workspace(entry.workspaceName)).frame(width: 6, height: 6)
            Text(entry.workspaceName).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Linked document: click shows it, drag takes it out (Mail, browser…).
    private func fileChip(_ file: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: file.path)
        return Button {
            if exists { FFMainWindow.reveal(file) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: exists ? "paperclip" : "exclamationmark.triangle")
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.accentColor.opacity(exists ? 0.12 : 0.05), in: Capsule())
            .foregroundStyle(exists ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(exists ? "Show “\(file.lastPathComponent)” in aiFlow — or drag it into Mail" : "The linked file was moved or deleted")
        .draggable(file)
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if entry.isLinkable {
                Button { model.chooseFileToLink(for: [entry]) } label: { Image(systemName: "paperclip") }
                    .help("Link to a document (or drop a file on this row)")
            }
            if case .reminder = entry.kind {
                Menu {
                    Button("In 1 Hour") { model.perform(.snooze(Date().addingTimeInterval(3_600)), on: [entry], name: "Snooze") }
                    Button("Tomorrow at 9:00") { model.perform(.snooze(TodayDates.tomorrowMorning(now)), on: [entry], name: "Snooze") }
                    Button("Next Week") { model.perform(.snooze(TodayDates.nextWeekMorning(now)), on: [entry], name: "Snooze") }
                } label: { Image(systemName: "moon.zzz") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Snooze")
            } else if entry.isMovable && !entry.isDoneTask {
                Menu {
                    Button("Today") { model.perform(.due(now), on: [entry], name: "Move to Today") }
                    Button("Tomorrow") { model.perform(.due(TodayDates.tomorrow(now)), on: [entry], name: "Move to Tomorrow") }
                    Button("Next Week") { model.perform(.due(TodayDates.nextWeek(now)), on: [entry], name: "Move to Next Week") }
                } label: { Image(systemName: "calendar") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Move the due date")
            }
            Button(action: open) { Image(systemName: "arrow.right.circle") }
                .help(entry.fileURL != nil ? "Show the document in aiFlow" : "Open in aiFlow")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .transition(.opacity)
    }

    private func datePill(_ label: String) -> some View {
        let late = isLate
        let isToday = entry.date.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
        let tint: Color = entry.isDoneTask ? .secondary : late ? .red : isToday ? .orange : .secondary
        return Text(label)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(late || isToday ? 0.14 : 0.08), in: Capsule())
            .foregroundStyle(tint)
    }

    private func priorityColor(_ t: WorkspaceTask) -> Color {
        switch t.priority {
        case .urgent: return .red
        case .high: return .orange
        default: return Color.secondary.opacity(0.7)
        }
    }

    private var symbolTint: Color {
        switch entry.kind {
        case .deadline: return .red
        case .review: return .purple
        case .expiry(_, let d): return d <= 7 ? .orange : .secondary
        case .request: return .teal
        case .versionFork: return .purple
        default: return .secondary
        }
    }

    // MARK: Text

    private var detail: String {
        var parts: [String] = []
        switch entry.kind {
        case .task(let t):
            if let a = t.assignee, !a.isEmpty { parts.append(a) }
            if t.status == .waiting { parts.append("Waiting") }
            if t.status == .inProgress { parts.append("In progress") }
        case .reminder:
            break
        case .deadline:
            parts.append("Workspace deadline")
        case .review(let rel, let r):
            parts.append(r.status == .review ? "Review requested" : "Review due")
            if let who = r.reviewer, !who.isEmpty { parts.append(who) }
            let folder = (rel as NSString).deletingLastPathComponent
            if !folder.isEmpty { parts.append(folder) }
        case .expiry(_, let days):
            parts.append(days < 0 ? "Expired \(-days) day\(days == -1 ? "" : "s") ago"
                         : days == 0 ? "Expires today" : "Expires in \(days) day\(days == 1 ? "" : "s")")
        case .request(let r):
            if let from = r.requestedFrom, !from.isEmpty { parts.append("From \(from)") }
        case .mailReminder(let rec, _):
            let who = rec.suggestion.entity.isEmpty ? rec.mail.from : rec.suggestion.entity
            parts.append(who)
            if let amount = rec.suggestion.facts["amount"], !amount.isEmpty {
                parts.append([amount, rec.suggestion.facts["currency"] ?? ""].joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces))
            }
        case .versionFork(let s):
            parts.append("New version of \(s.baseName) \(s.baseLabel)? Branch it or keep it separate")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var isLate: Bool {
        guard let d = entry.date, !entry.isDoneTask else { return false }
        if case .reminder = entry.kind { return d < now }
        return d < Calendar.current.startOfDay(for: now)
    }

    private var dateLabel: String? {
        // Ticked off today: when it was done, not how late it had been.
        if case .task(let t) = entry.kind, t.status == .done, let done = t.doneAt {
            return "✓ " + done.formatted(date: .omitted, time: .shortened)
        }
        guard let d = entry.date else { return nil }
        let cal = Calendar.current
        switch entry.kind {
        case .reminder:
            if cal.isDate(d, inSameDayAs: now) { return d.formatted(date: .omitted, time: .shortened) }
            return d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        default:
            if cal.isDate(d, inSameDayAs: now) {
                // Tasks typed with a time ("u 15h") show it; date-only ones say Today.
                let comps = cal.dateComponents([.hour, .minute], from: d)
                if case .task = entry.kind, comps.hour != 17 || comps.minute != 0 {
                    return d.formatted(date: .omitted, time: .shortened)
                }
                return "Today"
            }
            if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
            if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow" }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
            if days < 0 { return "\(-days)d late" }
            if days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
            return d.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

// MARK: - Small helpers

enum TodayDates {
    static func tomorrow(_ now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    static func nextWeek(_ now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    static func tomorrowMorning(_ now: Date) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow(now)) ?? now
    }

    static func nextWeekMorning(_ now: Date) -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: nextWeek(now)) ?? now
    }
}

enum TodayColors {
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown, .mint, .cyan]

    /// Stable color per workspace name (same name → same dot everywhere).
    static func workspace(_ name: String) -> Color {
        var h: UInt32 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }
}
