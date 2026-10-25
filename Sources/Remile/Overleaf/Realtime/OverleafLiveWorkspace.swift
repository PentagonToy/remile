import Foundation
import SwiftUI
import WebKit

/// Visible-project owner. A failure retains ownership until the user stops live mode.
@MainActor final class OverleafLiveWorkspace: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var syncingFiles = false
    @Published private(set) var recoveryDirectory: URL?
    private let fileSync: OverleafFileSync?
    private var treeDirty = false
    private var restarting = false
    private var lastFileCheck = Date.distantPast
    @Published private(set) var connecting = false
    @Published private(set) var issue: String?
    @Published private(set) var connected = false
    @Published private(set) var requiresGitReview = false
    @Published private(set) var pauseReason = "Disconnected"
    @Published private(set) var lastConfirmedAt: Date?
    private var awaitingConfirmation = true
    /// Count documents with unconfirmed intent, including typing before the next flush.
    var pendingDocumentCount: Int {
        guard let project else { return 0 }
        return states.filter { path, state in
            state.inFlight != nil || (project.buffers[path] ?? state.local) != state.base.text
        }.count
    }
    private func updateConfirmation() {
        guard connected, !connecting, !syncingFiles, !treeDirty, !restarting, conflict == nil, pendingDocumentCount == 0, resolving.isEmpty else { return }
        if awaitingConfirmation || lastConfirmedAt == nil {
            awaitingConfirmation = false; lastConfirmedAt = Date()
            if let connection { library?.markSynced(connection.id) }
        }
    }
    struct Conflict: Identifiable {
        let path: String; let local: String; let remote: OverleafLive.Snapshot
        var id: String { path }
    }
    @Published private(set) var conflict: Conflict?
    private weak var project: TeXProject?
    private weak var library: OverleafLibrary?
    private var connection: OverleafConnection?
    private var socket: (any OverleafLiveChannel)?
    private let authenticate: (UUID) async throws -> Void
    private let makeChannel: (OverleafConnection) -> any OverleafLiveChannel
    private var writer: OverleafLiveWriterLease?
    private var reader: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var states: [String: OverleafLive.State] = [:]
    private var paths: [String: String] = [:]
    private var disk: [String: String] = [:]
    private var sentAt: [String: Date] = [:]
    private var resolving = Set<String>()
    private var revision = 0
    private var generation = UUID()
    private var flushing = false
    private var choices: [String: ConflictChoice] = [:]
    private struct ConflictChoice { let local: String; let remote: OverleafLive.Snapshot; let result: String }
    init(syncFiles: Bool = true, files: OverleafFileSync? = nil, authenticate: @escaping (UUID) async throws -> Void = { try await OverleafLiveWorkspace.savedSession($0) }, makeChannel: @escaping (OverleafConnection) -> any OverleafLiveChannel = { OverleafLiveSocket(project: $0.projectID, profile: $0.profileID) }) {
        self.authenticate = authenticate; self.makeChannel = makeChannel; fileSync = syncFiles ? (files ?? OverleafFileSync()) : nil
    }
    private static func savedSession(_ profile: UUID) async throws {
        _ = try OverleafWebClient.parseProjects(await OverleafWebClient.request("/user/projects", profile: profile))
    }
    func start(project: TeXProject, library: OverleafLibrary, connection: OverleafConnection) async {
        guard !connecting, !connected, !library.busy, library.review == nil else { return }
        self.project = project; self.library = library; self.connection = connection
        let attempt = UUID(); generation = attempt
        connecting = true; enabled = true; issue = nil; conflict = nil; lastConfirmedAt = nil; awaitingConfirmation = true; requiresGitReview = false
        library.liveOwned.insert(connection.id)
        do {
            try NetworkAccess.requireOnline()
            guard !library.offlineMode, library.hasNetwork else { throw NetworkAccessGate.Offline() }
            if writer == nil {
                for index in 0...10 {
                    do { writer = try library.writerLease(connection); break }
                    catch OverleafLive.Failure.writerBusy where index < 10 {
                        try await Task.sleep(for: .milliseconds(150)); try check(attempt)
                    }
                }
            }
            library.liveOwned.insert(connection.id)
            // Verify the web account independently of the Git token.
            try await authenticate(connection.profileID)
            try check(attempt)
            var transport = makeChannel(connection); socket = transport
            var remoteProject = try await transport.connect()
            var fileBases = states.mapValues { $0.base.text }
            if let fileSync {
                syncingFiles = true
                defer { syncingFiles = false }
                for pass in 0..<3 {
                    let tree = try OverleafLiveFiles.tree(remoteProject, project: connection.projectID)
                    let result = try await fileSync.reconcile(project: project, library: library, connection: connection, tree: tree, textBases: fileBases, check: { try self.check(attempt) })
                    fileBases = result.bases; recoveryDirectory = fileSync.recovery
                    if !result.reconnect { break }
                    guard pass < 2 else { throw OverleafLiveFiles.Failure.stale }
                    await transport.stop(); try check(attempt)
                    transport = makeChannel(connection); socket = transport
                    remoteProject = try await transport.connect(); try check(attempt)
                }
            }
            treeDirty = false; lastFileCheck = Date()
            OverleafLiveDiagnostics.note("project-connected")
            try check(attempt)
            let documents = try OverleafLiveWire.documents(remoteProject, expectedID: connection.projectID).filter { project.buffers[$0.path] != nil }
            OverleafLiveDiagnostics.note("project-tree", code: documents.count)
            guard !documents.isEmpty, documents.count <= 1_000 else { throw OverleafLiveWire.Failure.changedTree }
            revision = project.fileRevision; states = [:]; paths = [:]; disk = [:]; sentAt = [:]; resolving = []
            let importedBase = connection.liveOnly == true && fileSync == nil ? try OverleafSourceArchive.sources(from: OverleafSourceArchive.baseline(connection.id, under: library.directory)) : nil
            for doc in documents {
                try check(attempt)
                let key = OverleafLive.Key(profile: connection.profileID, project: connection.projectID, document: doc.id)
                paths[doc.id] = doc.path
                let localDisk = try readDisk(doc.path); disk[doc.path] = localDisk
                let remote = try await transport.join(doc.id)
                OverleafLiveDiagnostics.note("document-joined")
                try check(attempt)
                guard let local = project.buffers[doc.path] else { throw OverleafLiveWire.Failure.changedTree }
                let file = OverleafLiveJournal.checkpoint(for: key, under: journalDirectory)
                let saved = FileManager.default.fileExists(atPath: file.path) ? try OverleafLiveJournal.load(from: file, for: key) : nil
                let reviewFile = file.appendingPathExtension("review")
                let base: String
                if let saved { base = saved.base.text }
                else if let original = fileBases[doc.path] { base = original }
                else if connection.liveOnly == true {
                    guard let original = importedBase?[doc.path] else { throw OverleafSourceArchive.Failure.baseline }
                    base = original
                } else {
                    let root = project.root
                    let bytes = try await Task.detached { try OverleafGit.run(["show", "HEAD:" + doc.path], at: root).data }.value
                    guard let text = String(data: bytes, encoding: .utf8) else { throw OverleafLiveWire.Failure.changedTree }
                    base = text
                }
                try check(attempt)
                guard project.buffers[doc.path] == local else { throw OverleafLive.Failure.staleDraft }
                var state = try OverleafLive.State(key: key, base: remote, local: local)
                try state.resume(remote, epoch: state.epoch)
                do {
                    let merged: String
                    if let choice = choices[doc.path], choice.local == local, choice.remote == remote {
                        merged = choice.result
                        try OverleafLive.validate(merged)
                    } else if FileManager.default.fileExists(atPath: reviewFile.path), local != remote.text {
                        throw OverleafLiveWire.Failure.conflict
                    } else if let pending = saved?.inFlight {
                        guard remote.text == pending.after || remote.text == local else { throw OverleafLiveWire.Failure.uncertain }
                        merged = try OverleafLiveText.merge(base: pending.after, local: local, remote: remote.text)
                    } else { merged = try OverleafLiveText.merge(base: base, local: local, remote: remote.text) }
                    try state.edited(merged); try install(doc.path, next: state, expected: local)
                    if FileManager.default.fileExists(atPath: reviewFile.path) { try FileManager.default.removeItem(at: reviewFile) }
                } catch {
                    states[doc.path] = state
                    try preserveConflict(path: doc.path, local: local, remote: remote, error: error)
                    throw error
                }
            }
            choices = [:]; connecting = false; connected = true
            reader = Task { [weak self] in
                for await event in transport.events {
                    guard let self, self.generation == attempt, !Task.isCancelled else { return }
                    do { try await self.receive(event, attempt: attempt) }
                    catch { await self.pause(error, attempt: attempt); return }
                }
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                await self.pause(OverleafLiveWire.Failure.disconnected, attempt: attempt)
            }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, self.generation == attempt else { return }
                    await self.flush()
                }
            }
            await flush()
        } catch { await pause(error, attempt: attempt) }
    }
    func flush() async {
        guard connected, !connecting, !flushing, let project, let socket else { return }
        flushing = true; defer { flushing = false; updateConfirmation() }
        let attempt = generation
        do {
            try check(attempt)
            if fileSync != nil {
                if states.keys.contains(where: { !FileManager.default.fileExists(atPath: project.root.appendingPathComponent($0).path) }) { treeDirty = true }
                if Date().timeIntervalSince(lastFileCheck) >= 2 {
                    lastFileCheck = Date()
                    let changed = try await fileSync!.changed(project); try check(attempt)
                    if changed { treeDirty = true }
                }
                if project.fileRevision != revision || treeDirty {
                    awaitingConfirmation = true
                    if sentAt.values.contains(where: { Date().timeIntervalSince($0) > 20 }) { throw OverleafLiveWire.Failure.uncertain }
                    guard !restarting, !project.compiling, states.values.allSatisfy({ $0.inFlight == nil }) else { return }
                    restarting = true
                    Task { [weak self] in guard let self else { return }; await self.retry(); self.restarting = false }
                    return
                }
            } else { guard project.fileRevision == revision else { throw OverleafLiveWire.Failure.changedTree } }
            for path in states.keys.sorted() {
                guard !resolving.contains(path), var state = states[path], let local = project.buffers[path] else { continue }
                let actualDisk = try readDisk(path)
                if actualDisk != disk[path], actualDisk != local {
                    guard local == disk[path] else { throw OverleafLive.Failure.staleDraft }
                    project.buffers[path] = actualDisk; disk[path] = actualDisk
                }
                let current = project.buffers[path]!
                try state.edited(current)
                if let sent = sentAt[path], Date().timeIntervalSince(sent) > 20 { throw OverleafLiveWire.Failure.timeout }
                let op = try state.submission()
                if op != nil || states[path]?.local != current || disk[path] != current { try install(path, next: state, expected: current) }
                if let op {
                    sentAt[path] = Date()
                    try await socket.submit(op); try check(attempt)
                }
            }
        } catch { await pause(error, attempt: attempt) }
    }
    func retry() async {
        guard let project, let library, let connection else { return }
        await pause(nil, attempt: generation)
        await start(project: project, library: library, connection: connection)
    }
    func choose(_ keepLocal: Bool) async {
        guard let conflict else { return }
        await choose(text: keepLocal ? conflict.local : conflict.remote.text)
    }
    func choose(text: String) async {
        guard let conflict, (try? OverleafLive.validate(text)) != nil else { return }
        choices[conflict.path] = ConflictChoice(local: conflict.local, remote: conflict.remote, result: text)
        await retry()
    }
    func reviewGit() async {
        guard requiresGitReview, let project, let library, let connection, library.allowsGit(connection) else { return }
        await stop()
        await library.check(connection, save: project.save)
    }
    func stop() async {
        await pause(nil, attempt: generation)
        enabled = false; issue = nil; conflict = nil
        if let connection, let library {
            library.automaticPaused.insert(connection.id); library.statuses[connection.id] = .changes
            library.liveOwned.remove(connection.id)
        }
        writer = nil
    }
    func suspend() async { if enabled { await pause(NetworkAccessGate.Offline(), attempt: generation) } }
    private var journalDirectory: URL { library!.directory.appendingPathComponent("Live") }
    private func check(_ attempt: UUID) throws {
        try Task.checkCancellation(); try NetworkAccess.requireOnline()
        guard attempt == generation, enabled, library?.offlineMode == false, library?.hasNetwork == true else { throw CancellationError() }
    }
    private func readDisk(_ path: String) throws -> String {
        guard let root = project?.root else { throw OverleafLive.Failure.staleDraft }
        let url = root.appendingPathComponent(path), canonical = url.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), canonical == url.standardizedFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile == true,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= OverleafLive.textLimit else { throw OverleafLive.Failure.staleDraft }
        let value = try String(contentsOf: url, encoding: .utf8); try OverleafLive.validate(value); return value
    }
    private func install(_ path: String, next: OverleafLive.State, expected: String) throws {
        guard let project, let expectedDisk = disk[path] else { throw OverleafLive.Failure.staleDraft }
        try OverleafLiveJournal.save(next.checkpoint, to: OverleafLiveJournal.checkpoint(for: next.key, under: journalDirectory))
        try project.installLiveSource(path, expected: expected, text: next.local, expectedDisk: expectedDisk)
        objectWillChange.send()
        disk[path] = next.local; states[path] = next
        if next.inFlight != nil || next.local != next.base.text { awaitingConfirmation = true }
    }
    private func preserveConflict(path: String, local: String, remote: OverleafLive.Snapshot, error: Error) throws {
        guard var state = states[path] else { throw error }
        try state.edited(local)
        // Keep both sides privately, even if the current file or app is subsequently closed.
        let folder = journalDirectory.appendingPathComponent("Reviews/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, text) in [("local.txt", local), ("remote.txt", remote.text)] {
            let file = folder.appendingPathComponent(name); try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try OverleafLiveJournal.save(state.checkpoint, to: OverleafLiveJournal.checkpoint(for: state.key, under: journalDirectory))
        let marker = OverleafLiveJournal.checkpoint(for: state.key, under: journalDirectory).appendingPathExtension("review")
        try Data("Review required before uploading this document.\n".utf8).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        conflict = Conflict(path: path, local: local, remote: remote)
    }
    private func receive(_ event: OverleafLiveSocket.Event, attempt: UUID) async throws {
        try check(attempt)
        if event.name == "remileDisconnected" { throw OverleafLiveWire.Failure.disconnected }
        if ["reciveNewDoc", "reciveNewFile", "removeEntity", "renameEntity", "moveEntity", "reciveEntityRename", "reciveEntityMove", "reciveNewFolder"].contains(event.name) {
            if fileSync != nil { treeDirty = true; awaitingConfirmation = true; return }
            throw OverleafLiveWire.Failure.changedTree
        }
        guard event.name == "otUpdateApplied", let update = event.args.first, let doc = update["doc"].string,
              let path = paths[doc], var state = states[path], let project, let local = project.buffers[path],
              let version = update["v"].integer, version >= 0, version < Int.max else { return }
        try state.edited(local)
        if let ops = update["op"].array, !ops.isEmpty {
            if version < state.base.version { return }
            if state.inFlight != nil { return } // After our acknowledgement, a fresh join includes all transformed ops.
            if version != state.base.version { try await refresh(path, attempt: attempt); return }
            let remote = OverleafLive.Snapshot(version: version + 1, text: try OverleafLiveText.applying(ops, to: state.base.text))
            try accept(remote, path: path, state: state, mergeBase: state.base.text)
        } else {
            guard let pending = state.inFlight, version >= pending.baseVersion else { return }
            // Always rejoin after durable ACK: the server may have transformed our operation.
            try await refresh(path, attempt: attempt, acknowledged: pending)
        }
    }
    private func refresh(_ path: String, attempt: UUID, acknowledged: OverleafLive.Submission? = nil) async throws {
        guard let socket, let state = states[path] else { throw OverleafLiveWire.Failure.disconnected }
        resolving.insert(path); defer { resolving.remove(path); updateConfirmation() }
        try await socket.leave(state.key.document)
        let remote = try await socket.join(state.key.document)
        try check(attempt)
        guard let latest = states[path] else { throw OverleafLive.Failure.staleDraft }
        guard remote.version >= latest.base.version, acknowledged == nil || remote.version > acknowledged!.baseVersion else { throw OverleafLive.Failure.staleSnapshot }
        try accept(remote, path: path, state: latest, mergeBase: acknowledged?.after ?? latest.base.text)
        sentAt[path] = nil
    }
    private func accept(_ remote: OverleafLive.Snapshot, path: String, state: OverleafLive.State, mergeBase: String) throws {
        guard let local = project?.buffers[path] else { throw OverleafLive.Failure.staleDraft }
        do {
            let merged = try OverleafLiveText.merge(base: mergeBase, local: local, remote: remote.text)
            var next = try OverleafLive.State(key: state.key, base: remote, local: merged)
            try next.resume(remote, epoch: next.epoch)
            try install(path, next: next, expected: local)
            awaitingConfirmation = true; updateConfirmation()
        } catch { try preserveConflict(path: path, local: local, remote: remote, error: error); throw error }
    }
    private func pause(_ error: Error?, attempt: UUID) async {
        guard generation == attempt else { return }; generation = UUID()
        fileSync?.cancel()
        connected = false; connecting = false; syncingFiles = false
        reader?.cancel(); ticker?.cancel(); reader = nil; ticker = nil
        let previous = socket; socket = nil
        if let error {
            issue = error.localizedDescription
            recoveryDirectory = fileSync?.recovery
            if let failure = error as? OverleafLiveFiles.Failure, case .stale = failure {
                pauseReason = "Files changed · reconnect"; requiresGitReview = false
            }
            else if error is OverleafLiveFiles.Failure {
                recoveryDirectory = fileSync?.recovery; pauseReason = "File review required"
                requiresGitReview = connection.map { library?.allowsGit($0) == true } ?? false
            }
            else if error is OverleafGit.Failure {
                pauseReason = "Git review required"
                requiresGitReview = connection.map { library?.allowsGit($0) == true } ?? false
            }
            else if let failure = error as? OverleafLive.Failure, case .writerBusy = failure {
                pauseReason = "Project already syncing"
                issue = "This project is syncing in another window. Stop that connection and reconnect here."
            }
            else if error is NetworkAccessGate.Offline { pauseReason = "Offline" }
            else if let failure = error as? OverleafWebClient.Failure {
                switch failure {
                case .sessionLocked: pauseReason = "Connection locked"
                case .signIn: pauseReason = "Sign in required"
                case .verification: pauseReason = "Browser verification required"
                case .permission: pauseReason = "Access not permitted"
                case .rateLimited: pauseReason = "Too many requests"
                case .unavailable, .response: pauseReason = "Overleaf unavailable"
                }
            }
            else if let failure = error as? OverleafLiveWire.Failure {
                switch failure {
                case .uncertain: pauseReason = "Upload unconfirmed"
                case .conflict: pauseReason = "Review required"
                case .changedTree:
                    pauseReason = "Project files changed"; requiresGitReview = true
                    if connection?.liveOnly == true { issue = "Project files changed. Your edits are saved locally. Export your work before importing a fresh project copy." }
                case .authentication: pauseReason = "Sign in required"
                case .permission: pauseReason = "Editing not permitted"
                case .timeout: pauseReason = "Confirmation timed out"
                default: pauseReason = "Disconnected"
                }
            } else { pauseReason = "Connection interrupted" }
        }
        await previous?.stop()
    }
}
