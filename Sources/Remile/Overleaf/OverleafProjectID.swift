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

/// Local to this Mac. An explicit choice wins over the first-open default.
enum OverleafSyncPreference {
    private static func key(_ id: UUID) -> String { "overleaf.prefersLive." + id.uuidString }
    static func live(_ id: UUID, store: UserDefaults = .standard) -> Bool { store.object(forKey: key(id)) as? Bool ?? true }
    static func choose(_ live: Bool, for id: UUID, store: UserDefaults = .standard) { store.set(live, forKey: key(id)) }
}
