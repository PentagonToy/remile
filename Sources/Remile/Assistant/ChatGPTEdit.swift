import Foundation

struct ChatGPTEdit: Decodable {
    let before: String
    let after: String
    let reason: String
    static func parse(_ text: String, source: String) throws -> Self {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let first = text.firstIndex(of: "\n"), text.hasSuffix("```") { text = String(text[text.index(after: first)..<text.index(text.endIndex, offsetBy: -3)]) }
        guard text.utf8.count <= 160_000, let data = text.data(using: .utf8), let edit = try? JSONDecoder().decode(Self.self, from: data), !edit.before.isEmpty, edit.before != edit.after, edit.reason.count <= 2000, source.components(separatedBy: edit.before).count == 2 else { throw ChatGPTIdentity.Failure("Could not match the edit. Nothing changed.") }
        return edit
    }
    func applying(to source: String) throws -> String {
        guard source.components(separatedBy: before).count == 2 else { throw ChatGPTIdentity.Failure("The source changed. Request a new suggestion.") }
        return source.replacingOccurrences(of: before, with: after)
    }
}
