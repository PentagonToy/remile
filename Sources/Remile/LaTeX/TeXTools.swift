import Foundation

@MainActor enum TeXTools {
    struct Edit { let source: String; let title: String; let count: Int; var references: [String] = [] }
    static func prepare(_ action: String, project: TeXProject, file: String, range: NSRange? = nil) throws -> Edit {
        guard let source = project.buffers[file] else { throw TeXSourceTools.Failure(errorDescription: "No editable source at this path.") }
        switch action {
        case "strip-notes":
            let edit = try TeXSourceTools.removingAuthorNotes(source)
            return Edit(source: edit.source, title: "Remove author notes", count: edit.count)
        case "embed-bibliography":
            guard file == project.main, let build = project.build, build.main == project.main, build.buffers == project.buffers else { throw TeXSourceTools.Failure(errorDescription: "Compile the unchanged main document before embedding references.") }
            let url = build.pdf.deletingPathExtension().appendingPathExtension("bbl")
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 4_000_000 else { throw TeXSourceTools.Failure(errorDescription: "No supported generated bibliography is available.") }
            return Edit(source: try TeXSourceTools.inlineBibliography(source, bbl: String(contentsOf: url, encoding: .utf8), keepOrigin: true), title: "Embed bibliography", count: 1)
        case "restore-bibliography":
            guard file == project.main else { throw TeXSourceTools.Failure(errorDescription: "Restore references from the main document.") }
            let edit = try TeXSourceTools.restoreBibliography(source)
            try requireReferences(edit.references, in: project)
            return Edit(source: edit.source, title: "Restore bibliography", count: 1, references: edit.references)
        case "toggle-comment", "indent", "outdent":
            let selected = range ?? NSRange(location: 0, length: (source as NSString).length)
            let change = action == "toggle-comment" ? EditorSourceEditing.toggleComment(source, selection: selected) : EditorSourceEditing.indent(source, selection: selected, reverse: action == "outdent")
            guard let change else { throw TeXSourceTools.Failure(errorDescription: "Invalid source range.") }
            return Edit(source: (source as NSString).replacingCharacters(in: change.range, with: change.text), title: action == "toggle-comment" ? "Toggle Comment" : action == "indent" ? "Indent" : "Outdent", count: 1)
        default: throw TeXSourceTools.Failure(errorDescription: "Unknown source action.")
        }
    }
    static func requireReferences(_ references: [String], in project: TeXProject) throws {
        for file in references {
            let url = try TeXFileSystem.url(file, root: project.root)
            let exists = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            guard exists else {
                throw TeXSourceTools.Failure(errorDescription: "Restore the original bibliography file “\(file)” first.")
            }
        }
    }
}
