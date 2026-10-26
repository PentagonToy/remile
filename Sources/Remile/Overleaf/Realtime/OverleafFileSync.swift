import Foundation
import AppKit
import Combine

@MainActor protocol OverleafFileRemote: AnyObject {
    func snapshot(_ tree: OverleafLiveFiles.Tree?) async throws -> OverleafFileSnapshot
    func upload(_ bytes: Data, path: String, root: String) async throws -> OverleafLiveFiles.Entry
    func rename(_ entry: OverleafLiveFiles.Entry, name: String) async throws
    func delete(_ entry: OverleafLiveFiles.Entry) async throws
    func close()
}
struct OverleafFileSnapshot: Sendable { let tree: OverleafLiveFiles.Tree; let files: [String: Data] }

@MainActor final class OverleafWebFiles: OverleafFileRemote {
    private let connection: OverleafConnection
    private let service: OverleafFileService
    private var opened = false
    init(_ connection: OverleafConnection) { self.connection = connection; service = OverleafFileService(connection) }
    private func tree() async throws -> OverleafLiveFiles.Tree {
        let socket = OverleafLiveSocket(project: connection.projectID, profile: connection.profileID)
        do {
            let value = try await socket.connect(); await socket.stop()
            return try OverleafLiveFiles.tree(value, project: connection.projectID)
        } catch { await socket.stop(); throw error }
    }
    func snapshot(_ advertised: OverleafLiveFiles.Tree?) async throws -> OverleafFileSnapshot {
        var before: OverleafLiveFiles.Tree
        if let advertised { before = advertised } else { before = try await tree() }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let bytes = try await OverleafSourceDownload(project: connection.projectID, profile: connection.profileID).load()
            let after = try await tree()
            if before == after {
                do { return OverleafFileSnapshot(tree: after, files: try OverleafLiveFiles.archive(bytes, tree: after)) }
                catch OverleafLiveFiles.Failure.stale where attempt < 2 { }
            }
            before = after
        }
        throw OverleafLiveFiles.Failure.stale
    }
    private func open() async throws { if !opened { try await service.open(); opened = true } }
    func upload(_ bytes: Data, path: String, root: String) async throws -> OverleafLiveFiles.Entry { try await open(); return try await service.upload(bytes, path: path, root: root) }
    func rename(_ entry: OverleafLiveFiles.Entry, name: String) async throws { try await open(); try await service.rename(entry, name: name) }
    func delete(_ entry: OverleafLiveFiles.Entry) async throws { try await open(); try await service.delete(entry) }
    func close() { service.close(); opened = false }
}

/// A durable baseline and recovery copies bracket every structural or binary operation.
@MainActor final class OverleafFileSync {
    private let makeRemote: @MainActor (OverleafConnection) -> any OverleafFileRemote
    private(set) var assetFingerprint: String?
    private(set) var recovery: URL?
    private var gitJob: Task<Void, Error>?
    func cancel() { gitJob?.cancel() }
    init(makeRemote: @escaping @MainActor (OverleafConnection) -> any OverleafFileRemote = { OverleafWebFiles($0) }) { self.makeRemote = makeRemote }
    private struct Operation: Codable {
        let path: String
        let stage: String?
        let parked: String?
        let original: Data?
        let desired: Data?
    }
    private struct Intent: Codable { let operations: [Operation] }
    struct Result { let reconnect: Bool; let bases: [String: String] }
    static func baseline(_ connection: OverleafConnection, library: URL) -> URL { library.appendingPathComponent("LiveFiles/" + connection.id.uuidString + "/baseline.json") }
    func changed(_ project: TeXProject) async throws -> Bool {
        guard let assetFingerprint else { return false }
        let root = project.root
        let scan = Task.detached(priority: .utility) { try OverleafLiveFiles.fingerprintAssets(at: root) }
        let current = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        return current != assetFingerprint
    }
    func reconcile(project: TeXProject, library: OverleafLibrary, connection: OverleafConnection, tree: OverleafLiveFiles.Tree, textBases: [String: String], check: () throws -> Void) async throws -> Result {
        try check()
        guard project.save() else { throw OverleafLiveFiles.Failure.stale }
        let local = try OverleafLiveFiles.scan(project.root, buffers: project.buffers)
        let baseline = Self.baseline(connection, library: library.directory)
        var base = try initialBase(connection, library: library.directory, root: project.root, file: baseline)
        for (path, text) in textBases { base[path] = Data(text.utf8) }
        // The per-document journal remains the authoritative base for existing OT documents.
        let remote = makeRemote(connection); defer { remote.close() }
        let before = try await remote.snapshot(tree); try check()
        let intentFile = baseline.deletingLastPathComponent().appendingPathComponent("pending.json")
        if FileManager.default.fileExists(atPath: intentFile.path) {
            try preserve(local: local, remote: before.files, connection: connection, library: library)
            try await recover(intentFile, snapshot: before, remote: remote, check: check)
            return Result(reconnect: true, bases: textBases)
        }
        var joined = Set<String>()
        for (path, entry) in tree.files where entry.kind == "doc" && OverleafLiveFiles.source(path) && local[path] != nil {
            if let known = base[path], let source = String(data: known, encoding: .utf8) {
                let key = OverleafLive.Key(profile: connection.profileID, project: connection.projectID, document: entry.id)
                let journal = OverleafLiveJournal.checkpoint(for: key, under: library.directory.appendingPathComponent("Live"))
                if FileManager.default.fileExists(atPath: journal.path), let saved = try? OverleafLiveJournal.load(from: journal, for: key) { base[path] = Data(saved.base.text.utf8) }
                else { base[path] = Data(source.utf8) }
                joined.insert(path)
            }
        }
        let plan: OverleafLiveFiles.Plan
        do { plan = try OverleafLiveFiles.plan(base: base, local: local, remote: before.files, joinedText: joined) }
        catch { try preserve(local: local, remote: before.files, connection: connection, library: library); throw error }
        var bases = base.compactMapValues { String(data: $0, encoding: .utf8) }
        guard plan.changes else {
            try check(); guard try OverleafLiveFiles.scan(project.root, buffers: project.buffers) == local else { throw OverleafLiveFiles.Failure.stale }
            try OverleafLiveFiles.save(before.files, to: baseline)
            assetFingerprint = OverleafLiveFiles.fingerprint(local, assetsOnly: true)
            return Result(reconnect: before.tree != tree, bases: bases)
        }
        // A preview compiles a private source snapshot. An unchanged manifest
        // can join Live immediately. Wait only before changing actual files.
        if project.compiling {
            for await compiling in project.$compiling.values {
                try check()
                if !compiling { break }
            }
            try check()
        }
        try preserve(local: local, remote: before.files, connection: connection, library: library)
        if library.allowsGit(connection) { try await gitRecovery(connection: connection, root: project.root) }
        try check(); guard try OverleafLiveFiles.scan(project.root, buffers: project.buffers) == local else { throw OverleafLiveFiles.Failure.stale }
        // Unique staging names avoid the upload endpoint's unconditional same-name replacement.
        // Existing entities are renamed to recovery names before their visible path is changed.
        var parked: [OverleafLiveFiles.Entry] = []
        let nonce = UUID().uuidString.lowercased()
        guard let root = tree.folders[""] else { throw OverleafLiveFiles.Failure.invalid }
        func relative(_ name: String, path: String) -> String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? name : parent + "/" + name
        }
        let useGit = (!plan.uploads.isEmpty || !plan.deletions.isEmpty) && library.allowsGit(connection) && OverleafCredential.availability(connection.profileID) == .available
        if useGit {
            guard let recovery else { throw OverleafLiveFiles.Failure.invalid }
            let root = project.root
            let job = Task.detached { try OverleafGitLiveFiles.publish(plan, connection: connection, root: root, recovery: recovery, beforePush: { try Task.checkCancellation() }) }
            gitJob = job
            do { try await job.value; gitJob = nil }
            catch { gitJob = nil; throw error }
            try check()
        } else {
            var intent: [Operation] = []
            for (index, path) in plan.uploads.enumerated() {
                let ext = (path as NSString).pathExtension
                let suffix = "-\(index)" + (ext.isEmpty ? "" : "." + ext)
                intent.append(Operation(path: path, stage: relative("remile-stage-" + nonce + suffix, path: path), parked: before.files[path] == nil ? nil : relative("remile-recovery-" + nonce + suffix, path: path), original: before.files[path], desired: plan.result[path]))
            }
            for (index, path) in plan.deletions.enumerated() {
                let ext = (path as NSString).pathExtension
                intent.append(Operation(path: path, stage: nil, parked: relative("remile-deleted-" + nonce + "-\(index)" + (ext.isEmpty ? "" : "." + ext), path: path), original: before.files[path], desired: nil))
            }
            try JSONEncoder().encode(Intent(operations: intent)).write(to: intentFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: intentFile.path)
            for (index, path) in plan.uploads.enumerated() {
                try check()
                let parent = (path as NSString).deletingLastPathComponent
                let ext = (path as NSString).pathExtension
                let name = "remile-stage-" + nonce + "-\(index)" + (ext.isEmpty ? "" : "." + ext)
                let temporary = parent.isEmpty ? name : parent + "/" + name
                let staged = try await remote.upload(plan.result[path]!, path: temporary, root: root)
                try check()
                if let existing = before.tree.files[path] {
                    let recoveryName = "remile-recovery-" + nonce + "-\(index)" + (ext.isEmpty ? "" : "." + ext)
                    try await remote.rename(existing, name: recoveryName)
                    parked.append(.init(id: existing.id, kind: existing.kind, path: parent.isEmpty ? recoveryName : parent + "/" + recoveryName))
                }
                try check(); try await remote.rename(staged, name: (path as NSString).lastPathComponent)
            }
            for (index, path) in plan.deletions.enumerated() {
                try check()
                guard let existing = before.tree.files[path] else { throw OverleafLiveFiles.Failure.stale }
                let parent = (path as NSString).deletingLastPathComponent, ext = (path as NSString).pathExtension
                let name = "remile-deleted-" + nonce + "-\(index)" + (ext.isEmpty ? "" : "." + ext)
                try await remote.rename(existing, name: name)
                parked.append(.init(id: existing.id, kind: existing.kind, path: parent.isEmpty ? name : parent + "/" + name))
            }
        }
        var after = before
        if !plan.uploads.isEmpty || !plan.deletions.isEmpty {
            after = try await remote.snapshot(nil); try check()
            // Save the parked bytes again: they can include an edit that raced the preflight.
            if let recovery { try OverleafLiveFiles.save(after.files, to: recovery.appendingPathComponent("after-remote.json")); try materialise(after.files, at: recovery.appendingPathComponent("After")) }
            for path in plan.uploads { guard after.files[path] == plan.result[path] else { throw OverleafLiveFiles.Failure.uncertain } }
            for path in plan.deletions { guard after.files[path] == nil else { throw OverleafLiveFiles.Failure.uncertain } }
            for entry in parked {
                guard after.tree.files[entry.path]?.id == entry.id else { throw OverleafLiveFiles.Failure.stale }
                let original = before.tree.files.first { $0.value.id == entry.id }?.key
                // A racing edit is kept remotely and locally, never silently discarded.
                guard let original, after.files[entry.path] == before.files[original] else { throw OverleafLiveFiles.Failure.conflict(original ?? entry.path) }
            }
        }
        try check()
        let touched = Set(plan.uploads + plan.deletions + parked.map(\.path))
        for path in Set(before.files.keys).union(after.files.keys).subtracting(touched) {
            if before.tree.files[path]?.kind == "doc", joined.contains(path), after.files[path] != nil { continue }
            guard before.files[path] == after.files[path] else { throw OverleafLiveFiles.Failure.stale }
        }
        guard try OverleafLiveFiles.scan(project.root, buffers: project.buffers) == local else { throw OverleafLiveFiles.Failure.stale }
        try project.installLiveFiles(expected: local, result: plan.result, paths: Set(plan.downloads + plan.removals))
        // Advance the manifest before cleanup. A lost cleanup response must not replay uploads.
        var confirmed = after.files
        for entry in parked { confirmed[entry.path] = nil }
        try OverleafLiveFiles.save(confirmed, to: baseline)
        for path in plan.downloads + plan.uploads where OverleafLiveFiles.source(path) { bases[path] = confirmed[path].flatMap { String(data: $0, encoding: .utf8) } }
        assetFingerprint = try OverleafLiveFiles.fingerprintAssets(at: project.root)
        for entry in parked { try check(); try await remote.delete(entry) }
        if FileManager.default.fileExists(atPath: intentFile.path) { try FileManager.default.removeItem(at: intentFile) }
        if let recovery { try Data("Confirmed. Recovery copies are retained locally.\n".utf8).write(to: recovery.appendingPathComponent("confirmed.txt"), options: .atomic) }
        return Result(reconnect: !plan.uploads.isEmpty || !plan.deletions.isEmpty, bases: bases)
    }
    /// Reconcile a lost reply against named staged entities before allowing any new transaction.
    private func recover(_ file: URL, snapshot: OverleafFileSnapshot, remote: any OverleafFileRemote, check: () throws -> Void) async throws {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OverleafLiveFiles.byteLimit * 3 else { throw OverleafLiveFiles.Failure.invalid }
        let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: file))
        for op in intent.operations {
            try check()
            guard OverleafLiveFiles.validPath(op.path), [op.stage, op.parked].compactMap({ $0 }).allSatisfy(OverleafLiveFiles.validPath) else { throw OverleafLiveFiles.Failure.invalid }
            let current = snapshot.files[op.path]
            let stage = op.stage.flatMap { snapshot.tree.files[$0] }
            let parked = op.parked.flatMap { snapshot.tree.files[$0] }
            if let stage { guard snapshot.files[stage.path] == op.desired else { throw OverleafLiveFiles.Failure.conflict(op.path) } }
            if let parked {
                guard snapshot.files[parked.path] == op.original else { throw OverleafLiveFiles.Failure.conflict(op.path) }
                if current == op.desired {
                    try await remote.delete(parked)
                } else if current == nil, op.desired != nil, stage != nil {
                    // The old entity was parked but the final rename never completed. Restore it.
                    try await remote.rename(parked, name: (op.path as NSString).lastPathComponent)
                } else { throw OverleafLiveFiles.Failure.conflict(op.path) }
            } else if current != op.original && current != op.desired { throw OverleafLiveFiles.Failure.conflict(op.path) }
            if let stage { try check(); try await remote.delete(stage) }
        }
        try check(); try FileManager.default.removeItem(at: file)
    }
    private func initialBase(_ connection: OverleafConnection, library: URL, root: URL, file: URL) throws -> [String: Data] {
        if FileManager.default.fileExists(atPath: file.path) { return try OverleafLiveFiles.load(file) }
        if connection.liveOnly == true { return try OverleafSourceArchive.sources(from: OverleafSourceArchive.baseline(connection.id, under: library)).mapValues { Data($0.utf8) } }
        var result: [String: Data] = [:], count = 0
        let paths = try OverleafGit.run(["ls-tree", "-rz", "--name-only", "HEAD"], at: root).text.split(separator: "\0").map(String.init)
        for path in paths where OverleafLiveFiles.validPath(path) {
            let bytes = try OverleafGit.run(["show", "HEAD:" + path], at: root).data
            count += bytes.count; guard count <= OverleafLiveFiles.byteLimit, bytes.count <= OverleafLiveFiles.fileLimit else { throw OverleafLiveFiles.Failure.invalid }
            result[path] = bytes
        }
        return result
    }
    private func materialise(_ files: [String: Data], at root: URL) throws {
        for (path, bytes) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }
    private func preserve(local: [String: Data], remote: [String: Data], connection: OverleafConnection, library: OverleafLibrary) throws {
        let folder = library.directory.appendingPathComponent("LiveFiles/" + connection.id.uuidString + "/Recovery/" + UUID().uuidString)
        recovery = folder
        try OverleafLiveFiles.save(local, to: folder.appendingPathComponent("local.json"))
        try OverleafLiveFiles.save(remote, to: folder.appendingPathComponent("remote.json"))
        try materialise(local, at: folder.appendingPathComponent("Local"))
        try materialise(remote, at: folder.appendingPathComponent("Overleaf"))
    }
    private func gitRecovery(connection: OverleafConnection, root: URL) async throws {
        guard let recovery else { return }
        try await Task.detached {
            // A private index and ref preserve the worktree without moving HEAD or the user's index.
            let index = recovery.appendingPathComponent("git-index")
            _ = try OverleafGit.run(["read-tree", "HEAD"], at: root, index: index)
            _ = try OverleafGit.run(["add", "--all", "--", "."], at: root, index: index)
            let tree = try OverleafGit.run(["write-tree"], at: root, index: index).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = try OverleafGit.run(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = try OverleafGit.run(["commit-tree", tree, "-p", head, "-m", "remile. Live file recovery"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = "refs/remile/live-recovery/" + UUID().uuidString.lowercased()
            _ = try OverleafGit.run(["update-ref", ref, commit], at: root)
            try Data((ref + "\n" + commit + "\n").utf8).write(to: recovery.appendingPathComponent("git-recovery.txt"), options: .atomic)
        }.value
    }
}
