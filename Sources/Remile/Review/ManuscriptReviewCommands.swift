import Foundation

@MainActor enum ManuscriptReviewCommands {
    static func criteria() throws -> [String: Any] {
        ["ok": true, "catalog": try JSONSerialization.jsonObject(with: ReviewCatalog.resource("criteria.json")), "instructions": try ReviewCatalog.instructions(), "compactCriteria": ["consistency", "scope", "clarity"]]
    }
    static func handle(_ request: EditorBridge.Request, project: TeXProject?) -> [String: Any] {
        do {
            if request.action == "criteria" { return try criteria() }
            if let source = request.source, !source.hasPrefix("/") { throw ReviewFailure("Supply an absolute project directory.") }
            guard let root = request.source.map({ URL(fileURLWithPath: $0) }) ?? project?.root else { throw ReviewFailure("Open a LaTeX project, or supply its absolute directory.") }
            let store = ManuscriptReviewStore.shared(for: root)
            switch request.action {
            case "run":
                guard let project, ManuscriptReviewStore.canonical(project.root) == ManuscriptReviewStore.canonical(root) else { throw ReviewFailure("Open this project in remile. before starting a review.") }
                try store.start(buffers: project.buffers, selected: request.file ?? project.selected)
            case "clear": try store.clear()
            case "stop": store.stop()
            case nil, "read": break
            default: throw ReviewFailure("Unknown review action.")
            }
            var value = try store.response(format: PDFCommentExport.format(named: request.kind, output: request.output), output: request.output)
            if let project, ManuscriptReviewStore.canonical(project.root) == ManuscriptReviewStore.canonical(root) {
                let hashes = project.sourceHashes
                value["staleRunIDs"] = store.archive.runs.filter { $0.sourceHashes.contains { hashes[$0.key] != $0.value } }.map { $0.id.uuidString }
            }
            return value
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
}
