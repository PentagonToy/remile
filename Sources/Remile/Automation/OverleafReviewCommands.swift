import Foundation

@MainActor enum OverleafReviewCommands {
    static func handle(
        connection: OverleafConnection, root: URL, project: TeXProject?, format: String?, output: String?,
        library: OverleafLibrary
    ) async -> [String: Any] {
        do {
            try OverleafReviewAccess.requireEnabled()
            let buffers =
                project?.buffers ?? library.warmProject.flatMap { $0.root.path == root.path ? $0.buffers : nil } ?? [:]
            var sources = try await Task.detached(priority: .utility) { try readSources(root) }.value
            for (path, source) in buffers { sources[path] = source }
            let snapshot = try await OverleafReviewService.read(
                connection, paths: sources.keys.sorted(), main: project?.main)
            library.comments[connection.id] = snapshot.archive
            project?.overleafReview = snapshot
            let format =
                format ?? output.map {
                    URL(fileURLWithPath: $0).pathExtension.lowercased() == "zip"
                        ? "bundle" : URL(fileURLWithPath: $0).pathExtension.lowercased() == "md" ? "markdown" : "json"
                } ?? "json"
            if format == "bundle" {
                guard let output, output.hasPrefix("/"),
                    URL(fileURLWithPath: output).pathExtension.lowercased() == "zip",
                    !FileManager.default.fileExists(atPath: output)
                else { throw OverleafGit.Failure("Provide a new absolute .zip output path for the review package.") }
                try await Task.detached(priority: .utility) {
                    try OverleafReviewPackage.write(snapshot, sources: sources, to: URL(fileURLWithPath: output))
                }.value
                return [
                    "ok": true, "output": output, "format": "bundle", "comments": snapshot.archive.threads.count,
                    "changes": snapshot.changes.count, "complete": snapshot.warning == nil,
                ]
            }
            return try snapshot.response(format: format, output: output)
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
    nonisolated static func readSources(_ root: URL) throws -> [String: String] {
        let paths = try TeXFileSystem.paths(root).filter {
            ["tex", "bib", "sty", "cls", "bst", "md", "txt"].contains(($0 as NSString).pathExtension.lowercased())
        }
        guard paths.count <= 1000 else {
            throw OverleafGit.Failure("Read up to 1,000 text source files per review package.")
        }
        var result: [String: String] = [:]
        var count = 0
        for path in paths {
            let value = try OverleafCommands.readSource(path, root: root)
            count += value.utf8.count
            guard count <= 64_000_000 else {
                throw OverleafGit.Failure("Read up to 64 MB of text sources per review package.")
            }
            result[path] = value
        }
        return result
    }
}
