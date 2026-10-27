import AppKit
import SwiftUI
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func navigationHostVersion(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
var checks = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS: " + label); fflush(stdout) }
@MainActor func settle(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    while !ready() { precondition(ContinuousClock.now < deadline, "Timed out waiting for the synthetic fixture"); try await Task.sleep(for: .milliseconds(20)) }
}
let output = URL(fileURLWithPath: CommandLine.arguments[1]), app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let defaults = UserDefaults.standard, original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var isolated = original; isolated[NetworkAccessGate.preference] = true; isolated["assistant.provider"] = "Off"; isolated["editor.aiSuggestions"] = false; isolated["markdown.spellcheck"] = false
        defaults.setVolatileDomain(isolated, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let source = "Alpha alpha alphabet αlpha\nalpha 12\nalpha 34\n한글 👩🏽‍💻"
        let plain = EditorFindEngine.search(source, query: "alpha", options: .init())
        check(plain.matches.count == 5, "Plain search ignores case by default")
        check(EditorFindEngine.search(source, query: "alpha", options: .init(caseSensitive: true)).matches.count == 4, "Case-sensitive search distinguishes capitals")
        check(EditorFindEngine.search(source, query: "alpha", options: .init(wholeWord: true)).matches.count == 4, "Whole-word search excludes alphabet")
        let regex = EditorFindEngine.search(source, query: #"alpha (\d+)"#, options: .init(regularExpression: true))
        check(regex.matches.count == 2, "Regular expressions find numbered text")
        check(EditorFindEngine.replacingAll(regex, replacement: "value $1", regex: true) == source.replacingOccurrences(of: "alpha 12", with: "value 12").replacingOccurrences(of: "alpha 34", with: "value 34"), "Regex replacement expands capture groups")
        check(EditorFindEngine.search("a+b aab", query: "a+b", options: .init()).matches.count == 1, "Plain search treats regex punctuation literally")
        check(EditorFindEngine.search("one", query: "[", options: .init(regularExpression: true)).error != nil, "Invalid expressions report an error")
        check(EditorFindEngine.search("", query: "", options: .init()).matches.isEmpty, "Empty queries do not allocate a document snapshot")
        let many = EditorFindEngine.search(String(repeating: "x ", count: 20_002), query: "x", options: .init())
        check(many.matches.count == EditorFindEngine.matchLimit && many.truncated, "Match storage has a fixed upper bound")
        check(EditorFindEngine.replacingAll(many, replacement: "y", regex: false) == nil, "Truncated results cannot silently replace part of a document")
        check(EditorFindEngine.search(String(repeating: "a", count: EditorFindEngine.sourceLimit + 1), query: "a", options: .init()).error != nil, "Unusually large sources fail closed")
        let zero = EditorFindEngine.search("ab", query: "(?=b)", options: .init(regularExpression: true))
        check(EditorFindEngine.replacingAll(zero, replacement: "-", regex: true) == "a-b", "Zero-length regex matches terminate and insert at the correct boundary")
        let unicode = EditorFindEngine.search(source, query: "👩🏽‍💻", options: .init())
        check((source as NSString).substring(with: unicode.matches[0].range) == "👩🏽‍💻", "Search ranges preserve UTF-16 emoji boundaries")

        let controller = MarkdownEditorController(), scroll = controller.makeView()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        controller.update(source, size: 17, serif: false)
        controller.find(.showReplaceInterface)
        check(scroll.findBarPosition == .belowContent && scroll.isFindBarVisible, "Find and Replace opens below the real editor")
        let state = controller.findState
        state.query = "alpha"; state.options.wholeWord = true
        try await settle { !state.busy && state.count == 4 }
        state.move(1); check(controller.textView!.selectedRange() == plain.matches[1].range, "Next match moves the editor selection")
        state.move(-1); check(state.current == 0, "Previous match moves back")
        state.replacement = "beta"
        state.replace(all: true)
        try await settle { !state.busy && controller.textView!.string.contains("beta") }
        check(controller.textView!.string == "beta beta alphabet αlpha\nbeta 12\nbeta 34\n한글 👩🏽‍💻", "Replace All edits the live source and preserves non-matches")
        check(window.firstResponder === controller.textView, "Replacement returns Undo and typing to the document instead of the search field")
        check(controller.textView!.undoManager?.canUndo == true, "Bulk replacement registers native Undo")
        controller.textView!.undoManager?.undo()
        check(controller.textView!.string == source, "One Undo restores every replacement")
        state.query = "alpha"; state.options = .init(); try await settle { !state.busy && state.count == 5 }
        controller.textView!.string = "changed elsewhere"
        state.replace(all: false)
        check(controller.textView!.string == "changed elsewhere", "Stale results never overwrite a changed buffer")
        controller.update(source, size: 17, serif: false); state.sourceChanged()
        try await settle { !state.busy && state.count == 5 }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [380, 560, 900] {
                window.setContentSize(.init(width: width, height: 420)); scroll.frame = .init(x: 0, y: 0, width: width, height: 420)
                state.layoutChanged?(); scroll.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
                let bar = scroll.findBarView!
                check(bar.frame.width <= width + 1 && bar.frame.height >= 76, "Find bar fits \(Int(width)) pt with replacement controls")
                let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("find-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
        let escapeHandled = controller.textView(controller.textView!, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check(escapeHandled && !state.visible, "Escape closes Find even after focus returns to the source")
        check(!scroll.isFindBarVisible && state.count == 0 && !state.busy, "Closing Find releases results and stops pending work")
        let pending = MarkdownEditorController(); pending.find(.showFindInterface)
        let pendingScroll = pending.makeView()
        let pendingWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        pendingWindow.contentView = pendingScroll
        check(pendingScroll.isFindBarVisible, "Find requested before the source mounts is applied on attachment")
        pending.findState.close()

        let document = PDFDocument()
        for i in 1...3 {
            let image = NSImage(size: .init(width: 240, height: 320))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 240, height: 320).fill()
            ("Reading \(i)" as NSString).draw(at: .init(x: 20, y: 160), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]); image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: i - 1)
        }
        try document.dataRepresentation()!.write(to: output.appendingPathComponent("Navigation A.pdf"))
        try document.dataRepresentation()!.write(to: output.appendingPathComponent("Navigation B.pdf"))
        let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        let pdf = PDFSelectionView(frame: root.bounds); root.addSubview(pdf); window.contentView = root
        pdf.document = document; pdf.displayMode = .singlePageContinuous; pdf.autoScales = true; pdf.receivesWindowPageKeys = true
        pdf.layoutDocumentView(); pdf.go(to: document.page(at: 0)!)
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123)!
        check(pdf.acceptsPageKeys(from: root) && pdf.acceptsPageKeys(from: pdf), "PDF arrows work with document or neutral window focus")
        check(!pdf.acceptsPageKeys(from: NSTextField()) && !pdf.acceptsPageKeys(from: NSTextView()), "PDF arrows never steal input-field or source-editor keys")
        check(pdf.turnPage(with: right), "Right arrow is consumed by PDF page navigation")
        check(document.index(for: pdf.currentPage!) == 1, "Right arrow opens the next PDF page")
        _ = pdf.turnPage(with: left)
        check(document.index(for: pdf.currentPage!) == 0, "Left arrow returns to the previous PDF page")
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
        check(!pdf.turnPage(with: down), "Vertical arrows retain native scrolling")
        let board = NSPasteboard.withUniqueName()
        board.writeObjects([output.appendingPathComponent("Navigation B.pdf") as NSURL])
        check(PDFSelectionView.droppedPDFs(from: board).count == 1, "PDF canvas accepts a file-URL drag")
        board.clearContents(); board.writeObjects([output.appendingPathComponent("note.md") as NSURL])
        check(PDFSelectionView.droppedPDFs(from: board).isEmpty, "Other file types keep their normal drop path")
        controller.suspend(); window.orderOut(nil); pendingWindow.orderOut(nil)
        print("Passed \(checks) editor navigation checks"); exit(0)
    } catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
