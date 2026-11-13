import Foundation
import Darwin

enum LocalDocumentIDs {
    enum Kind: String, Codable, Sendable {
        case latex, markdown

        static func forRecent(_ url: URL) -> Self? {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .latex }
            switch url.pathExtension.lowercased() {
            case "tex": return .latex
            case "md", "markdown": return .markdown
            default: return nil
            }
        }

        fileprivate func contains(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            switch self {
            case .latex: return values?.isDirectory == true
            case .markdown:
                return values?.isRegularFile == true && ["md", "markdown"].contains(url.pathExtension.lowercased())
            }
        }
    }

    private struct Entry: Codable, Equatable {
        let bookmark: Data
        let kind: Kind

        func location() throws -> URL {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
            guard kind.contains(url) else { throw Failure("The local document is unavailable.") }
            return url
        }
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static var directory: URL {
        EditorBridge.directory.deletingLastPathComponent().appendingPathComponent("DocumentIDs", isDirectory: true)
    }

    static func parse(_ value: String) -> UUID? {
        value.hasPrefix("local:") ? UUID(uuidString: String(value.dropFirst(6))) : nil
    }

    static func register(_ source: URL, kind: Kind, directory: URL = directory) throws -> String {
        var url = source.resolvingSymlinksInPath().standardizedFileURL
        if kind == .latex, url.pathExtension.lowercased() == "tex",
           try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            url = url.deletingLastPathComponent()
        }
        guard kind.contains(url) else { throw Failure("Open the saved document before copying its ID.") }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appendingPathComponent("catalogue.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure("The document ID store is unavailable.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Failure("The document ID store is busy.") }

        var entries = try load(directory)
        let id = entries.first(where: {
            $0.value.kind == kind && (try? $0.value.location().path) == url.path
        })?.key ?? UUID().uuidString
        let entry = try Entry(bookmark: url.bookmarkData(options: .minimalBookmark), kind: kind)
        if entries[id] != entry {
            entries[id] = entry
            try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("catalogue.json"), options: .atomic)
        }
        return "local:" + id
    }

    static func resolve(_ reference: String, directory: URL = directory) throws -> (url: URL, kind: Kind) {
        guard let id = parse(reference), let entry = try load(directory)[id.uuidString] else {
            throw Failure("Use a local ID copied from remile.")
        }
        guard let url = try? entry.location() else { throw Failure("The local document is unavailable.") }
        return (url, entry.kind)
    }

    private static func load(_ directory: URL) throws -> [String: Entry] {
        let file = directory.appendingPathComponent("catalogue.json")
        do { return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileReadNoSuchFile.rawValue { return [:] }
    }
}
