import Foundation
import Darwin

/// Private recovery data outside the project worktree; no cookies or Git tokens.
enum OverleafLiveJournal {
    static func checkpoint(for key: OverleafLive.Key, under directory: URL) -> URL {
        directory.appendingPathComponent(key.profile.uuidString).appendingPathComponent(key.project).appendingPathComponent(key.document + ".json")
    }
    static func lock(for key: OverleafLive.Key, under directory: URL) -> URL {
        directory.appendingPathComponent(key.profile.uuidString).appendingPathComponent(key.project).appendingPathComponent("writer.lock")
    }
    static func save(_ checkpoint: OverleafLive.Checkpoint, to file: URL) throws {
        try checkpoint.validate()
        let manager = FileManager.default, folder = file.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw OverleafLive.Failure.invalidCheckpoint }
        if manager.fileExists(atPath: file.path) {
            _ = try load(from: file, for: checkpoint.key)
        }
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= 16_000_000 else { throw OverleafLive.Failure.invalidCheckpoint }
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func load(from file: URL, for key: OverleafLive.Key) throws -> OverleafLive.Checkpoint {
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]).isSymbolicLink != true,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_000_000 else { throw OverleafLive.Failure.invalidCheckpoint }
        let saved = try JSONDecoder().decode(OverleafLive.Checkpoint.self, from: Data(contentsOf: file))
        try saved.validate()
        guard saved.key == key else { throw OverleafLive.Failure.invalidIdentity }
        return saved
    }
}

/// An OS lock expires with its owner. Keep the lock inode on release to avoid races.
final class OverleafLiveWriterLease {
    private let descriptor: Int32
    init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let opened = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard opened >= 0 else { throw OverleafLive.Failure.writerBusy }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(opened); throw OverleafLive.Failure.writerBusy }
        descriptor = opened
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
