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
    struct Project: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }
    enum Failure: LocalizedError {
        case signIn, response
        var errorDescription: String? { self == .signIn ? "Sign in once to list projects and read comments." : "Overleaf could not return this information. Try again shortly." }
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func request(_ path: String, profile: UUID) async throws -> Data {
        await OverleafWebIdentity.restore(profile)
        let store = WKWebsiteDataStore(forIdentifier: profile).httpCookieStore
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
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        if http.statusCode == 403 { webTransport.insert(profile); return try await webRequest(url, profile: profile) }
        if [301, 302, 303, 307, 308, 401].contains(http.statusCode) { throw Failure.signIn }
        guard http.statusCode == 200, bytes.count <= 8_000_000, http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true else { throw Failure.response }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in if let key = field.key as? String, let value = field.value as? String { result[key] = value } }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) { await store.setCookie(cookie) }
        await OverleafWebIdentity.remember(profile)
        return bytes
    }
    static func projects(_ profile: UUID) async throws -> [Project] { try parseProjects(await request("/user/projects", profile: profile)) }
    nonisolated static func parseProjects(_ data: Data) throws -> [Project] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["projects"] as? [[String: Any]], rows.count <= 10_000 else { throw Failure.response }
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = row["_id"] as? String, OverleafConnection.projectID("https://www.overleaf.com/project/" + id) != nil, let name = row["name"] as? String else { throw Failure.response }
            return Project(id: id.lowercased(), name: name)
        }.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func comments(_ project: OverleafConnection) async throws -> OverleafThreadArchive {
        let bytes = try await request("/project/" + project.projectID + "/threads", profile: project.profileID)
        return try OverleafThreadArchive.parse(bytes, project: project)
    }
}
