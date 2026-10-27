import SwiftUI

/// The document resizes once. Only the sidebar fades and moves during presentation.
@MainActor final class PDFSidebarPresentation: ObservableObject {
    static let duration = Duration.milliseconds(180)
    static let animation = Animation.easeOut(duration: 0.18)
    static let offset: CGFloat = 12
    @Published private(set) var mounted = false
    @Published private(set) var visible = false
    private var requested = false
    private var hiding: Task<Void, Never>?
    func setShown(_ shown: Bool, animated: Bool) {
        hiding?.cancel(); hiding = nil; requested = shown
        if shown {
            if mounted { visible = true }
            else { visible = !animated; mounted = true }
        } else {
            visible = false
            guard mounted, animated else { mounted = false; return }
            hiding = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.duration) } catch { return }
                guard let self, !self.requested else { return }
                self.mounted = false; self.hiding = nil
            }
        }
    }
    func appeared() { if requested { visible = true } }
    func cancel() { hiding?.cancel(); hiding = nil; requested = false; visible = false; mounted = false }
    deinit { hiding?.cancel() }
}
