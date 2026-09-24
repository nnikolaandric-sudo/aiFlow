import SwiftUI
import AppKit
import PDFKit

// MARK: - E-Sign window
//
// One window per document: the PDF in a PDFView, saved signatures and quick
// fields in a sidebar. A placement is a custom PDFAnnotation, so PDFKit keeps
// it glued to the page through scrolling and zooming; drag moves it, the
// corner handle resizes it, ⌫ removes it. "Save Signed Copy" never touches
// the original — it writes "<name> (signed).pdf" next to it.

extension Notification.Name {
    /// object: file URL to select in the browser once it's listed.
    /// userInfo["navigate"] == true also opens the file's folder.
    static let ffRevealFile = Notification.Name("FF.revealFile")
    /// File ▸ Sign Document…: object is an `ESignMenuRequest`; a browser
    /// window answers with its selection (or a picker in its folder).
    static let ffESignSelection = Notification.Name("FF.eSignSelection")
}

final class ESignMenuRequest {
    var handled = false
}

@MainActor
final class ESignWindowManager: NSObject, NSWindowDelegate {
    static let shared = ESignWindowManager()

    private var sessions: [ObjectIdentifier: (window: NSWindow, session: ESignSession)] = [:]

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        guard ESignSource.canSign(url) else {
            NSSound.beep()
            return
        }
        if let existing = sessions.values.first(where: { $0.session.sourceURL == url }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let session = ESignSession(sourceURL: url)
        let window = NSWindow(contentViewController: NSHostingController(rootView: ESignWindowView(session: session)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Sign — \(url.lastPathComponent)"
        window.representedURL = url
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1120, height: 800))
        window.minSize = NSSize(width: 800, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        sessions[ObjectIdentifier(window)] = (window, session)
        session.onClose = { [weak window] in window?.performClose(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.load()
    }

    /// Several files at once (multi-selection): one window each, at most 10.
    func open(_ urls: [URL]) {
        for url in urls.filter(ESignSource.canSign).prefix(10) { open(url) }
    }

    /// Menu / toolbar title for signing `urls` out of `total` selected items.
    static func signTitle(for urls: [URL], ofTotal total: Int) -> String {
        if urls.count > 1 { return "Sign \(min(urls.count, 10)) Documents…" }
        if total > 1, let only = urls.first { return "Sign “\(only.lastPathComponent)”…" }
        return "Sign…"
    }

    func openPanel(in directory: URL?) {
        let panel = NSOpenPanel()
        panel.title = "Sign a Document"
        panel.message = "Choose a PDF, a Word / RTF document, or a photo or scan to sign."
        panel.prompt = "Sign"
        panel.allowedContentTypes = ESignSource.signableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let directory { panel.directoryURL = directory }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// File ▸ Sign Document…: the browser's selection if it has a PDF or
    /// image, otherwise a file picker.
    func signFromMenu() {
        let request = ESignMenuRequest()
        NotificationCenter.default.post(name: .ffESignSelection, object: request)
        if !request.handled { openPanel(in: nil) }
    }

    /// ⌘Q skips windowShouldClose, so the app delegate asks here first.
    /// Returns false when the user wants to keep working.
    func confirmQuitDiscardingPlacements() -> Bool {
        guard let entry = sessions.values.first(where: { $0.session.hasUnsavedPlacements }) else { return true }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit without saving the signed copy?"
        alert.informativeText = "The signatures placed on “\(entry.session.sourceURL.lastPathComponent)” haven't been saved yet. The original file is never changed."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session = sessions[ObjectIdentifier(sender)]?.session, session.hasUnsavedPlacements else { return true }
        let alert = NSAlert()
        alert.messageText = "Close without saving a signed copy?"
        alert.informativeText = "The signatures placed on “\(session.sourceURL.lastPathComponent)” will be discarded. The original file is never changed."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak sender] response in
            guard response == .alertFirstButtonReturn else { return }
            session.discardChanges()
            sender?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        sessions[ObjectIdentifier(window)]?.session.tearDown()
        sessions[ObjectIdentifier(window)] = nil
    }
}

// MARK: - Session (one document)

@MainActor
final class ESignSession: ObservableObject {
    enum Phase: Equatable {
        case loading
        case needsPassword(wrongAttempt: Bool)
        case ready
        case failed(String)
    }

    struct SavedCopy: Equatable {
        let url: URL
        let sealed: Bool
    }

    let sourceURL: URL
    let pdfView = ESignPDFView()

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var placementCount = 0
    @Published private(set) var hasSelection = false
    @Published private(set) var pageLabel = ""
    @Published private(set) var existingSeal: ESignSeal.Verdict?
    /// Set when the source isn't a PDF (Word / RTF / image) — shown as a note.
    @Published private(set) var conversionNote: String?
    @Published private(set) var isSaving = false
    @Published private(set) var saveProgress = 0.0
    @Published private(set) var savedCopy: SavedCopy?
    @Published var errorMessage: String?
    @Published var showCreator = false

    var onClose: (() -> Void)?
    private var document: PDFDocument?
    private var password: String?
    private var dirty = false

    var hasUnsavedPlacements: Bool { dirty && placementCount > 0 }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        pdfView.session = self
    }

    func load() {
        phase = .loading
        let url = sourceURL
        if ESignSource.isPDF(url) {
            guard let document = PDFDocument(url: url) else {
                phase = .failed(ESignError.unreadable(url.lastPathComponent).localizedDescription)
                return
            }
            open(document)
            Task { [weak self] in
                let verdict = await Task.detached(priority: .utility) { ESignSeal.verify(fileAt: url) }.value
                if case .unsealed = verdict { return }
                self?.existingSeal = verdict
            }
        } else if ESignSource.isTextDocument(url) {
            conversionNote = "Converted from “\(url.lastPathComponent)” — check the layout on every page before signing (page breaks and headers aren't carried over). The signed copy is a PDF; the original stays as it is."
            Task { [weak self] in
                await Task.yield()   // let the spinner show; layout runs on the main thread
                do {
                    let data = try ESignSource.pdfData(fromTextDocumentAt: url)
                    guard let self else { return }
                    if let document = PDFDocument(data: data) {
                        self.open(document)
                    } else {
                        self.phase = .failed(ESignError.unreadable(url.lastPathComponent).localizedDescription)
                    }
                } catch {
                    self?.phase = .failed(error.localizedDescription)
                }
            }
        } else {
            conversionNote = "The image is placed on a PDF page; the signed copy is a PDF."
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try ESignSource.pdfData(fromImageAt: url) }
                }.value
                guard let self else { return }
                switch result {
                case .success(let data):
                    if let document = PDFDocument(data: data) {
                        self.open(document)
                    } else {
                        self.phase = .failed(ESignError.unreadable(url.lastPathComponent).localizedDescription)
                    }
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func open(_ document: PDFDocument) {
        self.document = document
        if document.isLocked {
            phase = .needsPassword(wrongAttempt: false)
        } else {
            present(document)
        }
    }

    func unlock(with password: String) {
        guard let document else { return }
        if document.unlock(withPassword: password) {
            self.password = password
            present(document)
        } else {
            phase = .needsPassword(wrongAttempt: true)
        }
    }

    private func present(_ document: PDFDocument) {
        guard document.allowsDocumentChanges || document.allowsCommenting else {
            phase = .failed(ESignError.restricted.localizedDescription)
            return
        }
        pdfView.document = document
        phase = .ready
        pageChanged()
    }

    // MARK: Placing

    func place(_ artwork: SignatureArtwork) {
        guard phase == .ready, let drawable = SignatureLibrary.shared.drawable(for: artwork) else {
            NSSound.beep()
            return
        }
        pdfView.placeNew(drawable, visualWidth: 170)
    }

    func placeText(_ text: String, pointSize: CGFloat = 11) {
        guard phase == .ready,
              let drawable = ESignDrawable.text(text, font: .systemFont(ofSize: pointSize),
                                                color: NSColor.black.cgColor, tight: false)
        else { return }
        pdfView.placeNew(drawable, visualWidth: drawable.contentBounds.width)
    }

    func placeDate() { placeText(Date().formatted(date: .numeric, time: .omitted)) }
    func placeName() { placeText(ESignDefaults.signerName) }
    func placeCheckmark() { placeText("✓", pointSize: 16) }

    func promptForText() {
        guard phase == .ready, let window = pdfView.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Text"
        alert.informativeText = "A line of text for the page — a place, a title or initials."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Text"
        alert.accessoryView = field
        alert.addButton(withTitle: "Place")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.placeText(field.stringValue)
        }
    }

    func removeSelected() { pdfView.removeSelection() }
    func placeSelectionOnEveryPage() { pdfView.placeSelectionOnAllPages() }
    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }

    // Callbacks from the PDF view.

    func placementsChanged() {
        placementCount = pdfView.placementCount
        dirty = true
        savedCopy = nil
    }

    func selectionChanged() {
        hasSelection = pdfView.hasSelection
    }

    func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else {
            pageLabel = ""
            return
        }
        pageLabel = "Page \(document.index(for: page) + 1) of \(document.pageCount)"
    }

    // MARK: Saving

    func save(chooseLocation: Bool = false) {
        guard phase == .ready, let document, !isSaving else { return }
        guard pdfView.placementCount > 0 else {
            errorMessage = "Place a signature on the document first."
            return
        }
        var destination = ESignSource.signedCopyURL(for: sourceURL)
        if chooseLocation {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.directoryURL = destination.deletingLastPathComponent()
            panel.nameFieldStringValue = destination.lastPathComponent
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard url.standardizedFileURL != sourceURL.standardizedFileURL else {
                errorMessage = "Choose another name — the original file always stays untouched."
                return
            }
            destination = url
        }

        let placements = pdfView.snapshotPlacements()
        // Serialize what the viewer shows (form fields typed in here included),
        // minus our own placements, which are burned in separately.
        guard let baseData = pdfView.withPlacementsDetached({ document.dataRepresentation() }) else {
            errorMessage = "The document couldn't be read for signing."
            return
        }
        let info = ESignDocumentSigner.DocumentInfo(document.documentAttributes)
        let seal = ESignDefaults.addSeal
            ? ESignDocumentSigner.SealRequest(signer: ESignDefaults.signerName, email: ESignDefaults.signerEmail,
                                              source: sourceURL.lastPathComponent)
            : nil
        let password = self.password
        isSaving = true
        saveProgress = 0
        errorMessage = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ESignDocumentSigner.signAndWrite(
                        baseData: baseData, password: password, info: info, placements: placements,
                        seal: seal, to: destination
                    ) { value in
                        Task { @MainActor in self?.saveProgress = value }
                    }
                }
            }.value
            self?.finishSave(result, destination: destination)
        }
    }

    private func finishSave(_ result: Result<ESignSeal.Payload?, Error>, destination: URL) {
        isSaving = false
        switch result {
        case .success(let payload):
            dirty = false
            savedCopy = SavedCopy(url: destination, sealed: payload != nil)
            NotificationCenter.default.post(name: .refreshDirectory, object: destination.deletingLastPathComponent())
            NotificationCenter.default.post(name: .ffRevealFile, object: destination)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func openSavedCopy() {
        guard let url = savedCopy?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Select the signed copy in the browser and close this window.
    func revealSavedCopy() {
        guard let url = savedCopy?.url else { return }
        NotificationCenter.default.post(name: .ffRevealFile, object: url, userInfo: ["navigate": true])
        onClose?()
    }

    func discardChanges() { dirty = false }

    func tearDown() {
        pdfView.session = nil
        pdfView.document = nil
    }
}

// MARK: - Placement annotation

enum ESignHandle { case body, resize, delete }

/// A signature / field on a page. Drawn by PDFKit (possibly on a background
/// render thread), so geometry and chrome state sit behind a lock. Never
/// written into a file itself: saving burns a snapshot into a new PDF.
final class ESignPlacementAnnotation: PDFAnnotation {
    let drawable: ESignDrawable
    let quarterTurns: Int

    private struct Chrome {
        var selected = false
        /// Page units per screen point (1 / zoom), so handles keep their size.
        var unit: CGFloat = 1
        var accent: CGColor = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
    }

    private let lock = NSLock()
    private var center_: CGPoint
    private var visualSize_: CGSize
    private var chrome = Chrome()

    init(drawable: ESignDrawable, center: CGPoint, visualSize: CGSize, quarterTurns: Int) {
        self.drawable = drawable
        self.quarterTurns = quarterTurns
        center_ = center
        visualSize_ = visualSize
        super.init(bounds: ESignGeometry.pageBounds(center: center, visualSize: visualSize, quarterTurns: quarterTurns),
                   forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    var center: CGPoint {
        lock.lock(); defer { lock.unlock() }
        return center_
    }

    var visualSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return visualSize_
    }

    /// The art's box in page space (without selection chrome).
    var pageRect: CGRect {
        ESignGeometry.pageBounds(center: center, visualSize: visualSize, quarterTurns: quarterTurns)
    }

    func setGeometry(center: CGPoint, visualSize: CGSize) {
        lock.lock()
        center_ = center
        visualSize_ = visualSize
        lock.unlock()
        syncBounds()
    }

    func setChrome(selected: Bool, unit: CGFloat, accent: CGColor) {
        lock.lock()
        chrome = Chrome(selected: selected, unit: unit, accent: accent)
        lock.unlock()
        syncBounds()
    }

    /// Bounds grow while selected so PDFKit repaints the handles too.
    private func syncBounds() {
        lock.lock()
        let box = ESignGeometry.pageBounds(center: center_, visualSize: visualSize_, quarterTurns: quarterTurns)
        let outset = chrome.selected ? 14 * chrome.unit : 0
        lock.unlock()
        bounds = box.insetBy(dx: -outset, dy: -outset)
    }

    func hitZone(_ point: CGPoint, tolerance: CGFloat) -> ESignHandle? {
        lock.lock()
        let center = center_, size = visualSize_, chrome = self.chrome
        lock.unlock()
        let v = ESignGeometry.toVisual(CGPoint(x: point.x - center.x, y: point.y - center.y), quarterTurns: quarterTurns)
        let halfW = size.width / 2 + 3 * chrome.unit, halfH = size.height / 2 + 3 * chrome.unit
        if chrome.selected {
            if hypot(v.x - halfW, v.y + halfH) <= tolerance { return .resize }
            if hypot(v.x - halfW, v.y - halfH) <= tolerance { return .delete }
        }
        return abs(v.x) <= halfW && abs(v.y) <= halfH ? .body : nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        lock.lock()
        let center = center_, size = visualSize_, chrome = self.chrome
        lock.unlock()
        ESignRenderer.draw(drawable, center: center, visualSize: size, quarterTurns: quarterTurns, in: context)
        guard chrome.selected else { return }

        // Selection chrome in the upright (visual) frame: dashed box,
        // resize handle bottom-right, remove button top-right.
        let u = chrome.unit
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        if quarterTurns % 4 != 0 { context.rotate(by: CGFloat(quarterTurns % 4) * .pi / 2) }
        let frame = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            .insetBy(dx: -3 * u, dy: -3 * u)
        context.setStrokeColor(chrome.accent)
        context.setLineWidth(1.2 * u)
        context.setLineDash(phase: 0, lengths: [4 * u, 3 * u])
        context.stroke(frame)
        context.setLineDash(phase: 0, lengths: [])

        let radius = 5.5 * u
        let white = CGColor(gray: 1, alpha: 1)
        let resize = CGRect(x: frame.maxX - radius, y: frame.minY - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(white)
        context.fillEllipse(in: resize)
        context.setLineWidth(1.5 * u)
        context.strokeEllipse(in: resize)

        let remove = CGRect(x: frame.maxX - radius, y: frame.maxY - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(CGColor(srgbRed: 0.91, green: 0.26, blue: 0.23, alpha: 1))
        context.fillEllipse(in: remove)
        let arm = 2.2 * u
        context.setStrokeColor(white)
        context.setLineWidth(1.4 * u)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: remove.midX - arm, y: remove.midY - arm))
        context.addLine(to: CGPoint(x: remove.midX + arm, y: remove.midY + arm))
        context.move(to: CGPoint(x: remove.midX - arm, y: remove.midY + arm))
        context.addLine(to: CGPoint(x: remove.midX + arm, y: remove.midY - arm))
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - PDF view with placement editing

final class ESignPDFView: PDFView {
    weak var session: ESignSession?

    private(set) var placements: [ESignPlacementAnnotation] = []
    private weak var selected: ESignPlacementAnnotation?
    private var drag: Drag?

    private struct Drag {
        let annotation: ESignPlacementAnnotation
        let page: PDFPage
        let handle: ESignHandle
        let startPoint: CGPoint
        let startCenter: CGPoint
        let startSize: CGSize
        /// Resize: from the pointer to the art's corner (as seen), so grabbing
        /// the handle a few points off the corner doesn't make it jump.
        var grab = CGPoint.zero
    }

    var placementCount: Int { placements.count }
    var hasSelection: Bool { selected != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(scaleDidChange),
                                               name: .PDFViewScaleChanged, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange),
                                               name: .PDFViewPageChanged, object: self)
    }

    private var chromeUnit: CGFloat { 1 / max(scaleFactor, 0.05) }

    private var accent: CGColor {
        (NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue).cgColor
    }

    @objc private func scaleDidChange(_ note: Notification) {
        guard let selected else { return }
        selected.setChrome(selected: true, unit: chromeUnit, accent: accent)
        refresh(selected)
    }

    @objc private func pageDidChange(_ note: Notification) {
        session?.pageChanged()
    }

    private func refresh(_ annotation: ESignPlacementAnnotation) {
        if let page = annotation.page { annotationsChanged(on: page) }
    }

    // MARK: Placements

    /// Drop new artwork in the middle of what's on screen, upright even on
    /// rotated pages, never exactly on top of the previous one.
    func placeNew(_ drawable: ESignDrawable, visualWidth: CGFloat) {
        guard let document, document.pageCount > 0 else { return }
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let page = page(for: viewCenter, nearest: true) ?? currentPage else { return }
        let box = page.bounds(for: .cropBox)
        let turns = ESignGeometry.quarterTurns(of: page)
        let visiblePage = ESignGeometry.visualSize(of: box, quarterTurns: turns)
        let width = min(visualWidth, visiblePage.width * 0.5)
        var size = CGSize(width: width, height: width / drawable.aspect)
        if size.height > visiblePage.height * 0.4 {
            size = CGSize(width: visiblePage.height * 0.4 * drawable.aspect, height: visiblePage.height * 0.4)
        }
        var center = convert(viewCenter, to: page)
        if !box.contains(center) { center = CGPoint(x: box.midX, y: box.midY) }
        // Don't cover what's already there: slide below it (as seen).
        for _ in 0..<12 {
            let rect = ESignGeometry.pageBounds(center: center, visualSize: size, quarterTurns: turns)
            guard let blocker = placements.first(where: { $0.page === page && $0.pageRect.intersects(rect) })
            else { break }
            let offset = ESignGeometry.toVisual(CGPoint(x: blocker.center.x - center.x, y: blocker.center.y - center.y),
                                                quarterTurns: turns)
            let drop = offset.y - blocker.visualSize.height / 2 - 8 - size.height / 2
            let move = ESignGeometry.fromVisual(CGPoint(x: 0, y: min(drop, -1)), quarterTurns: turns)
            center = CGPoint(x: center.x + move.x, y: center.y + move.y)
        }
        center = ESignGeometry.clampCenter(center, visualSize: size, quarterTurns: turns, in: box)
        let annotation = ESignPlacementAnnotation(drawable: drawable, center: center, visualSize: size,
                                                  quarterTurns: turns)
        page.addAnnotation(annotation)
        placements.append(annotation)
        select(annotation)
        window?.makeFirstResponder(self)
        session?.placementsChanged()
    }

    func select(_ annotation: ESignPlacementAnnotation?) {
        guard selected !== annotation else { return }
        if let old = selected {
            old.setChrome(selected: false, unit: chromeUnit, accent: accent)
            refresh(old)
        }
        selected = annotation
        if let annotation {
            annotation.setChrome(selected: true, unit: chromeUnit, accent: accent)
            refresh(annotation)
        }
        session?.selectionChanged()
    }

    func remove(_ annotation: ESignPlacementAnnotation) {
        if selected === annotation {
            selected = nil
            session?.selectionChanged()
        }
        let page = annotation.page
        page?.removeAnnotation(annotation)
        placements.removeAll { $0 === annotation }
        if let page { annotationsChanged(on: page) }
        session?.placementsChanged()
    }

    func removeSelection() {
        if let selected { remove(selected) }
    }

    /// Same spot (relative to the page) on every other page — initials.
    func placeSelectionOnAllPages() {
        guard let selected, let sourcePage = selected.page, let document else { return }
        let sourceBox = sourcePage.bounds(for: .cropBox)
        let fx = (selected.center.x - sourceBox.minX) / max(sourceBox.width, 1)
        let fy = (selected.center.y - sourceBox.minY) / max(sourceBox.height, 1)
        var added = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page !== sourcePage,
                  !placements.contains(where: { $0.page === page && $0.drawable === selected.drawable })
            else { continue }
            let box = page.bounds(for: .cropBox)
            let turns = ESignGeometry.quarterTurns(of: page)
            let center = ESignGeometry.clampCenter(
                CGPoint(x: box.minX + fx * box.width, y: box.minY + fy * box.height),
                visualSize: selected.visualSize, quarterTurns: turns, in: box)
            let copy = ESignPlacementAnnotation(drawable: selected.drawable, center: center,
                                                visualSize: selected.visualSize, quarterTurns: turns)
            page.addAnnotation(copy)
            placements.append(copy)
            added += 1
        }
        if added > 0 { session?.placementsChanged() }
    }

    func snapshotPlacements() -> [ESignPlacement] {
        guard let document else { return [] }
        return placements.compactMap { annotation in
            guard let page = annotation.page else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            return ESignPlacement(pageIndex: index, center: annotation.center, visualSize: annotation.visualSize,
                                  quarterTurns: annotation.quarterTurns, drawable: annotation.drawable)
        }
    }

    func withPlacementsDetached<T>(_ body: () -> T) -> T {
        let attached = placements.compactMap { annotation in annotation.page.map { (annotation, $0) } }
        for (annotation, page) in attached { page.removeAnnotation(annotation) }
        defer { for (annotation, page) in attached { page.addAnnotation(annotation) } }
        return body()
    }

    // MARK: Mouse & keyboard

    private func hit(at viewPoint: CGPoint) -> (ESignPlacementAnnotation, ESignHandle)? {
        let tolerance = 9 * chromeUnit
        // The selection first: its handles may hang off the page.
        if let selected, let page = selected.page,
           let handle = selected.hitZone(convert(viewPoint, to: page), tolerance: tolerance) {
            return (selected, handle)
        }
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        let point = convert(viewPoint, to: page)
        for annotation in placements.reversed() where annotation.page === page && annotation !== selected {
            if let handle = annotation.hitZone(point, tolerance: tolerance) { return (annotation, handle) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let (annotation, handle) = hit(at: viewPoint), let page = annotation.page else {
            select(nil)
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        if handle == .delete {
            remove(annotation)
            return
        }
        select(annotation)
        let start = convert(viewPoint, to: page)
        var newDrag = Drag(annotation: annotation, page: page, handle: handle, startPoint: start,
                           startCenter: annotation.center, startSize: annotation.visualSize)
        if handle == .resize {
            let pointer = ESignGeometry.toVisual(CGPoint(x: start.x - newDrag.startCenter.x, y: start.y - newDrag.startCenter.y),
                                                 quarterTurns: annotation.quarterTurns)
            newDrag.grab = CGPoint(x: newDrag.startSize.width / 2 - pointer.x, y: -newDrag.startSize.height / 2 - pointer.y)
        }
        drag = newDrag
        (handle == .body ? NSCursor.closedHand : NSCursor.crosshair).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(convert(event.locationInWindow, from: nil), to: drag.page)
        let box = drag.page.bounds(for: .cropBox)
        let turns = drag.annotation.quarterTurns
        switch drag.handle {
        case .body:
            let moved = CGPoint(x: drag.startCenter.x + point.x - drag.startPoint.x,
                                y: drag.startCenter.y + point.y - drag.startPoint.y)
            drag.annotation.setGeometry(
                center: ESignGeometry.clampCenter(moved, visualSize: drag.startSize, quarterTurns: turns, in: box),
                visualSize: drag.startSize)
        case .resize:
            // Top-left corner (as seen) stays put; the aspect ratio is kept.
            let anchor = CGPoint(x: -drag.startSize.width / 2, y: drag.startSize.height / 2)
            let pointer = ESignGeometry.toVisual(CGPoint(x: point.x - drag.startCenter.x, y: point.y - drag.startCenter.y),
                                                 quarterTurns: turns)
            let corner = CGPoint(x: pointer.x + drag.grab.x, y: pointer.y + drag.grab.y)
            let aspect = drag.startSize.width / max(drag.startSize.height, 0.01)
            let limit = ESignGeometry.visualSize(of: box, quarterTurns: turns)
            // Project the corner onto the box's diagonal: grows and shrinks
            // naturally whichever way the pointer goes.
            let diagonal = CGPoint(x: drag.startSize.width, y: -drag.startSize.height)
            let along = ((corner.x - anchor.x) * diagonal.x + (corner.y - anchor.y) * diagonal.y)
                / max(diagonal.x * diagonal.x + diagonal.y * diagonal.y, 0.0001)
            let proposed = along * drag.startSize.width
            var width = min(max(proposed, 12), limit.width, limit.height * aspect)
            func center(for width: CGFloat) -> CGPoint {
                let offset = ESignGeometry.fromVisual(CGPoint(x: anchor.x + width / 2, y: anchor.y - width / aspect / 2),
                                                      quarterTurns: turns)
                return CGPoint(x: drag.startCenter.x + offset.x, y: drag.startCenter.y + offset.y)
            }
            func fits(_ width: CGFloat) -> Bool {
                let rect = ESignGeometry.pageBounds(center: center(for: width),
                                                    visualSize: CGSize(width: width, height: width / aspect),
                                                    quarterTurns: turns)
                return box.insetBy(dx: -0.5, dy: -0.5).contains(rect)
            }
            // Grow up to the page edge, no further — the anchored corner stays put.
            if !fits(width), fits(12) {
                var low: CGFloat = 12, high = width
                for _ in 0..<14 {
                    let mid = (low + high) / 2
                    if fits(mid) { low = mid } else { high = mid }
                }
                width = low
            }
            let size = CGSize(width: width, height: width / aspect)
            drag.annotation.setGeometry(
                center: ESignGeometry.clampCenter(center(for: width), visualSize: size, quarterTurns: turns, in: box),
                visualSize: size)
        case .delete:
            return
        }
        refresh(drag.annotation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else {
            super.mouseUp(with: event)
            return
        }
        self.drag = nil
        if drag.annotation.center != drag.startCenter || drag.annotation.visualSize != drag.startSize {
            session?.placementsChanged()
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if updateCursor(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseMoved(with: event)
    }

    @discardableResult
    private func updateCursor(at viewPoint: CGPoint) -> Bool {
        guard let (_, handle) = hit(at: viewPoint) else { return false }
        switch handle {
        case .body: NSCursor.openHand.set()
        case .resize: NSCursor.crosshair.set()
        case .delete: NSCursor.pointingHand.set()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let selected, let page = selected.page else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGPoint
        switch event.keyCode {
        case 51, 117:                                   // ⌫ ⌦
            remove(selected)
            return
        case 53:                                        // esc
            select(nil)
            return
        case 123: delta = CGPoint(x: -step, y: 0)       // ←
        case 124: delta = CGPoint(x: step, y: 0)        // →
        case 125: delta = CGPoint(x: 0, y: -step)       // ↓
        case 126: delta = CGPoint(x: 0, y: step)        // ↑
        default:
            super.keyDown(with: event)
            return
        }
        let d = ESignGeometry.fromVisual(delta, quarterTurns: selected.quarterTurns)
        let moved = CGPoint(x: selected.center.x + d.x, y: selected.center.y + d.y)
        selected.setGeometry(
            center: ESignGeometry.clampCenter(moved, visualSize: selected.visualSize,
                                              quarterTurns: selected.quarterTurns, in: page.bounds(for: .cropBox)),
            visualSize: selected.visualSize)
        refresh(selected)
        session?.placementsChanged()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (annotation, _) = hit(at: convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        select(annotation)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let everyPage = NSMenuItem(title: "Place on Every Page", action: #selector(placeOnEveryPageAction),
                                   keyEquivalent: "")
        everyPage.target = self
        everyPage.isEnabled = (document?.pageCount ?? 0) > 1
        menu.addItem(everyPage)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeAction), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func placeOnEveryPageAction() { placeSelectionOnAllPages() }
    @objc private func removeAction() { removeSelection() }
}

// MARK: - Verification

@MainActor
enum ESignVerification {
    struct Summary {
        let title: String
        let detail: String
        let symbol: String
        let color: Color
        let nsColor: NSColor
    }

    private static func when(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "an unknown date"
    }

    static func summary(_ verdict: ESignSeal.Verdict) -> Summary {
        switch verdict {
        case .intact(let payload, let mine):
            return Summary(title: "Signed and unchanged",
                           detail: "Sealed by \(payload.signer), \(when(payload.date))" + (mine ? " · this Mac" : ""),
                           symbol: "checkmark.seal.fill", color: .green, nsColor: .systemGreen)
        case .modified(let payload):
            return Summary(title: "Changed after signing",
                           detail: "The seal by \(payload.signer) from \(when(payload.date)) no longer matches.",
                           symbol: "exclamationmark.triangle.fill", color: .orange, nsColor: .systemOrange)
        case .invalid:
            return Summary(title: "Seal can't be trusted",
                           detail: "The aiFlow seal in this file is damaged or was edited.",
                           symbol: "xmark.seal.fill", color: .red, nsColor: .systemRed)
        case .unsealed:
            return Summary(title: "No aiFlow seal",
                           detail: "This PDF wasn't sealed by aiFlow.",
                           symbol: "seal", color: .secondary, nsColor: .secondaryLabelColor)
        }
    }

    /// Context menu / Finder service: check the file and show the verdict.
    static func present(for url: URL) { present(for: [url]) }

    /// Several PDFs: one summary alert, a line per file.
    static func present(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let verdicts = await Task.detached(priority: .userInitiated) {
                urls.map { ESignSeal.verify(fileAt: $0) }
            }.value
            if urls.count == 1 {
                show(verdicts[0], fileName: urls[0].lastPathComponent)
            } else {
                showSummary(Array(zip(urls, verdicts)))
            }
        }
    }

    private static func showSummary(_ results: [(URL, ESignSeal.Verdict)]) {
        var intact = 0
        let lines = results.map { url, verdict -> String in
            let mark: String
            switch verdict {
            case .intact: mark = "✓"; intact += 1
            case .modified: mark = "⚠︎"
            case .invalid: mark = "✕"
            case .unsealed: mark = "–"
            }
            return "\(mark)  \(url.lastPathComponent) — \(summary(verdict).title.lowercased())"
        }
        let alert = NSAlert()
        alert.messageText = "\(intact) of \(results.count) PDFs signed and unchanged"
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nAn aiFlow seal is a simple integrity check, not a qualified electronic signature."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func show(_ verdict: ESignSeal.Verdict, fileName: String) {
        let summary = summary(verdict)
        let note = "\n\nAn aiFlow seal is a simple integrity check (Ed25519 over SHA-256), not a qualified electronic signature."
        let text: String
        switch verdict {
        case .intact(let p, let mine):
            let who = p.email.isEmpty ? p.signer : "\(p.signer) <\(p.email)>"
            text = "“\(fileName)” was sealed by \(who) on \(when(p.date)) and hasn't changed since.\n\nSigning key: \(p.keyFingerprint)\(mine ? " (this Mac)" : "")." + note
        case .modified(let p):
            text = "“\(fileName)” was sealed by \(p.signer) on \(when(p.date)), but it has been edited or re-saved since. Ask for the original signed copy." + note
        case .invalid:
            text = "The seal inside “\(fileName)” doesn't verify — the seal or the file was tampered with." + note
        case .unsealed:
            text = "“\(fileName)” has no aiFlow seal. Signatures visible on its pages may be genuine, but aiFlow can't confirm who signed it or whether it changed."
        }
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = text
        if let icon = NSImage(systemSymbolName: summary.symbol, accessibilityDescription: summary.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [summary.nsColor]))) {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Finder Services ("Sign with FinderFlow", "Verify E-Signature")

/// Registered as `NSApp.servicesProvider`; the entries are NSServices in
/// Info.plist (Finder ▸ right-click ▸ Services / Quick Actions).
final class ESignServiceProvider: NSObject {
    static let shared = ESignServiceProvider()

    @objc func signDocument(_ pboard: NSPasteboard, userData: String,
                            error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.fileURLs(on: pboard).filter(ESignSource.canSign)
        guard !urls.isEmpty else {
            error.pointee = "Select a PDF or an image to sign."
            return
        }
        Task { @MainActor in
            for url in urls.prefix(4) { ESignWindowManager.shared.open(url) }
        }
    }

    @objc func verifySignature(_ pboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let url = Self.fileURLs(on: pboard).first(where: ESignSource.isPDF) else {
            error.pointee = "Select a PDF to verify."
            return
        }
        Task { @MainActor in ESignVerification.present(for: url) }
    }

    private static func fileURLs(on pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

// MARK: - SwiftUI

struct ESignWindowView: View {
    @ObservedObject var session: ESignSession
    @ObservedObject private var library = SignatureLibrary.shared

    private var errorShown: Binding<Bool> {
        Binding(get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } })
    }

    var body: some View {
        HStack(spacing: 0) {
            ESignSidebar(session: session, library: library)
                .frame(width: 272)
            Divider()
            VStack(spacing: 0) {
                if let seal = session.existingSeal {
                    ESignSealBanner(summary: ESignVerification.summary(seal))
                    Divider()
                }
                if let note = session.conversionNote {
                    ESignNoteBanner(text: note)
                    Divider()
                }
                ZStack {
                    ESignPDFContainer(pdfView: session.pdfView)
                    phaseOverlay
                    if session.isSaving { savingOverlay }
                }
                if let saved = session.savedCopy {
                    Divider()
                    ESignSavedBar(saved: saved, session: session)
                }
                Divider()
                ESignBottomBar(session: session)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .sheet(isPresented: $session.showCreator) {
            SignatureCreatorSheet { artwork in session.place(artwork) }
        }
        .alert("Couldn't sign the document", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch session.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
        case .needsPassword(let wrongAttempt):
            ESignPasswordView(wrongAttempt: wrongAttempt) { session.unlock(with: $0) }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Close") { session.onClose?() }
            }
            .padding(24)
            .background(.regularMaterial, in: FFTheme.floatingShape)
        case .ready:
            EmptyView()
        }
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
            VStack(spacing: 10) {
                ProgressView(value: session.saveProgress)
                    .frame(width: 200)
                Text(ESignDefaults.addSeal ? "Signing and sealing…" : "Signing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: FFTheme.cardShape)
        }
    }
}

private struct ESignPDFContainer: NSViewRepresentable {
    let pdfView: ESignPDFView

    func makeNSView(context: Context) -> ESignPDFView { pdfView }
    func updateNSView(_ nsView: ESignPDFView, context: Context) {}
}

private struct ESignSidebar: View {
    @ObservedObject var session: ESignSession
    @ObservedObject var library: SignatureLibrary
    @AppStorage(ESignDefaults.signerNameKey) private var signerName = ""
    @AppStorage(ESignDefaults.addSealKey) private var addSeal = true
    @State private var keyID: String?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                signatures
                fields
                seal
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { refreshKeyID() }
        .onChange(of: session.savedCopy) { _, _ in refreshKeyID() }
    }

    private func refreshKeyID() {
        keyID = ESignKeyStore.existingPublicKey().map(ESignKeyStore.fingerprint(ofPublicKey:))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(FFTheme.heroGradient)
                    .frame(width: 30, height: 30)
                Image(systemName: "signature")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("E-Sign")
                    .font(.system(size: 13, weight: .semibold))
                Text(session.sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private var signatures: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Signatures")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(library.items) { artwork in
                    SignatureCard(artwork: artwork, thumbnail: library.thumbnail(for: artwork),
                                  onPlace: { session.place(artwork) },
                                  onRename: { rename(artwork) },
                                  onDelete: { delete(artwork) })
                }
                Button { session.showCreator = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                        Text("New")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .overlay(FFTheme.cardShape
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(Color.accentColor.opacity(0.6)))
                    .contentShape(FFTheme.cardShape)
                }
                .buttonStyle(.plain)
                .help("Draw, type or import a new signature")
            }
            Text(library.items.isEmpty
                 ? "Create your signature once — draw it, type it or import a photo — and reuse it on any document."
                 : "Click a signature to put it on the page you're viewing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Fields")
            LazyVGrid(columns: columns, spacing: 8) {
                FieldButton(title: "Date", systemImage: "calendar") { session.placeDate() }
                FieldButton(title: "Name", systemImage: "person.text.rectangle") { session.placeName() }
                FieldButton(title: "Text…", systemImage: "character.cursor.ibeam") { session.promptForText() }
                FieldButton(title: "Check", systemImage: "checkmark") { session.placeCheckmark() }
            }
        }
    }

    private var seal: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Seal")
            Toggle("Tamper-evident seal", isOn: $addSeal)
                .toggleStyle(.switch)
                .controlSize(.small)
            Text("Signs the finished file with this Mac's key so aiFlow can later tell whether it was changed. A simple integrity check, not a qualified e-signature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Signer", text: $signerName, prompt: Text(NSFullUserName()))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Label(keyID.map { "Key \($0)" } ?? "Key is created with the first seal", systemImage: "key.fill")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func rename(_ artwork: SignatureArtwork) {
        let alert = NSAlert()
        alert.messageText = "Rename Signature"
        let field = NSTextField(string: artwork.label)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.rename(artwork.id, to: field.stringValue)
    }

    private func delete(_ artwork: SignatureArtwork) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(artwork.label)”?"
        alert.informativeText = "Documents you already signed keep it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.delete(artwork.id)
    }
}

private struct SignatureCard: View {
    let artwork: SignatureArtwork
    let thumbnail: NSImage?
    let onPlace: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPlace) {
            VStack(spacing: 4) {
                ZStack {
                    FFTheme.cardShape.fill(Color.white)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    } else {
                        Image(systemName: "questionmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 64)
                .overlay(FFTheme.cardShape
                    .strokeBorder(hovering ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: hovering ? 1.5 : 1))
                Text(artwork.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Place “\(artwork.label)” on the current page")
        .contextMenu {
            Button("Place on Page", action: onPlace)
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete Signature…", role: .destructive, action: onDelete)
        }
    }
}

private struct FieldButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

private struct ESignSealBanner: View {
    let summary: ESignVerification.Summary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: summary.symbol)
                .foregroundStyle(summary.color)
            Text(summary.title)
                .font(.callout.weight(.semibold))
            Text(summary.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(summary.color.opacity(0.08))
    }
}

private struct ESignNoteBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.06))
    }
}

/// Preview-panel line for signable files: the seal status of a sealed PDF
/// (checked off the main thread) and a one-click Sign….
struct ESignPreviewRow: View {
    let url: URL
    @State private var verdict: ESignSeal.Verdict?

    var body: some View {
        if ESignSource.canSign(url) {
            HStack(spacing: 6) {
                if let verdict, let summary = sealSummary(verdict) {
                    Image(systemName: summary.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(summary.color)
                    Text(summary.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(summary.detail)
                }
                Spacer(minLength: 0)
                Button { ESignWindowManager.shared.open(url) } label: {
                    Label("Sign…", systemImage: "signature")
                }
                .controlSize(.small)
                .help("Sign “\(url.lastPathComponent)” — the original stays untouched")
            }
            .task(id: url) { await check() }
        }
    }

    private func sealSummary(_ verdict: ESignSeal.Verdict) -> ESignVerification.Summary? {
        if case .unsealed = verdict { return nil }
        return ESignVerification.summary(verdict)
    }

    private func check() async {
        verdict = nil
        let url = self.url
        guard ESignSource.isPDF(url),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size < 150_000_000 else { return }
        let result = await Task.detached(priority: .utility) { ESignSeal.verify(fileAt: url) }.value
        if !Task.isCancelled { verdict = result }
    }
}

private struct ESignSavedBar: View {
    let saved: ESignSession.SavedCopy
    @ObservedObject var session: ESignSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved “\(saved.url.lastPathComponent)”")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(saved.sealed ? "Sealed — “Verify Signature” will show if it's ever changed."
                                  : "Saved without a seal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Open") { session.openSavedCopy() }
            Button("Show in aiFlow") { session.revealSavedCopy() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.07))
    }
}

private struct ESignBottomBar: View {
    @ObservedObject var session: ESignSession

    private var hint: String {
        if session.placementCount == 0 {
            return "Pick a signature or field on the left — it lands on the page you're viewing."
        }
        if session.hasSelection {
            return "Drag to move · corner to resize · ⌫ removes · right-click: every page"
        }
        return "\(session.placementCount) placed · click one to adjust it"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(session.pageLabel)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            HStack(spacing: 2) {
                Button { session.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out")
                Button { session.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Fit")
                Button { session.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In")
            }
            .buttonStyle(.borderless)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            if session.hasSelection {
                Button("Remove") { session.removeSelected() }
            }
            Button("Save As…") { session.save(chooseLocation: true) }
                .disabled(session.placementCount == 0 || session.isSaving)
            Button("Save Signed Copy") { session.save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(session.placementCount == 0 || session.isSaving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ESignPasswordView: View {
    let wrongAttempt: Bool
    let onUnlock: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("This PDF is password protected")
                .font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { if !password.isEmpty { onUnlock(password) } }
            if wrongAttempt {
                Text("Wrong password — try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Unlock") { onUnlock(password) }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            Text("The signed copy is saved without a password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: FFTheme.floatingShape)
    }
}
