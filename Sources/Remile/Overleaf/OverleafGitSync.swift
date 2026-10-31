import Foundation

/// Git owns transport. Private snapshots own recovery; the editor never undergoes a pull/reset.
enum OverleafGitSync {
    struct ReviewRequired: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    struct Prepared: Sendable {
        let review: OverleafGit.Review
        let files: [String: Data]
        let head: String
        let originalHead: String
        let recovery: URL
    }
    static func prepare(_ connection: OverleafConnection, root: URL, recovery: URL, transport: String? = nil) throws -> Prepared {
        try Task.checkCancellation()
        let originalHead = try OverleafAutoPublisher.head(root)
        let review = try OverleafGit.prepare(connection, root: root, reviewRoot: recovery, transport: transport)
        if review.changes.isEmpty {
            if FileManager.default.fileExists(atPath: review.stage.path) {
                guard try OverleafGit.fingerprint(root) == review.fingerprint,
                      try OverleafAutoPublisher.head(root) == originalHead else { throw ReviewRequired("Local files changed. Review changes before syncing.") }
                // History-only remote commits need no source install or outgoing push.
                _ = try OverleafGit.run(["reset", "--mixed", review.remoteHead], at: root)
                try FileManager.default.removeItem(at: review.stage)
            }
            return Prepared(review: review, files: [:], head: review.remoteHead, originalHead: originalHead, recovery: recovery)
        }
        for change in review.changes where change.conflict {
            let base = try source(":1:" + change.path, at: review.stage)
            let local = try source(":2:" + change.path, at: review.stage)
            let remote = try source(":3:" + change.path, at: review.stage)
            guard let base, let local, let remote,
                  let merged = try? OverleafLiveText.merge(base: base, local: local, remote: remote) else {
                throw ReviewRequired("Both sides changed “\(change.path)”. Review changes before syncing.")
            }
            try merged.write(to: TeXFileSystem.url(change.path, root: review.stage), atomically: true, encoding: .utf8)
            _ = try OverleafGit.run(["add", "--", change.path], at: review.stage)
        }
        let files = try OverleafLiveFiles.scan(review.stage)
        // Preserve the local snapshot and its history before creating a linear Overleaf commit.
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "fetch", review.stage.path, "HEAD"], at: root)
        let local = try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OverleafGit.run(["update-ref", "refs/remile/git-recovery/" + UUID().uuidString.lowercased(), local], at: root)
        _ = try OverleafGit.run(["add", "--all"], at: review.stage)
        let tree = try OverleafGit.run(["write-tree"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTree = try OverleafGit.run(["rev-parse", review.remoteHead + "^{tree}"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = tree == remoteTree ? review.remoteHead : try OverleafGit.run(["commit-tree", tree, "-p", review.remoteHead, "-m", "Update manuscript from remile."], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lost push response is resolved by the next fetch. Keep this commit reachable meanwhile.
        _ = try OverleafGit.run(["update-ref", "refs/remile/prepared", head], at: review.stage)
        try Data((head + "\n").utf8).write(to: review.stage.appendingPathComponent(".git/remile-pending"), options: .atomic)
        return Prepared(review: review, files: files, head: head, originalHead: originalHead, recovery: review.stage)
    }
    @discardableResult static func publish(_ prepared: Prepared) throws -> Bool {
        try Task.checkCancellation()
        let review = prepared.review
        guard try OverleafAutoPublisher.head(review.root) == prepared.originalHead else {
            throw OverleafGit.Failure("The local Git history changed. Check changes before syncing.")
        }
        let local = review.transport.hasPrefix("/") ? ["-c", "protocol.file.allow=always"] : []
        if prepared.head != review.remoteHead {
            _ = try OverleafGit.run(local + ["push", review.transport, prepared.head + ":refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID)
        }
        // Fetch, rather than ls-remote: Overleaf materialises browser edits when fetching.
        _ = try OverleafGit.run(local + ["fetch", "--no-tags", review.transport, "refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID)
        let remote = try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try OverleafGit.run(["merge-base", "--is-ancestor", prepared.head, remote], at: review.stage, allowFailure: true).status == 0 else {
            throw OverleafGit.Failure("The upload could not be confirmed. Your local work is safe. Retry sync.")
        }
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "fetch", review.stage.path, prepared.head], at: review.root)
        return remote == prepared.head
    }
    /// Rebase typing that happened during transport onto the prepared result.
    static func reconcile(base: [String: Data], current: [String: Data], result: [String: Data]) throws -> [String: Data] {
        var merged = current
        for path in Set(base.keys).union(result.keys) where base[path] != result[path] {
            if current[path] == base[path] || current[path] == result[path] { merged[path] = result[path]; continue }
            guard let b = base[path].flatMap({ String(data: $0, encoding: .utf8) }),
                  let l = current[path].flatMap({ String(data: $0, encoding: .utf8) }),
                  let r = result[path].flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw ReviewRequired("“\(path)” changed during sync. Your edits and the recovery copy are kept.")
            }
            merged[path] = Data(try OverleafLiveText.merge(base: b, local: l, remote: r).utf8)
        }
        return merged
    }
    private static func source(_ ref: String, at root: URL) throws -> String? {
        let result = try OverleafGit.run(["show", ref], at: root, allowFailure: true)
        guard result.status == 0, result.data.count <= OverleafLive.textLimit else { return nil }
        return String(data: result.data, encoding: .utf8)
    }
}
