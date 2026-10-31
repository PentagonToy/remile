import Foundation

/// Bounded ordinary project files shared by Git preparation and source installation.
enum OverleafSourceFiles {
    static let byteLimit = 100 * 1024 * 1024
    static let fileLimit = 30 * 1024 * 1024
    enum Failure: LocalizedError {
        case stale, invalid, uncertain
        var errorDescription: String? {
            switch self {
            case .stale: return "Project files changed during sync. Reconnect to check the latest versions."
            case .invalid: return "Git sync supports ordinary project files up to 30 MB each and 100 MB in total."
            case .uncertain: return "A file operation was not confirmed. Reconnect to check Overleaf before trying again."
            }
        }
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 4096 && !path.contains("\\") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && $0.utf8.count <= 150
        }
    }
    static func source(_ path: String) -> Bool { ["tex", "bib", "sty", "cls"].contains((path as NSString).pathExtension.lowercased()) }
    private static func files(at root: URL) throws -> [(path: String, url: URL, size: Int)] {
        var result: [(path: String, url: URL, size: Int)] = [], total = 0, folded = Set<String>()
        var traversalError: Error?
        let directory = root.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
            traversalError = error; return false
        }) else { throw Failure.invalid }
        for case let url as URL in walker {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            // An unsupported link must never look like a deliberate deletion of the remote file.
            guard values.isSymbolicLink != true else { throw Failure.invalid }
            guard values.isRegularFile == true else { continue }
            let canonical = url.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(directory.path + "/") else { throw Failure.invalid }
            let path = String(canonical.path.dropFirst(directory.path.count + 1)), size = values.fileSize ?? Int.max
            guard result.count < 10_000, validPath(path), folded.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted, size <= fileLimit else { throw Failure.invalid }
            _ = try TeXFileSystem.url(path, root: root)
            total += size; guard total <= byteLimit else { throw Failure.invalid }
            result.append((path, url, size))
        }
        // Incomplete enumeration is not evidence that omitted remote files were deleted locally.
        if let traversalError { throw traversalError }
        return result
    }
    static func scan(_ root: URL, buffers: [String: String] = [:]) throws -> [String: Data] {
        var result: [String: Data] = [:], total = 0
        for file in try files(at: root) {
            try Task.checkCancellation()
            let bytes = try buffers[file.path].map { Data($0.utf8) } ?? Data(contentsOf: file.url, options: .mappedIfSafe)
            total += bytes.count
            guard bytes.count <= fileLimit, total <= byteLimit else { throw Failure.invalid }
            result[file.path] = bytes
        }
        return result
    }
}
