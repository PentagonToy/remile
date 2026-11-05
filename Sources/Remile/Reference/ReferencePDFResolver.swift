import Foundation
import PDFKit

/// One explicit search, shared by callers. Discovery never writes to the catalogue.
enum ReferencePDFResolver {
    struct Candidate: Sendable {
        let url: URL
        var version: String = ""
    }
    struct Found: Sendable {
        let data: Data
        let source: URL
        let version: String
    }
    struct Resource: Sendable {
        let data: Data
        let url: URL
        let html: Bool
    }
    typealias Loader = @Sendable (URL, Date) async throws -> Resource
    typealias Locations = @Sendable (String, Date) async throws -> [Candidate]
    typealias Metadata = @Sendable (ReferenceRecord, Date) async throws -> ReferenceRecord

    static func archiveID(_ record: ReferenceRecord) -> String? {
        ReferenceRecognition.archiveID(record) ?? ReferencePDFMetadata.arxivID(in: (record.fields["doi"] ?? "").replacingOccurrences(of: "10.48550/arXiv.", with: "arXiv:", options: .caseInsensitive))
    }

    static func seeds(_ record: ReferenceRecord) -> [Candidate] {
        var urls: [URL] = []
        if let id = archiveID(record), let url = URL(string: "https://arxiv.org/pdf/" + id) { urls.append(url) }
        if let id = record.fields["pmcid"], id.range(of: #"^PMC[0-9]{1,10}$"#, options: .caseInsensitive) != nil,
           let url = URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/" + id.uppercased() + "/pdf/") { urls.append(url) }
        if let raw = record.fields["url"], let url = URL(string: raw), ReferencePaperLookup.publicURL(url) { urls.append(url) }
        let doi = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? "")
        if doi.hasPrefix("10.") {
            var source = URLComponents(string: "https://doi.org")!; source.path = "/" + doi
            if let url = source.url { urls.append(url) }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }.map { Candidate(url: $0) }
    }

    static func resolve(_ record: ReferenceRecord, startingAt url: URL? = nil, load: Loader = ReferencePDFTransfer.fetch, locations: Locations = openLocations, metadata: Metadata = ReferencePaperLookup.pdfMetadata) async throws -> Found {
        guard let found = try await discover(record, startingAt: url, load: load, locations: locations, metadata: metadata).1 else {
            throw ReferenceFailure("No accessible PDF found.")
        }
        return found
    }

    static func fromLink(_ url: URL, target: ReferenceRecord?, load: Loader = ReferencePDFTransfer.fetch) async throws -> (ReferenceRecord, Found?) {
        try await discover(target, startingAt: url, includeRecordSources: false, load: load, locations: openLocations, metadata: ReferencePaperLookup.pdfMetadata)
    }

    private static func discover(_ record: ReferenceRecord?, startingAt url: URL?, includeRecordSources: Bool = true, load: Loader, locations: Locations, metadata: Metadata) async throws -> (ReferenceRecord, Found?) {
        try Task.checkCancellation(); try NetworkAccess.requireOnline()
        let deadline = Date().addingTimeInterval(90)
        var queue = url.map { [Candidate(url: $0)] } ?? []
        if includeRecordSources, let record { queue += seeds(record) }
        var seen = Set<URL>(), blockedHosts = Set<String>(), indexed = false, attempts = 0
        var identified = record ?? ReferenceRecord()
        var landingReference: ReferenceRecord?
        var last: Error = ReferenceFailure("No accessible PDF found. You can add a local PDF.")
        while attempts < 8 && Date() < deadline {
            try Task.checkCancellation()
            if queue.isEmpty {
                guard includeRecordSources, !indexed else { break }
                indexed = true
                if record != nil && (identified.fields["doi"] ?? "").isEmpty && archiveID(identified) == nil && ReferenceRecognition.eligible(identified) {
                    do {
                        let found = try await metadata(identified, deadline)
                        if ReferencePaperLookup.matches(identified, fields: found.fields) {
                            for key in ["doi", "url", "eprint", "archiveprefix"] where identified.fields[key] == nil { identified.fields[key] = found.fields[key] }
                            queue = seeds(identified)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { }
                }
                var doi = ReferenceDuplicates.normaliseDOI(identified.fields["doi"] ?? "")
                if doi.isEmpty, let id = archiveID(identified) { doi = "10.48550/arxiv." + ReferenceArxiv.base(id) }
                if doi.hasPrefix("10.") {
                    do { queue += try await locations(doi, deadline) }
                    catch is CancellationError { throw CancellationError() }
                    catch { /* A failed index does not invalidate another public route. */ }
                }
                if queue.isEmpty || Date() >= deadline { break }
            }
            let candidate = queue.removeFirst()
            guard ReferencePaperLookup.publicURL(candidate.url), !blockedHosts.contains(candidate.url.host ?? ""), seen.insert(candidate.url).inserted else { continue }
            attempts += 1
            do {
                let resource = try await load(candidate.url, deadline)
                try Task.checkCancellation()
                guard Date() < deadline else { break }
                if resource.html {
                    // Only explicit PDF metadata and PDF alternate links, never arbitrary page links.
                    let allowReference = record == nil && attempts == 1 && ReferencePaperLookup.citableWebURL(candidate.url)
                    let landing = ReferencePaperLookup.landing(resource.data, base: resource.url, includeReference: allowReference)
                    if allowReference { landingReference = landing.reference }
                    queue.insert(contentsOf: landing.pdfs.map { Candidate(url: $0, version: candidate.version) }, at: 0)
                    continue
                }
                let declaredPaper = landingReference.flatMap { $0.fields["doi"] == nil ? nil : $0 }
                let expected = record == nil ? declaredPaper : identified
                let result = try await Task.detached { () throws -> ReferenceRecord? in
                    try Task.checkCancellation()
                    guard let pdf = readablePDF(resource.data) else { return nil }
                    var fields = ReferencePDFMetadata.fields(pdf, fallback: "")
                    if let expected {
                        guard matchesPDF(fields, for: expected) else { return nil }
                        if record != nil { return expected }
                    }
                    if fields["title"] == "" {
                        let name = resource.url.deletingPathExtension().lastPathComponent
                        fields["title"] = name.lowercased().hasSuffix(".pdf") ? String(name.dropLast(4)) : name
                    }
                    var draft = ReferenceRecord(fields: fields)
                    if draft.fields["entrysubtype"] == "preprint" { draft.type = "misc" }
                    if let degree = ReferenceKind.thesisKind(draft.fields["type"] ?? "") { draft = degree.applying(to: draft) }
                    return draft
                }.value
                try Task.checkCancellation()
                guard let result else { last = ReferenceFailure("The PDF could not be matched or opened. You can add it locally after checking."); continue }
                return (result, Found(data: resource.data, source: resource.url, version: candidate.version))
            } catch is CancellationError { throw CancellationError() }
            catch let busy as ReferencePDFTransfer.Busy { blockedHosts.insert(candidate.url.host ?? ""); blockedHosts.insert(busy.host); last = busy }
            catch { last = error }
        }
        try Task.checkCancellation()
        try NetworkAccess.requireOnline()
        if let landingReference { return (landingReference, nil) }
        throw last
    }

    static func readLocal(_ url: URL, for record: ReferenceRecord) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ReferencePaperLookup.pdfLimit else { throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ReferencePaperLookup.pdfLimit + 1) ?? Data()
        guard data.count <= ReferencePaperLookup.pdfLimit else { throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
        guard try validate(data, for: record) else { throw ReferenceFailure("This PDF does not match the selected paper. Check the downloaded file.") }
        return data
    }

    static func validate(_ data: Data, for record: ReferenceRecord) throws -> Bool {
        try Task.checkCancellation()
        guard let pdf = readablePDF(data) else { return false }
        return matchesPDF(ReferencePDFMetadata.fields(pdf, fallback: ""), for: record)
    }

    private static func matchesPDF(_ fields: [String: String], for record: ReferenceRecord) -> Bool {
        let extractedTitle = (fields["title"] ?? "").lowercased()
        if ["supplementary", "supplemental", "supporting information"].contains(where: extractedTitle.contains), !ReferencePaperLookup.matches(record, fields: ["title": fields["title"] ?? ""]) { return false }
        if let wanted = archiveID(record) {
            guard let actual = fields["eprint"], ReferenceArxiv.base(actual).lowercased() == ReferenceArxiv.base(wanted).lowercased() else { return false }
            return !wanted.contains("v") || wanted.lowercased() == actual.lowercased()
        }
        // A book DOI can appear in a chapter. Whole books require a matching title too.
        if ["book", "proceedings", "collection"].contains(record.type) {
            let wanted = ReferenceDuplicates.normaliseDOI(record.fields["doi"] ?? ""), actual = ReferenceDuplicates.normaliseDOI(fields["doi"] ?? "")
            if !wanted.isEmpty && !actual.isEmpty && wanted != actual { return false }
            var titleOnly = record; titleOnly.fields.removeValue(forKey: "doi")
            return ReferencePaperLookup.matches(titleOnly, fields: ["title": fields["title"] ?? ""])
        }
        return ReferencePaperLookup.matches(record, fields: fields)
    }

    private static func readablePDF(_ data: Data) -> PDFDocument? {
        guard data.count <= ReferencePaperLookup.pdfLimit, data.prefix(5) == Data("%PDF-".utf8),
              let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { return nil }
        return pdf
    }

    static func openLocations(_ doi: String, deadline: Date) async throws -> [Candidate] {
        let data = try await ReferencePaperLookup.openAccessData(doi: doi, deadline: deadline)
        return try parseLocations(data)
    }
    static func parseLocations(_ data: Data) throws -> [Candidate] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var locations = object["locations"] as? [[String: Any]] ?? []
        if let best = object["best_oa_location"] as? [String: Any] { locations.insert(best, at: 0) }
        func rank(_ item: [String: Any]) -> Int { item["version"] as? String == "publishedVersion" ? 0 : item["version"] as? String == "acceptedVersion" ? 1 : 2 }
        var seen = Set<URL>(), result: [Candidate] = []
        for item in locations.filter({ $0["is_oa"] as? Bool == true }).sorted(by: { rank($0) < rank($1) }) {
            let version = ["publishedVersion": "Published version", "acceptedVersion": "Accepted manuscript", "submittedVersion": "Preprint"][item["version"] as? String ?? ""] ?? ""
            for key in ["pdf_url", "landing_page_url"] {
                if let raw = item[key] as? String, let url = URL(string: raw), ReferencePaperLookup.publicURL(url), seen.insert(url).inserted { result.append(Candidate(url: url, version: version)) }
            }
            if result.count >= 12 { break }
        }
        return Array(result.prefix(12))
    }
}

/// Bounded, cookie-free retrieval. Partial downloads live only for this request.
enum ReferencePDFTransfer {
    struct Busy: LocalizedError {
        let host: String
        var errorDescription: String? { "The source is busy. Try again later." }
    }
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        private var count = 0
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            count += 1
            completionHandler(count <= 8 && request.url.map(ReferencePaperLookup.publicURL) == true ? request : nil)
        }
    }
    static func fetch(_ url: URL, deadline: Date) async throws -> ReferencePDFResolver.Resource {
        try NetworkAccess.requireOnline()
        guard ReferencePaperLookup.publicURL(url), deadline.timeIntervalSinceNow > 0 else { throw ReferenceFailure("PDF lookup timed out. Try again.") }
        try await ReferencePDFPacing.shared.wait(url.host ?? "")
        try Task.checkCancellation(); try NetworkAccess.requireOnline()
        guard deadline.timeIntervalSinceNow > 0 else { throw ReferenceFailure("PDF lookup timed out. Try again.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = min(15, deadline.timeIntervalSinceNow)
        configuration.timeoutIntervalForResource = min(30, deadline.timeIntervalSinceNow)
        let session = URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let lease = try NetworkAccess.gate.watch(session); defer { NetworkAccess.gate.release(lease) }
        var request = URLRequest(url: url)
        request.setValue("application/pdf,text/html;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("remile/0.1.3 Reference", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if [401, 403].contains(http.statusCode) {
            let signed = URLComponents(url: http.url ?? url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name.caseInsensitiveCompare("X-Amz-Signature") == .orderedSame
            } == true
            if signed { throw ReferenceFailure("The signed PDF link was refused or expired. Copy a fresh link from the article page.") }
            throw ReferenceFailure("The source refused access. Download the PDF in your browser and add the local file.")
        }
        // Do not retry a throttled host during this search, including its alternate links.
        if [429, 503].contains(http.statusCode) { throw Busy(host: response.url?.host ?? url.host ?? "") }
        guard http.statusCode == 200 else { throw ReferenceFailure("No accessible PDF found. You can add a local PDF.") }
        let html = ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "")
        guard html || ["application/pdf", "application/octet-stream"].contains(response.mimeType?.lowercased() ?? "") else { throw ReferenceFailure("The source did not return a PDF.") }
        let limit = html ? 192_000 : ReferencePaperLookup.pdfLimit
        guard html || response.expectedContentLength <= limit else { throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remile-pdf-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("download")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        var buffer = Data(), count = 0, head = Data()
        buffer.reserveCapacity(32_768)
        for try await byte in stream {
            guard count < limit else { if html { break }; throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
            buffer.append(byte); count += 1
            if !html && count == 5 && buffer != Data("%PDF-".utf8) { throw ReferenceFailure("The source did not return a PDF.") }
            if buffer.count == 32_768 {
                try Task.checkCancellation(); try NetworkAccess.requireOnline()
                guard Date() < deadline else { throw ReferenceFailure("PDF lookup timed out. Try again.") }
                try handle.write(contentsOf: buffer)
                if html { head.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
                if html && String(decoding: head, as: UTF8.self).localizedCaseInsensitiveContains("</head>") { break }
            }
        }
        try handle.write(contentsOf: buffer)
        try Task.checkCancellation(); try NetworkAccess.requireOnline()
        guard Date() < deadline else { throw ReferenceFailure("PDF lookup timed out. Try again.") }
        return .init(data: try Data(contentsOf: file, options: .mappedIfSafe), url: response.url ?? url, html: html)
    }
}

private actor ReferencePDFPacing {
    static let shared = ReferencePDFPacing()
    private var next: [String: Date] = [:]
    func wait(_ host: String) async throws {
        let now = Date(), start = max(now, next[host] ?? now)
        next = next.filter { $0.value > now }
        next[host] = start.addingTimeInterval(1)
        let delay = start.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
    }
}
