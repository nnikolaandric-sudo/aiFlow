#!/usr/bin/env swift
// pdf-inspect — CLI za AI agente (Jev, Claude Code, Codex, Cursor, budući agenti).
//
// Brzo čitanje PDF-a lokalno na Mac-u, bez mreže i bez OCR servisa:
// klasifikacija (text/scanned/mixed) + čist Markdown + JSON za pipe-ove.
// Port ideje firecrawl/pdf-inspector (MIT) u Swift/PDFKit — deli kod sa
// FinderFlow/PDFInspector.swift pa se ponašaju identično.
//
// Build (bez Xcode-a, samo Command Line Tools):
//   ./tools/pdf-inspect/run.sh dokument.pdf --json
//
// Direktno (sporije, bez builda):
//   swift -M ... // ne — koristi run.sh, PDFKit treba SDK link.
//
// Usage:
//   pdf-inspect dokument.pdf [--json] [--markdown] [--raw] [--excerpt N]
//             [--detect] [--select-pages 1,3,5-10] [--no-ocr] [--pretty]
//
//   Bez flaga štampa Markdown. --json štampa detekciju + Markdown zajedno
//   (pogodno za `| jq` i za Jev/AI prompt excerpt).
import Foundation
import PDFKit
import Vision

// MARK: - Ponovljene jezgre iz PDFInspector.swift (CLI je standalone binary)

// NOTE: CLI namerno NE uvozi celu aplikaciju — kopira minimum iz
// FinderFlow/PDFInspector.swift da ostane jedan fajl za `swiftc`.
// Ako menjaš logiku, promeni na OBA mesta (app + ovaj fajl).

enum PIType: String, Codable {
    case textBased = "text_based"
    case scanned = "scanned"
    case imageBased = "image_based"
    case mixed = "mixed"
}

struct PIResult: Codable {
    var pdfType: PIType
    var confidence: Double
    var pageCount: Int
    var pagesNeedingOcr: [Int]
    var text: String?
    var markdown: String?
    var title: String?
    var ocrUsed: Bool

    enum CodingKeys: String, CodingKey {
        case pdfType = "pdf_type"
        case confidence
        case pageCount = "page_count"
        case pagesNeedingOcr = "pages_needing_ocr"
        case text, markdown, title
        case ocrUsed = "ocr_used"
    }
}

func piHasText(_ s: String) -> Bool {
    s.filter { $0.isLetter || $0.isNumber }.count >= 40
}

func piRecognize(_ image: CGImage) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.automaticallyDetectsLanguage = true
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return "" }
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func piPageImage(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = min(4, 2000 / max(box.width, box.height))
    var rect = CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale)
    return page.thumbnail(of: rect.size, for: .mediaBox).cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func piToMarkdown(_ text: String) -> String {
    var lines = text.replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    var merged: [String] = []
    for line in lines {
        if let last = merged.last, last.hasSuffix("-"),
           let first = line.first, first.isLetter, first.isLowercase {
            merged[merged.count - 1] = String(last.dropLast()) + line
        } else { merged.append(line) }
    }
    lines = merged
    var out: [String] = []
    var blanks = 0
    for var line in lines {
        if line.isEmpty { blanks += 1; if blanks <= 1 { out.append("") }; continue }
        blanks = 0
        if line.contains("..") {
            line = line.replacingOccurrences(of: "\\.{3,}", with: " ... ", options: .regularExpression)
            line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if let f = line.first, "•○●◦▪–".contains(f) {
            line = "- " + line.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        if line.count <= 80, !line.hasSuffix("."),
           line == line.uppercased(),
           line.filter({ $0.isLetter }).count >= 4 {
            line = "## " + line.capitalized
        }
        out.append(line)
    }
    return out.joined(separator: "\n")
        .replacingOccurrences(of: "[ \\t]{3,}", with: "  ", options: .regularExpression)
        .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func piExcerpt(_ md: String, maxChars: Int) -> String {
    let c = md.split(whereSeparator: \.isNewline)
        .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
    return String(c.prefix(maxChars))
}

/// "1,3,5-10" → sortirani 1-indexed brojevi.
func parseSelectPages(_ s: String, pageCount: Int) -> [Int] {
    var out = Set<Int>()
    for part in s.split(separator: ",") {
        let p = part.trimmingCharacters(in: .whitespaces)
        if p.contains("-") {
            let b = p.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if b.count == 2 {
                for n in min(b[0], b[1])...max(b[0], b[1]) where n >= 1 && n <= pageCount { out.insert(n) }
            }
        } else if let n = Int(p), n >= 1 && n <= pageCount { out.insert(n) }
    }
    return out.sorted()
}

func process(url: URL, selectPages: [Int]?, useOCR: Bool) -> PIResult? {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
    let pageCount = doc.pageCount
    let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let wanted: [Int] = {
        if let s = selectPages, !s.isEmpty { return s.map { $0 - 1 }.filter { $0 >= 0 && $0 < pageCount } }
        return Array(0..<min(pageCount, 60))
    }()
    var layerTexts: [Int: String] = [:]
    for i in wanted { layerTexts[i] = doc.page(at: i)?.string ?? "" }
    // Klasifikacija uzorkom do 8 strana (kao upstream Sample(8)).
    var sample = wanted
    if sample.count > 8 {
        sample = (0..<8).map { sample[Int(Double($0) * Double(sample.count - 1) / 7.0)] }
    }
    let textInSample = sample.filter { piHasText(layerTexts[$0] ?? "") }.count
    let ratio = sample.isEmpty ? 0 : Double(textInSample) / Double(sample.count)
    let type: PIType
    let conf: Double
    if ratio >= 1.0 { type = .textBased; conf = 1.0 }
    else if ratio <= 0.0 { type = pageCount == 1 ? .imageBased : .scanned; conf = 0.95 }
    else { type = .mixed; conf = 0.5 + ratio / 2 }
    var missing: [Int] = []
    for i in wanted where !piHasText(layerTexts[i] ?? "") { missing.append(i + 1) }
    var ocrUsed = false
    var pages: [String] = []
    for i in wanted {
        let layer = (layerTexts[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if piHasText(layer) { pages.append(layer) }
        else if useOCR, missing.prefix(4).contains(i + 1),
                let page = doc.page(at: i), let img = piPageImage(page) {
            let t = piRecognize(img)
            ocrUsed = true
            pages.append(t.isEmpty ? layer : t)
        } else { pages.append(layer) }
    }
    let full = pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !full.isEmpty else {
        return PIResult(pdfType: type, confidence: conf, pageCount: pageCount,
                        pagesNeedingOcr: missing, text: nil, markdown: nil, title: title, ocrUsed: ocrUsed)
    }
    return PIResult(pdfType: type, confidence: conf, pageCount: pageCount,
                    pagesNeedingOcr: missing, text: full, markdown: piToMarkdown(full),
                    title: title, ocrUsed: ocrUsed)
}

// MARK: - Args

func usage() -> Never {
    fputs("""
    pdf-inspect — lokalno čitanje PDF-a za AI agente (FinderFlow, Jev, Claude Code, Codex…)

    Usage: pdf-inspect dokument.pdf [--json] [--raw] [--excerpt N] [--detect]
               [--select-pages 1,3,5-10] [--no-ocr] [--pretty]

      (bez flaga)            Markdown na stdout
      --json                 JSON: pdf_type, confidence, page_count, pages_needing_ocr, markdown…
      --pretty               JSON sa uvlačenjem (uz --json)
      --raw                  samo Markdown bez headera (isto kao bez flaga)
      --excerpt N            AI izvod: jedna linija po izvornoj liniji, max N znakova
      --detect               samo klasifikacija: "text_based (1.00), 12 pages"
      --select-pages LIST    samo date strane, npr. 1,3,5-10
      --no-ocr               bez Vision OCR-a (samo tekstualni sloj)

    Primeri:
      pdf-inspect faktura.pdf --json | jq .pdf_type
      pdf-inspect sken.pdf --excerpt 4000
      pdf-inspect ugovor.pdf --select-pages 1-3 --json --pretty
    """, stderr)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let pdfPath = args.first(where: { !$0.hasPrefix("-") }) else { usage() }
let url = URL(fileURLWithPath: pdfPath)
guard FileManager.default.fileExists(atPath: url.path) else {
    fputs("pdf-inspect: ne postoji: \(pdfPath)\n", stderr); exit(1)
}
let wantJSON = args.contains("--json")
let pretty = args.contains("--pretty")
let wantDetect = args.contains("--detect")
let wantRaw = args.contains("--raw")
let useOCR = !args.contains("--no-ocr")
var excerptN: Int?
if let i = args.firstIndex(of: "--excerpt"), i + 1 < args.count, let n = Int(args[i + 1]) { excerptN = n }
var selectPages: [Int]?
if let i = args.firstIndex(of: "--select-pages"), i + 1 < args.count {
    // pageCount tek nakon otvaranja — privremeno parsiraj široko.
    selectPages = args[i + 1].split(separator: ",").flatMap { part -> [Int] in
        let p = part.trimmingCharacters(in: .whitespaces)
        if p.contains("-") {
            let b = p.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if b.count == 2 { return Array(min(b[0], b[1])...max(b[0], b[1])) }
            return []
        }
        return Int(p).map { [$0] } ?? []
    }
}

guard let doc = PDFDocument(url: url) else {
    fputs("pdf-inspect: ne mogu da otvorim PDF: \(pdfPath)\n", stderr); exit(1)
}
let validSelect = selectPages.map { parseSelectPages($0.map(String.init).joined(separator: ","), pageCount: doc.pageCount) }
guard let r = process(url: url, selectPages: validSelect, useOCR: useOCR) else {
    fputs("pdf-inspect: prazan ili nečitljiv PDF: \(pdfPath)\n", stderr); exit(1)
}

if wantDetect {
    print("\(r.pdfType.rawValue) (\(String(format: "%.2f", r.confidence))), \(r.pageCount) \(r.pageCount == 1 ? "page" : "pages")\(r.ocrUsed ? ", OCR used" : "")")
    exit(0)
}
if let n = excerptN {
    if let md = r.markdown { print(piExcerpt(md, maxChars: n)) }
    exit(0)
}
if wantJSON {
    let enc = JSONEncoder()
    if pretty { enc.outputFormatting = [.prettyPrinted, .sortedKeys] }
    if let data = try? enc.encode(r), let s = String(data: data, encoding: .utf8) { print(s) }
    else { fputs("pdf-inspect: JSON encode failed\n", stderr); exit(1) }
    exit(0)
}
// default + --raw: čist Markdown (header samo kad NIJE --raw, kao pdf2md).
if wantRaw, let md = r.markdown { print(md) }
else if let md = r.markdown {
    print("# \(url.deletingPathExtension().lastPathComponent)")
    print("<!-- \(r.pdfType.rawValue), \(r.pageCount) pages\(r.ocrUsed ? ", OCR" : "") -->")
    print("")
    print(md)
}
