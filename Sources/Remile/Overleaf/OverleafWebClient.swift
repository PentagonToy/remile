import Foundation
import WebKit

/// Read-only HTTP requests reuse only remile.'s own signed-in account store.
/// No editor page or collaboration socket is opened.
@MainActor enum OverleafWebClient {
    private static var webTransport = Set<UUID>()
    private static func webRequest(_ url: URL, profile: UUID) async throws -> Data {
        let bytes = try await OverleafJSONRequest(url: url, profile: profile).load()
        await OverleafWebIdentity.remember(profile)
        return bytes
    }
    struct Tag: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let color: String?
    }
    struct Project: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        var tags: [Tag] = []
        var tagsLoaded = true
    }
    enum Failure: LocalizedError {
        case signIn, response, verification, permission, rateLimited, unavailable, sessionLocked
        var needsConnection: Bool { self == .signIn || self == .verification || self == .sessionLocked }
        var errorDescription: String? {
            switch self {
            case .signIn: return "Connect your Overleaf account to list projects and read comments."
            case .response: return "Overleaf could not return this information. Try again shortly."
            case .verification: return "Overleaf needs browser verification. Open the connection screen to continue."
            case .permission: return "This Overleaf account does not have access to this information."
            case .rateLimited: return "Overleaf is receiving too many requests. Wait a moment, then retry."
            case .unavailable: return "Overleaf is temporarily unavailable. Try again shortly."
            case .sessionLocked: return "Allow access to the saved session in Connection, or sign in again."
            }
        }
    }
    nonisolated static func isLoginURL(_ url: URL) -> Bool {
        ["overleaf.com", "www.overleaf.com"].contains(url.host?.lowercased() ?? "") && ["/login", "/user/login"].contains(url.path)
    }
    nonisolated static func responseFailure(_ http: HTTPURLResponse) -> Failure? {
        if http.statusCode == 401 { return .signIn }
        if [301, 302, 303, 307, 308].contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: http.url)?.absoluteURL, isLoginURL(url) { return .signIn }
        if http.statusCode == 403 { return http.mimeType?.lowercased() == "application/json" ? .permission : .verification }
        if http.statusCode == 429 { return .rateLimited }
        if (500...599).contains(http.statusCode) { return .unavailable }
        guard http.statusCode == 200, http.mimeType?.lowercased() == "application/json" else { return .response }
        return nil
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func request(_ path: String, profile: UUID) async throws -> Data {
        try NetworkAccess.requireOnline()
        do { try await OverleafWebIdentity.restore(profile) }
        catch Failure.sessionLocked {
            // WebKit may still hold a valid session even when the saved backup needs approval.
            do { return try await webRequest(URL(string: "https://www.overleaf.com" + path)!, profile: profile) }
            catch Failure.signIn { throw Failure.sessionLocked }
        }
        let store = OverleafWebIdentity.dataStore(profile).httpCookieStore
        let cookies = await store.allCookies()
        let url = URL(string: "https://www.overleaf.com" + path)!
        if webTransport.contains(profile) { return try await webRequest(url, profile: profile) }
        let allowed = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return ["overleaf.com", "www.overleaf.com"].contains(domain) && (cookie.expiresDate.map { $0 > Date() } ?? true) && url.path.hasPrefix(cookie.path)
        }
        guard !allowed.isEmpty else { return try await webRequest(url, profile: profile) }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        for (key, value) in HTTPCookie.requestHeaderFields(with: allowed) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("remile/\(RemileRelease.current) (Mozilla/5.0 compatible)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.overleaf.com/", forHTTPHeaderField: "Referer")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
        let lease = try NetworkAccess.gate.watch(session); defer { NetworkAccess.gate.release(lease) }
        defer { session.invalidateAndCancel() }
        let bytes: Data, response: URLResponse
        do { (bytes, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .badServerResponse {
            webTransport.insert(profile); return try await webRequest(url, profile: profile)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        if http.statusCode == 403 || responseFailure(http) == .signIn { webTransport.insert(profile); return try await webRequest(url, profile: profile) }
        if let failure = responseFailure(http) { throw failure }
        guard bytes.count <= 8_000_000 else { throw Failure.response }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in if let key = field.key as? String, let value = field.value as? String { result[key] = value } }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) { await store.setCookie(cookie) }
        await OverleafWebIdentity.remember(profile)
        return bytes
    }
    static func projects(_ profile: UUID) async throws -> [Project] {
        let projects = try parseProjects(await request("/user/projects", profile: profile))
        // Tags are optional metadata. An unavailable tag endpoint must not hide projects.
        guard let data = try? await request("/tag", profile: profile), let tags = try? parseTags(data) else { return projects }
        return projects.map { project in var item = project; item.tags = tags[item.id] ?? []; item.tagsLoaded = true; return item }
    }
    nonisolated static func parseTags(_ data: Data) throws -> [String: [Tag]] {
        guard data.count <= 8_000_000, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 10_000 else { throw Failure.response }
        var result: [String: [Tag]] = [:]
        for row in rows {
            guard let id = row["_id"] as? String, let name = row["name"] as? String, !name.isEmpty, let projects = row["project_ids"] as? [String], projects.count <= 10_000 else { throw Failure.response }
            let tag = Tag(id: id, name: String(name.prefix(200)), color: row["color"] as? String)
            for project in Set(projects) { if result[project, default: []].contains(where: { $0.id == id }) == false { result[project, default: []].append(tag) } }
        }
        return result.mapValues { $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }
    nonisolated static func parseProjects(_ data: Data) throws -> [Project] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["projects"] as? [[String: Any]], rows.count <= 10_000 else { throw Failure.response }
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = row["_id"] as? String, OverleafConnection.projectID("https://www.overleaf.com/project/" + id) != nil, let name = row["name"] as? String else { throw Failure.response }
            return Project(id: id.lowercased(), name: name, tagsLoaded: false)
        }.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func comments(_ project: OverleafConnection) async throws -> OverleafThreadArchive {
        let bytes = try await request("/project/" + project.projectID + "/threads", profile: project.profileID)
        return try OverleafThreadArchive.parse(bytes, project: project)
    }
}
