import Foundation

struct ReferenceLibrary: Codable, Identifiable, Equatable, Sendable {
    static let allID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let primary = Self(id: primaryID, name: "My library")
    var id: UUID = UUID()
    var name: String
    var parentID: UUID?
    var trashed: Date?
    var source: String? = nil
    var zoteroScope: ZoteroScope? = nil
    var remarkableFolders: [RemarkableFolderScope]? = nil
    var importedZoteroScope: ZoteroScope? {
        if let zoteroScope { return zoteroScope }
        guard let source, source.hasPrefix("zotero-import:") else { return nil }
        let parts = source.dropFirst("zotero-import:".count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].range(of: #"^(users/0|groups/[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        let library = ZoteroLibrary(path: String(parts[0]), name: name)
        if parts[1].isEmpty { return ZoteroScope(library: library) }
        guard ZoteroItem.validKey(String(parts[1])) else { return nil }
        return ZoteroScope(library: library, collection: ZoteroCollection(key: String(parts[1]), name: name, parent: nil))
    }
}
extension ReferenceRecord {
    var library: UUID { libraryID ?? ReferenceLibrary.primaryID }
}

enum ReferenceDuplicates {
    /// Find duplicates independently, so matching records elsewhere never colour a library.
    static func withinLibraries(_ records: [ReferenceRecord]) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for library in Dictionary(grouping: records.filter { $0.remarkable == nil }, by: { $0.collectionID ?? $0.library }).values {
            result.merge(lookup(library), uniquingKeysWith: { first, _ in first })
        }
        return result
    }
    static func lookup(_ records: [ReferenceRecord]) -> [UUID: [UUID]] {
        let active = records.filter { $0.trashed == nil }
        var parent = Array(active.indices), seen: [String: Int] = [:]
        func root(_ i: Int) -> Int { var x = i; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for (i, record) in active.enumerated() {
            var keys = record.attachments.map { "pdf:" + $0.sha256 }
            for field in ["doi", "url"] {
                if let raw = record.fields[field] {
                    let doi = normaliseDOI(raw)
                    if doi.range(of: #"^10\.[0-9]{4,9}/\S+$"#, options: .regularExpression) != nil { keys.append("doi:" + doi) }
                }
            }
            let title = normalise(record.fields["title"] ?? ""), author = normalise(record.authors), year = normalise(record.year)
            if title.count >= 12, !author.isEmpty, !year.isEmpty {
                keys.append("text:" + title + ":" + author + ":" + year)
                let first = record.authors.components(separatedBy: " and ").first ?? ""
                let family = first.contains(",") ? first.components(separatedBy: ",")[0] : first
                let surname = normalise(family.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "")
                let publicationYear = String(record.year.prefix(4))
                if surname.count >= 2, publicationYear.count == 4, publicationYear.allSatisfy(\.isNumber) {
                    keys.append("title-author:" + title + ":" + surname + ":" + publicationYear)
                    if title.count >= 24, ReferenceMergePlan.status(record) == "Preprint", let year = Int(publicationYear) {
                        for nearby in [year - 1, year + 1] { keys.append("title-author:" + title + ":" + surname + ":" + String(nearby)) }
                    }
                }
            }
            for key in keys { if let other = seen[key] { parent[root(i)] = root(other) } else { seen[key] = i } }
        }
        var groups: [Int: [UUID]] = [:]
        for i in active.indices { groups[root(i), default: []].append(active[i].id) }
        var result: [UUID: [UUID]] = [:]
        for group in groups.values where group.count > 1 { for id in group { result[id] = group } }
        return result
    }
    static func normaliseDOI(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("\\url{"), value.hasSuffix("}") { value = String(value.dropFirst(5).dropLast()) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "{} \t\r\n"))
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "https://www.doi.org/", "doi:"] { if value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) } }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func normalise(_ value: String) -> String { value.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: "", options: .regularExpression).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
}
