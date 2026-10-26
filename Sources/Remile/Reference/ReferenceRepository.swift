import Foundation
import CryptoKit
import PDFKit
import Darwin

/// Shared by native views and command adapters. Only this service writes the catalogue.
struct ReferenceRepository: Sendable {
    private let configuredRoot: URL?
    var root: URL { configuredRoot ?? StoragePaths.reference() }
    private let keyRule: ReferenceKeyRule?
    private let history: History?
    private let readOnly: Bool
    init(root: URL? = nil, keyRule: ReferenceKeyRule? = nil, history: History? = nil, readOnly: Bool = false) { self.configuredRoot = root; self.keyRule = keyRule; self.history = history; self.readOnly = readOnly }
    fileprivate struct Catalogue: Codable { var schema = 1; var records: [ReferenceRecord] = []; var libraries: [ReferenceLibrary]?; var garbage: [ReferenceAttachment]? }
    func recordingHistory(_ history: History) -> Self { Self(root: configuredRoot, keyRule: keyRule, history: history, readOnly: readOnly) }
    func undo(redo: Bool = false) throws {
        guard let history else { return }
        try catalogueTransaction(historyMove: redo) { try history.apply(to: &$0, redo: redo, root: root) }
    }
    private var catalogue: URL { root.appendingPathComponent("library.json") }
    struct Version: Equatable, Sendable {
        let root: URL
        let modified: Date?
        let bytes: UInt64
        let inode: UInt64
    }
    /// A single file stat when completion is requested, never a directory scan or timer.
    func version() -> Version {
        let values = (try? FileManager.default.attributesOfItem(atPath: catalogue.path)) ?? [:]
        return Version(root: root, modified: values[.modificationDate] as? Date, bytes: (values[.size] as? NSNumber)?.uint64Value ?? 0, inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
    func requireStorage() throws { if configuredRoot == nil { try StoragePaths.requireAvailable(root) } }
    private func readCatalogue() throws -> Catalogue {
        try requireStorage()
        guard FileManager.default.fileExists(atPath: catalogue.path) else {
            if configuredRoot == nil && root.standardizedFileURL != StoragePaths.defaultReference.standardizedFileURL {
                throw ReferenceFailure("The library is not downloaded. Wait for folder sync, then try again.")
            }
            return Catalogue()
        }
        let values = try catalogue.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? Int.max) <= 32_000_000 else { throw ReferenceFailure("The reference library is too large to read.") }
        let stored = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: catalogue))
        guard stored.schema == 1 else { throw ReferenceFailure("This reference library needs a newer version of remile.") }
        try validate(stored.records)
        return stored
    }
    func snapshot() throws -> (records: [ReferenceRecord], libraries: [ReferenceLibrary]) {
        let stored = try readCatalogue()
        history?.observe(stored)
        return (stored.records, stored.libraries ?? [.primary])
    }
    func records() throws -> [ReferenceRecord] { try readCatalogue().records }
    func libraries() throws -> [ReferenceLibrary] { try readCatalogue().libraries ?? [.primary] }
    @discardableResult func addLibrary(_ name: String, parentID: UUID? = nil) throws -> ReferenceLibrary {
        try catalogueTransaction { catalogue in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var libraries = catalogue.libraries ?? [.primary]
            guard !name.isEmpty, name.count <= 80, !libraries.contains(where: { $0.parentID == parentID && $0.trashed == nil && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw ReferenceFailure("Use a new library name of up to 80 characters.") }
            if let parentID { guard libraries.contains(where: { $0.id == parentID && $0.parentID == nil && $0.trashed == nil }) else { throw ReferenceFailure("Choose an active library for this collection.") } }
            let library = ReferenceLibrary(name: name, parentID: parentID); libraries.append(library); catalogue.libraries = libraries; return library
        }
    }
    func reorderLibrary(_ id: UUID, before target: UUID) throws {
        try catalogueTransaction { catalogue in
            var libraries = catalogue.libraries ?? [.primary]
            guard id != target, let source = libraries.firstIndex(where: { $0.id == id }), libraries.contains(where: { $0.id == target }) else { return }
            let moved = libraries.remove(at: source)
            libraries.insert(moved, at: libraries.firstIndex(where: { $0.id == target })!)
            catalogue.libraries = libraries
        }
    }
    func deleteLibrary(_ id: UUID) throws {
        try catalogueTransaction { catalogue in
            var libraries = catalogue.libraries ?? [.primary]
            guard libraries.contains(where: { $0.id == id && $0.trashed == nil }) else { throw ReferenceFailure("The library is unavailable.") }
            for index in libraries.indices where libraries[index].id == id || libraries[index].parentID == id { libraries[index].trashed = Date() }
            if !libraries.contains(where: { $0.trashed == nil && $0.parentID == nil }) { libraries.append(ReferenceLibrary(name: "My library")) }
            catalogue.libraries = libraries
        }
    }
    func restoreLibrary(_ id: UUID) throws {
        try catalogueTransaction { catalogue in
            var libraries = catalogue.libraries ?? [.primary]
            guard let source = libraries.first(where: { $0.id == id }) else { throw ReferenceFailure("The library is unavailable.") }
            let root = source.parentID.flatMap { parent in libraries.first(where: { $0.id == parent && $0.trashed != nil })?.id } ?? id
            for index in libraries.indices where libraries[index].id == root || libraries[index].parentID == root { libraries[index].trashed = nil }
            catalogue.libraries = libraries
        }
    }
    /// Commit catalogue removal first. Only unreferenced managed PDFs are then removed.
    func emptyTrash() throws {
        defer { history?.clear() }
        let removed: [ReferenceAttachment] = try catalogueTransaction { catalogue in
            var libraries = catalogue.libraries ?? [.primary]
            let deleted = Set(libraries.filter { $0.trashed != nil }.map(\.id))
            let discarded = catalogue.records.filter { $0.trashed != nil || deleted.contains($0.library) || $0.collectionID.map(deleted.contains) == true }
            let discardedIDs = Set(discarded.map(\.id))
            let recovery = root.appendingPathComponent("Recovery")
            if FileManager.default.fileExists(atPath: recovery.path) {
                for url in try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                    let saved = try JSONDecoder().decode([ReferenceRecord].self, from: Data(contentsOf: url))
                    let kept = saved.filter { !discardedIDs.contains($0.id) }
                    if kept.count != saved.count {
                        if kept.isEmpty { try FileManager.default.removeItem(at: url) }
                        else { try JSONEncoder().encode(kept).write(to: url, options: .atomic) }
                    }
                }
            }
            catalogue.records.removeAll { $0.trashed != nil || deleted.contains($0.library) || $0.collectionID.map(deleted.contains) == true }
            libraries.removeAll { deleted.contains($0.id) }
            catalogue.libraries = libraries
            catalogue.garbage = (catalogue.garbage ?? []) + discarded.flatMap(\.attachments)
            return catalogue.garbage ?? []
        }
        try catalogueTransaction { catalogue in
            let retained = Set(catalogue.records.flatMap(\.attachments).map(\.id))
            for file in removed where !retained.contains(file.id) {
                let url = attachmentURL(file)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            catalogue.garbage = []
            let passages = root.appendingPathComponent("Passages")
            if FileManager.default.fileExists(atPath: passages.path) {
                let retainedRecords = Set(catalogue.records.map(\.id))
                for file in try FileManager.default.contentsOfDirectory(at: passages, includingPropertiesForKeys: nil) {
                    if file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !retainedRecords.contains(id) { try FileManager.default.removeItem(at: file) }
                }
            }
        }
    }
    func merge(_ snapshots: [ReferenceRecord], preferred: UUID, alignMetadata: Bool, resolvedFields: [String: String]? = nil) throws {
        try transaction { records in
            let versions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.revision) })
            let indices = records.indices.filter { versions[records[$0].id] != nil }
            guard versions[preferred] != nil, indices.count >= 2, indices.count == snapshots.count, indices.allSatisfy({ records[$0].trashed == nil && records[$0].revision == versions[records[$0].id] }),
                  let master = records.first(where: { $0.id == preferred }), let group = ReferenceDuplicates.lookup(records)[preferred], Set(versions.keys).isSubset(of: Set(group)) else { throw ReferenceFailure("The duplicate references changed. Review them again.") }
            let resolved = resolvedFields ?? ReferenceMergePlan.fields(snapshots, preferred: preferred)
            var discarded = Set<UUID>()
            let attachments = Dictionary(indices.flatMap { records[$0].attachments }.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id.uuidString < $1.id.uuidString }
            for (_, group) in Dictionary(grouping: indices, by: { records[$0].collectionID ?? records[$0].library }) {
                let library = records[group[0]].library
                let keep = group.first { records[$0].id == preferred } ?? group.min { records[$0].created < records[$1].created }!
                let before = records[keep]
                let notes = Array(Set(group.compactMap { records[$0].fields["note"] }.filter { !$0.isEmpty })).sorted().joined(separator: "\n\n")
                if alignMetadata || library == master.library { records[keep].fields = resolved; records[keep].type = master.type }
                else {
                    for index in group { for (key, value) in records[index].fields where records[keep].fields[key]?.isEmpty != false { records[keep].fields[key] = value } }
                }
                if !notes.isEmpty { records[keep].fields["note"] = notes }
                let key = uniqueKey(master.citationKey, in: records.filter { $0.library == library && $0.id != before.id })
                records[keep].key = key; records[keep].attachments = Array(attachments); records[keep].revision = UUID(); records[keep].modified = Date()
                var mapping: [String: String] = [:]
                for index in group { mapping[records[index].key] = key; if index != keep { discarded.insert(records[index].id) } }
                mapping[before.key] = key
                try rewriteRelations(&records, indices: records.indices.filter { records[$0].library == library && records[$0].trashed == nil }, mapping: mapping)
            }
            records.removeAll { discarded.contains($0.id) }
        }
    }
    func applyCleanup(_ changes: [ReferenceCleanup.Change]) throws {
        try transaction { records in
            for change in changes {
                guard let index = records.firstIndex(where: { $0.id == change.id }), records[index].revision == change.before.revision, records[index].trashed == nil else { throw ReferenceFailure("A reference changed. Run Clean up again before applying.") }
                _ = try destination(records[index].collectionID ?? records[index].library)
                records[index].fields = change.after.fields; records[index].type = change.after.type
                records[index].revision = UUID(); records[index].modified = Date()
            }
        }
    }
    func refreshAttachment(_ id: UUID) throws {
        try transaction(recordHistory: false) { records in
            guard let file = records.flatMap(\.attachments).first(where: { $0.id == id }) else { return }
            let url = attachmentURL(file)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 200_000_000 else { throw ReferenceFailure("This PDF is too large to update.") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard file.sha256 != sha else { return }
            for index in records.indices {
                var changed = false
                for item in records[index].attachments.indices where records[index].attachments[item].id == id { records[index].attachments[item].sha256 = sha; records[index].attachments[item].bytes = data.count; changed = true }
                if changed { records[index].modified = Date(); records[index].revision = UUID() }
            }
        }
    }
    /// Unlink only. Unshared managed bytes are collected by an explicit Empty Trash action.
    @discardableResult func removeAttachments(_ ids: Set<UUID>, from id: UUID, expected: UUID) throws -> ReferenceRecord {
        try catalogueTransaction { catalogue in
            guard !ids.isEmpty, let index = catalogue.records.firstIndex(where: { $0.id == id && $0.trashed == nil }), catalogue.records[index].revision == expected,
                  ids.isSubset(of: Set(catalogue.records[index].attachments.map(\.id))) else { throw ReferenceFailure("The attachments changed. Open the reference again.") }
            let record = catalogue.records[index], libraries = catalogue.libraries ?? [.primary]
            guard libraries.contains(where: { $0.id == record.library && $0.trashed == nil }), record.collectionID == nil || libraries.contains(where: { $0.id == record.collectionID && $0.trashed == nil }) else { throw ReferenceFailure("Restore the library before changing attachments.") }
            let removed = catalogue.records[index].attachments.filter { ids.contains($0.id) }
            catalogue.records[index].attachments.removeAll { ids.contains($0.id) }
            catalogue.records[index].revision = UUID(); catalogue.records[index].modified = Date()
            var pending = catalogue.garbage ?? []
            for file in removed where !pending.contains(where: { $0.id == file.id }) { pending.append(file) }
            catalogue.garbage = pending
            return catalogue.records[index]
        }
    }
    func attachmentURL(_ attachment: ReferenceAttachment) -> URL { root.appendingPathComponent(attachment.relativePath) }
    private func destination(_ id: UUID) throws -> ReferenceLibrary {
        guard let library = try libraries().first(where: { $0.id == id && $0.trashed == nil }) else { throw ReferenceFailure("Choose an active library.") }
        return library
    }
    @discardableResult func add(_ drafts: [ReferenceRecord], libraryID: UUID = ReferenceLibrary.primaryID) throws -> [ReferenceRecord] {
        let destination = try destination(libraryID)
        return try transaction { records in
            try append(drafts.map { var record = $0; record.libraryID = destination.parentID ?? destination.id; record.collectionID = destination.parentID == nil ? nil : destination.id; return record }, to: &records)
        }
    }
    @discardableResult func update(_ replacement: ReferenceRecord, expected: UUID) throws -> ReferenceRecord {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == replacement.id }), records[index].revision == expected else { throw ReferenceFailure("The reference changed. Open it again before saving.") }
            guard replacement.attachments == records[index].attachments, replacement.trashed == records[index].trashed, replacement.library == records[index].library, replacement.collectionID == records[index].collectionID else { throw ReferenceFailure("Use the attachment or Trash action for this change.") }
            var record = replacement; record.key = records[index].key; record.revision = UUID(); record.modified = Date()
            records[index] = record; return record
        }
    }
    @discardableResult func duplicate(_ id: UUID, to libraryID: UUID? = nil) throws -> ReferenceRecord {
        let target = try libraryID.map { try destination($0) }
        return try transaction { records in
            guard var copy = records.first(where: { $0.id == id && $0.trashed == nil }) else { throw ReferenceFailure("The reference is unavailable.") }
            copy.id = UUID(); copy.revision = UUID(); if let target { copy.libraryID = target.parentID ?? target.id; copy.collectionID = target.parentID == nil ? nil : target.id }; copy.key = uniqueKey((keyRule ?? .current).key(for: copy), in: records.filter { $0.library == copy.library })
            copy.created = Date(); copy.modified = Date(); records.append(copy); return copy
        }
    }
    func move(_ id: UUID, to collectionID: UUID?) throws {
        let target = try collectionID.map { try destination($0) }
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == id && $0.trashed == nil }), target == nil || target?.parentID == records[index].library else { throw ReferenceFailure("Choose a collection in this library.") }
            records[index].collectionID = target?.id; records[index].revision = UUID(); records[index].modified = Date()
        }
    }
    func trash(_ id: UUID, restore: Bool = false, expected: UUID? = nil) throws {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == id }), expected == nil || records[index].revision == expected else { throw ReferenceFailure("The reference changed. Read it again.") }
            records[index].trashed = restore ? nil : Date(); records[index].revision = UUID(); records[index].modified = Date()
        }
    }
    @discardableResult func regenerate(id: UUID? = nil, expected: UUID? = nil, libraryID: UUID? = nil, rule: ReferenceKeyRule) throws -> Int {
        let target = try libraryID.map { try destination($0) }
        let hidden = Set(try libraries().filter { $0.trashed != nil }.map(\.id))
        return try transaction { records in
            if let id {
                guard records.contains(where: { $0.id == id && $0.trashed == nil && $0.revision == expected }) else { throw ReferenceFailure("The reference changed. Select it again before regenerating its key.") }
            }
            let selected = records.indices.filter { records[$0].trashed == nil && (id == nil || records[$0].id == id) && (target == nil || records[$0].library == (target?.parentID ?? target?.id)) && (target?.parentID == nil || records[$0].collectionID == target?.id) && !hidden.contains(records[$0].library) && records[$0].collectionID.map(hidden.contains) != true }.sorted {
                if records[$0].created != records[$1].created { return records[$0].created < records[$1].created }
                return records[$0].id.uuidString < records[$1].id.uuidString
            }
            let ids = Set(selected.map { records[$0].id })
            var reserved = Dictionary(grouping: records.filter { !ids.contains($0.id) }, by: \.library).mapValues { Set($0.map { $0.citationKey.lowercased() }) }
            var mappings: [UUID: [String: String]] = [:], changed = 0
            for index in selected {
                let library = records[index].library
                let key = reserveKey(rule.key(for: records[index]), keys: &reserved[library, default: []])
                if key != records[index].key { mappings[library, default: [:]][records[index].key] = key; records[index].key = key; records[index].revision = UUID(); records[index].modified = Date(); changed += 1 }
            }
            for (library, mapping) in mappings { try rewriteRelations(&records, indices: records.indices.filter { records[$0].trashed == nil && records[$0].library == library }, mapping: mapping) }
            return changed
        }
    }
    /// Inputs are copied into managed storage. Originals and existing attachments are never replaced.
    @discardableResult func importFiles(_ urls: [URL], attachingTo target: UUID? = nil, expected: UUID? = nil, libraryID: UUID = ReferenceLibrary.primaryID, matchingExisting: Bool = false, rejectAmbiguous: Bool = false) throws -> [ReferenceRecord] {
        guard !urls.isEmpty, urls.count <= 100, urls.allSatisfy(\.isFileURL) else { throw ReferenceFailure("Choose up to 100 PDF or BibTeX files.") }
        let destinationLibrary = try destination(libraryID)
        var created: [URL] = []
        do {
            return try transaction { records in
                if let target {
                    guard let record = records.first(where: { $0.id == target && $0.trashed == nil }), record.revision == expected else { throw ReferenceFailure("The reference changed. Select it again before adding files.") }
                    guard urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) else { throw ReferenceFailure("Drop PDFs onto a reference. Import BibTeX into the library.") }
                }
                var imported: [ReferenceRecord] = [], total = 0
                for url in urls {
                    try Task.checkCancellation()
                    let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= 200_000_000 else { throw ReferenceFailure("Choose regular files no larger than 200 MB.") }
                    total += size; guard total <= 1_000_000_000 else { throw ReferenceFailure("Import less than 1 GB at once.") }
                    let ext = url.pathExtension.lowercased()
                    if ["bib", "bibtex"].contains(ext), target == nil {
                        guard size <= 4_000_000 else { throw ReferenceFailure("Use a bibliography smaller than 4 MB.") }
                        let data = try Data(contentsOf: url)
                        guard let source = String(data: data, encoding: .utf8) else { throw ReferenceFailure("Save BibTeX as UTF-8 before importing.") }
                        imported += try append(ReferenceBibTeX.parse(source).map { var record = $0; record.libraryID = destinationLibrary.parentID ?? destinationLibrary.id; record.collectionID = destinationLibrary.parentID == nil ? nil : destinationLibrary.id; return record }, to: &records)
                    } else if ext == "pdf" {
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard data.count <= 200_000_000, let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw ReferenceFailure("Choose an unlocked, readable PDF.") }
                        var attachment = ReferenceAttachment(name: url.lastPathComponent, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: data.count)
                        let existing = records.flatMap(\.attachments).first { $0.sha256 == attachment.sha256 && (try? Data(contentsOf: attachmentURL($0), options: .mappedIfSafe)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() == attachment.sha256 } == true }
                        if let existing { attachment = existing }
                        let destination = attachmentURL(attachment)
                        if existing == nil {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try data.write(to: destination, options: .withoutOverwriting); created.append(destination)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                        }
                        if let target, let index = records.firstIndex(where: { $0.id == target }) {
                            if !records[index].attachments.contains(where: { $0.sha256 == attachment.sha256 }) { records[index].attachments.append(attachment) }; records[index].revision = UUID(); records[index].modified = Date()
                        } else {
                            let fields = ReferencePDFMetadata.fields(pdf, fallback: url.deletingPathExtension().lastPathComponent)
                            let library = destinationLibrary.parentID ?? destinationLibrary.id
                            let doi = ReferenceDuplicates.normaliseDOI(fields["doi"] ?? "")
                            let matches = records.indices.filter { index in
                                let candidate = records[index]
                                return candidate.trashed == nil && candidate.library == library &&
                                    (!rejectAmbiguous || destinationLibrary.parentID == nil || candidate.collectionID == destinationLibrary.id) &&
                                    (candidate.attachments.contains { $0.sha256 == attachment.sha256 } ||
                                     (!doi.isEmpty && ReferenceDuplicates.normaliseDOI(candidate.fields["doi"] ?? "") == doi))
                            }
                            if rejectAmbiguous, matches.count > 1 { throw ReferenceFailure("Several references match. Resolve them in Reference first.") }
                            if matchingExisting, matches.count == 1, let index = matches.first {
                                if !records[index].attachments.contains(where: { $0.sha256 == attachment.sha256 }) { records[index].attachments.append(attachment) }
                                for (key, value) in fields where records[index].fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { records[index].fields[key] = value }
                                records[index].revision = UUID(); records[index].modified = Date(); imported.append(records[index])
                            } else {
                                var record = ReferenceRecord(); record.libraryID = library; record.collectionID = destinationLibrary.parentID == nil ? nil : destinationLibrary.id; record.attachments = [attachment]; record.fields = fields; if fields["entrysubtype"] == "preprint" { record.type = "misc" }
                                record.key = uniqueKey((keyRule ?? .current).key(for: record), in: records.filter { $0.library == record.library }); records.append(record); imported.append(record)
                            }
                        }
                    } else { throw ReferenceFailure("Reference accepts PDF and BibTeX files.") }
                }
                if let target, let record = records.first(where: { $0.id == target }) { return [record] }
                return imported
            }
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    @discardableResult func addFetched(_ draft: ReferenceRecord, pdf: Data?, libraryID: UUID, attachingTo target: UUID? = nil, expected: UUID? = nil) throws -> ReferenceRecord {
        guard target == nil || pdf != nil else { throw ReferenceFailure("Choose a PDF before attaching it.") }
        let destination = try destination(libraryID)
        var created: URL?
        do {
            return try transaction { records in
                var record = draft
                if let target {
                    guard let current = records.first(where: { $0.id == target && $0.trashed == nil }), current.revision == expected else { throw ReferenceFailure("The reference changed. Open it again.") }
                    record = current
                }
                record.libraryID = destination.parentID ?? destination.id; record.collectionID = destination.parentID == nil ? nil : destination.id
                if let bytes = pdf {
                    guard bytes.count <= 25 * 1024 * 1024, let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else { throw ReferenceFailure("Choose a readable PDF smaller than 25 MB.") }
                    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    if target != nil, let existing = record.attachments.first(where: { $0.sha256 == hash }), (try? Data(contentsOf: attachmentURL(existing), options: .mappedIfSafe)) == bytes { return record }
                    var attachment = ReferenceAttachment(name: String(record.displayTitle.prefix(100)) + ".pdf", sha256: hash, bytes: bytes.count)
                    if let shared = records.flatMap(\.attachments).first(where: { $0.sha256 == hash && (try? Data(contentsOf: attachmentURL($0), options: .mappedIfSafe)) == bytes }) { attachment = shared }
                    else {
                        let url = attachmentURL(attachment)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try bytes.write(to: url, options: .withoutOverwriting); created = url
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                    if target == nil { record.attachments = [attachment] }
                    else if let index = record.attachments.firstIndex(where: { $0.sha256 == attachment.sha256 }) { record.attachments[index] = attachment }
                    else { record.attachments.append(attachment) }
                }
                if let target, let index = records.firstIndex(where: { $0.id == target }) {
                    record.revision = UUID(); record.modified = Date(); records[index] = record; return record
                }
                return try append([record], to: &records)[0]
            }
        } catch { if let created { try? FileManager.default.removeItem(at: created) }; throw error }
    }
    private func append(_ drafts: [ReferenceRecord], to records: inout [ReferenceRecord]) throws -> [ReferenceRecord] {
        let start = records.count
        var identities = Set(records.map(\.id)), keysByLibrary = Dictionary(grouping: records, by: \.library).mapValues { Set($0.map { $0.citationKey.lowercased() }) }
        var mapping: [String: String] = [:]
        for var record in drafts {
            guard identities.insert(record.id).inserted else { throw ReferenceFailure("This reference already exists.") }
            if !record.key.isEmpty { record.originalKey = record.key }
            let key = reserveKey((keyRule ?? .current).key(for: record), keys: &keysByLibrary[record.library, default: []])
            if !record.key.isEmpty { mapping[record.key] = key }
            record.key = key; record.modified = Date(); records.append(record)
        }
        try rewriteRelations(&records, indices: Array(start..<records.count), mapping: mapping)
        return Array(records[start...])
    }
    private func rewriteRelations(_ records: inout [ReferenceRecord], indices: [Int], mapping: [String: String]) throws {
        guard !mapping.isEmpty else { return }
        let hidden = Set(try libraries().filter { $0.trashed != nil }.map(\.id))
        for index in indices where !hidden.contains(records[index].library) && records[index].collectionID.map(hidden.contains) != true {
            var changed = false
            for field in ["crossref", "xref", "xdata", "entryset"] {
                guard let before = records[index].fields[field] else { continue }
                let after = before.components(separatedBy: ",").map { value in
                    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return mapping[key] ?? key
                }.joined(separator: ",")
                if before != after { records[index].fields[field] = after; changed = true }
            }
            if changed { records[index].revision = UUID(); records[index].modified = Date() }
        }
    }
    private func uniqueKey(_ desired: String, in records: [ReferenceRecord]) -> String {
        var keys = Set(records.map { $0.citationKey.lowercased() })
        return reserveKey(desired, keys: &keys)
    }
    private func reserveKey(_ desired: String, keys: inout Set<String>) -> String {
        if keys.insert(desired.lowercased()).inserted { return desired }
        var index = 2
        while !keys.insert((desired + "_" + String(index)).lowercased()).inserted { index += 1 }
        return desired + "_" + String(index)
    }
    private func validate(_ records: [ReferenceRecord]) throws {
        guard records.count <= 10_000, Set(records.map(\.id)).count == records.count, Set(records.map { $0.library.uuidString + ":" + $0.citationKey.lowercased() }).count == records.count else { throw ReferenceFailure("The library contains duplicate identities or too many references.") }
        for record in records {
            guard ReferenceBibTeX.validToken(record.citationKey), ReferenceBibTeX.validToken(record.type), record.fields.count <= 100, record.originalCitation.utf8.count <= 4_000_000,
                  record.fields.allSatisfy({ ReferenceBibTeX.validToken($0.key) && $0.value.utf8.count <= 500_000 }), record.attachments.count <= 100,
                  record.attachments.allSatisfy({ $0.bytes >= 0 && $0.bytes <= 200_000_000 && $0.sha256.count == 64 && $0.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) && $0.name.utf8.count <= 1024 }) else { throw ReferenceFailure("Check the reference fields and attachments before saving.") }
        }
    }
    private func transaction<T>(recordHistory: Bool = true, _ action: (inout [ReferenceRecord]) throws -> T) throws -> T {
        try catalogueTransaction(recordHistory: recordHistory) { catalogue in
            let before = Dictionary(uniqueKeysWithValues: catalogue.records.map { ($0.id, $0) })
            let result = try action(&catalogue.records)
            let libraries = catalogue.libraries ?? [.primary]
            for record in catalogue.records where before[record.id] != record {
                guard libraries.contains(where: { $0.id == record.library && $0.trashed == nil }), record.collectionID == nil || libraries.contains(where: { $0.id == record.collectionID && $0.trashed == nil && $0.parentID == record.library }) else { throw ReferenceFailure("This library is in Trash. Restore it before editing.") }
            }
            return result
        }
    }
    private func catalogueTransaction<T>(historyMove: Bool? = nil, recordHistory: Bool = true, _ action: (inout Catalogue) throws -> T) throws -> T {
        try withLibraryLock {
            var catalogue = try readCatalogue()
            let before = catalogue
            let result = try action(&catalogue)
            try validate(catalogue.records)
            let libraries = catalogue.libraries ?? [.primary]
            guard libraries.count <= 200, Set(libraries.map(\.id)).count == libraries.count, libraries.allSatisfy({ child in child.parentID == nil || libraries.contains { $0.id == child.parentID && $0.parentID == nil } }), catalogue.records.allSatisfy({ record in libraries.contains { $0.id == record.library } }) else { throw ReferenceFailure("Check the library identities before saving.") }
            let data = try JSONEncoder().encode(catalogue)
            guard data.count <= 32_000_000 else { throw ReferenceFailure("The reference catalogue is full.") }
            try data.write(to: self.catalogue, options: .atomic)
            if let historyMove { history?.didMove(to: catalogue, redo: historyMove) }
            else if recordHistory { history?.record(before: before, after: catalogue) }
            else if before.records != catalogue.records { history?.clear() }
            return result
        }
    }
    func withLibraryLock<T>(_ action: () throws -> T) throws -> T {
        StoragePaths.gate.lock(); defer { StoragePaths.gate.unlock() }
        try requireStorage()
        guard !readOnly && !StoragePaths.isReadOnly(root) else { throw ReferenceFailure("This library is read only. Enable editing in Storage on one Mac at a time.") }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(root.appendingPathComponent("library.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ReferenceFailure("Could not open the reference library.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ReferenceFailure("The reference library is busy. Try again.") }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}

extension ReferenceRepository {
    /// Session-only metadata deltas. PDF bytes are never copied into history.
    final class History: @unchecked Sendable {
        private struct Change: Codable {
            var before: [ReferenceRecord]
            var after: [ReferenceRecord]
            var librariesBefore: [ReferenceLibrary]?
            var librariesAfter: [ReferenceLibrary]?
            var bytes: Int = 0
        }
        private let lock = NSRecursiveLock()
        private var past: [Change] = []
        private var future: [Change] = []
        private var expected: Data?
        var canUndo: Bool { lock.lock(); defer { lock.unlock() }; return !past.isEmpty }
        var canRedo: Bool { lock.lock(); defer { lock.unlock() }; return !future.isEmpty }
        func clear() { lock.lock(); defer { lock.unlock() }; past.removeAll(); future.removeAll(); expected = nil }
        private func fingerprint(_ catalogue: Catalogue) -> Data? {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(catalogue)).map { Data(SHA256.hash(data: $0)) }
        }
        fileprivate func observe(_ catalogue: Catalogue) {
            lock.lock(); defer { lock.unlock() }
            if let expected, expected != fingerprint(catalogue) { clear() }
        }
        fileprivate func record(before: Catalogue, after: Catalogue) {
            lock.lock(); defer { lock.unlock() }
            observe(before)
            let old = Dictionary(uniqueKeysWithValues: before.records.map { ($0.id, $0) })
            let new = Dictionary(uniqueKeysWithValues: after.records.map { ($0.id, $0) })
            let ids = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
            let oldLibraries = before.libraries ?? [.primary], newLibraries = after.libraries ?? [.primary]
            guard !ids.isEmpty || oldLibraries != newLibraries else { return }
            var change = Change(before: before.records.filter { ids.contains($0.id) }, after: after.records.filter { ids.contains($0.id) }, librariesBefore: oldLibraries == newLibraries ? nil : oldLibraries, librariesAfter: oldLibraries == newLibraries ? nil : newLibraries)
            change.bytes = (try? JSONEncoder().encode(change).count) ?? Int.max
            future.removeAll()
            guard change.bytes <= 8_000_000 else { clear(); return }
            past.append(change)
            while past.count > 30 || past.reduce(0, { $0 + $1.bytes }) > 8_000_000 { past.removeFirst() }
            expected = fingerprint(after)
        }
        fileprivate func apply(to catalogue: inout Catalogue, redo: Bool, root: URL) throws {
            lock.lock(); defer { lock.unlock() }
            guard expected != nil, expected == fingerprint(catalogue) else { clear(); throw ReferenceFailure("Reference changed elsewhere. Undo history was cleared.") }
            guard let change = (redo ? future : past).last else { throw ReferenceFailure("Nothing to undo or redo.") }
            let restore = redo ? change.after : change.before
            let ids = Set((change.before + change.after).map(\.id))
            for attachment in restore.flatMap(\.attachments) {
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(attachment.relativePath).path) else { throw ReferenceFailure("An attachment is missing. This change cannot be restored.") }
            }
            var garbage = catalogue.garbage ?? []
            for attachment in catalogue.records.filter({ ids.contains($0.id) }).flatMap(\.attachments) where !garbage.contains(where: { $0.id == attachment.id }) { garbage.append(attachment) }
            catalogue.garbage = garbage
            catalogue.records.removeAll { ids.contains($0.id) }
            catalogue.records.append(contentsOf: restore.map { record in
                var record = record; record.revision = UUID(); record.modified = Date(); return record
            })
            if let libraries = redo ? change.librariesAfter : change.librariesBefore { catalogue.libraries = libraries }
        }
        fileprivate func didMove(to catalogue: Catalogue, redo: Bool) {
            lock.lock(); defer { lock.unlock() }
            if redo, let change = future.popLast() { past.append(change) }
            else if !redo, let change = past.popLast() { future.append(change) }
            expected = fingerprint(catalogue)
        }
    }
}
