import Foundation

/// Shares one account restore and briefly backs off denied silent reads.
/// Stores coordination state only. Credentials remain in Keychain and WebKit.
@MainActor final class OverleafSessionAccess {
    private struct Attempt { let id: UUID; let interactive: Bool; let task: Task<Void, Error> }
    private var restoring: [UUID: Attempt] = [:]
    private var retryAfter: [UUID: Date] = [:]
    func restore(_ profile: UUID, interactive: Bool = false, now: Date = Date(), operation: @escaping @MainActor () async throws -> Void) async throws {
        if let pending = restoring[profile] {
            // An explicit retry waits for a silent attempt, then asks once itself.
            if !interactive || pending.interactive { try await pending.task.value; try Task.checkCancellation(); return }
            _ = try? await pending.task.value
            try Task.checkCancellation()
            if restoring[profile]?.id == pending.id { restoring[profile] = nil }
            try await restore(profile, interactive: true, now: now, operation: operation)
            return
        }
        if !interactive, let retry = retryAfter[profile], now < retry { throw OverleafWebClient.Failure.sessionLocked }
        let task = Task { try await operation() }, id = UUID()
        restoring[profile] = Attempt(id: id, interactive: interactive, task: task)
        defer { if restoring[profile]?.id == id { restoring[profile] = nil } }
        do { try await task.value; if restoring[profile]?.id == id { retryAfter[profile] = nil } }
        catch {
            if restoring[profile]?.id == id, (error as? OverleafWebClient.Failure) == .sessionLocked { retryAfter[profile] = now.addingTimeInterval(30) }
            throw error
        }
        try Task.checkCancellation()
    }
}
