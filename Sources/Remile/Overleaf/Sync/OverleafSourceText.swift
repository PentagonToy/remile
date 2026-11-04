import Foundation

/// Conservative character-range reconciliation: overlapping intent remains a review.
enum OverleafSourceText {
    private static let wordRefinementByteLimit = 32 * 1024
    /// Line anchors separate independent changes. Bound the LCS table and fall back
    /// to one conservative range when a document is too complex for a cheap diff.
    static func edits(from base: String, to changed: String) throws -> [OverleafSource.Edit] {
        try OverleafSource.validate(base); try OverleafSource.validate(changed)
        if base == changed { return [] }
        func lines(_ text: String) -> [String] {
            let parts = text.components(separatedBy: "\n")
            return parts.enumerated().map { $0.offset < parts.count - 1 ? $0.element + "\n" : $0.element }
        }
        let a = lines(base), b = lines(changed)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var endA = a.count, endB = b.count
        while endA > prefix, endB > prefix, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let n = endA - prefix, m = endB - prefix
        guard n <= 2_000, m <= 2_000, (n + 1) * (m + 1) <= 250_000 else { return [try OverleafSource.Edit.between(base, changed)] }
        let width = m + 1
        var table = [Int](repeating: 0, count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * width + j] = a[prefix + i] == b[prefix + j] ? 1 + table[(i + 1) * width + j + 1] : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var matches: [(Int, Int)] = [], i = 0, j = 0
        while i < n, j < m {
            if a[prefix + i] == b[prefix + j] { matches.append((prefix + i, prefix + j)); i += 1; j += 1 }
            else if table[(i + 1) * width + j] >= table[i * width + j + 1] { i += 1 }
            else { j += 1 }
        }
        matches.append((endA, endB))
        var result: [OverleafSource.Edit] = [], left = prefix, right = prefix
        var wordBudget = 250_000 - table.count
        var offset = a[..<prefix].reduce(0) { $0 + $1.utf16.count }
        for (x, y) in matches {
            let before = a[left..<x].joined(), after = b[right..<y].joined()
            if before != after {
                result += try wordEdits(from: before, to: after, offset: offset, budget: &wordBudget)
            }
            offset += before.utf16.count + (x < endA ? a[x].utf16.count : 0)
            left = x + 1; right = y + 1
        }
        return result
    }
    /// Unique words provide conservative anchors inside paragraphs. One shared
    /// budget bounds all refinements in this diff, not a new table per line.
    private static func wordEdits(from before: String, to after: String, offset: Int, budget: inout Int) throws -> [OverleafSource.Edit] {
        func tokens(_ text: String) -> [String] {
            var result: [String] = [], token = ""
            for character in text {
                if let previous = token.last, previous.isWhitespace != character.isWhitespace {
                    result.append(token); token = ""
                }
                token.append(character)
            }
            if !token.isEmpty { result.append(token) }
            return result
        }
        func single() throws -> [OverleafSource.Edit] {
            let edit = try OverleafSource.Edit.between(before, after)
            return [OverleafSource.Edit(offset: offset + edit.offset, deleted: edit.deleted, inserted: edit.inserted)]
        }
        // Reject long lines before allocating token strings.
        guard before.utf8.count <= wordRefinementByteLimit, after.utf8.count <= wordRefinementByteLimit else { return try single() }
        let a = tokens(before), b = tokens(after)
        guard a.count <= 2_000, b.count <= 2_000 else { return try single() }
        let width = b.count + 1, cells = (a.count + 1) * width
        guard cells <= budget, !a.isEmpty, !b.isEmpty else { return try single() }
        budget -= cells
        let countsA = Dictionary(a.map { ($0, 1) }, uniquingKeysWith: +)
        let countsB = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        let unique = Set(a.filter { countsA[$0] == 1 && countsB[$0] == 1 && $0.filter({ !$0.isWhitespace }).count >= 3 })
        guard !unique.isEmpty else { return try characterEdits(from: before, to: after, offset: offset, budget: &budget) }
        func anchor(_ i: Int, _ j: Int) -> Bool { a[i] == b[j] && unique.contains(a[i]) }
        var table = [Int](repeating: 0, count: cells)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = anchor(i, j) ? 1 + table[(i + 1) * width + j + 1] : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var matches: [(Int, Int)] = [], i = 0, j = 0
        while i < a.count, j < b.count {
            if anchor(i, j) { matches.append((i, j)); i += 1; j += 1 }
            else if table[(i + 1) * width + j] >= table[i * width + j + 1] { i += 1 }
            else { j += 1 }
        }
        matches.append((a.count, b.count))
        var result: [OverleafSource.Edit] = [], left = 0, right = 0, position = offset
        for (x, y) in matches {
            let old = a[left..<x].joined(), new = b[right..<y].joined()
            if old != new {
                result += try characterEdits(from: old, to: new, offset: position, budget: &budget)
            }
            position += old.utf16.count + (x < a.count ? a[x].utf16.count : 0)
            left = x + 1; right = y + 1
        }
        return result
    }
    /// Refine small gaps only when their character alignment is unambiguous.
    /// Grapheme boundaries, a per-gap size cap and the shared cell budget apply.
    private static func characterEdits(from before: String, to after: String, offset: Int, budget: inout Int) throws -> [OverleafSource.Edit] {
        func single() throws -> [OverleafSource.Edit] {
            let edit = try OverleafSource.Edit.between(before, after)
            return [OverleafSource.Edit(offset: offset + edit.offset, deleted: edit.deleted, inserted: edit.inserted)]
        }
        guard before.utf8.count <= 1024, after.utf8.count <= 1024 else { return try single() }
        let a = Array(before), b = Array(after)
        guard a.count <= 256, b.count <= 256 else { return try single() }
        var prefix = 0, endA = a.count, endB = b.count
        while prefix < min(endA, endB), a[prefix] == b[prefix] { prefix += 1 }
        while endA > prefix, endB > prefix, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let n = endA - prefix, m = endB - prefix, width = endB - prefix + 1
        let cells = (n + 1) * width
        guard n > 0, m > 0, cells <= budget else { return try single() }
        budget -= cells
        var table = [Int](repeating: 0, count: cells)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[prefix + i] == b[prefix + j] ? 1 + table[(i + 1) * width + j + 1] : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var matches: [(Int, Int)] = [], i = 0, j = 0
        while i < n, j < m {
            let down = table[(i + 1) * width + j], right = table[i * width + j + 1]
            if a[prefix + i] == b[prefix + j] {
                guard down < table[i * width + j], right < table[i * width + j] else { return try single() }
                matches.append((prefix + i, prefix + j)); i += 1; j += 1
            } else {
                if down == 0, right == 0 { break }
                if down == right {
                    guard table[(i + 1) * width + j + 1] == down else { return try single() }
                    i += 1; j += 1
                } else if down > right { i += 1 } else { j += 1 }
            }
        }
        matches.append((endA, endB))
        var result: [OverleafSource.Edit] = [], left = prefix, right = prefix
        var position = offset + String(a[..<prefix]).utf16.count
        for (x, y) in matches {
            let old = String(a[left..<x]), new = String(b[right..<y])
            if old != new { result.append(.init(offset: position, deleted: old, inserted: new)) }
            position += old.utf16.count + (x < endA ? String(a[x]).utf16.count : 0)
            left = x + 1; right = y + 1
        }
        return result
    }
    static func replacing(_ base: String, edits: [OverleafSource.Edit]) throws -> String {
        var result = base
        for edit in edits.sorted(by: { $0.offset > $1.offset }) {
            guard let range = Range(NSRange(location: edit.offset, length: edit.deleted.utf16.count), in: result), String(result[range]) == edit.deleted else { throw OverleafSource.Failure.conflict }
            result.replaceSubrange(range, with: edit.inserted)
        }
        try OverleafSource.validate(result); return result
    }
    /// At an unfinished last line, a continuation precedes a separate new line.
    /// Both insertions must be append-only and each must contain one content line.
    /// Two competing continuations or blocks still need review.
    private static func continuedLine(_ a: OverleafSource.Edit, _ b: OverleafSource.Edit, at end: Int) -> OverleafSource.Edit? {
        guard a.offset == end, b.offset == a.offset,
              a.deleted.isEmpty, b.deleted.isEmpty else { return nil }
        let aBreak = a.inserted.first?.isNewline == true
        let bBreak = b.inserted.first?.isNewline == true
        guard aBreak != bBreak else { return nil }
        let continuation = aBreak ? b.inserted : a.inserted
        let block = aBreak ? a.inserted : b.inserted
        guard continuation.split(whereSeparator: { $0.isNewline }).count == 1,
              block.split(whereSeparator: { $0.isNewline }).count == 1 else { return nil }
        return OverleafSource.Edit(offset: a.offset, deleted: "", inserted: continuation + block)
    }
    static func merge(base: String, local: String, remote: String) throws -> String {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        let localEdits = try edits(from: base, to: local), remoteEdits = try edits(from: base, to: remote)
        var combined = localEdits
        let end = base.utf16.count
        let unfinishedEnd = base.last?.isNewline == false ? end : -1
        for b in remoteEdits {
            var duplicate = false
            for (index, a) in localEdits.enumerated() {
                if a.offset == b.offset, a.deleted == b.deleted, a.inserted == b.inserted { duplicate = true; continue }
                if a.offset == end, b.offset == a.offset, a.deleted.isEmpty, b.deleted.isEmpty,
                   a.inserted.hasPrefix(b.inserted) || b.inserted.hasPrefix(a.inserted) {
                    combined[index] = a.inserted.count >= b.inserted.count ? a : b
                    duplicate = true; continue
                }
                if let append = continuedLine(a, b, at: unfinishedEnd) {
                    combined[index] = append; duplicate = true; continue
                }
                let aEnd = a.offset + a.deleted.utf16.count, bEnd = b.offset + b.deleted.utf16.count
                // Coarse replacements can already contain a received insertion.
                // A shared end boundary is ambiguous without a separate anchor.
                if (!a.deleted.isEmpty && b.deleted.isEmpty && b.offset == aEnd) ||
                   (!b.deleted.isEmpty && a.deleted.isEmpty && a.offset == bEnd) { throw OverleafSource.Failure.conflict }
                guard (aEnd <= b.offset || bEnd <= a.offset), a.offset != b.offset else { throw OverleafSource.Failure.conflict }
            }
            if !duplicate { combined.append(b) }
        }
        return try replacing(base, edits: combined)
    }
}
