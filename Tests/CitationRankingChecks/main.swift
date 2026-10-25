import Foundation

struct EvaluationDocument: Decodable { let key: String; let title: String; let abstract: String }
struct EvaluationCase: Codable { let context: String; let keys: [String]; let kind: String }
struct EvaluationFixture: Decodable { let description: String; let documents: [EvaluationDocument]; let cases: [EvaluationCase] }
func option(_ flag: String) -> String? { CommandLine.arguments.firstIndex(of: flag).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
func read(_ path: String) throws -> Data {
    guard path.hasPrefix("/"), let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000 else { throw ReferenceFailure("Use an absolute input file smaller than 4 MB.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path)); guard data.count <= 4_000_000 else { throw ReferenceFailure("The input is too large.") }; return data
}
func evaluate(_ records: [ReferenceRecord], cases: [EvaluationCase], description: String) throws {
    let index = ReferenceCitationIndex(records), known = Set(records.map(\.citationKey))
    var rows: [[String: Any]] = [], recall = 0.0, reciprocal = 0.0, missing = 0
    for example in cases {
        let expected = Set(example.keys).intersection(known)
        missing += Set(example.keys).subtracting(known).count
        guard !expected.isEmpty else { continue }
        let keys = ReferenceCitationCompletion.suggestions(query: "", project: ReferenceCitationIndex(), library: index, limit: 5, context: example.context).map { $0.record.citationKey }
        let hit = Double(Set(keys).intersection(expected).count) / Double(expected.count)
        let rr = keys.firstIndex(where: expected.contains).map { 1 / Double($0 + 1) } ?? 0
        recall += hit; reciprocal += rr
        rows.append(["kind": example.kind, "context": example.context, "expected": expected.sorted(), "top5": keys, "recallAt5": hit, "reciprocalRankAt5": rr])
    }
    guard !rows.isEmpty else { throw ReferenceFailure("No citation examples have matching bibliography keys.") }
    let report: [String: Any] = ["description": description, "documents": records.count, "examples": rows.count, "missingKeys": missing, "recallAt5": recall / Double(rows.count), "mrrAt5": reciprocal / Double(rows.count), "scientificSupportVerified": false, "cases": rows]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("ranking.json")
    try data.write(to: output, options: .atomic)
    print("Evaluated \(rows.count) examples: recall@5 \(recall / Double(rows.count)), MRR@5 \(reciprocal / Double(rows.count)). Missing keys: \(missing). Output: \(output.path)")
}
do {
    if let tex = option("--tex"), let bib = option("--bib") {
        let source = String(decoding: try read(tex), as: UTF8.self).replacingOccurrences(of: #"(?m)(?<!\\)%[^\n]*"#, with: "", options: .regularExpression)
        let records = try ReferenceBibTeX.parse(String(decoding: try read(bib), as: UTF8.self))
        let pattern = try NSRegularExpression(pattern: #"(?<!\\)\\(?:cite|citep|citet|parencite|textcite|autocite|footcite|smartcite)\*?(?:\[[^\]]*\])*\{([^{}]+)\}"#)
        var cases: [EvaluationCase] = []
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).prefix(2000) {
            let keys = (source as NSString).substring(with: match.range(at: 1)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let context = ReferenceRelevance.sentence(source, before: match.range.location)
            if !context.isEmpty { cases.append(.init(context: context, keys: keys, kind: "existing-citation")) }
        }
        try evaluate(records, cases: cases, description: "Existing manuscript citations are a retrieval reference, not verified scientific ground truth. No manuscript feedback is added to the index. Macro-generated citations and included files are not expanded. MRR is truncated at rank 5.")
    } else if let dataset = option("--dataset") {
        let fixture = try JSONDecoder().decode(EvaluationFixture.self, from: read(dataset))
        try evaluate(fixture.documents.map { ReferenceRecord(key: $0.key, fields: ["title": $0.title, "abstract": $0.abstract]) }, cases: fixture.cases, description: fixture.description)
    } else { throw ReferenceFailure("Provide --dataset, or --tex and --bib.") }
} catch { print("FAILED: \(error)"); exit(1) }
