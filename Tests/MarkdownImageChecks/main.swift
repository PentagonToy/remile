import AppKit
import WebKit
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}
var checks = 0
func verify(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let repo = URL(fileURLWithPath: CommandLine.arguments[2])
var finished = false
let application = NSApplication.shared
Task { @MainActor in
    let readme = repo.appendingPathComponent("README.md")
    let source = try! String(contentsOf: readme, encoding: .utf8)
    let preview = MarkdownPreviewModel()
    await preview.render(source, url: readme)
    verify(preview.message == nil, "README renders successfully")
    preview.web.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
    preview.display(dark: false, scale: 1, wide: false, serif: false)
    var imagesLoaded = false
    for _ in 0..<100 {
        try? await Task.sleep(for: .milliseconds(50))
        imagesLoaded = (try? await preview.web.evaluateJavaScript("document.images.length===2 && [...document.images].every(i=>i.complete && i.naturalWidth>0)") as? Bool) == true
        if imagesLoaded { break }
    }
    verify(imagesLoaded, "WebKit decodes both actual README SVG banners")
    let light = try! await preview.web.evaluateJavaScript("getComputedStyle(document.querySelector('.picture-light')).display") as! String
    verify(light == "inline", "Light reader displays fallback image")
    preview.display(dark: true, scale: 1, wide: false, serif: false)
    let dark = try! await preview.web.evaluateJavaScript("getComputedStyle(document.querySelector('.picture-dark')).display") as! String
    let hiddenLight = try! await preview.web.evaluateJavaScript("getComputedStyle(document.querySelector('.picture-light')).display") as! String
    verify(dark == "inline" && hiddenLight == "none", "Reader appearance switches image without changing source")
    let quote = try! await preview.web.evaluateJavaScript("document.querySelector('blockquote').textContent") as! String
    verify(quote == "Across time, a few words find you here.", "Slogan is one continuous sentence")
    try! await MarkdownPDF.write(preview.html!, to: output.appendingPathComponent("readme.pdf"))
    let pdf = PDFDocument(url: output.appendingPathComponent("readme.pdf"))!
    verify(pdf.string?.contains("Across time, a few words find you here.") == true, "PDF preserves the slogan")
    let image = pdf.page(at: 0)!.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("readme-page-1.png"))
    print("\(checks) native Markdown image checks passed; README exported to \(pdf.pageCount) PDF pages")
    finished = true
}
while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
