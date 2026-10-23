import Foundation

/// Shared bounded ZIP extraction. Never replace an existing project or the input archive.
enum TeXSourceArchive {
    struct Failure: LocalizedError { var errorDescription: String? { "Choose a valid LaTeX source ZIP and a new project folder." } }
    static func extract(_ data: Data, at root: URL, requireClass: Bool = false) throws -> [String: String] {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.path) else { throw Failure() }
        let archive: WordArchive
        do { archive = try WordArchive(data) } catch { throw Failure() }
        var names = Set<String>()
        for entry in archive.entries {
            let path = entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" && !$0.lowercased().hasPrefix(".remile") }), names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw Failure() }
        }
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = root.deletingLastPathComponent().appendingPathComponent(".remile-extract-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        var sources: [String: String] = [:]
        for entry in archive.entries {
            let target = stage.appendingPathComponent(entry.name)
            if entry.name.hasSuffix("/") { try manager.createDirectory(at: target, withIntermediateDirectories: true); continue }
            let bytes = try archive.read(entry.name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .withoutOverwriting)
            if ["tex", "bib", "sty", "cls"].contains(target.pathExtension.lowercased()) {
                guard bytes.count <= 4_000_000, let text = String(data: bytes, encoding: .utf8) else { throw Failure() }
                sources[entry.name] = text
            }
        }
        guard sources.count <= 1000, sources.contains(where: { $0.key.lowercased().hasSuffix(".tex") && (!requireClass || $0.value.contains("\\documentclass")) }) else { throw Failure() }
        try manager.moveItem(at: stage, to: root)
        return sources
    }
    static func projectRoot(in folder: URL) throws -> URL {
        var folder = folder
        for _ in 0..<8 {
            let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { $0.lastPathComponent != "__MACOSX" }
            guard children.count == 1, let child = children.first, try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { break }
            folder = child
        }
        return folder
    }
}
