import SwiftUI

enum SearchExcerpt {
    static func highlight(_ text: String, query: String, caseSensitive: Bool) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var range = text.startIndex..<text.endIndex
        while let match = text.range(of: query, options: caseSensitive ? [] : .caseInsensitive, range: range) {
            if let converted = Range(match, in: result) { result[converted].backgroundColor = Color.yellow.opacity(0.35) }
            guard match.upperBound < text.endIndex else { break }
            range = match.upperBound..<text.endIndex
        }
        return result
    }
}
