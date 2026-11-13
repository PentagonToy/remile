import Foundation

/// An on-demand text snapshot. Asset paths are listed without loading their bytes.
enum EditorSourceRead {
    private static let extensions: Set<String> = ["tex", "bib", "sty", "cls", "bst", "md", "markdown", "txt"]
    private static let fileLimit = 4_000_000
    private static let totalLimit = 32_000_000
    private static let sourceLimit = 2_000

    static func local(
        id: String, url: URL, kind: LocalDocumentIDs.Kind, file: String?,
        markdown: String? = nil, buffers: [String: String] = [:], main: String? = nil, dirty: Bool = false
    ) throws -> [String: Any] {
        var response: [String: Any]
        switch kind {
        case .markdown:
            let path = url.lastPathComponent
            guard file == nil || file == path else { throw Failure("Use the Markdown document's filename with --file.") }
            let source = try markdown ?? readText(url)
            response = [
                "files": [path], "folders": [String](),
                "sources": [path: try entry(source, buffered: markdown != nil, path: path)],
            ]
        case .latex:
            response = try project(root: url, file: file, buffers: buffers, main: main)
        }
        response["ok"] = true
        response["id"] = id
        response["kind"] = kind.rawValue
        response["dirty"] = dirty
        return response
    }

    static func project(
        root: URL, file: String?, buffers: [String: String] = [:], main: String? = nil
    ) throws -> [String: Any] {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure("The local project folder is unavailable.")
        }
        let tree = try TeXFileSystem.snapshot(root)
        let paths = buffers.isEmpty ? tree.paths : Set(tree.paths).union(buffers.keys).sorted()
        let sources = paths.filter(isTextSource)
        let selected: [String]
        if let file {
            guard sources.contains(file) else { throw Failure("Choose a text source from the project file list.") }
            selected = [file]
        } else {
            guard sources.count <= sourceLimit else { throw Failure("Read up to 2,000 text sources at once. Use --file for one source.") }
            selected = sources
        }
        var total = 0
        var result: [String: [String: String]] = [:]
        var mainSources: [String: String] = [:]
        for path in selected {
            let buffer = buffers[path]
            let text = try buffer ?? readProjectFile(path, root: root)
            total += text.utf8.count
            guard total <= totalLimit else { throw Failure("Read up to 32 MB of text at once. Use --file for one source.") }
            result[path] = try entry(text, buffered: buffer != nil, path: path)
            if (path as NSString).pathExtension.lowercased() == "tex" { mainSources[path] = text }
        }
        let saved = (UserDefaults.standard.dictionary(forKey: "latex.mainDocuments") as? [String: String])?[root.path]
        let inferred: String?
        if file == nil {
            inferred = TeXMainDocument.choose(sources: mainSources, saved: saved)
        } else if let saved, sources.contains(saved) {
            inferred = saved
        } else {
            inferred = sources.contains("main.tex") ? "main.tex" : nil
        }
        let folders = Set(tree.folders).union(buffers.keys.flatMap { path in
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { return [String]() }
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        return ["root": root.path, "files": paths, "folders": folders.sorted(), "sources": result,
                "main": (main ?? inferred) as Any? ?? NSNull()]
    }

    static func isTextSource(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func readProjectFile(_ path: String, root: URL) throws -> String {
        guard isTextSource(path) else { throw Failure("Choose a text source file.") }
        return try readText(TeXFileSystem.url(path, root: root))
    }

    private static func readText(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= fileLimit else {
            throw Failure("Read UTF-8 source files up to 4 MB: \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= fileLimit,
              let chunk = try handle.read(upToCount: fileLimit + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
        }
        guard data.count <= fileLimit, let source = String(data: data, encoding: .utf8) else {
            throw Failure("Read UTF-8 source files up to 4 MB: \(url.lastPathComponent)")
        }
        return source
    }

    private static func entry(_ source: String, buffered: Bool, path: String) throws -> [String: String] {
        guard source.utf8.count <= fileLimit else { throw Failure("Read UTF-8 source files up to 4 MB: \(path)") }
        return ["source": source, "sha256": SourceDigest.sha256(source), "origin": buffered ? "editor-buffer" : "disk"]
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
