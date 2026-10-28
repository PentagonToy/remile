import AppKit
import PDFKit
import SwiftUI
import WebKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0
}

// Small document doubles exercise the production window registry without opening user files.
@MainActor final class TabPDFSession { func persistReadingPosition() {} }
@MainActor final class ReadingSession {
    struct Document { enum Content { case pdf, markdown }; var content: Content = .pdf }
    var document = Document()
    var url: URL?
    var pdfSession: TabPDFSession?
}
@MainActor final class HomeModel {
    let reader = ReadingSession()
    func open(_ url: URL, inNewPDFTab: Bool = true) {
        if inNewPDFTab, RemileWindows.shared.openPDFTab(url, from: self) { return }
        reader.url = url
    }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message); print("PASS: \(message)")
}
MainActor.assumeIsolated {
_ = NSApplication.shared
let registry = RemileWindows.shared
var retained: [NSWindow] = []
@MainActor func make(_ name: String) -> (NSWindow, HomeModel) {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; retained.append(window)
    let home = HomeModel(); home.reader.url = URL(fileURLWithPath: "/tmp/\(name).pdf")
    registry.register(home, window: window)
    return (window, home)
}
let (a, ah) = make("a")
var created = 0
registry.createWindow = { created += 1 }
registry.openExternalDocument(URL(fileURLWithPath: "/tmp/b.pdf"))
expect(created == 1, "Finder PDF requests a tab window")
let (b, bh) = make("placeholder")
expect(bh.reader.url?.lastPathComponent == "b.pdf", "Queued Finder URL reaches the new session")
expect(registry.documentTabs(for: bh.reader).count == 2 && !a.isVisible && b.isVisible, "Finder open joins the existing PDF group")
registry.openExternalDocument(URL(fileURLWithPath: "/tmp/b.pdf"))
expect(created == 1, "Duplicate Finder open selects the existing session")
let aid = ObjectIdentifier(a), bid = ObjectIdentifier(b)
registry.moveDocumentTab(bid, to: aid, after: false)
expect(registry.documentTabs(for: bh.reader).map(\.id) == [bid, aid], "Dragging before a tab changes order")
registry.moveDocumentTab(bid, to: aid, after: true)
expect(registry.documentTabs(for: bh.reader).map(\.id) == [aid, bid], "Dragging after a tab changes order")
let drag = PDFTabDragState.shared
expect(!AnimationPolicy.enabled(reduceMotion: true), "Reduced motion disables tab motion")
expect(drag.feedback == nil, "Drag feedback starts idle")
var idleDragUpdates = 0
let dragObserver = drag.objectWillChange.sink { idleDragUpdates += 1 }
drag.finish(); drag.finish()
expect(idleDragUpdates == 0, "Idle drag cleanup does not invalidate tab strips")
dragObserver.cancel()
drag.begin(bid)
expect(drag.feedback?.source == bid, "Starting a drag identifies the lifted tab")
let inactiveDragSurface = PDFTabDragView()
inactiveDragSurface.viewWillMove(toWindow: nil)
expect(drag.feedback?.source == bid, "An unrelated tab surface cannot clear another tab's drag feedback")
drag.hover(aid, after: false)
expect(drag.feedback?.target == aid && drag.feedback?.after == false, "Leading-half hover exposes a before insertion marker")
drag.hover(aid, after: true)
expect(drag.feedback?.after == true, "Trailing-half hover moves the insertion marker")
drag.hover(bid)
expect(drag.feedback?.target == nil, "Hovering the source clears the insertion marker")
drag.hover(nil)
expect(drag.feedback?.target == nil && drag.feedback?.source == bid, "Leaving the strip keeps source feedback without a stale target")
drag.finish()
expect(drag.feedback == nil, "Drop or cancellation clears drag feedback")
let nativeButton = PDFTabDragView(); nativeButton.tabID = aid; nativeButton.performClick(nil)
expect(registry.active === ah && a.isVisible, "Native tab button selects the retained document")
expect(a.animationBehavior == .none && b.animationBehavior == .none, "Tab selection disables native window expansion")
expect((a.tabGroup?.windows.count ?? 1) <= 1 && (b.tabGroup?.windows.count ?? 1) <= 1, "Bottom tabs do not create a native top tab bar")
let oldReader = bh.reader
registry.detachDocumentTab(bid, at: NSPoint(x: 900, y: 700))
expect(registry.documentTabs(for: ah.reader).count == 1 && registry.documentTabs(for: bh.reader).count == 1, "Tear-off splits the group")
expect(a.isVisible && b.isVisible && bh.reader === oldReader, "Tear-off reveals both windows and preserves the session")
registry.moveDocumentTab(bid, to: aid, after: true)
expect(registry.documentTabs(for: ah.reader).count == 2 && !a.isVisible && b.isVisible, "Cross-window drop merges groups and selects the moved PDF")
if CommandLine.arguments.count > 1 {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    for dark in [false, true] {
        for width in [560.0, 1000.0] {
            for state in ["idle", "before", "after"] {
                if state == "idle" { drag.finish() }
                else { drag.begin(bid); drag.hover(aid, after: state == "after") }
                let root = PDFDocumentTabs(reader: bh.reader)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .frame(width: width, height: 40)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 40)
                host.layoutSubtreeIfNeeded()
                func surfaces(_ view: NSView) -> [PDFTabDragView] {
                    (view as? PDFTabDragView).map { [$0] } ?? view.subviews.flatMap { surfaces($0) }
                }
                let hitAreas = surfaces(host)
                precondition(hitAreas.count == 2 && hitAreas.allSatisfy { $0.bounds.width >= 150 && $0.bounds.height >= 28 }, "Every tab label must offer a full-width native drag target")
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "tabs-\(dark ? "dark" : "light")-\(Int(width))-\(state).png"
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            }
        }
    }
    drag.finish()
    print("12 production tab-strip captures created")
}
// Exercise both directions through the actual native pointer handlers.
let strip = NSView(frame: b.contentView!.bounds)
b.contentView = strip
let leftTarget = PDFTabDragView(frame: NSRect(x: 10, y: 10, width: 180, height: 30)); leftTarget.tabID = aid
let dragged = PDFTabDragView(frame: NSRect(x: 230, y: 10, width: 180, height: 30)); dragged.tabID = bid
strip.addSubview(leftTarget); strip.addSubview(dragged)
func pointer(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 25), modifierFlags: [], timestamp: 0, windowNumber: b.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
weak var releasedPreview: NSWindow?
autoreleasepool {
    dragged.mouseDown(with: pointer(.leftMouseDown, 260))
    dragged.mouseDragged(with: pointer(.leftMouseDragged, 30))
    releasedPreview = NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.ignoresMouseEvents }
    dragged.mouseUp(with: pointer(.leftMouseUp, 30))
}
expect(releasedPreview == nil, "A completed drag releases its temporary preview window")
expect(registry.documentTabs(for: bh.reader).map(\.id) == [bid, aid], "Native pointer handlers move B before A")
dragged.frame.origin.x = 10; leftTarget.frame.origin.x = 230
dragged.mouseDown(with: pointer(.leftMouseDown, 30))
dragged.mouseDragged(with: pointer(.leftMouseDragged, 385))
dragged.mouseUp(with: pointer(.leftMouseUp, 385))
expect(registry.documentTabs(for: bh.reader).map(\.id) == [aid, bid], "Native pointer handlers move B after A")
registry.remove(b)
expect(registry.documentTabs(for: ah.reader).count == 1 && a.isVisible, "Closing the selected tab reveals its neighbour")
let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
let document = PDFDocument(); let image = NSImage(size: NSSize(width: 600, height: 900))
image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 900).fill(); image.unlockFocus()
document.insert(PDFPage(image: image)!, at: 0); view.document = document
let zoom = ReaderZoom(); zoom.attach(view)
expect(view.scaleFactor < 1 && view.scaleFactor > 0.1, "Initial zoom fits a tall page inside the viewport")
let fitted = view.scaleFactor
view.scaleFactor = fitted * 0.9
zoom.updateFitForLayout(pageChanged: true, selecting: false)
expect(abs(view.scaleFactor - fitted * 0.9) < 0.001, "Same-size page notifications do not reapply Fit")
zoom.fit(width: false)
expect(abs(view.scaleFactor - fitted) < 0.001, "Explicit Fit still recalculates the scale")
view.setFrameSize(NSSize(width: 900, height: 750))
zoom.updateFitForLayout(pageChanged: true, selecting: true)
expect(abs(view.scaleFactor - fitted) < 0.001, "Selection page changes do not change zoom")
zoom.updateFitForLayout(pageChanged: false, selecting: false)
expect(view.scaleFactor > fitted, "Real viewport resizing still updates Fit")
zoom.change(1.25)
expect(abs(view.scaleFactor - 1.25) < 0.001, "Manual zoom remains available after initial fit")
for window in retained { window.orderOut(nil) }
print("PDF tab and initial fit checks passed")

}
