import Foundation

/// Keep the legacy path so removing an old account also removes its source baseline.
enum OverleafSourceArchive {
    static func baseline(_ id: UUID, under library: URL) -> URL { library.appendingPathComponent("LiveSources/" + id.uuidString + ".json") }
}
