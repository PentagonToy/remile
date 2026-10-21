import Foundation

@MainActor enum WritingAlternatives {
    static var provider: String { UserDefaults.standard.string(forKey: "assistant.provider") ?? "Apple Intelligence" }
    static func enabled(correction: Bool) -> Bool { provider != "Off" && AIConfiguration.writingEnabled && (UserDefaults.standard.object(forKey: correction ? "chatgpt.grammar" : "chatgpt.synonyms") as? Bool ?? true) }
    static func suggest(text: String, context: String, correction: Bool) async throws -> (choices: [String], provider: String) {
        guard enabled(correction: correction) else { throw ChatGPTIdentity.Failure("Writing suggestions are off in AI settings.") }
        if provider == "ChatGPT", AIUsage.shared.reason == nil {
            do { return (try await choices(text: text, context: context, correction: correction), "ChatGPT") }
            catch is CancellationError { throw CancellationError() }
            catch { guard AIConfiguration.fallbackEnabled, AppleIntelligence.status().ready else { throw error } }
        }
        if provider == "ChatGPT", !AIConfiguration.fallbackEnabled { throw ChatGPTIdentity.Failure(AIUsage.shared.reason ?? "ChatGPT is unavailable.") }
        try Task.checkCancellation()
        let values = correction ? try await EditorSynonyms.proofread(text) : try await EditorSynonyms.suggest(.init(range: NSRange(location: 0, length: (text as NSString).length), text: text, context: context))
        return (values, provider == "ChatGPT" ? "Apple Intelligence · fallback" : "Apple Intelligence")
    }
    private static var cache: [(key: String, date: Date, choices: [String])] = []
    static func choices(text: String, context: String, correction: Bool) async throws -> [String] {
        let key = ChatGPTConnection.shared.model + "|" + (correction ? "fix|" : "synonym|") + text + "|" + context
        if let saved = cache.first(where: { $0.key == key && Date().timeIntervalSince($0.date) < 600 }) { return saved.choices }
        let input = try JSONSerialization.data(withJSONObject: ["selected": text, "context": context])
        let response = try await ChatGPTConnection.shared.respond(String(decoding: input, as: UTF8.self), instructions: correction ? AssistantPrompts.grammar : AssistantPrompts.synonyms)
        let choices: [String]
        if correction {
            let raw = response.trimmingCharacters(in: .whitespacesAndNewlines)
            let values = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            var seen = Set<String>([text])
            choices = Array(values.filter { !$0.isEmpty && $0.utf16.count <= 4000 && !$0.contains("\\") && !$0.contains("$") && seen.insert($0).inserted }.prefix(3))
        } else { choices = EditorSynonyms.candidates(response, for: text) }
        cache.removeAll { Date().timeIntervalSince($0.date) >= 600 }; cache.append((key, Date(), choices)); cache = Array(cache.suffix(64))
        return choices
    }
}
