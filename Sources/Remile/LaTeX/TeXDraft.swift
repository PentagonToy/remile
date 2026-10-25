import Foundation

/// Private working folders are not added to Recent and are never used as published projects.
enum TeXDraft {
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Drafts/LaTeX", isDirectory: true) }
    static func create(under parent: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try TeXProjectCreation.create(at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
}
