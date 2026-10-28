import Foundation

/// Conservative character-range reconciliation: overlapping intent remains a review.
enum OverleafLiveText {
    static func applying(_ ops: [OverleafLiveWire.JSON], to text: String) throws -> String {
        guard ops.count <= 10_000 else { throw OverleafLiveWire.Failure.protocolMismatch }
        var value = text
        for op in ops {
            guard let offset = op["p"].integer, offset >= 0, offset <= value.utf16.count else { throw OverleafLiveWire.Failure.protocolMismatch }
            let deleted = op["d"].string, inserted = op["i"].string, comment = op["c"].string
            guard [deleted, inserted, comment].compactMap({ $0 }).count == 1 else { throw OverleafLiveWire.Failure.protocolMismatch }
            let length = (deleted ?? comment)?.utf16.count ?? 0
            let units = value as NSString
            func boundary(_ index: Int) -> Bool {
                index == 0 || index == units.length || !((0xD800...0xDBFF).contains(units.character(at: index - 1)) && (0xDC00...0xDFFF).contains(units.character(at: index)))
            }
            guard length <= value.utf16.count - offset,
                  boundary(offset), boundary(offset + length),
                  let range = Range(NSRange(location: offset, length: length), in: value) else { throw OverleafLiveWire.Failure.protocolMismatch }
            if let expected = deleted ?? comment, String(value[range]) != expected { throw OverleafLiveWire.Failure.protocolMismatch }
            if comment != nil { continue }
            value.replaceSubrange(range, with: inserted ?? "")
            try OverleafLive.validate(value)
        }
        return value
    }
    /// Line anchors separate independent changes. Bound the LCS table and fall back
    /// to one conservative range when a document is too complex for a cheap diff.
    static func edits(from base: String, to changed: String) throws -> [OverleafLive.Edit] {
        try OverleafLive.validate(base); try OverleafLive.validate(changed)
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
        guard n <= 2_000, m <= 2_000, (n + 1) * (m + 1) <= 250_000 else { return [try OverleafLive.Edit.between(base, changed)] }
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
        var result: [OverleafLive.Edit] = [], left = prefix, right = prefix
        var offset = a[..<prefix].reduce(0) { $0 + $1.utf16.count }
        for (x, y) in matches {
            let before = a[left..<x].joined(), after = b[right..<y].joined()
            if before != after {
                let edit = try OverleafLive.Edit.between(before, after)
                result.append(OverleafLive.Edit(offset: offset + edit.offset, deleted: edit.deleted, inserted: edit.inserted))
            }
            offset += before.utf16.count + (x < endA ? a[x].utf16.count : 0)
            left = x + 1; right = y + 1
        }
        return result
    }
    static func replacing(_ base: String, edits: [OverleafLive.Edit]) throws -> String {
        var result = base
        for edit in edits.sorted(by: { $0.offset > $1.offset }) {
            guard let range = Range(NSRange(location: edit.offset, length: edit.deleted.utf16.count), in: result), String(result[range]) == edit.deleted else { throw OverleafLiveWire.Failure.conflict }
            result.replaceSubrange(range, with: edit.inserted)
        }
        try OverleafLive.validate(result); return result
    }
    static func merge(base: String, local: String, remote: String) throws -> String {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        let localEdits = try edits(from: base, to: local), remoteEdits = try edits(from: base, to: remote)
        var combined = localEdits
        for b in remoteEdits {
            var duplicate = false
            for a in localEdits {
                if a.offset == b.offset, a.deleted == b.deleted, a.inserted == b.inserted { duplicate = true; continue }
                let aEnd = a.offset + a.deleted.utf16.count, bEnd = b.offset + b.deleted.utf16.count
                guard (aEnd <= b.offset || bEnd <= a.offset), a.offset != b.offset else { throw OverleafLiveWire.Failure.conflict }
            }
            if !duplicate { combined.append(b) }
        }
        return try replacing(base, edits: combined)
    }
}
