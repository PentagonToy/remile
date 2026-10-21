import AppKit
import Combine
import PDFKit
import SwiftUI

/// One consent and one temporary original per document transaction. No per-stroke files or timers.
final class PDFEditProtection: ObservableObject {
    @Published private(set) var requiresConsent = false
    @Published private(set) var authorised = false
    @Published private(set) var attempts = 0
    private(set) var snapshotURL: URL?
    var isLocked: Bool { requiresConsent && !authorised }
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remile-pdf-edits", isDirectory: true)
    private static let reapOrphans: Void = {
        let manager = FileManager.default
        for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            let parts = url.lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, UUID(uuidString: String(parts[1])) != nil,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? manager.removeItem(at: url)
        }
    }()
    func configure(_ document: PDFDocument?) {
        finish()
        requiresConsent = document.map(PDFFormPreservation.hasDigitalSignature) ?? false
        attempts = 0
    }
    func requireConsent() { requiresConsent = true }
    func refuse() { attempts += 1 }
    /// Invoked only by the visible lock control, never automatically by a blocked edit.
    func requestUnlock(data: Data) {
        guard isLocked else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Unlock PDF editing?"
        alert.informativeText = "Changes may alter or invalidate digital signatures. A temporary original is kept until you save or discard."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Unlock Editing")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try authorise(data: data) } catch { NSAlert(error: error).runModal() }
    }
    /// Call only after explicit consent. Separated from the dialog for controlled transaction tests.
    func authorise(data: Data) throws {
        guard requiresConsent else { return }
        try keepOriginal(data)
        authorised = true
    }
    func allowEdit(data: Data) throws -> Bool {
        guard !isLocked else { refuse(); return false }
        if requiresConsent { try keepOriginal(data) }
        return true
    }
    private func keepOriginal(_ data: Data) throws {
        guard snapshotURL == nil else { return }
        _ = Self.reapOrphans
        let manager = FileManager.default
        try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = Self.directory.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent("original.pdf")
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            snapshotURL = url
        } catch { try? manager.removeItem(at: folder); throw error }
    }
    func committed() { removeSnapshot() }
    func finish() { removeSnapshot(); authorised = false }
    private func removeSnapshot() {
        if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
        snapshotURL = nil
    }
    deinit { if let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) } }
}

struct PDFProtectionButton: View {
    @ObservedObject var protection: PDFEditProtection
    let unlock: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance.animations") private var animations = true
    var body: some View {
        Button(action: unlock) {
            Image(systemName: protection.isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 15, weight: .semibold)).frame(width: 32, height: 28).contentShape(Rectangle())
                .modifier(LockShake(progress: (reduceMotion || !animations) ? 0 : Double(protection.attempts)))
                .animation((reduceMotion || !animations) ? nil : .easeInOut(duration: 0.35), value: protection.attempts)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(protection.isLocked ? "Unlock signed PDF editing" : "Signed PDF editing unlocked")
        .help(protection.isLocked ? "Unlock editing. Changes may affect digital signatures." : "Editing unlocked for this document. The original is kept until Save or Discard.")
    }
    private struct LockShake: GeometryEffect {
        var progress: Double
        var animatableData: Double { get { progress } set { progress = newValue } }
        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: sin(progress * .pi * 6) * 5, y: 0))
        }
    }
}
