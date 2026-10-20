import AppKit
import SwiftUI
import CryptoKit

/// Official ChatGPT-plan OAuth and Responses transport. No agent runtime or web editor.
@MainActor final class ChatGPTConnection: ObservableObject {
    static let shared = ChatGPTConnection()
    struct Model: Identifiable { let id: String; let name: String }
    private struct Account: Codable {
        let client: String
        let subject: String
        let name: String
        var access: String
        var refresh: String
        var identity: String
        var expiry: Date
        var scopes: String
    }
    @Published var connected = UserDefaults.standard.bool(forKey: "chatgpt.connected")
    @Published var name = UserDefaults.standard.string(forKey: "chatgpt.accountName") ?? ""
    @Published var models: [Model] = []
    @Published var model = UserDefaults.standard.string(forKey: "chatgpt.model") ?? "" { didSet { UserDefaults.standard.set(model, forKey: "chatgpt.model") } }
    @Published var busy = false
    @Published private(set) var unlocking = false
    @Published private(set) var credentialUnavailable = false
    @Published var error: String?
    private var account: Account?
    private var attemptedLoad = false
    private var callback: ChatGPTCallback?
    private var refreshing: Task<Account, Error>?
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    func signIn() async {
        guard !busy else { return }; busy = true; error = nil
        defer { callback?.cancel(); callback = nil; busy = false }
        do {
            let state = try ChatGPTIdentity.random(), nonce = try ChatGPTIdentity.random(), verifier = try ChatGPTIdentity.random()
            let receiver = try ChatGPTCallback(state: state); callback = receiver
            let redirect = try await receiver.start()
            let host = UserDefaults.standard.string(forKey: "chatgpt.host") ?? "urn:uuid:" + UUID().uuidString
            UserDefaults.standard.set(host, forKey: "chatgpt.host")
            var query = ["client_id": "dynamic_agent_client", "agent_name_hint": "remile", "ext_agent_host_id": host, "response_type": "code", "redirect_uri": redirect, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": ChatGPTIdentity.base64(Data(SHA256.hash(data: Data(verifier.utf8))))]
            // A returning account keeps its issued registration and identity hint.
            if let saved = await load() { query["client_id"] = saved.client; query["id_token_hint"] = saved.identity; query.removeValue(forKey: "agent_name_hint") }
            else if let issued = UserDefaults.standard.string(forKey: "chatgpt.pendingClient") { query["client_id"] = issued; query.removeValue(forKey: "agent_name_hint") }
            var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!; url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let link = url.url, NSWorkspace.shared.open(link) else { throw ChatGPTIdentity.Failure("Could not open ChatGPT sign-in.") }
            var result: [String: String]?
            for try await value in receiver.values { result = value; break }
            guard let result, result["error"] == nil, let code = result["code"] else { throw ChatGPTIdentity.Failure("ChatGPT sign-in was not completed.") }
            let returning = query["client_id"] != "dynamic_agent_client"
            guard let client = result["client_id"] ?? (returning ? query["client_id"] : nil), client != "dynamic_agent_client", !client.isEmpty,
                  !returning || client == query["client_id"] else { throw ChatGPTIdentity.Failure("ChatGPT did not return the expected application registration.") }
            UserDefaults.standard.set(client, forKey: "chatgpt.pendingClient")
            let response = try await Self.token(["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": "https://api.openai.com/v1"])
            guard let identity = response["id_token"] as? String else { throw ChatGPTIdentity.Failure("ChatGPT did not return a verified identity.") }
            let keys = try await Self.getKeys()
            let claims = try ChatGPTIdentity.verify(identity, client: client, nonce: nonce, keys: keys)
            if returning, let previous = await load(), claims["sub"] as? String != previous.subject { throw ChatGPTIdentity.Failure("Sign in with the saved account, or disconnect it before choosing another account.") }
            let saved = try Self.account(response, client: client, subject: claims["sub"] as! String, name: claims["email"] as? String ?? claims["name"] as? String ?? "ChatGPT", previous: nil)
            try save(saved); await loadModels()
        } catch is CancellationError { error = "Sign-in cancelled." }
        catch { self.error = error.localizedDescription }
    }
    func cancelSignIn() { callback?.cancel() }
    func disconnect() {
        guard !busy else { return }
        refreshing?.cancel(); refreshing = nil; ChatGPTVault.remove(); account = nil; attemptedLoad = true; connected = false; name = ""; models = []; model = ""; error = nil
        UserDefaults.standard.removeObject(forKey: "chatgpt.connected"); UserDefaults.standard.removeObject(forKey: "chatgpt.accountName")
        UserDefaults.standard.removeObject(forKey: "chatgpt.pendingClient")
    }
    private func load() async -> Account? {
        if let account { return account }
        guard !attemptedLoad else { return nil }; attemptedLoad = true
        let bytes = await Task.detached { ChatGPTVault.read() }.value
        guard let bytes, let saved = try? JSONDecoder().decode(Account.self, from: bytes) else { credentialUnavailable = true; return nil }
        account = saved; return saved
    }
    private func save(_ saved: Account) throws {
        try ChatGPTVault.write(JSONEncoder().encode(saved)); credentialUnavailable = false; account = saved; connected = true; name = saved.name
        UserDefaults.standard.removeObject(forKey: "chatgpt.pendingClient")
        UserDefaults.standard.set(true, forKey: "chatgpt.connected"); UserDefaults.standard.set(saved.name, forKey: "chatgpt.accountName")
    }
    private static func account(_ response: [String: Any], client: String, subject: String, name: String, previous: Account?) throws -> Account {
        guard let access = response["access_token"] as? String, !access.isEmpty, let refresh = response["refresh_token"] as? String, !refresh.isEmpty,
              let identity = response["id_token"] as? String ?? previous?.identity, let expiry = response["expires_in"] as? Double, expiry > 0,
              let scopes = response["scope"] as? String ?? previous?.scopes, scopes.split(separator: " ").contains("chatgpt.tokens.use.direct"), response["token_type"] as? String == "Bearer" else { throw ChatGPTIdentity.Failure("ChatGPT plan access was not granted. Reconnect and enable plan usage during sign-in.") }
        return Account(client: client, subject: subject, name: name, access: access, refresh: refresh, identity: identity, expiry: Date().addingTimeInterval(expiry), scopes: scopes)
    }
    private static func token(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?/#"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
        let session = session(); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 128_000, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ChatGPTIdentity.Failure("ChatGPT could not renew this connection. Continue with ChatGPT to sign in again.") }
        return object
    }
    private static func getKeys() async throws -> Data {
        let session = session(); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 128_000 else { throw ChatGPTIdentity.Failure("Could not verify ChatGPT’s signing keys.") }; return bytes
    }
    private func access() async throws -> String {
        guard let saved = await load() else { throw ChatGPTIdentity.Failure(connected ? "Unlock the connection in Settings." : "Connect ChatGPT from Home → Settings.") }
        if saved.expiry.timeIntervalSinceNow > 60 { return saved.access }
        if let refreshing { return try await refreshing.value.access }
        let task = Task {
            let response = try await Self.token(["grant_type": "refresh_token", "client_id": saved.client, "refresh_token": saved.refresh, "resource": "https://api.openai.com/v1"])
            if let identity = response["id_token"] as? String {
                let keys = try await Self.getKeys(), claims = try ChatGPTIdentity.verify(identity, client: saved.client, nonce: nil, keys: keys)
                guard claims["sub"] as? String == saved.subject else { throw ChatGPTIdentity.Failure("The refreshed ChatGPT identity did not match this account.") }
            }
            let next = try Self.account(response, client: saved.client, subject: saved.subject, name: saved.name, previous: saved)
            try save(next); return next
        }
        refreshing = task; defer { refreshing = nil }
        return try await task.value.access
    }
    func unlock() async {
        guard !busy, !unlocking else { return }; unlocking = true; error = nil
        defer { unlocking = false }
        let bytes = await Task.detached(priority: .userInitiated) { ChatGPTVault.read(interactive: true) }.value
        attemptedLoad = true
        guard let bytes, let saved = try? JSONDecoder().decode(Account.self, from: bytes) else { credentialUnavailable = true; error = "Connection remains locked."; return }
        account = saved; credentialUnavailable = false; await loadModels()
    }
    func loadModels() async {
        guard AIUsage.shared.online else { return }
        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!); request.setValue("Bearer " + (try await access()), forHTTPHeaderField: "Authorization")
            let session = Self.session(); defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 2_000_000, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let rows = object["models"] as? [[String: Any]] else { throw ChatGPTIdentity.Failure("Could not load the models available to this ChatGPT account.") }
            models = rows.filter { $0["visibility"] as? String == "list" }.compactMap { row in guard let id = row["slug"] as? String, let name = row["display_name"] as? String else { return nil }; return Model(id: id, name: name) }
            if !UserDefaults.standard.bool(forKey: "chatgpt.lunaDefault") || !models.contains(where: { $0.id == model }) {
                model = models.first(where: { $0.id.contains("luna") })?.id ?? models.first?.id ?? ""
                UserDefaults.standard.set(true, forKey: "chatgpt.lunaDefault")
            }
        } catch { self.error = error.localizedDescription }
    }
    func respond(_ input: String, instructions: String) async throws -> String {
        guard await load() != nil else { throw ChatGPTIdentity.Failure("Unlock the connection in Settings.") }
        try AIUsage.shared.begin()
        var counted = false
        defer { if !counted { AIUsage.shared.finish() } }
        if models.isEmpty { await loadModels() }
        guard !model.isEmpty else { throw ChatGPTIdentity.Failure(error ?? "Choose a ChatGPT model in Settings.") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!); request.httpMethod = "POST"
        request.setValue("Bearer " + (try await access()), forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instructions, "input": [["role": "user", "content": [["type": "input_text", "text": input]]]], "store": false, "stream": true])
        let session = Self.session(); defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var bytes = Data()
            for try await byte in stream { bytes.append(byte); if bytes.count >= 16_384 { break } }
            let failure = ChatGPTRequestFailure(status: http.statusCode, body: bytes, requestID: http.value(forHTTPHeaderField: "x-request-id"))
            if failure.code == "subscription_sharing_usage_limit_exceeded" { AIUsage.shared.pause() }
            throw failure
        }
        var result = ChatGPTStream()
        for try await line in stream.lines {
            try Task.checkCancellation()
            do { try result.receive(line) }
            catch let failure as ChatGPTRequestFailure { if failure.code == "subscription_sharing_usage_limit_exceeded" { AIUsage.shared.pause() }; throw failure }
        }
        let answer = try result.result()
        AIUsage.shared.finish(input: result.inputTokens, output: result.outputTokens); counted = true
        return answer
    }
}

extension AssistantEngine {
    static var chatGPT: Self {
        Self(status: {
            if let reason = AIUsage.shared.reason { let local = AppleIntelligence.status(); return (local.ready, "On-device · " + reason) }
            return (true, "ChatGPT")
        }, singlePass: true, expandedContext: AIUsage.shared.reason == nil, respond: { input, instructions, tokens in
            if AIUsage.shared.reason != nil { return try await AppleIntelligence.respond(to: AssistantPrompts.deviceFallback(input), instructions: instructions, maximumTokens: min(tokens, 1400)) }
            do { return try await ChatGPTConnection.shared.respond(input, instructions: AssistantPrompts.budget(instructions, tokens: tokens)) }
            catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(error.code) { AIUsage.shared.connectionInterrupted(); return try await AppleIntelligence.respond(to: AssistantPrompts.deviceFallback(input), instructions: instructions, maximumTokens: min(tokens, 1400)) }
            catch let error as ChatGPTRequestFailure where error.code == "subscription_sharing_usage_limit_exceeded" { return try await AppleIntelligence.respond(to: AssistantPrompts.deviceFallback(input), instructions: instructions, maximumTokens: min(tokens, 1400)) }
            catch let error as ChatGPTRequestFailure where error.status >= 500 || error.status == 429 || ["subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"].contains(error.code ?? "") { AIUsage.shared.connectionInterrupted(); return try await AppleIntelligence.respond(to: AssistantPrompts.deviceFallback(input), instructions: instructions, maximumTokens: min(tokens, 1400)) }
        })
    }
}
