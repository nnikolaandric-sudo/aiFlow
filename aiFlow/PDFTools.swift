import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PDF Tools
//
// Local PDF operations on PDFKit: combine PDFs and images, images → PDF,
// split, extract pages, rotate, compress, and make a scan searchable (PDFKit
// runs Vision OCR on-device while saving — nothing is uploaded).
//
// The original is never changed — every result is a new file next to the
// first input ("Ugovor (compressed).pdf"), the same rule as E-Sign.
// One window (PDFToolsWindowManager) serves the right-click menu, the ⌘K
// palette, Finder ▸ Services and the Shortcuts actions (AppIntents.swift).

enum PDFTool: String, CaseIterable, Identifiable {
    case combine, imagesToPDF, split, extractPages, rotate, compress, makeSearchable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combine: return "Combine into PDF"
        case .imagesToPDF: return "Images to PDF"
        case .split: return "Split into Pages"
        case .extractPages: return "Extract Pages"
        case .rotate: return "Rotate"
        case .compress: return "Compress PDF"
        case .makeSearchable: return "Make Searchable (OCR)"
        }
    }

    var symbol: String {
        switch self {
        case .combine: return "doc.on.doc"
        case .imagesToPDF: return "photo.on.rectangle"
        case .split: return "square.split.2x1"
        case .extractPages: return "doc.badge.plus"
        case .rotate: return "rotate.right"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .makeSearchable: return "text.viewfinder"
        }
    }

    var summary: String {
        switch self {
        case .combine: return "Merge PDFs and images into one PDF, in the order below."
        case .imagesToPDF: return "One page per image, fitted to A4 — photos, scans, receipts."
        case .split: return "Every page becomes its own PDF, in a new folder."
        case .extractPages: return "Copy the chosen pages into a new PDF."
        case .rotate: return "Turn every page and save a rotated copy."
        case .compress: return "Re-save the images as JPEG sized for screens — often a fraction of the size."
        case .makeSearchable: return "Recognize text on scanned pages on this Mac, so you can search and copy it."
        }
    }

    var actionTitle: String {
        switch self {
        case .combine: return "Combine"
        case .imagesToPDF: return "Create PDF"
        case .split: return "Split"
        case .extractPages: return "Extract"
        case .rotate: return "Rotate"
        case .compress: return "Compress"
        case .makeSearchable: return "Recognize Text"
        }
    }

    /// Combine/Images take a list the user can reorder; the rest one PDF.
    var takesManyInputs: Bool { self == .combine || self == .imagesToPDF }

    /// Whether the selection fits this tool — by type only (no file I/O:
    /// runs while a context menu is built).
    func accepts(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let pdfs = urls.filter(PDFToolsEngine.isPDF)
        let images = urls.filter(PDFToolsEngine.isImage)
        switch self {
        case .combine:
            return urls.count >= 2 && pdfs.count + images.count == urls.count && !pdfs.isEmpty
        case .imagesToPDF:
            return images.count == urls.count
        case .split, .extractPages, .rotate, .compress, .makeSearchable:
            return urls.count == 1 && pdfs.count == 1
        }
    }

    /// Best tool for a selection nobody picked a tool for (palette,
    /// Services): several files → combine, one image → PDF, one PDF → OCR.
    static func suggested(for urls: [URL]) -> PDFTool {
        if PDFTool.imagesToPDF.accepts(urls) { return .imagesToPDF }
        if PDFTool.combine.accepts(urls) { return .combine }
        return .makeSearchable
    }
}

enum PDFToolError: LocalizedError {
    case noInput
    case unreadable(String)
    case locked(String)
    case badRange(String)
    case notSmaller
    case writeFailed(String)
    case nothingRecognized

    var errorDescription: String? {
        switch self {
        case .noInput: return "Add at least one file."
        case .unreadable(let n): return "“\(n)” couldn't be read as a PDF or an image."
        case .locked(let n): return "“\(n)” is password-protected. Unlock it in Preview first."
        case .badRange(let why): return why
        case .notSmaller: return "This PDF is already compact — a compressed copy wouldn't be smaller, so nothing was saved."
        case .writeFailed(let n): return "Couldn't save “\(n)”. Check that the folder is writable."
        case .nothingRecognized: return "No text was found on the pages. The copy was not saved."
        }
    }
}

// MARK: - Engine (no UI; AppIntents and tests call it directly)

enum PDFToolsEngine {
    /// A4 in points — the page for an image, in the image's orientation.
    static let a4 = CGSize(width: 595, height: 842)

    static func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
    }

    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .pdf)
    }

    static func pageCount(_ url: URL) -> Int? {
        if isImage(url) { return 1 }
        return PDFDocument(url: url)?.pageCount
    }

    static func fileSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }

    // MARK: Output names

    /// "Ugovor.pdf" → "Ugovor (compressed)". Split names the folder.
    static func defaultOutputName(for tool: PDFTool, inputs: [URL], pages: String = "") -> String {
        guard let first = inputs.first else { return tool == .imagesToPDF ? "Images" : "Combined" }
        let stem = first.deletingPathExtension().lastPathComponent
        switch tool {
        case .combine: return "\(stem) (combined)"
        case .imagesToPDF: return inputs.count == 1 ? stem : "\(stem) (+\(inputs.count - 1))"
        case .split: return "\(stem) (pages)"
        case .extractPages:
            let p = pages.replacingOccurrences(of: " ", with: "")
            return p.isEmpty ? "\(stem) (pages)" : "\(stem) (pages \(p))"
        case .rotate: return "\(stem) (rotated)"
        case .compress: return "\(stem) (compressed)"
        case .makeSearchable: return "\(stem) (searchable)"
        }
    }

    /// Where a result lands: the first input's folder, never overwriting.
    static func outputURL(named name: String, beside input: URL, isFolder: Bool = false) -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = clean.isEmpty ? "Untitled" : clean
        let folder = input.deletingLastPathComponent()
        let desired = isFolder
            ? folder.appendingPathComponent(base, isDirectory: true)
            : folder.appendingPathComponent(base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf")
        return uniqueDestinationURL(for: desired, isFolder: isFolder)
    }

    // MARK: Reading

    private static func openPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFToolError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw PDFToolError.locked(url.lastPathComponent) }
        return doc
    }

    /// One PDF page for an image: A4 in the image's orientation, aspect-fit.
    private static func imagePage(_ url: URL) throws -> PDFPage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0,
              let rep = image.representations.first else {
            throw PDFToolError.unreadable(url.lastPathComponent)
        }
        // Orientation from the pixels (NSImage.size can carry odd DPI).
        let px = CGSize(width: rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) : image.size.width,
                        height: rep.pixelsHigh > 0 ? CGFloat(rep.pixelsHigh) : image.size.height)
        let landscape = px.width > px.height
        let box = CGRect(origin: .zero, size: landscape ? CGSize(width: a4.height, height: a4.width) : a4)
        guard let page = PDFPage(image: image, options: [
            .mediaBox: NSValue(rect: box),
            .upscaleIfSmaller: true,
            .compressionQuality: 0.85,
        ]) else { throw PDFToolError.unreadable(url.lastPathComponent) }
        return page
    }

    private static func write(_ doc: PDFDocument, to url: URL,
                              options: [PDFDocumentWriteOption: Any] = [:]) throws {
        let ok = options.isEmpty ? doc.write(to: url) : doc.write(to: url, withOptions: options)
        guard ok else {
            try? FileManager.default.removeItem(at: url)
            throw PDFToolError.writeFailed(url.lastPathComponent)
        }
    }

    // MARK: Operations

    /// PDFs and images, in the given order, into one PDF.
    @discardableResult
    static func combine(_ inputs: [URL], to output: URL,
                        progress: ((Int, Int) -> Void)? = nil) throws -> URL {
        guard !inputs.isEmpty else { throw PDFToolError.noInput }
        let out = PDFDocument()
        for (i, url) in inputs.enumerated() {
            progress?(i, inputs.count)
            if isImage(url) {
                out.insert(try imagePage(url), at: out.pageCount)
            } else {
                let doc = try openPDF(url)
                for p in 0..<doc.pageCount {
                    guard let page = doc.page(at: p)?.copy() as? PDFPage else { continue }
                    out.insert(page, at: out.pageCount)
                }
            }
        }
        guard out.pageCount > 0 else { throw PDFToolError.noInput }
        try write(out, to: output)
        return output
    }

    /// Every page to its own PDF inside `folder` (created here).
    static func split(_ pdf: URL, into folder: URL) throws -> [URL] {
        let doc = try openPDF(pdf)
        guard doc.pageCount > 0 else { throw PDFToolError.unreadable(pdf.lastPathComponent) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = pdf.deletingPathExtension().lastPathComponent
        let width = String(doc.pageCount).count
        var made: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let one = PDFDocument()
            one.insert(page, at: 0)
            let number = String(repeating: "0", count: max(0, width - String(i + 1).count)) + String(i + 1)
            let url = folder.appendingPathComponent("\(stem) - \(number).pdf")
            try write(one, to: url)
            made.append(url)
        }
        return made
    }

    /// "1-3, 5, 8-" → 0-based page indices in the order written (duplicates
    /// dropped). Throws a readable reason for anything out of range.
    static func parsePageRanges(_ text: String, pageCount: Int) throws -> [Int] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw PDFToolError.badRange("Type the pages to keep, e.g. 1-3, 5.") }
        var out: [Int] = []
        var seen = Set<Int>()
        for part in parts {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let lo: Int, hi: Int
            if bounds.count == 1, let n = Int(bounds[0]) {
                lo = n; hi = n
            } else if bounds.count == 2 {
                guard let a = bounds[0].isEmpty ? 1 : Int(bounds[0]),
                      let b = bounds[1].isEmpty ? pageCount : Int(bounds[1]) else {
                    throw PDFToolError.badRange("“\(part)” isn't a page range.")
                }
                lo = a; hi = b
            } else {
                throw PDFToolError.badRange("“\(part)” isn't a page number.")
            }
            guard lo >= 1, hi <= pageCount, lo <= hi else {
                throw PDFToolError.badRange("“\(part)” is outside 1–\(pageCount).")
            }
            for p in lo...hi where seen.insert(p - 1).inserted { out.append(p - 1) }
        }
        return out
    }

    @discardableResult
    static func extract(_ pdf: URL, pages: [Int], to output: URL) throws -> URL {
        let doc = try openPDF(pdf)
        let out = PDFDocument()
        for i in pages where i >= 0 && i < doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
        }
        guard out.pageCount > 0 else { throw PDFToolError.badRange("No pages to extract.") }
        try write(out, to: output)
        return output
    }

    /// `degrees`: 90 = clockwise, -90 = counter-clockwise, 180.
    @discardableResult
    static func rotate(_ pdf: URL, degrees: Int, to output: URL) throws -> URL {
        let doc = try openPDF(pdf)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        try write(doc, to: output)
        return output
    }

    /// JPEG images sized for screens. Throws `.notSmaller` (and leaves
    /// nothing behind) when that wouldn't save at least 5%.
    @discardableResult
    static func compress(_ pdf: URL, to output: URL) throws -> (before: Int64, after: Int64) {
        let doc = try openPDF(pdf)
        try write(doc, to: output, options: [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ])
        let before = fileSize(pdf), after = fileSize(output)
        if before > 0, after >= before * 95 / 100 {
            try? FileManager.default.removeItem(at: output)
            throw PDFToolError.notSmaller
        }
        return (before, after)
    }

    /// Pages without a text layer get one from PDFKit's on-device OCR
    /// (Vision, same as Live Text); pages that already have text, links and
    /// annotations are kept as they are. Returns how many pages were scans.
    @discardableResult
    static func makeSearchable(_ pdf: URL, to output: URL) throws -> (scannedPages: Int, pages: Int) {
        let doc = try openPDF(pdf)
        // A scan has no text layer at all; a cover page with one short
        // title does, and PDFKit leaves such pages alone anyway.
        let scanned = (0..<doc.pageCount).filter { i in
            (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        try write(doc, to: output, options: [.saveTextFromOCROption: true])
        // Verify on the saved copy: a scan with nothing readable (blank page,
        // photo) shouldn't leave a "(searchable)" file that isn't.
        if !scanned.isEmpty, let saved = PDFDocument(url: output) {
            let gained = scanned.contains { i in
                !(saved.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !gained {
                try? FileManager.default.removeItem(at: output)
                throw PDFToolError.nothingRecognized
            }
        }
        return (scanned.count, doc.pageCount)
    }
}

// MARK: - Window model

@MainActor
final class PDFToolsModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case done(message: String, outputs: [URL])
        case failed(String)
    }

    @Published var tool: PDFTool { didSet { if tool != oldValue { toolChanged() } } }
    @Published var inputs: [URL] { didSet { refreshDefaultName() } }
    @Published var outputName = ""
    @Published var pageRange = "" { didSet { if tool == .extractPages { refreshDefaultName() } } }
    @Published var rotation = 90
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pageCounts: [URL: Int] = [:]

    /// The user typed a name — tool/input changes stop overwriting it.
    var nameEdited = false
    private var lastDefaultName = ""

    init(tool: PDFTool, inputs: [URL]) {
        self.tool = tool
        self.inputs = inputs
        refreshDefaultName()
        loadPageCounts()
    }

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    var firstPDFPageCount: Int? { inputs.first.flatMap { pageCounts[$0] } }

    var canRun: Bool {
        guard !isRunning, !inputs.isEmpty else { return false }
        if tool.takesManyInputs {
            return tool == .imagesToPDF ? inputs.allSatisfy(PDFToolsEngine.isImage)
                : inputs.allSatisfy { PDFToolsEngine.isPDF($0) || PDFToolsEngine.isImage($0) }
        }
        guard inputs.count == 1, PDFToolsEngine.isPDF(inputs[0]) else { return false }
        if tool == .extractPages {
            return !pageRange.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// Why the action button is off, shown under the list.
    var inputHint: String? {
        if inputs.isEmpty { return "Add files to start." }
        if tool.takesManyInputs {
            if tool == .imagesToPDF, !inputs.allSatisfy(PDFToolsEngine.isImage) {
                return "Images to PDF takes images only — use Combine for PDFs."
            }
            return nil
        }
        if inputs.count != 1 || !PDFToolsEngine.isPDF(inputs[0]) { return "\(tool.title) works on one PDF." }
        return nil
    }

    func nameChanged(_ name: String) {
        outputName = name
        nameEdited = name != lastDefaultName
    }

    private func toolChanged() {
        phase = .idle
        if !tool.takesManyInputs, inputs.count > 1,
           let pdf = inputs.first(where: PDFToolsEngine.isPDF) {
            inputs = [pdf]
        }
        refreshDefaultName()
    }

    private func refreshDefaultName() {
        let name = PDFToolsEngine.defaultOutputName(for: tool, inputs: inputs, pages: pageRange)
        lastDefaultName = name
        if !nameEdited { outputName = name }
    }

    private func loadPageCounts() {
        let urls = inputs.filter { pageCounts[$0] == nil }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var counts: [URL: Int] = [:]
            for u in urls { counts[u] = PDFToolsEngine.pageCount(u) ?? 0 }
            await MainActor.run { [counts] in
                self.pageCounts.merge(counts) { _, new in new }
            }
        }
    }

    // MARK: List editing

    func move(from source: IndexSet, to destination: Int) {
        inputs.move(fromOffsets: source, toOffset: destination)
    }

    func moveUp(_ url: URL) {
        guard let i = inputs.firstIndex(of: url), i > 0 else { return }
        inputs.swapAt(i, i - 1)
    }

    func moveDown(_ url: URL) {
        guard let i = inputs.firstIndex(of: url), i < inputs.count - 1 else { return }
        inputs.swapAt(i, i + 1)
    }

    func remove(_ url: URL) {
        inputs.removeAll { $0 == url }
        if inputs.isEmpty { nameEdited = false }
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = tool.title
        panel.prompt = "Add"
        panel.allowsMultipleSelection = tool.takesManyInputs
        panel.canChooseDirectories = false
        panel.allowedContentTypes = tool == .imagesToPDF ? [.image]
            : tool.takesManyInputs ? [.pdf, .image] : [.pdf]
        if let dir = inputs.first?.deletingLastPathComponent() { panel.directoryURL = dir }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.filter { !inputs.contains($0) }
        if tool.takesManyInputs { inputs.append(contentsOf: picked) } else if let one = panel.urls.first { inputs = [one] }
        phase = .idle
        loadPageCounts()
    }

    // MARK: Run

    func run() {
        guard canRun else { return }
        let tool = self.tool, inputs = self.inputs, name = outputName
        let range = pageRange, degrees = rotation
        let count = firstPDFPageCount
        phase = .running(tool == .makeSearchable ? "Recognizing text on this Mac…" : "Working…")
        Task.detached(priority: .userInitiated) {
            let result: Phase
            do {
                result = try Self.perform(tool: tool, inputs: inputs, name: name,
                                          range: range, degrees: degrees, knownPageCount: count)
            } catch {
                result = .failed(error.localizedDescription)
            }
            await MainActor.run {
                self.phase = result
                if case .done(_, let outs) = result, let first = outs.first {
                    // Like E-Sign's signed copy: the browser refreshes and
                    // selects the result when its folder is on screen.
                    NotificationCenter.default.post(name: .ffRevealFile, object: first)
                }
            }
        }
    }

    nonisolated private static func perform(tool: PDFTool, inputs: [URL], name: String,
                                            range: String, degrees: Int, knownPageCount: Int?) throws -> Phase {
        guard let first = inputs.first else { throw PDFToolError.noInput }
        let fmt = ByteCountFormatter()
        switch tool {
        case .combine, .imagesToPDF:
            let out = PDFToolsEngine.outputURL(named: name, beside: first)
            try PDFToolsEngine.combine(inputs, to: out)
            let pages = PDFToolsEngine.pageCount(out) ?? 0
            return .done(message: "Saved “\(out.lastPathComponent)” — \(pages) page\(pages == 1 ? "" : "s"), \(fmt.string(fromByteCount: PDFToolsEngine.fileSize(out)))", outputs: [out])
        case .split:
            let folder = PDFToolsEngine.outputURL(named: name, beside: first, isFolder: true)
            let made = try PDFToolsEngine.split(first, into: folder)
            return .done(message: "Saved \(made.count) PDFs in “\(folder.lastPathComponent)”", outputs: [folder])
        case .extractPages:
            let total = knownPageCount ?? PDFToolsEngine.pageCount(first) ?? 0
            let pages = try PDFToolsEngine.parsePageRanges(range, pageCount: total)
            let out = PDFToolsEngine.outputURL(named: name, beside: first)
            try PDFToolsEngine.extract(first, pages: pages, to: out)
            return .done(message: "Saved “\(out.lastPathComponent)” — \(pages.count) of \(total) pages", outputs: [out])
        case .rotate:
            let out = PDFToolsEngine.outputURL(named: name, beside: first)
            try PDFToolsEngine.rotate(first, degrees: degrees, to: out)
            return .done(message: "Saved “\(out.lastPathComponent)”", outputs: [out])
        case .compress:
            let out = PDFToolsEngine.outputURL(named: name, beside: first)
            let (before, after) = try PDFToolsEngine.compress(first, to: out)
            let saved = before > 0 ? Int((Double(before - after) / Double(before) * 100).rounded()) : 0
            return .done(message: "Saved “\(out.lastPathComponent)” — \(fmt.string(fromByteCount: before)) → \(fmt.string(fromByteCount: after)) (−\(saved)%)", outputs: [out])
        case .makeSearchable:
            let out = PDFToolsEngine.outputURL(named: name, beside: first)
            let (scanned, pages) = try PDFToolsEngine.makeSearchable(first, to: out)
            let what = scanned == 0 ? "all \(pages) pages already had text"
                : "text recognized on \(scanned) of \(pages) page\(pages == 1 ? "" : "s")"
            return .done(message: "Saved “\(out.lastPathComponent)” — \(what)", outputs: [out])
        }
    }
}

// MARK: - Window

@MainActor
final class PDFToolsWindowManager: NSObject, NSWindowDelegate {
    static let shared = PDFToolsWindowManager()
    private var window: NSWindow?

    /// One PDF Tools window; opening again replaces what it works on.
    /// `tool` nil picks one from the selection (palette, Services).
    func open(tool: PDFTool?, urls: [URL]) {
        let files = urls.map(\.standardizedFileURL)
            .filter { PDFToolsEngine.isPDF($0) || PDFToolsEngine.isImage($0) }
        let model = PDFToolsModel(tool: tool ?? PDFTool.suggested(for: files), inputs: files)
        let root = PDFToolsView(model: model) { [weak self] in self?.window?.performClose(nil) }
        if let window {
            window.contentViewController = NSHostingController(rootView: root)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "PDF Tools"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 520, height: 470))
        window.minSize = NSSize(width: 460, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        window = nil
    }
}

struct PDFToolsView: View {
    @ObservedObject var model: PDFToolsModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider()
            fileList
            if let hint = model.inputHint {
                Text(hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 6)
            }
            options
                .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            footer
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 400)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.tool.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.tool.title).font(.headline)
                Text(model.tool.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("Tool", selection: $model.tool) {
                ForEach(PDFTool.allCases) { t in
                    Label(t.title, systemImage: t.symbol).tag(t)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isRunning)
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            if model.inputs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.tool.takesManyInputs ? "No files yet" : "No PDF yet")
                        .foregroundStyle(.secondary)
                    Button("Add Files…") { model.addFiles() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else {
                List {
                    ForEach(model.inputs, id: \.self) { url in
                        row(url)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
                HStack {
                    Button {
                        model.addFiles()
                    } label: {
                        Label(model.tool.takesManyInputs ? "Add Files…" : "Choose Another PDF…", systemImage: "plus")
                    }
                    .buttonStyle(.link)
                    .disabled(model.isRunning)
                    Spacer()
                    if model.tool.takesManyInputs, model.inputs.count > 1 {
                        Text("Drag to change the order")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 6)
            }
        }
        .frame(minHeight: 150)
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detail(url)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.tool.takesManyInputs, model.inputs.count > 1 {
                Button { model.moveUp(url) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).help("Move up")
                    .disabled(model.inputs.first == url || model.isRunning)
                Button { model.moveDown(url) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).help("Move down")
                    .disabled(model.inputs.last == url || model.isRunning)
            }
            Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from the list")
                .disabled(model.isRunning)
        }
        .padding(.vertical, 2)
    }

    private func detail(_ url: URL) -> String {
        var parts: [String] = []
        if PDFToolsEngine.isImage(url) {
            parts.append("Image")
        } else if let n = model.pageCounts[url] {
            parts.append(n == 0 ? "Can't read" : "\(n) page\(n == 1 ? "" : "s")")
        }
        parts.append(ByteCountFormatter().string(fromByteCount: PDFToolsEngine.fileSize(url)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.tool {
            case .extractPages:
                HStack {
                    Text("Pages").frame(width: 64, alignment: .leading)
                    TextField("e.g. 1-3, 5", text: $model.pageRange)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    if let n = model.firstPDFPageCount, n > 0 {
                        Text("of \(n)").foregroundStyle(.secondary)
                    }
                }
            case .rotate:
                HStack {
                    Text("Turn").frame(width: 64, alignment: .leading)
                    Picker("Turn", selection: $model.rotation) {
                        Label("Left", systemImage: "rotate.left").tag(-90)
                        Label("Right", systemImage: "rotate.right").tag(90)
                        Text("180°").tag(180)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            default:
                EmptyView()
            }
            HStack {
                Text(model.tool == .split ? "Folder" : "Save as").frame(width: 64, alignment: .leading)
                TextField("Name", text: Binding(get: { model.outputName },
                                                 set: { model.nameChanged($0) }))
                    .textFieldStyle(.roundedBorder)
                if model.tool != .split { Text(".pdf").foregroundStyle(.secondary) }
            }
            if let folder = model.inputs.first?.deletingLastPathComponent() {
                Text("In “\(folder.lastPathComponent)” — the original stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 72)
            }
        }
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .running(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .failed(let text):
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
        case .done(let text, _):
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase != .idle {
                status.frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            if case .done(_, let outputs) = model.phase, let first = outputs.first {
                Button("Show in aiFlow") { revealInBrowser(first) }
                Button("Open") { NSWorkspace.shared.open(first) }
            }
            if case .done = model.phase {
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                Button(model.tool.actionTitle) { model.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
            }
        }
    }

    /// Select the result in the browser and close (E-Sign's "Show").
    private func revealInBrowser(_ url: URL) {
        NotificationCenter.default.post(name: .ffRevealFile, object: url, userInfo: ["navigate": true])
        onClose()
    }
}

// MARK: - Right-click menu

/// "PDF Tools ▸" in the file context menu — only the tools that fit.
struct PDFToolsMenuItems: View {
    let urls: [URL]

    var body: some View {
        let tools = PDFTool.allCases.filter { $0.accepts(urls) }
        if !tools.isEmpty {
            Menu {
                ForEach(tools) { t in
                    Button { PDFToolsWindowManager.shared.open(tool: t, urls: urls) } label: {
                        Label(t.title + "…", systemImage: t.symbol)
                    }
                }
            } label: {
                Label("PDF Tools", systemImage: "doc.richtext")
            }
        }
    }
}

// MARK: - Finder ▸ Services

extension ESignServiceProvider {
    /// "Combine into PDF with aiFlow" (PDFs + images selected in Finder).
    @objc func combineIntoPDF(_ pboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = PDFServiceFiles.fileURLs(on: pboard)
            .filter { PDFToolsEngine.isPDF($0) || PDFToolsEngine.isImage($0) }
        guard !urls.isEmpty else {
            error.pointee = "Select PDFs or images to combine."
            return
        }
        let tool: PDFTool = urls.allSatisfy(PDFToolsEngine.isImage) ? .imagesToPDF : .combine
        Task { @MainActor in PDFToolsWindowManager.shared.open(tool: tool, urls: urls) }
    }

    /// "Make PDF Searchable with aiFlow".
    @objc func makePDFSearchable(_ pboard: NSPasteboard, userData: String,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let url = PDFServiceFiles.fileURLs(on: pboard).first(where: PDFToolsEngine.isPDF) else {
            error.pointee = "Select a PDF."
            return
        }
        Task { @MainActor in PDFToolsWindowManager.shared.open(tool: .makeSearchable, urls: [url]) }
    }
}

private enum PDFServiceFiles {
    static func fileURLs(on pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
