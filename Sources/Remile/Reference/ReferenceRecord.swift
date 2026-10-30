import Foundation

struct ReferenceAttachment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var sha256: String
    var bytes: Int
    var previousIDs: [UUID]? = nil
    func matches(_ value: UUID) -> Bool { id == value || previousIDs?.contains(value) == true }
    var relativePath: String { "Attachments/\(id.uuidString).pdf" }
}

struct ReferenceRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var revision: UUID = UUID()
    var key: String = ""
    var citationKeyLocked: Bool?
    var type: String = "article"
    var fields: [String: String] = [:]
    var attachments: [ReferenceAttachment] = []
    var originalCitation: String = ""
    var originalKey: String?
    var remarkable: RemarkableReference?
    var zotero: ZoteroReference?
    var linkedReferences: [UUID]?
    var disconnectedReferences: [UUID]?
    var detachedPDFs: [String]?
    var libraryID: UUID?
    var collectionID: UUID?
    var created = Date()
    var modified = Date()
    var trashed: Date?
    var title: String { fields["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled reference" }
    var authors: String { fields["author"] ?? "" }
    var editors: String { fields["editor"] ?? "" }
    var usesEditors: Bool { authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !editors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var contributors: String { usesEditors ? editors : authors }
    var year: String { fields["year"] ?? "" }
    var citationKey: String { key.isEmpty ? "ref" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12) : key }
    var searchText: String { ([citationKey, displayTitle, displayAuthors] + Array(fields.values)).joined(separator: " ") }
}

struct ReferenceFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct RemarkableReference: Codable, Equatable, Sendable {
    var id: String
    var revision: String
    var title: String
    var fileType: String
    var attachmentID: UUID? = nil
    var generatedKey: String? = nil
    var sha256: String? = nil
    var created: Date? = nil
    var item: RemarkableCloudItem {
        RemarkableCloudItem(id: id, title: title, revision: revision, fileType: fileType)
    }
}

struct ZoteroReference: Codable, Equatable, Sendable {
    var source: String
    var version: Int?
    var files: [ZoteroReferenceFile] = []
    var mergedSources: [ZoteroReference]? = nil
    var sources: [ZoteroReference] {
        var primary = self
        primary.mergedSources = nil
        return [primary] + (mergedSources ?? [])
    }
}
struct ZoteroReferenceFile: Codable, Equatable, Sendable {
    var key: String
    var attachment: UUID
    var sha256: String
    var sourceVersion: Int? = nil
    var sourceBytes: Int? = nil
    var sourceModified: Date? = nil
}
