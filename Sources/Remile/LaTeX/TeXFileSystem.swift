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
    static func folders(_ root: URL) throws -> [String] {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var result: [String] = []
        for case let url as URL in items {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            if values.isDirectory == true { result.append(String(url.path.dropFirst(root.path.count + 1))) }
            guard result.count < 10000 else { throw CocoaError(.fileReadTooLarge) }
        }
        return result.sorted()
    }
    static func reference(_ path: String) -> String { path.hasSuffix(".tex") ? String(path.dropLast(4)) : path }
    static func topLevel(_ paths: [String]) -> [String] { paths.filter { path in !paths.contains { $0 != path && path.hasPrefix($0 + "/") } } }
    static func importFile(_ source: URL, root: URL, folder: String) throws -> String {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw Failure(errorDescription: "Add files up to 64 MB each.") }
        let path = folder.isEmpty ? source.lastPathComponent : folder + "/" + source.lastPathComponent
        let target = try url(path, root: root)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure(errorDescription: "A file with this name already exists.") }
        try FileManager.default.copyItem(at: source, to: target); return path
    }
}
