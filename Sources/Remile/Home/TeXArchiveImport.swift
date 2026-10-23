import AppKit

extension HomeModel {
    func importTeXArchive(_ archive: URL) {
        let panel = NSOpenPanel()
        panel.title = "Extract LaTeX project"
        panel.message = "Choose where to create the project folder. The source ZIP stays unchanged."
        panel.prompt = "Extract here"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let base = archive.deletingPathExtension().lastPathComponent
        var destination = parent.appendingPathComponent(base.isEmpty ? "LaTeX project" : base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent(base + " " + String(suffix)); suffix += 1
        }
        let previousTarget = automationTarget
        opening = true
        let folder = destination
        Task {
            defer { opening = false }
            do {
                let root = try await Task.detached(priority: .userInitiated) {
                    let scope = archive.startAccessingSecurityScopedResource(); defer { if scope { archive.stopAccessingSecurityScopedResource() } }
                    let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw TeXSourceArchive.Failure() }
                    _ = try TeXSourceArchive.extract(Data(contentsOf: archive), at: folder)
                    return try TeXSourceArchive.projectRoot(in: folder)
                }.value
                guard automationTarget == previousTarget else {
                    self.error = "Project extracted to " + root.path + ". Open it when you are ready."
                    return
                }
                openTeX(root)
            } catch { self.error = "Could not extract LaTeX project: " + error.localizedDescription }
        }
    }
}
