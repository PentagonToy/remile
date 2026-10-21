import Foundation

/// Publish a saved local snapshot without replacing files or reloading the editor.
enum OverleafAutoPublisher {
    static func needsCheck(_ project: OverleafConnection, root: URL, transport: String? = nil) throws -> Bool {
        let remote = try OverleafGit.run(["ls-remote", "--exit-code", transport ?? project.remote, "refs/heads/" + project.branch], at: root, credential: project.profileID).text.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard let remote else { throw OverleafGit.Failure("Project revision unavailable.") }
        return try remote != head(root) || !OverleafGit.run(["status", "--porcelain", "--untracked-files=normal"], at: root).data.isEmpty
    }
    static func head(_ root: URL) throws -> String {
        try OverleafGit.run(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func isLocalOnly(_ review: OverleafGit.Review) throws -> Bool {
        try head(review.root) == review.remoteHead && !review.changes.contains(where: \.conflict)
    }
    static func publish(_ review: OverleafGit.Review) throws {
        guard try isLocalOnly(review), try OverleafGit.fingerprint(review.root) == review.fingerprint else {
            throw OverleafGit.Failure("The project changed. Check changes before syncing.")
        }
        _ = try OverleafGit.run(["fetch", "--no-tags", review.transport, "refs/heads/" + review.connection.branch], at: review.root, credential: review.connection.profileID)
        let remote = try OverleafGit.run(["rev-parse", "FETCH_HEAD"], at: review.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote == review.remoteHead, try isLocalOnly(review) else { throw OverleafGit.Failure("Overleaf has new changes. Check changes to review them.") }
        // A normal push rejects a remote change racing the fetch; never force-push.
        _ = try OverleafGit.run(["push", review.transport, "HEAD:refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID)
        _ = try OverleafGit.run(["-c", "protocol.file.allow=always", "fetch", review.stage.path, "HEAD"], at: review.root)
        guard try head(review.root) == review.remoteHead else { throw OverleafGit.Failure("Published the saved version. Check changes to reconcile the local revision.") }
        // Mixed reset advances the base only. Edits made during upload remain on disk and in the editor.
        _ = try OverleafGit.run(["reset", "--mixed", "FETCH_HEAD"], at: review.root)
    }
}
