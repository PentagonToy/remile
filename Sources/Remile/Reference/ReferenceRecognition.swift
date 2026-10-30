import Foundation

/// Fill missing fields without overwriting edits. reMarkable PDFs may also use an exact title match.
enum ReferenceRecognition {
    actor Receipt {
        private var saved: [ReferenceRecord] = []
        private var problem: String?
        func fail(_ message: String) { if problem == nil { problem = message } }
        func failure() -> String? { problem }
        func store(_ records: [ReferenceRecord]) { saved = records }
        func read() -> [ReferenceRecord] { saved }
    }
    static func eligible(_ record: ReferenceRecord) -> Bool {
        record.trashed == nil && (identifier(record) || (!ReferencePDFMetadata.placeholderTitle(record.title) && record.title != "Untitled reference" && record.title.count >= 20 && record.title.count <= 500))
    }
    static func automaticEligible(_ record: ReferenceRecord) -> Bool {
        let pendingPaper = record.remarkable?.fileType == "pdf" && ReferenceKind.classify(record) == .note
        let invalidTitle = ReferencePDFMetadata.placeholderTitle(record.title, journal: record.fields["journal"])
        let needsMetadata = record.contributors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || record.year.isEmpty || pendingPaper || invalidTitle
        let exactTitleCandidate = pendingPaper && record.title.split(whereSeparator: \.isWhitespace).count >= 3
        return eligible(record) && !record.attachments.isEmpty && needsMetadata && (identifier(record) || exactTitleCandidate)
    }
    private static func identifier(_ record: ReferenceRecord) -> Bool {
        archiveID(record) != nil || ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "").hasPrefix("10.")
    }
    static func archiveID(_ record: ReferenceRecord) -> String? {
        ReferencePDFMetadata.arxivID(in: "arXiv:" + (record.fields["eprint"] ?? "") + " " + record.title + " " + (record.fields["url"] ?? ""))
    }
    static func merged(_ local: ReferenceRecord, with fetched: ReferenceRecord) throws -> ReferenceRecord {
        let arxiv = archiveID(local).map(ReferenceArxiv.base)
        if let arxiv {
            guard fetched.fields["eprint"].map(ReferenceArxiv.base) == arxiv else { throw ReferenceFailure("The archive record did not match this paper.") }
        } else {
            let doi = ReferenceDuplicates.normaliseDOI(local.fields["doi"] ?? "")
            if !doi.isEmpty {
                guard doi == ReferenceDuplicates.normaliseDOI(fetched.fields["doi"] ?? "") else { throw ReferenceFailure("The DOI record did not match this paper.") }
            } else {
                guard ReferencePaperLookup.matches(local, fields: fetched.fields) else { throw ReferenceFailure("The title did not match this paper.") }
            }
        }
        var next = local
        for (key, value) in fetched.fields where !value.isEmpty && local.fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            if ReferenceMergePlan.published(local), fetched.fields["entrysubtype"] == "preprint", ["year", "date", "entrysubtype", "journal", "booktitle", "publisher", "volume", "number", "pages", "doi", "url"].contains(key) { continue }
            next.fields[key] = value
        }
        let placeholder = ReferencePDFMetadata.placeholderTitle(local.title, journal: local.fields["journal"])
            || ReferencePDFMetadata.placeholderTitle(local.title, journal: fetched.fields["journal"])
        if !fetched.title.isEmpty, local.title == "Untitled reference" || placeholder { next.fields["title"] = fetched.title }
        if !ReferenceMergePlan.published(local) {
            next.type = fetched.type
            if local.remarkable?.fileType == "pdf", ReferenceKind.classify(local) == .note {
                if ReferenceKind.classify(fetched) == .other {
                    next.type = local.type
                    next.fields["entrysubtype"] = "note"
                } else {
                    next.fields["entrysubtype"] = fetched.fields["entrysubtype"]
                }
            }
        }
        return next
    }
    static func enrich(_ records: [ReferenceRecord], repository: ReferenceRepository, lookup: @escaping @Sendable (ReferenceRecord) async throws -> ReferenceRecord = ReferencePaperLookup.metadata, onFailure: @escaping @Sendable (String) async -> Void = { _ in }) async -> [ReferenceRecord] {
        guard !NetworkAccess.offline else { return records }
        let work = Task { await process(records, repository: repository, lookup: lookup, onFailure: onFailure) }
        guard let lease = try? NetworkAccess.gate.watch({ work.cancel() }) else { work.cancel(); return records }
        defer { NetworkAccess.gate.release(lease) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    private static func process(_ records: [ReferenceRecord], repository: ReferenceRepository, lookup: @escaping @Sendable (ReferenceRecord) async throws -> ReferenceRecord, onFailure: @escaping @Sendable (String) async -> Void) async -> [ReferenceRecord] {
        var result = records
        var cache: [String: ReferenceRecord] = [:], attempted = Set<String>()
        for (index, record) in records.enumerated() where eligible(record) {
            guard !NetworkAccess.offline, !Task.isCancelled else { break }
            do {
                let doi = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "")
                let key = archiveID(record).map { "arxiv:" + $0 } ?? (doi.hasPrefix("10.") ? "doi:" + doi : "title:" + record.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
                if attempted.contains(key), cache[key] == nil { continue }
                attempted.insert(key)
                let fetched: ReferenceRecord
                if let saved = cache[key] { fetched = saved }
                else { fetched = try await lookup(record); cache[key] = fetched }
                try Task.checkCancellation(); try NetworkAccess.requireOnline()
                let next = try merged(record, with: fetched)
                guard next.fields != record.fields || next.type != record.type else { continue }
                try repository.applyCleanup([.init(before: record, after: next)])
                result[index] = try repository.records().first { $0.id == record.id } ?? record
            } catch is CancellationError { break }
            catch { if !NetworkAccess.offline, !Task.isCancelled { await onFailure(error.localizedDescription) } }
        }
        return result
    }
    static func importFiles(_ urls: [URL], repository: ReferenceRepository, target: ReferenceRecord? = nil, library: UUID, matchingExisting: Bool = false) async throws -> [ReferenceRecord] {
        let records = try repository.importFiles(urls, attachingTo: target?.id, expected: target?.revision, libraryID: library, matchingExisting: matchingExisting)
        let enriched = await enrich(records.filter(automaticEligible), repository: repository)
        let byID = Dictionary(uniqueKeysWithValues: enriched.map { ($0.id, $0) })
        return records.map { byID[$0.id] ?? $0 }
    }
}
