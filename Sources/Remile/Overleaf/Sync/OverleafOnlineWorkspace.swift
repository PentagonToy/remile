import Foundation
import SwiftUI

/// One visible-project Git writer with bounded foreground and collaboration checks.
@MainActor final class OverleafOnlineWorkspace: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var reconnecting = false
    @Published private(set) var syncingFiles = false
    @Published private(set) var reviewing = false
    private let transport: String?
    init(transport: String? = nil) { self.transport = transport }
    @Published private(set) var recoveryDirectory: URL?
    @Published private(set) var issue: String?
    @Published private(set) var requiresGitReview = false
    @Published private(set) var pauseReason = "Saved locally"
    @Published private(set) var lastConfirmedAt: Date?
    private weak var project: TeXProject?
    private weak var library: OverleafLibrary?
    private var connection: OverleafConnection?
    private var ticker: Task<Void, Never>?
    private var visible = true
    private var generation = UUID()
    private var lastEdit = Date.distantPast
    private var firstEdit: Date?
    private var nextCheck = Date.distantPast
    private var failures = 0
    private var unchangedChecks = 0
    private var collaborationUntil = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var gitChecks = 0
    private var confirmedRevision = -1
    private var confirmedFileRevision = -1
    var pendingDocumentCount: Int { project.map { $0.editRevision != confirmedRevision || $0.fileRevision != confirmedFileRevision || $0.dirty ? 1 : 0 } ?? 0 }
    var automationStatus: [String: Any] {
        let pending = pendingDocumentCount
        return ["transport": "git", "mode": enabled ? "online" : "on-device", "enabled": enabled, "connected": connected, "connecting": connecting,
         "reconnecting": reconnecting, "pendingDocuments": pending,
         "syncingFiles": syncingFiles, "confirmed": connected && !syncingFiles && pending == 0 && issue == nil,
         "lastConfirmedAt": lastConfirmedAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
         "reviewRequired": requiresGitReview, "issue": issue as Any? ?? NSNull(),
         "gitChecks": gitChecks, "nextCheckAt": nextCheck.timeIntervalSince1970]
    }
    func connectVisible(project: TeXProject, library: OverleafLibrary, connection: OverleafConnection) {
        self.project = project; self.library = library; self.connection = connection
        visible = true; enabled = true
        foregrounded()
    }
    func start(project: TeXProject, library: OverleafLibrary, connection: OverleafConnection) async {
        connectVisible(project: project, library: library, connection: connection)
        nextCheck = .distantPast
    }
    func edited() {
        guard pendingDocumentCount > 0 else { return }
        lastEdit = Date(); if firstEdit == nil { firstEdit = lastEdit }
        objectWillChange.send()
        if !connecting { wake() }
    }
    func setVisible(_ value: Bool) {
        visible = value
        if value { foregrounded() }
        else { ticker?.cancel(); ticker = nil }
    }
    func foregrounded() {
        guard visible, enabled else { return }
        if connecting { startTicker(); return }
        if failures == 0 {
            let now = Date()
            collaborationUntil = now.addingTimeInterval(120)
            nextCheck = min(nextCheck, Self.foregroundDeadline(now: now, attempt: lastAttempt))
        }
        wake()
    }
    static func foregroundDeadline(now: Date, attempt: Date) -> Date {
        max(now, attempt.addingTimeInterval(15))
    }
    static func remoteDelay(unchangedChecks: Int, activeUntil: Date, now: Date) -> TimeInterval {
        now < activeUntil ? 15 : idleDelay(unchangedChecks: unchangedChecks)
    }
    private func startTicker() {
        guard visible, enabled, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.flush()
                guard let delay = self?.nextDelay() else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    private func wake() { ticker?.cancel(); ticker = nil; startTicker() }
    static func idleDelay(unchangedChecks: Int) -> TimeInterval {
        min(300, 60 * pow(2, Double(max(0, min(unchangedChecks - 1, 3)))))
    }
    static func editDeadline(first: Date, last: Date, attempt: Date) -> Date {
        max(min(last.addingTimeInterval(5), first.addingTimeInterval(20)), attempt.addingTimeInterval(15))
    }
    private func nextDelay() -> TimeInterval {
        guard !requiresGitReview, library?.offlineMode == false, !NetworkAccess.offline, library?.hasNetwork == true else { return 300 }
        if library?.busy == true || library?.review != nil { return 15 }
        let deadline: Date
        if let firstEdit {
            let edit = Self.editDeadline(first: firstEdit, last: lastEdit, attempt: lastAttempt)
            deadline = failures == 0 ? edit : max(edit, nextCheck)
        } else { deadline = nextCheck }
        return max(1, deadline.timeIntervalSinceNow)
    }
    func retry() async {
        while connecting && enabled {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard enabled, !reviewing else { return }
        requiresGitReview = false; issue = nil; nextCheck = .distantPast; failures = 0
        await flush(force: true)
        wake()
    }
    func flush() async { await flush(force: false) }
    private func flush(force: Bool) async {
        guard enabled, visible, !connecting, !requiresGitReview, (!reviewing || force), let project, let library, let connection else { return }
        guard !library.offlineMode, !NetworkAccess.offline, library.hasNetwork else {
            connected = false; reconnecting = true; pauseReason = "Saved locally · offline"; return
        }
        guard library.allowsGit(connection) else {
            issue = "This local copy needs a Git connection. Add its project link with a Git token; the existing files are kept."
            pauseReason = "Git connection needed"; requiresGitReview = true; return
        }
        guard !library.busy, library.review == nil else { return }
        let now = Date()
        let editing = firstEdit != nil
        let ready = editing && now >= Self.editDeadline(first: firstEdit!, last: lastEdit, attempt: lastAttempt)
        guard force || (now >= nextCheck && (!editing || ready)) || (ready && failures == 0) else { return }
        let epoch = generation
        connecting = true; syncingFiles = true
        lastAttempt = now
        library.liveOwned.insert(connection.id)
        defer { connecting = false; syncingFiles = false; library.liveOwned.remove(connection.id) }
        do {
            let lease = try library.writerLease(connection)
            defer { withExtendedLifetime(lease) {} }
            guard project.save() else { throw OverleafGit.Failure("Save the project before syncing.") }
            let root = project.root, folder = library.directory.appendingPathComponent("GitSyncRecovery")
            recoveryDirectory = folder
            let revision = project.editRevision, fileRevision = project.fileRevision
            let transport = self.transport
            gitChecks += 1
            let outcome = try await Self.background { try OverleafGitSync.synchronise(connection, root: root, recovery: folder, transport: transport) }
            try active(epoch)
            let prepared = outcome.prepared
            if prepared.review.changes.isEmpty && !prepared.resumed {
                connected = true; reconnecting = false; issue = nil
                lastConfirmedAt = Date(); confirmedRevision = revision; confirmedFileRevision = fileRevision; library.markSynced(connection.id)
                if pendingDocumentCount == 0 { firstEdit = nil }
                let now = Date()
                if prepared.review.remoteHead != prepared.originalHead { collaborationUntil = now.addingTimeInterval(120) }
                unchangedChecks = now < collaborationUntil ? 0 : unchangedChecks + 1
                failures = 0
                nextCheck = now.addingTimeInterval(Self.remoteDelay(unchangedChecks: unchangedChecks, activeUntil: collaborationUntil, now: now))
                recoveryDirectory = nil
                return
            }
            recoveryDirectory = prepared.recovery
            let caughtUp = outcome.caughtUp
            let installed = try await install(prepared, in: project, epoch: epoch)
            // A mixed reset advances only the base. Files and new typing remain untouched.
            try await Self.background { _ = try OverleafGit.run(["reset", "--mixed", prepared.head], at: root) }
            try active(epoch)
            connected = true; reconnecting = false; issue = nil; failures = 0
            confirmedRevision = revision; lastConfirmedAt = Date(); library.markSynced(connection.id)
            if installed.matchesRemote && caughtUp && project.editRevision == installed.editRevision && project.fileRevision == installed.fileRevision {
                confirmedRevision = installed.editRevision; confirmedFileRevision = installed.fileRevision; firstEdit = nil
            }
            unchangedChecks = 0
            collaborationUntil = Date().addingTimeInterval(120)
            nextCheck = Date().addingTimeInterval(15)
            if !caughtUp { confirmedRevision = -1 }
            try await Self.background { try OverleafSyncRecovery.finish(prepared) }
            recoveryDirectory = nil
        } catch is CancellationError { connected = false }
        catch {
            guard generation == epoch else { return }
            connected = false; issue = error.localizedDescription
            // Merge ambiguity pauses publishing. Transient transport failures keep a bounded retry schedule.
            requiresGitReview = (error as? OverleafSource.Failure) == .conflict || error is OverleafGitSync.ReviewRequired || issue?.contains("Review changes") == true
            reconnecting = !requiresGitReview
            pauseReason = requiresGitReview ? "Review needed" : "Saved locally · retrying"
            failures = min(failures + 1, 6)
            nextCheck = Date().addingTimeInterval(max((error as? OverleafGit.Failure)?.retryAfter ?? 0, [5.0, 15, 30, 60, 120, 180, 300][failures]))
        }
    }
    private func install(_ prepared: OverleafGitSync.Prepared, in project: TeXProject, epoch: UUID) async throws -> (matchesRemote: Bool, editRevision: Int, fileRevision: Int) {
        for _ in 0..<3 {
            let root = project.root, buffers = project.buffers, editRevision = project.editRevision, fileRevision = project.fileRevision
            let plan = try await Self.background {
                try TeXProject.prepareLiveInstall(root: root, buffers: buffers, editRevision: editRevision, fileRevision: fileRevision,
                                                 base: prepared.review.localFiles, result: prepared.files, head: prepared.originalHead)
            }
            try active(epoch)
            guard project.root == root, project.editRevision == editRevision, project.fileRevision == fileRevision else { continue }
            try project.installLiveFiles(plan)
            return (plan.matchesRemote, project.editRevision, project.fileRevision)
        }
        throw OverleafGit.Failure("Your edits are kept. Sync will retry when editing settles.")
    }
    private func active(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard enabled, visible, epoch == generation, !NetworkAccess.offline, library?.offlineMode == false else { throw CancellationError() }
    }
    private static func background<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: action)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func stop() async {
        enabled = false; generation = UUID(); ticker?.cancel(); ticker = nil
        connected = false; reconnecting = false; issue = nil
        // Recovery copies and legacy journals are retained. Stopping never publishes pending work.
    }
    func suspend() async { ticker?.cancel(); ticker = nil; generation = UUID(); connected = false; reconnecting = enabled }
    func networkChanged() async {
        if NetworkAccess.offline || library?.offlineMode == true || library?.hasNetwork == false { await suspend() }
        else if enabled { foregrounded() }
    }
    func decideReviewChange(_ change: OverleafReviewSnapshot.Change, accept: Bool) async throws {
        guard enabled, connected, !connecting, !syncingFiles, !reviewing, pendingDocumentCount == 0,
              !requiresGitReview, let project, let connection, !project.compiling,
              change.singleRange, change.anchor.localPathKnown,
              project.buffers[change.anchor.file] == change.anchor.source else {
            throw OverleafGit.Failure("Wait for confirmed sync, then refresh the review.")
        }
        reviewing = true; defer { reviewing = false }
        let ranges = try await OverleafWebClient.request("/project/" + connection.projectID + "/ranges", profile: connection.profileID)
        guard try change.isCurrent(in: ranges), pendingDocumentCount == 0,
              project.buffers[change.anchor.file] == change.anchor.source else { throw OverleafGit.Failure("This change moved. Refresh the review.") }
        if !accept {
            let prepared = try OverleafReviewRejection.prepare(change, root: project.root, source: change.anchor.source)
            let after = prepared.restored
            if after != change.anchor.source {
                guard let edit = project.editSource, edit(change.anchor.file, change.anchor.source, after, "Reject Overleaf change") else {
                    throw OverleafGit.Failure("Open the source editor before rejecting this change.")
                }
                edited(); await flush(force: true)
            }
            guard connected, issue == nil, pendingDocumentCount == 0, project.buffers[change.anchor.file] == after else {
                throw OverleafGit.Failure("The rejection is saved locally. Finish syncing before retrying.")
            }
            let service = OverleafReviewWrite(connection)
            defer { service.close() }
            try await service.open()
            let latest = try await OverleafWebClient.request("/project/" + connection.projectID + "/ranges", profile: connection.profileID)
            if try OverleafReviewRejection.needsResolution(change, ranges: latest) {
                let download = try await OverleafWebClient.request("/Project/" + connection.projectID + "/doc/" + change.documentID + "/download", profile: connection.profileID, document: true)
                let remote = try JSONSerialization.jsonObject(with: download) as? [String: Any]
                guard remote?["text"] as? String == after, pendingDocumentCount == 0,
                      project.buffers[change.anchor.file] == after else { throw OverleafGit.Failure("Source changed before completing the rejection. Refresh the review.") }
                // Overleaf's accept route removes only range metadata. The inverse source edit already went through Git.
                try await service.acceptChange(document: change.documentID, change: change.changeID)
                let confirmed = try await OverleafWebClient.request("/project/" + connection.projectID + "/ranges", profile: connection.profileID)
                guard try !OverleafReviewRejection.needsResolution(change, ranges: confirmed) else { throw OverleafGit.Failure("Source restored. Retry to finish clearing the suggestion.") }
            }
            try OverleafReviewRejection.finish(change, root: project.root)
            return
        }
        let service = OverleafReviewWrite(connection)
        defer { service.close() }
        try await service.open()
        guard pendingDocumentCount == 0, project.buffers[change.anchor.file] == change.anchor.source else { throw OverleafSource.Failure.staleDraft }
        let latest = try await OverleafWebClient.request("/project/" + connection.projectID + "/ranges", profile: connection.profileID)
        guard try change.isCurrent(in: latest), pendingDocumentCount == 0, project.buffers[change.anchor.file] == change.anchor.source else { throw OverleafGit.Failure("This change moved. Refresh the review.") }
        try await service.acceptChange(document: change.documentID, change: change.changeID)
    }
    func reviewGit() async {
        guard let project, let library, let connection else { return }
        await stop()
        await library.check(connection, save: project.save)
        enabled = true; requiresGitReview = library.review != nil
        pauseReason = "Review needed"
        if !requiresGitReview { startTicker() }
    }
}
