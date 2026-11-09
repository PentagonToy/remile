import Foundation
import CryptoKit
import SQLite3

/// Locations are local preferences. Moving a library never removes its recovery copy.
enum StoragePaths {
    static let referencePreference = "storage.referenceDirectory"
    static let pendingReferencePreference = "storage.pendingReferenceDirectory"
    static let pendingReferenceOpen = "storage.pendingReferenceOpen"
    static let settingsPreference = "storage.settingsFile"
    static let readOnlyPreference = StorageFileAccess.readOnlyPreference
    static let changed = Notification.Name("remile.storageChanged")
    static let gate = NSRecursiveLock()
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app") }
    static var defaultReference: URL { support.appendingPathComponent("Reference") }
    static func reference(defaults: UserDefaults = .standard) -> URL {
        var url = defaults.string(forKey: referencePreference).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? StorageLocation.root(defaults: defaults).appendingPathComponent("Reference")
        for _ in 0..<8 {
            let marker = url.appendingPathComponent("relocated.json")
            guard let size = try? marker.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_000,
                  let data = try? Data(contentsOf: marker), let path = try? JSONDecoder().decode(String.self, from: data), path.hasPrefix("/"), path != url.path else { break }
            url = URL(fileURLWithPath: path)
        }
        return url
    }
    static func requireAvailable(_ url: URL) throws {
        if url.standardizedFileURL != defaultReference.standardizedFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw Failure("Connect the disk containing your reference library.") }
        }
    }
    static func scheduleReference(_ folder: URL, opening: Bool, defaults: UserDefaults = .standard) throws {
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        if opening {
            try validateReference(folder)
            guard folder.path != reference(defaults: defaults).standardizedFileURL.path else { throw Failure("This Reference folder is already open.") }
        } else {
            let source = reference(defaults: defaults).resolvingSymlinksInPath()
            let destination = folder.appendingPathComponent("remile-reference")
            guard folder.path != source.path, !folder.path.hasPrefix(source.path + "/"),
                  !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("Choose a parent folder without a remile-reference folder.") }
        }
        defaults.set(opening, forKey: pendingReferenceOpen)
        defaults.set(folder.path, forKey: pendingReferencePreference)
    }
    static func applyPendingReference(defaults: UserDefaults = .standard) throws {
        guard let path = defaults.string(forKey: pendingReferencePreference), path.hasPrefix("/") else { return }
        let folder = URL(fileURLWithPath: path)
        if defaults.bool(forKey: pendingReferenceOpen) {
            try connect(to: folder, defaults: defaults)
        } else {
            let source = reference(defaults: defaults)
            let readOnly = isReadOnly(source, defaults: defaults)
            let move = { try relocate(from: source, into: folder, defaults: defaults, redirectSource: false) }
            let moved = FileManager.default.fileExists(atPath: source.path)
                ? try ReferenceRepository(root: source).withLibraryLock(allowReadOnly: true, move)
                : try move()
            defaults.set(readOnly ? moved.path : "", forKey: readOnlyPreference)
        }
        defaults.removeObject(forKey: pendingReferencePreference)
        defaults.removeObject(forKey: pendingReferenceOpen)
    }
    static func isReadOnly(_ root: URL, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: readOnlyPreference) == root.standardizedFileURL.path
    }
    /// Connect to the folder synced on this Mac, never a path copied from another Mac.
    static func connect(to folder: URL, defaults: UserDefaults = .standard, commit: (() throws -> Void) throws -> Void = { try $0() }) throws {
        gate.lock(); defer { gate.unlock() }
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        try validateReference(folder)
        try commit {
            defaults.set(folder.path, forKey: readOnlyPreference)
            defaults.set(folder.path, forKey: referencePreference)
        }
    }
    private static func validateReference(_ folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("relocated.json").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.json").path) else {
            throw Failure("Choose the synced library folder containing library.json.")
        }
        _ = try ReferenceRepository(root: folder).snapshot()
    }
    static func relocate(from source: URL, into parent: URL, defaults: UserDefaults = .standard, redirectSource: Bool = true,
                         commit: (() throws -> Void) throws -> Void = { try $0() }) throws -> URL {
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
        let files = manager.fileExists(atPath: source.path)
            ? manager.enumerator(at: source, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in enumerationError = error; return false })
            : nil
        guard files != nil || (!redirectSource && source == defaultReference) else { throw Failure("Could not read the reference folder.") }
        var manifest: [(String, Data)] = []
        while let file = files?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw Failure("The reference folder contains a symbolic link. Keep the current location and check its files.") }
            let path = file.resolvingSymlinksInPath().path
            let prefix = source.path + "/"
            guard path.hasPrefix(prefix) else { throw Failure("A Reference file is outside its library folder.") }
            let name = String(path.dropFirst(prefix.count))
            if ["library.lock", "relocated.json"].contains(name) { continue }
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
            if redirectSource {
                do { try JSONEncoder().encode(destination.path).write(to: source.appendingPathComponent("relocated.json"), options: .atomic) }
                catch { try? manager.removeItem(at: destination); throw error }
            }
            defaults.set(destination.path, forKey: referencePreference)
            published = true
        }
        return destination
    }
    static func scheduleStorage(_ destination: URL, defaults: UserDefaults = .standard) throws {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let old = StorageLocation.root(defaults: defaults).resolvingSymlinksInPath()
        let library = reference(defaults: defaults).resolvingSymlinksInPath()
        guard destination.path != old.path, !destination.path.hasPrefix(old.path + "/"),
              destination.path != library.path, !destination.path.hasPrefix(library.path + "/"),
              !destination.path.hasPrefix("/Applications/") else { throw Failure("Choose another storage folder.") }
        if FileManager.default.fileExists(atPath: destination.path) { try validateStorage(destination) }
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
            try validateStorage(destination)
        } else {
            try StorageLocation.requireAvailable(defaults: defaults)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(#"{"schema":1}"#.utf8).write(to: stage.appendingPathComponent("remile-storage.json"))
        }
        let machine = StorageLocation.machineID(defaults: defaults)
        let oldRoot = StorageLocation.root(defaults: defaults)
        let ownMarks = StorageLocation.overleafMarksFolder + "/" + machine
        let oldMarks = oldRoot.appendingPathComponent(ownMarks)
        let newMarks = target.appendingPathComponent(ownMarks)
        if manager.fileExists(atPath: oldMarks.path), !manager.fileExists(atPath: newMarks.path) {
            let parent = newMarks.deletingLastPathComponent()
            let incoming = parent.appendingPathComponent(".incoming-" + UUID().uuidString)
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: incoming) }
            try manager.copyItem(at: oldMarks, to: incoming)
            try manager.moveItem(at: incoming, to: newMarks)
        }
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
        defaults.set(oldReference.path, forKey: referencePreference)
        defaults.set(destination.path, forKey: StorageLocation.preference)
        defaults.removeObject(forKey: StorageLocation.pendingPreference)
    }
    private static func validateStorage(_ root: URL) throws {
        let marker = root.appendingPathComponent("remile-storage.json")
        guard let size = try? marker.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_000,
              let data = try? Data(contentsOf: marker),
              let schema = try? JSONDecoder().decode([String: Int].self, from: data), schema["schema"] == 1 else {
            throw Failure("Choose an existing remile storage folder.")
        }
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
