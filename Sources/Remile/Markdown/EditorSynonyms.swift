import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum EditorSynonyms {
    struct Word { let range: NSRange; let text: String; let context: String }
    static func word(at index: Int, in source: String) -> Word? {
        let raw = source as NSString
        guard index >= 0, index < raw.length,
              let pattern = try? NSRegularExpression(pattern: #"[\p{L}]+(?:['’][\p{L}]+)*"#) else { return nil }
        let start = max(0, index - 60), end = min(raw.length, index + 60)
        guard let range = pattern.matches(in: source, range: NSRange(location: start, length: end - start)).map(\.range).first(where: { NSLocationInRange(index, $0) }),
              range.length > 1, range.length <= 48,
              EditorSpellcheck.accepts(range, excluded: EditorSpellcheck.excluded(source)) else { return nil }
        let word = raw.substring(with: range)
        let contextStart = max(0, range.location - 240), contextEnd = min(raw.length, NSMaxRange(range) + 240)
        return Word(range: range, text: word, context: raw.substring(with: NSRange(location: contextStart, length: contextEnd - contextStart)))
    }
    static func candidates(_ response: String, for word: String) -> [String] {
        guard let data = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), let words = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>([word.lowercased()])
        return Array(words.compactMap { candidate -> String? in
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1, text.count <= 48, text.range(of: #"^[\p{L}]+(?:['’][\p{L}]+)*$"#, options: .regularExpression) != nil, seen.insert(text.lowercased()).inserted else { return nil }
            if word == word.uppercased() { return text.uppercased() }
            if word.first?.isUppercase == true { return text.prefix(1).uppercased() + text.dropFirst() }
            return text
        }.prefix(5))
    }
    static func proofread(_ text: String) async throws -> [String] {
        let status = AppleIntelligence.status()
        guard status.ready else { throw AppleIntelligence.Failure.unavailable(status.message) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let request = try JSONSerialization.data(withJSONObject: ["selected": text], options: [.sortedKeys])
            let model = LanguageModelSession(instructions: AssistantPrompts.grammar)
            let schema = try GenerationSchema(root: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 0, maximumElements: 3), dependencies: [])
            let result = try await model.respond(to: String(decoding: request, as: UTF8.self), schema: schema, options: GenerationOptions(temperature: 0, maximumResponseTokens: 800))
            try Task.checkCancellation()
            return try [String](result.content)
        }
        #endif
        throw AppleIntelligence.Failure.unavailable(status.message)
    }
    static func suggest(_ word: Word) async throws -> [String] {
        let status = AppleIntelligence.status()
        guard status.ready else { throw AppleIntelligence.Failure.unavailable(status.message) }
        let request = try JSONSerialization.data(withJSONObject: ["word": word.text, "context": word.context], options: [.sortedKeys])
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = LanguageModelSession(instructions: AssistantPrompts.deviceSynonyms)
            let schema = try GenerationSchema(root: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 6, maximumElements: 6), dependencies: [])
            let result = try await model.respond(to: String(decoding: request, as: UTF8.self), schema: schema, options: GenerationOptions(temperature: 0, maximumResponseTokens: 180))
            try Task.checkCancellation()
            return candidates(String(decoding: try JSONEncoder().encode([String](result.content)), as: UTF8.self), for: word.text)
        }
        #endif
        throw AppleIntelligence.Failure.unavailable(status.message)
    }
}
