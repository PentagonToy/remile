import Foundation
import CryptoKit
import Security
import LocalAuthentication

struct OverleafConnection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var profileID = UUID()
    let projectID: String
    var name: String
    var account: String
    var branch: String
    var liveOnly: Bool? = nil
    var webURL: URL { URL(string: "https://www.overleaf.com/project/" + projectID)! }
    var remote: String { "https://git@git.overleaf.com/" + projectID }
    static func projectID(_ value: String) -> String? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", ["www.overleaf.com", "overleaf.com", "git.overleaf.com"].contains(url.host), url.password == nil, url.query == nil, url.fragment == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        let id = url.host == "git.overleaf.com" && parts.count == 1 ? String(parts[0]) : parts.count == 2 && parts[0] == "project" ? String(parts[1]) : ""
        return id.range(of: "^[a-fA-F0-9]{24}$", options: .regularExpression) != nil ? id.lowercased() : nil
    }
}

enum OverleafCredential {
    static let service = "local.remile.overleaf.git"
    private static let lock = NSLock()
    private static var tokens: [UUID: String] = [:]
    enum Availability { case available, missing, locked }
    static func availability(_ id: UUID) -> Availability {
        lock.lock(); let cached = tokens[id] != nil; lock.unlock()
        if cached { return .available }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let result = KeychainAccess.read(matching: query, interactive: false)
        if result.status == errSecItemNotFound { return .missing }
        return result.status == errSecSuccess && result.data != nil ? .available : .locked
    }
    static func read(_ id: UUID, interactive: Bool = false) throws -> String {
        lock.lock()
        if let token = tokens[id] { lock.unlock(); return token }
        lock.unlock()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let result = KeychainAccess.read(matching: query, interactive: interactive)
        switch result.status {
        case errSecItemNotFound:
            throw OverleafGit.Failure("No Git token is saved for this account. Open Git token in Connection options.")
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw OverleafGit.Failure("Choose Sync now to allow Keychain access to the saved Git token.")
        default:
            guard result.status == errSecSuccess, let data = result.data,
                  let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                throw OverleafGit.Failure("Could not read the saved Git token from Keychain.")
            }
            lock.lock(); tokens[id] = token; lock.unlock(); return token
        }
    }
    static func store(_ token: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw OverleafGit.Failure("Unable to save the credential in Keychain.") }
        if status == errSecDuplicateItem, SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess { throw OverleafGit.Failure("Unable to update the Keychain credential.") }
        lock.lock(); tokens[id] = token; lock.unlock()
    }
    static func erase(_ id: UUID) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OverleafGit.Failure("The saved Git token could not be removed. Unlock Keychain and try again.") }
        lock.lock(); tokens.removeValue(forKey: id); lock.unlock()
    }
    static func remove(_ id: UUID) { try? erase(id) }

}

enum OverleafGit {
    struct SnapshotChanged: Error {}

    static func head(_ root: URL) throws -> String {
        try run(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        let retryAfter: TimeInterval?
        let httpStatus: Int?
        init(_ message: String, retryAfter: TimeInterval? = nil, httpStatus: Int? = nil) {
            errorDescription = message; self.retryAfter = retryAfter; self.httpStatus = httpStatus
        }
    }
    struct Transfer: Sendable {
        enum Phase: String { case fetch, push, confirm }
        let phase: Phase
        let milliseconds: Int
        let succeeded: Bool
        let httpStatus: Int?

        var status: [String: Any] {
            var value: [String: Any] = ["phase": phase.rawValue, "milliseconds": milliseconds, "succeeded": succeeded]
            if let httpStatus { value["httpStatus"] = httpStatus }
            return value
        }
    }
    typealias RecordTransfer = (Transfer) -> Void
    struct Result { let status: Int32; let data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
    struct Change: Identifiable, Sendable {
        let path: String
        let local: String
        let remote: String
        let result: String
        let conflict: Bool
        var id: String { path }
    }
    struct Review: Sendable {
        let id = UUID()
        let connection: OverleafConnection
        let root: URL
        let stage: URL
        let fingerprint: String
        let remoteHead: String
        let transport: String
        let changes: [Change]
        let localChanges: Bool
        var localFiles: [String: Data] = [:]
    }
    /// Git output is bounded on disk, so large repositories cannot block a full pipe.
    static func run(_ args: [String], at directory: URL, credential: UUID? = nil, allowFailure: Bool = false, input: Data? = nil, index: URL? = nil) throws -> Result {
        try Task.checkCancellation()
        let networking = args.contains { $0.hasPrefix("https://") || $0.hasPrefix("http://") || $0.hasPrefix("ssh://") }
        if networking { try NetworkAccess.requireOnline() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("remile-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("output"), errors = scratch.appendingPathComponent("errors")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]); FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = directory
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        process.arguments = ["-c", "credential.helper=", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=never", "-c", "core.quotePath=false", "-c", "core.fileMode=false"] + args
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"; environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        if let index { environment["GIT_INDEX_FILE"] = index.path }
        environment["GIT_AUTHOR_NAME"] = "remile."; environment["GIT_AUTHOR_EMAIL"] = "local@remile.invalid"
        environment["GIT_COMMITTER_NAME"] = "remile."; environment["GIT_COMMITTER_EMAIL"] = "local@remile.invalid"
        if let credential, args.contains(where: { $0.hasPrefix("https://git@git.overleaf.com/") }) {
            let askpass = scratch.appendingPathComponent("askpass")
            let script = "#!/bin/sh\ncase \"$1\" in *Username*) printf '%s\\n' git ;; *) printf '%s\\n' \"$REMILE_GIT_TOKEN\" ;; esac\n"
            try script.write(to: askpass, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            environment["GIT_ASKPASS"] = askpass.path
            // Only the child process receives the secret. No token in arguments, scripts or Git configuration.
            environment["REMILE_GIT_TOKEN"] = try OverleafCredential.read(credential)
        }
        process.environment = environment; process.standardOutput = stdout; process.standardError = stderr
        if let input { let path = scratch.appendingPathComponent("input"); try input.write(to: path); process.standardInput = try FileHandle(forReadingFrom: path) }
        else { process.standardInput = FileHandle.nullDevice }
        var lease: UUID?
        if networking { lease = try NetworkAccess.gate.start(process) } else { try process.run() }
        defer { if let lease { NetworkAccess.gate.release(lease) } }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
        while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled, process.isRunning { process.terminate() }
        }
        watchdog.cancel()
        try Task.checkCancellation()
        let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size < 32 * 1024 * 1024 else { throw Failure("The project diff is too large to review at once.") }
        let result = Result(status: process.terminationStatus, data: try Data(contentsOf: output))
        // Never return server output: redirects, credentials and private remotes can appear in Git errors.
        if result.status != 0 && !allowFailure {
            if networking, let error = try? FileHandle(forReadingFrom: errors) {
                defer { try? error.close() }
                let message = String(decoding: (try? error.read(upToCount: 65536)) ?? Data(), as: UTF8.self).lowercased()
                throw transportFailure(message)
            }
            throw Failure("Could not complete the Git operation. Check the connection, project access and Git token, then retry.")
        }
        return result
    }
    static func transportFailure(_ message: String) -> Failure {
        let status = message.range(of: "returned error: ").flatMap { Int(message[$0.upperBound...].prefix(3)) }
            .flatMap { (400...599).contains($0) ? $0 : nil }
        if status == 429 || message.contains("error: 429") || message.contains("too many requests") || message.contains("rate limit") {
            return Failure("Overleaf is receiving too many requests. Your work is saved locally. Sync will retry later.", retryAfter: 300, httpStatus: status)
        }
        if status == 403 { return Failure("Overleaf refused the Git request (HTTP 403). Sync will try again.", retryAfter: 120, httpStatus: status) }
        return Failure("Could not complete the Git operation. Check the connection, project access and Git token, then retry.", httpStatus: status)
    }
    static func transfer(_ phase: Transfer.Phase, _ args: [String], at root: URL, credential: UUID, record: RecordTransfer?) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        func emit(_ succeeded: Bool, _ status: Int?) {
            record?(.init(phase: phase, milliseconds: Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000),
                          succeeded: succeeded, httpStatus: status))
        }
        do {
            _ = try run(args, at: root, credential: credential)
            emit(true, nil)
        } catch {
            emit(false, (error as? Failure)?.httpStatus)
            throw error
        }
    }
    static func clone(_ connection: OverleafConnection, root: URL) throws -> String {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try run(["clone", "--single-branch", "--", connection.remote, root.path], at: root.deletingLastPathComponent(), credential: connection.profileID)
        _ = try run(["config", "core.autocrlf", "false"], at: root)
        try excludePrivateFiles(root)
        return try run(["symbolic-ref", "--short", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func excludePrivateFiles(_ root: URL) throws {
        let path = root.appendingPathComponent(".git/info/exclude")
        let original = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard !original.contains("# remile. local data") else { return }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (original + "\n# remile. local data\n.DS_Store\nThumbs.db\n.remile/\n.env\n.env.*\n*.pem\n*.key\n.git-credentials\n.ssh/\n").write(to: path, atomically: true, encoding: .utf8)
    }
    static func fingerprint(_ root: URL) throws -> String {
        let names = try run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], at: root).text.split(separator: "\0").map(String.init)
        var hash = SHA256()
        for path in Set(names).sorted() {
            let url = try TeXFileSystem.url(path, root: root)
            hash.update(data: Data(path.utf8)); hash.update(data: Data([0]))
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw Failure("Review ordinary project files up to 128 MB each.") }
                hash.update(data: try Data(contentsOf: url, options: .mappedIfSafe))
            } else { hash.update(data: Data("missing".utf8)) }
        }
        hash.update(data: try run(["rev-parse", "HEAD"], at: root).data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func prepare(_ connection: OverleafConnection, root: URL, reviewRoot: URL, transport: String? = nil, includeContents: Bool = true, stageDirectory: URL? = nil, record: RecordTransfer? = nil) throws -> Review {
        try excludePrivateFiles(root)
        let transport = transport ?? connection.remote
        try transfer(.fetch, (transport.hasPrefix("/") ? ["-c", "protocol.file.allow=always"] : []) + ["fetch", "--no-tags", transport, "refs/heads/" + connection.branch], at: root, credential: connection.profileID, record: record)
        let remote = try run(["rev-parse", "FETCH_HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stage = stageDirectory ?? reviewRoot.appendingPathComponent(UUID().uuidString)
        if try run(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) == remote,
           try run(["status", "--porcelain", "--untracked-files=normal"], at: root).data.isEmpty {
            return Review(connection: connection, root: root, stage: stage, fingerprint: "", remoteHead: remote, transport: transport, changes: [], localChanges: false)
        }
        let before = try fingerprint(root)
        if stageDirectory != nil { try OverleafSyncRecovery.checkCapacity(root: root, recovery: reviewRoot) }
        try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A private review copy keeps merges and conflicts away from the active editor.
        _ = try run(["-c", "protocol.file.allow=always", "clone", "--shared", "--no-checkout", "--", root.path, stage.path], at: reviewRoot)
        do {
            _ = try run(["checkout", "-b", "remile-review", "HEAD"], at: stage)
            let patch = try run(["diff", "--binary", "HEAD", "--"], at: root).data
            if !patch.isEmpty { _ = try run(["apply", "--binary", "--index", "-"], at: stage, input: patch) }
            let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z"], at: root).text.split(separator: "\0").map(String.init)
            for path in untracked {
                let from = try TeXFileSystem.url(path, root: root), to = try TeXFileSystem.url(path, root: stage)
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            }
            // Automatic sync reconciles later edits against this private copy.
            if !includeContents, try fingerprint(root) != before { throw SnapshotChanged() }
            _ = try run(["add", "-A"], at: stage)
            let dirty = try run(["diff", "--cached", "--quiet"], at: stage, allowFailure: true).status != 0
            if dirty { _ = try run(["-c", "commit.gpgsign=false", "commit", "-m", "Local writing changes"], at: stage) }
            let localFiles = try OverleafSourceFiles.scan(stage)
            let localHead = try run(["rev-parse", "HEAD"], at: stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let merge = try run(["-c", "commit.gpgsign=false", "merge", "--no-commit", remote], at: stage, allowFailure: true)
            let conflicts = Set(try run(["diff", "--name-only", "--diff-filter=U", "-z"], at: stage).text.split(separator: "\0").map(String.init))
            guard merge.status == 0 || !conflicts.isEmpty else { throw Failure("These revisions could not be merged. The local project is unchanged.") }
            let base = try run(["merge-base", localHead, remote], at: stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let localNames = try run(["diff", "--name-only", "-z", base, localHead, "--"], at: stage).text.split(separator: "\0").map(String.init)
            let remoteNames = try run(["diff", "--name-only", "-z", base, remote, "--"], at: stage).text.split(separator: "\0").map(String.init)
            func content(_ ref: String, _ path: String) throws -> String {
                let data = try run(["show", ref + ":" + path], at: stage, allowFailure: true).data
                return data.count < 600_000 && !data.contains(0) ? String(data: data, encoding: .utf8) ?? "Binary file" : "Binary file"
            }
            let changes = try Set(localNames + remoteNames).sorted().map { path in
                // Automatic sync needs paths and conflict flags, not three display copies per file.
                if !includeContents { return Change(path: path, local: "", remote: "", result: "", conflict: conflicts.contains(path)) }
                let url = try TeXFileSystem.url(path, root: stage)
                let data = (try? Data(contentsOf: url)) ?? Data()
                let text = data.count < 600_000 && !data.contains(0) ? String(data: data, encoding: .utf8) ?? "Binary file" : "Binary file"
                return Change(path: path, local: try content(localHead, path), remote: try content(remote, path), result: text, conflict: conflicts.contains(path))
            }
            if includeContents, try fingerprint(root) != before {
                throw Failure("The local files changed while checking. Check again to review the latest version.")
            }
            return Review(connection: connection, root: root, stage: stage, fingerprint: before, remoteHead: remote, transport: transport, changes: changes, localChanges: dirty || !localNames.isEmpty, localFiles: localFiles)
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }
    static func finish(_ review: Review, choices: [String: Bool], publish: Bool) throws {
        guard try fingerprint(review.root) == review.fingerprint else { throw Failure("The local files changed. Check again before applying this review.") }
        for change in review.changes where change.conflict {
            guard let local = choices[change.path] else { throw Failure("Choose a version for every conflicting file.") }
            let side = local ? "--ours" : "--theirs"
            // A deleted side has no stage entry. Selecting it means deleting this file.
            let result = try run(["checkout", side, "--", change.path], at: review.stage, allowFailure: true)
            if result.status != 0 {
                let stage = local ? ":2:" : ":3:"
                guard try run(["cat-file", "-e", stage + change.path], at: review.stage, allowFailure: true).status != 0 else { throw Failure("Could not resolve this file.") }
                let path = try TeXFileSystem.url(change.path, root: review.stage)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
        }
        _ = try run(["add", "-A"], at: review.stage)
        let mergePending = FileManager.default.fileExists(atPath: review.stage.appendingPathComponent(".git/MERGE_HEAD").path)
        if mergePending { _ = try run(["-c", "commit.gpgsign=false", "commit", "-m", "Merge reviewed Overleaf changes"], at: review.stage) }
        _ = try run(["fetch", "--no-tags", review.transport, "refs/heads/" + review.connection.branch], at: review.root, credential: review.connection.profileID)
        let current = try run(["rev-parse", "FETCH_HEAD"], at: review.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == review.remoteHead, try fingerprint(review.root) == review.fingerprint else { throw Failure("The project changed. Check again. Your local edits are safe.") }
        if publish {
            let tree = try run(["write-tree"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = try run(["commit-tree", tree, "-p", review.remoteHead, "-m", "Update reviewed manuscript"], at: review.stage).text.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try run(["update-ref", "HEAD", commit], at: review.stage)
            _ = try run(["push", review.transport, "HEAD:refs/heads/" + review.connection.branch], at: review.stage, credential: review.connection.profileID)
        }
        // Fetch the accepted tree before dropping the private review copy.
        _ = try run(["-c", "protocol.file.allow=always", "fetch", review.stage.path, "HEAD"], at: review.root)
        guard try fingerprint(review.root) == review.fingerprint else { throw Failure("The remote action finished, but local files changed. Reopen the comparison to reconcile them.") }
        _ = try run(["reset", "--hard", "FETCH_HEAD"], at: review.root)
        _ = try run(["gc", "--auto"], at: review.root, allowFailure: true)
    }
}
