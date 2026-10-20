import Foundation

/// The document answer workflow stays identical for local and connected models.
@MainActor struct AssistantEngine {
    let status: () -> (ready: Bool, message: String)
    var singlePass = false
    var expandedContext = false
    let respond: (String, String, Int) async throws -> String
    static let onDevice = Self(status: { let status = AppleIntelligence.status(); return (status.ready, status.message) }, respond: { text, instructions, tokens in try await AppleIntelligence.respond(to: text, instructions: instructions, maximumTokens: tokens) })
}
