import Foundation
import OSLog

/// Stores current review marks for a saved source. Anchor fingerprints contain no source text.
enum EditorEditMarks {
    private static let limit = 256
    private static let width = 24
    private static let base: UInt64 = 1_000_003
    private static let power = (1..<width).reduce(UInt64(1)) { result, _ in result &* base }
    private static let anchorLimit = 1_000_000

    struct Span: Codable, Equatable {
        let start: Int
        let length: Int
        init(_ range: NSRange) { start = range.location; length = range.length }
        func range(within count: Int) -> NSRange? {
            guard start >= 0, start <= count, length > 0, length <= count - start else { return nil }
            return NSRange(location: start, length: length)
        }
    }
    struct Anchor: Codable, Equatable {
        let fingerprint: UInt64
        let digest: String
        let span: Span
    }
    struct Snapshot: Codable, Equatable {
        var version = 1
        let digest: String
        let ranges: [Span]
        let anchors: [Anchor]

        init(source: String, ranges: [NSRange]) {
            digest = SourceDigest.sha256(source)
            let count = source.utf16.count
            self.ranges = ranges.suffix(limit).map(Span.init)
            guard !ranges.isEmpty, (width...anchorLimit).contains(count) else { anchors = []; return }
            let units = Array(source.utf16)
            let marked = self.ranges.compactMap { $0.range(within: count) }
            var candidates: [Anchor] = []
            func add(_ start: Int, in range: NSRange) {
                let end = NSMaxRange(range)
                let length = min(width, end - start)
                let window = range.length >= width
                    ? min(start, end - width)
                    : min(count - width, max(0, start - (width - length) / 2))
                let slice = units[window..<(window + width)]
                candidates.append(Anchor(fingerprint: fingerprint(slice), digest: checksum(slice),
                                         span: Span(NSRange(location: start - window, length: length))))
            }
            for range in marked { add(range.location, in: range) }
            let remaining = max(1, limit - candidates.count)
            let markedLength = marked.reduce(0) { $0 + $1.length }
            let spacing = max(width, (markedLength + remaining - 1) / remaining)
            for range in marked where candidates.count < limit {
                for start in stride(from: range.location + spacing, to: NSMaxRange(range), by: spacing) {
                    add(start, in: range)
                    if candidates.count == limit { break }
                }
            }
            let positions = uniqueWindows(units, matching: Set(candidates.map(\.fingerprint)))
            anchors = candidates.filter { positions[$0.fingerprint, default: -1] >= 0 }
        }

        func restore(in source: String) -> [NSRange] {
            let count = source.utf16.count
            guard version == 1, ranges.count <= limit, anchors.count <= limit else { return [] }
            if SourceDigest.sha256(source) == digest { return ranges.compactMap { $0.range(within: count) } }
            guard !anchors.isEmpty, (width...anchorLimit).contains(count) else { return [] }
            let units = Array(source.utf16)
            let positions = uniqueWindows(units, matching: Set(anchors.map(\.fingerprint)))
            return EditorProvenance.merged(anchors.compactMap { anchor in
                guard let offset = positions[anchor.fingerprint], offset >= 0,
                      let span = anchor.span.range(within: width),
                      checksum(units[offset..<(offset + width)]) == anchor.digest else { return nil }
                return NSRange(location: offset + span.location, length: span.length)
            })
        }
    }

    private static func fingerprint(_ units: ArraySlice<UInt16>) -> UInt64 {
        units.reduce(0) { ($0 &* base) &+ UInt64($1) }
    }
    private static func checksum(_ units: ArraySlice<UInt16>) -> String {
        SourceDigest.sha256(String(decoding: units, as: UTF16.self))
    }
    private static func uniqueWindows(_ units: [UInt16], matching wanted: Set<UInt64>) -> [UInt64: Int] {
        guard !wanted.isEmpty, units.count >= width else { return [:] }
        var hash = fingerprint(units.prefix(width))
        var matches: [UInt64: Int] = [:]
        let last = units.count - width
        for offset in 0...last {
            if wanted.contains(hash) { matches[hash] = matches[hash] == nil ? offset : -1 }
            if offset < last {
                hash = ((hash &- (UInt64(units[offset]) &* power)) &* base) &+ UInt64(units[offset + width])
            }
        }
        return matches
    }

    struct Store {
        static let local = Store(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.remile.app/EditMarks", isDirectory: true))
        let directory: URL
        private static let logger = Logger(subsystem: "local.remile.app", category: "EditMarks")

        private func location(_ source: URL) -> URL {
            directory.appendingPathComponent(SourceDigest.sha256(source.standardizedFileURL.path) + ".json")
        }
        func read(for source: URL) -> Snapshot? {
            let url = location(source)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64_000 else { return nil }
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return nil
            }
            guard let data = try? Data(contentsOf: url), data.count <= 64_000 else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        func save(for source: URL, text: String, ranges: [NSRange]) {
            if ranges.isEmpty { remove(for: source); return }
            _ = write(Snapshot(source: text, ranges: ranges), for: source)
        }
        @discardableResult func write(_ snapshot: Snapshot, for source: URL) -> Bool {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(snapshot).write(to: location(source), options: .atomic)
                return true
            } catch { Self.logger.error("Could not save review marks."); return false }
        }
        func remove(for source: URL) {
            do { try FileManager.default.removeItem(at: location(source)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { Self.logger.error("Could not remove review marks.") }
        }
        func move(from source: URL, to destination: URL) {
            guard source.standardizedFileURL != destination.standardizedFileURL,
                  let snapshot = read(for: source), write(snapshot, for: destination) else { return }
            remove(for: source)
        }
    }

    struct Shared {
        let root: URL
        let machine: String
        let project: String

        var available: Bool {
            root.path == StorageLocation.support.path || FileManager.default.fileExists(atPath: root.appendingPathComponent("remile-storage.json").path)
        }
        private var directory: URL { root.appendingPathComponent(StorageLocation.overleafMarksFolder, isDirectory: true) }
        private func store(in device: URL) -> Store { Store(directory: device.appendingPathComponent(SourceDigest.sha256(project.lowercased()), isDirectory: true)) }
        private var own: Store { store(in: directory.appendingPathComponent(machine, isDirectory: true)) }
        private func key(_ file: String) -> URL { URL(fileURLWithPath: "/" + file) }

        func ownSnapshot(for file: String) -> Snapshot? { available ? own.read(for: key(file)) : nil }
        func save(_ snapshot: Snapshot, for file: String) {
            if available { own.write(snapshot, for: key(file)) }
        }
        func ranges(fromOtherMacsFor file: String, in source: String) -> [NSRange] {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            guard available, let devices = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                                          options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
            var ranges: [NSRange] = []
            for case let device as URL in devices.prefix(32) {
                let name = device.lastPathComponent
                guard name != machine, UUID(uuidString: name) != nil,
                      let values = try? device.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let snapshot = store(in: device).read(for: key(file)) else { continue }
                ranges = EditorProvenance.merged(ranges + snapshot.restore(in: source))
            }
            return ranges
        }
        func move(from file: String, to destination: String) {
            if available { own.move(from: key(file), to: key(destination)) }
        }
        func remove(_ file: String) {
            if available { own.remove(for: key(file)) }
        }
    }
}
