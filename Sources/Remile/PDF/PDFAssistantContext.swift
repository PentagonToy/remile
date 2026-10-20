import Foundation
import PDFKit
import NaturalLanguage

/// PDFKit objects stay inside this actor; the UI supplies bytes and receives value-only passages.
actor PDFAssistantContext {
    enum Failure: LocalizedError {
        case unreadable, restricted, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: "No readable PDF text. Scanned pages may need OCR."
            case .restricted: "Text access is restricted for this PDF."
            case .tooLarge: "This PDF is too large for Ask."
            }
        }
    }
    func passages(data: Data, password: String, path: String, question: String, currentPage: Int,
                  selection: (page: Int, text: String)?, expanded: Bool = false, progress: @escaping @Sendable (Double) async -> Void) async throws -> [AssistantPassage] {
        guard data.count <= 256 * 1024 * 1024 else { throw Failure.tooLarge }
        guard let document = PDFDocument(data: data) else { throw Failure.unreadable }
        if document.isLocked { document.unlock(withPassword: password) }
        guard !document.isLocked, document.allowsCopying else { throw Failure.restricted }
        let terms = Self.terms(question)
        var candidates: [(page: Int, score: Double, text: String)] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if let page = document.page(at: index), let raw = page.string {
                // Retain only top passages, rather than the text of an entire book.
                let text = String(raw.prefix(100_000))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let score = Self.score(text, terms: terms) + (index + 1 == currentPage ? 0.25 : 0)
                    candidates.append((index + 1, score, Self.excerpt(text, terms: terms, bytes: expanded ? 8000 : 650)))
                    candidates.sort { $0.score == $1.score ? $0.page < $1.page : $0.score > $1.score }
                    if candidates.count > (expanded ? 12 : 6) { candidates.removeLast() }
                }
            }
            if index.isMultiple(of: 8) || index + 1 == document.pageCount {
                await progress(Double(index + 1) / Double(max(1, document.pageCount)))
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        var result: [AssistantPassage] = []
        if let selection, selection.page > 0, selection.page <= document.pageCount, !selection.text.isEmpty {
            result.append(AssistantPassage(location: AssistantLocation(path: path, unit: selection.page, label: "Page \(selection.page)"), text: Self.excerpt(selection.text, terms: terms, bytes: expanded ? 8000 : 650)))
        }
        for candidate in candidates where !result.contains(where: { $0.location.unit == candidate.page }) {
            result.append(AssistantPassage(location: AssistantLocation(path: path, unit: candidate.page, label: "Page \(candidate.page)"), text: candidate.text))
        }
        guard !result.isEmpty else { throw Failure.unreadable }
        return result
    }
    static func terms(_ question: String) -> [String] {
        let stop: Set<String> = ["a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "in", "on", "at", "and", "or", "for", "from", "with", "this", "that", "these", "those", "it", "its", "they", "their", "them", "what", "why", "how", "when", "where", "which", "who", "can", "could", "would", "should", "does", "do", "did", "not", "about", "please", "explain", "summarize", "summary", "document", "pdf", "page", "more", "detail", "tell", "me"]
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = question
        var result: [String] = []
        tokenizer.enumerateTokens(in: question.startIndex..<question.endIndex) { range, _ in
            let word = String(question[range]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if word.count > 1, !stop.contains(word), !result.contains(word) { result.append(word) }
            return result.count < 24
        }
        return result
    }
    static func score(_ text: String, terms: [String]) -> Double {
        let words = termsForText(text)
        return terms.reduce(0) { score, term in
            let exact = words.filter { $0 == term || ($0.count > 4 && term.count > 4 && ($0.hasPrefix(term) || term.hasPrefix($0))) }.count
            if exact > 0 { return score + 3 + log(1 + Double(exact)) }
            // One insertion, deletion or substitution tolerates common typing errors.
            return score + (term.count >= 5 && words.contains(where: { oneEdit($0, term) }) ? 1.5 : 0)
        } / (1 + log(1 + Double(words.count)) * 0.08)
    }
    private static func termsForText(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static func oneEdit(_ lhs: String, _ rhs: String) -> Bool {
        guard abs(lhs.count - rhs.count) <= 1 else { return false }
        let a = Array(lhs), b = Array(rhs)
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1; if edits > 1 { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (i < a.count || j < b.count ? 1 : 0) <= 1
    }
    static func excerpt(_ text: String, terms: [String], bytes: Int = 650) -> String {
        if text.utf8.count <= bytes { return text }
        // Find the densest paragraph window so a keyword near the end of a page survives truncation.
        let chunks = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var best = text, bestScore = -Double.infinity
        for index in chunks.indices {
            let window = chunks[index..<min(chunks.count, index + (bytes > 650 ? 40 : 5))].joined(separator: " ")
            let value = score(window, terms: terms)
            if value > bestScore { best = window; bestScore = value }
        }
        // A PDF paragraph may itself be one long line.
        if let range = terms.compactMap({ best.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).min(by: { $0.lowerBound < $1.lowerBound }), best.distance(from: best.startIndex, to: range.lowerBound) > 180 {
            let start = best.index(range.lowerBound, offsetBy: -120, limitedBy: best.startIndex) ?? best.startIndex
            best = "…" + best[start...]
        }
        return AssistantEvidence.bounded(best, bytes: bytes)
    }
}
