import Foundation
import Combine
import CryptoKit

enum AIPrivacy {
    static func redact(_ text: String) -> String {
        var result = text
        result = replacing(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", in: result, with: "[email]")
        result = replacing(pattern: "(?=(?:[^0-9]*[0-9]){9})(?:\\+?[0-9][0-9 ()-]{7,}[0-9])", in: result, with: "[phone]")
        result = replacing(pattern: "\\b[A-Z]{2}[0-9]{2}[A-Z0-9 ]{10,}\\b", in: result, with: "[account]")
        return result
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}

struct AIExecutionRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let task: String
    let model: String
    let fileCount: Int
    let inputChars: Int
    let outputChars: Int
    let promptTokens: Int
    let completionTokens: Int
    let costUSD: Double
    let latencyMS: Int
    let success: Bool
    let failure: String?
    let payloadHash: String
}

final class AIExecutionLog: ObservableObject {
    static let shared = AIExecutionLog()

    @Published private(set) var records: [AIExecutionRecord]

    private let queue = DispatchQueue(label: "FinderFlow.aiExecutionLog", qos: .utility)

    private init() {
        records = Self.loadRecords()
    }

    var totalCost: Double { records.reduce(0) { $0 + $1.costUSD } }
    var successfulCount: Int { records.filter(\.success).count }
    var averageLatencyMS: Int { records.isEmpty ? 0 : records.map(\.latencyMS).reduce(0, +) / records.count }

    func record(task: String, model: String, fileCount: Int, inputChars: Int, outputChars: Int,
                promptTokens: Int, completionTokens: Int, costUSD: Double, latencyMS: Int,
                success: Bool, payload: String, failure: Error? = nil) {
        let record = AIExecutionRecord(
            id: UUID(), date: Date(), task: task, model: model, fileCount: fileCount,
            inputChars: inputChars, outputChars: outputChars, promptTokens: promptTokens,
            completionTokens: completionTokens, costUSD: costUSD, latencyMS: latencyMS,
            success: success, failure: failure == nil ? nil : "request_failed", payloadHash: Self.hash(payload))
        queue.async { [weak self] in
            guard let self else { return }
            var all = Self.loadRecords()
            all.insert(record, at: 0)
            if all.count > 250 { all = Array(all.prefix(250)) }
            if let data = try? JSONEncoder().encode(all) {
                try? FileManager.default.createDirectory(at: Self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: Self.storageURL, options: .atomic)
            }
            let published = all
            DispatchQueue.main.async { self.records = published }
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: Self.storageURL)
            DispatchQueue.main.async { self.records = [] }
        }
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadRecords() -> [AIExecutionRecord] {
        guard let data = try? Data(contentsOf: storageURL),
              let records = try? JSONDecoder().decode([AIExecutionRecord].self, from: data) else { return [] }
        return Array(records.prefix(250))
    }

    private static var storageURL: URL {
        let base = ProcessInfo.processInfo.environment["FF_AI_EVAL_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FinderFlow", isDirectory: true)
        return base.appendingPathComponent("AIExecutionLog.json")
    }
}
