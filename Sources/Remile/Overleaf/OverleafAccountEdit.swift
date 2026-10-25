import Foundation

/// A small recoverable journal keeps the two existing catalogues consistent across interruption.
enum OverleafAccountEdit {
    struct Change: Codable, Sendable {
        let accounts: Data
        let projects: Data
        let removedProjects: [OverleafConnection]
        let removedProfile: UUID?
    }
    // Removal callers hold all project writer leases through credential and file cleanup.
    static func apply(_ change: Change, under directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("account-edit.json")
        try JSONEncoder().encode(change).write(to: file, options: .atomic)
        try finish(change, under: directory)
    }
    static func recover(under directory: URL) throws {
        let manager = FileManager.default, file = directory.appendingPathComponent("account-edit.json")
        guard manager.fileExists(atPath: file.path) else { return }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let change = try JSONDecoder().decode(Change.self, from: Data(contentsOf: file))
        let leases = try change.removedProjects.map { project -> OverleafLiveWriterLease in
            let key = OverleafLive.Key(profile: project.profileID, project: project.projectID, document: project.projectID)
            try key.validate()
            return try OverleafLiveWriterLease(file: OverleafLiveJournal.lock(for: key, under: directory.appendingPathComponent("Live")))
        }
        defer { withExtendedLifetime(leases) {} }
        try finish(change, under: directory)
    }
    private static func finish(_ change: Change, under directory: URL) throws {
        let manager = FileManager.default, file = directory.appendingPathComponent("account-edit.json")
        for project in change.removedProjects {
            let root = directory.appendingPathComponent("Projects/" + project.id.uuidString)
            // Never follow a project alias outside the managed library when removing history.
            let parent = directory.appendingPathComponent("Projects").resolvingSymlinksInPath().standardizedFileURL.path
            guard parent.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                let history = TeXHistory.directory(root)
                if manager.fileExists(atPath: history.path) { try manager.removeItem(at: history) }
                let review = ManuscriptReviewStore.file(for: root)
                if manager.fileExists(atPath: review.path) { try manager.removeItem(at: review) }
            }
            if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
            let baseline = OverleafSourceArchive.baseline(project.id, under: directory)
            if manager.fileExists(atPath: baseline.path) { try manager.removeItem(at: baseline) }
            let liveFiles = directory.appendingPathComponent("LiveFiles/" + project.id.uuidString)
            if manager.fileExists(atPath: liveFiles.path) { try manager.removeItem(at: liveFiles) }
        }
        if let profile = change.removedProfile {
            let live = directory.appendingPathComponent("Live/" + profile.uuidString)
            if let files = manager.enumerator(at: live, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                for case let path as URL in files {
                    let attributes = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if attributes.isSymbolicLink == true { files.skipDescendants(); continue }
                    // Keep lock inodes stable for other remile processes. They contain no history.
                    if attributes.isDirectory != true, path.lastPathComponent != "writer.lock" { try manager.removeItem(at: path) }
                }
            }
        }
        try change.projects.write(to: directory.appendingPathComponent("projects.json"), options: .atomic)
        try change.accounts.write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
        try manager.removeItem(at: file)
    }
}
