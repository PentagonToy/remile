import Foundation

/// Session-only ranges: local edits remove their own overlap and shift surviving external text.
enum EditorProvenance {
    static func change(before: String, after: String) -> (removed: NSRange, inserted: NSRange) {
        let a = Array(before.utf16), b = Array(after.utf16)
        var head = 0, tail = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        while tail < min(a.count, b.count) - head, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
        return (NSRange(location: head, length: a.count - head - tail), NSRange(location: head, length: b.count - head - tail))
    }
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location { result[result.count - 1] = NSUnionRange(last, range) }
            else { result.append(range) }
        }
        return Array(result.suffix(256))
    }
    static func rebase(_ ranges: [NSRange], before: String, after: String) -> [NSRange] {
        let edit = change(before: before, after: after), start = edit.removed.location, end = NSMaxRange(edit.removed)
        let shift = edit.inserted.length - edit.removed.length
        return merged(ranges.flatMap { range -> [NSRange] in
            var kept: [NSRange] = []
            if range.location < start { kept.append(NSRange(location: range.location, length: min(NSMaxRange(range), start) - range.location)) }
            if NSMaxRange(range) > end { let right = max(range.location, end); kept.append(NSRange(location: right + shift, length: NSMaxRange(range) - right)) }
            return kept
        })
    }
}
