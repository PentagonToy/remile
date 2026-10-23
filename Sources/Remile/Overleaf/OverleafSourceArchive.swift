import Foundation

/// A source snapshot and private merge base, independent of the Premium Git service.
enum OverleafSourceArchive {
    enum Failure: LocalizedError {
        case invalid, download, baseline
        var errorDescription: String? {
            switch self {
            case .invalid: return "This source archive is too large or contains unsupported files."
            case .download: return "Could not download project sources. Check the connection and try again."
            case .baseline: return "The saved Live baseline is unavailable. Your local work is preserved."
            }
        }
    }
    static func baseline(_ id: UUID, under library: URL) -> URL { library.appendingPathComponent("LiveSources/" + id.uuidString + ".json") }
    static func install(_ data: Data, at root: URL, baseline: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.path), !manager.fileExists(atPath: baseline.path) else { throw Failure.invalid }
        let sources = try TeXSourceArchive.extract(data, at: root, requireClass: true)
        do {
            try manager.createDirectory(at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(sources).write(to: baseline, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: baseline.path)
        } catch { try? manager.removeItem(at: root); throw error }
    }
    static func sources(from baseline: URL) throws -> [String: String] {
        guard (try? baseline.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= 100 * 1024 * 1024,
              let bytes = try? Data(contentsOf: baseline), let sources = try? JSONDecoder().decode([String: String].self, from: bytes), sources.count <= 1_000 else { throw Failure.baseline }
        return sources
    }
}
