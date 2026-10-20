import SwiftUI
import Network

/// Bounded local counters; never a claim about the account's remaining allowance.
@MainActor final class AIUsage: ObservableObject {
    static let shared = AIUsage()
    @Published var online = true
    @Published private(set) var active = false
    @Published private(set) var requests = 0
    @Published private(set) var inputTokens = 0
    @Published private(set) var outputTokens = 0
    @Published private(set) var paused = false
    @Published private(set) var reconnecting = false
    private var recoveryTask: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private let defaults: UserDefaults
    private var day = ""
    var limit: Int { max(1, defaults.object(forKey: "chatgpt.dailyLimit") as? Int ?? 100) }
    var needsConnection: Bool { !ChatGPTConnection.shared.connected || ChatGPTConnection.shared.credentialUnavailable }
    var showsGPTMark: Bool { needsConnection || reason == nil }
    var reason: String? {
        if !online { return "Offline" }
        if !ChatGPTConnection.shared.connected { return "Connect ChatGPT" }
        if ChatGPTConnection.shared.credentialUnavailable { return "Unlock connection in Settings" }
        if paused { return "ChatGPT limit reached" }
        if Calendar.current.isDate(Date(timeIntervalSince1970: defaults.double(forKey: "chatgpt.counterDate")), inSameDayAs: Date()) && requests >= limit { return "Daily app limit reached" }
        if reconnecting { return "Reconnecting to ChatGPT" }
        return nil
    }
    init(defaults: UserDefaults = .standard, monitoring: Bool = true) {
        self.defaults = defaults; paused = defaults.bool(forKey: "chatgpt.usagePaused")
        if !defaults.bool(forKey: "chatgpt.limit100Default") {
            if defaults.object(forKey: "chatgpt.dailyLimit") == nil || defaults.integer(forKey: "chatgpt.dailyLimit") == 50 { defaults.set(100, forKey: "chatgpt.dailyLimit") }
            defaults.set(true, forKey: "chatgpt.limit100Default")
        }
        rollover()
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in
            guard let self else { return }; let wasOffline = !self.online; self.online = path.status == .satisfied
            if wasOffline && self.online { self.retryConnection() }
        } }
        if monitoring { monitor.start(queue: DispatchQueue(label: "local.remile.assistant-network")) }
    }
    func begin() throws {
        rollover()
        if let reason { throw ChatGPTIdentity.Failure(reason) }
        guard !active else { throw ChatGPTIdentity.Failure("ChatGPT is answering another request.") }
        active = true; requests += 1; persist()
    }
    func finish(input: Int = 0, output: Int = 0) { active = false; inputTokens += max(0, input); outputTokens += max(0, output); persist() }
    func pause() { paused = true; defaults.set(true, forKey: "chatgpt.usagePaused") }
    func resume() { paused = false; defaults.set(false, forKey: "chatgpt.usagePaused") }
    func connectionInterrupted() {
        reconnecting = true; recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.reconnecting = false
        }
    }
    func retryConnection() { recoveryTask?.cancel(); recoveryTask = nil; reconnecting = false }
    private func rollover() {
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        guard day != today else { return }; day = today
        let saved = defaults.dictionary(forKey: "chatgpt.localUsage") ?? [:]
        requests = saved["day"] as? String == day ? saved["requests"] as? Int ?? 0 : 0
        inputTokens = saved["day"] as? String == day ? saved["input"] as? Int ?? 0 : 0
        outputTokens = saved["day"] as? String == day ? saved["output"] as? Int ?? 0 : 0
    }
    private func persist() { defaults.set(Date().timeIntervalSince1970, forKey: "chatgpt.counterDate"); defaults.set(["day": day, "requests": requests, "input": inputTokens, "output": outputTokens], forKey: "chatgpt.localUsage") }
}
