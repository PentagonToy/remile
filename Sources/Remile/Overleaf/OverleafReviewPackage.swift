import Foundation

/// A portable reading package. It deliberately excludes credentials, figures and build artefacts.
enum OverleafReviewPackage {
    static func write(_ review: OverleafReviewSnapshot, sources: [String: String], to output: URL, replacing: Bool = false) throws {
        let manager = FileManager.default
        guard output.isFileURL, output.pathExtension.lowercased() == "zip", replacing || !manager.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let additional = review.reviewSources.filter { sources[$0.key] != $0.value }
        guard sources.count + additional.count <= 1000, (Array(sources.values) + Array(additional.values)).reduce(0, { $0 + $1.utf8.count }) <= 64_000_000 else { throw OverleafGit.Failure("Export up to 1,000 text sources and 64 MB per review package.") }
        let temporary = manager.temporaryDirectory.appendingPathComponent("remile-review-" + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("Review"), staged = temporary.appendingPathComponent("review.zip")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        func write(_ text: String, path: String) throws {
            guard !path.hasPrefix("/"), !path.contains("\\"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileWriteInvalidFileName) }
            let file = package.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try review.export(json: false).write(to: package.appendingPathComponent("review.md"))
        try review.export(json: true).write(to: package.appendingPathComponent("review.json"))
        for (path, text) in sources { try write(text, path: "source/" + path) }
        var differences: [String] = []
        for (path, text) in review.reviewSources where sources[path] != text {
            differences.append(path); try write(text, path: "review-source/" + path)
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "projectReference": "overleaf:" + review.archive.projectID, "main": review.main as Any? ?? NSNull(), "sourceHashes": sources.mapValues(SourceDigest.sha256), "reviewSourceHashes": review.reviewSources.mapValues(SourceDigest.sha256), "differentSources": differences.sorted()]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
        try write("Read review.md with source/. IDs identify comments and tracked edits. Hashes identify source snapshots. If a local source differs, review-source/ keeps the version used for its review anchor. This package contains text sources only. Figures and compiled PDFs are omitted.\n", path: "README.txt")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", package.path, staged.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Data(contentsOf: staged).write(to: output, options: .atomic)
    }
}
