import Foundation

@MainActor enum WritingProofreading {
    static var provider: String { UserDefaults.standard.string(forKey: "assistant.provider") ?? "Apple Intelligence" }
    static var enabled: Bool { provider != "Off" && AIConfiguration.writingEnabled && (UserDefaults.standard.object(forKey: "chatgpt.grammar") as? Bool ?? true) }
    static func suggest(text: String) async throws -> (choices: [String], provider: String) {
        guard enabled else { throw ChatGPTIdentity.Failure("Writing suggestions are off in AI settings.") }
        if provider == "ChatGPT", AIUsage.shared.reason == nil {
            do { return (try await choices(text: text), "ChatGPT") }
            catch is CancellationError { throw CancellationError() }
            catch { guard AIConfiguration.fallbackEnabled, AppleIntelligence.status().ready else { throw error } }
        }
        if provider == "ChatGPT", !AIConfiguration.fallbackEnabled { throw ChatGPTIdentity.Failure(AIUsage.shared.reason ?? "ChatGPT is unavailable.") }
        try Task.checkCancellation()
        return (try await EditorProofreading.proofread(text), provider == "ChatGPT" ? "Apple Intelligence · fallback" : "Apple Intelligence")
    }
    private static var cache: [(key: String, date: Date, choices: [String])] = []
    private static func choices(text: String) async throws -> [String] {
        let key = ChatGPTConnection.shared.model + "|" + text
        if let saved = cache.first(where: { $0.key == key && Date().timeIntervalSince($0.date) < 600 }) { return saved.choices }
        let input = try JSONSerialization.data(withJSONObject: ["selected": text])
        let response = try await ChatGPTConnection.shared.respond(String(decoding: input, as: UTF8.self), instructions: AssistantPrompts.grammar)
        let values = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var seen = Set<String>([text])
        let choices = Array(values.filter { !$0.isEmpty && $0.utf16.count <= 4000 && !$0.contains("\\") && !$0.contains("$") && seen.insert($0).inserted }.prefix(3))
        cache.removeAll { Date().timeIntervalSince($0.date) >= 600 }; cache.append((key, Date(), choices)); cache = Array(cache.suffix(64))
        return choices
    }
}
