import Foundation

enum TeXFileSystem {
    struct Failure: LocalizedError { let errorDescription: String? }
    static func url(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure(errorDescription: "Invalid project path.") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let result = base.appendingPathComponent(path).standardizedFileURL
        guard result.resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { throw Failure(errorDescription: "The path leaves the project.") }
        return result
    }
    static func move(root: URL, from: String, to: String) throws {
        let source = try url(from, root: root), destination = try url(to, root: root)
        guard source != destination, !destination.path.hasPrefix(source.path + "/"), !FileManager.default.fileExists(atPath: destination.path) else { throw Failure(errorDescription: "The destination already exists or is inside this folder.") }
        try FileManager.default.moveItem(at: source, to: destination)
    }
    static func paths(_ root: URL) throws -> [String] {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var paths: [String] = []
        for case let url as URL in items {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            guard paths.count < 10000 else { throw CocoaError(.fileReadTooLarge) }
            paths.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return paths.sorted()
    }
    static func importFile(_ source: URL, root: URL, folder: String) throws -> String {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let allowed = ["tex", "bib", "sty", "cls", "pdf", "png", "jpg", "jpeg", "svg", "eps", "csv", "txt", "dat"]
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024, allowed.contains(source.pathExtension.lowercased()) else { throw Failure(errorDescription: "Drop source files or document assets, up to 64 MB each.") }
        let path = folder.isEmpty ? source.lastPathComponent : folder + "/" + source.lastPathComponent
        let target = try url(path, root: root)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure(errorDescription: "A file with this name already exists.") }
        try FileManager.default.copyItem(at: source, to: target); return path
    }
}
