import AppIntents
import Foundation
import UniformTypeIdentifiers

// MARK: - Shortcuts, Spotlight & Siri (App Intents)
//
// aiFlow actions for the Shortcuts app (and Finder ▸ Quick Actions built
// from a shortcut): Open Today, Combine into PDF, Make PDF Searchable,
// Compress PDF, Sort Folder Now, Add Task. "Open Today" is also an App
// Shortcut, so Spotlight and Siri know it without any setup.
//
// Everything runs on this Mac through the same engines as the app (PDF
// Tools, Folder Rules, Workspace store). PDF actions return a new file and
// never touch their input.
//
// ⚠️ No Xcode on the build Mac: the metadata Shortcuts reads
// (Contents/Resources/Metadata.appintents) is written by
// tools/appintents/make_metadata.py, which build-local.sh runs after
// compiling. Adding/renaming an intent or a @Parameter here means updating
// INTENTS in that script too (names, titles and types must match).

struct AiFlowIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// Scratch space for files Shortcuts hands over (their bytes may not live
/// at a path we can read) and for results nobody asked to save anywhere.
enum IntentScratch {
    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiFlow-Shortcuts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A local copy of an IntentFile under its own name ("in" subfolder, so
    /// results with the same name never collide with inputs).
    static func materialize(_ file: IntentFile, index: Int, in dir: URL) throws -> URL {
        let inDir = dir.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        var name = file.filename.isEmpty ? "File \(index + 1)" : file.filename
        if (name as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let url = uniqueDestinationURL(for: inDir.appendingPathComponent(name))
        try file.data.write(to: url)
        return url
    }

    /// Output inside `dir` named after the user's name or the tool default.
    static func output(named name: String?, fallback: String, in dir: URL) -> URL {
        var base = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = fallback }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if !base.lowercased().hasSuffix(".pdf") { base += ".pdf" }
        return dir.appendingPathComponent(base)
    }

    static func pdfResult(_ url: URL) -> IntentFile {
        IntentFile(fileURL: url, filename: url.lastPathComponent, type: .pdf)
    }

    /// Real path for actions that must act in place (folders, workspace).
    static func localURL(_ file: IntentFile, what: String) throws -> URL {
        guard let url = file.fileURL, url.isFileURL else {
            throw AiFlowIntentError(message: "Choose a \(what) on this Mac.")
        }
        return url.standardizedFileURL
    }
}

// MARK: Open Today

struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Shows what needs you today in aiFlow: tasks, reminders, reviews, mail waiting and what Folder Rules sorted.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        TodayWindowManager.shared.open()
        return .result()
    }
}

// MARK: PDF

struct CombinePDFsIntent: AppIntent {
    static let title: LocalizedStringResource = "Combine into PDF"
    static let description = IntentDescription("Combines PDFs and images, in the order given, into one PDF. Runs on this Mac.")

    @Parameter(title: "Files", description: "PDFs and images, in order.",
               supportedTypeIdentifiers: ["com.adobe.pdf", "public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "File Name", description: "Name of the new PDF (optional).")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Combine \(\.$files) into PDF") { \.$name }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard !files.isEmpty else { throw AiFlowIntentError(message: "Add PDFs or images to combine.") }
        let dir = try IntentScratch.makeDir()
        let inputs = try files.enumerated().map { try IntentScratch.materialize($1, index: $0, in: dir) }
        let tool: PDFTool = inputs.allSatisfy(PDFToolsEngine.isImage) ? .imagesToPDF : .combine
        let out = IntentScratch.output(named: name,
                                       fallback: PDFToolsEngine.defaultOutputName(for: tool, inputs: inputs), in: dir)
        try PDFToolsEngine.combine(inputs, to: out)
        return .result(value: IntentScratch.pdfResult(out))
    }
}

struct MakePDFSearchableIntent: AppIntent {
    static let title: LocalizedStringResource = "Make PDF Searchable"
    static let description = IntentDescription("Recognizes text on scanned pages on this Mac (nothing is uploaded) and returns a searchable copy.")

    @Parameter(title: "PDF", supportedTypeIdentifiers: ["com.adobe.pdf"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$file) searchable")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let dir = try IntentScratch.makeDir()
        let input = try IntentScratch.materialize(file, index: 0, in: dir)
        let out = IntentScratch.output(named: nil,
                                       fallback: PDFToolsEngine.defaultOutputName(for: .makeSearchable, inputs: [input]), in: dir)
        try PDFToolsEngine.makeSearchable(input, to: out)
        return .result(value: IntentScratch.pdfResult(out))
    }
}

struct CompressPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress PDF"
    static let description = IntentDescription("Re-saves the PDF's images as JPEG sized for screens. Returns the original when it can't get smaller.")

    @Parameter(title: "PDF", supportedTypeIdentifiers: ["com.adobe.pdf"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$file)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let dir = try IntentScratch.makeDir()
        let input = try IntentScratch.materialize(file, index: 0, in: dir)
        let out = IntentScratch.output(named: nil,
                                       fallback: PDFToolsEngine.defaultOutputName(for: .compress, inputs: [input]), in: dir)
        do {
            try PDFToolsEngine.compress(input, to: out)
        } catch PDFToolError.notSmaller {
            // In a shortcut, "already small" isn't a failure: pass it on.
            return .result(value: IntentScratch.pdfResult(input))
        }
        return .result(value: IntentScratch.pdfResult(out))
    }
}

// MARK: Folder Rules

struct SortFolderNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sort Folder Now"
    static let description = IntentDescription("Applies the folder's aiFlow auto-sort rules to every file in it now, like Preview ▸ Sort N Files. Moves are undoable in Today and the Folder Rules window.")

    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Sort \(\.$folder) now")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = try IntentScratch.localURL(folder, what: "folder")
        let service = FolderRulesService.shared
        guard let watched = service.folder(for: url), watched.enabled else {
            throw AiFlowIntentError(message: "“\(url.lastPathComponent)” has no auto-sort rules. In aiFlow, right-click it ▸ Auto-Sort This Folder.")
        }
        let path = watched.path
        let plan: [FolderRulePlanItem] = await withCheckedContinuation { cont in
            service.preview(path) { plan, _ in cont.resume(returning: plan) }
        }
        guard !plan.isEmpty else { return .result(value: "Nothing to sort in “\(url.lastPathComponent)”.") }
        let (done, errors): (Int, [String]) = await withCheckedContinuation { cont in
            service.apply(plan, in: path) { n, errs in cont.resume(returning: (n, errs)) }
        }
        var text = "Sorted \(done) file\(done == 1 ? "" : "s") in “\(url.lastPathComponent)”."
        if let first = errors.first { text += " \(errors.count) couldn't be moved: \(first)" }
        return .result(value: text)
    }
}

// MARK: Workspace

struct AddWorkspaceTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to the aiFlow workspace of a file or folder, linked to that file. A folder that isn't a workspace yet becomes one.")

    @Parameter(title: "Task")
    var taskTitle: String

    @Parameter(title: "File or Folder", supportedTypeIdentifiers: ["public.item"])
    var file: IntentFile

    @Parameter(title: "Due Date")
    var dueDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Add task \(\.$taskTitle) to \(\.$file)") { \.$dueDate }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AiFlowIntentError(message: "Give the task a title.") }
        let url = try IntentScratch.localURL(file, what: "file or folder")
        guard let target = WorkspaceComposer.resolve(for: url) else {
            throw AiFlowIntentError(message: "“\(url.lastPathComponent)” can't hold a workspace.")
        }
        WorkspaceStore.shared.addTask(to: target.workspaceID,
                                      WorkspaceTask(title: title, dueDate: dueDate, linkedFile: target.relative))
        let ws = WorkspaceStore.shared.workspaces.first { $0.id == target.workspaceID }?.name ?? target.fileName
        return .result(value: "Added “\(title)” to \(ws).")
    }
}

// MARK: App Shortcuts (Spotlight, Siri — no setup)

struct AiFlowAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenTodayIntent(),
                    phrases: [
                        "Open Today in \(.applicationName)",
                        "What's due in \(.applicationName)",
                        "Show my \(.applicationName) day",
                    ],
                    shortTitle: "Today",
                    systemImageName: "sun.max")
    }
}
