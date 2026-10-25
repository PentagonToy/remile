import AppKit
import PDFKit
import SwiftUI

// Swift's interpreter needs the availability helper normally linked by the native app.
@_cdecl("__isPlatformVersionAtLeast")
public func writerHostVersion(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0
}

try MainActor.assumeIsolated {
NSApplication.shared.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var checks = 0
@MainActor func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { guard try condition() else { fatalError(message) }; checks += 1 }
@MainActor func reject(_ action: () throws -> Void) { do { try action(); fatalError("Expected rejection") } catch { checks += 1 } }
let model = WriterModel()
let documentCanvas = WriterCanvas(model: model)
documentCanvas.rebuild()
try check(model.paper == "A4" && !model.landscape, "A4 portrait default")
try check(WriterFont.allCases.count == 4 && WriterFont.sans.family == "Arial", "Bounded font choices")
try check(WriterPalette.okabeIto.colours.count == 8 && WriterPalette.ibm.colours.count == 14 && WriterPalette.bright.colours.count == 7 && WriterPalette.muted.colours.count == 9, "Canonical palette sizes")
try check(WriterPalette.hex(WriterPalette.colour(0x0072B2)) == 0x0072B2, "sRGB palette roundtrip")
let body = "Dear Editor,\n\nPlease consider our manuscript.\n\nWith kind regards,\nThe authors"
model.replaceBody(NSAttributedString(string: body, attributes: model.attributes))
try check(documentCanvas.ranges().count == 1, "Short letter fits one page")
let view = documentCanvas.sheets[0].text
model.activeText = view; view.setSelectedRange(NSRange(location: 0, length: 4))
model.font = .georgia; model.size = 14; model.colour = 0x0072B2; model.alignment = NSTextAlignment.center.rawValue
if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }; model.undo.beginUndoGrouping(); model.format(); model.undo.endUndoGrouping()
try check((model.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Georgia", "Font applies to selection")
try check((model.storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.familyName == "Times New Roman", "Font leaves unselected text intact")
try check((model.storage.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center, "Alignment applies to whole paragraph")
model.undo.undo()
try check((model.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Times New Roman", "Formatting Undo")
model.undo.redo()
try check((model.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Georgia", "Formatting Redo")
if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }; model.undo.beginUndoGrouping(); model.add(.line); model.undo.endUndoGrouping()
var line = model.selectedObject!; line.startArrow = .open; line.endArrow = .filled; line.end = CGPoint(x: 400, y: 130); model.update(line)
try check(model.objects[0].startArrow == .open && model.objects[0].endArrow == .filled, "Independent arrow ends")
model.add(.rectangle)
var rectangle = model.selectedObject!; rectangle.text = "A short note"; rectangle.start.y = 310; rectangle.end.y = 390; rectangle.font = "Georgia"; model.update(rectangle)
try check(model.objects.count == 2 && model.objects[1].text == "A short note", "Rectangle stores editable text")
model.add(.table)
var table = model.selectedObject!; table.start = CGPoint(x: 90, y: 450); table.end = CGPoint(x: 430, y: 570); table.cells[0] = "Method"; table.cells[1] = "Value"; table.width = 2.5; model.update(table)
model.resizeTable(rows: 4, columns: 2)
try check(model.selectedObject?.cells[0] == "Method" && model.selectedObject?.cells[1] == "Value" && model.selectedObject?.cells.count == 8, "Table resize preserves cells")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let pixel = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 1)
for x in 0..<400 { for y in 0..<200 { bitmap.setColor(pixel, atX: x, y: y) } }
let imageBytes = bitmap.representation(using: .png, properties: [:])!, textBeforeImage = model.storage.string
try model.addImage(imageBytes)
try check(model.objects.last?.kind == .image && model.storage.string == textBeforeImage, "Photos are independent of body flow")
var photo = model.objects.last!; photo.start.x += 25; photo.end.x += 25; model.update(photo)
try check(model.storage.string == textBeforeImage, "Moving a photo never edits text")
try check(WriterImage.valid(photo.imageData!), "Imported photos are bounded PNG pixels")
let old = model.objects[0].start
if model.undo.groupingLevel > 0 { model.undo.endUndoGrouping() }; model.undo.beginUndoGrouping(); model.resizePaper("A3", landscape: true); model.undo.endUndoGrouping()
try check(model.pageSize.width > model.pageSize.height && model.objects[0].start != old, "Paper resize keeps relative shape positions")
model.undo.undo(); try check(model.paper == "A4" && !model.landscape && abs(model.objects[0].start.x - old.x) < 0.001, "Paper size Undo restores object positions")
documentCanvas.paginate()
let docx = try WriterArchive.encode(model), target = output.appendingPathComponent("letter.docx")
try docx.write(to: target)
let archive = try WordArchive(docx), xml = String(decoding: try archive.read("word/document.xml"), as: UTF8.self)
try check(xml.contains("startarrow=\"open\"") && xml.contains("endarrow=\"block\""), "DOCX preserves independent arrowheads")
try check(xml.contains("A short note") && xml.contains("v:rect") && xml.contains("w:pgSz"), "DOCX contains text box and page size")
try check(xml.contains("<w:tbl>") && xml.contains("w:sz=\"20\"") && xml.contains("v:imagedata"), "DOCX includes table borders and floating photo")
let restored = WriterModel(); try WriterArchive.open(target, model: restored)
try check(restored.storage.string == model.storage.string, "DOCX body roundtrip")
try check(restored.objects == model.objects && restored.paper == model.paper, "DOCX shape and paper roundtrip")
try check((restored.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Georgia", "DOCX preserves source formatting")
let altered = archive.replacing("word/document.xml", with: Data(xml.replacingOccurrences(of: "Dear", with: "Hello").utf8)), alteredURL = output.appendingPathComponent("external-edit.docx")
try altered.write(to: alteredURL); reject { try WriterArchive.open(alteredURL, model: restored) }
let pdf = try documentCanvas.pdf(); try pdf.write(to: output.appendingPathComponent("letter.pdf"))
try check(PDFDocument(data: pdf)?.pageCount == 1, "PDF page count")
try check(PDFDocument(data: pdf)?.string?.contains("Dear") == true, "PDF keeps searchable body text")
let previewModel = WriterModel(); try WriterArchive.open(target, model: previewModel)
let preview = NSHostingView(rootView: WriterWorkspace(model: previewModel, goHome: {}).environment(\.colorScheme, .dark))
let previewWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
previewWindow.isReleasedWhenClosed = false; previewWindow.appearance = NSAppearance(named: .darkAqua); previewWindow.contentView = preview
preview.frame = CGRect(x: 0, y: 0, width: 1120, height: 850); preview.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
if let surface = previewModel.canvas, let scroll = surface.enclosingScrollView { try check(surface.frame.width <= max(scroll.contentSize.width, previewModel.pageSize.width + 64) + 1, "Canvas centres within available document area") }
if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
    preview.cacheDisplay(in: preview.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("writer-preview.png"))
}
let cleanRevision = previewModel.revision, documentGeometry = previewModel.objects
previewModel.showRulers = true; previewModel.setZoom(1.25)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
try check(abs((previewModel.canvas?.enclosingScrollView?.magnification ?? 0) - 1.25) < 0.001, "Zoom changes the native viewport")
try check(previewModel.objects == documentGeometry && previewModel.revision == cleanRevision, "Rulers and zoom never edit document geometry")
if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
    preview.cacheDisplay(in: preview.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("writer-rulers.png"))
}
previewModel.fitWidth()
try check(previewModel.zoom >= 0.25 && previewModel.zoom <= 2, "Fit uses current viewport bounds")
let viewResult = WriterCommands.handle(EditorBridge.Request(operation: "writer-view", zoom: 0.75, rulers: false), model: previewModel)
try check(viewResult["ok"] as? Bool == true && previewModel.zoom == 0.75 && !previewModel.showRulers, "CLI view controls share native state")
let badZoom = WriterCommands.handle(EditorBridge.Request(operation: "writer-view", zoom: .nan), model: previewModel)
try check(badZoom["ok"] as? Bool == false && previewModel.zoom == 0.75, "CLI rejects invalid zoom")
previewModel.setZoom(1); previewModel.showRulers = false
preview.rootView = WriterWorkspace(model: previewModel, goHome: {}).environment(\.colorScheme, .light)
previewWindow.appearance = NSAppearance(named: .aqua)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
    preview.cacheDisplay(in: preview.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("writer-light.png"))
}
let formulaPreview = NSHostingView(rootView: WriterLaTeXSheet(source: .constant(#"\frac{a+b}{c}"#), cancel: {}, insert: { _ in }).environment(\.colorScheme, .dark))
let formulaWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
formulaWindow.isReleasedWhenClosed = false; formulaWindow.appearance = NSAppearance(named: .darkAqua); formulaWindow.contentView = formulaPreview
formulaPreview.frame = CGRect(x: 0, y: 0, width: 440, height: 250); formulaPreview.layoutSubtreeIfNeeded()
if let bitmap = formulaPreview.bitmapImageRepForCachingDisplay(in: formulaPreview.bounds) {
    formulaPreview.cacheDisplay(in: formulaPreview.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("latex-sheet.png"))
}
formulaWindow.contentView = nil; formulaWindow.close()
previewWindow.contentView = nil; previewWindow.close()
let long = String(repeating: "A paragraph for pagination.\n", count: 180)
model.replaceBody(NSAttributedString(string: long, attributes: model.attributes)); documentCanvas.paginate()
let ranges = documentCanvas.ranges()
try check(ranges.count > 1 && ranges.reduce(0, { $0 + $1.length }) == model.storage.length, "Multiple text containers cover entire body")
let multiple = try documentCanvas.pdf(); try multiple.write(to: output.appendingPathComponent("pages.pdf"))
try check(PDFDocument(data: multiple)?.pageCount == ranges.count, "PDF exports every laid-out page")
let sourceHash = SourceDigest.sha256(model.storage.string + model.revision.uuidString)
let read = WriterCommands.handle(EditorBridge.Request(operation: "read"), model: model)
try check(read["sha256"] as? String == sourceHash && read["source"] as? String == long, "CLI shares live document")
let stale = WriterCommands.handle(EditorBridge.Request(operation: "replace", source: "stale", expectedSHA256: String(repeating: "0", count: 64)), model: model)
try check(stale["ok"] as? Bool == false && model.storage.string == long, "CLI rejects stale writes")
let replacement = WriterCommands.handle(EditorBridge.Request(operation: "replace", source: "A replacement letter", expectedSHA256: sourceHash), model: model)
try check(replacement["ok"] as? Bool == true && model.storage.string == "A replacement letter", "CLI replacement uses shared model")
let bodyBefore = model.storage.string
model.choose(nil); model.activeText = documentCanvas.sheets[0].text; model.activeText?.setSelectedRange(NSRange(location: 0, length: 0)); model.bullet()
try check(model.storage.string.hasPrefix("•\t"), "Bullet toggle inserts marker")
model.activeText?.setSelectedRange(NSRange(location: 0, length: 0)); model.bullet()
try check(model.storage.string == bodyBefore, "Bullet toggle removes marker")
let typedBefore = model.storage.string
model.activeText?.insertText("!", replacementRange: NSRange(location: model.storage.length, length: 0))
try check(model.storage.string == typedBefore + "!", "Native text insertion")
model.undo.undo(); try check(model.storage.string == typedBefore, "Native text shares Undo history")
model.undo.redo(); try check(model.storage.string == typedBefore + "!", "Native text Redo")
model.choose(nil); model.activeText = documentCanvas.sheets[0].text; model.activeText?.setSelectedRange(NSRange(location: model.storage.length, length: 0))
var finished = false
Task { @MainActor in
    await model.insertFormula(#"\frac{a+b}{c}=\sqrt{x}"#)
    finished = true
}
let deadline = Date().addingTimeInterval(30)
while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
try check(finished && model.error == nil, "Local formula renderer finishes")
try check(model.storage.attribute(.attachment, at: model.storage.length - 1, effectiveRange: nil) is NSTextAttachment, "Equation is a native attachment")
let equationURL = output.appendingPathComponent("equation.docx"); try WriterArchive.encode(model).write(to: equationURL)
let equation = WriterModel(); try WriterArchive.open(equationURL, model: equation)
try check(equation.storage.attribute(.init("remile.formula"), at: equation.storage.length - 1, effectiveRange: nil) as? String == #"\frac{a+b}{c}=\sqrt{x}"#, "Equation source survives roundtrip")
try documentCanvas.pdf().write(to: output.appendingPathComponent("equation.pdf"))
documentCanvas.suspend(); try check(model.layout.textContainers.isEmpty && model.canvas == nil && model.activeText == nil, "Leaving workspace releases canvas/layout views")
let listModel = WriterModel()
let listSurface = WriterCanvas(model: listModel); listSurface.rebuild()
let listText = listSurface.sheets[0].text
listModel.activeText = listText
listModel.replaceBody(NSAttributedString(string: "First\nSecond\nThird", attributes: listModel.attributes))
listText.setSelectedRange(NSRange(location: 0, length: listModel.storage.length))
listModel.bold = true; listModel.italic = true; listModel.format()
let emphasised = listModel.storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
try check(NSFontManager.shared.traits(of: emphasised).contains([.boldFontMask, .italicFontMask]), "Bold and italic combine")
listText.setSelectedRange(NSRange(location: 0, length: listModel.storage.length)); listModel.applyList(.numbers)
try check(listModel.storage.string == "1.\tFirst\n2.\tSecond\n3.\tThird", "Numbers span selected paragraphs")
listModel.applyList(.letters)
try check(listModel.storage.string == "a.\tFirst\nb.\tSecond\nc.\tThird", "Alphabet replaces number markers")
listModel.applyList(.roman)
try check(listModel.storage.string == "i.\tFirst\nii.\tSecond\niii.\tThird", "Roman replaces alphabet markers")
let listFont = listModel.storage.attribute(.font, at: 3, effectiveRange: nil) as! NSFont
try check(NSFontManager.shared.traits(of: listFont).contains([.boldFontMask, .italicFontMask]), "Changing lists preserves emphasis")
listModel.undo.undo()
try check(listModel.storage.string.hasPrefix("a.\t"), "List change Undo")
listModel.undo.redo()
try check(listModel.storage.string.hasPrefix("i.\t"), "List change Redo")
listText.setSelectedRange(NSRange(location: 0, length: listModel.storage.length)); listModel.applyList(.none)
try check(listModel.storage.string == "First\nSecond\nThird", "None removes only list markers")
listText.setSelectedRange(NSRange(location: 0, length: listModel.storage.length)); listModel.applyList(.numbers)
listText.setSelectedRange(NSRange(location: listModel.storage.length, length: 0)); listText.insertNewline(nil)
try check(listModel.storage.string.hasSuffix("\n4.\t"), "Enter continues numbered list")
listText.insertNewline(nil)
try check(listModel.storage.string.hasSuffix("\n") && listModel.list == .none, "Enter on empty item leaves list")
listModel.add(.rectangle); listModel.bold = true; listModel.italic = true; listModel.format()
try check(NSFontManager.shared.traits(of: listModel.selectedObject!.textFont).contains([.boldFontMask, .italicFontMask]), "Text boxes share emphasis controls")
let listDocument = try WriterArchive.encode(listModel), listArchive = try WordArchive(listDocument)
let listXML = String(decoding: try listArchive.read("word/document.xml"), as: UTF8.self)
try check(listXML.contains("<w:b/>") && listXML.contains("<w:i/>"), "DOCX writes emphasis")
let listURL = output.appendingPathComponent("emphasis.docx"); try listDocument.write(to: listURL)
let listRestored = WriterModel(); try WriterArchive.open(listURL, model: listRestored)
try check(listRestored.objects.first?.bold == true && listRestored.objects.first?.italic == true, "Text box emphasis roundtrip")
listSurface.suspend()
let layoutModel = WriterModel()
let wrappingCanvas = WriterCanvas(model: layoutModel); wrappingCanvas.rebuild()
layoutModel.replaceBody(NSAttributedString(string: String(repeating: "A clear paragraph keeps its words outside the figure. ", count: 70), attributes: layoutModel.attributes))
layoutModel.add(.rectangle)
var obstacle = layoutModel.selectedObject!
obstacle.start = CGPoint(x: 100, y: 130); obstacle.end = CGPoint(x: 400, y: 230)
obstacle.wrapsText = true; obstacle.locked = true; obstacle.filled = true; obstacle.fillHex = 0x56B4E9; obstacle.fillOpacity = 0.65
layoutModel.update(obstacle); wrappingCanvas.paginate()
try check(wrappingCanvas.sheets[0].text.textContainer?.exclusionPaths.count == 1, "Text wrap creates a bounded exclusion path")
let area = obstacle.bounds.insetBy(dx: -7, dy: -7).offsetBy(dx: -56, dy: -56)
var intrudes = false
if let container = wrappingCanvas.sheets[0].text.textContainer {
    layoutModel.layout.enumerateLineFragments(forGlyphRange: layoutModel.layout.glyphRange(for: container)) { _, used, _, _, _ in
        if used.width > 0 && used.height > 0 && used.intersects(area) { intrudes = true }
    }
}
try check(!intrudes, "Laid-out body text avoids wrapped shapes")
var decoration = WriterPageStyle(); decoration.header = "A short document"; decoration.footer = "Draft"; decoration.topLine = true; decoration.bottomLine = true; decoration.pageNumbers = true
layoutModel.setPageStyle(decoration)
try check(layoutModel.pageStyle == decoration, "Page furniture applies")
layoutModel.undo.undo(); try check(layoutModel.pageStyle == WriterPageStyle(), "Page furniture Undo")
layoutModel.undo.redo(); try check(layoutModel.pageStyle == decoration, "Page furniture Redo")
let decoratedDOCX = try WriterArchive.encode(layoutModel), decoratedURL = output.appendingPathComponent("layout.docx")
try decoratedDOCX.write(to: decoratedURL)
let decoratedArchive = try WordArchive(decoratedDOCX), decoratedXML = String(decoding: try decoratedArchive.read("word/document.xml"), as: UTF8.self)
try check(decoratedXML.contains("w:headerReference") && decoratedXML.contains("w:footerReference") && decoratedXML.contains("w10:wrap") && decoratedXML.contains("65%"), "DOCX writes furniture, wrapping and fill")
try check(String(decoding: try decoratedArchive.read("word/footer1.xml"), as: UTF8.self).contains("PAGE"), "DOCX uses a real page field")
let layoutRestored = WriterModel(); try WriterArchive.open(decoratedURL, model: layoutRestored)
try check(layoutRestored.pageStyle == decoration && layoutRestored.objects[0].locked == true && layoutRestored.objects[0].wrapsText == true, "Page and object layout roundtrip")
let decoratedPDF = try wrappingCanvas.pdf(); try decoratedPDF.write(to: output.appendingPathComponent("layout.pdf"))
try check(PDFDocument(data: decoratedPDF)?.string?.contains("A short document") == true, "PDF includes searchable header text")
let alignment = WriterAlignment.snap(CGRect(x: 202, y: 200, width: 190, height: 80), page: CGSize(width: 600, height: 800), neighbours: [], baselines: [202], tolerance: 5)
try check(alignment.0 == CGPoint(x: 3, y: 2) && alignment.1.count == 2, "Guides align page centre and text rows")
try check(WriterAlignment.constrained(CGPoint(x: 120, y: 31), from: CGPoint(x: 10, y: 10)) == CGPoint(x: 120, y: 10), "Shift constrains a horizontal line")
try check(WriterAlignment.constrained(CGPoint(x: 12, y: 130), from: CGPoint(x: 10, y: 10)) == CGPoint(x: 10, y: 130), "Shift constrains a vertical line")
let objectRead = WriterCommands.handle(EditorBridge.Request(operation: "read"), model: layoutModel), objectHash = objectRead["sha256"] as! String
let objectChange = WriterCommands.handle(EditorBridge.Request(operation: "writer-object", expectedSHA256: objectHash, object: obstacle.id, wrap: false, locked: false), model: layoutModel)
try check(objectChange["ok"] as? Bool == true && layoutModel.objects[0].wrapsText == false, "CLI updates wrap and lock with the current revision")
let outdated = WriterCommands.handle(EditorBridge.Request(operation: "writer-page", expectedSHA256: objectHash, header: "Old edit"), model: layoutModel)
try check(outdated["ok"] as? Bool == false && layoutModel.pageStyle.header == "A short document", "CLI rejects stale page edits")
let currentHash = objectChange["sha256"] as! String
let headerChange = WriterCommands.handle(EditorBridge.Request(operation: "writer-page", expectedSHA256: currentHash, header: "New header"), model: layoutModel)
try check(headerChange["ok"] as? Bool == true && layoutModel.pageStyle.header == "New header", "CLI page edit shares the native model")
let nativeListModel = WriterModel()
let nativeListSurface = WriterCanvas(model: nativeListModel); nativeListSurface.rebuild(); let nativeListView = nativeListSurface.sheets[0].text; nativeListModel.activeText = nativeListView
for choice in [WriterList.dash, .circle, .square, .upperLetters, .upperRoman] {
    nativeListModel.replaceBody(NSAttributedString(string: "One\nTwo", attributes: nativeListModel.attributes))
    nativeListView.setSelectedRange(NSRange(location: 0, length: nativeListModel.storage.length)); nativeListModel.applyList(choice)
    try check(nativeListModel.storage.string.hasPrefix(WriterList.marker(NSTextList(markerFormat: choice.format!, options: 0), number: 1)), "Additional list marker \(choice)")
    nativeListModel.applyList(.none)
    try check(nativeListModel.storage.string == "One\nTwo", "Additional list style removes cleanly")
}
try check(!nativeListModel.confirmLeaving(decision: { .alertSecondButtonReturn }), "Cancel keeps an edited Writer document open")
try check(nativeListModel.confirmLeaving(decision: { .alertThirdButtonReturn }), "Discard permits leaving")
var visited: URL?; nativeListModel.didVisit = { visited = $0 }
let recentURL = output.appendingPathComponent("saved-letter.docx")
try check(nativeListModel.save(to: recentURL) && visited == recentURL, "Save reports the destination for recent documents")
var askedToSaveClean = false
try check(nativeListModel.confirmLeaving(decision: { askedToSaveClean = true; return .alertSecondButtonReturn }) && !askedToSaveClean, "Clean documents leave without prompting")
nativeListModel.replaceBody(NSAttributedString(string: "Revised letter", attributes: nativeListModel.attributes))
try check(nativeListModel.confirmLeaving(decision: { .alertFirstButtonReturn }), "Save-and-leave writes the chosen destination")
nativeListSurface.suspend(); wrappingCanvas.suspend()
let importModel = WriterModel()
var importFinished = false, importPassed = false
Task { @MainActor in
    importPassed = await importModel.openFile(target)
    importFinished = true
}
while !importFinished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
try check(importPassed && importModel.objects == restored.objects && !importModel.dirty && importModel.url == target, "Async open preserves native Writer editing state")
let plainURL = try writerImportFixture(output, name: "foreign-text", body: "<w:p><w:r><w:t>A foreign letter</w:t></w:r></w:p>")
importFinished = false
Task { @MainActor in importPassed = await importModel.openFile(plainURL); importFinished = true }
while !importFinished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
try check(importPassed && importModel.storage.string.contains("A foreign letter") && !importModel.dirty && importModel.url == plainURL, "Foreign text keeps its original path without a false edit")
let originalForeign = try Data(contentsOf: plainURL)
try check(importModel.confirmLeaving(decision: { preconditionFailure("Unchanged Word files must close quietly") }), "Unchanged foreign Word file needs no save confirmation")
try check(importModel.save() && (try Data(contentsOf: plainURL)) == originalForeign, "Saving an unchanged Word file does not rewrite its bytes")
let revisedForeign = NSMutableAttributedString(attributedString: importModel.storage)
let foreignRange = (revisedForeign.string as NSString).range(of: "foreign")
revisedForeign.replaceCharacters(in: foreignRange, with: "revised")
importModel.replaceBody(revisedForeign)
try check(importModel.save() && !importModel.dirty && importModel.url == plainURL, "Supported foreign text edits save to the original file")
let revisedArchive = try WordArchive(Data(contentsOf: plainURL)), originalArchive = try WordArchive(originalForeign)
try check(String(decoding: try revisedArchive.read("word/document.xml"), as: UTF8.self).contains("A revised letter"), "Word receives the edited body text")
for part in originalArchive.entries where part.name != "word/document.xml" {
    try check(try originalArchive.read(part.name) == revisedArchive.read(part.name), "In-place Word saving preserves package part " + part.name)
}
let beforeUnsupportedSave = try Data(contentsOf: plainURL)
let styledForeign = NSMutableAttributedString(attributedString: importModel.storage)
styledForeign.addAttribute(.font, value: NSFont.systemFont(ofSize: 19), range: NSRange(location: 0, length: 1))
importModel.replaceBody(styledForeign)
try check(!importModel.save(to: plainURL) && (try Data(contentsOf: plainURL)) == beforeUnsupportedSave, "A rich Word edit cannot flatten the original file")
let foreignCopyCanvas = WriterCanvas(model: importModel)
foreignCopyCanvas.rebuild()
let foreignCopy = output.appendingPathComponent("foreign-copy.docx")
try check(importModel.save(to: foreignCopy) && importModel.url == foreignCopy, "A rich edit can become a new editable Writer DOCX")
try check(try Data(contentsOf: plainURL) == beforeUnsupportedSave, "Saving a Writer copy keeps the source Word file")
let changedOutside = (try Data(contentsOf: foreignCopy)) + Data("external edit".utf8)
try changedOutside.write(to: foreignCopy)
importModel.changed()
try check(!importModel.save(to: foreignCopy) && (try Data(contentsOf: foreignCopy)) == changedOutside, "An externally changed Word file is never overwritten")
try check(!importModel.save(to: output.appendingPathComponent("wrong-working-file.pdf")) && importModel.url == foreignCopy, "A PDF export cannot become the editable working file")
let inlineShape = "<w:p><w:r><w:t>Before shape</w:t></w:r><w:r><w:drawing><wp:inline><wp:extent cx=\"1270000\" cy=\"635000\"/><a:spPr><a:prstGeom prst=\"ellipse\"/><a:solidFill><a:srgbClr val=\"56B4E9\"/></a:solidFill></a:spPr></wp:inline></w:drawing></w:r></w:p>"
let shapeURL = try writerImportFixture(output, name: "foreign-shape", body: inlineShape)
let shapeModel = WriterModel()
importFinished = false
Task { @MainActor in importPassed = await shapeModel.openFile(shapeURL); importFinished = true }
let shapeDeadline = Date().addingTimeInterval(30)
while !importFinished && Date() < shapeDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
var shapeImages = 0
shapeModel.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: shapeModel.storage.length)) { value, _, _ in if (value as? NSTextAttachment)?.image != nil { shapeImages += 1 } }
try check(importFinished && importPassed && shapeImages == 1 && shapeModel.storage.string.contains("Before shape"), "Supported foreign shape becomes a local inline image")
let shapeCanvas = WriterCanvas(model: shapeModel); shapeCanvas.rebuild()
try shapeCanvas.pdf().write(to: output.appendingPathComponent("imported-shape.pdf"))
let copiedShapeURL = output.appendingPathComponent("imported-shape.docx"); try WriterArchive.encode(shapeModel).write(to: copiedShapeURL)
let copiedShape = WriterModel(); try WriterArchive.open(copiedShapeURL, model: copiedShape)
try check(copiedShape.storage.string == shapeModel.storage.string, "Foreign fallback image survives Writer save and reopen")
let unsupportedURL = try writerImportFixture(output, name: "foreign-table", body: "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Keep this table</w:t></w:r></w:p></w:tc></w:tr></w:tbl>")
let guardedModel = WriterModel()
let guardedSurface = WriterCanvas(model: guardedModel); guardedSurface.rebuild()
guardedModel.replaceBody(NSAttributedString(string: "Keep this current document", attributes: guardedModel.attributes))
try check(guardedModel.save(to: output.appendingPathComponent("untouched.docx")), "Import guard fixture is saved")
let beforeFailedOpen = guardedModel.storage.string, beforeFailedURL = guardedModel.url
importFinished = false
Task { @MainActor in importPassed = await guardedModel.openFile(unsupportedURL); importFinished = true }
while !importFinished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
try check(!importPassed && guardedModel.storage.string == beforeFailedOpen && guardedModel.url == beforeFailedURL, "Unsupported foreign layout leaves the current document untouched")
try check(!guardedModel.loading, "Import failure releases the busy state")
shapeCanvas.suspend(); guardedSurface.suspend()
let columnModel = WriterModel()
// Both columns share one text store and one layout manager.
let columns = WriterCanvas(model: columnModel); columns.rebuild()
columnModel.replaceBody(NSAttributedString(string: String(repeating: "A continuous paragraph flows through both columns. ", count: 250), attributes: columnModel.attributes))
let continuousBody = columnModel.storage.string
var twoColumnStyle = WriterPageStyle(); twoColumnStyle.columns = 2; twoColumnStyle.header = "Two-column document"; twoColumnStyle.pageNumbers = true
columnModel.setPageStyle(twoColumnStyle)
try check(columns.sheets.allSatisfy { $0.texts.count == 2 } && columnModel.layout.textContainers.count == columns.sheets.count * 2, "Two columns use sequential native text containers")
let columnRanges = columns.sheets.flatMap(\.texts).compactMap(\.textContainer).map { columnModel.layout.characterRange(forGlyphRange: columnModel.layout.glyphRange(for: $0), actualGlyphRange: nil) }
try check(columnRanges.first!.length > 0 && columnRanges[1].length > 0 && zip(columnRanges, columnRanges.dropFirst()).allSatisfy { NSMaxRange($0.0) == $0.1.location }, "Text flows left to right and then onto the next page without gaps")
try check(columns.ranges().map { (columnModel.storage.string as NSString).substring(with: $0) }.joined() == continuousBody, "Page ranges include both columns without losing text")
try columns.pdf().write(to: output.appendingPathComponent("two-columns.pdf"))
let columnURL = output.appendingPathComponent("two-columns.docx"); try WriterArchive.encode(columnModel).write(to: columnURL)
let columnXML = String(decoding: try WordArchive(Data(contentsOf: columnURL)).read("word/document.xml"), as: UTF8.self)
try check(columnXML.contains("<w:cols w:num=\"2\" w:space=\"400\"/>"), "DOCX writes two-column page settings")
let reopenedColumns = WriterModel(); try WriterArchive.open(columnURL, model: reopenedColumns)
try check(reopenedColumns.pageStyle.columnCount == 2 && reopenedColumns.storage.string == continuousBody, "Column setting and full text survive reopening")
columnModel.undo.undo(); try check(columns.sheets.allSatisfy { $0.texts.count == 1 } && columnModel.storage.string == continuousBody, "Column Undo returns to one column without changing text")
columnModel.undo.redo(); try check(columns.sheets.allSatisfy { $0.texts.count == 2 }, "Column Redo restores two columns")
let columnHash = WriterCommands.handle(EditorBridge.Request(operation: "read"), model: columnModel)["sha256"] as! String
try check(WriterCommands.handle(EditorBridge.Request(operation: "writer-page", expectedSHA256: columnHash, columns: 1), model: columnModel)["ok"] as? Bool == true && columns.sheets.allSatisfy { $0.texts.count == 1 }, "CLI changes columns through native page state")
try check(WriterCommands.handle(EditorBridge.Request(operation: "writer-page", expectedSHA256: columnHash, columns: 3), model: columnModel)["ok"] as? Bool == false, "CLI rejects invalid column settings")
columnModel.setPageStyle(twoColumnStyle); columnModel.add(.rectangle)
var columnObstacle = columnModel.selectedObject!; columnObstacle.start = CGPoint(x: 150, y: 150); columnObstacle.end = CGPoint(x: 430, y: 250); columnObstacle.wrapsText = true; columnObstacle.filled = true; columnModel.update(columnObstacle)
columns.paginate()
var columnIntrusion = false
for text in columns.sheets[0].texts {
    let area = columnObstacle.bounds.insetBy(dx: -7, dy: -7).offsetBy(dx: -text.frame.minX, dy: -text.frame.minY)
    columnModel.layout.enumerateLineFragments(forGlyphRange: columnModel.layout.glyphRange(for: text.textContainer!)) { _, used, _, _, _ in
        if !used.isEmpty && used.intersects(area) { columnIntrusion = true }
    }
}
try check(!columnIntrusion, "Both columns avoid a wrapped object that crosses the gutter")
try columns.pdf().write(to: output.appendingPathComponent("two-columns-wrapped.pdf"))
let inlineModel = WriterModel()
let inlineCanvas = WriterCanvas(model: inlineModel); inlineCanvas.rebuild()
let wideImage = NSImage(data: imageBytes)!; wideImage.size = CGSize(width: 400, height: 200)
let wideAttachment = NSTextAttachment(); wideAttachment.image = wideImage; wideAttachment.bounds = CGRect(origin: .zero, size: wideImage.size)
inlineModel.replaceBody(NSAttributedString(attachment: wideAttachment)); inlineModel.setPageStyle(twoColumnStyle)
let fittedImage = inlineModel.storage.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
try check(fittedImage.bounds.width <= inlineCanvas.sheets[0].text.bounds.width && fittedImage.bounds.height == fittedImage.bounds.width / 2, "Inline images fit the column and retain their aspect ratio")
inlineModel.undo.undo()
let recoveredImage = inlineModel.storage.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
try check(recoveredImage.bounds.width == 400, "Column Undo restores the inline image size")
inlineCanvas.suspend()
columns.suspend()
let splitProbe = SearchSplitProbe(), splitDocument = PDFDocument(data: pdf)!
let splitHost = NSHostingView(rootView: SearchSplitFixture(probe: splitProbe, document: splitDocument))
let splitWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
splitWindow.isReleasedWhenClosed = false; splitWindow.contentView = splitHost
splitHost.frame = CGRect(x: 0, y: 0, width: 1000, height: 700); splitHost.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
let originalPDFView = splitProbe.view
try check(splitProbe.created == 1 && originalPDFView?.document === splitDocument, "Search preview mounts a single PDF view")
for presented in [true, false, true, false] {
    splitProbe.ask = presented
    RunLoop.current.run(until: Date().addingTimeInterval(0.15)); splitHost.layoutSubtreeIfNeeded()
    try check(splitProbe.created == 1 && splitProbe.removed == 0 && splitProbe.view === originalPDFView && splitProbe.view?.document === splitDocument, "Ask toggle preserves the PDF view and its document")
}
splitProbe.ask = true
splitWindow.setContentSize(CGSize(width: 560, height: 700)); splitHost.frame.size = CGSize(width: 560, height: 700)
RunLoop.current.run(until: Date().addingTimeInterval(0.2)); splitHost.layoutSubtreeIfNeeded()
try check((splitProbe.view?.bounds.width ?? 0) >= 280 && (splitProbe.view?.bounds.height ?? 0) >= 600, "Narrow Ask layout keeps a full-height PDF visible")
if let bitmap = splitHost.bitmapImageRepForCachingDisplay(in: splitHost.bounds) {
    splitHost.cacheDisplay(in: splitHost.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("search-ask-narrow.png"))
}
splitWindow.contentView = nil; splitWindow.close()
let savePanel = NSHostingView(rootView: ReferenceSavePanel(filename: "A short research article.pdf", libraries: [.primary], library: .constant(ReferenceLibrary.primaryID), busy: false, message: nil, cancel: {}, save: {}).environment(\.colorScheme, .dark))
let saveWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 404, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
saveWindow.isReleasedWhenClosed = false; saveWindow.appearance = NSAppearance(named: .darkAqua); saveWindow.contentView = savePanel
savePanel.frame = CGRect(x: 0, y: 0, width: 404, height: 240); savePanel.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
if let bitmap = savePanel.bitmapImageRepForCachingDisplay(in: savePanel.bounds) {
    savePanel.cacheDisplay(in: savePanel.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("reference-save-panel.png"))
}
saveWindow.contentView = nil; saveWindow.close()
let geometryModel = WriterModel()
let geometryDesk = WriterDesk(model: geometryModel)
let geometryWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1500, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
geometryWindow.isReleasedWhenClosed = false; geometryWindow.contentView = geometryDesk
for width in [CGFloat(1500), 900, 1800] {
    geometryWindow.setContentSize(CGSize(width: width, height: 950)); geometryDesk.frame.size = CGSize(width: width, height: 950)
    for zoom in [1.0, 1.25, 2.0] {
        geometryModel.setZoom(zoom); geometryDesk.update(); geometryDesk.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let page = geometryModel.canvas!.sheets[0]
        let pageRect = geometryDesk.convert(page.bounds, from: page)
        let viewport = geometryDesk.convert(geometryDesk.scroll.contentView.bounds, from: geometryDesk.scroll.contentView)
        try check(abs(pageRect.midX - viewport.midX) <= 1, "Paper stays centred at viewport width \(width) and zoom \(zoom)")
    }
}
geometryModel.showRulers = true; geometryDesk.update()
let ruledPage = geometryModel.canvas!.sheets[0]
try check(abs(geometryDesk.convert(ruledPage.bounds, from: ruledPage).midX - geometryDesk.convert(geometryDesk.scroll.contentView.bounds, from: geometryDesk.scroll.contentView).midX) <= 1, "Rulers preserve viewport centring")
geometryDesk.frame.size.width = 700; geometryDesk.layoutSubtreeIfNeeded(); geometryDesk.update()
try check(geometryDesk.scroll.documentVisibleRect.minX > 20, "Narrow zoomed viewport permits a real horizontal pan")
let scrollPosition = CGPoint(x: max(0, geometryDesk.scroll.documentVisibleRect.minX - 20), y: geometryDesk.scroll.documentVisibleRect.minY)
geometryDesk.scroll.contentView.scroll(to: scrollPosition); geometryDesk.scroll.reflectScrolledClipView(geometryDesk.scroll.contentView)
let panned = geometryDesk.scroll.documentVisibleRect.minX
geometryDesk.update()
try check(abs(geometryDesk.scroll.documentVisibleRect.minX - panned) <= 1, "Ordinary updates preserve a manual horizontal pan")
geometryWindow.contentView = nil; geometryWindow.close(); geometryDesk.suspend()
print("Passed \(checks) Writer checks")

}
