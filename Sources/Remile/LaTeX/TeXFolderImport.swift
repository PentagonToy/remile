import Foundation

extension TeXFileSystem {
    struct FolderImport: Sendable {
        let staging: URL
        let files: [String]
        let folders: [String]
        let sources: [String: String]
    }

    static func stageFolder(_ source: URL, root: URL) throws -> FolderImport {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard source.isFileURL, values.isDirectory == true, values.isSymbolicLink != true,
              sourcePath != rootPath, !rootPath.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(rootPath + "/") else {
            throw Failure(errorDescription: "Choose a folder outside this project.")
        }
        let contents = try OverleafSourceFiles.scan(source)
        let directories = try folders(source)
        // Keep staging outside the working tree while Git scans untracked files.
        let staging = root.deletingLastPathComponent().appendingPathComponent(".remile-folder-" + UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for path in directories {
                guard OverleafSourceFiles.validPath(path) else { throw Failure(errorDescription: "This folder contains an unsupported name.") }
                try manager.createDirectory(at: staging.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            var sources: [String: String] = [:]
            for (path, data) in contents {
                try Task.checkCancellation()
                if OverleafSourceFiles.source(path) {
                    guard data.count <= 4_000_000, sources.count < 2000, let text = String(data: data, encoding: .utf8) else {
                        throw Failure(errorDescription: "Add UTF-8 source files up to 4 MB each.")
                    }
                    sources[path] = text
                }
                let target = staging.appendingPathComponent(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .withoutOverwriting)
            }
            return FolderImport(staging: staging, files: contents.keys.sorted(), folders: directories, sources: sources)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
}
