import Foundation

/// A partial stream is never a completed suggestion.
struct ChatGPTStream {
    private(set) var text = ""
    private(set) var completed = false
    private var size = 0
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    mutating func receive(_ line: String) throws {
        size += line.utf8.count
        guard size <= 2_000_000 else { throw ChatGPTIdentity.Failure("The ChatGPT response exceeded the review limit.") }
        guard line.hasPrefix("data: "), let data = String(line.dropFirst(6)).data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = event["type"] as? String
        if ["response.failed", "response.incomplete", "error"].contains(type ?? "") {
            if let response = event["response"] as? [String: Any], let error = response["error"] as? [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: ["error": error]) { throw ChatGPTRequestFailure(status: 200, body: bytes, requestID: response["id"] as? String) }
            throw ChatGPTIdentity.Failure("ChatGPT did not finish the request. Check your plan usage and try again.")
        }
        guard !completed else { return }
        if type == "response.output_text.delta" { text += event["delta"] as? String ?? "" }
        if type == "response.completed" {
            completed = true
            if let response = event["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] { inputTokens = usage["input_tokens"] as? Int ?? 0; outputTokens = usage["output_tokens"] as? Int ?? 0 }
        }
    }
    func result() throws -> String {
        guard completed, !text.isEmpty else { throw ChatGPTIdentity.Failure("ChatGPT’s response was interrupted. No changes were applied.") }
        return text
    }
}
