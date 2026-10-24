import Foundation
import CryptoKit

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
    private static func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return Data(hash.finalize())
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}
