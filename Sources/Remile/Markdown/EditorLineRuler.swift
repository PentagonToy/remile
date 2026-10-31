import AppKit

@MainActor final class EditorLineRuler: NSRulerView {
    init(scroll: NSScrollView) { super.init(scrollView: scroll, orientation: .verticalRuler); ruleThickness = 46 }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor(RemileStyle.editorBar).setFill(); bounds.fill()
        guard let view = scrollView?.documentView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let source = view.string as NSString
        let visible = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: view.visibleRect, in: container), actualGlyphRange: nil)
        var position = source.lineRange(for: NSRange(location: min(visible.location, source.length), length: 0)).location
        var number = source.substring(to: position).filter { $0 == "\n" }.count + 1
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(RemileStyle.secondaryInk)]
        while position < source.length, position <= NSMaxRange(visible) {
            let glyph = layout.glyphIndexForCharacter(at: position)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = convert(NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y), from: view)
            let label = String(number) as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 9, y: point.y), withAttributes: attributes)
            position = NSMaxRange(source.lineRange(for: NSRange(location: position, length: 0))); number += 1
        }
    }
}
