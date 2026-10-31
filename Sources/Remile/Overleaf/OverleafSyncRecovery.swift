import Foundation

/// One resumable operation per project. Receipts reference Git objects, never duplicate document bodies.
enum OverleafSyncRecovery {
    static let byteLimit = 256 * 1024 * 1024
    static let retainedReferences = 3
    static let pendingReference = "refs/remile/git-pending"
    private struct Receipt: Codable {
        let version: Int
        let connection: UUID
        let root: String
        let branch: String
        let originalHead: String
        let remoteHead: String
        let localHead: String
        let head: String
        let fingerprint: String
    }
    static func stage(_ connection: OverleafConnection, recovery: URL) -> URL {
        recovery.appendingPathComponent(connection.id.uuidString.lowercased() + ".work", isDirectory: true)
    }
    private static func receipt(_ connection: OverleafConnection, recovery: URL) -> URL {
        recovery.appendingPathComponent(connection.id.uuidString.lowercased() + ".json")
    }
    static func reference() -> String {
        "refs/remile/git-recovery/" + String(Int64(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.lowercased()
    }
    static func save(_ prepared: OverleafGitSync.Prepared, localHead: String) throws {
        let review = prepared.review
        let value = Receipt(version: 1, connection: review.connection.id,
                            root: SourceDigest.sha256(review.root.resolvingSymlinksInPath().path), branch: review.connection.branch,
                            originalHead: prepared.originalHead, remoteHead: review.remoteHead, localHead: localHead,
                            head: prepared.head, fingerprint: review.fingerprint)
        let url = receipt(review.connection, recovery: review.stage.deletingLastPathComponent())
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    static func resume(_ connection: OverleafConnection, root: URL, recovery: URL, transport: String?) throws -> OverleafGitSync.Prepared? {
        let url = receipt(connection, recovery: recovery)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 8192 else { throw invalid() }
        let data = try Data(contentsOf: url)
        guard data.count <= 8192, let saved = try? JSONDecoder().decode(Receipt.self, from: data),
              saved.version == 1, saved.connection == connection.id, saved.branch == connection.branch,
              saved.root == SourceDigest.sha256(root.resolvingSymlinksInPath().path),
              [saved.originalHead, saved.remoteHead, saved.localHead, saved.head].allSatisfy(validObject) else { throw invalid() }
        let stage = stage(connection, recovery: recovery)
        let properties = try stage.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard properties.isSymbolicLink != true, properties.isDirectory == true else { throw invalid() }
        let currentHead = try OverleafGit.head(root)
        guard currentHead == saved.originalHead || currentHead == saved.head else { throw invalid() }
        // Git objects are immutable. Share identical bytes only within this resume, never in a persistent cache.
        var objects: [String: Data] = [:]
        let base = try files(saved.localHead, at: root, objects: &objects)
        let result = try files(saved.head, at: stage, objects: &objects)
        let paths = Set(base.keys).union(result.keys).filter { base[$0] != result[$0] }
        // A completed source install may have happened before the app stopped. Reconcile is idempotent.
        let changes = paths.sorted().map { OverleafGit.Change(path: $0, local: "", remote: "", result: "", conflict: false) }
        let review = OverleafGit.Review(connection: connection, root: root, stage: stage, fingerprint: saved.fingerprint,
                                       remoteHead: saved.remoteHead, transport: transport ?? connection.remote,
                                       changes: changes, localChanges: true, localFiles: base)
        return .init(review: review, files: result, head: saved.head, originalHead: currentHead, recovery: stage, resumed: true)
    }
    private static func validObject(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func invalid() -> OverleafGitSync.ReviewRequired {
        .init("Sync recovery needs review. Your local files and recovery copy are kept.")
    }
    private static func files(_ commit: String, at root: URL, objects: inout [String: Data]) throws -> [String: Data] {
        let listing = try OverleafGit.run(["ls-tree", "-rlz", "--full-tree", commit], at: root).text
        var result: [String: Data] = [:], total = 0, names = Set<String>()
        for row in listing.split(separator: "\0") {
            try Task.checkCancellation()
            let parts = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw invalid() }
            let fields = parts[0].split(separator: " "), path = String(parts[1])
            guard fields.count == 4, ["100644", "100755"].contains(String(fields[0])), fields[1] == "blob", validObject(String(fields[2])),
                  let size = Int(fields[3]), size >= 0 else { throw invalid() }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            guard size <= OverleafSourceFiles.fileLimit, result.count < 10_000, OverleafSourceFiles.validPath(path), result[path] == nil,
                  names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid() }
            total += size
            guard total <= OverleafSourceFiles.byteLimit else { throw invalid() }
            let id = String(fields[2])
            let bytes: Data
            if let known = objects[id] { bytes = known }
            else {
                bytes = try OverleafGit.run(["cat-file", "blob", id], at: root).data
                guard bytes.count == size else { throw invalid() }
                objects[id] = bytes
            }
            guard bytes.count == size else { throw invalid() }
            result[path] = bytes
        }
        return result
    }
    static func finish(_ prepared: OverleafGitSync.Prepared) throws {
        try finishReviewed(prepared.review.connection, root: prepared.review.root, recovery: prepared.recovery.deletingLastPathComponent())
    }
    static func finishReviewed(_ connection: OverleafConnection, root: URL, recovery: URL) throws {
        let url = receipt(connection, recovery: recovery)
        let stage = stage(connection, recovery: recovery)
        let pending = try OverleafGit.run(["rev-parse", "--verify", pendingReference], at: root, allowFailure: true)
        let head = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pending.status == 0, validObject(head) {
            let commands = "start\ncreate " + reference() + " " + head + "\ndelete " + pendingReference + " " + head + "\nprepare\ncommit\n"
            _ = try OverleafGit.run(["update-ref", "--stdin"], at: root, input: Data(commands.utf8))
        }
        // Remove the receipt first: a crash during cleanup leaves only a reproducible preparation.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
        try trimReferences(at: root)
    }
    static func trimReferences(at root: URL) throws {
        let prefix = "refs/remile/git-recovery/"
        let rows = try OverleafGit.run(["for-each-ref", "--format=%(refname) %(objectname)", prefix], at: root).text.split(separator: "\n")
        let references = rows.compactMap { row -> (String, String)? in
            let fields = row.split(separator: " ")
            guard fields.count == 2, fields[0].hasPrefix(prefix), validObject(String(fields[1])) else { return nil }
            // Older unlabelled refs may protect unresolved recovery copies. Never expire them by guessing.
            let suffix = fields[0].dropFirst(prefix.count)
            guard suffix.count == 50, Int64(suffix.prefix(13)) != nil, UUID(uuidString: String(suffix.dropFirst(14))) != nil else { return nil }
            return (String(fields[0]), String(fields[1]))
        }.sorted { left, right in
            func timestamp(_ name: String) -> Int64 { Int64(name.dropFirst(prefix.count).prefix(13)) ?? 0 }
            let a = timestamp(left.0), b = timestamp(right.0)
            return a == b ? left.0 > right.0 : a > b
        }
        let stale = references.dropFirst(retainedReferences)
        guard !stale.isEmpty else { return }
        let commands = "start\n" + stale.map { "delete " + $0.0 + " " + $0.1 + "\n" }.joined() + "prepare\ncommit\n"
        _ = try OverleafGit.run(["update-ref", "--stdin"], at: root, input: Data(commands.utf8))
    }
    static func checkCapacity(root: URL, recovery: URL) throws {
        // Count logical bytes, including private Git files. No file bodies are loaded or cached.
        func size(_ folder: URL, hidden: Bool) throws -> Int {
            guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
            var failure: Error?
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: hidden ? [] : [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw invalid() }
            var total = 0, count = 0
            for case let file as URL in walker {
                try Task.checkCancellation(); count += 1
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, count <= 50_000 else { throw invalid() }
                if values.isRegularFile == true { total += values.fileSize ?? byteLimit }
                if total > byteLimit { break }
            }
            if let failure { throw failure }
            return total
        }
        guard try size(recovery, hidden: true) + size(root, hidden: false) <= byteLimit else {
            throw OverleafGitSync.ReviewRequired("Recovery space is full. Finish or review the pending sync before starting another. Your files are kept.")
        }
    }
}
