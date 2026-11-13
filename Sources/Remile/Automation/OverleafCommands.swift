import Foundation

/// Resolve persistent project references before using the open-document commands.
@MainActor enum OverleafCommands {
    static func handle(_ request: EditorBridge.Request, homes: [HomeModel], current: HomeModel?) async -> [String: Any] {
        do {
            var models = homes
            if let current, !models.contains(where: { $0 === current }) { models.append(current) }
            guard let library = (current ?? models.first)?.overleaf else {
                if request.action == "read-sources", request.target == nil, let id = request.source {
                    return try await Task.detached(priority: .utility) {
                        try readSaved(id: id, connectionID: request.name, file: request.file)
                    }.value
                }
                throw Failure("Open remile before querying Overleaf projects.")
            }
            if request.action == "list" {
                let query = request.kind ?? ""
                let projects = library.projects.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
                return ["ok": true, "projects": projects.map { metadata($0, library: library) }]
            }
            guard let id = request.source.flatMap(OverleafProjectID.parse) else { throw Failure("Provide a valid Overleaf project ID.") }
            let matches = library.projects.filter { $0.projectID == id && (request.name == nil || $0.id.uuidString.caseInsensitiveCompare(request.name!) == .orderedSame) }
            guard matches.count == 1, let connection = matches.first else {
                if matches.isEmpty { throw Failure("This project is not connected on this Mac. Add it in the Overleaf library first.") }
                return ["ok": false, "error": "This project has several connections. Choose --connection from overleaf list.", "connections": matches.map { metadata($0, library: library) }]
            }
            let root = library.root(connection)
            let sessions = models.filter { $0.page != .writer && $0.texProject?.root.standardizedFileURL.path == root.standardizedFileURL.path }
            let selected = sessions.filter { request.target == nil || $0.automationTarget == request.target }
            guard request.target == nil || selected.count == 1 else { throw Failure("The target is not an open session of this project. Run documents again.") }
            guard selected.count <= 1 else { throw Failure("This project is open in several windows. Choose --target from documents.") }
            var home = selected.first
            if request.action == "open", home == nil {
                guard let destination = current ?? models.first, destination.page != .writer, !destination.opening, destination.texProject?.dirty != true, !destination.reader.dirty, destination.writer?.dirty != true else { throw Failure("Save the current document or open a separate window first.") }
                guard FileManager.default.fileExists(atPath: root.path) else { throw Failure("The local project folder is missing. Reconnect it in the Overleaf library.") }
                destination.open(root)
                guard destination.texProject?.root.standardizedFileURL.path == root.standardizedFileURL.path else { throw Failure(destination.error ?? "The project could not be opened.") }
                destination.overleaf.browsing = false
                home = destination
            }
            if request.action == "review" {
                return await OverleafReviewCommands.handle(connection: connection, root: root, project: home?.texProject, format: request.kind, output: request.output, library: library)
            }
            if request.action == "read-sources" {
                let project = home?.texProject
                let buffers = project?.buffers ?? [:], main = project?.main
                let syncDate = library.syncedAt[connection.id]
                let dirty = project?.dirty ?? false
                var result = try await Task.detached(priority: .utility) {
                    try sourceResponse(connection, root: root, file: request.file, buffers: buffers, main: main, syncedAt: syncDate)
                }.value
                result["dirty"] = dirty
                if let project { result["target"] = project.identity.uuidString }
                return result
            }
            var result = metadata(connection, library: library)
            result["ok"] = true
            result["observedAt"] = Date().timeIntervalSince1970
            result["remoteFreshness"] = "not-checked"
            result["open"] = home != nil
            let online = home?.texProject?.liveWorkspace.automationStatus as Any? ?? NSNull()
            result["online"] = online
            result["live"] = online // Keep the original CLI field as a compatibility alias.
            if let project = home?.texProject {
                result["target"] = project.identity.uuidString
                result["dirty"] = project.dirty
                result["main"] = project.main
                result["files"] = project.buffers.keys.sorted()
                result["sourceHashes"] = project.sourceHashes
                result["compiling"] = project.compiling
                result["pdfAvailable"] = project.pdf != nil
                result["pdfCurrent"] = project.outputCurrent
            } else {
                // A closed project has no live buffer or verified current PDF.
                result["pdfCurrent"] = NSNull()
                result["files"] = try await Task.detached(priority: .utility) { try TeXFileSystem.paths(root) }.value
            }
            if request.action == "read" {
                guard let file = request.file else { throw Failure("Provide a project-relative --file.") }
                let source: String
                if let project = home?.texProject {
                    guard let buffer = project.buffers[file] else { throw Failure("No editable source at this project-relative path.") }
                    source = buffer; result["origin"] = "editor-buffer"
                } else {
                    source = try await Task.detached(priority: .utility) { try readSource(file, root: root) }.value
                    result["origin"] = "disk"
                }
                result["file"] = file; result["source"] = source; result["sha256"] = SourceDigest.sha256(source)
            }
            return result
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }

    nonisolated static func readSaved(
        id: String, connectionID: String?, file: String?, directory: URL = OverleafLibrary.defaultDirectory
    ) throws -> [String: Any] {
        guard let projectID = OverleafProjectID.parse(id) else { throw Failure("Provide a valid Overleaf project ID.") }
        let catalogue = directory.appendingPathComponent("projects.json")
        let projects: [OverleafConnection]
        do { projects = try JSONDecoder().decode([OverleafConnection].self, from: Data(contentsOf: catalogue)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileReadNoSuchFile.rawValue { projects = [] }
        let matches = projects.filter {
            $0.projectID == projectID && (connectionID == nil || UUID(uuidString: connectionID ?? "") == $0.id)
        }
        guard !matches.isEmpty else {
            throw Failure("This project is not connected on this Mac. Add it in the Overleaf library first.")
        }
        guard matches.count == 1, let connection = matches.first else {
            return ["ok": false, "error": "This project has several connections. Choose --connection.",
                    "connections": matches.map { ["connection": $0.id.uuidString, "name": $0.name, "account": $0.account] }]
        }
        let root = OverleafLibrary.projectRoot(connection, directory: directory)
        let syncedAt = UserDefaults.standard.object(forKey: "overleaf.synced." + connection.id.uuidString) as? Date
        return try sourceResponse(connection, root: root, file: file, syncedAt: syncedAt)
    }

    nonisolated private static func sourceResponse(
        _ connection: OverleafConnection, root: URL, file: String?,
        buffers: [String: String] = [:], main: String? = nil, syncedAt: Date?
    ) throws -> [String: Any] {
        var response = try EditorSourceRead.project(root: root, file: file, buffers: buffers, main: main)
        response["ok"] = true
        response["id"] = OverleafProjectID.reference(connection.projectID)
        response["kind"] = "overleaf"
        response["connection"] = connection.id.uuidString
        response["name"] = connection.name
        response["dirty"] = false
        response["lastSyncedAt"] = syncedAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()
        response["remoteFreshness"] = "not-checked"
        response["observedAt"] = Date().timeIntervalSince1970
        return response
    }

    private static func metadata(_ project: OverleafConnection, library: OverleafLibrary) -> [String: Any] {
        var result: [String: Any] = ["id": OverleafProjectID.reference(project.projectID), "connection": project.id.uuidString, "name": project.name, "root": library.root(project).path, "url": project.webURL.absoluteString]
        result["lastSyncedAt"] = library.syncedAt[project.id].map { $0.timeIntervalSince1970 } as Any? ?? NSNull()
        result["syncStatus"] = library.statuses[project.id].map { String(describing: $0) } ?? "unchecked"
        return result
    }

    nonisolated static func readSource(_ file: String, root: URL) throws -> String {
        try EditorSourceRead.readProjectFile(file, root: root)
    }

    struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}
