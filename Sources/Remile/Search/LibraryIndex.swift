import Foundation
import PDFKit
import SQLite3

struct LibraryFolder: Identifiable, Sendable {
    let id: String
    let path: String
    let bookmark: Data
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    func url() throws -> URL { try resolved().url }
    func resolved() throws -> (url: URL, renew: Bool) {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            return (url, stale)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain, failure.code == CocoaError.fileReadCorruptFile.rawValue else { throw error }
            do { return (try Self.verifiedUnscopedURL(bookmark, path: path), true) }
            catch { throw LibraryIndex.Failure.inaccessible }
        }
    }
    static func verifiedUnscopedURL(_ bookmark: Data, path: String) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
        let expected = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let actual = url.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard url.isFileURL, actual.path == expected.path,
              FileManager.default.fileExists(atPath: actual.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: actual.path) else { throw LibraryIndex.Failure.inaccessible }
        return actual
    }

}

struct LibrarySummary: Sendable {
    var folders: [LibraryFolder] = []
    var documents = 0
    var pages = 0
    var needsOCR = 0
    var failed = 0
    var needsAttention = 0
}
struct LibraryIndexedDocument: Identifiable, Sendable {
    let path: String
    let emptyPages: Int
    let failed: Bool
    var id: String { path }
    var status: String { failed ? "Not indexed" : emptyPages > 0 ? "\(emptyPages) pages without text" : "Indexed" }
}

struct LibraryHit: Identifiable, Sendable {
    let path: String
    let folderID: String
    let page: Int
    let excerpt: String
    let score: Double
    var sectionTitle: String? = nil
    var matchQuery: String? = nil
    var id: String { path + "#" + String(page) }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    var isMarkdown: Bool { URL(fileURLWithPath: path).pathExtension.lowercased() != "pdf" }
    var location: String { isMarkdown ? (sectionTitle ?? "Section \(page)") : "Page \(page)" }
}

struct LibrarySearchPage: Sendable {
    let hits: [LibraryHit]
    let hasMore: Bool
}

struct LibraryProgress: Sendable {
    let completed: Int
    let total: Int
    let name: String
    var preparingSearch = false
}

enum SearchScope {
    static let bibliographyPreference = "search.includeBibliography"
    static var includesBibliography: Bool { UserDefaults.standard.bool(forKey: bibliographyPreference) }
}

struct SearchPageStructure {
    let body: String
    let bibliography: String
    static func marginKey(_ line: String) -> String {
        line.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNumber }).joined(separator: " ")
    }
    static func marginLines(_ text: String) -> Set<String> {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 8 else { return [] }
        return Set((Array(lines.prefix(2)) + Array(lines.suffix(2))).map(marginKey).filter { (8...120).contains($0.count) })
    }
    private static let references = try! NSRegularExpression(pattern: "(?i)^(?:[0-9.]+[ .]+)?(?:references|bibliography|literature cited)$")
    private static let entry = try! NSRegularExpression(pattern: "^(?:\\s*\\[\\d+\\]|\\s*\\d+[.)]\\s)|\\b(?:19|20)\\d{2}[a-z]?\\b")
    private static let resume = try! NSRegularExpression(pattern: "(?i)^(?:appendix(?:[ .:]|$)|appendices$|chapter[ \\t]+[0-9]+|supplementary material)")
    static func analyse(_ text: String, repeatedMargins: Set<String> = [], inBibliography: inout Bool) -> Self {
        let lines = text.components(separatedBy: .newlines)
        var body: [String] = [], bibliography: [String] = []
        if inBibliography {
            let evidence = lines.filter { entry.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }.count
            if evidence < 2 { inBibliography = false }
        }
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            if resume.firstMatch(in: trimmed, range: range) != nil { inBibliography = false }
            if references.firstMatch(in: trimmed, range: range) != nil {
                let following = lines.dropFirst(offset + 1).prefix(24)
                let evidence = following.filter { entry.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }.count
                if evidence >= 2 { inBibliography = true }
            }
            let margin = offset < 2 || offset >= lines.count - 2
            if margin && repeatedMargins.contains(marginKey(line)) { continue }
            if margin && trimmed.allSatisfy(\.isNumber) && !trimmed.isEmpty { continue }
            if inBibliography { bibliography.append(line) } else { body.append(line) }
        }
        let content = body.joined(separator: "\n")
        // A page start is not evidence of a heading. Markdown headings are supplied separately.
        return Self(body: content, bibliography: bibliography.joined(separator: "\n"))
    }
}

/// Serial ownership of one SQLite connection; PDF objects never leave this actor.
actor LibraryIndex {
    enum Failure: LocalizedError {
        case database(String), folderOverlap, inaccessible, invalidPDF, emptyQuery, invalidQuery
        var errorDescription: String? {
            switch self {
            case .database(let message): return "The search index could not be updated: \(message)"
            case .folderOverlap: return "This folder is already covered by the library. Choose a separate folder."
            case .inaccessible: return "The folder is unavailable. Reconnect its drive or add it again."
            case .invalidPDF: return "This PDF is locked, damaged or does not allow text extraction."
            case .emptyQuery: return "Enter words or a phrase in quotation marks."
            case .invalidQuery: return "Use balanced quotation marks and no more than 24 terms or 512 characters."
            }
        }
    }
    private var database: OpaquePointer?
    private var sparseRanker: SparseSearchRanker?
    private var sparseVersion: Int32 = -1
    private var sparseKey = ""
    private(set) var lastRankerPreparation = "none"
    private let managedLocation: Bool
    private let location: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(location: URL? = nil) {
        self.location = location ?? StorageLocation.search()
        self.managedLocation = location == nil
    }
    deinit { if let database { sqlite3_close(database) } }

    private func connect() throws {
        if managedLocation { try StorageLocation.requireAvailable() }
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(location.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open storage."
            if let handle { sqlite3_close(handle) }
            throw Failure.database(message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 1500)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS folders(id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, bookmark BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS documents(path TEXT PRIMARY KEY, folder TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE, revision TEXT NOT NULL, pages INTEGER NOT NULL, empty_pages INTEGER NOT NULL, error TEXT)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(path UNINDEXED, page UNINDEXED, heading, body, tokenize='unicode61 remove_diacritics 2')")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search_pages USING fts5(path UNINDEXED,page UNINDEXED,heading,body,bibliography,tokenize='unicode61 remove_diacritics 2')")
            try execute("CREATE TABLE IF NOT EXISTS search_identity(id TEXT NOT NULL)")
            try execute("INSERT INTO search_identity SELECT lower(hex(randomblob(16))) WHERE NOT EXISTS(SELECT 1 FROM search_identity)")
            try execute("CREATE TABLE IF NOT EXISTS search_metadata(key TEXT PRIMARY KEY,value INTEGER NOT NULL)")
            try execute("INSERT OR IGNORE INTO search_metadata VALUES('generation',0)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search_vocabulary USING fts5vocab(search_pages, 'row')")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS vocabulary USING fts5vocab(pages, 'row')")
        } catch {
            sqlite3_close(handle); database = nil; throw error
        }
    }

    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(result, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(result); throw failure()
            }
        }
        return result
    }
    private func failure() -> Failure { .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Storage is closed.") }
    private func text(_ row: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(row, column).map { String(cString: $0) } ?? "" }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let row = try statement(sql, values); defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw failure() }
    }

    func indexedDocuments(issuesOnly: Bool = false) throws -> [LibraryIndexedDocument] {
        try connect()
        let rows = try statement("SELECT path,empty_pages,error IS NOT NULL FROM documents WHERE ?='0' OR error IS NOT NULL OR empty_pages>0 ORDER BY error IS NOT NULL DESC,empty_pages DESC,path LIMIT 2000", [issuesOnly ? "1" : "0"]); defer { sqlite3_finalize(rows) }
        // Only problem files are requested by the Library panel.
        var result: [LibraryIndexedDocument] = []
        while sqlite3_step(rows) == SQLITE_ROW {
            result.append(LibraryIndexedDocument(path: text(rows, 0), emptyPages: Int(sqlite3_column_int(rows, 1)), failed: sqlite3_column_int(rows, 2) != 0))
        }
        return result
    }
    func summary() throws -> LibrarySummary {
        try connect()
        var result = LibrarySummary()
        let folders = try statement("SELECT id,path,bookmark FROM folders ORDER BY path")
        defer { sqlite3_finalize(folders) }
        while sqlite3_step(folders) == SQLITE_ROW {
            let bytes = sqlite3_column_bytes(folders, 2)
            guard let blob = sqlite3_column_blob(folders, 2), bytes > 0 else { continue }
            var folder = LibraryFolder(id: text(folders, 0), path: text(folders, 1), bookmark: Data(bytes: blob, count: Int(bytes)))
            if let resolved = try? folder.resolved(), resolved.renew {
                let scope = resolved.url.startAccessingSecurityScopedResource()
                defer { if scope { resolved.url.stopAccessingSecurityScopedResource() } }
                if let renewed = try? resolved.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    let update = try statement("UPDATE folders SET bookmark=? WHERE id=?", ["", folder.id])
                    let binding = renewed.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), transient) }
                    let saved = binding == SQLITE_OK && sqlite3_step(update) == SQLITE_DONE
                    sqlite3_finalize(update)
                    if saved { folder = LibraryFolder(id: folder.id, path: folder.path, bookmark: renewed) }
                }
            }
            result.folders.append(folder)
        }
        let totals = try statement("SELECT COUNT(*),COALESCE(SUM(pages),0),COALESCE(SUM(empty_pages),0),COALESCE(SUM(error IS NOT NULL),0),COALESCE(SUM(error IS NOT NULL OR empty_pages>0),0) FROM documents")
        defer { sqlite3_finalize(totals) }
        if sqlite3_step(totals) == SQLITE_ROW {
            result.documents = Int(sqlite3_column_int(totals, 0)); result.pages = Int(sqlite3_column_int(totals, 1))
            result.needsOCR = Int(sqlite3_column_int(totals, 2)); result.failed = Int(sqlite3_column_int(totals, 3)); result.needsAttention = Int(sqlite3_column_int(totals, 4))
        }
        return result
    }

    func add(_ url: URL) throws {
        try connect()
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        for folder in try summary().folders {
            let path = folder.path
            if canonical.path == path || canonical.path.hasPrefix(path + "/") || path.hasPrefix(canonical.path + "/") { throw Failure.folderOverlap }
        }
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let row = try statement("INSERT INTO folders VALUES(?,?,?)", [UUID().uuidString, canonical.path])
        defer { sqlite3_finalize(row) }
        let status = bookmark.withUnsafeBytes { sqlite3_bind_blob(row, 3, $0.baseAddress, Int32($0.count), transient) }
        guard status == SQLITE_OK, sqlite3_step(row) == SQLITE_DONE else { throw failure() }
    }

    private func invalidateRanker() {
        sparseRanker = nil
        for suffix in ["body-rank", "all-rank"] { try? FileManager.default.removeItem(at: location.deletingPathExtension().appendingPathExtension(suffix)) }
    }
    func remove(_ folder: LibraryFolder) throws {
        try connect(); invalidateRanker(); try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE search_metadata SET value=value+1 WHERE key='generation'")
            try execute("DELETE FROM search_pages WHERE path IN (SELECT path FROM documents WHERE folder=?)", [folder.id])
            try execute("DELETE FROM pages WHERE path IN (SELECT path FROM documents WHERE folder=?)", [folder.id])
            try execute("DELETE FROM folders WHERE id=?", [folder.id])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func refresh(folderID: String? = nil, force: Bool = false, progress: @Sendable (LibraryProgress) async -> Void) async throws {
        try connect(); try ensureSearchText()
        for folder in try summary().folders where folderID == nil || folder.id == folderID {
            try Task.checkCancellation()
            let url = try folder.url()
            let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.inaccessible }
            // An incomplete traversal must never remove files from the previous index.
            var traversalError: Error?
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                traversalError = error; return false
            }) else { throw Failure.inaccessible }
            var files: [URL] = []
            while let file = walker.nextObject() as? URL {
                try Task.checkCancellation()
                if ["pdf", "md", "markdown", "mdown"].contains(file.pathExtension.lowercased()), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(file.resolvingSymlinksInPath()) }
            }
            if let traversalError { throw traversalError }
            var seen = Set<String>()
            for (offset, file) in files.sorted(by: { $0.path < $1.path }).enumerated() {
                try Task.checkCancellation()
                seen.insert(file.path)
                await progress(LibraryProgress(completed: offset, total: files.count, name: file.lastPathComponent))
                try index(file, folder: folder.id, force: force)
                await progress(LibraryProgress(completed: offset + 1, total: files.count, name: file.lastPathComponent))
            }
            try Task.checkCancellation()
            let existing = try statement("SELECT path FROM documents WHERE folder=?", [folder.id])
            var removed: [String] = []
            while sqlite3_step(existing) == SQLITE_ROW { let path = text(existing, 0); if !seen.contains(path) { removed.append(path) } }
            sqlite3_finalize(existing)
            if !removed.isEmpty { invalidateRanker() }
            try execute("BEGIN IMMEDIATE")
            do {
                for path in removed { try execute("DELETE FROM search_pages WHERE path=?", [path]); try execute("DELETE FROM pages WHERE path=?", [path]); try execute("DELETE FROM documents WHERE path=?", [path]) }
                if !removed.isEmpty { try execute("UPDATE search_metadata SET value=value+1 WHERE key='generation'") }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        try Task.checkCancellation()
        await progress(LibraryProgress(completed: 0, total: 1, name: "Preparing search…", preparingSearch: true))
        try prepareSearch()
    }

    private func revision(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        return "search-v4:\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0):\(String(describing: values.fileResourceIdentifier))"
    }
    private func index(_ url: URL, folder: String, force: Bool = false) throws {
        try Task.checkCancellation()
        let stamp = try revision(url)
        let previous = try statement("SELECT revision,error FROM documents WHERE path=?", [url.path])
        let unchanged = sqlite3_step(previous) == SQLITE_ROW && text(previous, 0) == stamp && sqlite3_column_type(previous, 1) == SQLITE_NULL
        sqlite3_finalize(previous)
        if unchanged && !force { return }
        invalidateRanker()
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM search_pages WHERE path=?", [url.path])
            try execute("DELETE FROM pages WHERE path=?", [url.path])
            try autoreleasepool {
                if url.pathExtension.lowercased() != "pdf" {
                    let sections = SearchMarkdown.sections(try SearchMarkdown.read(url))
                    for section in sections {
                        try Task.checkCancellation()
                        try execute("INSERT INTO pages(path,page,heading,body) VALUES(?,?,?,?)", [url.path, String(section.number), section.title, SearchMarkdown.searchText(section.source)])
                    }
                    guard try revision(url) == stamp else { throw CocoaError(.fileReadUnknown) }
                    try execute("INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,NULL)", [url.path, folder, stamp, String(sections.count), "0"])
                    return
                }
                guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.allowsCopying else { throw Failure.invalidPDF }
                var empty = 0
                for number in 0..<pdf.pageCount {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let body = pdf.page(at: number)?.string ?? ""
                        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1; return }
                        let heading = ""
                        try execute("INSERT INTO pages(path,page,heading,body) VALUES(?,?,?,?)", [url.path, String(number + 1), heading, body])
                    }
                }
                guard try revision(url) == stamp else { throw CocoaError(.fileReadUnknown) }
                try execute("INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,NULL)", [url.path, folder, stamp, String(pdf.pageCount), String(empty)])
            }
            try prepareSearchText(url.path)
            try execute("UPDATE search_metadata SET value=value+1 WHERE key='generation'")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            if error is CancellationError { throw error }
            // Preserve old bytes for retry, but hide stale results until a successful refresh.
            try execute("INSERT OR REPLACE INTO documents VALUES(?,?,?,0,0,?)", [url.path, folder, "", error.localizedDescription])
            try execute("UPDATE search_metadata SET value=value+1 WHERE key='generation'")
        }
    }

    /// Quoted phrases stay together; all terms are required and FTS syntax is escaped.
    static func queryTerms(_ query: String) throws -> [String] {
        guard query.count <= 512, query.filter({ $0 == "\"" }).count.isMultiple(of: 2) else { throw Failure.invalidQuery }
        let regex = try NSRegularExpression(pattern: "\"([^\"]+)\"|([^\\s\"]+)")
        let source = query as NSString
        let matches = regex.matches(in: query, range: NSRange(location: 0, length: source.length))
        guard matches.count <= 24 else { throw Failure.invalidQuery }
        let groups = matches.compactMap { match -> String? in
            let range = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
            let term = source.substring(with: range)
            guard term.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
            return term
        }
        guard !groups.isEmpty else { throw Failure.emptyQuery }
        return groups
    }

    static func expression(_ query: String) throws -> String {
        try queryTerms(query).map { "\"" + SearchNormalisation.indexText($0) + "\"" }.joined(separator: " AND ")
    }

    func spellingSuggestions(_ query: String) throws -> [String] {
        try connect()
        guard !query.contains("\""), let groups = try? Self.queryTerms(query), groups.count <= 6,
              groups.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return [] }
        let words = groups.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        var choices = [[String]](), changed = 0
        for word in words {
            try Task.checkCancellation()
            let exact = try statement("SELECT term FROM search_vocabulary WHERE term=?", [word])
            let known = sqlite3_step(exact) == SQLITE_ROW; sqlite3_finalize(exact)
            if known || word.count < 4 || word.count > 32 { choices.append([word]); continue }
            changed += 1; guard changed <= 2 else { return [] }
            let limit = word.count >= 7 ? 2 : 1
            let row = try statement("SELECT term,doc FROM search_vocabulary WHERE length(term) BETWEEN CAST(? AS INTEGER) AND CAST(? AS INTEGER) ORDER BY doc DESC,term LIMIT 4000", [String(word.count - limit), String(word.count + limit)])
            var candidates: [(String, Int, Int)] = []
            while sqlite3_step(row) == SQLITE_ROW {
                let term = text(row, 0), distance = SearchExpansion.distance(word, term, limit: limit)
                if distance <= limit { candidates.append((term, distance, Int(sqlite3_column_int(row, 1)))) }
            }
            sqlite3_finalize(row)
            candidates.sort { a, b in a.1 == b.1 ? (a.2 == b.2 ? a.0 < b.0 : a.2 > b.2) : a.1 < b.1 }
            guard !candidates.isEmpty else { return [] }
            choices.append(candidates.prefix(2).map { $0.0 })
        }
        guard changed > 0 else { return [] }
        var variants: [[String]] = [[]]
        for choice in choices { variants = variants.flatMap { prefix in choice.map { prefix + [$0] } }.prefix(3).map { $0 } }
        var suggestions: [String] = []
        for variant in variants {
            let text = variant.joined(separator: " ")
            if try !search(text).isEmpty { suggestions.append(text) }
        }
        return suggestions
    }
    func explorationVocabulary() throws -> [String] {
        try connect()
        let row = try statement("SELECT term FROM search_vocabulary WHERE length(term) BETWEEN 4 AND 32 ORDER BY doc DESC,term LIMIT 2000")
        defer { sqlite3_finalize(row) }
        let common = Set("about after again also been before being between both could each from have into more most other over same some such than that their them then there these they this those through under very were what when where which while with would your".split(separator: " ").map(String.init))
        var terms: [String] = []
        while sqlite3_step(row) == SQLITE_ROW && terms.count < 160 {
            try Task.checkCancellation()
            let term = text(row, 0)
            if !common.contains(term) && term.allSatisfy(\.isLetter) { terms.append(term) }
        }
        return terms
    }

    /// Candidate page numbers from this exact, current file; the reader re-reads its live PDF text.
    func assistantPages(path: String, terms: [String]) throws -> [Int]? {
        guard !terms.isEmpty, FileManager.default.fileExists(atPath: location.path) else { return nil }
        try connect()
        let stamp = try revision(URL(fileURLWithPath: path))
        let document = try statement("SELECT revision FROM documents WHERE path=? AND error IS NULL", [path])
        defer { sqlite3_finalize(document) }
        guard sqlite3_step(document) == SQLITE_ROW, text(document, 0) == stamp else { return nil }
        let expression = terms.prefix(24).map { "\"" + SearchNormalisation.indexText($0) + "\"" + ($0.count >= 4 ? "*" : "") }.joined(separator: " OR ")
        let row = try statement("SELECT page FROM pages WHERE pages MATCH ? AND path=? ORDER BY bm25(pages,0,0,4,1),CAST(page AS INTEGER) LIMIT 12", [expression, path])
        defer { sqlite3_finalize(row) }
        var result: [Int] = []
        var status = sqlite3_step(row)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            result.append(Int(sqlite3_column_int(row, 0))); status = sqlite3_step(row)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result.isEmpty ? nil : result
    }

    /// Re-read complete indexed passages only for explicit cloud questions.
    func answerContext(_ hits: [LibraryHit]) throws -> [LibraryHit] {
        try connect()
        return try hits.prefix(12).compactMap { hit in
            let row = try statement("SELECT body FROM pages WHERE path=? AND page=? AND path IN (SELECT path FROM documents WHERE error IS NULL)", [hit.path, String(hit.page)])
            defer { sqlite3_finalize(row) }
            guard sqlite3_step(row) == SQLITE_ROW else { return nil }
            return LibraryHit(path: hit.path, folderID: hit.folderID, page: hit.page, excerpt: String(text(row, 0).prefix(8000)), score: hit.score, sectionTitle: hit.sectionTitle)
        }
    }

    private func metadata(_ key: String) throws -> Int64 {
        let row = try statement("SELECT value FROM search_metadata WHERE key=?", [key]); defer { sqlite3_finalize(row) }
        return sqlite3_step(row) == SQLITE_ROW ? sqlite3_column_int64(row, 0) : 0
    }
    private func ensureSearchText() throws {
        guard try metadata("format") != 1 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM search_pages")
            let paths = try statement("SELECT path FROM documents WHERE error IS NULL ORDER BY path")
            defer { sqlite3_finalize(paths) }
            while sqlite3_step(paths) == SQLITE_ROW { try Task.checkCancellation(); try prepareSearchText(text(paths, 0)) }
            try execute("INSERT OR REPLACE INTO search_metadata VALUES('format',1)")
            try execute("UPDATE search_metadata SET value=value+1 WHERE key='generation'")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepareSearchText(_ path: String) throws {
        let pdf = URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
        var repeated = Set<String>()
        if pdf {
            let rows = try statement("SELECT body FROM pages WHERE path=?", [path]); defer { sqlite3_finalize(rows) }
            var counts: [String: Int] = [:], pageCount = 0
            while sqlite3_step(rows) == SQLITE_ROW {
                try Task.checkCancellation(); pageCount += 1
                for key in SearchPageStructure.marginLines(text(rows, 0)) { counts[key, default: 0] += 1 }
            }
            repeated = Set(counts.filter { $0.value >= max(3, (pageCount + 1) / 2) }.map(\.key))
        }
        let rows = try statement("SELECT rowid,page,heading,body FROM pages WHERE path=? ORDER BY CAST(page AS INTEGER)", [path]); defer { sqlite3_finalize(rows) }
        var bibliography = false
        while sqlite3_step(rows) == SQLITE_ROW {
            try Task.checkCancellation()
            let raw = text(rows, 3), analysis = SearchPageStructure.analyse(raw, repeatedMargins: repeated, inBibliography: &bibliography)
            let heading = pdf ? "" : text(rows, 2)
            try execute("INSERT OR REPLACE INTO search_pages(rowid,path,page,heading,body,bibliography) VALUES(?,?,?,?,?,?)", [String(sqlite3_column_int64(rows, 0)), path, text(rows, 1), SearchNormalisation.indexText(heading), SearchNormalisation.indexText(analysis.body), SearchNormalisation.indexText(analysis.bibliography)])
        }
    }

    func prepareSearch(includeBibliography: Bool = SearchScope.includesBibliography) throws {
        try connect(); try ensureSearchText()
        let identityRow = try statement("SELECT id FROM search_identity"); defer { sqlite3_finalize(identityRow) }
        guard sqlite3_step(identityRow) == SQLITE_ROW else { throw failure() }
        let key = "rank-v2:\(text(identityRow, 0)):\(try metadata("generation")):\(includeBibliography)"
        let versionRow = try statement("PRAGMA data_version")
        let version = sqlite3_step(versionRow) == SQLITE_ROW ? sqlite3_column_int(versionRow, 0) : -1
        sqlite3_finalize(versionRow)
        if sparseRanker == nil || sparseVersion != version || sparseKey != key {
            let cache = location.deletingPathExtension().appendingPathExtension(includeBibliography ? "all-rank" : "body-rank")
            if let restored = try? SparseSearchRanker.load(from: cache, key: key) {
                sparseRanker = restored; sparseVersion = version; sparseKey = key; lastRankerPreparation = "disk"
            } else {
            let ranker = SparseSearchRanker()
            let rows = try statement("SELECT search_pages.rowid,heading,body || CASE WHEN ?='1' THEN ' ' || bibliography ELSE '' END FROM search_pages JOIN documents ON documents.path=search_pages.path WHERE documents.error IS NULL ORDER BY search_pages.path,CAST(page AS INTEGER)", [includeBibliography ? "1" : "0"])
            // Prepared normalised search text.
            defer { sqlite3_finalize(rows) }
            var status = sqlite3_step(rows)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                autoreleasepool { ranker.append(rowID: sqlite3_column_int64(rows, 0), heading: text(rows, 1), body: text(rows, 2)) }
                status = sqlite3_step(rows)
            }
            guard status == SQLITE_DONE else { throw failure() }
            try ranker.finish(); sparseRanker = ranker; sparseVersion = version; sparseKey = key; lastRankerPreparation = "rebuilt"
            try? ranker.save(to: cache, key: key)
            }
        } else { lastRankerPreparation = "memory" }
    }

    /// Native B0 over the complete current library; no FTS candidate truncation before ranking.
    func rankedSearch(_ query: String, expansions: [String] = []) throws -> [LibraryHit] {
        try rankedPage(query, expansions: expansions).hits
    }
    func rankedPage(_ query: String, expansions: [String] = [], offset: Int = 0, limit: Int = 200, includeBibliography: Bool = SearchScope.includesBibliography) throws -> LibrarySearchPage {
        guard offset >= 0, limit > 0, offset <= Int.max - limit - 1 else { throw CocoaError(.coderInvalidValue) }
        try Task.checkCancellation()
        _ = try Self.queryTerms(query)
        if SearchLexicon.terms(query).isEmpty {
            let hits = try search(query, interpretQuestions: false, offset: offset, limit: limit + 1, includeBibliography: includeBibliography)
            return LibrarySearchPage(hits: Array(hits.prefix(limit)), hasMore: hits.count > limit)
        }
        try prepareSearch(includeBibliography: includeBibliography)
        let regex = try NSRegularExpression(pattern: "\"([^\"]+)\"")
        let source = query as NSString
        let phrases = regex.matches(in: query, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) }
        var allowed: Set<Int64>?
        if !phrases.isEmpty {
            let expression = phrases.map { "\"" + SearchNormalisation.indexText($0) + "\"" }.joined(separator: " AND ")
            let columns = includeBibliography ? "{heading body bibliography}" : "{heading body}"
            let rows = try statement("SELECT rowid FROM search_pages WHERE search_pages MATCH ?", [columns + " : (" + expression + ")"]); defer { sqlite3_finalize(rows) }
            allowed = []
            while sqlite3_step(rows) == SQLITE_ROW { allowed!.insert(sqlite3_column_int64(rows, 0)) }
        }
        let ranked = try sparseRanker!.search(query, expansions: expansions, allowed: allowed, offset: offset, limit: limit + 1)
        var hits: [LibraryHit] = [], seen = Set<String>()
        let rows = try statement("SELECT pages.path,page,body,folder,heading FROM pages JOIN documents ON documents.path=pages.path WHERE pages.rowid=? AND documents.error IS NULL")
        defer { sqlite3_finalize(rows) }
        for match in ranked.prefix(limit) {
            try Task.checkCancellation()
            sqlite3_reset(rows); sqlite3_clear_bindings(rows); sqlite3_bind_int64(rows, 1, match.rowID)
            guard sqlite3_step(rows) == SQLITE_ROW else { continue }
            let body = text(rows, 2), path = text(rows, 0)
            guard seen.insert(body.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")).inserted else { continue }
            let matched = SearchLexicon.matchedQuery(body, query: query + " " + expansions.joined(separator: " "))
            var startsInBibliography = false
            let excerptBody = includeBibliography ? body : SearchPageStructure.analyse(body, inBibliography: &startsInBibliography).body
            let excerpt = SearchText.context(excerptBody, query: matched.isEmpty ? query : matched).excerpt
            hits.append(LibraryHit(path: path, folderID: text(rows, 3), page: Int(sqlite3_column_int(rows, 1)), excerpt: excerpt, score: -match.score, sectionTitle: URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" ? nil : text(rows, 4), matchQuery: matched.isEmpty ? query : matched))
        }
        return LibrarySearchPage(hits: hits, hasMore: ranked.count > limit)
    }

    func search(_ query: String, interpretQuestions: Bool = true, offset: Int = 0, limit: Int = 200, includeBibliography: Bool = SearchScope.includesBibliography) throws -> [LibraryHit] {
        // Release temporary Foundation text objects between successive searches.
        return try autoreleasepool {
            try connect(); try ensureSearchText()
            let literal = try Self.expression(query)
            let question = interpretQuestions ? SearchQuestion(query) : nil
            let expression = question?.expression ?? literal
            let columns = includeBibliography ? "{heading body bibliography}" : "{heading body}"
            let row = try statement("SELECT pages.path,pages.page,pages.body,bm25(search_pages,0,0,4,1,0.15),documents.folder,pages.heading FROM search_pages JOIN pages ON pages.rowid=search_pages.rowid JOIN documents ON documents.path=pages.path WHERE search_pages MATCH ? AND documents.error IS NULL ORDER BY bm25(search_pages,0,0,4,1,0.15),pages.path,CAST(pages.page AS INTEGER) LIMIT ? OFFSET ?", [columns + " : (" + expression + ")", String(limit), String(offset)])
            defer { sqlite3_finalize(row) }
            var results: [LibraryHit] = []
            var status = sqlite3_step(row)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                let body = text(row, 2)
                let matchedQuery = question?.matchedQuery(in: body)
                let context = SearchText.context(body, query: matchedQuery ?? query)
                results.append(LibraryHit(path: text(row, 0), folderID: text(row, 4), page: Int(sqlite3_column_int(row, 1)), excerpt: context.excerpt, score: sqlite3_column_double(row, 3) * (1 + 0.25 * context.proximity), sectionTitle: URL(fileURLWithPath: text(row, 0)).pathExtension.lowercased() == "pdf" ? nil : text(row, 5), matchQuery: matchedQuery))
                status = sqlite3_step(row)
            }
            guard status == SQLITE_DONE else { throw failure() }
            return results.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score < $1.score }
        }
    }
}
