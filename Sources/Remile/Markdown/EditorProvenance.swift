import Foundation
import CryptoKit

/// Session-only ranges: local edits remove their own overlap and shift surviving external text.
enum EditorProvenance {
    static func change(before: String, after: String) -> (removed: NSRange, inserted: NSRange) {
        let a = Array(before.utf16), b = Array(after.utf16)
        var head = 0, tail = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        while tail < min(a.count, b.count) - head, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
        return (NSRange(location: head, length: a.count - head - tail), NSRange(location: head, length: b.count - head - tail))
    }
    static func highlight(before: String, after: String) -> NSRange {
        guard before != after else { return NSRange(location: 0, length: 0) }
        let edit = change(before: before, after: after)
        if edit.inserted.length > 0 || after.isEmpty { return edit.inserted }
        let raw = after as NSString, anchor = min(edit.inserted.location, raw.length - 1)
        let pattern = try? NSRegularExpression(pattern: #"\\[A-Za-z@]+|[\p{L}\p{N}_]+"#)
        if let word = pattern?.matches(in: after, range: NSRange(location: 0, length: raw.length)).map(\.range).first(where: { anchor >= $0.location && anchor <= NSMaxRange($0) }) { return word }
        return raw.rangeOfComposedCharacterSequence(at: anchor)
    }
    struct Tracker {
        private(set) var ranges: [NSRange] = []
        private var lastBefore: [NSRange] = []
        private var transitioned = false
        private var undo: (before: String, after: String, beforeBytes: Int, afterBytes: Int, ranges: [NSRange])?
        private static func key(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }
        mutating func transition(before: String, after: String) {
            if let undo, before.utf8.count == undo.afterBytes, after.utf8.count == undo.beforeBytes, undo.after == Self.key(before), undo.before == Self.key(after) { ranges = undo.ranges; self.undo = nil }
            else { lastBefore = ranges; ranges = EditorProvenance.rebase(ranges, before: before, after: after) }
            transitioned = true
        }
        mutating func mark(before: String, after: String) {
            let first = Self.key(before), second = Self.key(after)
            undo = (first, second, before.utf8.count, after.utf8.count, transitioned ? lastBefore : ranges)
            transitioned = false
            let range = EditorProvenance.highlight(before: before, after: after)
            ranges = EditorProvenance.merged(ranges + (range.length > 0 ? [range] : []))
        }
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
