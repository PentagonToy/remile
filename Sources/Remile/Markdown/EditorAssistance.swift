import AppKit
import SwiftUI

struct InlineWordCompletion {
    let prefix: String
    private let needsSpace: Bool
    private let startsSentence: Bool

    init?(before: String) {
        let prefix = String(before.reversed().prefix(while: Self.isWordCharacter).reversed())
        let preceding = before.dropLast(prefix.count)
        if !prefix.isEmpty, preceding.last == "\\" || prefix.first?.isLetter != true { return nil }
        self.prefix = prefix
        needsSpace = prefix.isEmpty && before.last.map { !$0.isWhitespace && !"([{“‘。！？".contains($0) } == true
        let sentenceEnd = before.reversed().drop(while: { $0.isWhitespace || "\"’”')]".contains($0) }).first
        startsSentence = sentenceEnd.map { ".!?。！？".contains($0) } ?? true
    }

    func insertion(for answer: String) -> String? {
        guard let first = answer.split(whereSeparator: \.isWhitespace).first,
              first.count <= 48, first.first?.isLetter == true, first.last?.isLetter == true,
              first.allSatisfy(Self.isWordCharacter) else { return nil }
        let word = String(first)
        if !prefix.isEmpty {
            guard word.count > prefix.count, word.prefix(prefix.count).lowercased() == prefix.lowercased() else { return nil }
            return String(word.dropFirst(prefix.count))
        }
        let completed = startsSentence ? word.prefix(1).uppercased() + word.dropFirst() : word
        return (needsSpace ? " " : "") + completed
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || "-'’".contains(character)
    }
}

/// A completion is only applied on Tab; generation never edits the document.
@MainActor final class EditorAssistance {
    private var task: Task<Void, Never>?
    private var ghost: NSTextField?
    private var proposal: (source: String, offset: Int, text: String)?
    func cancel() { task?.cancel(); task = nil; ghost?.removeFromSuperview(); ghost = nil; proposal = nil }
    func schedule(_ view: NSTextView) {
        cancel()
        guard AIConfiguration.writingEnabled, AIConfiguration.mode != .gpt || AIConfiguration.fallbackEnabled, UserDefaults.standard.string(forKey: "assistant.provider") != "Off", UserDefaults.standard.bool(forKey: "editor.aiSuggestions"), !view.hasMarkedText(), view.selectedRange().length == 0 else { return }
        let source = view.string, offset = view.selectedRange().location
        let ns = source as NSString
        var lineEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: offset, length: 0))
        let remaining = ns.substring(with: NSRange(location: offset, length: max(0, lineEnd - offset)))
        guard remaining.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        task = Task { @MainActor [weak self, weak view] in
            do {
                try await Task.sleep(for: .milliseconds(550))
                guard let self, let view, !view.hasMarkedText(), view.string == source, view.selectedRange() == NSRange(location: offset, length: 0) else { return }
                let ns = source as NSString, before = ns.substring(with: NSRange(location: max(0, offset - 600), length: min(600, offset))), after = ns.substring(with: NSRange(location: offset, length: min(120, ns.length - offset)))
                guard let completion = InlineWordCompletion(before: before) else { return }
                let language = UserDefaults.standard.string(forKey: "editor.language") ?? "Automatic"
                let prefix = completion.prefix.isEmpty ? "(none)" : completion.prefix
                let answer = try await AppleIntelligence.respond(to: "Writing language: \(language)\nTyped word prefix: \(prefix)\nBefore cursor:\n<source>\(before)</source>\nAfter cursor:\n<source>\(after)</source>", instructions: AssistantPrompts.completion, maximumTokens: 30)
                try Task.checkCancellation()
                guard AIConfiguration.writingEnabled, AIConfiguration.mode != .manual, AIConfiguration.mode != .gpt || AIConfiguration.fallbackEnabled, view.string == source, view.selectedRange() == NSRange(location: offset, length: 0), !view.hasMarkedText() else { return }
                guard !answer.contains("Before cursor:"), !answer.contains("After cursor:"), !answer.contains("Typed word prefix:") else { return }
                guard let text = completion.insertion(for: answer), let layout = view.layoutManager, let container = view.textContainer else { return }
                let field = NSTextField(labelWithString: text); field.font = view.font; field.textColor = NSColor.secondaryLabelColor; field.alphaValue = 0.65; field.isSelectable = false
                guard let window = view.window else { return }
                layout.ensureLayout(for: container)
                let caret = view.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
                guard caret.height > 0 else { return }
                let rect = view.convert(window.convertFromScreen(caret), from: nil)
                field.sizeToFit(); field.frame.origin = NSPoint(x: rect.minX, y: rect.minY)
                view.addSubview(field); self.ghost = field; self.proposal = (source, offset, text)
            } catch { }
        }
    }
    func accept(_ view: NSTextView) -> Bool {
        guard AIConfiguration.writingEnabled, AIConfiguration.mode != .manual, AIConfiguration.mode != .gpt || AIConfiguration.fallbackEnabled, let proposal, !view.hasMarkedText(), proposal.source == view.string, view.selectedRange() == NSRange(location: proposal.offset, length: 0) else { cancel(); return false }
        cancel(); view.breakUndoCoalescing(); view.insertText(proposal.text, replacementRange: NSRange(location: proposal.offset, length: 0)); view.undoManager?.setActionName("Accept Suggestion"); view.breakUndoCoalescing(); return true
    }
}

struct EditorLanguageSettings: View {
    static func languageTitle(_ value: String) -> String {
        switch value.replacingOccurrences(of: "-", with: "_") {
        case "en", "en_US": return "English (US)"
        case "en_GB": return "English (UK)"
        default: return Locale.current.localizedString(forIdentifier: value) ?? value
        }
    }
    @AppStorage("editor.language") private var language = "Automatic"
    @AppStorage("editor.spellcheck") private var spellcheck = true
    var body: some View {
        Picker("Writing language", selection: $language) {
            Text("Automatic").tag("Automatic")
            ForEach(NSSpellChecker.shared.availableLanguages.sorted(), id: \.self) { value in Text(Self.languageTitle(value)).tag(value) }
        }
        Toggle("Check spelling", isOn: $spellcheck)
    }
}
