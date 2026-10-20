import Foundation

/// Only disposable UUID build folders are managed here. Projects and history are separate.
enum TeXCache {
    static var root: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app") }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = Set<URL>()
    static func allocate(_ category: String) -> URL {
        let url = root.appendingPathComponent(category + "/" + UUID().uuidString)
        lock.lock(); active.insert(url); lock.unlock()
        return url
    }
    static func discard(_ url: URL?) {
        guard let url else { return }
        lock.lock(); defer { lock.unlock() }
        guard active.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
    static func prune(at root: URL = root, now: Date = Date(), budget: Int = 512 * 1024 * 1024) {
        let manager = FileManager.default
        var entries: [(url: URL, date: Date, bytes: Int)] = []
        for category in ["LaTeX", "Submission", "Exports"] {
            let urls = (try? manager.contentsOfDirectory(at: root.appendingPathComponent(category), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
            for url in urls where UUID(uuidString: url.lastPathComponent) != nil {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                var bytes = 0
                if let files = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                    for case let file as URL in files {
                        let item = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                        if item?.isSymbolicLink == true { files.skipDescendants(); continue }
                        bytes += item?.fileSize ?? 0
                    }
                }
                entries.append((url, values.contentModificationDate ?? .distantPast, bytes))
            }
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for item in entries.sorted(by: { $0.date < $1.date }) where total > budget || now.timeIntervalSince(item.date) > 7 * 86400 {
            lock.lock()
            if !active.contains(item.url) { do { try manager.removeItem(at: item.url); total -= item.bytes } catch { } }
            lock.unlock()
        }
    }
}
