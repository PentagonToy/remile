import Foundation

/// A portable project reference. Account connections and editor sessions keep their own IDs.
enum OverleafProjectID {
    static func parse(_ value: String) -> String? {
        let text = value.hasPrefix("overleaf:") ? String(value.dropFirst(9)) : value
        guard text.utf8.count == 24, text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return text.lowercased()
    }
    static func reference(_ id: String) -> String { "overleaf:" + id.lowercased() }
}
