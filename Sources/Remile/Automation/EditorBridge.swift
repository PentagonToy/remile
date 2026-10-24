import Foundation

/// A per-user file mailbox. Operations are fixed; no arbitrary commands are evaluated.
enum EditorBridge {
    struct Request: Codable {
        var id: UUID = UUID()
        let operation: String
        var target: UUID?
        var file: String?
        var source: String?
        var expectedSHA256: String?
        var action: String?
        var name: String?
        var output: String?
        var kind: String?
        var apply: Bool?
        var scratch: Bool?
        var submissionCheck: Bool?
        var start: Int?
        var length: Int?
        var zoom: Double?
        var rulers: Bool?
        var fit: Bool?
        var header: String?
        var footer: String?
        var topLine: Bool?
        var bottomLine: Bool?
        var pageNumbers: Bool?
        var columns: Int?
        var object: UUID?
        var wrap: Bool?
        var locked: Bool?
    }
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Automation") }
    static func digest(_ source: String) -> String { SourceDigest.sha256(source) }
    @MainActor static func serve(_ home: HomeModel) async { await serve { home } }
    @MainActor static func serve(_ currentHome: @escaping @MainActor () -> HomeModel?, directory folder: URL = directory) async {
        let manager = FileManager.default
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) } catch { return }
        while !Task.isCancelled {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let changes = try DirectoryChanges(folder)
                defer { changes.cancel() }
                for await _ in changes.events {
                    guard !Task.isCancelled else { return }
                    let requests = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter {
                        $0.lastPathComponent.hasSuffix(".request.json") && UUID(uuidString: String($0.lastPathComponent.dropLast(".request.json".count))) != nil
                    }
                    for file in requests {
                        guard !Task.isCancelled else { return }
                        do {
                            let attributes = try manager.attributesOfItem(atPath: file.path)
                            guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), (attributes[.size] as? Int ?? Int.max) < 5_000_000 else { continue }
                            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: file))
                            guard file.lastPathComponent == request.id.uuidString + ".request.json" else { try manager.removeItem(at: file); continue }
                            let output = folder.appendingPathComponent(request.id.uuidString + ".response.json")
                            if manager.fileExists(atPath: output.path) { try manager.removeItem(at: file); continue }
                            // A pending CLI command may need the first window to finish registering.
                            let homes = RemileWindows.shared.models
                            var home: HomeModel?
                            if let target = request.target {
                                home = homes.first { $0.automationTarget == target }
                                if home == nil, currentHome()?.automationTarget == target { home = currentHome() }
                            } else { home = currentHome() }
                            for _ in 0..<100 where home == nil && request.target == nil && request.operation != "documents" {
                                try await Task.sleep(for: .milliseconds(50)); home = currentHome()
                            }
                            let response: [String: Any]
                            if request.operation == "overleaf" { response = await OverleafCommands.handle(request, homes: homes, current: currentHome()) }
                            else if request.operation == "documents" { response = ["ok": true, "documents": homes.compactMap { $0.automationDescription }] }
                            else if let home { response = await handle(request, home: home) }
                            else if request.target != nil { response = ["ok": false, "error": "The target document is no longer open. Run documents again."] }
                            else { response = ["ok": false, "error": "The document window is not ready. Try again."] }
                            let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                            try bytes.write(to: output, options: [.atomic]); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path); try manager.removeItem(at: file)
                        } catch is CancellationError { return }
                        catch { try? manager.removeItem(at: file) }
                        await Task.yield()
                    }
                }
            } catch { return }
        }
    }
    @MainActor private static func handle(_ request: Request, home: HomeModel) async -> [String: Any] {
        if let target = request.target, home.automationTarget != target { return ["ok": false, "error": "The target document changed. Run documents again."] }
        if request.operation == "diagnostics" { return RuntimeDiagnostics.snapshot(home) }
        if request.operation == "review" { return ManuscriptReviewCommands.handle(request, project: home.texProject) }
        if request.operation == "open" {
            guard let path = request.file, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return ["ok": false, "error": "Provide an existing absolute path."] }
            home.open(URL(fileURLWithPath: path)); return ["ok": home.error == nil, "message": home.error ?? "", "opening": home.opening]
        }
        if home.page == .writer, let writer = home.writer, ["status", "read", "replace", "save", "export", "writer-view", "writer-page", "writer-object"].contains(request.operation) { return WriterCommands.handle(request, model: writer) }
        if request.operation == "status" {
            return ["ok": true, "projectID": home.automationProjectID, "target": home.automationTarget?.uuidString ?? "", "kind": home.texProject == nil ? "document" : "latex-local", "path": home.texProject?.root.path ?? home.reader.url?.path ?? "", "dirty": home.texProject?.dirty ?? home.reader.dirty, "compiling": home.texProject?.compiling ?? false, "selected": home.texProject?.selected ?? "", "pages": home.texProject?.pdf?.pageCount ?? 0, "errors": home.texProject?.diagnostics.filter { $0.severity == .error }.count ?? 0, "warnings": home.texProject?.diagnostics.filter { $0.severity == .warning }.count ?? 0, "historyMinutes": TeXHistory.intervalMinutes, "aiSuggestions": UserDefaults.standard.bool(forKey: "editor.aiSuggestions"), "compileCurrent": home.texProject?.outputCurrent ?? false]
        }
        if request.operation == "library-search" {
            do {
                guard let query = request.source else { return ["ok": false, "error": "Provide a search question or keywords."] }
                let response = try await home.librarySearch(query, boost: request.apply != false)
                return ["ok": true, "engine": response.phrases.isEmpty ? "B0" : "B-guided", "expansionPhrases": response.phrases, "hits": response.hits.map { hit in
                    ["path": hit.path, "page": hit.page, "excerpt": hit.excerpt, "score": hit.score, "matchQuery": hit.matchQuery ?? query] as [String: Any]
                }]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        }
        if request.operation == "pdf-read" {
            do {
                guard home.texProject == nil, let inspect = home.reader.pdfInspection else { return ["ok": false, "error": "Open a PDF in the reader first, or supply an absolute PDF path."] }
                var result = try inspect(request.start, request.source, request.output)
                result["path"] = home.reader.url?.path ?? ""; result["dirty"] = home.reader.dirty
                return result
            } catch { return ["ok": false, "error": error.localizedDescription] }
        }
        if request.operation == "comments" {
            do {
                if let root = home.texProject?.root, let project = home.overleaf.connection(for: root) {
                    guard let archive = home.overleaf.comments[project.id] else { return ["ok": false, "error": "Open Online review and read this project's comments first."] }
                    return try archive.response(format: PDFCommentExport.format(named: request.kind, output: request.output), output: request.output)
                }
                guard home.texProject == nil, case .pdf = home.reader.document.content, let export = home.reader.commentsExport else { return ["ok": false, "error": "Open a PDF to read its comments."] }
                let archive = try export(), format = try PDFCommentExport.format(named: request.kind, output: request.output)
                return try PDFCommentExport.response(archive, format: format, output: request.output)
            } catch { return ["ok": false, "error": error.localizedDescription] }
        }
        if home.texProject == nil, home.reader.url != nil, case .markdown(let source) = home.reader.document.content {
            return await markdown(request, reader: home.reader, source: source)
        }
        guard let project = home.texProject else { return ["ok": false, "error": "Open a local LaTeX project first."] }
        let file = request.file ?? project.selected
        switch request.operation {
        case "submission-compare":
            if request.kind != "status" {
                guard !project.compiling else { return ["ok": false, "error": "Compilation is already running."] }
                project.compareSubmission()
            }
            return ["ok": true, "running": project.submission.running, "sourceChanged": project.buffers != project.submission.buffers || project.main != project.submission.main, "sourceHashes": project.submission.buffers.mapValues(digest), "results": project.submission.json]
        case "logs":
            return ["ok": true, "compiling": project.compiling, "log": String(project.log.suffix(min(150000, max(1, request.length ?? 150000)))), "diagnostics": project.diagnostics.map { ["id": $0.id, "severity": String(describing: $0.severity), "message": $0.message, "file": $0.file ?? "", "line": $0.line ?? 0] as [String: Any] }, "sourceHashes": project.sourceHashes]
        case "read":
            guard let source = project.buffers[file] else { return ["ok": false, "error": "No editable file at this project-relative path."] }
            return ["ok": true, "file": file, "source": source, "sha256": digest(source), "dirty": project.dirty, "externalEdits": (project.externalEdits[file] ?? []).map { ["start": $0.location, "length": $0.length] }, "externalEditsSessionOnly": true]
        case "select":
            guard project.buffers[file] != nil else { return ["ok": false, "error": "No editable file at this project-relative path."] }
            project.visit(file: file); return ["ok": true, "file": file]
        case "replace":
            guard !project.compiling, let current = project.buffers[file], request.expectedSHA256 == digest(current), let source = request.source, source.utf8.count <= 4_000_000 else { return ["ok": false, "error": "Source conflict, invalid file or compilation in progress. Read the current source hash first."] }
            guard project.applyTool(file: file, before: current, after: source, name: "CLI edit", feedback: false) else { return ["ok": false, "error": project.message ?? "Could not apply edit."] }
            project.markExternalEdit(file: file, before: current, after: source)
            return ["ok": true, "file": file, "sha256": digest(source), "saved": false]
        case "save": return ["ok": project.save(), "message": project.message ?? ""]
        case "compile", "submission-check":
            guard !project.compiling else { return ["ok": false, "error": "Compilation is already running."] }
            let check = request.operation == "submission-check" || request.submissionCheck == true
            project.compile(scratch: request.scratch ?? false, submissionCheck: check); return ["ok": project.compiling, "compiling": project.compiling, "submissionCheck": check, "missingTools": TeXConfiguration.current.missingTools(buffers: project.buffers, submissionCheck: check)]
        case "history": return ["ok": true, "revisions": project.revisions.map { ["id": $0.id.uuidString, "file": $0.file, "date": $0.date.timeIntervalSince1970, "marker": $0.marker ?? ""] }]
        case "rename":
            guard let name = request.name else { return ["ok": false, "error": "Provide --name."] }
            return ["ok": request.kind == "project" ? project.renameProject(to: name) : project.rename(file, to: name), "message": project.message ?? ""]
        case "transform":
            do {
                guard let action = request.action, let before = project.buffers[file] else { throw TeXSourceTools.Failure(errorDescription: "Provide an action and editable file.") }
                let range = request.start.map { NSRange(location: max(0, $0), length: max(0, request.length ?? 0)) }
                let edit = try TeXTools.prepare(action, project: project, file: file, range: range)
                if request.apply == true {
                    guard request.expectedSHA256 == digest(before) else { throw TeXSourceTools.Failure(errorDescription: "Source conflict. Read the current SHA-256 before applying.") }
                    let applied = project.applyTool(file: file, before: before, after: edit.source, name: edit.title, feedback: false)
                    if applied { project.markExternalEdit(file: file, before: before, after: edit.source) }
                    return ["ok": applied, "saved": false, "sha256": digest(project.buffers[file] ?? "")]
                }
                return ["ok": true, "file": file, "title": edit.title, "count": edit.count, "beforeSHA256": digest(before), "source": edit.source, "saved": false]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        case "export":
            do {
                guard let output = request.output, output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output), !URL(fileURLWithPath: output).resolvingSymlinksInPath().path.hasPrefix(project.root.resolvingSymlinksInPath().path + "/") else { throw TeXSourceTools.Failure(errorDescription: "Use a new absolute output file outside the project.") }
                let target = URL(fileURLWithPath: output), root = project.root, buffers = project.buffers
                if request.kind == "source" { guard target.pathExtension.lowercased() == "zip" else { throw TeXSourceTools.Failure(errorDescription: "Source archives use .zip.") }; try await Task.detached { try TeXSourceSnapshot.export(root: root, buffers: buffers, to: target) }.value }
                else if request.kind == "pdf", let pdf = project.build?.pdf { guard target.pathExtension.lowercased() == "pdf" else { throw TeXSourceTools.Failure(errorDescription: "PDF export uses .pdf.") }; try await Task.detached { try Data(contentsOf: pdf).write(to: target, options: .atomic) }.value }
                else { throw TeXSourceTools.Failure(errorDescription: "Choose --kind source or a successfully compiled PDF.") }
                return ["ok": true, "output": output]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        default: return ["ok": false, "error": "Unknown operation."]
        }
    }
    @MainActor private static func markdown(_ request: Request, reader: ReadingSession, source: String) async -> [String: Any] {
        if let file = request.file, file != reader.url?.path, file != reader.url?.lastPathComponent { return ["ok": false, "error": "The requested Markdown file is not open."] }
        switch request.operation {
        case "read": return ["ok": true, "file": reader.url?.path ?? "", "source": source, "sha256": digest(source), "dirty": reader.dirty, "externalEdits": reader.externalEdits.map { ["start": $0.location, "length": $0.length] }, "externalEditsSessionOnly": true]
        case "replace":
            guard request.expectedSHA256 == digest(source), let after = request.source, after.utf8.count <= 4_000_000, let edit = reader.editSource else { return ["ok": false, "error": "Source conflict or editor not ready. Read the current source hash first."] }
            guard await edit(source, after) else { return ["ok": false, "error": "The source changed or editor is not ready. Read it again before retrying."] }
            if let target = request.target, reader.identity != target { return ["ok": false, "error": "The target document changed during the edit. Read the document state before retrying."] }
            reader.markExternalEdit(before: source, after: after)
            return ["ok": true, "sha256": digest(after), "saved": false]
        case "save":
            guard !reader.isUntitled else { return ["ok": false, "error": "Choose a filename in the app, or export a source copy first."] }
            return ["ok": reader.save()]
        case "export":
            do {
                guard let output = request.output, output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output) else { throw TeXSourceTools.Failure(errorDescription: "Use a new absolute output file.") }
                let target = URL(fileURLWithPath: output)
                if request.kind == "source", ["md", "markdown"].contains(target.pathExtension.lowercased()) { try Data(source.utf8).write(to: target, options: .atomic) }
                else if request.kind == "pdf", target.pathExtension.lowercased() == "pdf" {
                    let url = reader.url ?? target
                    let html = try await Task.detached { var renderer = MarkdownHTML(baseURL: url); return try renderer.document(source) }.value
                    try await MarkdownPDF.write(html, to: target)
                } else { throw TeXSourceTools.Failure(errorDescription: "Choose source (.md) or pdf (.pdf).") }
                return ["ok": true, "output": output]
            } catch { return ["ok": false, "error": error.localizedDescription] }
        default: return ["ok": false, "error": "This operation requires a local LaTeX project. Markdown supports read, replace, save and export."]
        }
    }

}
