import Foundation

/// The native catalogue contract, including revision-checked writes.
enum ReferenceCLI {
    static func response(_ options: [String], repository: ReferenceRepository = ReferenceRepository()) throws -> [String: Any] {
        try EditorCLIArguments.validate(command: "reference", options: options)
        func option(_ key: String) -> String? { options.firstIndex(of: key).map { options[$0 + 1] } }
        // Evidence services validate identity themselves. Avoid loading the catalogue twice.
        switch options.first {
        case "passages":
            guard let id = option("--id").flatMap(UUID.init(uuidString:)) else { throw ReferenceFailure("Choose an active reference.") }
            let saved = try ReferencePassages.snapshot(recordID: id, repository: repository), record = saved.record
            return ["ok": true, "schema": 1, "id": id.uuidString, "key": record.citationKey, "passages": try saved.passages.map { passage -> [String: Any] in
                var payload = try ReferencePassages.payload(passage)
                payload["attached"] = record.attachments.contains(where: { $0.id == passage.attachment && $0.sha256 == passage.sha256 })
                return payload
            }]
        case "save-passage":
            guard let id = option("--id").flatMap(UUID.init(uuidString:)), let attachment = option("--attachment").flatMap(UUID.init(uuidString:)), let hash = option("--expected-sha256"), let page = option("--page").flatMap(Int.init), let start = option("--start").flatMap(Int.init), let length = option("--length").flatMap(Int.init) else { throw ReferenceFailure("Choose a PDF passage.") }
            let passage = try ReferencePassages.save(recordID: id, attachmentID: attachment, expectedSHA256: hash, page: page, range: NSRange(location: start, length: length), repository: repository)
            return ["ok": true, "schema": 1, "passage": try ReferencePassages.payload(passage)]
        case "evidence":
            guard let id = option("--id").flatMap(UUID.init(uuidString:)), let attachment = option("--attachment").flatMap(UUID.init(uuidString:)) else { throw ReferenceFailure("Choose a reference and attachment ID.") }
            return try ReferenceEvidence.page(recordID: id, attachmentID: attachment, page: Int(option("--page") ?? "1") ?? 1, repository: repository)
        default: break
        }
        let snapshot = try repository.snapshot()
        let records = snapshot.records, allLibraries = snapshot.libraries
        let libraries = allLibraries.filter { $0.trashed == nil }
        let deleted = Set(allLibraries.filter { $0.trashed != nil }.map(\.id))
        func inTrash(_ record: ReferenceRecord) -> Bool { record.trashed != nil || deleted.contains(record.library) || record.collectionID.map(deleted.contains) == true }
        let library = option("--library").flatMap(UUID.init(uuidString:))
        if let library, !libraries.contains(where: { $0.id == library }) { throw ReferenceFailure("Choose an existing library ID.") }
        func file() throws -> URL {
            guard let path = option("--source-file"), path.hasPrefix("/") else { throw ReferenceFailure("Provide an absolute --source-file path.") }
            return URL(fileURLWithPath: path)
        }
        if options.first == "import" {
            guard let library else { throw ReferenceFailure("Choose a destination library ID.") }
            let imported = try repository.importFiles([file()], libraryID: library)
            return ["ok": true, "schema": 1, "references": imported.map { ["id": $0.id.uuidString, "revision": $0.revision.uuidString] }]
        }
        let writes = ["update", "attach", "detach", "trash", "restore", "regenerate-key"]
        if let action = options.first, writes.contains(action) {
            guard let id = option("--id").flatMap(UUID.init(uuidString:)), let expected = option("--expected-revision").flatMap(UUID.init(uuidString:)), let record = records.first(where: { $0.id == id }), record.revision == expected else { throw ReferenceFailure("The reference changed. Read it again before writing.") }
            switch action {
            case "update":
                let url = try file(), size = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 4_000_000 else { throw ReferenceFailure("Use a regular UTF-8 BibTeX file smaller than 4 MB.") }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= 4_000_000, let source = String(data: bytes, encoding: .utf8) else { throw ReferenceFailure("Use a UTF-8 BibTeX file smaller than 4 MB.") }
                let parsed = try ReferenceBibTeX.parse(source)
                guard parsed.count == 1 else { throw ReferenceFailure("Update requires exactly one BibTeX entry.") }
                var updated = record; updated.fields = parsed[0].fields; updated.type = parsed[0].type
                if updated.fields["abstract"] == nil { updated.fields["abstract"] = record.fields["abstract"] }
                _ = try repository.update(updated, expected: expected)
            case "attach": _ = try repository.importFiles([file()], attachingTo: id, expected: expected, libraryID: record.collectionID ?? record.library)
            case "detach":
                guard let attachment = option("--attachment").flatMap(UUID.init(uuidString:)) else { throw ReferenceFailure("Choose an attachment ID.") }
                _ = try repository.removeAttachments([attachment], from: id, expected: expected)
            case "trash", "restore": try repository.trash(id, restore: action == "restore", expected: expected)
            case "regenerate-key": _ = try repository.regenerate(id: id, expected: expected, rule: .current)
            default: break
            }
            guard let updated = try repository.records().first(where: { $0.id == id }) else { throw ReferenceFailure("Read the catalogue to confirm the operation outcome.") }
            return ["ok": true, "schema": 1, "id": updated.id.uuidString, "revision": updated.revision.uuidString]
        }
        switch options.first {
        case "libraries": return ["ok": true, "schema": 1, "libraries": libraries.map { library in ["id": library.id.uuidString, "name": library.name, "parentID": library.parentID?.uuidString ?? "", "kind": library.parentID == nil ? "library" : "collection", "count": records.filter { ($0.library == library.id || $0.collectionID == library.id) && !inTrash($0) }.count] as [String: Any] }]
        case "list":
            let trash = options.contains("--trash"), text = option("--query") ?? ""
            let rows = records.filter { inTrash($0) == trash && (library == nil || $0.library == library || $0.collectionID == library) && (text.isEmpty || $0.searchText.localizedCaseInsensitiveContains(text)) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let offset = Int(option("--offset") ?? "0") ?? 0, limit = Int(option("--limit") ?? "50") ?? 50
            return ["ok": true, "schema": 1, "total": rows.count, "offset": offset, "references": rows.dropFirst(offset).prefix(limit).map { record in
                ["collectionID": record.collectionID?.uuidString ?? "", "libraryID": record.library.uuidString, "id": record.id.uuidString, "revision": record.revision.uuidString, "title": String(record.title.prefix(1000)), "authors": String(record.authors.prefix(500)), "year": String(record.year.prefix(32)), "publication": String(ReferenceColumn.publication.value(record).prefix(500)), "type": record.type, "summaryTruncated": record.title.count > 1000 || record.authors.count > 500 || record.year.count > 32 || ReferenceColumn.publication.value(record).count > 500, "key": record.citationKey, "attachments": record.attachments.count] as [String: Any]
            }]
        case "suggest":
            let candidates = records.filter { !inTrash($0) && ($0.library == library || $0.collectionID == library) }
            let suggestions = ReferenceCitationCompletion.suggestions(query: option("--query") ?? "", project: [], library: candidates, limit: Int(option("--limit") ?? "8") ?? 8)
            return ["ok": true, "schema": 1, "suggestions": suggestions.map { ["id": $0.record.id.uuidString, "revision": $0.record.revision.uuidString, "key": $0.record.citationKey, "title": $0.record.displayTitle, "authors": $0.record.displayAuthors, "year": $0.record.year] }]
        case "citation":
            guard let id = option("--id").flatMap(UUID.init(uuidString:)), let record = records.first(where: { $0.id == id && !inTrash($0) }), let format = ReferenceCitation.Format(rawValue: option("--kind") ?? "latex") else { throw ReferenceFailure("Choose an active reference and citation format.") }
            return ["ok": true, "schema": 1, "id": record.id.uuidString, "revision": record.revision.uuidString, "key": record.citationKey, "citation": try ReferenceCitation.text(record, format: format), "bibtex": try ReferenceExport.bibtex([record])]
        case "show":
            guard let id = option("--id").flatMap(UUID.init(uuidString:)), let record = records.first(where: { $0.id == id }) else { throw ReferenceFailure("Choose an existing reference ID.") }
            let encoded = try JSONEncoder().encode(record)
            var row = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            row["libraryID"] = record.library.uuidString
            row["attachments"] = record.attachments.map { ["id": $0.id.uuidString, "name": $0.name, "sha256": $0.sha256, "path": repository.attachmentURL($0).path] }
            return ["ok": true, "schema": 1, "reference": row, "bibtex": try ReferenceExport.bibtex([record])]
        case "export":
            let targetLibrary = library ?? (option("--id") == nil ? libraries.first?.id : nil)
            var chosen = records.filter { !inTrash($0) && (targetLibrary == nil || $0.library == targetLibrary || $0.collectionID == targetLibrary) }
            if let id = option("--id").flatMap(UUID.init(uuidString:)) { chosen = chosen.filter { $0.id == id } }
            guard !chosen.isEmpty else { throw ReferenceFailure("Choose an existing reference to export.") }
            let source = try ReferenceExport.bibtex(chosen)
            if let path = option("--output") {
                let url = URL(fileURLWithPath: path)
                guard path.hasPrefix("/"), url.pathExtension.lowercased() == "bib", !FileManager.default.fileExists(atPath: path) else { throw ReferenceFailure("Choose a new absolute .bib output file.") }
                try Data(source.utf8).write(to: url, options: .withoutOverwriting)
                return ["ok": true, "schema": 1, "output": path, "count": chosen.count]
            }
            return ["ok": true, "schema": 1, "bibtex": source, "count": chosen.count]
        default: throw ReferenceFailure("Use reference libraries, list, show or export.")
        }
    }
}
