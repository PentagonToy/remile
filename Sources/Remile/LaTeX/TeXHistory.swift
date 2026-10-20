import Foundation
import CryptoKit

enum TeXHistory {
    struct Revision: Codable, Identifiable {
        var id = UUID()
        var date = Date()
        let file: String
        let source: String
        var marker: String? = nil
    }
    static var intervalMinutes: Int { min(30, max(1, UserDefaults.standard.object(forKey: "latex.historyMinutes") as? Int ?? 3)) }
    static func retained(_ revisions: [Revision]) -> [Revision] {
        var bytes = 0
        return Array(revisions.prefix(50)).filter { item in bytes += item.source.utf8.count; return bytes <= 16_000_000 }
    }
    static func directory(_ root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/EditorHistory/" + key)
    }
    static func read(_ root: URL) -> [Revision] {
        let folder = directory(root)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])) ?? []).filter { $0.pathExtension == "json" }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = 0
        return urls.prefix(50).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), values.isSymbolicLink != true, let size = values.fileSize, size <= 8_100_000, total + size <= 16_000_000 else { return nil }
            total += size
            return try? JSONDecoder().decode(Revision.self, from: Data(contentsOf: url))
        }.sorted { $0.date > $1.date }
    }
    static func substantial(_ before: String, _ after: String) -> Bool {
        let a = Array(before.utf16), b = Array(after.utf16)
        var head = 0, tail = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        while tail < min(a.count, b.count) - head, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
        return max(a.count, b.count) - head - tail >= 24
    }
    static func clearAll() throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/EditorHistory")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    }
    @discardableResult static func record(root: URL, file: String, source: String, marker: String? = nil, previous cached: [Revision]? = nil) throws -> Revision? {
        guard source.utf8.count <= 4_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        let previous = cached ?? read(root)
        guard marker != nil || previous.first(where: { $0.file == file })?.source != source else { return nil }
        let folder = directory(root); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let revision = Revision(file: file, source: source, marker: marker)
        try JSONEncoder().encode(revision).write(to: folder.appendingPathComponent(revision.id.uuidString + ".json"), options: .atomic)
        // Keep bounded local text history; the project itself is never pruned.
        let retainedNames = Set(retained([revision] + previous).map { $0.id.uuidString + ".json" })
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" && !retainedNames.contains(file.lastPathComponent) && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil { try FileManager.default.removeItem(at: file) }
        return revision
    }
}

struct TeXOutlineItem: Identifiable {
    let id: Int
    let title: String
    let level: Int
    static func parse(_ source: String) -> [Self] {
        let pattern = try! NSRegularExpression(pattern: #"^\s*\\(part|chapter|section|subsection|subsubsection|paragraph)\*?(?:\[[^\]]*\])?\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}"#)
        let levels = ["part": 0, "chapter": 0, "section": 0, "subsection": 1, "subsubsection": 2, "paragraph": 3]
        return source.components(separatedBy: .newlines).enumerated().compactMap { line, text in
            let ns = text as NSString
            guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let title = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: #"\\[a-zA-Z]+|[{}]"#, with: "", options: .regularExpression)
            return Self(id: line, title: title, level: levels[ns.substring(with: match.range(at: 1))] ?? 0)
        }
    }
}
