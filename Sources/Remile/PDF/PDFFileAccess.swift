import AppKit

/// File metadata gates reads when a visible PDF regains focus.
enum PDFFileAccess {
    struct Version: Equatable, Sendable {
        let modified: Date?
        let size: UInt64
        let inode: UInt64

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    struct Snapshot: Sendable {
        let version: Version
        let data: Data
    }

    static func read(_ url: URL, since previous: Version?) throws -> Snapshot? {
        try Task.checkCancellation()
        let version = try Version(url)
        guard version != previous else { return nil }
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        guard try Version(url) == version else { throw CocoaError(.fileReadUnknown) }
        return Snapshot(version: version, data: data)
    }

    struct Application: Identifiable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    @MainActor static func applications(for url: URL) -> [Application] {
        var identifiers = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { application in
            let identifier = Bundle(url: application)?.bundleIdentifier ?? application.path
            guard identifier != "local.remile.app", identifier != Bundle.main.bundleIdentifier, identifiers.insert(identifier).inserted else { return nil }
            return Application(url: application, name: application.deletingPathExtension().lastPathComponent)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
