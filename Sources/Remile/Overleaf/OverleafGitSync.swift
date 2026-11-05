import Foundation

/// Git owns transport. Private snapshots own recovery; the editor never undergoes a pull/reset.
enum OverleafGitSync {
    struct ReviewRequired: LocalizedError {
        let errorDescription: String?
        let retryAfterEditing: Bool
        init(_ message: String, retryAfterEditing: Bool = false) { errorDescription = message; self.retryAfterEditing = retryAfterEditing }
    }
    struct RemoteAdvanced: LocalizedError {
        let errorDescription: String? = "Overleaf changed during sync. Your work is kept and sync will retry."
    }
    struct Prepared: Sendable {
        let review: OverleafGit.Review
        let files: [String: Data]
        let head: String
        let originalHead: String
        let localHead: String
        let recovery: URL
        var resumed = false
    }
    /// Reprepare once when the remote advances or pending local work changes.
    static func synchronise(_ connection: OverleafConnection, root: URL, recovery: URL, transport: String? = nil, record: OverleafGit.RecordTransfer? = nil) throws -> (prepared: Prepared, remoteChanged: Bool) {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let prepared = try prepare(connection, root: root, recovery: recovery, transport: transport, record: record)
            let remoteChanged = prepared.review.remoteHead != prepared.originalHead
            if prepared.review.changes.isEmpty && !prepared.resumed { return (prepared, remoteChanged) }
            do {
                let confirmed = try confirmPublication(prepared, record: record)
                return (try OverleafSyncRecovery.incorporatingConfirmedRemote(prepared, head: confirmed), remoteChanged || confirmed != prepared.head)
            }
            catch let error where error is RemoteAdvanced || error is OverleafGit.SnapshotChanged {
                guard attempt == 0 else { throw error }
                guard try OverleafGit.head(root) == prepared.originalHead else {
                    throw ReviewRequired("Local Git history changed during sync. Your work and recovery copy are kept.")
                }
                // Retain the unconfirmed local snapshot before rebuilding from current files.
                try OverleafSyncRecovery.finish(prepared)
            }
        }
        throw RemoteAdvanced()
    }
    static func prepare(_ connection: OverleafConnection, root: URL, recovery: URL, transport: String? = nil, record: OverleafGit.RecordTransfer? = nil) throws -> Prepared {
        try Task.checkCancellation()
        if let pending = try OverleafSyncRecovery.resume(connection, root: root, recovery: recovery, transport: transport) { return pending }
        let stage = OverleafSyncRecovery.stage(connection, recovery: recovery)
        // No push can occur before the receipt exists. An interrupted preparation is reproducible from the root.
        if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
        let originalHead = try OverleafGit.head(root)
        let review = try OverleafGit.prepare(connection, root: root, reviewRoot: recovery, transport: transport, includeContents: false, stageDirectory: stage, record: record)
        if review.changes.isEmpty {
            let prepared = Prepared(review: review, files: [:], head: review.remoteHead, originalHead: originalHead, localHead: originalHead, recovery: recovery)
            if FileManager.default.fileExists(atPath: review.stage.path) {
                guard try OverleafGit.head(root) == originalHead else { throw ReviewRequired("Local Git history changed. Review changes before syncing.") }
                guard try OverleafGit.fingerprint(root) == review.fingerprint else { throw OverleafGit.SnapshotChanged() }
                // History-only remote commits need no source install or outgoing push.
                try advanceLocalBase(prepared)
                try FileManager.default.removeItem(at: review.stage)
            }
            return prepared
        }
        try OverleafSyncRecovery.checkCapacity(root: root, recovery: recovery)
        for change in review.changes where change.conflict {
            let base = try source(":1:" + change.path, at: review.stage)
            let local = try source(":2:" + change.path, at: review.stage)
            let remote = try source(":3:" + change.path, at: review.stage)
            guard let base, let local, let remote,
                  let merged = try? OverleafSourceText.merge(base: base, local: local, remote: remote) else {
                throw ReviewRequired("Both sides changed “\(change.path)”. Review changes before syncing.", retryAfterEditing: true)
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
        let prepared = Prepared(review: review, files: files, head: head, originalHead: originalHead, localHead: local, recovery: review.stage)
        try OverleafSyncRecovery.save(prepared)
        return prepared
    }
    @discardableResult static func publish(_ prepared: Prepared) throws -> Bool {
        try confirmPublication(prepared, record: nil) == prepared.head
    }
    static func advanceLocalBase(_ prepared: Prepared) throws {
        let root = prepared.review.root
        let branch = "refs/heads/" + prepared.review.connection.branch
        let checkedOut = try OverleafGit.run(["symbolic-ref", "--quiet", "HEAD"], at: root, allowFailure: true)
        guard checkedOut.text.trimmingCharacters(in: .newlines) == branch,
              try OverleafGit.run(["update-ref", "-m", "Confirm Overleaf sync", branch, prepared.head, prepared.originalHead], at: root, allowFailure: true).status == 0 else {
            throw ReviewRequired("Local Git history changed during sync. Your work and recovery copy are kept.")
        }
        // Update the index after advancing the expected branch. Never reset a working file.
        _ = try OverleafGit.run(["read-tree", "--reset", "HEAD"], at: root)
    }
    static func containsPublication(_ prepared: Prepared, at remote: String) throws -> Bool {
        if prepared.head == remote { return true }
        let review = prepared.review
        if try OverleafGit.run(["merge-base", "--is-ancestor", prepared.head, remote], at: review.stage, allowFailure: true).status == 0 { return true }
        guard prepared.head != review.remoteHead, remote != review.remoteHead else { return false }

        // Overleaf can recreate the commit. Require the exact tree and parent
        // at the start of the remote's first-parent history after preparation.
        let publication = try OverleafGit.run(["show", "-s", "--format=%P %T", prepared.head], at: review.stage).text
            .trimmingCharacters(in: .newlines)
        let fields = publication.split(separator: " ")
        guard fields.count == 2, fields[0] == review.remoteHead else { return false }
        let range = review.remoteHead + ".." + remote
        let history = try OverleafGit.run(["log", "--first-parent", "--ancestry-path", "--format=%P %T", range], at: review.stage).text
        return history.split(separator: "\n").last == publication[...]
    }
    private static func confirmPublication(_ prepared: Prepared, record: OverleafGit.RecordTransfer?) throws -> String {
        try Task.checkCancellation()
        let review = prepared.review
        guard try OverleafGit.head(review.root) == prepared.originalHead else {
            throw OverleafGit.Failure("The local Git history changed. Check changes before syncing.")
        }
        let local = review.transport.hasPrefix("/") ? ["-c", "protocol.file.allow=always"] : []
        func fetch() throws -> String {
            try OverleafGit.transfer(.confirm, local + ["fetch", "--no-tags", review.transport, "refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID, record: record)
            return try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var observed: String?
        if prepared.resumed {
            let remote = try fetch()
            if try containsPublication(prepared, at: remote) { observed = remote }
            else if prepared.originalHead == prepared.head {
                throw ReviewRequired("Overleaf history no longer contains the installed sync. Review changes. Your local work and recovery copy are kept.")
            } else if remote != review.remoteHead {
                if try OverleafGit.run(["merge-base", "--is-ancestor", review.remoteHead, remote], at: review.stage, allowFailure: true).status == 0 { throw RemoteAdvanced() }
                throw ReviewRequired("Overleaf history changed while sync was interrupted. Review changes. Your local work and recovery copy are kept.")
            } else if try OverleafGit.fingerprint(review.root) != review.fingerprint { throw OverleafGit.SnapshotChanged() }
        }
        if observed == nil, prepared.head != review.remoteHead {
            do {
                try OverleafGit.transfer(.push, local + ["push", review.transport, prepared.head + ":refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID, record: record)
            } catch {
                try Task.checkCancellation()
                if (error as? OverleafGit.Failure)?.retryAfter != nil { throw error }
                // A failed response may hide either a concurrent push or an already accepted upload.
                let remote = try fetch()
                if try containsPublication(prepared, at: remote) { observed = remote }
                else if remote != review.remoteHead,
                        try OverleafGit.run(["merge-base", "--is-ancestor", review.remoteHead, remote], at: review.stage, allowFailure: true).status == 0 { throw RemoteAdvanced() }
                else { throw error }
            }
        }
        // Fetch, rather than ls-remote: Overleaf materialises browser edits when fetching.
        let remote = try observed ?? fetch()
        guard try observed != nil || containsPublication(prepared, at: remote) else {
            throw OverleafGit.Failure("The upload could not be confirmed. Your local work is safe. Retry sync.")
        }
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "fetch", review.stage.path, remote], at: review.root)
        return remote
    }
    /// Rebase typing that happened during transport onto the prepared result.
    static func reconcile(base: [String: Data], current: [String: Data], result: [String: Data]) throws -> [String: Data] {
        var base = base, current = current, result = result
        let localRenames = exactSourceRenames(base: base, changed: current)
        let remoteRenames = exactSourceRenames(base: base, changed: result)
        for path in Set(localRenames.keys).union(remoteRenames.keys) {
            guard let target = localRenames[path] ?? remoteRenames[path],
                  localRenames[path] == nil || remoteRenames[path] == nil || localRenames[path] == remoteRenames[path] else {
                throw ReviewRequired("A file was moved to different places. Your edits and the recovery copy are kept.", retryAfterEditing: true)
            }
            // Only an unchanged, unique source move supplies identity. Never
            // guess between copies, competing destinations or a deletion.
            for snapshot in [current, result] {
                guard (snapshot[path] != nil) != (snapshot[target] != nil) else {
                    throw ReviewRequired("“\(path)” was moved while its other version changed. Your work is kept.", retryAfterEditing: true)
                }
            }
            base[target] = base.removeValue(forKey: path)
            if let bytes = current.removeValue(forKey: path) { current[target] = bytes }
            if let bytes = result.removeValue(forKey: path) { result[target] = bytes }
        }
        var merged = current
        for path in Set(base.keys).union(result.keys) where base[path] != result[path] {
            if current[path] == base[path] || current[path] == result[path] { merged[path] = result[path]; continue }
            guard let b = base[path].flatMap({ String(data: $0, encoding: .utf8) }),
                  let l = current[path].flatMap({ String(data: $0, encoding: .utf8) }),
                  let r = result[path].flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw ReviewRequired("“\(path)” changed during sync. Your edits and the recovery copy are kept.", retryAfterEditing: true)
            }
            merged[path] = Data(try OverleafSourceText.merge(base: b, local: l, remote: r).utf8)
        }
        return merged
    }
    static func exactSourceRenames(base: [String: Data], changed: [String: Data]) -> [String: String] {
        var removed: [Data: [String]] = [:], added: [Data: [String]] = [:]
        for (path, bytes) in base where changed[path] == nil && OverleafSourceFiles.source(path) && bytes.count <= OverleafSource.textLimit && !bytes.isEmpty {
            removed[bytes, default: []].append(path)
        }
        guard !removed.isEmpty else { return [:] }
        for (path, bytes) in changed where base[path] == nil && OverleafSourceFiles.source(path) && bytes.count <= OverleafSource.textLimit && removed[bytes] != nil {
            added[bytes, default: []].append(path)
        }
        var renames: [String: String] = [:]
        for (bytes, paths) in removed where paths.count == 1 {
            if let targets = added[bytes], targets.count == 1 { renames[paths[0]] = targets[0] }
        }
        return renames
    }
    private static func source(_ ref: String, at root: URL) throws -> String? {
        let result = try OverleafGit.run(["show", ref], at: root, allowFailure: true)
        guard result.status == 0, result.data.count <= OverleafSource.textLimit else { return nil }
        return String(data: result.data, encoding: .utf8)
    }
}
