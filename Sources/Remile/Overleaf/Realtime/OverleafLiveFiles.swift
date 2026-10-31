import Foundation
import CryptoKit

/// Three-way file reconciliation. Text already joined to OT is left to its versioned journal.
enum OverleafLiveFiles {
    static let byteLimit = 100 * 1024 * 1024
    static let fileLimit = 30 * 1024 * 1024
    struct Entry: Codable, Equatable, Sendable { let id: String; let kind: String; let path: String }
    struct Tree: Equatable, Sendable {
        var files: [String: Entry]
        var folders: [String: String]
    }
    struct Plan: Sendable {
        let local: [String: Data]
        let remote: [String: Data]
        let result: [String: Data]
        let uploads: [String]
        let deletions: [String]
        let downloads: [String]
        let removals: [String]
        var changes: Bool { !uploads.isEmpty || !deletions.isEmpty || !downloads.isEmpty || !removals.isEmpty }
    }
    enum Failure: LocalizedError {
        case conflict(String), stale, invalid, uncertain, recovery(String)
        var errorDescription: String? {
            switch self {
            case .conflict(let path): return "Both sides changed “\(path)”. Both versions are saved in Live recovery."
            case .stale: return "Project files changed during sync. Reconnect to check the latest versions."
            case .invalid: return "Live file sync supports ordinary project files up to 30 MB each and 100 MB in total."
            case .uncertain: return "A file operation was not confirmed. Reconnect to check Overleaf before trying again."
            case .recovery(let path): return "File sync needs review. Your copies are saved at \(path)."
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
    static func tree(_ value: OverleafLiveWire.JSON, project: String) throws -> Tree {
        guard value["_id"].string == project else { throw Failure.invalid }
        var files: [String: Entry] = [:], folders: [String: String] = [:], ids = Set<String>(), names = Set<String>()
        func identity(_ value: OverleafLiveWire.JSON) throws -> String {
            guard let id = value.string, id.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil, ids.insert(id).inserted else { throw Failure.invalid }; return id
        }
        func walk(_ node: OverleafLiveWire.JSON, path: String, depth: Int) throws {
            guard depth < 32, files.count + folders.count < 10_000 else { throw Failure.invalid }
            folders[path] = try identity(node["_id"])
            for (key, kind) in [("docs", "doc"), ("fileRefs", "file")] {
                for item in node[key].array ?? [] {
                    guard let name = item["name"].string else { throw Failure.invalid }
                    if name.hasPrefix(".") { continue }
                    let full = path.isEmpty ? name : path + "/" + name
                    // Hidden metadata is not published by the local editor.
                    guard validPath(full), names.insert(full.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw Failure.invalid }
                    files[full] = Entry(id: try identity(item["_id"]), kind: kind, path: full)
                    guard files.count + folders.count <= 10_000 else { throw Failure.invalid }
                }
            }
            for child in node["folders"].array ?? [] {
                guard let name = child["name"].string else { throw Failure.invalid }
                if name.hasPrefix(".") { continue }
                let full = path.isEmpty ? name : path + "/" + name
                guard validPath(full), names.insert(full.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw Failure.invalid }
                try walk(child, path: full, depth: depth + 1)
            }
        }
        let roots = value["rootFolder"].array ?? [value["rootFolder"]]
        guard roots.count == 1 else { throw Failure.invalid }
        try walk(roots[0], path: "", depth: 0)
        return Tree(files: files, folders: folders)
    }
    static func archive(_ data: Data, tree: Tree) throws -> [String: Data] {
        let archive = try WordArchive(data)
        var result: [String: Data] = [:], total = 0
        for item in archive.entries where !item.name.hasSuffix("/") {
            // Ignore server metadata only when absent from the advertised editor tree.
            guard tree.files[item.name] != nil else { continue }
            guard validPath(item.name), result[item.name] == nil else { throw Failure.invalid }
            let bytes = try archive.read(item.name); total += bytes.count
            guard bytes.count <= fileLimit, total <= byteLimit else { throw Failure.invalid }
            result[item.name] = bytes
        }
        guard Set(result.keys) == Set(tree.files.keys) else { throw Failure.stale }
        return result
    }
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
    /// Same digest as fingerprint(scan(root), assetsOnly: true), without retaining file bytes.
    static func fingerprintAssets(at root: URL) throws -> String {
        var hash = SHA256()
        for file in try files(at: root).sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            hash.update(data: Data(file.path.utf8)); hash.update(data: Data([0]))
            guard !source(file.path) else { continue }
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            var read = 0
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                read += chunk.count; guard read <= file.size else { throw Failure.stale }
                hash.update(data: chunk)
            }
            guard read == file.size else { throw Failure.stale }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ files: [String: Data], assetsOnly: Bool = false) -> String {
        var hash = SHA256()
        for path in files.keys.sorted() {
            hash.update(data: Data(path.utf8)); hash.update(data: Data([0]))
            if !assetsOnly || !source(path) { hash.update(data: files[path]!) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func plan(base: [String: Data], local: [String: Data], remote: [String: Data], joinedText: Set<String>) throws -> Plan {
        var result: [String: Data] = [:]
        for path in Set(base.keys).union(local.keys).union(remote.keys).sorted() {
            let b = base[path], l = local[path], r = remote[path]
            if joinedText.contains(path), l != nil, r != nil { result[path] = l; continue }
            if l == r { result[path] = l }
            else if l == b { result[path] = r }
            else if r == b { result[path] = l }
            else { throw Failure.conflict(path) }
        }
        let active = joinedText.filter { local[$0] != nil && remote[$0] != nil }
        let paths = Set(result.keys).union(local.keys).union(remote.keys).subtracting(active)
        return Plan(local: local, remote: remote, result: result,
                    uploads: paths.filter { result[$0] != nil && result[$0] != remote[$0] }.sorted(),
                    deletions: paths.filter { result[$0] == nil && remote[$0] != nil }.sorted(),
                    downloads: paths.filter { result[$0] != nil && result[$0] != local[$0] }.sorted(),
                    removals: paths.filter { result[$0] == nil && local[$0] != nil }.sorted())
    }
    static func save(_ files: [String: Data], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(files).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load(_ url: URL) throws -> [String: Data] {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= byteLimit * 2 else { throw Failure.invalid }
        let result = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
        guard result.count <= 10_000, result.allSatisfy({ validPath($0.key) && $0.value.count <= fileLimit }), result.values.reduce(0, { $0 + $1.count }) <= byteLimit else { throw Failure.invalid }
        return result
    }
}
