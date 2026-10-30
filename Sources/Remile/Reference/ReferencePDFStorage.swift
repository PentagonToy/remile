import Foundation
import CryptoKit
import Darwin

extension ReferenceRepository {
    func sharePaperPDFs() throws {
        try catalogueTransaction { catalogue in try sharePaperPDFs(in: &catalogue) }
    }
    /// Strong identifiers link files, never titles alone. Local fields and keys remain independent.
    func sharePaperPDFs(in catalogue: inout Catalogue) throws {
        let hidden = Set((catalogue.libraries ?? []).filter { $0.trashed != nil }.map(\.id))
        let active = catalogue.records.indices.filter {
            let record = catalogue.records[$0]
            return record.trashed == nil && !hidden.contains(record.library) && record.collectionID.map(hidden.contains) != true
        }
        var sources: [String: [Int]] = [:]
        for index in active where !catalogue.records[index].attachments.isEmpty {
            for identity in ReferenceSourceIdentity.identifiers(catalogue.records[index]) { sources[identity, default: []].append(index) }
        }
        var verified: [UUID: Bool] = [:]
        for index in active where catalogue.records[index].remarkable == nil && catalogue.records[index].attachments.isEmpty {
            let record = catalogue.records[index]
            let matches = Set(ReferenceSourceIdentity.identifiers(record).flatMap { sources[$0] ?? [] })
            let candidates = matches.filter { ReferenceSourceIdentity.samePaper(record, catalogue.records[$0]) }
                .sorted { catalogue.records[$0].id.uuidString < catalogue.records[$1].id.uuidString }
            var files: [ReferenceAttachment] = []
            for candidate in candidates {
                let source = catalogue.records[candidate]
                if source.remarkable != nil {
                    if source.disconnectedReferences?.contains(record.id) == true { continue }
                    var links = Set(source.linkedReferences ?? [])
                    if links.insert(record.id).inserted, links.count <= 100 {
                        catalogue.records[candidate].linkedReferences = links.sorted { $0.uuidString < $1.uuidString }
                        catalogue.records[candidate].revision = UUID()
                    }
                    continue
                }
                for file in source.attachments where record.detachedPDFs?.contains(file.sha256) != true {
                    if verified[file.id] == nil { verified[file.id] = (try? verifiedBytes(file)) != nil }
                    if verified[file.id] == true && !files.contains(where: { $0.sha256 == file.sha256 }) { files.append(file) }
                }
            }
            if !files.isEmpty {
                catalogue.records[index].attachments = Array(files.prefix(100))
                catalogue.records[index].revision = UUID()
            }
        }
    }
    /// APFS clones share disk blocks while retaining separate paths and independent edits.
    @discardableResult func optimisePDFs(library: UUID? = nil) throws -> Int {
        try withLibraryLock {
            let snapshot = try snapshot()
            let hidden = Set(snapshot.libraries.filter { $0.trashed != nil }.map(\.id))
            let active = snapshot.records.filter { $0.trashed == nil && !hidden.contains($0.library) && $0.collectionID.map(hidden.contains) != true }
            let selected = Set(active.filter { library == nil || $0.library == library || $0.collectionID == library }.flatMap(\.attachments).map(\.id))
            let files = Dictionary(active.flatMap(\.attachments).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            let groups = Dictionary(grouping: files, by: \.sha256).values.filter { $0.count > 1 }
            let cacheURL = root.appendingPathComponent("PDFSharing.json")
            var cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL))) ?? [:]
            let before = cache
            func stamp(_ file: ReferenceAttachment) -> String? {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: attachmentURL(file).path),
                      let inode = attrs[.systemFileNumber] as? NSNumber, let date = attrs[.modificationDate] as? Date,
                      let bytes = attrs[.size] as? NSNumber else { return nil }
                return file.sha256 + ":" + inode.stringValue + ":" + bytes.stringValue + ":" + String(date.timeIntervalSince1970)
            }
            var count = 0
            for group in groups {
                try Task.checkCancellation()
                let ordered = group.sorted { $0.id.uuidString < $1.id.uuidString }
                guard let original = ordered.first else { continue }
                let originalURL = attachmentURL(original)
                let pending = ordered.dropFirst().filter { duplicate in
                    guard selected.contains(duplicate.id) || selected.contains(original.id), let a = stamp(original), let b = stamp(duplicate) else { return false }
                    return cache[duplicate.id.uuidString] != a + ":" + b
                }
                guard !pending.isEmpty, let bytes = try? verifiedBytes(original) else { continue }
                for duplicate in pending {
                    try Task.checkCancellation()
                    guard (try? verifiedBytes(duplicate)) == bytes else { continue }
                    let destination = attachmentURL(duplicate)
                    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".clone-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard clonefile(originalURL.path, temporary.path, 0) == 0 else {
                        throw ReferenceFailure("This storage location cannot share PDF space. Existing files are unchanged.")
                    }
                    // Recheck immediately before replacement so a changed or missing PDF is skipped.
                    guard try verifiedBytes(duplicate) == bytes,
                          (try? Data(contentsOf: temporary, options: .mappedIfSafe)) == bytes else { continue }
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    try FileManager.default.setAttributes(attributes.filter { [.posixPermissions, .creationDate, .modificationDate].contains($0.key) }, ofItemAtPath: temporary.path)
                    guard Darwin.rename(temporary.path, destination.path) == 0 else { throw ReferenceFailure("Could not optimise this PDF. Try again.") }
                    if let a = stamp(original), let b = stamp(duplicate) { cache[duplicate.id.uuidString] = a + ":" + b }
                    count += 1
                }
            }
            let ids = Set(files.map { $0.id.uuidString })
            cache = cache.filter { ids.contains($0.key) }
            if cache != before { try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic) }
            return count
        }
    }
    /// Give an opened reference its own path before editing, retaining shared APFS blocks.
    @discardableResult func prepareAttachment(_ attachment: ReferenceAttachment, for record: ReferenceRecord) throws -> ReferenceAttachment {
        var created: URL?
        do {
            return try catalogueTransaction { catalogue in
                guard let index = catalogue.records.firstIndex(where: { $0.id == record.id && $0.revision == record.revision }),
                      catalogue.records[index].attachments.contains(attachment), catalogue.records[index].trashed == nil
                else { throw ReferenceFailure("The attachment changed. Select the reference again.") }
                let owners = catalogue.records.filter { $0.attachments.contains(where: { $0.id == attachment.id }) }
                guard owners.count > 1 else { return attachment }
                let source = attachmentURL(attachment)
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 200_000_000 else { throw ReferenceFailure("This PDF is unavailable.") }
                var separate = attachment
                separate.id = UUID()
                separate.previousIDs = Array(Set((attachment.previousIDs ?? []) + [attachment.id]))
                guard separate.previousIDs!.count <= 1000 else { throw ReferenceFailure("This PDF has too many earlier versions.") }
                let destination = attachmentURL(separate)
                if clonefile(source.path, destination.path, 0) != 0 { try FileManager.default.copyItem(at: source, to: destination) }
                created = destination
                catalogue.records[index].attachments = catalogue.records[index].attachments.map { $0.id == attachment.id ? separate : $0 }
                if catalogue.records[index].remarkable?.attachmentID == attachment.id { catalogue.records[index].remarkable?.attachmentID = separate.id }
                catalogue.records[index].revision = UUID()
                return separate
            }
        } catch { if let created { try? FileManager.default.removeItem(at: created) }; throw error }
    }
    private func verifiedBytes(_ file: ReferenceAttachment) throws -> Data? {
        let url = attachmentURL(file)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes, file.bytes <= 200_000_000 else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hash == file.sha256 ? data : nil
    }
}
