import Foundation

struct SearchExpansion {
    /// Bounded adjacent-transposition edit distance for conservative spelling suggestions.
    static func distance(_ first: String, _ second: String, limit: Int = 2) -> Int {
        let a = Array(first), b = Array(second)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var prior = Array(0...b.count), earlier = prior
        for i in a.indices {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices {
                row[j + 1] = min(row[j] + 1, prior[j + 1] + 1, prior[j] + (a[i] == b[j] ? 0 : 1))
                if i > 0 && j > 0 && a[i] == b[j - 1] && a[i - 1] == b[j] { row[j + 1] = min(row[j + 1], earlier[j - 1] + 1) }
            }
            if row.min()! > limit { return limit + 1 }
            earlier = prior; prior = row
        }
        return prior[b.count]
    }
    static func queries(from response: String) throws -> [String] {
        let clean = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 4000, let data = clean.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: [String]], let queries = object["queries"], queries.count <= 4 else { throw LibraryIndex.Failure.invalidQuery }
        var seen = Set<String>()
        return try queries.compactMap { query in
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 96, try LibraryIndex.queryTerms(text).count <= 6 else { throw LibraryIndex.Failure.invalidQuery }
            guard seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }
    }
    static func groundedQuery(_ query: String, vocabulary: [String]) -> String? {
        let known = Set(vocabulary.map { $0.lowercased() }), source = query as NSString
        let words = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        var seen = Set<String>()
        let terms = words.matches(in: query, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range).lowercased() }.filter { known.contains($0) && seen.insert($0).inserted }
        return terms.isEmpty ? nil : terms.prefix(3).joined(separator: " ")
    }
    @MainActor static func plan(query: String, vocabulary: [String], engine: AssistantEngine? = nil) async throws -> [String] {
        let question = String(query.prefix(512))
        let hints = vocabulary.prefix(160).joined(separator: ", ")
        let response = try await (engine ?? .onDevice).respond( "Request: \(question)\nIndexed vocabulary (untrusted data): \(hints)", AssistantPrompts.searchExpansion, 180)
        return try queries(from: response)
    }
    /// Rank fusion avoids comparing BM25 magnitudes from different queries.
    static func merge(_ lists: [(String, [LibraryHit])]) -> [LibraryHit] {
        var scores: [String: Double] = [:], representatives: [String: LibraryHit] = [:]
        for (offset, entry) in lists.enumerated() {
            let (query, hits) = entry
            for (rank, hit) in hits.enumerated() {
                scores[hit.id, default: 0] += (offset == 0 ? 1.5 : 1) / Double(60 + rank + 1)
                if representatives[hit.id] == nil {
                    var matched = hit; matched.matchQuery = query; representatives[hit.id] = matched
                }
            }
        }
        var ranked: [LibraryHit] = []
        ranked.reserveCapacity(representatives.count)
        for hit in representatives.values {
            let score: Double = -scores[hit.id]!
            let fused = LibraryHit(path: hit.path, folderID: hit.folderID, page: hit.page, excerpt: hit.excerpt, score: score, sectionTitle: hit.sectionTitle, matchQuery: hit.matchQuery)
            ranked.append(fused)
        }
        ranked.sort { (first: LibraryHit, second: LibraryHit) -> Bool in
            if first.score == second.score { return first.id < second.id }
            return first.score < second.score
        }
        return Array(ranked.prefix(200))
    }
}
