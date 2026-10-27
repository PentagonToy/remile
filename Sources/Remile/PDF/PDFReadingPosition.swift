import Foundation

/// Small per-file reading markers, independent of document bytes and attachments.
enum PDFReadingPosition {
    struct Marker: Codable {
        let page: Int
        let x: Double
        let y: Double
        let updated: Date
    }
    private static let preference = "pdf.readingPositions"
    static func read(_ url: URL, defaults: UserDefaults = .standard) -> Marker? {
        markers(defaults)[key(url)]
    }
    static func save(_ marker: Marker, for url: URL, defaults: UserDefaults = .standard) {
        guard marker.page >= 0, marker.x.isFinite, marker.y.isFinite else { return }
        var values = markers(defaults)
        values[key(url)] = marker
        if values.count > 512 {
            values = Dictionary(uniqueKeysWithValues: values.sorted { $0.value.updated > $1.value.updated }.prefix(512).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: preference) }
    }
    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    private static func markers(_ defaults: UserDefaults) -> [String: Marker] {
        guard let data = defaults.data(forKey: preference) else { return [:] }
        return (try? JSONDecoder().decode([String: Marker].self, from: data)) ?? [:]
    }
}
