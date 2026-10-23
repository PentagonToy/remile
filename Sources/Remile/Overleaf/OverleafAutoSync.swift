import SwiftUI

/// The visible project owns the timer. No daemon or background permission is needed.
struct OverleafAutoSync: ViewModifier {
    @ObservedObject var library: OverleafLibrary
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    @StateObject private var clock = EditClock()
    private final class EditClock: ObservableObject { var lastEdit = Date.distantPast }
    private var revision: String { "\(project.editRevision):\(project.fileRevision):\(library.offlineMode):\(library.hasNetwork):\(NetworkAccess.offline)" }
    func body(content: Content) -> some View {
        content
            .onChange(of: project.editRevision) { _, _ in library.pendingFiles.insert(connection.id); clock.lastEdit = Date() }
            .onChange(of: project.fileRevision) { _, _ in library.pendingFiles.insert(connection.id); clock.lastEdit = Date() }
            .task(id: revision) {
                do {
                    try await Task.sleep(for: .seconds(2))
                    while library.busy { try await Task.sleep(for: .milliseconds(250)) }
                } catch { return }
                await sync()
            }
            .task(id: connection.id) {
                while !Task.isCancelled {
                    await sync()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
    private func sync() async {
        guard !library.liveOwned.contains(connection.id), Date().timeIntervalSince(clock.lastEdit) >= 1.9, !Task.isCancelled, !library.offlineMode, !NetworkAccess.offline, library.hasNetwork, !library.busy, library.review == nil, !project.compiling else { return }
        await library.syncLocalChanges(connection, save: project.save)
    }
}

extension OverleafLibrary {
    /// New remote revisions always go through the existing manual comparison.
    func syncLocalChanges(_ project: OverleafConnection, save: () -> Bool = { true }) async {
        guard allowsGit(project), !busy, !OverleafCredential.locked(project.profileID), !liveOwned.contains(project.id), !offlineMode, !NetworkAccess.offline, hasNetwork, review == nil, !automaticPaused.contains(project.id), !Task.isCancelled else { return }
        busy = true; syncRevision += 1
        defer { busy = false }
        let root = root(project), reviews = directory.appendingPathComponent("Reviews")
        do {
            let writer = try writerLease(project); defer { withExtendedLifetime(writer) {} }
            guard save() else { return }
            let changed = try await Task.detached(priority: .utility) { try OverleafAutoPublisher.needsCheck(project, root: root) }.value
            guard !Task.isCancelled, !offlineMode, !NetworkAccess.offline else { return }
            if !changed { if syncedAt[project.id] == nil || statuses[project.id] != .online || pendingFiles.contains(project.id) { markSynced(project.id) }; error = nil; return }
            let prepared = try await Task.detached(priority: .utility) { try OverleafGit.prepare(project, root: root, reviewRoot: reviews) }.value
            defer { try? FileManager.default.removeItem(at: prepared.stage) }
            guard !Task.isCancelled, !offlineMode, !NetworkAccess.offline, hasNetwork else { return }
            if prepared.changes.isEmpty { markSynced(project.id); error = nil; return }
            let localOnly = try await Task.detached(priority: .utility) { try OverleafAutoPublisher.isLocalOnly(prepared) }.value
            if !localOnly {
                automaticPaused.insert(project.id)
                statuses[project.id] = prepared.changes.contains(where: \.conflict) ? .conflict : .changes
                return
            }
            guard !Task.isCancelled, !offlineMode, !NetworkAccess.offline else { return }
            try await Task.detached(priority: .utility) { try OverleafAutoPublisher.publish(prepared) }.value
            markSynced(project.id); error = nil
        } catch {
            statuses[project.id] = .changes
            // Passive sync reports a locked account in the toolbar, not a repeating modal.
            if !OverleafCredential.locked(project.profileID) { self.error = error.localizedDescription }
        }
    }
}
