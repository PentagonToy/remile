import Foundation

/// Premium file operations use a normal Git push from the latest remote tree.
/// Only the reconciled paths are changed. A concurrent commit rejects the push.
enum OverleafGitLiveFiles {
    static func publish(_ plan: OverleafLiveFiles.Plan, connection: OverleafConnection, root: URL, recovery: URL, transport: String? = nil, beforePush: (() throws -> Void)? = nil) throws {
        try Task.checkCancellation()
        let remote = transport ?? connection.remote
        let localTransport = transport != nil && remote.hasPrefix("/") ? ["-c", "protocol.file.allow=always"] : []
        let stage = recovery.appendingPathComponent("Git publish")
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "clone", "--shared", "--no-checkout", "--", root.path, stage.path], at: recovery)
        _ = try OverleafGit.run(localTransport + ["fetch", "--no-tags", remote, "refs/heads/" + connection.branch], at: stage, credential: connection.profileID)
        _ = try OverleafGit.run(["checkout", "--detach", "FETCH_HEAD"], at: stage)
        let paths = plan.uploads + plan.deletions
        for path in paths {
            try Task.checkCancellation()
            guard OverleafLiveFiles.validPath(path) else { throw OverleafLiveFiles.Failure.invalid }
            let url = try TeXFileSystem.url(path, root: stage)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= OverleafLiveFiles.fileLimit else { throw OverleafLiveFiles.Failure.invalid }
            }
            let current = exists ? try Data(contentsOf: url) : nil
            guard current == plan.remote[path] else { throw OverleafLiveFiles.Failure.stale }
        }
        for path in paths {
            try Task.checkCancellation()
            let url = try TeXFileSystem.url(path, root: stage)
            if let bytes = plan.result[path] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        guard !paths.isEmpty else { return }
        _ = try OverleafGit.run(["add", "--all", "--"] + paths, at: stage)
        _ = try OverleafGit.run(["-c", "commit.gpgsign=false", "commit", "-m", "Sync remile. Live project files"], at: stage)
        try beforePush?()
        _ = try OverleafGit.run(localTransport + ["push", remote, "HEAD:refs/heads/" + connection.branch], at: stage, credential: connection.profileID)
        // Keep an additional local Git ref without changing the open project's branch or index.
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "fetch", stage.path, "HEAD"], at: root)
        let head = try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OverleafGit.run(["update-ref", "refs/remile/live-published/" + UUID().uuidString.lowercased(), head], at: root)
    }
}
