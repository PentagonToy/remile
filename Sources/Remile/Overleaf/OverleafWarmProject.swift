import Foundation

/// Keep one recently closed Live project briefly. No hidden file scan or flush
/// timer runs. The existing socket can finish ACKs and receive remote edits.
extension OverleafLibrary {
    @discardableResult func retainWarmProject(_ project: TeXProject, duration: Duration = .seconds(45)) -> Bool {
        guard let connection = connection(for: project.root), OverleafSyncPreference.live(connection.id), project.liveWorkspace.enabled else { return false }
        warmExpiry?.cancel()
        if let previous = warmProject, previous !== project {
            Task { await previous.liveWorkspace.stop(); previous.releaseWorkspaceResources() }
        }
        project.liveWorkspace.setVisible(false)
        warmProject = project
        warmExpiry = Task { [weak self, weak project] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, let project, self.warmProject === project else { return }
            await self.discardWarmProject()
        }
        return true
    }
    func takeWarmProject(_ root: URL) -> TeXProject? {
        guard let project = warmProject, project.root.path == root.standardizedFileURL.path, connection(for: project.root) != nil else { return nil }
        warmExpiry?.cancel(); warmExpiry = nil; warmProject = nil
        project.liveWorkspace.setVisible(true)
        return project
    }
    func discardWarmProject() async {
        warmExpiry?.cancel(); warmExpiry = nil
        guard let project = warmProject else { return }
        warmProject = nil
        await project.liveWorkspace.stop()
        project.releaseWorkspaceResources()
    }
}
