import AppKit
import PDFKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - E-Sign engine
//
// Simple e-signing for PDFs (and images, which become a one-page PDF):
//   • saved signatures — drawn (SignaturePad port), typed in a script face or
//     imported from a photo/scan (paper turned transparent);
//   • placements are burned into the page content of a signed COPY, as
//     vectors where possible; form values and notes are flattened with them,
//     links / outline / metadata / page rotation are carried over;
//   • an optional tamper-evident seal: an Ed25519 signature over the SHA-256
//     of the finished file, appended as a PDF comment. It proves "unchanged
//     since signed with this key", nothing more — no certificates, no PAdES.

enum ESignDefaults {
    static let signerNameKey = "ffESignSignerName"
    static let signerEmailKey = "ffESignSignerEmail"
    static let addSealKey = "ffESignAddSeal"

    static var signerName: String {
        let name = UserDefaults.standard.string(forKey: signerNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? NSFullUserName() : name
    }

    static var signerEmail: String {
        UserDefaults.standard.string(forKey: signerEmailKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var addSeal: Bool {
        UserDefaults.standard.object(forKey: addSealKey) as? Bool ?? true
    }
}

enum ESignError: LocalizedError {
    case unreadable(String)
    case locked
    case restricted
    case noSignatureInImage
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” can't be opened for signing."
        case .locked: return "The PDF is password protected."
        case .restricted: return "The owner of this PDF doesn't allow changes to it."
        case .noSignatureInImage: return "No signature found in the image — use dark ink on light paper."
        case .writeFailed(let reason): return "The signed copy couldn't be saved: \(reason)"
        }
    }
}

// MARK: - Geometry

/// Placements are kept in page space (PDFKit's, y up) as a center plus the
/// size the user SEES. On a page shown rotated by 90°/270° (/Rotate) the box
/// is swapped and the artwork is counter-rotated so it still reads upright.
enum ESignGeometry {
    static func quarterTurns(of page: PDFPage) -> Int {
        (((page.rotation % 360) + 360) % 360) / 90
    }

    static func pageBounds(center: CGPoint, visualSize: CGSize, quarterTurns: Int) -> CGRect {
        let size = quarterTurns % 2 == 0 ? visualSize : CGSize(width: visualSize.height, height: visualSize.width)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Page-space offset → offset as seen on screen (the page turns clockwise).
    static func toVisual(_ p: CGPoint, quarterTurns: Int) -> CGPoint {
        var v = p
        for _ in 0..<(quarterTurns % 4) { v = CGPoint(x: v.y, y: -v.x) }
        return v
    }

    /// Offset as seen on screen → page-space offset.
    static func fromVisual(_ v: CGPoint, quarterTurns: Int) -> CGPoint {
        var p = v
        for _ in 0..<(quarterTurns % 4) { p = CGPoint(x: -p.y, y: p.x) }
        return p
    }

    /// Visible page size (what the user sees after /Rotate).
    static func visualSize(of box: CGRect, quarterTurns: Int) -> CGSize {
        quarterTurns % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Keep the whole placement on the page (centered if it can't fit).
    static func clampCenter(_ center: CGPoint, visualSize: CGSize, quarterTurns: Int, in box: CGRect) -> CGPoint {
        let size = pageBounds(center: .zero, visualSize: visualSize, quarterTurns: quarterTurns).size
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi)
        }
        return CGPoint(x: clamp(center.x, box.minX + size.width / 2, box.maxX - size.width / 2),
                       y: clamp(center.y, box.minY + size.height / 2, box.maxY - size.height / 2))
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Drawable artwork

/// Immutable artwork that paints itself aspect-fit into a rect of a y-up
/// CoreGraphics context. Thread-safe by construction: PDFView renders
/// annotation tiles off the main thread and the signer flattens pages in the
/// background.
final class ESignDrawable: @unchecked Sendable {
    enum Art {
        case ink([SignatureSegment], SignaturePen, CGColor)   // pad space, y down
        case text(CTLine)                                     // baseline at y = 0
        case image(CGImage)
    }

    let art: Art
    /// Tight content box in the art's own space.
    let contentBounds: CGRect

    var aspect: CGFloat {
        contentBounds.height > 0 ? contentBounds.width / contentBounds.height : 1
    }

    private init(art: Art, contentBounds: CGRect) {
        self.art = art
        self.contentBounds = contentBounds
    }

    static func ink(_ ink: SignatureInk, color: CGColor) -> ESignDrawable? {
        let segments = ink.segments()
        let box = SignatureInkRenderer.bounds(of: segments, pen: ink.pen)
        guard !box.isNull, box.width > 1, box.height > 1 else { return nil }
        return ESignDrawable(art: .ink(segments, ink.pen, color), contentBounds: box)
    }

    /// `tight` hugs the glyph outlines (script signatures with swashes);
    /// otherwise the box is the line's ascent + descent (dates, names).
    static func text(_ string: String, font: NSFont, color: CGColor, tight: Bool) -> ESignDrawable? {
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let attributed = NSAttributedString(string: clean, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var box: CGRect
        if tight {
            box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            box = box.insetBy(dx: -font.pointSize * 0.04, dy: -font.pointSize * 0.04)
        } else {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            box = CGRect(x: 0, y: -descent, width: width, height: ascent + descent)
        }
        guard !box.isNull, box.width > 0.5, box.height > 0.5 else { return nil }
        return ESignDrawable(art: .text(line), contentBounds: box)
    }

    static func image(_ image: CGImage) -> ESignDrawable? {
        guard image.width > 0, image.height > 0 else { return nil }
        return ESignDrawable(art: .image(image),
                             contentBounds: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    func draw(in ctx: CGContext, rect: CGRect) {
        guard contentBounds.width > 0, contentBounds.height > 0 else { return }
        let target = ESignGeometry.aspectFit(contentBounds.size, in: rect)
        let scale = target.width / contentBounds.width
        ctx.saveGState()
        switch art {
        case .ink(let segments, let pen, let color):
            ctx.translateBy(x: target.minX, y: target.maxY)
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -contentBounds.minX, y: -contentBounds.minY)
            SignatureInkRenderer.draw(segments, pen: pen, color: color, in: ctx)
        case .text(let line):
            ctx.translateBy(x: target.minX, y: target.minY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -contentBounds.minX, y: -contentBounds.minY)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
        case .image(let image):
            ctx.interpolationQuality = .high
            ctx.draw(image, in: target)
        }
        ctx.restoreGState()
    }
}

/// One placed signature / field, detached from the viewer (value snapshot).
struct ESignPlacement {
    let pageIndex: Int
    let center: CGPoint
    let visualSize: CGSize
    let quarterTurns: Int
    let drawable: ESignDrawable
}

enum ESignRenderer {
    static func draw(_ drawable: ESignDrawable, center: CGPoint, visualSize: CGSize,
                     quarterTurns: Int, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        // /Rotate turns the page clockwise on screen; turn the art back.
        if quarterTurns % 4 != 0 { ctx.rotate(by: CGFloat(quarterTurns % 4) * .pi / 2) }
        drawable.draw(in: ctx, rect: CGRect(x: -visualSize.width / 2, y: -visualSize.height / 2,
                                            width: visualSize.width, height: visualSize.height))
        ctx.restoreGState()
    }

    static func draw(_ placement: ESignPlacement, in ctx: CGContext) {
        draw(placement.drawable, center: placement.center, visualSize: placement.visualSize,
             quarterTurns: placement.quarterTurns, in: ctx)
    }
}

// MARK: - Saved signatures

struct SignatureArtwork: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case drawn, typed, image }

    var id = UUID()
    var label: String
    var kind: Kind
    var created = Date()
    var colorHex: String
    var ink: SignatureInk?
    var text: String?
    var fontName: String?
    /// PNG file (transparent background) in the library folder.
    var imageFile: String?
}

enum SignatureInkColor: String, CaseIterable, Identifiable {
    case black = "#15171C"
    case blue = "#1B3A8C"

    var id: String { rawValue }
    var title: String { self == .black ? "Black" : "Blue" }
    var nsColor: NSColor { ESignColor.color(hex: rawValue) ?? .black }
}

enum ESignColor {
    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Script faces that ship with macOS, filtered at runtime.
enum SignatureFonts {
    static let candidates: [(name: String, title: String)] = [
        ("SnellRoundhand", "Snell Roundhand"),
        ("SavoyeLetPlain", "Savoye"),
        ("SignPainter-HouseScript", "SignPainter"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("BrushScriptMT", "Brush Script"),
        ("Zapfino", "Zapfino"),
        ("Apple-Chancery", "Apple Chancery"),
    ]

    static let available: [(name: String, title: String)] = candidates.filter {
        NSFont(name: $0.name, size: 12) != nil
    }

    static func font(named name: String?, size: CGFloat) -> NSFont {
        name.flatMap { NSFont(name: $0, size: size) }
            ?? available.first.flatMap { NSFont(name: $0.name, size: size) }
            ?? NSFont.systemFont(ofSize: size)
    }
}

/// The user's saved signatures:
/// ~/Library/Application Support/FinderFlow/Signatures/signatures.json
/// (+ one PNG per imported image). Local to this Mac, never uploaded.
@MainActor
final class SignatureLibrary: ObservableObject {
    static let shared = SignatureLibrary()

    @Published private(set) var items: [SignatureArtwork] = []
    private var drawables: [UUID: ESignDrawable] = [:]

    nonisolated static var directory: URL {
        // Test harnesses point this elsewhere so they never touch the user's
        // signatures or signing key.
        if let override = ProcessInfo.processInfo.environment["FF_ESIGN_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("FinderFlow/Signatures", isDirectory: true)
    }

    nonisolated static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private var indexURL: URL { Self.directory.appendingPathComponent("signatures.json") }

    private init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([SignatureArtwork].self, from: data)) ?? []
    }

    private func persist() throws {
        try Self.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    func add(_ artwork: SignatureArtwork, imagePNG: Data? = nil) throws {
        try Self.ensureDirectory()
        var artwork = artwork
        if let imagePNG {
            let name = "\(artwork.id.uuidString).png"
            try imagePNG.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
            artwork.imageFile = name
        }
        items.insert(artwork, at: 0)
        try persist()
    }

    func delete(_ id: UUID) {
        guard let artwork = items.first(where: { $0.id == id }) else { return }
        if let file = artwork.imageFile {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file))
        }
        items.removeAll { $0.id == id }
        drawables[id] = nil
        try? persist()
    }

    func rename(_ id: UUID, to label: String) {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].label = clean
        try? persist()
    }

    func drawable(for artwork: SignatureArtwork) -> ESignDrawable? {
        if let cached = drawables[artwork.id] { return cached }
        let color = (ESignColor.color(hex: artwork.colorHex) ?? .black).cgColor
        var made: ESignDrawable?
        switch artwork.kind {
        case .drawn:
            if let ink = artwork.ink { made = .ink(ink, color: color) }
        case .typed:
            if let text = artwork.text {
                made = .text(text, font: SignatureFonts.font(named: artwork.fontName, size: 72),
                             color: color, tight: true)
            }
        case .image:
            if let file = artwork.imageFile,
               let source = CGImageSourceCreateWithURL(Self.directory.appendingPathComponent(file) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                made = .image(image)
            }
        }
        drawables[artwork.id] = made
        return made
    }

    /// Vector thumbnail (redrawn at whatever resolution it's shown).
    func thumbnail(for artwork: SignatureArtwork) -> NSImage? {
        guard let drawable = drawable(for: artwork) else { return nil }
        let width: CGFloat = 220
        let size = NSSize(width: width, height: min(90, max(24, width / max(drawable.aspect, 0.1))))
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawable.draw(in: ctx, rect: rect)
            return true
        }
    }
}

/// Photo or scan of a handwritten signature → trimmed PNG with the paper
/// made transparent (brightness key relative to the paper's own level).
enum SignatureImageImporter {
    static func process(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1800,
              ] as CFDictionary)
        else { throw ESignError.unreadable(url.lastPathComponent) }

        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ESignError.unreadable(url.lastPathComponent) }

        func luma(_ i: Int) -> Int {
            (299 * Int(pixels[i]) + 587 * Int(pixels[i + 1]) + 114 * Int(pixels[i + 2])) / 1000
        }

        // Already transparent (a PNG exported by a signing app)? Keep its alpha.
        var seeThrough = 0
        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i + 3] < 250 { seeThrough += 1 } else { histogram[luma(i)] += 1 }
        }
        if seeThrough <= width * height / 100 {
            // The paper is the bright majority: take its level at the 80th
            // percentile, fade to transparent just below it, keep ink solid.
            let total = histogram.reduce(0, +)
            var paper = 255, running = 0
            for level in 0..<256 {
                running += histogram[level]
                if running * 10 >= total * 8 { paper = level; break }
            }
            let high = max(40, paper - 28), low = max(0, high - 70)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let y = luma(i)
                let alpha = y >= high ? 0 : (y <= low ? 255 : (high - y) * 255 / max(high - low, 1))
                // Photos render pen ink grey — darken it, then premultiply.
                for c in 0..<3 { pixels[i + c] = UInt8(Int(pixels[i + c]) * 6 / 10 * alpha / 255) }
                pixels[i + 3] = UInt8(alpha)
            }
        }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width where pixels[row + x * 4 + 3] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw ESignError.noSignatureInImage }

        let pad = 8
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(width, maxX + pad + 1), y1 = min(height, maxY + pad + 1)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let full = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: bytesPerRow, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let trimmed = full.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { throw ESignError.unreadable(url.lastPathComponent) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ESignError.unreadable(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, trimmed, nil)
        guard CGImageDestinationFinalize(destination) else { throw ESignError.unreadable(url.lastPathComponent) }
        return data as Data
    }
}

// MARK: - Documents

enum ESignSource {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// Word-processing formats the Cocoa text system reads (styles, tables,
    /// images): laid out on pages, printed to PDF, then signed like any PDF.
    static let documentExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    static func isTextDocument(_ url: URL) -> Bool { documentExtensions.contains(url.pathExtension.lowercased()) }

    static func canSign(_ url: URL) -> Bool { isPDF(url) || isImage(url) || isTextDocument(url) }

    /// For open panels: PDF, images, Word / RTF / ODT.
    static var signableContentTypes: [UTType] {
        [.pdf, .image, .rtf, .rtfd] + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                                       "org.oasis-open.opendocument.text"].compactMap { UTType($0) }
    }

    /// A4 everywhere except the Letter countries.
    static var paperSize: CGSize {
        let region = Locale.current.region?.identifier ?? ""
        return ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(region)
            ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    /// "Ugovor.pdf" → "Ugovor (signed).pdf", then "(signed 2)"… Re-signing a
    /// signed copy doesn't stack suffixes.
    static func signedCopyURL(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent()
        var base = source.deletingPathExtension().lastPathComponent
        if let r = base.range(of: #" \(signed( \d+)?\)$"#, options: .regularExpression) {
            base.removeSubrange(r)
        }
        var candidate = folder.appendingPathComponent("\(base) (signed).pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (signed \(n)).pdf")
            n += 1
        }
        return candidate
    }

    /// One page with the image's proportions, fitted to the paper size so a
    /// 4000 px phone photo isn't a 1.4 m wide page. JPEGs are embedded as-is.
    static func pdfData(fromImageAt url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { throw ESignError.unreadable(url.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let isJPEG = type?.conforms(to: .jpeg) ?? false
        let isPhoto = isJPEG || [UTType.heic, .heif, .webP].contains { type?.conforms(to: $0) ?? false }

        var image: CGImage
        if isJPEG, orientation == 1, let original = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = original
        } else {
            let longest = min(max(pixelWidth, pixelHeight, 1), 4096)
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longest,
            ] as CFDictionary) else { throw ESignError.unreadable(url.lastPathComponent) }
            image = upright
            // Decoded photos would be stored losslessly (tens of MB): re-encode.
            if isPhoto, let jpeg = jpegBacked(upright) { image = jpeg }
        }

        let paper = paperSize
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let frame = w > h ? CGSize(width: paper.height, height: paper.width) : paper
        let scale = min(frame.width / w, frame.height / h)
        var media = CGRect(x: 0, y: 0, width: (w * scale).rounded(), height: (h * scale).rounded())
        let out = NSMutableData()
        let info = [kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent] as CFDictionary
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, info)
        else { throw ESignError.unreadable(url.lastPathComponent) }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(media)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: media)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    /// Word / RTF / ODT → PDF: the document's own paper size and margins when
    /// it has them, laid out by NSTextView and printed to a temporary PDF.
    /// Page breaks and headers/footers aren't carried over — the window says
    /// so, and the user sees every page before signing. AppKit → main thread.
    @MainActor
    static func pdfData(fromTextDocumentAt url: URL) throws -> Data {
        var raw: NSDictionary?
        guard let text = try? NSAttributedString(url: url, options: [:], documentAttributes: &raw),
              text.length > 0
        else { throw ESignError.unreadable(url.lastPathComponent) }
        let attributes = raw as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]

        let info = NSPrintInfo()
        var paper = (attributes[.paperSize] as? NSValue)?.sizeValue ?? .zero
        if !(144...5000).contains(paper.width) || !(144...5000).contains(paper.height) { paper = paperSize }
        info.paperSize = paper
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat {
            let value = (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72
            return min(max(value, 18), paper.width / 4)
        }
        info.leftMargin = margin(.leftMargin)
        info.rightMargin = margin(.rightMargin)
        info.topMargin = margin(.topMargin)
        info.bottomMargin = margin(.bottomMargin)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        // Text with no colour of its own would print white in Dark Mode.
        let body = NSMutableAttributedString(attributedString: text)
        body.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            if value == nil { body.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - info.leftMargin - info.rightMargin,
                                            height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(body)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffesign-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: output), !data.isEmpty
        else { throw ESignError.unreadable(url.lastPathComponent) }
        return data
    }

    private static func jpegBacked(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

enum ESignDocumentSigner {
    struct SealRequest {
        let signer: String
        let email: String
        let source: String
    }

    /// The source's Info dictionary, carried into the signed copy.
    struct DocumentInfo {
        var title: String?
        var author: String?
        var subject: String?
        var keywords: String?
        var creationDate: Date?

        init(_ attributes: [AnyHashable: Any]?) {
            func string(_ key: PDFDocumentAttribute) -> String? {
                if let s = attributes?[key] as? String { return s }
                if let list = attributes?[key] as? [String] { return list.joined(separator: ", ") }
                return nil
            }
            title = string(.titleAttribute)
            author = string(.authorAttribute)
            subject = string(.subjectAttribute)
            keywords = string(.keywordsAttribute)
            creationDate = attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
        }
    }

    /// Burns the placements into a copy of `baseData` and writes it
    /// atomically to `url`, sealed if asked. Runs off the main thread.
    static func signAndWrite(baseData: Data, password: String?, info: DocumentInfo,
                             placements: [ESignPlacement], seal: SealRequest?, to url: URL,
                             progress: (Double) -> Void) throws -> ESignSeal.Payload? {
        var pdf = try signedPDF(from: baseData, password: password, info: info,
                                placements: placements, progress: progress)
        var payload: ESignSeal.Payload?
        if let seal {
            let sealed = try ESignSeal.seal(pdf, signer: seal.signer, email: seal.email, source: seal.source)
            pdf = sealed.data
            payload = sealed.payload
        }
        do {
            try pdf.write(to: url, options: .atomic)
        } catch {
            throw ESignError.writeFailed(error.localizedDescription)
        }
        return payload
    }

    /// Pass 1 redraws every page (content + annotations, i.e. filled forms)
    /// unrotated into a new PDF with the same boxes and paints the
    /// placements on top — so signatures are page content, not removable
    /// annotations. Pass 2 restores page rotation, links, outline, metadata.
    static func signedPDF(from baseData: Data, password: String?, info: DocumentInfo,
                          placements: [ESignPlacement], progress: (Double) -> Void) throws -> Data {
        guard let source = PDFDocument(data: baseData) else { throw ESignError.unreadable("the document") }
        if source.isLocked, !(password.map { source.unlock(withPassword: $0) } ?? false) {
            throw ESignError.locked
        }
        let pageCount = source.pageCount
        let flat = NSMutableData()
        guard let consumer = CGDataConsumer(data: flat as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, auxiliaryInfo(info))
        else { throw ESignError.writeFailed("no PDF context") }

        let byPage = Dictionary(grouping: placements, by: \.pageIndex)
        var rotations: [Int] = []
        for index in 0..<pageCount {
            guard let page = source.page(at: index) else { throw ESignError.unreadable("page \(index + 1)") }
            rotations.append(page.rotation)
            var media = page.bounds(for: .mediaBox)
            var crop = page.bounds(for: .cropBox)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData,
                kCGPDFContextCropBox: Data(bytes: &crop, count: MemoryLayout<CGRect>.size) as CFData,
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)
            page.rotation = 0
            page.draw(with: .mediaBox, to: ctx)
            for placement in byPage[index] ?? [] {
                ESignRenderer.draw(placement, in: ctx)
            }
            ctx.endPDFPage()
            progress(Double(index + 1) / Double(max(pageCount, 1)) * 0.92)
        }
        ctx.closePDF()

        guard let result = PDFDocument(data: flat as Data), result.pageCount == pageCount
        else { throw ESignError.writeFailed("the flattened PDF didn't load back") }
        for index in 0..<pageCount {
            guard let page = result.page(at: index), let original = source.page(at: index) else { continue }
            page.rotation = rotations[index]
            for annotation in original.annotations where annotation.type == "Link" {
                if let link = relink(annotation, from: source, to: result) { page.addAnnotation(link) }
            }
        }
        if let outline = source.outlineRoot {
            result.outlineRoot = copyOutline(outline, from: source, to: result)
        }
        var attributes: [AnyHashable: Any] = [
            PDFDocumentAttribute.creatorAttribute: "aiFlow E-Sign",
            PDFDocumentAttribute.modificationDateAttribute: Date(),
        ]
        attributes[PDFDocumentAttribute.titleAttribute] = info.title
        attributes[PDFDocumentAttribute.authorAttribute] = info.author
        attributes[PDFDocumentAttribute.subjectAttribute] = info.subject
        attributes[PDFDocumentAttribute.keywordsAttribute] = info.keywords
        attributes[PDFDocumentAttribute.creationDateAttribute] = info.creationDate
        result.documentAttributes = attributes
        guard let data = result.dataRepresentation() else { throw ESignError.writeFailed("PDFKit returned no data") }
        progress(1)
        return data
    }

    private static func auxiliaryInfo(_ info: DocumentInfo) -> CFDictionary {
        var aux: [CFString: Any] = [kCGPDFContextCreator: "aiFlow E-Sign"]
        aux[kCGPDFContextTitle] = info.title
        aux[kCGPDFContextAuthor] = info.author
        aux[kCGPDFContextSubject] = info.subject
        aux[kCGPDFContextKeywords] = info.keywords
        return aux as CFDictionary
    }

    private static func mapDestination(_ destination: PDFDestination?, from source: PDFDocument,
                                       to result: PDFDocument) -> PDFDestination? {
        guard let destination, let page = destination.page else { return nil }
        let index = source.index(for: page)
        guard index != NSNotFound, let target = result.page(at: index) else { return nil }
        return PDFDestination(page: target, at: destination.point)
    }

    private static func relink(_ link: PDFAnnotation, from source: PDFDocument,
                               to result: PDFDocument) -> PDFAnnotation? {
        let copy = PDFAnnotation(bounds: link.bounds, forType: .link, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = 0
        copy.border = border
        if let destination = mapDestination(link.destination, from: source, to: result) {
            copy.destination = destination
        } else if let goTo = link.action as? PDFActionGoTo,
                  let destination = mapDestination(goTo.destination, from: source, to: result) {
            copy.action = PDFActionGoTo(destination: destination)
        } else if let action = link.action as? PDFActionURL, let url = action.url {
            copy.action = PDFActionURL(url: url)
        } else if let url = link.url {
            copy.url = url
        } else {
            return nil
        }
        return copy
    }

    private static func copyOutline(_ node: PDFOutline, from source: PDFDocument,
                                    to result: PDFDocument) -> PDFOutline {
        let copy = PDFOutline()
        copy.label = node.label
        if let destination = mapDestination(node.destination ?? (node.action as? PDFActionGoTo)?.destination,
                                            from: source, to: result) {
            copy.destination = destination
        } else if let action = node.action as? PDFActionURL, let url = action.url {
            copy.action = PDFActionURL(url: url)
        }
        for i in 0..<node.numberOfChildren {
            if let child = node.child(at: i) {
                copy.insertChild(copyOutline(child, from: source, to: result), at: copy.numberOfChildren)
            }
        }
        copy.isOpen = node.isOpen
        return copy
    }
}

// MARK: - Tamper-evident seal

/// The signing key lives next to the signatures as a 0600 file rather than
/// in the Keychain: this build is ad-hoc signed, so every rebuild would
/// re-prompt for Keychain access. Good enough for "simple, not qualified".
enum ESignKeyStore {
    private static let lock = NSLock()

    static var keyURL: URL { SignatureLibrary.directory.appendingPathComponent("signing-key.ed25519") }

    static func signingKey() throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: keyURL),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try SignatureLibrary.ensureDirectory()
        guard FileManager.default.createFile(atPath: keyURL.path, contents: key.rawRepresentation,
                                             attributes: [.posixPermissions: 0o600])
        else { throw ESignError.writeFailed("the signing key couldn't be created") }
        return key
    }

    /// This Mac's public key, if a seal was ever made here.
    static func existingPublicKey() -> String? {
        guard let data = try? Data(contentsOf: keyURL),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Short, readable key ID: first 8 bytes of SHA-256(public key).
    static func fingerprint(ofPublicKey base64: String) -> String {
        guard let raw = Data(base64Encoded: base64) else { return "—" }
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02X", $0) }.joined()
        var groups: [String] = []
        var rest = Substring(hex)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: " ")
    }
}

/// Layout at the end of a sealed file (everything before the comment is the
/// signed PDF, byte for byte):
///
///     …%%EOF\n
///     %FinderFlow-ESign-1 <base64 JSON payload>\n
///     startxref\n<same offset>\n%%EOF\n
///
/// The comment is invisible to PDF readers and the repeated trailer keeps
/// "%%EOF" as the last line. Any edit, re-save or appended update breaks it.
enum ESignSeal {
    private static let marker = Data("%FinderFlow-ESign-1 ".utf8)

    struct Payload: Codable, Equatable {
        var v: Int
        var signer: String
        var email: String
        var signedAt: String
        var source: String
        var sha256: String
        var key: String
        var sig: String
        var app: String

        /// What the Ed25519 signature covers (all fields but key / sig / app).
        var signedMessage: Data {
            Data(["FinderFlow-ESign-\(v)", sha256, signer, email, signedAt, source]
                .joined(separator: "\n").utf8)
        }

        var date: Date? { ISO8601DateFormatter().date(from: signedAt) }
        var keyFingerprint: String { ESignKeyStore.fingerprint(ofPublicKey: key) }
    }

    enum Verdict {
        case unsealed
        case intact(Payload, byThisMac: Bool)
        case modified(Payload)
        case invalid(Payload?)
    }

    static func seal(_ pdf: Data, signer: String, email: String,
                     source: String) throws -> (data: Data, payload: Payload) {
        var base = pdf
        if base.last != 0x0A { base.append(0x0A) }
        guard let xref = lastStartXref(in: base) else { throw ESignError.writeFailed("no PDF trailer to seal") }
        let key = try ESignKeyStore.signingKey()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var payload = Payload(v: 1, signer: signer, email: email,
                              signedAt: ISO8601DateFormatter().string(from: Date()), source: source,
                              sha256: hex(SHA256.hash(data: base)),
                              key: key.publicKey.rawRepresentation.base64EncodedString(),
                              sig: "", app: "aiFlow \(version)")
        payload.sig = try key.signature(for: payload.signedMessage).base64EncodedString()
        var out = base
        out.append(marker)
        out.append(Data(try JSONEncoder().encode(payload).base64EncodedString().utf8))
        out.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return (out, payload)
    }

    static func verify(fileAt url: URL) -> Verdict {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unsealed }
        return verify(data)
    }

    static func verify(_ data: Data) -> Verdict {
        guard let found = data.range(of: marker, options: .backwards),
              found.lowerBound > data.startIndex, data[found.lowerBound - 1] == 0x0A
        else { return .unsealed }
        guard let lineEnd = data[found.upperBound...].firstIndex(of: 0x0A),
              let json = Data(base64Encoded: Data(data[found.upperBound..<lineEnd])),
              let payload = try? JSONDecoder().decode(Payload.self, from: json)
        else { return .invalid(nil) }
        guard let rawKey = Data(base64Encoded: payload.key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              let signature = Data(base64Encoded: payload.sig),
              publicKey.isValidSignature(signature, for: payload.signedMessage)
        else { return .invalid(payload) }

        let signed = data[data.startIndex..<found.lowerBound]
        let offset = lastStartXref(in: Data(signed.suffix(4096))) ?? -1
        let expectedTail = Data("\nstartxref\n\(offset)\n%%EOF\n".utf8)
        guard hex(SHA256.hash(data: signed)) == payload.sha256,
              Data(data[lineEnd...]) == expectedTail
        else { return .modified(payload) }
        return .intact(payload, byThisMac: payload.key == ESignKeyStore.existingPublicKey())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Byte offset after the last "startxref" keyword.
    private static func lastStartXref(in data: Data) -> Int? {
        let window = data.suffix(4096)
        guard let r = window.range(of: Data("startxref".utf8), options: .backwards) else { return nil }
        var i = r.upperBound
        while i < window.endIndex, [0x20, 0x0A, 0x0D, 0x09].contains(window[i]) { i += 1 }
        var digits = ""
        while i < window.endIndex, (0x30...0x39).contains(window[i]) {
            digits.append(Character(UnicodeScalar(window[i])))
            i += 1
        }
        return Int(digits)
    }
}
