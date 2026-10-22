import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum EditorProofreading {
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
}
