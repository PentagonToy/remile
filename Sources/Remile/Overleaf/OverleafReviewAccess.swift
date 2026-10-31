import Foundation

enum OverleafReviewAccess {
    static let key = "overleaf.reviewWebAccess.enabled"
    static func requireEnabled(in defaults: UserDefaults = .standard) throws {
        guard defaults.bool(forKey: key) else {
            throw OverleafGit.Failure(
                "Enable the review connection in the Overleaf Review panel first. Source sync uses Git.")
        }
    }
}
