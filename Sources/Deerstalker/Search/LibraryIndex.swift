import Foundation
import PDFKit
import SQLite3

struct LibraryFolder: Identifiable, Sendable {
    let id: String
    let path: String
    let bookmark: Data
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    func url() throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
    }
}

struct LibrarySummary: Sendable {
    var folders: [LibraryFolder] = []
    var documents = 0
    var pages = 0
    var needsOCR = 0
    var failed = 0
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

struct LibraryProgress: Sendable {
    let completed: Int
    let total: Int
    let name: String
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
    private let location: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(location: URL? = nil) {
        self.location = location ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deerstalker/Search/library-v1.sqlite")
    }
    deinit { if let database { sqlite3_close(database) } }

    private func connect() throws {
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

    func summary() throws -> LibrarySummary {
        try connect()
        var result = LibrarySummary()
        let folders = try statement("SELECT id,path,bookmark FROM folders ORDER BY path")
        defer { sqlite3_finalize(folders) }
        while sqlite3_step(folders) == SQLITE_ROW {
            let bytes = sqlite3_column_bytes(folders, 2)
            guard let blob = sqlite3_column_blob(folders, 2), bytes > 0 else { continue }
            result.folders.append(LibraryFolder(id: text(folders, 0), path: text(folders, 1), bookmark: Data(bytes: blob, count: Int(bytes))))
        }
        let totals = try statement("SELECT COUNT(*),COALESCE(SUM(pages),0),COALESCE(SUM(empty_pages),0),COALESCE(SUM(error IS NOT NULL),0) FROM documents")
        defer { sqlite3_finalize(totals) }
        if sqlite3_step(totals) == SQLITE_ROW {
            result.documents = Int(sqlite3_column_int(totals, 0)); result.pages = Int(sqlite3_column_int(totals, 1))
            result.needsOCR = Int(sqlite3_column_int(totals, 2)); result.failed = Int(sqlite3_column_int(totals, 3))
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

    func remove(_ folder: LibraryFolder) throws {
        try connect(); try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM pages WHERE path IN (SELECT path FROM documents WHERE folder=?)", [folder.id])
            try execute("DELETE FROM folders WHERE id=?", [folder.id])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func refresh(progress: @Sendable (LibraryProgress) async -> Void) async throws {
        try connect()
        for folder in try summary().folders {
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
                try index(file, folder: folder.id)
                await progress(LibraryProgress(completed: offset + 1, total: files.count, name: file.lastPathComponent))
            }
            try Task.checkCancellation()
            let existing = try statement("SELECT path FROM documents WHERE folder=?", [folder.id])
            var removed: [String] = []
            while sqlite3_step(existing) == SQLITE_ROW { let path = text(existing, 0); if !seen.contains(path) { removed.append(path) } }
            sqlite3_finalize(existing)
            try execute("BEGIN IMMEDIATE")
            do {
                for path in removed { try execute("DELETE FROM pages WHERE path=?", [path]); try execute("DELETE FROM documents WHERE path=?", [path]) }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    private func revision(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        return "search-v3:\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0):\(String(describing: values.fileResourceIdentifier))"
    }
    private func index(_ url: URL, folder: String) throws {
        try Task.checkCancellation()
        let stamp = try revision(url)
        let previous = try statement("SELECT revision,error FROM documents WHERE path=?", [url.path])
        let unchanged = sqlite3_step(previous) == SQLITE_ROW && text(previous, 0) == stamp && sqlite3_column_type(previous, 1) == SQLITE_NULL
        sqlite3_finalize(previous)
        if unchanged { return }
        try execute("BEGIN IMMEDIATE")
        do {
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
                        // A modest first-lines heuristic, not recovered font-based ranking.
                        let heading = body.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " ")
                        try execute("INSERT INTO pages(path,page,heading,body) VALUES(?,?,?,?)", [url.path, String(number + 1), heading, body])
                    }
                }
                guard try revision(url) == stamp else { throw CocoaError(.fileReadUnknown) }
                try execute("INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,NULL)", [url.path, folder, stamp, String(pdf.pageCount), String(empty)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            if error is CancellationError { throw error }
            // Preserve old bytes for retry, but hide stale results until a successful refresh.
            try execute("INSERT OR REPLACE INTO documents VALUES(?,?,?,0,0,?)", [url.path, folder, "", error.localizedDescription])
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
        try queryTerms(query).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
    }

    func spellingSuggestions(_ query: String) throws -> [String] {
        try connect()
        guard !query.contains("\""), let groups = try? Self.queryTerms(query), groups.count <= 6,
              groups.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return [] }
        let words = groups.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        var choices = [[String]](), changed = 0
        for word in words {
            try Task.checkCancellation()
            let exact = try statement("SELECT term FROM vocabulary WHERE term=?", [word])
            let known = sqlite3_step(exact) == SQLITE_ROW; sqlite3_finalize(exact)
            if known || word.count < 4 || word.count > 32 { choices.append([word]); continue }
            changed += 1; guard changed <= 2 else { return [] }
            let limit = word.count >= 7 ? 2 : 1
            let row = try statement("SELECT term,doc FROM vocabulary WHERE length(term) BETWEEN CAST(? AS INTEGER) AND CAST(? AS INTEGER) ORDER BY doc DESC,term LIMIT 4000", [String(word.count - limit), String(word.count + limit)])
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
        let row = try statement("SELECT term FROM vocabulary WHERE length(term) BETWEEN 4 AND 32 ORDER BY doc DESC,term LIMIT 2000")
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

    func search(_ query: String) throws -> [LibraryHit] {
        try connect()
        let expression = try Self.expression(query)
        let row = try statement("SELECT path,page,body,bm25(pages,0,0,4,1),(SELECT folder FROM documents WHERE documents.path=pages.path),heading FROM pages WHERE pages MATCH ? AND path IN (SELECT path FROM documents WHERE error IS NULL) ORDER BY bm25(pages,0,0,4,1),path,CAST(page AS INTEGER) LIMIT 200", [expression])
        defer { sqlite3_finalize(row) }
        var results: [LibraryHit] = []
        var status = sqlite3_step(row)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let context = SearchText.context(text(row, 2), query: query)
            results.append(LibraryHit(path: text(row, 0), folderID: text(row, 4), page: Int(sqlite3_column_int(row, 1)), excerpt: context.excerpt, score: sqlite3_column_double(row, 3) * (1 + 0.25 * context.proximity), sectionTitle: URL(fileURLWithPath: text(row, 0)).pathExtension.lowercased() == "pdf" ? nil : text(row, 5)))
            status = sqlite3_step(row)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return results.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score < $1.score }
    }
}
