import Foundation
import PDFKit

/// Explicit, bounded public lookups. No account cookies, background polling or automatic library writes.
enum ReferencePaperLookup {
    static let pdfLimit = 25 * 1024 * 1024
    struct Paper: Identifiable, Sendable { let record: ReferenceRecord; var id: UUID { record.id } }
    static func matches(_ record: ReferenceRecord, fields: [String: String]) -> Bool {
        let wanted = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "")
        let actual = ReferenceDuplicates.normaliseDOI(fields["doi"] ?? "")
        if !wanted.isEmpty && !actual.isEmpty { return wanted == actual }
        func title(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined() }
        let expected = title(record.title)
        return expected.count >= 20 && expected == title(fields["title"] ?? "")
    }
    static func localPDFs(for record: ReferenceRecord, candidates: [URL]) throws -> [URL] {
        var result: [URL] = [], seen = Set<URL>()
        for url in candidates.prefix(20) where url.isFileURL && url.pathExtension.lowercased() == "pdf" {
            try Task.checkCancellation()
            guard seen.insert(url.standardizedFileURL).inserted,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= pdfLimit,
                  let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0,
                  matches(record, fields: ReferencePDFMetadata.fields(pdf, fallback: url.deletingPathExtension().lastPathComponent)) else { continue }
            result.append(url)
        }
        return result
    }
    static func metadata(for record: ReferenceRecord) async throws -> ReferenceRecord {
        try await pdfMetadata(record, deadline: Date().addingTimeInterval(50))
    }
    static func pdfMetadata(_ record: ReferenceRecord, deadline: Date) async throws -> ReferenceRecord {
        if let id = ReferenceRecognition.archiveID(record) {
            try await ReferenceArchivePacing.shared.wait()
            var url = URLComponents(string: "https://export.arxiv.org/api/query")!
            url.queryItems = [URLQueryItem(name: "id_list", value: id)]
            let data = try await request(url.url!, limit: 200_000, accept: "application/atom+xml", deadline: deadline)
            return try ReferenceArxiv.parse(data, expectedID: id)
        }
        let doi = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "")
        let papers = try await search(doi.hasPrefix("10.") ? doi : record.title, deadline: deadline)
        let exact = papers.filter { matches(record, fields: $0.record.fields) }
        guard exact.count == 1, let paper = exact.first else { throw ReferenceFailure("No unique match. Add a DOI or arXiv ID and try again.") }
        if (record.fields["abstract"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await fillingAbstract(paper.record, deadline: deadline)
        }
        return paper.record
    }
    static func fillingAbstract(_ record: ReferenceRecord, deadline: Date, load: @escaping @Sendable (String, Date) async throws -> Data = { doi, deadline in try await openAccessData(doi: doi, deadline: deadline, abstractOnly: true) }) async throws -> ReferenceRecord {
        guard (record.fields["abstract"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return record }
        let doi = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "")
        guard doi.hasPrefix("10.") else { return record }
        var result = record
        do {
            let data = try await load(doi, deadline)
            try Task.checkCancellation()
            if let abstract = try openAbstract(data, doi: doi) { result.fields["abstract"] = abstract }
        } catch is CancellationError { throw CancellationError() }
        catch { /* Optional abstract availability must not discard other recognised fields. */ }
        try Task.checkCancellation()
        return result
    }
    static func openAbstract(_ data: Data, doi: String) throws -> String? {
        guard data.count <= 200_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = object["abstract_inverted_index"] as? [String: [Int]], !index.isEmpty, index.count <= 3000 else { return nil }
        let identifiers = [object["doi"] as? String].compactMap { $0 } + (object["locations"] as? [[String: Any]] ?? []).compactMap { $0["doi"] as? String }
        guard identifiers.contains(where: { ReferenceDuplicates.normaliseDOI($0) == ReferenceDuplicates.normaliseDOI(doi) }) else { return nil }
        var words: [Int: String] = [:], characters = 0
        for (word, positions) in index {
            guard !word.isEmpty, word.count <= 500, positions.count <= 3000 else { return nil }
            for position in positions {
                characters += word.count + 1
                guard position >= 0, position < 3000, characters <= 12_000, words.updateValue(word, forKey: position) == nil else { return nil }
            }
        }
        guard !words.isEmpty, words.count == (words.keys.max() ?? -1) + 1 else { return nil }
        let abstract = (0..<words.count).compactMap { words[$0] }.joined(separator: " ")
        return abstract.count >= 20 ? abstract : nil
    }
    static func search(_ query: String, deadline: Date = .distantFuture) async throws -> [Paper] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw ReferenceFailure("Enter a DOI or a title of up to 500 characters.") }
        let doi = ReferenceDuplicates.normaliseDOI(query)
        var url = URLComponents(string: "https://api.crossref.org/works")!
        let single = doi.hasPrefix("10.") && !doi.contains(where: \.isWhitespace)
        if single { url.percentEncodedPath += "/" + encoded(doi) }
        else { url.queryItems = [URLQueryItem(name: "query.bibliographic", value: query), URLQueryItem(name: "rows", value: "5")] }
        let data = try await request(url.url!, limit: 1_500_000, accept: "application/json", deadline: deadline)
        return try parseCrossref(data, single: single).map { Paper(record: $0) }
    }
    static func openAccessData(doi: String, deadline: Date, abstractOnly: Bool = false) async throws -> Data {
        let doi = ReferenceDuplicates.normaliseDOI(doi)
        guard doi.hasPrefix("10.") else { throw ReferenceFailure("Add a DOI to search public repositories.") }
        var url = URLComponents(string: "https://api.openalex.org")!
        url.percentEncodedPath = "/works/https://doi.org/" + encoded(doi)
        if abstractOnly { url.queryItems = [URLQueryItem(name: "select", value: "doi,locations,abstract_inverted_index")] }
        return try await request(url.url!, limit: abstractOnly ? 200_000 : 2_000_000, accept: "application/json", deadline: deadline)
    }
    static func parseCrossref(_ data: Data, single: Bool) throws -> [ReferenceRecord] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] as? [String: Any] else { throw ReferenceFailure("The metadata service returned an unreadable response.") }
        let items = single ? [message] : message["items"] as? [[String: Any]] ?? []
        return items.prefix(5).compactMap { item in
            guard let raw = (item["title"] as? [String])?.first else { return nil }
            let title = text(raw); guard !title.isEmpty else { return nil }
            var record = ReferenceRecord()
            let kind = item["type"] as? String ?? ""
            record.type = ["journal-article": "article", "proceedings-article": "inproceedings", "book": "book", "edited-book": "book", "reference-book": "book", "monograph": "book", "book-chapter": "incollection"][kind] ?? "misc"
            record.fields["title"] = title
            if let abstract = item["abstract"] as? String { record.fields["abstract"] = String(text(abstract).prefix(12_000)) }
            for role in ["author", "editor"] {
                let names = (item[role] as? [[String: Any]] ?? []).compactMap { person -> String? in
                    let family = (person["family"] as? String).map(text) ?? "", given = (person["given"] as? String).map(text) ?? ""
                    if !family.isEmpty { return family + (given.isEmpty ? "" : ", " + given) }
                    return (person["name"] as? String).map { "{" + text($0) + "}" }
                }
                if !names.isEmpty { record.fields[role] = names.joined(separator: " and ") }
            }
            if let doi = item["DOI"] as? String { record.fields["doi"] = ReferenceDuplicates.normaliseDOI(doi); record.fields["url"] = "https://doi.org/" + doi }
            for (source, target) in ["publisher": "publisher", "volume": "volume", "issue": "number", "page": "pages"] { if let value = item[source] as? String, !value.isEmpty { record.fields[target] = text(value) } }
            if let venue = (item["container-title"] as? [String])?.first, !venue.isEmpty { record.fields[kind == "proceedings-article" || kind == "book-chapter" ? "booktitle" : "journal"] = text(venue) }
            for name in ["ISBN", "ISSN"] { if let value = (item[name] as? [String])?.first { record.fields[name.lowercased()] = value } }
            for name in ["published-print", "published-online", "issued"] {
                if let date = item[name] as? [String: Any], let parts = date["date-parts"] as? [[Int]], let year = parts.first?.first { record.fields["year"] = String(year); break }
            }
            if kind == "posted-content" { record.fields["entrysubtype"] = "preprint" }
            record.originalCitation = (try? ReferenceBibTeX.export([record])) ?? ""
            return record
        }
    }
    static func parseOpenPDFs(_ data: Data) throws -> [URL] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReferenceFailure("The open-access service returned an unreadable response.") }
        var locations = object["locations"] as? [[String: Any]] ?? []
        if let best = object["best_oa_location"] as? [String: Any] { locations.insert(best, at: 0) }
        func priority(_ location: [String: Any]) -> Int { switch location["version"] as? String { case "publishedVersion": 0; case "acceptedVersion": 1; default: 2 } }
        var seen = Set<URL>()
        return locations.filter { $0["is_oa"] as? Bool == true }.sorted { priority($0) < priority($1) }.compactMap {
            guard let raw = $0["pdf_url"] as? String, let url = URL(string: raw), publicURL(url), seen.insert(url).inserted else { return nil }; return url
        }
    }
    static func landingPDFs(_ data: Data, base: URL) -> [URL] {
        guard data.count <= 192_000, let html = String(data: data, encoding: .utf8) else { return [] }
        let tags = try! NSRegularExpression(pattern: #"<meta\b[^>]{0,4000}>"#, options: .caseInsensitive)
        let attributes = try! NSRegularExpression(pattern: #"([a-zA-Z_-]+)\s*=\s*["']([^"']*)["']"#)
        let links = try! NSRegularExpression(pattern: #"<link\b[^>]{0,4000}>"#, options: .caseInsensitive)
        var result: [URL] = [], seen = Set<URL>()
        let all = tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) + links.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in all.prefix(200) {
            let tag = (html as NSString).substring(with: match.range) as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) { values[tag.substring(with: attribute.range(at: 1)).lowercased()] = tag.substring(with: attribute.range(at: 2)) }
            let meta = values["name"]?.lowercased() == "citation_pdf_url"
            let alternate = values["type"]?.lowercased() == "application/pdf" && (values["rel"] ?? "").lowercased().split(separator: " ").contains("alternate")
            guard meta || alternate, let raw = values[meta ? "content" : "href"], let url = URL(string: text(raw), relativeTo: base)?.absoluteURL, publicURL(url), seen.insert(url).inserted else { continue }
            result.append(url)
            if result.count == 3 { break }
        }
        return result
    }
    static func publicURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name.contains(".") && !["local", "localhost", "internal", "home", "lan"].contains(name.split(separator: ".").last.map(String.init) ?? "") && !name.contains(":") && name.split(separator: ".").last.map { $0.range(of: #"^[a-z][a-z0-9-]{1,62}$"#, options: .regularExpression) != nil } == true
    }
    private static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }
    private static func text(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        private var count = 0
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { count += 1; completionHandler(count <= 8 && request.url.map(publicURL) == true ? request : nil) }
    }
    private static func request(_ url: URL, limit: Int, accept: String, deadline: Date = .distantFuture) async throws -> Data { try await fetch(url, limit: limit, accept: accept, deadline: deadline).0 }
    private static func fetch(_ url: URL, limit: Int, accept: String, headOnly: Bool = false, deadline: Date = .distantFuture) async throws -> (Data, URL) {
        try NetworkAccess.requireOnline(); guard publicURL(url) else { throw ReferenceFailure("Choose a public HTTPS source.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        guard deadline.timeIntervalSinceNow > 0 else { throw ReferenceFailure("PDF lookup timed out. Try again.") }
        configuration.timeoutIntervalForRequest = min(15, deadline.timeIntervalSinceNow); configuration.timeoutIntervalForResource = min(40, deadline.timeIntervalSinceNow)
        let session = URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let lease = try NetworkAccess.gate.watch(session); defer { NetworkAccess.gate.release(lease) }
        var request = URLRequest(url: url); request.setValue(accept, forHTTPHeaderField: "Accept"); request.setValue("remile/0.1.3 Reference", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 { throw ReferenceFailure("The service is busy. Try again shortly.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw ReferenceFailure("The source requires access. You can add the reference without a PDF.") }
        guard http.statusCode == 200 else { throw ReferenceFailure(http.statusCode == 404 ? "No matching record was found." : "The source is unavailable. Try again later.") }
        guard headOnly || response.expectedContentLength <= limit else { throw ReferenceFailure(accept == "application/pdf" ? "Choose a PDF smaller than 25 MB." : "The metadata response is too large.") }
        if accept == "application/pdf", !["application/pdf", "application/octet-stream"].contains(response.mimeType?.lowercased() ?? "") { throw ReferenceFailure("The source did not return a PDF.") }
        if headOnly && response.mimeType?.lowercased() != "text/html" { return (Data(), response.url ?? url) }
        var bytes = Data()
        for try await byte in stream {
            if bytes.count % 16_384 == 0 { try Task.checkCancellation() }
            if headOnly && bytes.count % 8192 == 0 && String(decoding: bytes, as: UTF8.self).localizedCaseInsensitiveContains("</head>") { break }
            guard bytes.count < limit else { if headOnly { break }; throw ReferenceFailure("The response is too large.") }
            bytes.append(byte)
        }
        try NetworkAccess.requireOnline(); return (bytes, response.url ?? url)
    }
}
