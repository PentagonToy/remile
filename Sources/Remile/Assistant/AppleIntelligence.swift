import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Shared on-device inference boundary; no network model or provider selection.
enum AppleIntelligence {
    struct Status { let ready: Bool; let message: String }
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { switch self { case .unavailable(let message): return message } }
    }
    static func status() -> Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return Status(ready: true, message: "On-device")
            case .unavailable(.appleIntelligenceNotEnabled): return Status(ready: false, message: "Enable Apple Intelligence in System Settings.")
            case .unavailable(.modelNotReady): return Status(ready: false, message: "Apple Intelligence is preparing. Try again later.")
            case .unavailable(.deviceNotEligible): return Status(ready: false, message: "Apple Intelligence is unavailable on this Mac.")
            case .unavailable: return Status(ready: false, message: "Apple Intelligence is unavailable.")
            }
        }
        #endif
        return Status(ready: false, message: "Requires macOS 26 and Apple Intelligence.")
    }
    static func respond(to prompt: String, instructions: String, maximumTokens: Int = 450) async throws -> String {
        let state = status()
        guard state.ready else { throw Failure.unavailable(state.message) }
        try Task.checkCancellation()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let answer = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: maximumTokens))
            try Task.checkCancellation(); return answer.content
        }
        #endif
        throw Failure.unavailable(state.message)
    }
    static func retrievalPhrases(for question: String, instructions: String) async throws -> [String] {
        let state = status()
        guard state.ready else { throw Failure.unavailable(state.message) }
        try Task.checkCancellation()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let response = try await session.respond(to: question, generating: [String].self, options: GenerationOptions(temperature: 0, maximumResponseTokens: 180))
            try Task.checkCancellation()
            return response.content
        }
        #endif
        throw Failure.unavailable(state.message)
    }

}
