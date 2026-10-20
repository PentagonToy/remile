import Foundation

struct ChatGPTRequestFailure: LocalizedError {
    let status: Int
    let code: String?
    let parameter: String?
    let requestID: String?
    let body: Data
    init(status: Int, body: Data, requestID: String?) {
        self.status = status; self.body = body; self.requestID = requestID
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        code = error?["code"] as? String; parameter = error?["param"] as? String
    }
    var errorDescription: String? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return "This app has reached its ChatGPT usage allowance. Check ChatGPT Settings → Usage."
        case "subscription_sharing_user_not_eligible": return "This ChatGPT account or workspace does not currently allow plan usage in this app."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return "ChatGPT is temporarily unable to check plan access. Your connection is saved; try again shortly."
        case "subscription_sharing_unsupported_capability": return "ChatGPT could not accept this request" + (parameter.map { " (" + $0 + ")" } ?? "") + ". No changes were applied."
        default: return "ChatGPT could not complete the request (\(status)" + (code.map { ", " + $0 } ?? "") + "). No changes were applied."
        }
    }
}
