import Foundation

/// Transport-independent preparation. No editor socket or filesystem watcher is started here.
enum OverleafLive {
    static let textLimit = 2_000_000
    enum Failure: Error { case invalidIdentity, invalidText, invalidVersion, staleEpoch, staleSnapshot, reviewRequired, staleDraft, invalidCheckpoint, writerBusy }
    struct Key: Codable, Hashable, Sendable {
        let profile: UUID
        let project: String
        let document: String
        func validate() throws {
            for id in [project, document] {
                guard id.utf8.count == 24 && id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidIdentity }
            }
        }
    }
    static func validate(_ text: String) throws {
        guard text.utf8.count <= textLimit, !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { throw Failure.invalidText }
    }
    struct Snapshot: Codable, Equatable, Sendable {
        let version: Int
        let text: String
        func validate() throws {
            guard version >= 0, version < Int.max else { throw Failure.invalidVersion }
            try OverleafLive.validate(text)
        }
    }
    /// One bounded replacement, indexed in JavaScript-compatible UTF-16 units.
    struct Edit: Codable, Equatable, Sendable {
        let offset: Int
        let deleted: String
        let inserted: String
        static func between(_ before: String, _ after: String) throws -> Edit {
            try OverleafLive.validate(before); try OverleafLive.validate(after)
            let a = Array(before.unicodeScalars), b = Array(after.unicodeScalars)
            var start = 0, tail = 0
            while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
            while tail < min(a.count, b.count) - start, a[a.count - tail - 1] == b[b.count - tail - 1] { tail += 1 }
            func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(scalars)) }
            return Edit(offset: text(a[..<start]).utf16.count, deleted: text(a[start..<(a.count - tail)]), inserted: text(b[start..<(b.count - tail)]))
        }
    }
    struct Submission: Codable, Equatable, Sendable {
        let id: UUID
        let epoch: UUID
        let key: Key
        let baseVersion: Int
        let edit: Edit
        let after: String
    }
    struct Receipt: Sendable {
        let id: UUID
        let epoch: UUID
        let key: Key
        let version: Int
    }
    struct Checkpoint: Codable, Sendable {
        let schemaVersion: Int
        let key: Key
        let base: Snapshot
        let local: String
        let inFlight: Submission?
        func validate() throws {
            guard schemaVersion == 1 else { throw Failure.invalidCheckpoint }
            try key.validate(); try base.validate(); try OverleafLive.validate(local)
            if let inFlight {
                guard inFlight.key == key, inFlight.baseVersion == base.version,
                      inFlight.edit == (try Edit.between(base.text, inFlight.after)) else { throw Failure.invalidCheckpoint }
            }
        }
    }
    enum Phase: Equatable { case disconnected, ready, awaitingAcknowledgement, reviewRequired }
    struct State: Sendable {
        let key: Key
        private(set) var base: Snapshot
        private(set) var local: String
        private(set) var inFlight: Submission?
        private(set) var epoch = UUID()
        private(set) var connected = false
        private(set) var review: Snapshot?
        var phase: Phase { !connected ? .disconnected : review != nil ? .reviewRequired : inFlight != nil ? .awaitingAcknowledgement : .ready }
        var checkpoint: Checkpoint { Checkpoint(schemaVersion: 1, key: key, base: base, local: local, inFlight: inFlight) }
        init(key: Key, base: Snapshot, local: String? = nil) throws {
            try key.validate(); try base.validate(); try OverleafLive.validate(local ?? base.text)
            self.key = key; self.base = base; self.local = local ?? base.text
        }
        init(checkpoint: Checkpoint) throws {
            try checkpoint.validate()
            key = checkpoint.key; base = checkpoint.base; local = checkpoint.local; inFlight = checkpoint.inFlight
            // A recovered submission is uncertain until a fresh server snapshot is read.
        }
        mutating func edited(_ text: String) throws { try OverleafLive.validate(text); local = text }
        @discardableResult mutating func disconnect() -> UUID { connected = false; epoch = UUID(); return epoch }
        mutating func resume(_ remote: Snapshot, epoch expected: UUID) throws {
            guard expected == epoch else { throw Failure.staleEpoch }
            try remote.validate()
            guard remote.version >= base.version else { throw Failure.staleSnapshot }
            // The same server version cannot describe different text.
            if remote.version == base.version, remote.text != base.text { review = remote; connected = true; return }
            if remote.text == base.text || remote.text == local || remote.text == inFlight?.after {
                base = remote; inFlight = nil; review = nil
            } else { review = remote }
            connected = true
        }
        mutating func submission() throws -> Submission? {
            guard connected else { return nil }
            guard review == nil else { throw Failure.reviewRequired }
            guard inFlight == nil, local != base.text else { return nil }
            let value = Submission(id: UUID(), epoch: epoch, key: key, baseVersion: base.version, edit: try Edit.between(base.text, local), after: local)
            inFlight = value; return value
        }
        @discardableResult mutating func acknowledge(_ receipt: Receipt) -> Bool {
            guard connected, review == nil, let pending = inFlight, receipt.key == key,
                  receipt.epoch == epoch, pending.epoch == epoch, receipt.id == pending.id else { return false }
            guard receipt.version < Int.max, receipt.version == base.version + 1 else { disconnect(); return false }
            base = Snapshot(version: receipt.version, text: pending.after); inFlight = nil
            return true // New edits in local remain untouched.
        }
        mutating func resolveReview(remote: Snapshot, merged: String, expectedLocal: String) throws {
            guard connected, review == remote else { throw Failure.reviewRequired }
            guard local == expectedLocal else { throw Failure.staleDraft }
            try OverleafLive.validate(merged)
            base = remote; local = merged; inFlight = nil; review = nil
        }
    }
}

/// A future socket adapter must provide bounded snapshots and correlated receipts.
/// The coordinator owns offline gating; neither this contract nor State opens a connection.
protocol OverleafLiveTransport: Sendable {
    func snapshot(for key: OverleafLive.Key, epoch: UUID) async throws -> OverleafLive.Snapshot
    func submit(_ operation: OverleafLive.Submission) async throws -> OverleafLive.Receipt
    func stop(epoch: UUID) async
}
