import Foundation
import PDFKit

/// Small, on-demand evidence records. PDF bytes and extracted documents are never persisted here.
struct ReferencePassage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    let reference: UUID
    let attachment: UUID
    let sha256: String
    let page: Int
    let start: Int
    let length: Int
    let text: String
    let created: Date
}

enum ReferencePassages {
    static func list(recordID: UUID, repository: ReferenceRepository = ReferenceRepository()) throws -> [ReferencePassage] {
        try snapshot(recordID: recordID, repository: repository).passages
    }
    static func snapshot(recordID: UUID, repository: ReferenceRepository = ReferenceRepository()) throws -> (record: ReferenceRecord, passages: [ReferencePassage]) {
        guard let record = try ReferenceEvidence.active(repository).first(where: { $0.id == recordID }) else { throw ReferenceFailure("This reference is no longer available.") }
        return (record, try read(recordID: recordID, repository: repository))
    }
    private static func file(_ id: UUID, _ repository: ReferenceRepository) -> URL { repository.root.appendingPathComponent("Passages/" + id.uuidString + ".json") }
    private static func read(recordID: UUID, repository: ReferenceRepository) throws -> [ReferencePassage] {
        let url = file(recordID, repository)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000 else { throw ReferenceFailure("Saved passages could not be read.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000 else { throw ReferenceFailure("Saved passages could not be read.") }
        let saved = try JSONDecoder().decode([ReferencePassage].self, from: data)
        guard saved.count <= 200, saved.allSatisfy({ $0.reference == recordID && $0.page > 0 && $0.start >= 0 && $0.length > 0 && $0.text.utf16.count == $0.length && $0.length <= 4000 }) else { throw ReferenceFailure("Saved passages could not be read.") }
        return saved
    }
    static func save(recordID: UUID, attachmentID: UUID, expectedSHA256: String, page: Int, range: NSRange, repository: ReferenceRepository = ReferenceRepository()) throws -> ReferencePassage {
        let loaded = try ReferenceEvidence.attachment(recordID: recordID, attachmentID: attachmentID, repository: repository)
        guard loaded.attachment.sha256 == expectedSHA256 else { throw ReferenceFailure("The PDF changed. Open the source again.") }
        guard let document = PDFDocument(data: loaded.data), !document.isLocked, document.allowsCopying, page > 0, page <= document.pageCount, let text = document.page(at: page - 1)?.string else { throw ReferenceFailure("Choose text on a readable PDF page.") }
        let raw = text as NSString
        guard range.location >= 0, range.length > 0, range.length <= 4000, range.location <= raw.length, range.length <= raw.length - range.location, Range(range, in: text) != nil else { throw ReferenceFailure("Select up to 4,000 characters on one page.") }
        let quote = raw.substring(with: range)
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReferenceFailure("Select a passage first.") }
        let passage = ReferencePassage(id: UUID(), reference: recordID, attachment: attachmentID, sha256: expectedSHA256, page: page, start: range.location, length: range.length, text: quote, created: Date())
        return try repository.withLibraryLock {
            try Task.checkCancellation()
            guard let current = try ReferenceEvidence.active(repository).first(where: { $0.id == recordID }), current.revision == loaded.record.revision, current.attachments.contains(where: { $0.matches(attachmentID) && $0.sha256 == expectedSHA256 }) else { throw ReferenceFailure("The reference changed. Open the source again.") }
            var saved = try read(recordID: recordID, repository: repository)
            if let existing = saved.first(where: { $0.attachment == attachmentID && $0.sha256 == expectedSHA256 && $0.page == page && $0.start == range.location && $0.length == range.length }) { return existing }
            guard saved.count < 200 else { throw ReferenceFailure("This reference already has 200 saved passages.") }
            saved.append(passage)
            let data = try JSONEncoder().encode(saved)
            guard data.count <= 2_000_000 else { throw ReferenceFailure("Saved passages are full.") }
            let url = file(recordID, repository)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            return passage
        }
    }
    static func payload(_ passage: ReferencePassage) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(passage)) as? [String: Any] ?? [:]
    }
}
