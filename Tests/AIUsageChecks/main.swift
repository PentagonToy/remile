import Foundation
@MainActor final class ChatGPTConnection { static let shared = ChatGPTConnection(); var connected = true; var credentialUnavailable = false }
enum ChatGPTIdentity { struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } } }
Task { @MainActor in
    let name = "local.remile.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(2, forKey: "chatgpt.dailyLimit")
    let usage = AIUsage(defaults: defaults, monitoring: false)
    precondition(usage.limit == 2)
    precondition(usage.showsGPTMark)
    ChatGPTConnection.shared.credentialUnavailable = true
    precondition(usage.needsConnection && usage.showsGPTMark, "Locked GPT keeps its own provider mark")
    ChatGPTConnection.shared.credentialUnavailable = false
    usage.online = false; precondition(usage.reason == "Offline")
    precondition(!usage.showsGPTMark, "Offline fallback uses the local mark")
    usage.online = true; try usage.begin(); precondition(usage.active && usage.requests == 1)
    do { try usage.begin(); fatalError("concurrent request") } catch { }
    usage.finish(input: 10, output: 4); precondition(!usage.active && usage.inputTokens == 10 && usage.outputTokens == 4)
    usage.connectionInterrupted(); precondition(usage.reason == "Reconnecting to ChatGPT")
    usage.retryConnection(); precondition(usage.reason == nil && usage.requests == 1, "Recovery does not make an inference request")
    try usage.begin(); usage.finish(); precondition(usage.reason == "Daily app limit reached")
    usage.pause(); precondition(usage.reason == "ChatGPT limit reached"); usage.resume(); precondition(!usage.paused)
    let restored = AIUsage(defaults: defaults, monitoring: false); precondition(restored.requests == 2 && restored.inputTokens == 10)
    ChatGPTConnection.shared.connected = false; precondition(usage.reason == "Connect ChatGPT")
    defaults.removeObject(forKey: "chatgpt.limit100Default"); defaults.set(50, forKey: "chatgpt.dailyLimit")
    let migrated = AIUsage(defaults: defaults, monitoring: false); precondition(migrated.limit == 100)
    defaults.set(25, forKey: "chatgpt.dailyLimit")
    let custom = AIUsage(defaults: defaults, monitoring: false); precondition(custom.limit == 25)
    print("Passed 17 usage policy checks"); exit(0)
}
RunLoop.main.run()
