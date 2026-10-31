import Foundation

/// Bounded source values shared by Git merging, validation and writer identity.
enum OverleafSource {
    static let textLimit = 2_000_000
    enum Failure: LocalizedError, Equatable {
        case invalidIdentity, invalidText, writerBusy, conflict, staleDraft
        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "The project identity is invalid."
            case .invalidText: return "Sync supports ordinary source text up to 2 MB."
            case .writerBusy: return "This project is already syncing in another window or process."
            case .staleDraft: return "The source changed. Refresh the review before applying this change."
            case .conflict: return "Overlapping edits need review. Both versions are preserved."
            }
        }
    }
    struct Key: Codable, Hashable, Sendable {
        let profile: UUID
        let project: String
        let document: String
        func validate() throws {
            for id in [project, document] {
                guard id.utf8.count == 24 && id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidIdentity }
            }
        }
    }
    static func validate(_ text: String) throws {
        guard text.utf8.count <= textLimit, !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { throw Failure.invalidText }
    }
    /// One bounded replacement, indexed in JavaScript-compatible UTF-16 units.
    struct Edit: Codable, Equatable, Sendable {
        let offset: Int
        let deleted: String
        let inserted: String
        static func between(_ before: String, _ after: String) throws -> Edit {
            try OverleafSource.validate(before); try OverleafSource.validate(after)
            let a = Array(before.unicodeScalars), b = Array(after.unicodeScalars)
            var start = 0, tail = 0
            while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
            while tail < min(a.count, b.count) - start, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
            func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(scalars)) }
            return Edit(offset: text(a[..<start]).utf16.count, deleted: text(a[start..<(a.count - tail)]), inserted: text(b[start..<(b.count - tail)]))
        }
    }
}
