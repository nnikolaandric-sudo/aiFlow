import Foundation
import PDFKit
import Vision

// MARK: - PDFInspector (Swift port ideje firecrawl/pdf-inspector)
//
// Brza lokalna PDF inspekcija za AI agente (Jev, chat modeli, Claude Code,
// Codex, Cursor i svi budući agenti): klasifikacija da li PDF ima tekst ili
// je sken, izvlačenje teksta i konverzija u čist Markdown — bez mreže, bez
// OCR servisa, sve na Mac-u.
//
// Inspirisano MIT projektom firecrawl/pdf-inspector (Rust):
//   https://github.com/firecrawl/pdf-inspector
// Port je namerno Swift/PDFKit (bez Rust/Python/Node runtime-a) jer je
// FinderFlow self-contained app (~6.8 MB, bez Homebrew/Node zavisnosti).
// API je kompatibilan po imenima polja (snake_case JSON kao Python binding):
//   pdf_type: "text_based" | "scanned" | "image_based" | "mixed"
//   markdown, page_count, pages_needing_ocr, confidence
//
// Korišćenje iz aplikacije (Jev + AI Organizer):
//   let r = PDFInspector.processPDF(url: url)
//   entry.preview = r.excerpt(maxChars: 4000)
//   entry.details += r.details
//
// Korišćenje iz CLI alata za agente (tools/pdf-inspect):
//   pdf-inspect dokument.pdf --json
//   pdf-inspect dokument.pdf --markdown
//   pdf-inspect dokument.pdf --excerpt 4000

/// Klasifikacija PDF-a — isto kao upstream (TextBased/Scanned/ImageBased/Mixed).
enum PDFInspectorType: String, Codable, Equatable {
    case textBased = "text_based"
    case scanned = "scanned"
    case imageBased = "image_based"
    case mixed = "mixed"

    /// Kratak opis na srpskom/engleskom za AI prompt `details`.
    var detailLabel: String {
        switch self {
        case .textBased: return "text-based PDF"
        case .scanned: return "scanned, text read by OCR"
        case .imageBased: return "image-based PDF, text read by OCR"
        case .mixed: return "mixed PDF (partly scanned, text read by OCR)"
        }
    }
}

/// Strategija uzorkovanja stranica za klasifikaciju (kao upstream ScanStrategy).
enum PDFInspectorScanStrategy: Equatable {
    /// Sve stranice, stop na prvoj bez teksta (brza pipeline ruta).
    case earlyExit
    /// Sve stranice, bez ranog izlaza (najtačnije Mixed vs Scanned).
    case full
    /// Uzorkuj n ravnomerno raspoređenih stranica (default: 8).
    case sample(Int)
    /// Samo navedene 1-indexed stranice.
    case pages([Int])

    static var `default`: Self { .sample(8) }
}

struct PDFInspectorOptions {
    var strategy: PDFInspectorScanStrategy = .default
    /// OCR fallback za stranice bez tekstualnog sloja (Vision, on-device).
    var ocrMissingPages: Bool = true
    /// Koliko prvih stranica bez teksta se OCR-uje (štedi vreme na skenovima od 300+ strana).
    var ocrMaxPages: Int = 4
    /// Gornja granica veličine fajla za čitanje (80 MB kao ranije).
    var maxFileBytes: Int64 = 80 * 1024 * 1024
    /// Najmanje alfanumeričkih znakova da se stranica računa kao "ima tekst".
    var textThreshold: Int = 40

    static var `default`: Self { PDFInspectorOptions() }
}

/// Rezultat inspekcije jednog PDF-a. Codable sa snake_case ključevima da JSON
/// mogu da čitaju i Python/Node agenti navikli na upstream `process_pdf`.
struct PDFInspectorResult: Codable {
    var pdfType: PDFInspectorType
    var confidence: Double
    var pageCount: Int
    /// 1-indexed stranice bez tekstualnog sloja (rutiranje za OCR).
    var pagesNeedingOcr: [Int]
    /// Pun tekst (spojene stranice) ili nil kad nema ničega.
    var text: String?
    /// Očišćen Markdown (headings, liste, tabele-heuristika, page markeri opciono).
    var markdown: String?
    var title: String?
    /// Da li je OCR korišćen (bar jedna stranica).
    var ocrUsed: Bool

    enum CodingKeys: String, CodingKey {
        case pdfType = "pdf_type"
        case confidence
        case pageCount = "page_count"
        case pagesNeedingOcr = "pages_needing_ocr"
        case text
        case markdown
        case title
        case ocrUsed = "ocr_used"
    }

    /// Kompaktan JSON za AI agente / pipe-ove (`pdf2md --json` stil).
    func toJSON(pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        if pretty { enc.outputFormatting = [.prettyPrinted, .sortedKeys] }
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Kratak izvod za prompt (Jev + chat modeli): jedna linija po izvornoj
    /// liniji ("Datum: … | Kupac: …") — labele ostaju uz vrednosti.
    func excerpt(maxChars: Int) -> String? {
        guard let raw = markdown ?? text, !raw.isEmpty else { return nil }
        let collapsed = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxChars))
    }

    /// `details` fragmenti za AIFileEntry (stranice, naslov, tip).
    var details: [String] {
        var d: [String] = ["\(pageCount) \(pageCount == 1 ? "page" : "pages")"]
        if let t = title, !t.isEmpty { d.append("title “\(t.prefix(80))”") }
        // text_based se ne prijavljuje (podrazumeva se); ostalo pomaže modelu
        // da zna da OCR može imati sitne greške.
        if pdfType != .textBased { d.append(pdfType.detailLabel) }
        return d
    }
}

enum PDFInspector {
    /// Glavna tačka: učitaj dokument JEDNOM, klasifikuj, izvuci, vrati Markdown.
    /// `ocrMissingPages == false` = samo detekcija + tekstualni sloj (najbrže).
    static func processPDF(url: URL, options: PDFInspectorOptions = .default) -> PDFInspectorResult? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              Int64(size) <= options.maxFileBytes,
              let doc = PDFDocument(url: url) else { return nil }
        return processDocument(doc, options: options)
    }

    /// Varijanta za bajtove u memoriji (agenti koji već imaju Data).
    static func processPDF(data: Data, options: PDFInspectorOptions = .default) -> PDFInspectorResult? {
        guard Int64(data.count) <= options.maxFileBytes,
              let doc = PDFDocument(data: data) else { return nil }
        return processDocument(doc, options: options)
    }

    /// Drop-in za AIContentReader.describe: (preview, details) za Jev/AI prompt.
    static func describe(url: URL, size: Int64, maxChars: Int) -> (preview: String?, details: [String]) {
        var details: [String] = []
        var opts = PDFInspectorOptions.default
        opts.maxFileBytes = max(opts.maxFileBytes, size)
        guard let r = processPDF(url: url, options: opts) else { return (nil, details) }
        details = r.details
        return (r.excerpt(maxChars: maxChars), details)
    }

    // MARK: - Internals

    private static func processDocument(_ doc: PDFDocument, options: PDFInspectorOptions) -> PDFInspectorResult? {
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return nil }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Klasifikacija uzorkovanjem (kao upstream Sample(8)).
        let sampled = sampledPageIndexes(pageCount: pageCount, strategy: options.strategy)
        var pageTexts: [Int: String] = [:] // 0-indexed -> tekstualni sloj
        for idx in sampled {
            pageTexts[idx] = doc.page(at: idx)?.string ?? ""
        }
        func hasText(_ s: String) -> Bool {
            s.filter { $0.isLetter || $0.isNumber }.count >= options.textThreshold
        }
        let textPages = sampled.filter { hasText(pageTexts[$0] ?? "") }
        let ratio = sampled.isEmpty ? 0 : Double(textPages.count) / Double(sampled.count)

        let type: PDFInspectorType
        let confidence: Double
        if ratio >= 1.0 {
            type = .textBased; confidence = 1.0
        } else if ratio <= 0.0 {
            // Bez tekstualnog sloja: jedna strana bez teksta = slika,
            // više strana = sken (oba se čitaju OCR-om).
            type = pageCount == 1 ? .imageBased : .scanned
            confidence = 0.95
        } else {
            type = .mixed; confidence = 0.5 + ratio / 2
        }

        // 2) Stranice kojima treba OCR (1-indexed, kao upstream pages_needing_ocr).
        // Za sample strategiju proveri i ostatak jeftino (string je keširan u PDFKit).
        var missing: [Int] = []
        let checkSet: [Int]
        switch options.strategy {
        case .earlyExit:
            checkSet = Array(0..<pageCount)
        case .full, .sample, .pages:
            checkSet = Array(0..<pageCount)
        }
        // Cap: ne skeniraj stringove unedogled na ogromnim PDF-ovima —
        // prvih 60 strana je dovoljno za pages_needing_ocr + excerpt.
        let checkCap = min(pageCount, 60)
        for idx in checkSet.prefix(checkCap) {
            let s: String
            if let cached = pageTexts[idx] { s = cached }
            else {
                s = doc.page(at: idx)?.string ?? ""
                pageTexts[idx] = s
            }
            if !hasText(s) { missing.append(idx + 1) }
            if case .earlyExit = options.strategy, !missing.isEmpty { break }
        }

        // 3) Ekstrakcija: tekstualni sloj + selektivni OCR samo za stranice
        // koje ga nemaju (kao upstream selective OCR — čisti tekstualni PDF-ovi
        // nikad ne dodiruju Vision).
        var ocrUsed = false
        var fullPages: [String] = []
        fullPages.reserveCapacity(min(pageCount, checkCap))
        for idx in 0..<min(pageCount, checkCap) {
            let layer = (pageTexts[idx] ?? doc.page(at: idx)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if hasText(layer) {
                fullPages.append(layer)
            } else if options.ocrMissingPages,
                      missing.contains(idx + 1),
                      missing.prefix(options.ocrMaxPages).contains(idx + 1),
                      let page = doc.page(at: idx),
                      let img = pageImage(page) {
                let scanned = recognizeText(in: img)
                ocrUsed = true
                fullPages.append(scanned.isEmpty ? layer : scanned)
            } else {
                fullPages.append(layer)
            }
        }
        let fullText = fullPages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            return PDFInspectorResult(pdfType: type, confidence: confidence,
                                      pageCount: pageCount, pagesNeedingOcr: missing,
                                      text: nil, markdown: nil, title: title, ocrUsed: ocrUsed)
        }
        let md = toMarkdown(fullText, pageCount: pageCount, pagesRead: min(pageCount, checkCap))
        return PDFInspectorResult(pdfType: type, confidence: confidence,
                                  pageCount: pageCount, pagesNeedingOcr: missing,
                                  text: fullText, markdown: md, title: title, ocrUsed: ocrUsed)
    }

    private static func sampledPageIndexes(pageCount: Int, strategy: PDFInspectorScanStrategy) -> [Int] {
        guard pageCount > 0 else { return [] }
        switch strategy {
        case .earlyExit, .full:
            return Array(0..<pageCount)
        case .sample(let n):
            let n = max(1, n)
            if pageCount <= n { return Array(0..<pageCount) }
            // Ravnomerno: prva, poslednja + sredina (kao upstream).
            var idxs = Set<Int>()
            for i in 0..<n {
                idxs.insert(Int(Double(i) * Double(pageCount - 1) / Double(n - 1)))
            }
            return idxs.sorted()
        case .pages(let nums):
            return nums.compactMap { $0 >= 1 && $0 <= pageCount ? $0 - 1 : nil }.sorted()
        }
    }

    // MARK: Markdown (laka normalizacija tekstualnog sloja)

    static func toMarkdown(_ text: String, pageCount: Int, pagesRead: Int) -> String {
        var lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Spoj rastavljenih reči na kraju reda ("faktur-\na" → "faktura").
        var merged: [String] = []
        merged.reserveCapacity(lines.count)
        for line in lines {
            if let last = merged.last, last.hasSuffix("-"),
               let first = line.first, first.isLetter, first.isLowercase {
                merged[merged.count - 1] = String(last.dropLast()) + line
            } else {
                merged.append(line)
            }
        }
        lines = merged
        // Sabij prazne redove (max 1 uzastopni) i tačkaste lidere iz sadržaja.
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var blanks = 0
        for var line in lines {
            if line.isEmpty { blanks += 1; if blanks <= 1 { out.append("") }; continue }
            blanks = 0
            // TOC tačke "Uvod ..... 5" → "Uvod ... 5"
            if line.contains("..") {
                line = line.replacingOccurrences(of: "\\.{3,}", with: " ... ", options: .regularExpression)
                line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            // Bullet znaci → Markdown lista.
            if let f = line.first, "•○●◦▪–".contains(f) {
                line = "- " + line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            // Kratke ALL-CAPS linije su skoro uvek naslovi (fakture, ugovori).
            if line.count <= 80, !line.hasSuffix("."),
               line == line.uppercased(),
               line.filter({ $0.isLetter }).count >= 4 {
                line = "## " + line.capitalized
            }
            out.append(line)
        }
        var md = out.joined(separator: "\n")
        // Višestruki razmaci → jedan (tabele ostaju čitljive, tokeni se štede).
        md = md.replacingOccurrences(of: "[ \\t]{3,}", with: "  ", options: .regularExpression)
        md = md.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if pagesRead < pageCount {
            md += "\n\n<!-- First \(pagesRead) of \(pageCount) pages read; ask for more with --select-pages -->"
        }
        return md
    }

    // MARK: OCR (on-device Vision — ništa se ne uploaduje)

    static func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Stranica renderovana ~2000px po dužoj strani — dovoljno oštro za OCR.
    static func pageImage(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(4, 2000 / max(box.width, box.height))
        var rect = CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale)
        return page.thumbnail(of: rect.size, for: .mediaBox).cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
