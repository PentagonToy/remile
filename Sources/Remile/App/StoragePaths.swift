import Foundation
import CryptoKit
import SQLite3

/// Locations are local preferences. Moving a library never removes its recovery copy.
enum StoragePaths {
    static let referencePreference = "storage.referenceDirectory"
    static let settingsPreference = "storage.settingsFile"
    static let readOnlyPreference = StorageFileAccess.readOnlyPreference
    static let changed = Notification.Name("remile.storageChanged")
    static let gate = NSRecursiveLock()
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app") }
    static var defaultReference: URL { support.appendingPathComponent("Reference") }
    static func reference(defaults: UserDefaults = .standard) -> URL {
        if defaults.string(forKey: StorageLocation.preference) != nil {
            return StorageLocation.root(defaults: defaults).appendingPathComponent("Reference")
        }
        var url = defaults.string(forKey: referencePreference).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? defaultReference
        for _ in 0..<8 {
            let marker = url.appendingPathComponent("relocated.json")
            guard let size = try? marker.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_000,
                  let data = try? Data(contentsOf: marker), let path = try? JSONDecoder().decode(String.self, from: data), path.hasPrefix("/"), path != url.path else { break }
            url = URL(fileURLWithPath: path)
        }
        return url
    }
    static func requireAvailable(_ url: URL) throws {
        try StorageLocation.requireAvailable()
        if url.standardizedFileURL != defaultReference.standardizedFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw Failure("Connect the disk containing your reference library.") }
        }
    }
    static func isReadOnly(_ root: URL, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: readOnlyPreference) == root.standardizedFileURL.path
    }
    /// Connect to the folder synced on this Mac, never a path copied from another Mac.
    static func connect(to folder: URL, defaults: UserDefaults = .standard, commit: (() throws -> Void) throws -> Void = { try $0() }) throws {
        gate.lock(); defer { gate.unlock() }
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("relocated.json").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.json").path) else {
            throw Failure("Choose the synced library folder containing library.json.")
        }
        _ = try ReferenceRepository(root: folder).snapshot()
        try commit {
            defaults.set(folder.path, forKey: readOnlyPreference)
            defaults.set(folder.path, forKey: referencePreference)
        }
    }
    static func relocate(from source: URL, into parent: URL, defaults: UserDefaults = .standard, commit: (() throws -> Void) throws -> Void = { try $0() }) throws -> URL {
        gate.lock(); defer { gate.unlock() }
        let manager = FileManager.default
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        let destination = parent.appendingPathComponent("remile-reference", isDirectory: true)
        guard !manager.fileExists(atPath: source.appendingPathComponent("relocated.json").path), parent.path != source.path, !parent.path.hasPrefix(source.path + "/"), !destination.path.hasPrefix("/Applications/"),
              manager.fileExists(atPath: parent.path), !manager.fileExists(atPath: destination.path) else { throw Failure("Choose another folder. The destination must not contain a remile-reference folder.") }
        let stage = parent.appendingPathComponent(".remile-reference-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? manager.removeItem(at: stage) } }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let files = manager.enumerator(at: source, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw Failure("Could not read the reference folder.") }
        var manifest: [(String, Data)] = []
        for case let file as URL in files {
            let name = String(file.path.dropFirst(source.path.count + 1))
            if ["library.lock", "relocated.json"].contains(name) { continue }
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw Failure("The reference folder contains a symbolic link. Keep the current location and check its files.") }
            let copy = stage.appendingPathComponent(name)
            if values.isDirectory == true { try manager.createDirectory(at: copy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            else {
                guard values.isRegularFile == true else { throw Failure("The reference folder contains an unsupported file.") }
                try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: file, to: copy)
                let hash = try digest(file)
                guard try digest(copy) == hash else { throw Failure("A copied reference file did not match. The current library is unchanged.") }
                manifest.append((name, hash))
            }
        }
        if let enumerationError { throw enumerationError }
        if !manager.fileExists(atPath: stage.appendingPathComponent("library.json").path) {
            guard manifest.isEmpty else { throw Failure("The catalogue is missing. Wait for folder sync before moving this library.") }
            try Data(#"{"schema":1,"records":[]}"#.utf8).write(to: stage.appendingPathComponent("library.json"), options: .atomic)
        }
        // Recheck the source before publishing, including metadata and attachment bytes.
        for (name, hash) in manifest { guard try digest(source.appendingPathComponent(name)) == hash else { throw Failure("The reference library changed during the copy. Try again.") } }
        try commit {
            try manager.moveItem(at: stage, to: destination)
            do { try JSONEncoder().encode(destination.path).write(to: source.appendingPathComponent("relocated.json"), options: .atomic) }
            catch { try? manager.removeItem(at: destination); throw error }
            defaults.set(destination.path, forKey: referencePreference)
            published = true
        }
        return destination
    }
    static func scheduleStorage(_ destination: URL, defaults: UserDefaults = .standard) throws {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let old = reference(defaults: defaults).resolvingSymlinksInPath().standardizedFileURL
        guard destination.path != old.path, !destination.path.hasPrefix(old.path + "/"),
              !destination.path.hasPrefix("/Applications/"), destination.path != StorageLocation.root(defaults: defaults).path else {
            throw Failure("Choose another storage folder.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("remile-storage.json").path),
                  FileManager.default.fileExists(atPath: destination.appendingPathComponent("Reference/library.json").path) else {
                throw Failure("Choose a remile storage folder or a new destination.")
            }
            _ = try ReferenceRepository(root: destination.appendingPathComponent("Reference")).snapshot()
        }
        defaults.set(destination.path, forKey: StorageLocation.pendingPreference)
    }
    /// Runs before document windows and the automation server open.
    static func applyPendingStorage(defaults: UserDefaults = .standard) throws {
        guard let path = defaults.string(forKey: StorageLocation.pendingPreference), path.hasPrefix("/") else { return }
        gate.lock(); defer { gate.unlock() }
        let manager = FileManager.default
        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent()
        guard manager.fileExists(atPath: parent.path) else { throw Failure("Reconnect the destination drive and try again.") }
        let oldReference = reference(defaults: defaults)
        let oldSearch = StorageLocation.search(defaults: defaults)
        let stage = parent.appendingPathComponent(".remile-storage-" + UUID().uuidString)
        let existing = manager.fileExists(atPath: destination.path)
        let target = existing ? destination : stage
        var published = false
        defer { if !existing && !published { try? manager.removeItem(at: stage) } }
        if existing {
            guard manager.fileExists(atPath: destination.appendingPathComponent("remile-storage.json").path),
                  FileManager.default.fileExists(atPath: destination.appendingPathComponent("Reference/library.json").path) else { throw Failure("The destination is no longer a remile storage folder.") }
            _ = try ReferenceRepository(root: destination.appendingPathComponent("Reference")).snapshot()
        } else {
            try StorageLocation.requireAvailable(defaults: defaults)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let newReference = stage.appendingPathComponent("Reference")
            if manager.fileExists(atPath: oldReference.path) {
                let repository = ReferenceRepository(root: oldReference)
                try repository.withLibraryLock(allowReadOnly: true) {
                    _ = try repository.snapshot()
                    try manager.copyItem(at: oldReference, to: newReference)
                    guard let files = manager.enumerator(at: oldReference, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw Failure("Could not read Reference storage.") }
                    for case let file as URL in files {
                        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isSymbolicLink != true else { throw Failure("Remove symbolic links before moving storage.") }
                        if values.isRegularFile == true {
                            let relative = String(file.path.dropFirst(oldReference.path.count + 1))
                            guard try digest(file) == digest(newReference.appendingPathComponent(relative)) else { throw Failure("Reference changed while copying. The current storage is unchanged.") }
                        }
                    }
                }
                try? manager.removeItem(at: newReference.appendingPathComponent("library.lock"))
                try? manager.removeItem(at: newReference.appendingPathComponent("relocated.json"))
            } else {
                guard oldReference.standardizedFileURL == defaultReference.standardizedFileURL else { throw Failure("Reconnect your current Reference storage before moving it.") }
                try manager.createDirectory(at: newReference, withIntermediateDirectories: true)
                try Data(#"{"schema":1,"records":[]}"#.utf8).write(to: newReference.appendingPathComponent("library.json"))
            }
            if !manager.fileExists(atPath: newReference.appendingPathComponent("library.json").path) {
                try Data(#"{"schema":1,"records":[]}"#.utf8).write(to: newReference.appendingPathComponent("library.json"))
            }
            try Data(#"{"schema":1}"#.utf8).write(to: stage.appendingPathComponent("remile-storage.json"))
        }
        let machine = defaults.string(forKey: StorageLocation.machinePreference).flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
        let newSearch = target.appendingPathComponent("Search/" + machine + "/library-v1.sqlite")
        if manager.fileExists(atPath: oldSearch.path), !manager.fileExists(atPath: newSearch.path) {
            try manager.createDirectory(at: newSearch.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshotSearch(from: oldSearch, to: newSearch)
            for suffix in ["body-rank", "all-rank"] {
                let source = oldSearch.deletingPathExtension().appendingPathExtension(suffix)
                let copy = newSearch.deletingPathExtension().appendingPathExtension(suffix)
                if manager.fileExists(atPath: source.path) {
                    // Rebuildable cache failures must not prevent moving the catalogue.
                    do {
                        try manager.copyItem(at: source, to: copy)
                        if try digest(source) != digest(copy) { try? manager.removeItem(at: copy) }
                    } catch { try? manager.removeItem(at: copy) }
                }
            }
        }
        if !existing { try manager.moveItem(at: stage, to: destination); published = true }
        let reference = destination.appendingPathComponent("Reference")
        defaults.set(reference.path, forKey: referencePreference)
        defaults.set(existing || isReadOnly(oldReference, defaults: defaults) ? reference.path : "", forKey: readOnlyPreference)
        defaults.set(machine, forKey: StorageLocation.machinePreference)
        defaults.set(destination.path, forKey: StorageLocation.preference)
        defaults.removeObject(forKey: StorageLocation.pendingPreference)
    }
    private static func snapshotSearch(from source: URL, to destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        var complete = false
        defer {
            if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) }
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(output, "main", input, "main") else { throw Failure("Could not copy the search index. The current storage is unchanged.") }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw Failure("The search index is busy. Quit other remile instances and try again.") }
        // Publish a self-contained database. Normal opening re-enables WAL later.
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw Failure("Could not finish the copied search index.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        complete = true
    }
    private static func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return Data(hash.finalize())
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}
