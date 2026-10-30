import Foundation
import CryptoKit

struct ZoteroLibrary: Identifiable, Hashable, Codable, Sendable {
    let path: String
    let name: String
    var id: String { path }
    var source: String { "zotero:" + path }
}
struct ZoteroCollection: Identifiable, Hashable, Codable, Sendable {
    let key: String
    let name: String
    let parent: String?
    var id: String { key }
}
struct ZoteroScope: Identifiable, Hashable, Codable, Sendable {
    let library: ZoteroLibrary
    var collection: ZoteroCollection? = nil
    var id: String { library.id + ":" + (collection?.key ?? "") }
    var itemsPath: String { library.path + (collection.map { "/collections/" + $0.key } ?? "") + "/items/top" }
}
enum ZoteroAccess {
    static let enabledKey = "extensions.zotero.enabled"
    static func requireEnabled() throws {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { throw ReferenceFailure("Enable Zotero in Extensions.") }
    }
}

struct ZoteroItem: Decodable, Sendable {
    struct Creator: Decodable, Sendable {
        var creatorType: String?
        var firstName: String?
        var lastName: String?
        var name: String?
        var bibName: String {
            if let name, !name.isEmpty { return "{" + name + "}" }
            return [lastName, firstName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
    struct Tag: Decodable, Sendable { let tag: String }
    struct DataFields: Decodable, Sendable {
        let strings: [String: String]
        let creators: [Creator]
        let tags: [Tag]
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            var strings: [String: String] = [:]
            for key in values.allKeys { if let value = try? values.decode(String.self, forKey: key) { strings[key.stringValue] = value } }
            self.strings = strings
            creators = (try? values.decode([Creator].self, forKey: Key(stringValue: "creators")!)) ?? []
            tags = (try? values.decode([Tag].self, forKey: Key(stringValue: "tags")!)) ?? []
        }
    }
    let key: String
    let version: Int
    let data: DataFields
    var kind: String { data.strings["itemType"] ?? "" }
    static func validKey(_ value: String) -> Bool {
        value.utf8.count == 8 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    var isReference: Bool { !["attachment", "note", "annotation"].contains(kind) && !kind.isEmpty }
    var isPDF: Bool { kind == "attachment" && data.strings["contentType"] == "application/pdf" }
    func reference(in library: ZoteroLibrary) throws -> ReferenceRecord {
        guard Self.validKey(key), isReference else { throw ReferenceFailure("Unsupported Zotero reference.") }
        let types = ["journalArticle": "article", "book": "book", "bookSection": "incollection", "conferencePaper": "inproceedings", "report": "techreport", "thesis": "thesis", "webpage": "online", "newspaperArticle": "article", "manuscript": "unpublished"]
        var record = ReferenceRecord(type: types[kind] ?? "misc")
        let proposed = data.strings["citationKey"] ?? ""
        if !proposed.isEmpty, ReferenceBibTeX.validToken(proposed) { record.key = proposed }
        else if let extra = data.strings["extra"], let range = extra.range(of: #"(?im)^citation\s*key:\s*(\S+)\s*$"#, options: .regularExpression) {
            let line = String(extra[range])
            let candidate = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            record.key = ReferenceBibTeX.validToken(candidate) ? candidate : key
        } else { record.key = key }
        record.originalKey = record.key
        record.zotero = ZoteroReference(source: library.path + "/items/" + key, version: version)
        let mapping = ["title": "title", "date": "date", "publisher": "publisher", "place": "address", "volume": "volume", "issue": "number", "pages": "pages", "DOI": "doi", "ISBN": "isbn", "ISSN": "issn", "url": "url", "abstractNote": "abstract", "language": "language", "edition": "edition", "series": "series", "shortTitle": "shorttitle"]
        for (source, target) in mapping {
            if let value = data.strings[source], !value.isEmpty { record.fields[target] = value }
        }
        if let publication = data.strings["publicationTitle"], !publication.isEmpty {
            record.fields[["bookSection", "conferencePaper"].contains(kind) ? "booktitle" : "journal"] = publication
        }
        for role in ["author", "editor", "translator"] {
            let names = data.creators.filter { $0.creatorType == role }.map(\.bibName).filter { !$0.isEmpty }
            if !names.isEmpty { record.fields[role] = names.joined(separator: " and ") }
        }
        if let date = record.fields["date"], let range = date.range(of: #"\b[12]\d{3}\b"#, options: .regularExpression) { record.fields["year"] = String(date[range]) }
        if !data.tags.isEmpty { record.fields["keywords"] = data.tags.map(\.tag).joined(separator: ", ") }
        if kind == "thesis" {
            if let degree = data.strings["thesisType"], !degree.isEmpty {
                record.fields["type"] = degree
                record.type = ReferenceKind.thesisKind(degree)?.bibType ?? "thesis"
            }
            if let school = data.strings["university"], !school.isEmpty { record.fields["school"] = school }
        }
        if kind == "newspaperArticle" { record.fields["entrysubtype"] = "newspaper" }
        if kind == "preprint" { record.fields["entrysubtype"] = "preprint" }
        if kind == "attachment" { record.fields["entrysubtype"] = "note" }
        record.fields["zoterosource"] = library.path + "/items/" + key
        return record
    }
}

actor ZoteroLocalClient {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }
    }
    deinit { session.invalidateAndCancel() }
    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard !path.contains(".."), !path.contains("?"), !path.contains("#"), !path.hasPrefix("/") else { throw ReferenceFailure("Invalid Zotero request.") }
        var url = URLComponents(string: "http://127.0.0.1:23119/api/" + path)!
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw ReferenceFailure("Open Zotero and keep it running, then choose Check again.")
        }
        catch { throw ReferenceFailure("Zotero is not responding. Keep it running and choose Check again.") }
        try Task.checkCancellation()
        guard let response = result.1 as? HTTPURLResponse, response.url?.host == "127.0.0.1", response.url?.port == 23119, result.0.count <= 8_000_000 else { throw ReferenceFailure("The Zotero response exceeds its limit.") }
        if response.statusCode == 403 { throw ReferenceFailure("In Zotero Settings → Advanced, enable ‘Allow other applications on this computer to communicate with Zotero’.") }
        guard response.statusCode == 200 || response.statusCode == 404 else { throw ReferenceFailure("Zotero could not complete the request (\(response.statusCode)).") }
        return (result.0, response)
    }
    private func page<T: Decodable>(_ type: T.Type, path: String, start: Int) async throws -> ([T], String?) {
        var query = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "start", value: String(start))]
        if path.contains("/items/") { query += [URLQueryItem(name: "sort", value: "dateAdded"), URLQueryItem(name: "direction", value: "asc")] }
        let (data, response) = try await get(path, query: query)
        guard response.statusCode == 200 else { throw ReferenceFailure("The Zotero library or collection is unavailable. Refresh the list.") }
        let items = try JSONDecoder().decode([T].self, from: data)
        guard items.count <= 100 else { throw ReferenceFailure("Zotero did not apply the requested page limit.") }
        return (items, response.value(forHTTPHeaderField: "Last-Modified-Version"))
    }
    func libraries() async throws -> [ZoteroLibrary] {
        struct Group: Decodable { struct Details: Decodable { let name: String }; let id: Int; let data: Details }
        var libraries = [ZoteroLibrary(path: "users/0", name: "My Library")]
        for start in stride(from: 0, to: 200, by: 100) {
            let (groups, _) = try await page(Group.self, path: "users/0/groups", start: start)
            for group in groups where group.id > 0 { libraries.append(ZoteroLibrary(path: "groups/" + String(group.id), name: String(group.data.name.prefix(200)))) }
            guard Set(libraries.map(\.id)).count == libraries.count else { throw ReferenceFailure("Zotero returned duplicate library identities.") }
            if groups.count < 100 { return libraries }
        }
        throw ReferenceFailure("Choose a Zotero account with fewer than 200 group libraries.")
    }
    func collections(_ library: ZoteroLibrary) async throws -> [ZoteroCollection] {
        var result: [ZoteroCollection] = []
        for start in stride(from: 0, to: 5000, by: 100) {
            let (items, _) = try await page(ZoteroItem.self, path: library.path + "/collections", start: start)
            for item in items where ZoteroItem.validKey(item.key) {
                result.append(ZoteroCollection(key: item.key, name: String((item.data.strings["name"] ?? "Collection").prefix(200)), parent: item.data.strings["parentCollection"]))
            }
            guard Set(result.map(\.id)).count == result.count else { throw ReferenceFailure("Zotero collections changed. Refresh the list.") }
            if items.count < 100 { return result }
        }
        throw ReferenceFailure("This Zotero library has too many collections.")
    }
    func children(_ item: ZoteroItem, in library: ZoteroLibrary) async throws -> [ZoteroItem] {
        guard ZoteroItem.validKey(item.key) else { throw ReferenceFailure("Invalid Zotero item.") }
        let (items, _) = try await page(ZoteroItem.self, path: library.path + "/items/" + item.key + "/children", start: 0)
        guard items.count < 100 else { throw ReferenceFailure("This Zotero item has too many attachments.") }
        return items.filter(\.isPDF)
    }
    func localPDF(_ item: ZoteroItem, in library: ZoteroLibrary) async throws -> URL? {
        guard item.isPDF, ZoteroItem.validKey(item.key) else { return nil }
        let (data, response) = try await get(library.path + "/items/" + item.key + "/file/view/url")
        if response.statusCode == 404 { return nil }
        guard data.count < 32768, let value = String(data: data, encoding: .utf8),
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost", url.pathExtension.lowercased() == "pdf" else {
            throw ReferenceFailure("Zotero did not return a local PDF.")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        guard (values?.fileSize ?? Int.max) <= 200_000_000 else { throw ReferenceFailure("A Zotero PDF exceeds 200 MB.") }
        return url
    }
    func items(_ scope: ZoteroScope, start: Int) async throws -> ([ZoteroItem], String?) {
        try await page(ZoteroItem.self, path: scope.itemsPath, start: start)
    }
}
