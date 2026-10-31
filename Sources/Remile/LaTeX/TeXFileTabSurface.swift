import AppKit
import SwiftUI

@MainActor final class TeXFileTabDragState: ObservableObject {
    @Published var source: String?
    @Published var target: String?
    @Published var after = false
    func finish() { source = nil; target = nil; after = false }
}

/// Like PDF tabs, this is a local pointer move. No external drag or window detachment.
struct TeXFileTabSurface: NSViewRepresentable {
    let project: TeXProject
    let file: String
    let drag: TeXFileTabDragState
    let rename: () -> Void
    func makeNSView(context: Context) -> TeXFileTabButton { TeXFileTabButton() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TeXFileTabButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? DocumentTabMetrics.maximumWidth, height: proposal.height ?? DocumentTabMetrics.labelHeight)
    }
    func updateNSView(_ view: TeXFileTabButton, context: Context) {
        view.project = project; view.file = file; view.drag = drag; view.rename = rename
        view.setAccessibilityLabel((file as NSString).lastPathComponent)
        view.setAccessibilityValue(project.selected == file ? "Selected" : "")
        view.toolTip = file + "\nDrag to reorder. Double-click to rename."
    }
}

final class TeXFileTabButton: NSButton {
    private static let surfaces = NSHashTable<TeXFileTabButton>.weakObjects()
    weak var project: TeXProject?
    weak var drag: TeXFileTabDragState?
    var file = ""
    var rename: (() -> Void)?
    private var down: NSEvent?
    private var moving = false
    private var keyMonitor: Any?
    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.surfaces.add(self)
        isBordered = false; title = ""; target = self; action = #selector(selectFile)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {}
    @objc private func selectFile() { project?.selected = file }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let window,
              moving || hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) >= 5 else { return }
        if !moving {
            moving = true; drag?.source = file
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.finish(); return nil
            }
        }
        let destination = destination(at: window.convertPoint(toScreen: event.locationInWindow))
        if drag?.target != destination?.0 { drag?.target = destination?.0 }
        let after = destination?.1 ?? false
        if drag?.after != after { drag?.after = after }
        NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        let moved = moving
        let destination = window.flatMap { self.destination(at: $0.convertPoint(toScreen: event.locationInWindow)) }
        finish()
        if moved, let destination { project?.moveFileTab(file, to: destination.0, after: destination.1) }
        else if !moved { selectFile(); if event.clickCount == 2 { rename?() } }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finish() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finish() {
        let owned = moving; moving = false; down = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        if owned { drag?.finish(); NSCursor.arrow.set() }
    }
    private func destination(at point: NSPoint) -> (String, Bool)? {
        Self.surfaces.allObjects.compactMap { surface -> (String, Bool, CGFloat)? in
            guard let window = surface.window, window === self.window, surface.project === project,
                  surface.file != file, !surface.visibleRect.intersection(surface.bounds).isEmpty else { return nil }
            let rect = window.convertToScreen(surface.convert(surface.visibleRect.intersection(surface.bounds), to: nil))
            guard rect.insetBy(dx: -16, dy: -6).contains(point) else { return nil }
            return (surface.file, point.x > rect.midX, abs(point.x - rect.midX))
        }.min(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }
}
