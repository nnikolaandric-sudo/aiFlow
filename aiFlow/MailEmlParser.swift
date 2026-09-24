import Foundation
import CryptoKit

// MARK: - .eml parser (MAIL-01, local-first)
//
// RFC5322 + MIME multipart, dependency-free: headers (folded, RFC2047),
// base64 / quoted-printable bodies and attachments, nested multiparts.
// No network — .eml import and Mail.app drag&drop work offline; Gmail/Graph/
// IMAP connectors (MailConnector protocol in MailFilingService) deliver the
// same bytes later, so this parser is the single entry point either way.

struct ParsedAttachment {
    var filename: String
    var mimeType: String
    var data: Data
    var meta: MailAttachmentMeta {
        MailAttachmentMeta(filename: filename, mimeType: mimeType,
                           size: Int64(data.count), sha256: MailEmlParser.sha256(data))
    }
}

struct ParsedEmail {
    var messageID: String
    var threadID: String
    var from: String
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    var date: Date
    var attachments: [ParsedAttachment]
    var rawData: Data

    /// Stable dedup key: Message-ID, or From|Subject|timestamp when the mail
    /// has none (some MTAs omit it — without this every sync re-ingests them).
    /// Matches EmailMessage.fallbackID so store lookups agree.
    var dedupID: String {
        messageID.isEmpty ? "\(from)|\(subject)|\(date.timeIntervalSince1970)" : messageID
    }
}

enum MailEmlParser {
    // MARK: Entry points

    static func parse(url: URL) throws -> ParsedEmail {
        let data = try Data(contentsOf: url)
        return parse(data: data)
    }

    static func parse(data: Data) -> ParsedEmail {
        // Split header / body at the first blank line (CRLF or LF).
        let (headerData, bodyData) = splitHeaderBody(data)
        let headerText = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1) ?? ""
        let headers = parseHeaders(headerText)
        let subject = decodeWords(headers["subject"] ?? "")
        let from = firstAddress(headers["from"] ?? "")
        let to = allAddresses(headers["to"] ?? "")
        let cc = allAddresses(headers["cc"] ?? "")
        let messageID = (headers["message-id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let date = parseDate(headers["date"] ?? "")
        let contentType = headers["content-type"] ?? "text/plain"

        var body = ""
        var attachments: [ParsedAttachment] = []
        if contentType.lowercased().hasPrefix("multipart/"),
           let boundary = boundary(from: contentType) {
            let parts = splitMultipart(bodyData, boundary: boundary)
            var plainCandidates: [String] = []
            var htmlCandidates: [String] = []
            for part in parts { collect(part: part, plain: &plainCandidates, html: &htmlCandidates, attachments: &attachments) }
            body = plainCandidates.first ?? htmlCandidates.map(stripHTML).first(where: { !$0.isEmpty }) ?? ""
        } else {
            let encoding = headers["content-transfer-encoding"] ?? "7bit"
            let decoded = decode(bodyData, encoding: encoding)
            if contentType.lowercased().contains("html") {
                body = stripHTML(asText(decoded, contentType: contentType))
            } else {
                body = asText(decoded, contentType: contentType)
            }
        }
        let threadID = threadID(headers: headers, subject: subject)
        return ParsedEmail(messageID: messageID, threadID: threadID, from: from,
                           to: to, cc: cc, subject: subject,
                           body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                           date: date, attachments: attachments, rawData: data)
    }

    // MARK: MIME tree

    private static func collect(part: Data, plain: inout [String], html: inout [String],
                                attachments: inout [ParsedAttachment]) {
        let (hData, bData) = splitHeaderBody(part)
        let hText = String(data: hData, encoding: .utf8)
            ?? String(data: hData, encoding: .isoLatin1) ?? ""
        let h = parseHeaders(hText)
        let ctype = (h["content-type"] ?? "text/plain").lowercased()
        let disp = (h["content-disposition"] ?? "").lowercased()
        let encoding = h["content-transfer-encoding"] ?? "7bit"
        if ctype.hasPrefix("multipart/"), let b = boundary(from: h["content-type"] ?? "") {
            for sub in splitMultipart(bData, boundary: b) {
                collect(part: sub, plain: &plain, html: &html, attachments: &attachments)
            }
            return
        }
        let filename = attachmentFilename(contentType: h["content-type"] ?? "",
                                          disposition: h["content-disposition"] ?? "")
        let isAttachment = disp.hasPrefix("attachment") || (filename != nil && !disp.hasPrefix("inline") || (filename != nil && ctype.hasPrefix("application/")))
        if let name = filename, isAttachment || disp.hasPrefix("attachment") {
            let bytes = decode(bData, encoding: encoding)
            let clean = sanitizeFilename(decodeWords(name))
            guard !clean.isEmpty else { return }
            attachments.append(ParsedAttachment(filename: clean, mimeType: ctype.split(separator: ";").first.map(String.init) ?? "application/octet-stream", data: bytes))
            return
        }
        if ctype.hasPrefix("text/plain") {
            let t = asText(decode(bData, encoding: encoding), contentType: h["content-type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { plain.append(t) }
        } else if ctype.hasPrefix("text/html") {
            let t = asText(decode(bData, encoding: encoding), contentType: h["content-type"] ?? "")
            if !t.isEmpty { html.append(t) }
        } else if ctype.hasPrefix("message/rfc822") {
            // Forwarded message: recurse so its attachments are not lost.
            let nested = parse(data: bData)
            if !nested.body.isEmpty { plain.append(nested.body) }
            attachments += nested.attachments
        }
        // image/* inline without filename: keep as attachment so OCR still sees it.
        else if disp.hasPrefix("inline"), let name = filename ?? defaultInlineName(ctype) {
            let bytes = decode(bData, encoding: encoding)
            guard !bytes.isEmpty else { return }
            attachments.append(ParsedAttachment(filename: name, mimeType: ctype.split(separator: ";").first.map(String.init) ?? "application/octet-stream", data: bytes))
        }
    }

    // MARK: Headers

    static func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        func flush() {
            if let k = currentKey { out[k] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                currentKey = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return out
    }

    /// RFC2047 encoded-words: =?charset?B|Q?text?=
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var result = s
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for m in matches {
            guard let r = Range(m.range, in: s),
                  let cR = Range(m.range(at: 1), in: s),
                  let eR = Range(m.range(at: 2), in: s),
                  let tR = Range(m.range(at: 3), in: s) else { continue }
            let charset = String(s[cR]).lowercased()
            let enc = String(s[eR]).uppercased()
            let text = String(s[tR])
            let decoded: String
            if enc == "B", let d = Data(base64Encoded: text.filter { !$0.isWhitespace }) {
                decoded = string(d, charset: charset)
            } else {
                decoded = decodeQ(text, charset: charset)
            }
            result.replaceSubrange(r, with: decoded)
        }
        return result
    }

    private static func string(_ d: Data, charset: String) -> String {
        if charset.hasPrefix("utf-8") || charset.hasPrefix("utf8") { return String(data: d, encoding: .utf8) ?? "" }
        if charset.hasPrefix("iso-8859") || charset.hasPrefix("latin") { return String(data: d, encoding: .isoLatin1) ?? "" }
        if charset.hasPrefix("windows-125") { return String(data: d, encoding: .windowsCP1250) ?? String(data: d, encoding: .isoLatin1) ?? "" }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
    }

    private static func decodeQ(_ s: String, charset: String) -> String {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "_" { bytes.append(0x20); i = s.index(after: i) }
            else if c == "=", let h1 = s.index(i, offsetBy: 1, limitedBy: s.endIndex),
                    let h2 = s.index(i, offsetBy: 2, limitedBy: s.endIndex), h2 < s.endIndex,
                    let b = UInt8(String(s[h1...h2].prefix(2)), radix: 16) {
                bytes.append(b); i = s.index(i, offsetBy: 3, limitedBy: s.endIndex) ?? s.endIndex
            } else {
                bytes.append(contentsOf: String(c).utf8); i = s.index(after: i)
            }
        }
        return string(Data(bytes), charset: charset)
    }

    // MARK: Bodies

    private static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        if let r = data.range(of: Data("\r\n\r\n".utf8)) {
            return (data[..<r.lowerBound], data[r.upperBound...])
        }
        if let r = data.range(of: Data("\n\n".utf8)) {
            return (data[..<r.lowerBound], data[r.upperBound...])
        }
        return (data, Data())
    }

    private static func boundary(from contentType: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"boundary\s*=\s*"?([^";\r\n]+)"?"#, options: .caseInsensitive),
              let m = re.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
              let r = Range(m.range(at: 1), in: contentType) else { return nil }
        return String(contentType[r]).trimmingCharacters(in: .whitespaces)
    }

    private static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let sep = "--" + boundary
        var out: [Data] = []
        for chunk in text.components(separatedBy: sep) {
            var c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.hasPrefix("\r\n") { c = String(c.dropFirst(2)) }
            if c.hasPrefix("\n") { c = String(c.dropFirst()) }
            if c == "--" || c.hasSuffix("--") && c.trimmingCharacters(in: .whitespacesAndNewlines) == "--" { continue }
            if c.hasSuffix("--") { c = String(c.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !c.isEmpty, c.contains(":") || c.contains("Content-") else { continue }
            if let d = c.data(using: .utf8) { out.append(d) }
        }
        return out
    }

    private static func decode(_ data: Data, encoding: String) -> Data {
        switch encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64":
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            return Data(base64Encoded: text.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            if b == 0x3D { // "="
                let n1 = data.index(after: i)
                if n1 < data.endIndex {
                    let c1 = data[n1]
                    if c1 == 0x0D || c1 == 0x0A { // soft break
                        i = data.index(after: n1)
                        if c1 == 0x0D, i < data.endIndex, data[i] == 0x0A { i = data.index(after: i) }
                        continue
                    }
                    let n2 = data.index(after: n1)
                    if n2 < data.endIndex,
                       let h = String(bytes: [c1, data[n2]], encoding: .utf8),
                       let v = UInt8(h, radix: 16) {
                        out.append(v); i = data.index(after: n2); continue
                    }
                }
                out.append(b); i = data.index(after: i)
            } else { out.append(b); i = data.index(after: i) }
        }
        return out
    }

    private static func asText(_ data: Data, contentType: String) -> String {
        let lower = contentType.lowercased()
        if lower.contains("utf-8") || lower.contains("utf8") { return String(data: data, encoding: .utf8) ?? "" }
        if let s = String(data: data, encoding: .utf8), s.filter({ $0.isLetter }).count > 0 { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive, range: nil)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression, range: nil)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Addresses / dates / threads

    static func firstAddress(_ s: String) -> String {
        allAddresses(s).first ?? decodeWords(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func allAddresses(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        let decoded = decodeWords(s)
        guard let re = try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive) else { return [] }
        let matches = re.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        var seen: [String] = []
        for m in matches {
            if let r = Range(m.range, in: decoded) {
                let e = String(decoded[r]).lowercased()
                if !seen.contains(e) { seen.append(e) }
            }
        }
        return seen
    }

    static func parseDate(_ s: String) -> Date {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return Date() }
        let formats = ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss Z",
                       "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss Z",
                       "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
            // Strip parenthesised zone comment "(CET)".
            if let paren = t.firstIndex(of: "(") {
                let stripped = String(t[..<paren]).trimmingCharacters(in: .whitespaces)
                f.dateFormat = fmt
                if let d = f.date(from: stripped) { return d }
            }
        }
        return Date()
    }

    /// Stable thread id: In-Reply-To / References win, else normalized subject.
    static func threadID(headers: [String: String], subject: String) -> String {
        if let reply = headers["in-reply-to"], !reply.isEmpty {
            return reply.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        if let refs = headers["references"], let first = refs.split(separator: " ").first {
            return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        var s = subject.lowercased()
        for p in ["re:", "fw:", "fwd:", "odg:", "прос:"] { if s.hasPrefix(p) { s = String(s.dropFirst(p.count)) } }
        return "subj:" + s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attachmentFilename(contentType: String, disposition: String) -> String? {
        for src in [disposition, contentType] {
            if let re = try? NSRegularExpression(pattern: #"filename\*?=\s*(?:UTF-8''|utf-8''|"?)([^";\r\n]+)"?"#, options: .caseInsensitive),
               let m = re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
               let r = Range(m.range(at: 1), in: src) {
                let raw = String(src[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return raw.removingPercentEncoding ?? raw
            }
            if let re = try? NSRegularExpression(pattern: #"name\s*=\s*"([^"]+)"|name\s*=\s*([^;\s]+)"#, options: .caseInsensitive),
               let m = re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) {
                for idx in [1, 2] {
                    if m.range(at: idx).location != NSNotFound, let r = Range(m.range(at: idx), in: src) {
                        return String(src[r])
                    }
                }
            }
        }
        return nil
    }

    private static func defaultInlineName(_ ctype: String) -> String? {
        if ctype.hasPrefix("image/") {
            let ext = ctype.split(separator: "/").last.map(String.init) ?? "png"
            return "inline-image.\(ext.split(separator: ";").first.map(String.init) ?? "png")"
        }
        return nil
    }

    static func sanitizeFilename(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
