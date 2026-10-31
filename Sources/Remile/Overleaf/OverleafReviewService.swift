import Foundation

@MainActor enum OverleafReviewService {
    typealias Request = @MainActor (String, UUID, Bool) async throws -> Data
    static func read(_ connection: OverleafConnection, paths: [String], main: String? = nil, request: @escaping Request = { path, profile, document in
        try await OverleafWebClient.request(path, profile: profile, document: document)
    }) async throws -> OverleafReviewSnapshot {
        try await withThrowingTaskGroup(of: OverleafReviewSnapshot.self) { group in
            group.addTask { try await fetch(connection, paths: paths, main: main, request: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw OverleafGit.Failure("Review took too long to load. Try again.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private static func fetch(_ connection: OverleafConnection, paths: [String], main: String?, request: @escaping Request) async throws -> OverleafReviewSnapshot {
        let prefix = "/project/" + connection.projectID
        let threads = try await request(prefix + "/threads", connection.profileID, false)
        var result = OverleafReviewSnapshot(archive: try OverleafThreadArchive.parse(threads, project: connection))
        result.main = main
        do {
            let bytes = try await request(prefix + "/ranges", connection.profileID, false)
            let rows = try OverleafReviewSnapshot.documentRanges(bytes)
            for start in stride(from: 0, to: rows.count, by: 4) {
                let ids = rows[start..<min(rows.count, start + 4)].map(\.id)
                let documents = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                    for id in ids { group.addTask {
                        try Task.checkCancellation()
                        let bytes = try await request("/Project/" + connection.projectID + "/doc/" + id + "/download", connection.profileID, true)
                        return (id, bytes)
                    } }
                    var values: [String: Data] = [:]
                    for try await (id, document) in group { values[id] = document }
                    return values
                }
                for row in rows[start..<min(rows.count, start + 4)] {
                    try result.includeDownload(documents[row.id]!, ranges: row.ranges, documentID: row.id, paths: paths)
                }
            }
            let latest = try await request(prefix + "/ranges", connection.profileID, false)
            if try OverleafReviewSnapshot.fingerprint(bytes) != OverleafReviewSnapshot.fingerprint(latest) {
                result.anchors = [:]; result.changes = []
                result.warning = "Review changed while loading. Refresh to try again."
            }
            if !result.changes.isEmpty {
                do {
                    let authors = try await request(prefix + "/changes/users", connection.profileID, false)
                    try result.includeAuthors(authors)
                }
                catch is CancellationError { throw CancellationError() }
                catch { } // Names are optional. Review remains available if the author lookup fails.
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.warning = "Some review locations or changes could not be loaded."
            result.needsConnection = (error as? OverleafWebClient.Failure)?.needsConnection == true
        }
        try Task.checkCancellation()
        return result
    }
}
