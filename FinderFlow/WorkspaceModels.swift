import Foundation

// MARK: - Workspace composer notifications
//
// Right-click on any file → task/reminder auto-linked to it. userInfo:
// workspaceID, root, relative?, name. ContentView presents the sheet.
// Defined here (Foundation-only) so headless tests cover the composer too.
extension Notification.Name {
    static let ffComposeTask     = Notification.Name("FF.composeTask")
    static let ffComposeReminder = Notification.Name("FF.composeReminder")
}

// MARK: - Workspace Mode models (PRD §2–§17, MVP list §17)
//
// A Workspace is a project layer attached to an existing folder. The left
// side of the app stays a plain file browser; the right Preview/Inspector
// panel shows the work around the selected folder or file.
//
// Persistence: WorkspaceStore keeps `[Workspace]` as JSON under
// Application Support/FinderFlow/Workspaces (see WorkspaceStore.swift).
// File references inside a workspace are stored as paths RELATIVE to the
// workspace root so renames of parent folders don't silently break links.

// MARK: - Task

enum WorkspaceTaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo = "todo"
    case inProgress = "in_progress"
    case waiting = "waiting"
    case done = "done"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .waiting: return "Waiting"
        case .done: return "Done"
        }
    }

    var isOpen: Bool { self != .done }

    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.dotted"
        case .waiting: return "clock"
        case .done: return "checkmark.circle.fill"
        }
    }
}

enum WorkspacePriority: String, Codable, CaseIterable, Identifiable {
    case low, normal, high, urgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }
}

struct WorkspaceTask: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var dueDate: Date?
    var assignee: String?
    var priority: WorkspacePriority
    var status: WorkspaceTaskStatus
    /// Relative path (to workspace root) of the linked file, if this is a
    /// file task (§4). Nil = workspace-level task.
    var linkedFile: String?
    var notes: String?
    var createdAt: Date
    var doneAt: Date?

    init(id: String = UUID().uuidString,
         title: String,
         dueDate: Date? = nil,
         assignee: String? = nil,
         priority: WorkspacePriority = .normal,
         status: WorkspaceTaskStatus = .todo,
         linkedFile: String? = nil,
         notes: String? = nil,
         createdAt: Date = Date(),
         doneAt: Date? = nil) {
        self.id = id; self.title = title; self.dueDate = dueDate
        self.assignee = assignee; self.priority = priority; self.status = status
        self.linkedFile = linkedFile; self.notes = notes
        self.createdAt = createdAt; self.doneAt = doneAt
    }

    var isOverdue: Bool {
        guard status.isOpen, let due = dueDate else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let due = dueDate else { return false }
        return Calendar.current.isDateInToday(due)
    }
}

// MARK: - Review (§7)

enum WorkspaceReviewStatus: String, Codable, CaseIterable, Identifiable {
    case draft, review, approved, signed, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draft: return "Draft"
        case .review: return "Review"
        case .approved: return "Approved"
        case .signed: return "Signed"
        case .archived: return "Archived"
        }
    }

    /// Badge state for the file list: reviewed/approved files get ✓.
    var isEndorsed: Bool { self == .approved || self == .signed }
}

struct WorkspaceFileReview: Codable, Equatable {
    var status: WorkspaceReviewStatus
    var reviewer: String?
    var reviewDate: Date?
    var nextReviewDate: Date?
    var comment: String?

    init(status: WorkspaceReviewStatus = .draft,
         reviewer: String? = nil,
         reviewDate: Date? = nil,
         nextReviewDate: Date? = nil,
         comment: String? = nil) {
        self.status = status; self.reviewer = reviewer
        self.reviewDate = reviewDate; self.nextReviewDate = nextReviewDate
        self.comment = comment
    }
}

// MARK: - Validity / expiry (§8)

struct WorkspaceFileValidity: Codable, Equatable {
    var expiresAt: Date?
    var remindDaysBefore: [Int]
    var noLongerRequired: Bool

    init(expiresAt: Date? = nil,
         remindDaysBefore: [Int] = [30, 7, 1],
         noLongerRequired: Bool = false) {
        self.expiresAt = expiresAt
        self.remindDaysBefore = remindDaysBefore
        self.noLongerRequired = noLongerRequired
    }

    /// Days until expiry (negative = overdue). Nil when no date set.
    func daysUntil(_ now: Date = Date()) -> Int? {
        guard let exp = expiresAt else { return nil }
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.startOfDay(for: exp)
        return Calendar.current.dateComponents([.day], from: start, to: end).day
    }
}

// MARK: - Relations (§10)

enum WorkspaceRelationKind: String, Codable, CaseIterable, Identifiable {
    case related, replaces, previousVersion, attachment, supporting, generatedFrom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .related: return "Related to"
        case .replaces: return "Replaces"
        case .previousVersion: return "Previous version"
        case .attachment: return "Attachment"
        case .supporting: return "Supporting document"
        case .generatedFrom: return "Generated from"
        }
    }
}

struct WorkspaceRelation: Identifiable, Codable, Equatable {
    var id: String
    /// Relative path (to workspace root) of the connected document.
    var target: String
    var kind: WorkspaceRelationKind

    init(id: String = UUID().uuidString, target: String, kind: WorkspaceRelationKind = .related) {
        self.id = id; self.target = target; self.kind = kind
    }
}

// MARK: - Per-file metadata (§6–§11)

struct WorkspaceFileMeta: Codable, Equatable {
    var review: WorkspaceFileReview?
    var validity: WorkspaceFileValidity?
    /// Short internal note — plain text / Markdown, not a full editor (§11).
    var note: String?
    var noteUpdatedAt: Date?
    var relations: [WorkspaceRelation]

    init(review: WorkspaceFileReview? = nil,
         validity: WorkspaceFileValidity? = nil,
         note: String? = nil,
         noteUpdatedAt: Date? = nil,
         relations: [WorkspaceRelation] = []) {
        self.review = review; self.validity = validity
        self.note = note; self.noteUpdatedAt = noteUpdatedAt
        self.relations = relations
    }

    var isEmpty: Bool {
        review == nil && validity == nil
            && (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && relations.isEmpty
    }
}

// MARK: - File request (§2 quick action, §15 "requested document not received")

struct WorkspaceFileRequest: Identifiable, Codable, Equatable {
    var id: String
    var fileName: String
    var requestedFrom: String?
    var dueDate: Date?
    var received: Bool
    var createdAt: Date

    init(id: String = UUID().uuidString,
         fileName: String,
         requestedFrom: String? = nil,
         dueDate: Date? = nil,
         received: Bool = false,
         createdAt: Date = Date()) {
        self.id = id; self.fileName = fileName; self.requestedFrom = requestedFrom
        self.dueDate = dueDate; self.received = received; self.createdAt = createdAt
    }
}

// MARK: - Activity (§10 log, §15 recent activity)

struct WorkspaceActivity: Identifiable, Codable, Equatable {
    var id: String
    var date: Date
    var message: String
    /// Optional relative path of the file this event is about.
    var fileRelative: String?

    init(id: String = UUID().uuidString, date: Date = Date(), message: String, fileRelative: String? = nil) {
        self.id = id; self.date = date; self.message = message; self.fileRelative = fileRelative
    }
}

// MARK: - Reminder (Mac notification at an exact time, optionally on a document)

/// Unlike a task (work with a status), a reminder is a nudge: at `fireAt`
/// macOS shows a notification even if FinderFlow is in the background.
/// `linkedFile` (relative to the workspace root) ties it to a document —
/// created from a file it is filled automatically.
struct WorkspaceReminder: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var fireAt: Date
    /// Relative path (to workspace root) of the document, if any.
    /// Nil = workspace-level reminder.
    var linkedFile: String?
    var notes: String?
    var done: Bool
    var createdAt: Date

    init(id: String = UUID().uuidString,
         title: String,
         fireAt: Date,
         linkedFile: String? = nil,
         notes: String? = nil,
         done: Bool = false,
         createdAt: Date = Date()) {
        self.id = id; self.title = title; self.fireAt = fireAt
        self.linkedFile = linkedFile; self.notes = notes
        self.done = done; self.createdAt = createdAt
    }

    var isOverdue: Bool {
        !done && fireAt < Date()
    }
}

// MARK: - Workspace root

struct Workspace: Identifiable, Codable, Equatable {
    var id: String
    /// Canonical absolute path of the workspace root folder.
    var rootPath: String
    var name: String
    /// Free-form status. Ships with Active/Archived presets but users can
    /// add their own (PRD §3: "NEKA SE MOGU DODAVATI I NOVI").
    var status: String
    var owner: String?
    var deadline: Date?
    var createdAt: Date
    var tasks: [WorkspaceTask]
    /// Keyed by path relative to root (e.g. "Agreement.pdf", "docs/NDA.pdf").
    var files: [String: WorkspaceFileMeta]
    var fileRequests: [WorkspaceFileRequest]
    var reminders: [WorkspaceReminder]
    var activity: [WorkspaceActivity]

    static let defaultStatuses = ["Active", "On Hold", "Archived"]

    enum CodingKeys: String, CodingKey {
        case id, rootPath, name, status, owner, deadline, createdAt
        case tasks, files, fileRequests, reminders, activity
    }

    init(id: String = UUID().uuidString,
         rootPath: String,
         name: String,
         status: String = "Active",
         owner: String? = nil,
         deadline: Date? = nil,
         createdAt: Date = Date(),
         tasks: [WorkspaceTask] = [],
         files: [String: WorkspaceFileMeta] = [:],
         fileRequests: [WorkspaceFileRequest] = [],
         reminders: [WorkspaceReminder] = [],
         activity: [WorkspaceActivity] = []) {
        self.id = id; self.rootPath = rootPath; self.name = name
        self.status = status; self.owner = owner; self.deadline = deadline
        self.createdAt = createdAt; self.tasks = tasks; self.files = files
        self.fileRequests = fileRequests; self.reminders = reminders
        self.activity = activity
    }

    /// Forward-compatible decode: stores written before `reminders` existed
    /// (or any future field) still load instead of wiping the workspace.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        rootPath = try c.decode(String.self, forKey: .rootPath)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: rootPath).lastPathComponent
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "Active"
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        tasks = try c.decodeIfPresent([WorkspaceTask].self, forKey: .tasks) ?? []
        files = try c.decodeIfPresent([String: WorkspaceFileMeta].self, forKey: .files) ?? [:]
        fileRequests = try c.decodeIfPresent([WorkspaceFileRequest].self, forKey: .fileRequests) ?? []
        reminders = try c.decodeIfPresent([WorkspaceReminder].self, forKey: .reminders) ?? []
        activity = try c.decodeIfPresent([WorkspaceActivity].self, forKey: .activity) ?? []
    }

    var openTasks: [WorkspaceTask] { tasks.filter { $0.status.isOpen } }
    var overdueTasks: [WorkspaceTask] { tasks.filter { $0.isOverdue } }
    var pendingRequests: [WorkspaceFileRequest] { fileRequests.filter { !$0.received } }
    var activeReminders: [WorkspaceReminder] { reminders.filter { !$0.done } }

    func remindersForFile(relative: String) -> [WorkspaceReminder] {
        reminders.filter { $0.linkedFile == relative }
            .sorted { $0.fireAt < $1.fireAt }
    }

    func tasksForFile(relative: String) -> [WorkspaceTask] {
        tasks.filter { $0.linkedFile == relative }
    }

    func openTasksForFile(relative: String) -> [WorkspaceTask] {
        tasks.filter { $0.linkedFile == relative && $0.status.isOpen }
    }
}
