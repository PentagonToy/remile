import Foundation

enum SearchResultOrder: String, CaseIterable {
    case relevance = "Relevance", document = "Document order"
}

struct SearchResultGroup: Identifiable {
    let path: String
    let hits: [LibraryHit]
    let bestRank: Int
    let ranks: [String: Int]
    var id: String { path }
    var name: String { hits.first?.name ?? "" }
    func rank(for hit: LibraryHit) -> Int? { ranks[hit.id] }
    static func make(_ hits: [LibraryHit], filter: String = "", order: SearchResultOrder = .relevance) -> [SearchResultGroup] {
        let filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var paths: [String] = [], groups: [String: [LibraryHit]] = [:], ranks: [String: Int] = [:]
        for (offset, hit) in hits.enumerated() {
            guard filter.isEmpty || hit.path.localizedStandardContains(filter) else { continue }
            if groups[hit.path] == nil { paths.append(hit.path) }
            groups[hit.path, default: []].append(hit)
            ranks[hit.id] = min(ranks[hit.id] ?? Int.max, offset + 1)
        }
        return paths.map { path in
            let ranked = groups[path]!
            let ordered = order == .document ? ranked.sorted { $0.page < $1.page } : ranked
            return SearchResultGroup(path: path, hits: ordered, bestRank: ranks[ranked[0].id]!, ranks: ranks)
        }
    }
}
