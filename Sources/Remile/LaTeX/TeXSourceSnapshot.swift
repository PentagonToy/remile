import Foundation

/// Snapshot copying is shared by compilation and source export. Original files are never changed.
enum TeXSourceSnapshot {
    static func write(root: URL, buffers: [String: String], to destination: URL, submissionCheck: Bool = false) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path), !destination.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileWriteFileExists) }
        guard let items = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var count = 0, size = buffers.values.reduce(0) { $0 + $1.utf8.count }
        for case let url as URL in items {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]); count += 1; size += values.fileSize ?? 0
            guard values.isSymbolicLink != true, count <= 10000, size <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let path = String(url.path.dropFirst(root.path.count + 1)), target = destination.appendingPathComponent(path)
            if submissionCheck, values.isDirectory != true, isBuildOrBibliographyFile(url) { continue }
            if values.isDirectory == true { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
            else { try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try manager.copyItem(at: url, to: target) }
        }
        for (file, source) in buffers {
            if submissionCheck, isBuildOrBibliographyFile(URL(fileURLWithPath: file)) { continue }
            guard source.utf8.count <= 4_000_000, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { throw CocoaError(.fileReadInvalidFileName) }
            try source.write(to: destination.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }
    private static func isBuildOrBibliographyFile(_ url: URL) -> Bool {
        ["bib", "bbl", "bst", "aux", "bcf", "blg", "toc", "out", "lof", "lot", "fls", "fdb_latexmk"].contains(url.pathExtension.lowercased()) || url.lastPathComponent.hasSuffix(".run.xml") || url.lastPathComponent.hasSuffix(".synctex.gz")
    }
    static func export(root: URL, buffers: [String: String], to output: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: output.path), !output.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileWriteFileExists) }
        let folder = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Exports/" + UUID().uuidString)
        defer { try? manager.removeItem(at: folder) }
        let snapshot = folder.appendingPathComponent(root.lastPathComponent)
        try write(root: root, buffers: buffers, to: snapshot)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", snapshot.path, output.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
