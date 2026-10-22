import Foundation

/// Not attached to the shipping UI. A fake transport exercises lifecycle before socket adoption.
actor OverleafLiveCoordinator {
    private var state: OverleafLive.State
    private let transport: any OverleafLiveTransport
    private let gate: NetworkAccessGate
    private let checkpoint: URL
    private let writer: OverleafLiveWriterLease
    private var networkLease: UUID?
    private var submitting = false
    init(state: OverleafLive.State, transport: any OverleafLiveTransport, gate: NetworkAccessGate, directory: URL) throws {
        self.state = state; self.transport = transport; self.gate = gate; checkpoint = OverleafLiveJournal.checkpoint(for: state.key, under: directory)
        writer = try OverleafLiveWriterLease(file: OverleafLiveJournal.lock(for: state.key, under: directory))
    }
    func current() -> OverleafLive.Checkpoint { state.checkpoint }
    func phase() -> OverleafLive.Phase { state.phase }
    func edit(_ text: String) throws {
        var next = state; try next.edited(text); try persist(next)
    }
    func reconnect() async throws {
        try gate.requireOnline()
        if let networkLease { gate.release(networkLease); self.networkLease = nil }
        let previousEpoch = state.epoch
        let epoch = state.disconnect()
        await transport.stop(epoch: previousEpoch)
        try Task.checkCancellation(); try gate.requireOnline()
        guard state.epoch == epoch else { throw OverleafLive.Failure.staleEpoch }
        networkLease = try gate.watch { [weak self] in Task { await self?.stop(epoch: epoch) } }
        do {
            let remote = try await transport.snapshot(for: state.key, epoch: epoch)
            try Task.checkCancellation(); try gate.requireOnline()
            var next = state; try next.resume(remote, epoch: epoch); try persist(next)
        } catch { if state.epoch == epoch { state.disconnect() }; throw error }
    }
    func publishOne() async throws {
        try gate.requireOnline(); try Task.checkCancellation()
        guard !submitting else { return }
        var next = state
        guard let operation = try next.submission() else { return }
        try persist(next) // Recover the intent before sending anything.
        submitting = true; defer { submitting = false }
        do {
            let receipt = try await transport.submit(operation)
            try Task.checkCancellation(); try gate.requireOnline()
            next = state
            let accepted = next.acknowledge(receipt)
            try persist(next)
            if !accepted { throw OverleafLive.Failure.staleEpoch }
        } catch { if state.epoch == operation.epoch { state.disconnect() }; throw error }
    }
    func resolveReview(remote: OverleafLive.Snapshot, merged: String, expectedLocal: String) throws {
        var next = state; try next.resolveReview(remote: remote, merged: merged, expectedLocal: expectedLocal); try persist(next)
    }
    func stop() async {
        let epoch = state.epoch
        state.disconnect()
        if let networkLease { gate.release(networkLease); self.networkLease = nil }
        await transport.stop(epoch: epoch)
    }
    private func stop(epoch expected: UUID) async {
        guard state.epoch == expected else { return }
        await stop()
    }
    private func persist(_ next: OverleafLive.State) throws { try OverleafLiveJournal.save(next.checkpoint, to: checkpoint); state = next }
    deinit { if let networkLease { gate.release(networkLease) } }
}
