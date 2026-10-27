import Foundation

/// B0 page/passage BM25 and guided two-route fusion. Owned by the serial library actor.
final class SparseSearchRanker {
    struct Posting { let unit: Int; var value: Float }
    struct Page: Codable { let rowID: Int64; let start: Int; let count: Int; let heading: Set<Int> }
    struct Match { let rowID: Int64; let score: Double }
    private var vocabulary: [String: Int] = [:]
    private var rawVocabulary: [String: Int] = [:]
    private var pages: [Page] = []
    private var tokens: [Int32] = []
    private var pagePostings: [[Posting]] = []
    private var chunkPostings: [[Posting]] = []
    private var chunkOwners: [Int] = []
    private var chunkLengths: [Int] = []
    private var idf: [Float] = []

    func append(rowID: Int64, heading: String, body: String) {
        let sequence = SearchLexicon.words(body).map { raw -> Int32 in
            if let id = rawVocabulary[raw] { return Int32(id) }
            let word = SearchLexicon.stem(raw)
            let id: Int
            if let known = vocabulary[word] { id = known }
            else { id = vocabulary.count; vocabulary[word] = id; pagePostings.append([]); chunkPostings.append([]) }
            rawVocabulary[raw] = id
            return Int32(id)
        }
        let owner = pages.count
        let headings = Set(SearchLexicon.words(heading).compactMap { vocabulary[SearchLexicon.stem($0)] })
        pages.append(Page(rowID: rowID, start: tokens.count, count: sequence.count, heading: headings))
        tokens.append(contentsOf: sequence)
        appendCounts(sequence[...], unit: owner, chunks: false)
        for start in stride(from: 0, to: max(1, sequence.count - 40), by: 120) {
            let part = sequence[start..<min(sequence.count, start + 160)]
            let unit = chunkOwners.count
            chunkOwners.append(owner); chunkLengths.append(part.count)
            appendCounts(part, unit: unit, chunks: true)
        }
    }
    private func appendCounts(_ sequence: ArraySlice<Int32>, unit: Int, chunks: Bool) {
        var counts: [Int: Int] = [:]
        for token in sequence { counts[Int(token), default: 0] += 1 }
        for (term, count) in counts {
            let posting = Posting(unit: unit, value: Float(count))
            if chunks { chunkPostings[term].append(posting) } else { pagePostings[term].append(posting) }
        }
    }
    func finish() throws {
        rawVocabulary.removeAll(keepingCapacity: false)
        let pageMean = max(1, Double(pages.reduce(0) { $0 + $1.count }) / Double(max(1, pages.count)))
        let chunkMean = max(1, Double(chunkLengths.reduce(0, +)) / Double(max(1, chunkLengths.count)))
        idf = Array(repeating: 0, count: vocabulary.count)
        for term in pagePostings.indices {
            if term.isMultiple(of: 1000) { try Task.checkCancellation() }
            idf[term] = Float(log1p((Double(pages.count - pagePostings[term].count) + 0.5) / (Double(pagePostings[term].count) + 0.5)))
            let chunkIDF = Float(log1p((Double(chunkOwners.count - chunkPostings[term].count) + 0.5) / (Double(chunkPostings[term].count) + 0.5)))
            for i in pagePostings[term].indices {
                let p = pagePostings[term][i], norm = 1.2 * (0.25 + 0.75 * Double(pages[p.unit].count) / pageMean)
                pagePostings[term][i].value = Float(Double(idf[term] * p.value * 2.2) / (Double(p.value) + norm))
            }
            for i in chunkPostings[term].indices {
                let p = chunkPostings[term][i], norm = 1.2 * (0.25 + 0.75 * Double(chunkLengths[p.unit]) / chunkMean)
                chunkPostings[term][i].value = Float(Double(chunkIDF * p.value * 2.2) / (Double(p.value) + norm))
            }
        }
        chunkLengths.removeAll(keepingCapacity: false)
    }
    private struct Archive: Codable {
        let version: Int
        let key: String
        let vocabulary: [String: Int]
        let pages: [Page]
        let tokens: Data
        let pagePostings: Data
        let chunkPostings: Data
        let chunkOwners: Data
        let idf: Data
    }
    private static func pack<T>(_ values: [T]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
    private static func unpack<T>(_ data: Data, as type: T.Type) throws -> [T] {
        guard data.count.isMultiple(of: MemoryLayout<T>.stride) else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: MemoryLayout<T>.stride).map { raw.loadUnaligned(fromByteOffset: $0, as: T.self) }
        }
    }
    private static func packPostings(_ lists: [[Posting]]) -> Data {
        var values: [UInt32] = []
        for list in lists {
            values.append(UInt32(list.count))
            for posting in list { values.append(UInt32(posting.unit)); values.append(posting.value.bitPattern) }
        }
        return pack(values)
    }
    private static func unpackPostings(_ data: Data, terms: Int, units: Int) throws -> [[Posting]] {
        let values = try unpack(data, as: UInt32.self)
        var cursor = 0, result: [[Posting]] = []
        for _ in 0..<terms {
            guard cursor < values.count else { throw CocoaError(.fileReadCorruptFile) }
            let count = Int(values[cursor]); cursor += 1
            guard count <= (values.count - cursor) / 2 else { throw CocoaError(.fileReadCorruptFile) }
            var list: [Posting] = []; list.reserveCapacity(count)
            for _ in 0..<count {
                let unit = Int(values[cursor]), value = Float(bitPattern: values[cursor + 1]); cursor += 2
                guard unit < units, value.isFinite, value >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                list.append(Posting(unit: unit, value: value))
            }
            result.append(list)
        }
        guard cursor == values.count else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    func save(to url: URL, key: String) throws {
        try Task.checkCancellation()
        let archive = Archive(version: 1, key: key, vocabulary: vocabulary, pages: pages, tokens: Self.pack(tokens), pagePostings: Self.packPostings(pagePostings), chunkPostings: Self.packPostings(chunkPostings), chunkOwners: Self.pack(chunkOwners.map(Int64.init)), idf: Self.pack(idf))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(archive)
        try Task.checkCancellation()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load(from url: URL, key: String) throws -> SparseSearchRanker? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let archive = try PropertyListDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, archive.key == key else { return nil }
        try Task.checkCancellation()
        let ranker = SparseSearchRanker(); ranker.vocabulary = archive.vocabulary; ranker.pages = archive.pages
        let count = archive.vocabulary.count
        guard Set(archive.vocabulary.values) == Set(0..<count) else { throw CocoaError(.fileReadCorruptFile) }
        ranker.tokens = try unpack(archive.tokens, as: Int32.self)
        ranker.chunkOwners = try unpack(archive.chunkOwners, as: Int64.self).map(Int.init)
        ranker.idf = try unpack(archive.idf, as: Float.self)
        guard ranker.idf.count == count, ranker.idf.allSatisfy({ $0.isFinite && $0 >= 0 }),
              ranker.tokens.allSatisfy({ $0 >= 0 && $0 < count }),
              ranker.chunkOwners.allSatisfy({ $0 >= 0 && $0 < ranker.pages.count }),
              ranker.pages.allSatisfy({ $0.start >= 0 && $0.count >= 0 && $0.start <= ranker.tokens.count && $0.count <= ranker.tokens.count - $0.start && $0.heading.allSatisfy({ $0 >= 0 && $0 < count }) }) else { throw CocoaError(.fileReadCorruptFile) }
        ranker.pagePostings = try unpackPostings(archive.pagePostings, terms: count, units: ranker.pages.count)
        ranker.chunkPostings = try unpackPostings(archive.chunkPostings, terms: count, units: ranker.chunkOwners.count)
        return ranker
    }
    private func queryTerms(_ query: String) -> [(Int, Float)] {
        var order: [Int] = [], counts: [Int: Int] = [:]
        for word in SearchLexicon.terms(query) {
            guard let id = vocabulary[word] else { continue }
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        return order.map { ($0, Float(1 + log(Double(counts[$0]!)))) }
    }
    private func bm25(_ query: String, passages: Bool = false) -> [Float] {
        var result = Array(repeating: Float(0), count: passages ? chunkOwners.count : pages.count)
        for (term, weight) in queryTerms(query) {
            for posting in passages ? chunkPostings[term] : pagePostings[term] { result[posting.unit] += posting.value * weight }
        }
        guard passages else { return result }
        var maxima = Array(repeating: Float(0), count: pages.count)
        for i in result.indices { maxima[chunkOwners[i]] = max(maxima[chunkOwners[i]], result[i]) }
        return maxima
    }
    private func b0(_ query: String) throws -> [Float] {
        let terms = queryTerms(query).map(\.0), passage = bm25(query, passages: true)
        var result = bm25(query)
        let total = terms.reduce(Float(0)) { $0 + idf[$1] }
        guard total > 0 else { return result }
        let lookup = Dictionary(uniqueKeysWithValues: terms.enumerated().map { ($1, $0) })
        let pairs = max(1, terms.count * (terms.count - 1) / 2)
        for i in pages.indices {
            if i.isMultiple(of: 128) { try Task.checkCancellation() }
            result[i] += 0.5 * passage[i]
            guard result[i] > 0 else { continue }
            let page = pages[i]
            if terms.count == 1 {
                if page.heading.contains(terms[0]) { result[i] += 0.25 * idf[terms[0]] }
                continue
            }
            var positions = Array(repeating: [Int](), count: terms.count)
            for offset in 0..<page.count {
                if let term = lookup[Int(tokens[page.start + offset])] { positions[term].append(offset) }
            }
            let coverage = terms.indices.reduce(Float(0)) { $0 + (positions[$1].isEmpty ? 0 : idf[terms[$1]]) } / total
            var proximity: Float = 0
            for a in terms.indices {
                for b in terms.indices where b > a {
                    guard !positions[a].isEmpty, !positions[b].isEmpty else { continue }
                    let distance = closest(positions[a], positions[b])
                    if distance <= 64 { proximity += min(idf[terms[a]], idf[terms[b]]) / (1 + Float(distance) / 8) }
                }
            }
            let heading = terms.reduce(Float(0)) { $0 + (page.heading.contains($1) ? idf[$1] : 0) }
            result[i] *= 0.5 + 0.5 * coverage
            result[i] += 2 * proximity / Float(pairs) + 0.25 * heading
        }
        return result
    }
    private func closest(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0, j = 0, best = Int.max
        while i < a.count && j < b.count {
            best = min(best, abs(a[i] - b[j]))
            if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return best
    }
    private func order(_ scores: [Float], allowed: Set<Int64>?, limit: Int = 200) -> [Int] {
        func better(_ a: Int, _ b: Int) -> Bool { scores[a] == scores[b] ? a < b : scores[a] > scores[b] }
        guard limit > 0 else { return [] }
        if limit >= scores.count {
            return scores.indices.filter { scores[$0] > 0 && (allowed == nil || allowed!.contains(pages[$0].rowID)) }.sorted(by: better)
        }
        // Keep the worst retained candidate at the root. Ranking and ties stay identical.
        var heap: [Int] = []; heap.reserveCapacity(limit)
        for i in scores.indices where scores[i] > 0 && (allowed == nil || allowed!.contains(pages[i].rowID)) {
            if heap.count < limit {
                heap.append(i)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard better(heap[parent], heap[child]) else { break }
                    heap.swapAt(parent, child); child = parent
                }
            } else if better(i, heap[0]) {
                heap[0] = i
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, better(heap[child], heap[child + 1]) { child += 1 }
                    guard better(heap[parent], heap[child]) else { break }
                    heap.swapAt(parent, child); parent = child
                }
            }
        }
        return heap.sorted(by: better)
    }
    func search(_ query: String, expansions: [String] = [], allowed: Set<Int64>? = nil, offset: Int = 0, limit: Int = 200) throws -> [Match] {
        guard offset >= 0, limit > 0, offset <= Int.max - limit else { throw CocoaError(.coderInvalidValue) }
        let original = try b0(query)
        let base = order(original, allowed: allowed, limit: expansions.isEmpty ? offset + limit : pages.count)
        guard !expansions.isEmpty else { return base.dropFirst(offset).prefix(limit).map { Match(rowID: pages[$0].rowID, score: Double(original[$0])) } }
        var expanded = Array(repeating: Float(0), count: pages.count)
        for phrase in expansions {
            try Task.checkCancellation()
            let route = bm25(phrase)
            for i in route.indices { expanded[i] += route[i] / Float(expansions.count) }
        }
        var fusion: [Int: Double] = [:]
        for (rank, i) in base.enumerated() { fusion[i, default: 0] += 1 / Double(61 + rank) }
        for (rank, i) in order(expanded, allowed: allowed, limit: pages.count).enumerated() { fusion[i, default: 0] += 0.7 / Double(61 + rank) }
        return fusion.keys.sorted { fusion[$0] == fusion[$1] ? $0 < $1 : fusion[$0]! > fusion[$1]! }.dropFirst(offset).prefix(limit).map { Match(rowID: pages[$0].rowID, score: fusion[$0]!) }
    }
}
