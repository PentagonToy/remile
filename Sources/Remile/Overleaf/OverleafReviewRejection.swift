import Foundation

/// A retry must clear the review marker without applying the inverse source edit twice.
struct OverleafReviewRejection: Codable {
    let originalHash: String
    let restoredHash: String

    static func location(_ change: OverleafReviewSnapshot.Change, root: URL) throws -> URL {
        let identity = change.documentID + ":" + change.changeID + ":" + (change.insertion ? "insert:" : "delete:") + change.text
        return try TeXFileSystem.url(".remile/review-rejections/" + SourceDigest.sha256(identity) + ".json", root: root)
    }
    static func prepare(_ change: OverleafReviewSnapshot.Change, root: URL, source: String) throws -> (receipt: Self, restored: String) {
        let url = try location(change, root: root)
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 2048 else { throw OverleafGit.Failure("Review recovery could not be read. Check this change in Overleaf.") }
            let data = try Data(contentsOf: url)
            guard data.count <= 2048 else { throw OverleafGit.Failure("Review recovery could not be read. Check this change in Overleaf.") }
            let receipt = try JSONDecoder().decode(Self.self, from: data)
            if SourceDigest.sha256(source) == receipt.restoredHash { return (receipt, source) }
            guard SourceDigest.sha256(source) == receipt.originalHash else { throw OverleafGit.Failure("Source changed after this rejection. Check the remaining suggestion in Overleaf.") }
            let restored = try change.rejectedSource()
            guard SourceDigest.sha256(restored) == receipt.restoredHash else { throw OverleafGit.Failure("This suggestion moved. Check it in Overleaf.") }
            return (receipt, restored)
        }
        let restored = try change.rejectedSource()
        let receipt = Self(originalHash: SourceDigest.sha256(source), restoredHash: SourceDigest.sha256(restored))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        return (receipt, restored)
    }
    static func needsResolution(_ change: OverleafReviewSnapshot.Change, ranges: Data) throws -> Bool {
        guard let document = try OverleafReviewSnapshot.documentRanges(ranges).first(where: { $0.id == change.documentID }) else { return false }
        let matches = (document.ranges["changes"] as? [[String: Any]] ?? []).filter { $0["id"] as? String == change.changeID }
        if matches.isEmpty { return false }
        guard matches.count == 1, let op = matches[0]["op"] as? [String: Any],
              op[change.insertion ? "i" : "d"] as? String == change.text,
              op[change.insertion ? "d" : "i"] == nil else { throw OverleafGit.Failure("This suggestion changed. Refresh the review.") }
        return true
    }
    static func finish(_ change: OverleafReviewSnapshot.Change, root: URL) throws {
        let url = try location(change, root: root)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
