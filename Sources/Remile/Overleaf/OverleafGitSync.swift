import Foundation

/// Git owns transport. Private snapshots own recovery; the editor never undergoes a pull/reset.
enum OverleafGitSync {
    struct ReviewRequired: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    struct RemoteAdvanced: LocalizedError {
        let errorDescription: String? = "Overleaf changed during sync. Your work is kept and sync will retry."
    }
    struct Prepared: Sendable {
        let review: OverleafGit.Review
        let files: [String: Data]
        let head: String
        let originalHead: String
        let recovery: URL
        var resumed = false
    }
    /// One immediate retry absorbs an ordinary concurrent push without an unbounded network loop.
    static func synchronise(_ connection: OverleafConnection, root: URL, recovery: URL, transport: String? = nil) throws -> (prepared: Prepared, caughtUp: Bool) {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let prepared = try prepare(connection, root: root, recovery: recovery, transport: transport)
            if prepared.review.changes.isEmpty && !prepared.resumed { return (prepared, true) }
            do { return (prepared, try publish(prepared)) }
            catch is RemoteAdvanced {
                guard attempt == 0 else { throw RemoteAdvanced() }
                guard try OverleafGit.head(root) == prepared.originalHead else {
                    throw ReviewRequired("Local Git history changed during sync. Your work and recovery copy are kept.")
                }
                // The server was fetched and has not accepted this head. Retain its local snapshot before rebuilding.
                try OverleafSyncRecovery.finish(prepared)
            }
        }
        throw RemoteAdvanced()
    }
    static func prepare(_ connection: OverleafConnection, root: URL, recovery: URL, transport: String? = nil) throws -> Prepared {
        try Task.checkCancellation()
        if let pending = try OverleafSyncRecovery.resume(connection, root: root, recovery: recovery, transport: transport) { return pending }
        let stage = OverleafSyncRecovery.stage(connection, recovery: recovery)
        // No push can occur before the receipt exists. An interrupted preparation is reproducible from the root.
        if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
        let originalHead = try OverleafGit.head(root)
        let review = try OverleafGit.prepare(connection, root: root, reviewRoot: recovery, transport: transport, includeContents: false, stageDirectory: stage)
        if review.changes.isEmpty {
            if FileManager.default.fileExists(atPath: review.stage.path) {
                guard try OverleafGit.fingerprint(root) == review.fingerprint,
                      try OverleafGit.head(root) == originalHead else { throw ReviewRequired("Local files changed. Review changes before syncing.") }
                // History-only remote commits need no source install or outgoing push.
                _ = try OverleafGit.run(["reset", "--mixed", review.remoteHead], at: root)
                try FileManager.default.removeItem(at: review.stage)
            }
            return Prepared(review: review, files: [:], head: review.remoteHead, originalHead: originalHead, recovery: recovery)
        }
        try OverleafSyncRecovery.checkCapacity(root: root, recovery: recovery)
        for change in review.changes where change.conflict {
            let base = try source(":1:" + change.path, at: review.stage)
            let local = try source(":2:" + change.path, at: review.stage)
            let remote = try source(":3:" + change.path, at: review.stage)
            guard let base, let local, let remote,
                  let merged = try? OverleafSourceText.merge(base: base, local: local, remote: remote) else {
                throw ReviewRequired("Both sides changed “\(change.path)”. Review changes before syncing.")
            }
            try merged.write(to: TeXFileSystem.url(change.path, root: review.stage), atomically: true, encoding: .utf8)
            _ = try OverleafGit.run(["add", "--", change.path], at: review.stage)
        }
        let files = try OverleafSourceFiles.scan(review.stage)
        // Preserve the local snapshot and its history before creating a linear Overleaf commit.
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "fetch", review.stage.path, "HEAD"], at: root)
        let local = try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try OverleafGit.run(["update-ref", OverleafSyncRecovery.pendingReference, local], at: root)
        _ = try OverleafGit.run(["add", "--all"], at: review.stage)
        let tree = try OverleafGit.run(["write-tree"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteTree = try OverleafGit.run(["rev-parse", review.remoteHead + "^{tree}"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = tree == remoteTree ? review.remoteHead : try OverleafGit.run(["commit-tree", tree, "-p", review.remoteHead, "-m", "Update manuscript from remile."], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lost push response is resolved by the next fetch. Keep this commit reachable meanwhile.
        _ = try OverleafGit.run(["update-ref", "refs/remile/prepared", head], at: review.stage)
        try Data((head + "\n").utf8).write(to: review.stage.appendingPathComponent(".git/remile-pending"), options: .atomic)
        let prepared = Prepared(review: review, files: files, head: head, originalHead: originalHead, recovery: review.stage)
        try OverleafSyncRecovery.save(prepared, localHead: local)
        return prepared
    }
    @discardableResult static func publish(_ prepared: Prepared) throws -> Bool {
        try Task.checkCancellation()
        let review = prepared.review
        guard try OverleafGit.head(review.root) == prepared.originalHead else {
            throw OverleafGit.Failure("The local Git history changed. Check changes before syncing.")
        }
        let local = review.transport.hasPrefix("/") ? ["-c", "protocol.file.allow=always"] : []
        func fetch() throws -> String {
            _ = try OverleafGit.run(local + ["fetch", "--no-tags", review.transport, "refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID)
            return try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var observed: String?
        if prepared.resumed {
            let remote = try fetch()
            if try OverleafGit.run(["merge-base", "--is-ancestor", prepared.head, remote], at: review.stage, allowFailure: true).status == 0 { observed = remote }
            else if prepared.originalHead == prepared.head {
                throw ReviewRequired("Overleaf history no longer contains the installed sync. Review changes. Your local work and recovery copy are kept.")
            } else if remote != review.remoteHead {
                if try OverleafGit.run(["merge-base", "--is-ancestor", review.remoteHead, remote], at: review.stage, allowFailure: true).status == 0 { throw RemoteAdvanced() }
                throw ReviewRequired("Overleaf history changed while sync was interrupted. Review changes. Your local work and recovery copy are kept.")
            }
        }
        if observed == nil, prepared.head != review.remoteHead {
            do {
                _ = try OverleafGit.run(local + ["push", review.transport, prepared.head + ":refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID)
            } catch {
                try Task.checkCancellation()
                if (error as? OverleafGit.Failure)?.retryAfter != nil { throw error }
                // A failed response may hide either a concurrent push or an already accepted upload.
                let remote = try fetch()
                if try OverleafGit.run(["merge-base", "--is-ancestor", prepared.head, remote], at: review.stage, allowFailure: true).status == 0 { observed = remote }
                else if remote != review.remoteHead,
                        try OverleafGit.run(["merge-base", "--is-ancestor", review.remoteHead, remote], at: review.stage, allowFailure: true).status == 0 { throw RemoteAdvanced() }
                else { throw error }
            }
        }
        // Fetch, rather than ls-remote: Overleaf materialises browser edits when fetching.
        let remote = try observed ?? fetch()
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
            merged[path] = Data(try OverleafSourceText.merge(base: b, local: l, remote: r).utf8)
        }
        return merged
    }
    private static func source(_ ref: String, at root: URL) throws -> String? {
        let result = try OverleafGit.run(["show", ref], at: root, allowFailure: true)
        guard result.status == 0, result.data.count <= OverleafSource.textLimit else { return nil }
        return String(data: result.data, encoding: .utf8)
    }
}
