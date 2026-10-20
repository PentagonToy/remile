import AppKit
import SwiftUI
import PDFKit
import WebKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
var finished = false
let application = NSApplication.shared
var checks = 0
func verify(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
Task { @MainActor in
    let data = NSMutableData()
    var rect = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &rect, nil)!
    context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
    let document = PDFDocument(data: data as Data)!
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
    view.document = document; view.layoutDocumentView()
    let zoom = ReaderZoom(); zoom.attach(view)
    zoom.change(1.5)
    verify(abs(view.scaleFactor - 1.5) < 0.01, "PDF percentage controls native scale")
    zoom.fit(width: false); let pageFit = view.scaleFactor
    zoom.fit(width: true)
    verify(view.scaleFactor > pageFit, "Fit width differs from whole-page fit")
    zoom.change(1)
    verify(abs(view.scaleFactor - 1) < 0.01, "Actual size restores 100 percent")
    view.zoomIn(nil)
    try? await Task.sleep(for: .milliseconds(80))
    verify(abs(zoom.scale - view.scaleFactor) < 0.01, "Native PDF zoom updates visible percentage")
    let textZoom = ReaderZoom(text: true), web = WKWebView()
    textZoom.attach(web); textZoom.change(1.5)
    verify(abs(web.pageZoom - 1.5) < 0.01, "Markdown web preview responds to scale")
    textZoom.fit(width: true)
    verify(textZoom.wide && abs(web.pageZoom - 1) < 0.01, "Markdown fit width resets scale")
    textZoom.change(100)
    verify(textZoom.scale == 5, "Zoom bounded above")
    textZoom.change(0)
    verify(textZoom.scale == 0.25, "Zoom bounded below")

    zoom.change(1.63); zoom.step(1)
    verify(abs(zoom.scale - 1.73) < 0.001, "Visible buttons add ten percentage points")
    zoom.step(-1, fine: true)
    verify(abs(zoom.scale - 1.71) < 0.001, "Keyboard adjustment uses two percentage points")
    let fixture = output.appendingPathComponent("editing-fixture.md")
    try! Data("# Original".utf8).write(to: fixture)
    let reader = ReadingSession()
    try! reader.open(fixture, recordRecent: false)
    verify(reader.url == fixture && !reader.dirty, "Opening uses an in-window session")
    reader.document.content = .markdown("# Edited\n\nLive preview")
    verify(reader.dirty, "Markdown source edits mark document dirty")
    verify(reader.save(), "Native save writes edited Markdown")
    verify((try! String(contentsOf: fixture, encoding: .utf8)) == "# Edited\n\nLive preview" && !reader.dirty, "Saved source survives round trip")
    reader.close()
    verify(reader.url == nil, "Returning Home clears the clean session")

    let firstPDF = output.appendingPathComponent("First.pdf"), secondPDF = output.appendingPathComponent("Second.pdf")
    let word = output.appendingPathComponent("Notes.docx")
    if case .open(let url) = try! HomeFileDrop.plan([firstPDF], target: .open) { verify(url == firstPDF, "Background drop opens a PDF") }
    if case .convert(let urls) = try! HomeFileDrop.plan([fixture, word], target: .convert) { verify(urls == [fixture, word], "Convert card preserves supported inputs") }
    if case .compress(let url) = try! HomeFileDrop.plan([firstPDF], target: .compress) { verify(url == firstPDF, "Compress card receives one PDF") }
    if case .combine(let urls) = try! HomeFileDrop.plan([secondPDF, firstPDF], target: .combine) { verify(urls == [secondPDF, firstPDF], "Combine preserves dropped order") }
    for (urls, target) in [([firstPDF], HomeFileDrop.Target.convert), ([fixture], .compress), ([firstPDF], .combine), ([firstPDF, secondPDF], .open), ([URL(string: "https://example.com/file.pdf")!], .open)] {
        do { _ = try HomeFileDrop.plan(urls, target: target); preconditionFailure("Invalid card input must not fall through to open") }
        catch { verify(error is HomeFileDrop.Failure, "Invalid drop has a clear destination error") }
    }
    let provided: [URL] = await withCheckedContinuation { continuation in
        HomeFileDrop.receive([NSItemProvider(object: secondPDF as NSURL), NSItemProvider(object: firstPDF as NSURL)]) { continuation.resume(returning: $0) }
    }
    verify(provided == [secondPDF, firstPDF], "Native file URL providers preserve drop order")
    let bytesProvider = NSItemProvider()
    bytesProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in completion(Data(fixture.absoluteString.utf8), nil); return nil }
    let decoded: [URL] = await withCheckedContinuation { continuation in HomeFileDrop.receive([bytesProvider]) { continuation.resume(returning: $0) } }
    verify(decoded == [fixture], "Finder-style URL data decodes as a local file")
    let dropped = HomeModel(); dropped.handleDrop([fixture], target: .convert)
    verify(dropped.convertPresented && dropped.conversion.inputs == [fixture] && dropped.reader.url == nil, "Convert drop preloads sheet without opening reader")
    dropped.convertPresented = false; dropped.handleDrop([firstPDF], target: .compress)
    verify(dropped.compressPresented && dropped.compression.input == firstPDF, "Compress drop preloads selected PDF")

    @MainActor func snapshot<V: View>(_ root: V, name: String, size: NSSize, dark: Bool) async {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light).preferredColorScheme(dark ? .dark : .light))
        window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
    for dark in [false, true] {
        UserDefaults.standard.setVolatileDomain([ReaderAppearance.preference: dark ? "Dark" : "Light"], forName: UserDefaults.argumentDomain)
        let theme = dark ? "dark" : "light"
        let home = HomeModel(); home.recent = [fixture]
        await snapshot(HomeWorkspace(model: home, loadOnAppear: false), name: "home-" + theme, size: NSSize(width: 1120, height: 800), dark: dark)
        await snapshot(ConvertWorkspace(), name: "convert-empty-" + theme, size: NSSize(width: 940, height: 600), dark: dark)
        let queued = ConversionModel(); queued.inputs = [URL(fileURLWithPath: "/tmp/Research notes.md"), URL(fileURLWithPath: "/tmp/Diagram.png")]
        await snapshot(ConvertWorkspace(model: queued), name: "convert-queue-" + theme, size: NSSize(width: 940, height: 600), dark: dark)
        let ready = ConversionModel()
        let temp = output.appendingPathComponent("Deerstalker-Convert-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        let pdf = temp.appendingPathComponent("Preview.pdf"); try! (data as Data).write(to: pdf)
        let item = ConversionItem(input: URL(fileURLWithPath: "/tmp/Research notes.md"), kind: "Markdown", output: pdf, message: nil)
        ready.inputs = [item.input]; ready.batch = ConversionBatch(directory: temp, items: [item]); ready.selected = item.id
        await snapshot(ConvertWorkspace(model: ready), name: "convert-ready-" + theme, size: NSSize(width: 940, height: 600), dark: dark)
        await snapshot(HStack { Text("PDF Preview"); Spacer(); ReaderZoomControls(zoom: zoom) }.padding(12), name: "zoom-controls-" + theme, size: NSSize(width: 600, height: 64), dark: dark)
        await snapshot(ReaderSettings(), name: "settings-" + theme, size: NSSize(width: 584, height: 404), dark: dark)
        let md = "# Reading at 150%\n\nA readable paragraph with **emphasis** and inline `code`.\n\n> A quotation stays aligned.\n\n- First point\n- Second point"
        await snapshot(MarkdownWorkspace(source: .constant(md), mode: .split), name: "markdown-split-" + theme, size: NSSize(width: 1000, height: 650), dark: dark)
        await snapshot(MarkdownPreview(source: md, scale: 1.5), name: "markdown-zoom-" + theme, size: NSSize(width: 760, height: 480), dark: dark)
    }
    print("\(checks) native reading checks passed; refined interface states rendered")
    finished = true
}
while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
