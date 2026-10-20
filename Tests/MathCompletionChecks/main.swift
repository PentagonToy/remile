import AppKit

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
}

var checks = 0
func verify(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1 }
func context(_ text: String) -> MathCompletion.Context? { MathCompletion.context(text, selection: NSRange(location: text.utf16.count, length: 0)) }
var finished = false
let application = NSApplication.shared
Task { @MainActor in
    for text in [#"$\eps"#, "$$\n\\eps", #"\(\eps"#, #"\[\eps"#, #"한글 👩🏽‍💻 $k-\eps"#] {
        let completion = context(text)
        verify(completion != nil && MathCompletion.suggestions(completion!).contains(#"\epsilon"#), "Completion inside formula: \(text)")
        verify((text as NSString).substring(with: completion!.range) == #"\eps"#, "UTF-16 command range")
    }
    for text in [#"prose \eps"#, #"$5 for \eps"#, #"$5 to $10 \eps"#, #"\$\eps"#, #"`$\eps"#, #"``$\eps"#, "```tex\n$\\eps", "~~~\n$\\eps", "    $\\eps", "$x$ \\eps", "$$x$$ \\eps", #"$x \\eps"#, "$x\n\\eps"] {
        verify(context(text) == nil, "No completion outside active math/code/currency: \(text)")
    }
    verify(context("```tex\n$x$\n```\n$\\eps") != nil, "Completion resumes after closed code fence")
    verify(context("```tex\n~~~\n$\\eps") == nil, "Other marker cannot close fence")
    verify(context("```tex\n```x\n$\\eps") == nil, "Trailing code cannot close fence")
    verify(context("`code` $\\eps") != nil, "Closed inline code does not block later formula")
    verify(MathCompletion.context("$\\eps", selection: NSRange(location: 1, length: 1)) == nil, "Selection never replaced as completion")
    verify(MathCompletion.context(#"$\epsilon$"#, selection: NSRange(location: 5, length: 0)) == nil, "Completion cannot duplicate a command suffix")
    verify(MathCompletion.context(#"$\fr{a}{b}$"#, selection: NSRange(location: 4, length: 0)) == nil, "Template cannot duplicate existing arguments")
    verify(context(String(repeating: "a", count: 200_001) + "$\\eps") == nil, "Bounded scan fails closed for huge prefix")
    verify(MathCompletion.suggestions(context("$\\zzzz")!).isEmpty, "Unknown command has no invented suggestion")
    verify(MathCompletion.suggestions(context("$\\")!).count <= 12, "Short prefix has bounded suggestions")
    verify(MathCompletion.insertionSelection(#"\frac{}{}"#, location: 12).location == 18, "Fraction places caret in numerator")
    verify(MathCompletion.insertionSelection(#"\epsilon"#, location: 12).location == 20, "Symbol places caret after command")
    let controller = MarkdownEditorController(), scroll = controller.makeView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    let view = controller.textView as! MarkdownSourceTextView
    verify(!view.isAutomaticTextCompletionEnabled, "Completion never opens automatically while typing")
    controller.update("한글 👩🏽‍💻 $\\fr$", size: 17, serif: false)
    let command = (view.string as NSString).range(of: #"\fr"#)
    view.setSelectedRange(NSRange(location: NSMaxRange(command), length: 0)); window.makeFirstResponder(view)
    verify(view.rangeForUserCompletion == command, "Native completion uses full TeX command range")
    var selected = 0
    verify(view.completions(forPartialWordRange: command, indexOfSelectedItem: &selected) == [#"\frac{}{}"#] && selected == -1, "Native completion list is explicit")
    let original = view.string
    view.undoManager?.beginUndoGrouping()
    view.insertCompletion(#"\frac{}{}"#, forPartialWordRange: command, movement: NSReturnTextMovement, isFinal: true)
    view.undoManager?.endUndoGrouping()
    verify(view.string == "한글 👩🏽‍💻 $\\frac{}{}$", "Native completion preserves surrounding Unicode and delimiters")
    verify(view.selectedRange() == MathCompletion.insertionSelection(#"\frac{}{}"#, location: command.location), "Native fraction selection enters placeholder")
    verify(view.undoManager?.canUndo == true, "Completion registers native Undo")
    view.undoManager?.undo()
    verify(view.string == original, "Native Undo restores partial command")
    view.setSelectedRange(NSRange(location: NSMaxRange(command), length: 0))
    view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composing = view.string
    verify(view.rangeForUserCompletion.location == NSNotFound, "IME composition suppresses native completion")
    view.insertCompletion(#"\frac{}{}"#, forPartialWordRange: command, movement: NSReturnTextMovement, isFinal: true)
    verify(view.hasMarkedText() && view.string == composing, "Completion cannot replace marked text")
    view.unmarkText()
    print("PASS: \(checks) math completion checks")
    finished = true
}
while !finished { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
