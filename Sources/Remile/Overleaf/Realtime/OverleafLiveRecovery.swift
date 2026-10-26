import Foundation
import WebKit

/// Only transport/server availability failures qualify for unattended recovery.
enum OverleafLiveRecovery {
    static func transient(_ error: Error) -> Bool {
        if error is NetworkAccessGate.Offline { return true }
        if let failure = error as? OverleafLiveWire.Failure {
            switch failure {
            case .disconnected, .timeout: return true
            case .handshake(let status): return status == 408 || (500...599).contains(status)
            default: return false
            }
        }
        if let failure = error as? OverleafWebClient.Failure, case .unavailable = failure { return true }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable].contains(URLError.Code(rawValue: value.code))
        }
        return value.domain == WKError.errorDomain && value.code == WKError.webContentProcessTerminated.rawValue
    }
    static func delay(_ attempt: Int) -> Duration { .milliseconds([500, 1_000, 2_000, 4_000, 8_000, 15_000, 30_000][min(max(0, attempt), 6)]) }
}
