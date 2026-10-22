import Foundation

struct ReviewCatalog: Codable {
    struct Criterion: Codable {
        struct Example: Codable { let scenario: String; let question: String; let synthetic: Bool }
        let id: String; let title: String; let check: String; let example: Example; let suppressWhen: String
    }
    let schemaVersion: Int; let version: String; let examples: String; let criteria: [Criterion]
    static func resource(_ name: String) throws -> Data {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("others/templates/review/" + name)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Templates/Review/" + name)
        return try Data(contentsOf: [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) } ?? source)
    }
    static func load() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: resource("criteria.json"))
        guard value.schemaVersion == 1, !value.criteria.isEmpty, Set(value.criteria.map(\.id)).count == value.criteria.count else { throw ReviewFailure("Review criteria could not be loaded.") }
        return value
    }
    static func instructions() throws -> String { String(decoding: try resource("question-style.md"), as: UTF8.self) }
}
struct ReviewFailure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
struct ReviewAnchor: Codable {
    let file: String; let quote: String; let line: Int; let offset: Int; let sourceSHA256: String
}
struct ReviewQuestion: Codable, Identifiable {
    let id: UUID; let criterion: String; let question: String; let reason: String; let anchors: [ReviewAnchor]
}
struct ReviewRun: Codable, Identifiable {
    let id: UUID; let createdAt: Date; let criteriaVersion: String; let provider: String
    let fingerprint: String; let sourceHashes: [String: String]; let scope: String; let omittedFiles: Int
    let questions: [ReviewQuestion]
}
struct ReviewArchive: Codable {
    var schemaVersion = 1
    var root: String
    var runs: [ReviewRun] = []
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    func markdown() -> String {
        func safe(_ text: String) -> String {
            var value = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            for token in ["\\", "`", "[", "]", "*", "_", "!", "#"] { value = value.replacingOccurrences(of: token, with: "\\" + token) }
            return value
        }
        func quote(_ text: String) -> String { text.components(separatedBy: .newlines).map { "> " + safe($0) }.joined(separator: "\n") }
        var lines = ["# Manuscript review", "", "Project: " + safe(root), "", "Questions for the author, not scientific verdicts. Source hashes identify the reviewed versions.", ""]
        for run in runs {
            lines += ["## " + run.createdAt.formatted(date: .abbreviated, time: .shortened), "", "Scope: " + safe(run.scope) + " · Provider: " + safe(run.provider) + " · Criteria: " + run.criteriaVersion, ""]
            if run.omittedFiles > 0 { lines += ["Partial context: \(run.omittedFiles) project files were not included.", ""] }
            if run.questions.isEmpty { lines += ["No grounded questions returned for this scope. This is not an assurance that the manuscript has no issues.", ""] }
            for item in run.questions {
                lines += ["### " + safe(item.question), "", safe(item.reason), "", "Criterion: " + item.criterion, ""]
                for anchor in item.anchors { lines += [safe(anchor.file) + ":" + String(anchor.line + 1) + " · SHA256 " + anchor.sourceSHA256, "", quote(anchor.quote), ""] }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
    func response(format: PDFCommentExport.Format, output: String?) throws -> [String: Any] {
        let bytes = format == .json ? try Self.encoder().encode(self) : Data(markdown().utf8)
        if let output {
            guard output.hasPrefix("/"), URL(fileURLWithPath: output).pathExtension.lowercased() == (format == .json ? "json" : "md") else { throw ReviewFailure("Choose a new absolute .json or .md export file.") }
            try bytes.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
            return ["ok": true, "output": output, "runs": runs.count, "questions": runs.reduce(0) { $0 + $1.questions.count }]
        }
        if format == .markdown { return ["ok": true, "markdown": String(decoding: bytes, as: UTF8.self)] }
        var value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]; value["ok"] = true; return value
    }
}
struct ReviewContext {
    let documents: [String: String]; let sourceHashes: [String: String]; let selected: String; let omittedFiles: Int; let truncated: [String]
    static func make(buffers: [String: String], selected: String, budget: Int) throws -> Self {
        guard buffers[selected] != nil else { throw ReviewFailure("Choose an editable source file first.") }
        let paths = [selected] + buffers.keys.filter { $0 != selected && ["tex", "bib"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        var remaining = budget, documents: [String: String] = [:], hashes: [String: String] = [:], truncated: [String] = []
        for path in paths where documents.count < 12 && remaining > 0 {
            let text = buffers[path]!, part = AssistantEvidence.bounded(text, bytes: min(remaining, path == selected ? budget * 2 / 3 : budget / 4))
            guard !part.isEmpty else { continue }
            documents[path] = part; hashes[path] = SourceDigest.sha256(text); remaining -= part.utf8.count
            if part.utf8.count < text.utf8.count { truncated.append(path) }
        }
        guard !documents.isEmpty else { throw ReviewFailure("This source has no text to review.") }
        return Self(documents: documents, sourceHashes: hashes, selected: selected, omittedFiles: max(0, buffers.count - documents.count), truncated: truncated)
    }
    func fingerprint(criteria: String, provider: String) -> String {
        let parts = documents.keys.sorted().map { $0 + ":" + sourceHashes[$0]! + ":" + SourceDigest.sha256(documents[$0]!) }
        return SourceDigest.sha256(([selected, criteria, provider] + parts).joined(separator: "\n"))
    }
    func request(catalog: ReviewCatalog, compact: Bool = false) throws -> String {
        let criteria: Any = compact ? catalog.criteria.map { ["id": $0.id, "check": $0.check, "suppressWhen": $0.suppressWhen] } : try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog))
        let value: [String: Any] = ["selectedFile": selected, "documents": documents, "omittedFiles": omittedFiles, "truncatedFiles": truncated, "maximumFindings": compact ? 2 : 5, "criteria": criteria]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }
    func questions(from response: String, catalog: ReviewCatalog) throws -> [ReviewQuestion] {
        struct Reply: Decodable {
            struct Item: Decodable {
                struct Anchor: Decodable { let file: String; let quote: String }
                let criterion: String; let question: String; let reason: String; let anchors: [Anchor]
            }
            let findings: [Item]
        }
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let first = text.firstIndex(of: "\n"), text.hasSuffix("```") { text = String(text[text.index(after: first)..<text.index(text.endIndex, offsetBy: -3)]) }
        guard text.utf8.count <= 64_000, let bytes = text.data(using: .utf8), let reply = try? JSONDecoder().decode(Reply.self, from: bytes), reply.findings.count <= 5 else { throw ReviewFailure("Review could not be read. Try again.") }
        var questions: [ReviewQuestion] = []
        for item in reply.findings {
            let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard catalog.criteria.contains(where: { $0.id == item.criterion }), !question.isEmpty, question.count <= 500, ["?", "？"].contains(String(question.suffix(1))), !item.reason.isEmpty, item.reason.count <= 1200, (1...3).contains(item.anchors.count) else { throw ReviewFailure("Review did not follow the criteria. Try again.") }
            var anchors: [ReviewAnchor] = []
            for anchor in item.anchors {
                guard let source = documents[anchor.file], !anchor.quote.isEmpty, anchor.quote.count <= 600, source.components(separatedBy: anchor.quote).count == 2, let range = source.range(of: anchor.quote) else { throw ReviewFailure("Source links could not be verified. Try again.") }
                anchors.append(.init(file: anchor.file, quote: anchor.quote, line: source[..<range.lowerBound].filter { $0 == "\n" }.count, offset: NSRange(range, in: source).location, sourceSHA256: sourceHashes[anchor.file]!))
            }
            let distinct = Set(anchors.map { $0.file + ":" + String($0.offset) })
            guard !["consistency", "clarity"].contains(item.criterion) || distinct.count >= 2 else { throw ReviewFailure("A comparison needs two distinct source passages. Saved questions are unchanged.") }
            questions.append(.init(id: UUID(), criterion: item.criterion, question: question, reason: item.reason, anchors: anchors))
        }
        return questions
    }
}
