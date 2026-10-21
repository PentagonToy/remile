import Foundation

enum SearchResultOrder: String, CaseIterable {
    case relevance = "Relevance", rank = "Rank"
}

struct RankedSearchHit: Identifiable {
    let hit: LibraryHit
    let rank: Int
    var id: String { hit.id }
    static func make(_ hits: [LibraryHit], filter: String = "") -> [RankedSearchHit] {
        let filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return hits.enumerated().compactMap { offset, hit in
            guard filter.isEmpty || hit.path.localizedStandardContains(filter) else { return nil }
            return RankedSearchHit(hit: hit, rank: offset + 1)
        }
    }
}

struct SearchResultGroup: Identifiable {
    let path: String
    let hits: [LibraryHit]
    let bestRank: Int
    let ranks: [String: Int]
    var id: String { path }
    var name: String { hits.first?.name ?? "" }
    func rank(for hit: LibraryHit) -> Int? { ranks[hit.id] }
    static func make(_ hits: [LibraryHit], filter: String = "") -> [SearchResultGroup] {
        var paths: [String] = [], groups: [String: [LibraryHit]] = [:], ranks: [String: Int] = [:]
        for entry in RankedSearchHit.make(hits, filter: filter) {
            let hit = entry.hit
            if groups[hit.path] == nil { paths.append(hit.path) }
            groups[hit.path, default: []].append(hit)
            ranks[hit.id] = min(ranks[hit.id] ?? Int.max, entry.rank)
        }
        return paths.map { path in
            let hits = groups[path]!
            return SearchResultGroup(path: path, hits: hits, bestRank: ranks[hits[0].id]!, ranks: ranks)
        }
    }
}
