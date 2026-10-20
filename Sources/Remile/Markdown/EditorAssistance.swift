import AppKit
import SwiftUI

/// A completion is only applied on Tab; generation never edits the document.
@MainActor final class EditorAssistance {
    private var task: Task<Void, Never>?
    private var ghost: NSTextField?
    private var proposal: (source: String, offset: Int, text: String)?
    func cancel() { task?.cancel(); task = nil; ghost?.removeFromSuperview(); ghost = nil; proposal = nil }
    func schedule(_ view: NSTextView) {
        cancel()
        guard UserDefaults.standard.string(forKey: "assistant.provider") != "Off", UserDefaults.standard.bool(forKey: "editor.aiSuggestions"), !view.hasMarkedText(), view.selectedRange().length == 0 else { return }
        let source = view.string, offset = view.selectedRange().location
        task = Task { @MainActor [weak self, weak view] in
            do {
                try await Task.sleep(for: .milliseconds(1200))
                guard let self, let view, !view.hasMarkedText(), view.string == source, view.selectedRange() == NSRange(location: offset, length: 0) else { return }
                let ns = source as NSString, before = ns.substring(with: NSRange(location: max(0, offset - 600), length: min(600, offset))), after = ns.substring(with: NSRange(location: offset, length: min(120, ns.length - offset)))
                let language = UserDefaults.standard.string(forKey: "editor.language") ?? "Automatic"
                let answer = try await AppleIntelligence.respond(to: "Writing language: \(language)\nBefore cursor:\n<source>\(before)</source>\nAfter cursor:\n<source>\(after)</source>", instructions: AssistantPrompts.completion, maximumTokens: 30)
                try Task.checkCancellation()
                guard view.string == source, view.selectedRange() == NSRange(location: offset, length: 0), !view.hasMarkedText() else { return }
                let text = String(answer.components(separatedBy: .newlines).first?.prefix(48) ?? "")
                guard !text.isEmpty, !text.contains("```"), !text.contains("\\"), !text.contains("$"), let layout = view.layoutManager, view.textContainer != nil else { return }
                self.proposal = (source, offset, text)
                let field = NSTextField(labelWithString: text); field.font = view.font; field.textColor = NSColor.secondaryLabelColor; field.alphaValue = 0.65; field.isSelectable = false
                let glyph = layout.glyphIndexForCharacter(at: min(offset, max(0, ns.length - 1)))
                let rect = ns.length == 0 || source.hasSuffix("\n") && offset == ns.length ? layout.extraLineFragmentRect : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let point = ns.length == 0 ? NSPoint.zero : layout.location(forGlyphAt: glyph)
                field.sizeToFit(); field.frame.origin = NSPoint(x: view.textContainerOrigin.x + rect.minX + point.x + (offset == ns.length && ns.length > 0 && !source.hasSuffix("\n") ? (view.font?.maximumAdvancement.width ?? 8) * 0.55 : 0), y: view.textContainerOrigin.y + rect.minY)
                view.addSubview(field); self.ghost = field
            } catch { }
        }
    }
    func accept(_ view: NSTextView) -> Bool {
        guard let proposal, !view.hasMarkedText(), proposal.source == view.string, view.selectedRange() == NSRange(location: proposal.offset, length: 0) else { cancel(); return false }
        cancel(); view.breakUndoCoalescing(); view.insertText(proposal.text, replacementRange: NSRange(location: proposal.offset, length: 0)); view.undoManager?.setActionName("Accept Suggestion"); view.breakUndoCoalescing(); return true
    }
}

struct EditorLanguageSettings: View {
    @AppStorage("editor.language") private var language = "Automatic"
    @AppStorage("editor.spellcheck") private var spellcheck = true
    var body: some View {
        Picker("Writing language", selection: $language) {
            Text("Automatic").tag("Automatic")
            ForEach(NSSpellChecker.shared.availableLanguages.sorted(), id: \.self) { value in Text(Locale.current.localizedString(forIdentifier: value) ?? value).tag(value) }
        }
        Toggle("Check spelling", isOn: $spellcheck)
    }
}
