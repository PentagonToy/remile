import Foundation
import PDFKit

/// Explicit, bounded public lookups. No account cookies, background polling or automatic library writes.
enum ReferencePaperLookup {
    static let pdfLimit = 25 * 1024 * 1024
    struct Paper: Identifiable, Sendable { let record: ReferenceRecord; var id: UUID { record.id } }
    static func search(_ query: String) async throws -> [Paper] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw ReferenceFailure("Enter a DOI or a title of up to 500 characters.") }
        let doi = ReferenceDuplicates.normaliseDOI(query)
        var url = URLComponents(string: "https://api.crossref.org/works")!
        let single = doi.hasPrefix("10.") && !doi.contains(where: \.isWhitespace)
        if single { url.percentEncodedPath += "/" + encoded(doi) }
        else { url.queryItems = [URLQueryItem(name: "query.bibliographic", value: query), URLQueryItem(name: "rows", value: "5")] }
        let data = try await request(url.url!, limit: 1_500_000, accept: "application/json")
        return try parseCrossref(data, single: single).map { Paper(record: $0) }
    }
    static func openPDFs(doi: String) async throws -> [URL] {
        guard doi.hasPrefix("10.") else { return [] }
        var url = URLComponents(string: "https://api.openalex.org")!
        url.percentEncodedPath = "/works/https://doi.org/" + encoded(doi)
        let data = try await request(url.url!, limit: 2_000_000, accept: "application/json")
        let direct = try parseOpenPDFs(data)
        if !direct.isEmpty { return direct }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["open_access"] as? [String: Any], access["is_oa"] as? Bool == true,
              let raw = access["oa_url"] as? String, let landing = URL(string: raw), publicURL(landing) else { return [] }
        let (head, resolved) = try await fetch(landing, limit: 192_000, accept: "text/html", headOnly: true)
        return landingPDFs(head, base: resolved)
    }
    static func download(_ candidates: [URL]) async throws -> Data {
        var last: Error = ReferenceFailure("No open PDF was found. You can add the reference without a PDF.")
        for url in candidates.prefix(2) {
            try Task.checkCancellation()
            do {
                let bytes = try await request(url, limit: pdfLimit, accept: "application/pdf")
                guard bytes.prefix(5) == Data("%PDF-".utf8), let pdf = PDFDocument(data: bytes), !pdf.isLocked, pdf.pageCount > 0 else { throw ReferenceFailure("The source did not return a readable PDF.") }
                return bytes
            } catch is CancellationError { throw CancellationError() }
            catch { last = error }
        }
        throw last
    }
    static func parseCrossref(_ data: Data, single: Bool) throws -> [ReferenceRecord] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] as? [String: Any] else { throw ReferenceFailure("The metadata service returned an unreadable response.") }
        let items = single ? [message] : message["items"] as? [[String: Any]] ?? []
        return items.prefix(5).compactMap { item in
            guard let raw = (item["title"] as? [String])?.first else { return nil }
            let title = text(raw); guard !title.isEmpty else { return nil }
            var record = ReferenceRecord()
            let kind = item["type"] as? String ?? ""
            record.type = ["journal-article": "article", "proceedings-article": "inproceedings", "book": "book", "monograph": "book", "book-chapter": "incollection"][kind] ?? "misc"
            record.fields["title"] = title
            let authors = (item["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
                let family = (author["family"] as? String).map(text) ?? "", given = (author["given"] as? String).map(text) ?? ""
                if !family.isEmpty { return family + (given.isEmpty ? "" : ", " + given) }
                return (author["name"] as? String).map { "{" + text($0) + "}" }
            }
            if !authors.isEmpty { record.fields["author"] = authors.joined(separator: " and ") }
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
        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let tag = (html as NSString).substring(with: match.range) as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) { values[tag.substring(with: attribute.range(at: 1)).lowercased()] = tag.substring(with: attribute.range(at: 2)) }
            guard values["name"]?.lowercased() == "citation_pdf_url", let raw = values["content"], let url = URL(string: text(raw), relativeTo: base)?.absoluteURL, publicURL(url) else { continue }
            return [url]
        }
        return []
    }
    static func publicURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host.contains(".") && !host.hasSuffix(".local") && !host.hasSuffix(".localhost") && !host.hasSuffix(".internal") && !host.contains(":") && host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil
    }
    private static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }
    private static func text(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(request.url.map(publicURL) == true ? request : nil) }
    }
    private static func request(_ url: URL, limit: Int, accept: String) async throws -> Data { try await fetch(url, limit: limit, accept: accept).0 }
    private static func fetch(_ url: URL, limit: Int, accept: String, headOnly: Bool = false) async throws -> (Data, URL) {
        try NetworkAccess.requireOnline(); guard publicURL(url) else { throw ReferenceFailure("Choose a public HTTPS source.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 40
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
