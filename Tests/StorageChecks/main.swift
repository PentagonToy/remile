import Foundation
import SQLite3
var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { fatalError(message) }; checks += 1
}
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection: " + label) } catch { checks += 1 }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let unifiedDefaults = UserDefaults(suiteName: "remile.storage-test." + UUID().uuidString)!
let unifiedOld = output.appendingPathComponent("unified-old")
let unifiedReference = unifiedOld.appendingPathComponent("Reference")
try FileManager.default.createDirectory(at: unifiedReference, withIntermediateDirectories: true)
try Data(#"{"schema":1,"records":[]}"#.utf8).write(to: unifiedReference.appendingPathComponent("library.json"))
try Data(#"{"schema":1}"#.utf8).write(to: unifiedOld.appendingPathComponent("remile-storage.json"))
unifiedDefaults.set(unifiedOld.path, forKey: StorageLocation.preference)
unifiedDefaults.set(unifiedReference.path, forKey: StoragePaths.referencePreference)
let unifiedSearch = StorageLocation.search(defaults: unifiedDefaults)
try FileManager.default.createDirectory(at: unifiedSearch.deletingLastPathComponent(), withIntermediateDirectories: true)
var fixtureDB: OpaquePointer?
try check(sqlite3_open(unifiedSearch.path, &fixtureDB) == SQLITE_OK, "Storage fixture opens")
sqlite3_exec(fixtureDB, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES('kept');", nil, nil, nil)
try Data("cached-ranking".utf8).write(to: unifiedSearch.deletingPathExtension().appendingPathExtension("body-rank"))
let unifiedDestination = output.appendingPathComponent("unified-new")
try StoragePaths.scheduleStorage(unifiedDestination, defaults: unifiedDefaults)
try check(StorageLocation.root(defaults: unifiedDefaults).path == unifiedOld.path, "Scheduling leaves active storage unchanged")
try StoragePaths.applyPendingStorage(defaults: unifiedDefaults)
sqlite3_close(fixtureDB)
try check(StoragePaths.reference(defaults: unifiedDefaults).path == unifiedDestination.appendingPathComponent("Reference").path, "Reference follows unified storage")
try check(FileManager.default.fileExists(atPath: unifiedSearch.path), "Moving retains the source index")
let copiedSearch = StorageLocation.search(defaults: unifiedDefaults)
try check(try Data(contentsOf: copiedSearch.deletingPathExtension().appendingPathExtension("body-rank")) == Data("cached-ranking".utf8), "Moving retains the prepared ranking cache")
var copiedDB: OpaquePointer?, copiedRow: OpaquePointer?
try check(sqlite3_open_v2(copiedSearch.path, &copiedDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Moved search database opens read only")
let prepareResult = sqlite3_prepare_v2(copiedDB, "SELECT value FROM sample", -1, &copiedRow, nil)
if prepareResult != SQLITE_OK { FileHandle.standardError.write(Data(("SQL failure: " + String(cString: sqlite3_errmsg(copiedDB)) + "\n").utf8)) }
try check(prepareResult == SQLITE_OK, "Moved snapshot retains its table")
try check(sqlite3_step(copiedRow) == SQLITE_ROW && String(cString: sqlite3_column_text(copiedRow, 0)) == "kept", "SQLite snapshot includes committed WAL data")
sqlite3_finalize(copiedRow); sqlite3_close(copiedDB)
try check(unifiedDefaults.string(forKey: StorageLocation.pendingPreference) == nil, "Successful move clears pending change")
let otherMacDefaults = UserDefaults(suiteName: "remile.storage-test." + UUID().uuidString)!
otherMacDefaults.set(unifiedDestination.path, forKey: StorageLocation.preference)
try check(StorageLocation.search(defaults: otherMacDefaults) != copiedSearch, "Shared storage gives each Mac a separate search database")
try FileManager.default.moveItem(at: unifiedDestination, to: output.appendingPathComponent("disconnected"))
rejects("Disconnected storage never silently recreates a local directory") { try StorageLocation.requireAvailable(defaults: unifiedDefaults) }
try check(!FileManager.default.fileExists(atPath: unifiedDestination.path), "Availability check does not recreate missing storage")
print("Passed \(checks) Reference checks including unified storage")
let unavailableDestination = output.appendingPathComponent("missing-drive/remile-storage")
unifiedDefaults.set(unavailableDestination.path, forKey: StorageLocation.pendingPreference)
let beforeFailure = StorageLocation.root(defaults: unifiedDefaults).path
rejects("Missing destination leaves the active storage unchanged") { try StoragePaths.applyPendingStorage(defaults: unifiedDefaults) }
try check(StorageLocation.root(defaults: unifiedDefaults).path == beforeFailure, "Failed move preserves the selected root")
let unrelatedFolder = output.appendingPathComponent("unrelated")
try FileManager.default.createDirectory(at: unrelatedFolder, withIntermediateDirectories: true)
rejects("Existing unrelated folders are never overwritten") { try StoragePaths.scheduleStorage(unrelatedFolder, defaults: unifiedDefaults) }
let emptyDefaults = UserDefaults(suiteName: "remile.storage-test." + UUID().uuidString)!
let emptyRoot = output.appendingPathComponent("empty-source")
let emptyReference = emptyRoot.appendingPathComponent("Reference")
try FileManager.default.createDirectory(at: emptyReference, withIntermediateDirectories: true)
try Data(#"{"schema":1}"#.utf8).write(to: emptyRoot.appendingPathComponent("remile-storage.json"))
emptyDefaults.set(emptyRoot.path, forKey: StorageLocation.preference)
emptyDefaults.set(emptyReference.path, forKey: StoragePaths.referencePreference)
emptyDefaults.set(emptyReference.path, forKey: StoragePaths.readOnlyPreference)
let emptyStorage = output.appendingPathComponent("empty-storage")
try StoragePaths.scheduleStorage(emptyStorage, defaults: emptyDefaults)
try StoragePaths.applyPendingStorage(defaults: emptyDefaults)
try check(FileManager.default.fileExists(atPath: emptyStorage.appendingPathComponent("Reference/library.json").path), "Moving an empty Reference produces a usable catalogue")
try check(StoragePaths.isReadOnly(StoragePaths.reference(defaults: emptyDefaults), defaults: emptyDefaults), "Moving preserves read-only mode")
print("Passed \(checks) unified storage checks")
