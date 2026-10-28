import AppKit
import SwiftUI

/// Only tab strips observe pointer feedback. Document and PDF state stay untouched.
@MainActor final class PDFTabDragState: ObservableObject {
    static let shared = PDFTabDragState()
    struct Feedback: Equatable {
        let source: ObjectIdentifier
        var target: ObjectIdentifier?
        var after = false
    }
    @Published private(set) var feedback: Feedback?
    func begin(_ source: ObjectIdentifier) { feedback = Feedback(source: source) }
    func hover(_ target: ObjectIdentifier?, after: Bool = false) {
        guard var next = feedback else { return }
        next.target = target == next.source ? nil : target; next.after = after
        if next != feedback { feedback = next }
    }
    func finish() { if feedback != nil { feedback = nil } }
}

/// A tab is an in-app move, with no pasteboard or external drop negotiation.
struct PDFTabDragSurface: NSViewRepresentable {
    let id: ObjectIdentifier
    let title: String
    func makeNSView(context: Context) -> PDFTabDragView { PDFTabDragView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFTabDragView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: proposal.height ?? 30)
    }
    func updateNSView(_ view: PDFTabDragView, context: Context) {
        view.tabID = id; view.tabTitle = title; view.setAccessibilityLabel(title)
        view.toolTip = "Drag to reorder or move to another window"
    }
}

final class PDFTabDragView: NSButton {
    private static let surfaces = NSHashTable<PDFTabDragView>.weakObjects()
    var tabID: ObjectIdentifier?
    var tabTitle = ""
    private var down: NSEvent?
    private var dragging = false
    private var keyMonitor: Any?
    private var preview: NSPanel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.surfaces.add(self)
        isBordered = false; title = ""; target = self; action = #selector(selectTab)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // SwiftUI draws the label. This button owns its full click and drag region.
    override func draw(_ dirtyRect: NSRect) {}
    @objc private func selectTab() { if let tabID { RemileWindows.shared.selectDocumentTab(tabID) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let tabID, let window,
              dragging || hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) >= 5 else { return }
        if !dragging {
            dragging = true; PDFTabDragState.shared.begin(tabID)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.finishFeedback(); return nil
            }
            makePreview()
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let target = Self.target(at: point)
        PDFTabDragState.shared.hover(target?.0, after: target?.1 ?? false)
        preview?.setFrameOrigin(NSPoint(x: point.x + 14, y: point.y - 24))
        NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        let moved = dragging
        let point = window?.convertPoint(toScreen: event.locationInWindow)
        // Remove the preview before finding the destination window.
        finishFeedback()
        guard moved, let point, let tabID else { if !moved { selectTab() }; return }
        if let (destination, after) = Self.target(at: point) {
            RemileWindows.shared.moveDocumentTab(tabID, to: destination, after: after)
        } else if !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) {
            RemileWindows.shared.detachDocumentTab(tabID, at: point)
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishFeedback() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finishFeedback() {
        let ownedGesture = dragging
        down = nil; dragging = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        preview?.orderOut(nil); preview = nil
        if ownedGesture { PDFTabDragState.shared.finish(); NSCursor.arrow.set() }
    }
    private func makePreview() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: min(220, max(92, bounds.width)), height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
        panel.level = .floating; panel.hasShadow = true; panel.alphaValue = 0.92
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = effectiveAppearance; panel.backgroundColor = .windowBackgroundColor
        let label = NSTextField(labelWithString: tabTitle)
        label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 10, y: 7, width: panel.frame.width - 20, height: 16)
        panel.contentView?.addSubview(label)
        preview = panel
        if let point = window?.convertPoint(toScreen: down?.locationInWindow ?? .zero) {
            panel.setFrameOrigin(NSPoint(x: point.x + 14, y: point.y - 24))
        }
        panel.orderFront(nil)
    }
    private static func target(at point: NSPoint) -> (ObjectIdentifier, Bool)? {
        let candidates = surfaces.allObjects
        let front = NSApp.orderedWindows.first { window in
            window.isVisible && window.frame.contains(point) && candidates.contains { $0.window === window }
        }
        return candidates.compactMap { surface -> (ObjectIdentifier, Bool, CGFloat)? in
            guard let window = surface.window, window === front, let id = surface.tabID,
                  !surface.visibleRect.intersection(surface.bounds).isEmpty else { return nil }
            // On recent macOS, visibleRect may extend beyond an unclipped control.
            let visible = surface.visibleRect.intersection(surface.bounds)
            let rect = window.convertToScreen(surface.convert(visible, to: nil))
            guard rect.insetBy(dx: -16, dy: -6).contains(point) else { return nil }
            return (id, point.x > rect.midX, abs(point.x - rect.midX))
        }.min(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }
}
