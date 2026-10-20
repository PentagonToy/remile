import Foundation

/// One-time local migration; old preferences and documents remain recoverable.
enum LegacyMigration {
    static let oldIdentifier = "local.deerstalker.app"
    static let identifier = "local.remile.app"
    static func run(defaults: UserDefaults = .standard, support: URL? = nil, oldID: String = oldIdentifier, newID: String = identifier) throws {
        var current = defaults.persistentDomain(forName: newID) ?? [:]
        guard current["migration.remile.v1"] as? Bool != true else { return }
        let old = defaults.persistentDomain(forName: oldID) ?? [:]
        let manager = FileManager.default
        let base = support ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = base.appendingPathComponent(newID)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for (source, name) in [(base.appendingPathComponent(oldID + "/EditorHistory"), "EditorHistory"), (base.appendingPathComponent("Deerstalker/Search"), "Search"), (base.appendingPathComponent("Deerstalker/Ask"), "Ask")] {
            let target = destination.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) {
                let staging = destination.appendingPathComponent(".migration-" + UUID().uuidString)
                do { try manager.copyItem(at: source, to: staging); try manager.moveItem(at: staging, to: target) }
                catch { try? manager.removeItem(at: staging); throw error }
            }
        }
        current = old.merging(current) { _, new in new }
        if current["latex.theme"] as? String == "Deerstalker" { current["latex.theme"] = "remile." }
        if let paths = current["reader.recentDocuments"] as? [String] {
            current["reader.recentDocuments"] = paths.filter { manager.fileExists(atPath: $0) }
        }
        current["migration.remile.v1"] = true
        defaults.setPersistentDomain(current, forName: newID)
    }
}
