import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
@MainActor final class ZoomWindow: NSWindow {
    var zooms = 0
    override func performZoom(_ sender: Any?) { zooms += 1 }
}
MainActor.assumeIsolated {
    let window = ZoomWindow(contentRect: NSRect(x: 40,y: 40,width: 800,height: 500), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered,defer: false)
    let handler = TitlebarDrag(window: window)
    func event(_ point: NSPoint, count: Int = 2, windowNumber: Int? = nil) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: windowNumber ?? window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
    let blank = NSPoint(x: 400,y: window.contentLayoutRect.maxY + 8)
    precondition(handler.handle(event(blank)) && window.zooms == 1)
    precondition(handler.handle(event(blank)) && window.zooms == 2)
    precondition(!handler.handle(event(NSPoint(x: 400,y: 100))))
    precondition(!handler.handle(event(blank, count: 3)))
    if let close = window.standardWindowButton(.closeButton) {
        let bounds = close.convert(close.bounds, to: nil)
        precondition(!handler.handle(event(NSPoint(x: bounds.midX,y: bounds.midY))))
    }
    window.isMovable = false
    precondition(!handler.handle(event(blank)))
    window.isMovable = true; window.styleMask.remove(.resizable)
    precondition(!handler.handle(event(blank)))
    print("Passed title-bar double-click zoom/restore routing, content/control exclusion, triple-click refusal and fixed-window guards")
}
