import AppKit
import CoreText
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

Task { @MainActor in
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1; print("PASS:", label) }
    let bytes = NSMutableData(), media = CGRect(x: 0, y: 0, width: 612, height: 792)
    var box = media
    let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
    for index in 1...2 {
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 70, y: 680)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Mapping page \(index)", attributes: [.font: NSFont.systemFont(ofSize: 18)])), context)
        context.endPDFPage()
    }
    context.closePDF()
    let document = PDFDocument(data: bytes as Data)!, navigation = TeXPDFController()
    let view = TeXPreviewPDFView(frame: CGRect(x: 40, y: 40, width: 520, height: 600))
    view.document = document; view.displayMode = .singlePageContinuous; view.autoScales = true; view.navigation = navigation
    navigation.attach(view)
    navigation.show(.init(location: .init(page: 2, x: 70, y: 112)))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView!.addSubview(view); window.orderBack(nil)
    window.contentView!.layoutSubtreeIfNeeded(); view.layoutDocumentView(); view.layout()
    let deadline = Date().addingTimeInterval(5)
    while view.currentPage !== document.page(at: 1), Date() < deadline { await Task.yield(); view.layout() }
    expect(view.currentPage === document.page(at: 1), "A jump requested before attachment is applied after PDF layout")
    let page = document.page(at: 1)!, selected = page.selection(for: NSRange(location: 0, length: 7))!
    view.setCurrentSelection(selected, animate: false); view.go(to: selected.bounds(for: page), on: page); view.layoutDocumentView()
    let bounds = selected.bounds(for: page)
    let point = view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page)
    let location = view.convert(point, to: nil)
    func event(_ point: CGPoint, count: Int = 2, number: Int? = nil, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: number ?? window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
    var jumps = [TeXSync.PDFLocation]()
    navigation.reverse = { jumps.append($0) }
    expect(navigation.handleDoubleClick(event(location)), "A double-click inside the PDF is received without competing with selection")
    expect(jumps.count == 1 && jumps[0].page == 2 && abs(jumps[0].x - bounds.midX) < 1, "Double-clicking selected text uses that selection on its actual page")
    expect(jumps[0].hint?.text.contains("Mapping") == true, "PDF double-click carries a bounded text hint")
    expect(view.currentSelection?.string == "Mapping", "Source navigation preserves the native PDF selection")
    expect(!navigation.handleDoubleClick(event(location, count: 1)), "Single clicks remain native PDF interactions")
    expect(!navigation.handleDoubleClick(event(.zero)), "Clicks outside the PDF do not navigate")
    let other = NSWindow(contentRect: media, styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false; other.orderBack(nil)
    expect(!navigation.handleDoubleClick(event(location, number: other.windowNumber)), "A different window cannot trigger source navigation")
    let previousJumps = jumps.count
    navigation.observeSelectionGesture(event(location))
    expect(jumps.count == previousJumps, "Word selection finishes before source navigation starts")
    navigation.observeSelectionGesture(event(location, type: .leftMouseUp))
    expect(jumps.count == previousJumps + 1, "A completed double-click navigates once")
    navigation.observeSelectionGesture(event(location))
    navigation.observeSelectionGesture(event(location, type: .leftMouseDragged))
    navigation.observeSelectionGesture(event(location, type: .leftMouseUp))
    expect(jumps.count == previousJumps + 1, "Dragging selected words never triggers source navigation")
    navigation.detach()
    expect(!navigation.handleDoubleClick(event(location)), "Dismantling the preview removes its navigation target")
    other.close(); window.close()
    print("Passed \(checks) native TeX PDF navigation checks")
    NSApplication.shared.terminate(nil)
}
NSApplication.shared.run()
