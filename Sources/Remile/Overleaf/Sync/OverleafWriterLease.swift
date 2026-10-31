import Foundation
import Darwin

/// An OS lock expires with its owner. Keep the lock inode on release to avoid races.
final class OverleafWriterLease {
    // Keep the existing Live directory layout so old and new builds exclude the same writer.
    static func lock(for key: OverleafSource.Key, under directory: URL) -> URL {
        directory.appendingPathComponent(key.profile.uuidString).appendingPathComponent(key.project).appendingPathComponent("writer.lock")
    }
    private let descriptor: Int32
    init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let opened = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard opened >= 0 else { throw OverleafSource.Failure.writerBusy }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(opened); throw OverleafSource.Failure.writerBusy }
        descriptor = opened
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
