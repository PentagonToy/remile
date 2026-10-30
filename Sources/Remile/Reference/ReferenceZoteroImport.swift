import Foundation
import CryptoKit
import PDFKit

struct ZoteroImportEntry: Sendable {
    var record: ReferenceRecord
    var files: [URL]
    var fileKeys: [String] = []
    var fileVersions: [Int] = []
}

extension ReferenceRepository {
    /// Explicit local copies. Zotero is never written, and earlier imports stay independent.
    @discardableResult func importZotero(_ scope: ZoteroScope, entries: [ZoteroImportEntry], updating libraryID: UUID? = nil) throws -> UUID {
        guard (!entries.isEmpty || libraryID != nil), entries.count <= 10000 else { throw ReferenceFailure("Choose a Zotero source with up to 10,000 references.") }
        var created: [URL] = []
        do {
            return try catalogueTransaction { catalogue in
                var libraries = catalogue.libraries ?? [.primary]
                let provenance = "zotero-import:" + scope.id
                let library: ReferenceLibrary
                if let libraryID {
                    guard let existing = libraries.first(where: { $0.id == libraryID && $0.source == provenance && $0.trashed == nil }) else { throw ReferenceFailure("This Zotero library changed. Select it again.") }
                    library = existing
                } else if let existing = libraries.first(where: { $0.source == provenance && $0.trashed == nil }) { library = existing }
                else {
                    library = ReferenceLibrary(name: String((scope.collection?.name ?? scope.library.name).prefix(80)), source: provenance, zoteroScope: scope)
                    libraries.append(library); catalogue.libraries = libraries
                }
                if let index = libraries.firstIndex(where: { $0.id == library.id }), libraries[index].zoteroScope == nil {
                    libraries[index].zoteroScope = scope; catalogue.libraries = libraries
                }
                let hidden = Set(libraries.filter { $0.trashed != nil }.map(\.id))
                var keys = Set(catalogue.records.filter { $0.library == library.id }.map { $0.citationKey.lowercased() })
                var filesByHash = Dictionary(grouping: catalogue.records.flatMap(\.attachments), by: \.sha256)
                var bySource: [String: [Int]] = [:]
                for (index, record) in catalogue.records.enumerated() where record.library == library.id {
                    let sources = record.zotero?.sources.map(\.source) ?? [record.fields["zoterosource"] ?? ""]
                    for source in Set(sources) where !source.isEmpty { bySource[source, default: []].append(index) }
                }
                for entry in entries {
                    try Task.checkCancellation()
                    guard entry.files.count <= 100, entry.fileKeys.isEmpty || entry.fileKeys.count == entry.files.count, entry.fileVersions.isEmpty || entry.fileVersions.count == entry.files.count else { throw ReferenceFailure("This Zotero reference has invalid PDF sources.") }
                    let source = entry.record.zotero?.source ?? entry.record.fields["zoterosource"] ?? ""
                    let known = libraryID == nil ? [] : (bySource[source] ?? [])
                    let active = known.filter { catalogue.records[$0].trashed == nil && catalogue.records[$0].collectionID.map(hidden.contains) != true }
                    // A local Trash action is retained, even if the item still exists in Zotero.
                    if !known.isEmpty && active.isEmpty { continue }
                    let destinations: [Int?] = active.isEmpty ? [nil] : active.map(Optional.some)
                    for index in destinations {
                        let before = index.map { catalogue.records[$0] }
                        var record = before ?? entry.record
                        if before == nil {
                            record.id = UUID(); record.revision = UUID(); record.libraryID = library.id; record.collectionID = nil
                            record.attachments = []; record.remarkable = nil; record.linkedReferences = nil
                            record.citationKeyLocked = nil; record.created = Date(); record.modified = Date(); record.trashed = nil
                            let candidate = entry.record.key
                            let base = !candidate.isEmpty && ReferenceBibTeX.validToken(candidate) ? candidate : citationKeyRule.key(for: record)
                            var key = base, suffix = 2
                            while !keys.insert(key.lowercased()).inserted { key = base + "_" + String(suffix); suffix += 1 }
                            record.key = key
                        } else {
                            for (field, value) in entry.record.fields where !value.isEmpty && record.fields[field]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { record.fields[field] = value }
                        }
                        var origin = record.zotero?.sources.first { $0.source == source } ?? entry.record.zotero
                        if origin == nil, !source.isEmpty { origin = ZoteroReference(source: source, version: nil) }
                        if let version = entry.record.zotero?.version { origin?.version = version }
                        var tracked = origin?.files ?? []
                        for (offset, file) in entry.files.enumerated() {
                            try Task.checkCancellation()
                            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                            guard file.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
                                (values.fileSize ?? Int.max) <= 200_000_000 else { throw ReferenceFailure("Choose a local Zotero PDF smaller than 200 MB.") }
                            let fileKey = entry.fileKeys.isEmpty ? String(offset) : entry.fileKeys[offset]
                            let fileVersion = entry.fileVersions.isEmpty ? nil : entry.fileVersions[offset]
                            let previous = tracked.first { $0.key == fileKey }
                            if let previous, let version = fileVersion, previous.sourceVersion == version,
                                previous.sourceBytes == values.fileSize, let date = values.contentModificationDate, previous.sourceModified == date {
                                continue
                            }
                            let data = try Data(contentsOf: file, options: .mappedIfSafe)
                            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw ReferenceFailure("A Zotero PDF could not be opened.") }
                            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                            let local = previous.flatMap { previous in record.attachments.first { $0.matches(previous.attachment) } }
                            if previous?.sha256 == hash, local == nil { continue }
                            var attachment: ReferenceAttachment
                            if let same = record.attachments.first(where: { $0.sha256 == hash && (try? Data(contentsOf: attachmentURL($0), options: .mappedIfSafe)) == data }) { attachment = same }
                            else if let shared = (filesByHash[hash] ?? []).first(where: { (try? Data(contentsOf: attachmentURL($0), options: .mappedIfSafe)) == data }) { attachment = shared }
                            else {
                                attachment = ReferenceAttachment(name: file.lastPathComponent, sha256: hash, bytes: data.count)
                                let url = attachmentURL(attachment)
                                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                                try data.write(to: url, options: .withoutOverwriting); created.append(url)
                                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                            }
                            if let previous, let local, local.id != attachment.id,
                                !tracked.contains(where: { $0.key != fileKey && local.matches($0.attachment) }),
                                local.sha256 == previous.sha256, try managedAttachmentUnchanged(local, expected: previous.sha256) {
                                record.attachments.removeAll { $0.id == local.id }
                                catalogue.garbage = (catalogue.garbage ?? []) + [local]
                            }
                            if !record.attachments.contains(where: { $0.id == attachment.id }) { record.attachments.append(attachment) }
                            if !(filesByHash[hash] ?? []).contains(where: { $0.id == attachment.id }) { filesByHash[hash, default: []].append(attachment) }
                            tracked.removeAll { $0.key == fileKey }
                            tracked.append(ZoteroReferenceFile(key: fileKey, attachment: attachment.id, sha256: hash, sourceVersion: fileVersion, sourceBytes: values.fileSize, sourceModified: values.contentModificationDate))
                        }
                        origin?.files = tracked
                        if var primary = record.zotero, primary.source != source, let origin {
                            var sources = primary.mergedSources ?? []
                            sources.removeAll { $0.source == source }; sources.append(origin)
                            primary.mergedSources = sources
                            record.zotero = primary
                        } else {
                            origin?.mergedSources = record.zotero?.mergedSources
                            record.zotero = origin
                        }
                        if let index {
                            if record != before { record.revision = UUID(); record.modified = Date(); catalogue.records[index] = record }
                        } else {
                            if !source.isEmpty { bySource[source, default: []].append(catalogue.records.count) }
                            catalogue.records.append(record)
                        }
                    }
                }
                return library.id
            }
        } catch { for file in created { try? FileManager.default.removeItem(at: file) }; throw error }
    }
    func managedAttachmentUnchanged(_ attachment: ReferenceAttachment, expected: String) throws -> Bool {
        let url = attachmentURL(attachment)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 200_000_000,
            let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected
    }

}

enum ReferenceSourceIdentity {
    private static func doi(_ record: ReferenceRecord) -> String? {
        for field in ["doi", "url"] {
            let value = ReferenceDuplicates.normaliseDOI(record.fields[field] ?? "")
            if value.range(of: #"^10\.[0-9]{4,9}/\S+$"#, options: .regularExpression) != nil { return value }
        }
        return nil
    }
    static func identifiers(_ record: ReferenceRecord) -> [String] {
        var values: [String] = []
        if let doi = doi(record) { values.append("doi:" + doi) }
        if let arxiv = ReferenceRecognition.archiveID(record) { values.append("arxiv:" + ReferenceArxiv.base(arxiv)) }
        return values
    }
    static func samePaper(_ lhs: ReferenceRecord, _ rhs: ReferenceRecord) -> Bool {
        if let a = doi(lhs), let b = doi(rhs) { return a == b }
        if let a = ReferenceRecognition.archiveID(lhs), let b = ReferenceRecognition.archiveID(rhs) { return ReferenceArxiv.base(a) == ReferenceArxiv.base(b) }
        return false
    }
}
