let base = URL(fileURLWithPath: CommandLine.arguments[1])
let oldID = "local.remile-test." + UUID().uuidString + ".old", newID = oldID + ".new"
let defaults = UserDefaults.standard
let manager = FileManager.default
defer { defaults.removePersistentDomain(forName: oldID); defaults.removePersistentDomain(forName: newID) }
let existing = base.appendingPathComponent("existing.tex")
try manager.createDirectory(at: base, withIntermediateDirectories: true)
try "source".write(to: existing, atomically: true, encoding: .utf8)
defaults.setPersistentDomain(["reader.appearance": "dark", "latex.theme": "Deerstalker", "reader.recentDocuments": [existing.path, base.appendingPathComponent("missing.tex").path]], forName: oldID)
defaults.setPersistentDomain(["reader.appearance": "light"], forName: newID)
for path in [oldID + "/EditorHistory", oldID + "/Automation", "Deerstalker/Search", "Deerstalker/Ask"] {
    let folder = base.appendingPathComponent(path); try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try "evidence".write(to: folder.appendingPathComponent("data"), atomically: true, encoding: .utf8)
}
try LegacyMigration.run(defaults: defaults, support: base, oldID: oldID, newID: newID)
let migrated = defaults.persistentDomain(forName: newID)!
precondition(migrated["reader.appearance"] as? String == "light")
precondition(migrated["latex.theme"] as? String == "remile.")
precondition(migrated["reader.recentDocuments"] as? [String] == [existing.path])
for path in ["EditorHistory/data", "Search/data", "Ask/data"] { precondition(manager.fileExists(atPath: base.appendingPathComponent(newID + "/" + path).path)) }
precondition(!manager.fileExists(atPath: base.appendingPathComponent(newID + "/Automation").path))
precondition(manager.fileExists(atPath: base.appendingPathComponent("Deerstalker/Search/data").path))
try "changed".write(to: base.appendingPathComponent("Deerstalker/Search/data"), atomically: true, encoding: .utf8)
try LegacyMigration.run(defaults: defaults, support: base, oldID: oldID, newID: newID)
let retained = try String(contentsOf: base.appendingPathComponent(newID + "/Search/data"), encoding: .utf8)
precondition(retained == "evidence")
print("Passed migration: preferences, recent filtering, theme, three stores, pending-request exclusion, originals and idempotence")
