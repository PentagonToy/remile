import AppKit
import SwiftUI

@MainActor
final class MarkdownEditorController: NSObject, ObservableObject, NSTextViewDelegate {
    private(set) var scroll: NSScrollView?
    private(set) var textView: NSTextView?
    var proofreadRequested: ((NSRange, NSTextView) -> Void)?
    var dismissWriting: (() -> Void)?
    var writingRanges: [NSRange] = [] { didSet { scheduleStyle() } }
    var texTheme: TeXEditorTheme?
    var externalRanges: [NSRange] = [] { didSet { if oldValue != externalRanges { scheduleStyle() } } }
    var showExternalEdits = false { didSet { if oldValue != showExternalEdits { scheduleStyle() } } }
    var syncToPreview: ((Int) -> Void)?
    var sourceSyncHint: TeXSync.TextHint? {
        guard let view = textView else { return nil }
        return TeXSync.hint(in: view.string, offset: view.selectedRange().location)
    }
    var inspectCitation: ((String) -> Void)?
    var citationCompletion: ((String, NSRange) async -> EditorCompletion.Context?)?
    var prepareCitation: ((EditorCompletion.Item) throws -> Void)?
    var citationFailure: ((String) -> Void)?
    private let completion = EditorCompletionPanel()
    private var completionTask: Task<Void, Never>?
    private var focusMode = false
    private static let markdownPatterns = ["(?m)^#{1,6}\\s+.*$", "`[^`\\n]+`", "\\*\\*[^*\\n]+\\*\\*", "\\[[^]\\n]+\\]\\([^\\n)]+\\)"].compactMap { try? NSRegularExpression(pattern: $0) }
    private var appliedTheme: String?
    private var hasStyled = false
    private var documentID: String?
    private var pairing = false
    private let assistance = EditorAssistance()
    private var flashTask: Task<Void, Never>?
    private var flashRange = NSRange(location: 0, length: 0)
    private var pendingLocation: (Int, String)?
    var changed: (String) -> Void = { _ in }
    private var styling: Task<Void, Never>?
    private var styledRange = NSRange(location: 0, length: 0)
    private var scrollObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var appliedLanguage: String?
    private var spellingSource = ""
    private var spellingExcluded: [NSRange] = []
    func makeView() -> NSScrollView {
        if let scroll { scroll.removeFromSuperview(); return scroll }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = MarkdownSourceTextView(frame: .zero)
        view.isRichText = false; view.allowsUndo = true; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.minSize = NSSize(width: 0, height: 0); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true; view.textContainerInset = NSSize(width: 24, height: 24)
        view.delegate = self; view.setAccessibilityLabel("Markdown source")
        view.backgroundColor = NSColor(RemileStyle.surface); view.textColor = NSColor(RemileStyle.ink)
        view.sourceInteraction = { [weak self] in self?.fadeFlash(); self?.dismissWriting?() }
        view.inspectCitation = { [weak self] key in self?.inspectCitation?(key) }
        view.proofreadSelection = { [weak self, weak view] range in guard let view else { return }; self?.proofreadRequested?(range, view) }
        view.completionKey = { [weak self] event in
            guard let self else { return false }
            if self.completion.key(event) { return true }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if self.texTheme != nil, modifiers == .command, event.charactersIgnoringModifiers == "/" { self.toggleComment(); return true }
            return false
        }
        view.resigned = { [weak self] in self?.completion.dismiss(); self?.assistance.cancel() }
        view.syncSelection = { [weak self] in guard let self else { return }; self.syncToPreview?(self.selectedLine) }
        scroll.documentView = view; ReaderScrolling.configure(scroll); self.scroll = scroll; textView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleStyle(); self?.scroll?.verticalRulerView?.needsDisplay = true }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, let view = self.textView else { return }; self.applyPreferences(view) }
        }
        return scroll
    }
    private func applyPreferences(_ view: NSTextView) {
        let focus = UserDefaults.standard.bool(forKey: "editor.focusMode")
        if focusMode != focus { focusMode = focus; scheduleStyle() }
        let numbers = texTheme == nil && UserDefaults.standard.bool(forKey: "markdown.lineNumbers")
        if scroll?.verticalRulerView == nil, let scroll { scroll.verticalRulerView = EditorLineRuler(scroll: scroll); scroll.hasVerticalRuler = true }
        scroll?.rulersVisible = numbers
        scroll?.verticalRulerView?.needsDisplay = true
        let spellcheck = texTheme == nil ? (UserDefaults.standard.object(forKey: "markdown.spellcheck") as? Bool ?? true) : (UserDefaults.standard.object(forKey: "editor.spellcheck") as? Bool ?? true)
        if view.isGrammarCheckingEnabled != spellcheck { view.isGrammarCheckingEnabled = spellcheck }
        if view.isContinuousSpellCheckingEnabled != spellcheck { view.isContinuousSpellCheckingEnabled = spellcheck }
        let language = UserDefaults.standard.string(forKey: "editor.language") ?? "Automatic"
        if appliedLanguage != language {
            appliedLanguage = language
            NSSpellChecker.shared.automaticallyIdentifiesLanguages = language == "Automatic"
            if language != "Automatic" { NSSpellChecker.shared.setLanguage(language) }
        }
        if !AIConfiguration.writingEnabled || (AIConfiguration.mode == .gpt && !AIConfiguration.fallbackEnabled) || UserDefaults.standard.string(forKey: "assistant.provider") == "Off" || !UserDefaults.standard.bool(forKey: "editor.aiSuggestions") { assistance.cancel() }
    }
    func update(_ source: String, size: CGFloat, serif: Bool, document: String? = nil) {
        guard let view = textView else { return }
        if documentID != document { assistance.cancel(); documentID = document; view.undoManager?.removeAllActions(); clearFlash(); completion.dismiss() }
        var needsStyle = !hasStyled
        if view.string != source, !view.hasMarkedText() {
            needsStyle = true
            let selection = view.selectedRange(), origin = scroll?.contentView.bounds.origin ?? .zero
            clearFlash(); completion.dismiss(); assistance.cancel()
            view.string = source
            view.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: (source as NSString).length)))
            scroll?.contentView.scroll(to: origin)
        }
        let palette = texTheme?.palette
        (view as? MarkdownSourceTextView)?.markdownMode = texTheme == nil
        view.setAccessibilityLabel(texTheme == nil ? "Markdown source" : "LaTeX source")
        let theme = texTheme?.rawValue ?? "Markdown"
        if appliedTheme != theme {
            appliedTheme = theme; needsStyle = true
            view.backgroundColor = palette?.background ?? NSColor(RemileStyle.surface)
            view.textColor = palette?.ink ?? NSColor(RemileStyle.ink)
        }
        let font = serif ? NSFont.systemFont(ofSize: size).withDesign(.serif) : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if view.font != font {
            needsStyle = true
            let style = NSMutableParagraphStyle(); style.lineSpacing = size * 0.32
            view.font = font; view.defaultParagraphStyle = style
            view.typingAttributes = [.font: font, .foregroundColor: palette?.ink ?? NSColor(RemileStyle.ink), .paragraphStyle: style]
            view.textStorage?.addAttributes([.font: font, .paragraphStyle: style], range: NSRange(location: 0, length: (view.string as NSString).length))
        }
        applyPreferences(view)
        if needsStyle { hasStyled = true; scheduleStyle() }
        if let pending = pendingLocation { pendingLocation = nil; reveal(line: pending.0, text: pending.1) }
    }
    func textDidChange(_ notification: Notification) {
        guard let view = textView else { return }; fadeFlash(); changed(view.string); scroll?.verticalRulerView?.needsDisplay = true; scheduleStyle(); scheduleCompletion(); assistance.schedule(view)
    }
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any] = [:], results: [NSTextCheckingResult], orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        if spellingSource != view.string { spellingSource = view.string; spellingExcluded = EditorSpellcheck.excluded(view.string) }
        return results.filter { EditorSpellcheck.accepts($0.range, excluded: spellingExcluded) }
    }
    func table() -> MarkdownTable? { guard let view = textView else { return nil }; return MarkdownTable.parse(view.string, selection: view.selectedRange()) ?? MarkdownTable.empty(at: view.selectedRange()) }
    func applyTable(_ table: MarkdownTable, expected: String) -> Bool {
        guard let view = textView, view.string == expected else { return false }
        let text = view.string as NSString
        let before = table.range.location > 0 && text.character(at: table.range.location - 1) != 10 ? "\n" : ""
        let after = NSMaxRange(table.range) < text.length && text.character(at: NSMaxRange(table.range)) != 10 ? "\n" : ""
        apply(.init(range: table.range, text: before + table.markdown + after, selection: NSRange(location: table.range.location + (before as NSString).length, length: 0)), name: "Edit Table")
        return true
    }
    func selectWritingIssue(_ range: NSRange, source: String) {
        guard let view = textView, view.string == source, NSMaxRange(range) <= (source as NSString).length else { return }
        view.window?.makeFirstResponder(view); view.setSelectedRange(range); view.scrollRangeToVisible(range)
    }
    func replaceWritingIssue(_ range: NSRange, with replacement: String, source: String) {
        guard textView?.string == source, NSMaxRange(range) <= (source as NSString).length else { return }
        apply(.init(range: range, text: replacement, selection: NSRange(location: range.location + (replacement as NSString).length, length: 0)), name: "Writing suggestion")
    }
    func suspend() {
        completionTask?.cancel(); styling?.cancel(); flashTask?.cancel()
        completion.dismiss(); assistance.cancel(); changed = { _ in }
    }
    func pasteMarkdown() { (textView as? MarkdownSourceTextView)?.pasteMarkdown(nil) }
    func textViewDidChangeSelection(_ notification: Notification) { completion.dismiss(); if focusMode { scheduleStyle() }; if let view = textView { assistance.schedule(view) } }
    private func scheduleCompletion() {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, let view = self.textView, !view.hasMarkedText() else { return }
            let source = view.string, selection = view.selectedRange()
            let custom = self.texTheme == nil ? nil : await self.citationCompletion?(source, selection)
            guard !Task.isCancelled, view.string == source, view.selectedRange() == selection else { return }
            if self.texTheme != nil, ReferenceCitationCompletion.prefix(source, selection: selection) != nil, custom == nil { self.completion.dismiss(); return }
            self.completion.show(in: view, tex: self.texTheme != nil, custom: custom, prepare: self.prepareCitation, failure: self.citationFailure)
            if self.completion.visible { self.assistance.cancel() }
        }
    }
    private func scheduleStyle() {
        styling?.cancel()
        styling = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            self?.highlightVisibleText()
        }
    }
    /// Temporary layout attributes preserve canonical source, selection and native Undo.
    private func highlightVisibleText() {
        guard let view = textView, !view.hasMarkedText(), let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        guard text.length > 0 else { return }
        let glyphs = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = max(0, visible.location - 1000), end = min(text.length, NSMaxRange(visible) + 2000)
        let range = NSRange(location: start, length: min(30_000, max(0, end - start)))
        let old = NSIntersectionRange(styledRange, NSRange(location: 0, length: text.length))
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: old)
        styledRange = range
        if let palette = texTheme?.palette {
            for token in TeXSyntax.tokens(view.string, range: range) {
                let colour: NSColor
                switch token.kind { case .command: colour = palette.command; case .punctuation: colour = palette.punctuation; case .comment: colour = palette.comment }
                layout.addTemporaryAttribute(.foregroundColor, value: colour, forCharacterRange: token.range)
            }
        } else {
        for regex in Self.markdownPatterns {
            for match in regex.matches(in: view.string, range: range) { layout.addTemporaryAttribute(.foregroundColor, value: NSColor(RemileStyle.accent), forCharacterRange: match.range) }
        }
        }
        if focusMode {
            let paragraph = text.paragraphRange(for: NSRange(location: min(view.selectedRange().location, max(0, text.length - 1)), length: 0))
            let dim = (texTheme?.palette.ink ?? NSColor(RemileStyle.ink)).withAlphaComponent(0.34)
            if range.location < paragraph.location { layout.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: range.location, length: min(NSMaxRange(range), paragraph.location) - range.location)) }
            if NSMaxRange(paragraph) < NSMaxRange(range) { let start = max(range.location, NSMaxRange(paragraph)); layout.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: start, length: NSMaxRange(range) - start)) }
        }
        for issue in writingRanges {
            let marked = NSIntersectionRange(issue, range)
            if marked.length > 0 {
                layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue, forCharacterRange: marked)
                layout.addTemporaryAttribute(.underlineColor, value: NSColor.systemOrange, forCharacterRange: marked)
            }
        }
        if showExternalEdits {
            for external in externalRanges {
                let marked = NSIntersectionRange(external, range)
                if marked.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemPurple, forCharacterRange: marked) }
            }
        }
    }
    func apply(_ change: MarkdownEditing.Change, name: String) {
        guard let view = textView, !view.hasMarkedText() else { return }
        view.window?.makeFirstResponder(view)
        view.breakUndoCoalescing()
        view.insertText(change.text, replacementRange: change.range)
        view.setSelectedRange(change.selection); view.undoManager?.setActionName(name); view.breakUndoCoalescing()
    }
    func wrap(_ before: String, _ after: String, name: String) {
        guard let view = textView else { return }
        apply(MarkdownEditing.wrap(view.string, selection: view.selectedRange(), before: before, after: after), name: name)
    }
    func prefix(_ marker: String, name: String) {
        guard let view = textView else { return }
        apply(MarkdownEditing.prefix(view.string, selection: view.selectedRange(), marker: marker), name: name)
    }
    func find() {
        guard let view = textView else { return }; view.window?.makeFirstResponder(view)
        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue); view.performFindPanelAction(item)
    }
    var selectedLine: Int {
        guard let view = textView else { return 0 }
        return (view.string as NSString).substring(to: min(view.selectedRange().location, (view.string as NSString).length)).filter { $0 == "\n" }.count
    }
    func reveal(line: Int, text selected: String = "") {
        clearFlash()
        guard let view = textView else { pendingLocation = (line, selected); return }
        let text = view.string as NSString; var index = 0
        for _ in 0..<line { guard index < text.length else { break }; index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0))) }
        var range = NSRange(location: min(index, text.length), length: 0)
        if !selected.isEmpty {
            let found = text.range(of: selected, options: [], range: NSRange(location: range.location, length: min(4000, text.length - range.location)))
            if found.location != NSNotFound { range = found }
        }
        view.setSelectedRange(range); view.scrollRangeToVisible(range); view.window?.makeFirstResponder(view)
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if texTheme != nil, !pairing, !textView.hasMarkedText(), replacementString == "}",
           let change = EditorCompletion.closeEnvironment(textView.string, selection: affectedCharRange) {
            pairing = true; defer { pairing = false }; apply(change, name: "Complete Environment"); return false
        }
        guard !pairing, !textView.hasMarkedText(), UserDefaults.standard.object(forKey: "markdown.autoPair") as? Bool ?? true,
              let replacementString, let change = MarkdownEditing.pair(textView.string, range: affectedCharRange, replacement: replacementString) else { return true }
        pairing = true; defer { pairing = false }
        apply(change, name: "Pair Delimiters"); return false
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if assistance.accept(textView) { return true }
            if texTheme != nil, let change = EditorSourceEditing.indent(textView.string, selection: textView.selectedRange(), reverse: false) { apply(change, name: "Indent"); return true }
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), texTheme != nil, let change = EditorSourceEditing.indent(textView.string, selection: textView.selectedRange(), reverse: true) { apply(change, name: "Outdent"); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { assistance.cancel() }
        guard !textView.hasMarkedText(), commandSelector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let change = MarkdownEditing.newline(textView.string, selection: textView.selectedRange()) else { return false }
        apply(change, name: "Continue List"); return true
    }
    func toggleComment() {
        guard let view = textView, let change = EditorSourceEditing.toggleComment(view.string, selection: view.selectedRange()) else { return }
        apply(change, name: "Toggle Comment")
    }
    @discardableResult func reveal(range: NSRange) -> Bool {
        guard let view = textView, let layout = view.layoutManager, range.location >= 0, range.length > 0, NSMaxRange(range) <= (view.string as NSString).length else { return false }
        clearFlash(); flashRange = range
        view.setSelectedRange(range); view.scrollRangeToVisible(range); view.window?.makeFirstResponder(view)
        layout.addTemporaryAttribute(.backgroundColor, value: RemileStyle.amber.withAlphaComponent(0.3), forCharacterRange: range)
        return true
    }
    func flash(line: Int) {
        guard let view = textView, let layout = view.layoutManager else { return }
        flashTask?.cancel()
        let text = view.string as NSString
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(flashRange, NSRange(location: 0, length: text.length)))
        var index = 0
        for _ in 0..<line { guard index < text.length else { break }; index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0))) }
        guard index < text.length else { return }
        let range = text.lineRange(for: NSRange(location: index, length: 0)); flashRange = range
        layout.addTemporaryAttribute(.backgroundColor, value: RemileStyle.amber.withAlphaComponent(0.3), forCharacterRange: range)
    }
    private func clearFlash() {
        flashTask?.cancel(); flashTask = nil
        if let view = textView { view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(flashRange, NSRange(location: 0, length: (view.string as NSString).length))) }
        flashRange = NSRange(location: 0, length: 0)
    }
    private func fadeFlash() {
        guard flashRange.length > 0, flashTask == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { clearFlash(); return }
        let range = flashRange
        flashTask = Task { @MainActor [weak self] in
            for step in 1...18 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, let view = self.textView else { return }
                let safe = NSIntersectionRange(range, NSRange(location: 0, length: (view.string as NSString).length))
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: RemileStyle.amber.withAlphaComponent(0.3 * (1 - Double(step) / 18)), forCharacterRange: safe)
            }
            self?.clearFlash()
        }
    }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }; if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }
}

/// Native editing, explicit mathematical completion and optional local suggestion lists.
@MainActor
final class MarkdownSourceTextView: NSTextView {
    var syncSelection: () -> Void = {}
    var sourceInteraction: () -> Void = {}
    var completionKey: (NSEvent) -> Bool = { _ in false }
    var inspectCitation: ((String) -> Void)?
    var proofreadSelection: (NSRange) -> Void = { _ in }
    var markdownMode = true
    var resigned: () -> Void = {}
    override func paste(_ sender: Any?) {
        guard markdownMode else { super.paste(sender); return }
        let board = NSPasteboard.general
        if let text = board.string(forType: .string), let table = MarkdownTable.pasted(text) { insertText(table, replacementRange: selectedRange()); undoManager?.setActionName("Paste Table"); return }
        if let text = board.string(forType: .string), text.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil, selectedRange().length > 0 {
            let title = (string as NSString).substring(with: selectedRange())
            insertText("[" + title + "](" + text.replacingOccurrences(of: ")", with: "%29") + ")", replacementRange: selectedRange()); undoManager?.setActionName("Paste Link"); return
        }
        super.paste(sender)
    }
    @objc func pasteMarkdown(_ sender: Any?) {
        guard let data = NSPasteboard.general.data(forType: .rtf), data.count <= 1_000_000, let rich = NSAttributedString(rtf: data, documentAttributes: nil) else { paste(sender); return }
        var output = ""
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            let text = (rich.string as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { output += text; return }
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            var value = text
            if traits.contains(.boldFontMask) { value = "**" + value + "**" }
            if traits.contains(.italicFontMask) { value = "*" + value + "*" }
            if let link = attributes[.link], let url = URL(string: String(describing: link)), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { value = "[" + value + "](" + url.absoluteString.replacingOccurrences(of: ")", with: "%29") + ")" }
            output += value
        }
        breakUndoCoalescing(); insertText(output, replacementRange: selectedRange()); undoManager?.setActionName("Paste as Markdown"); breakUndoCoalescing()
    }
    override func keyDown(with event: NSEvent) { sourceInteraction(); if !completionKey(event) { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) {
        sourceInteraction(); resigned(); super.mouseDown(with: event)
        if event.clickCount == 2 { syncSelection() }
    }
    override func resignFirstResponder() -> Bool { resigned(); return super.resignFirstResponder() }
    override var rangeForUserCompletion: NSRange {
        guard !hasMarkedText(), let context = MathCompletion.context(string, selection: selectedRange()) else { return NSRange(location: NSNotFound, length: 0) }
        return context.range
    }
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard !hasMarkedText(), let context = MathCompletion.context(string, selection: selectedRange()), context.range == charRange else { return nil }
        index.pointee = -1
        return MathCompletion.suggestions(context)
    }
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard !hasMarkedText() else { return }
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag, movement != NSCancelTextMovement, MathCompletion.commands.contains(word) {
            setSelectedRange(MathCompletion.insertionSelection(word, location: charRange.location))
            undoManager?.setActionName("Complete Math Command")
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let clickedRange = NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0)
        if inspectCitation != nil, let key = ReferenceEvidence.key(in: string, selection: clickedRange) {
            let source = NSMenuItem(title: "View reference source", action: #selector(inspectSelectedCitation(_:)), keyEquivalent: "")
            source.target = self; source.representedObject = key
            menu.insertItem(source, at: 0); menu.insertItem(.separator(), at: 1)
        }
        if selectedRange().length > 0 {
            let proofread = NSMenuItem(title: WritingProofreading.provider == "ChatGPT" ? "Proofread with ChatGPT" : "Proofread with Apple Intelligence", action: #selector(proofreadSelectedText(_:)), keyEquivalent: "")
            proofread.target = self; proofread.toolTip = "Review a grammar suggestion before applying it."
            menu.insertItem(proofread, at: 0); menu.insertItem(.separator(), at: 1)
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Complete Math Command", action: #selector(completeMathCommand(_:)), keyEquivalent: "")
        item.target = self; item.toolTip = "Inside a formula, type a TeX command and press Option-Escape."
        menu.addItem(item)
        return menu
    }
    @objc private func inspectSelectedCitation(_ sender: NSMenuItem) { if let key = sender.representedObject as? String { inspectCitation?(key) } }
    @objc private func proofreadSelectedText(_ sender: Any?) { proofreadSelection(selectedRange()) }
    @objc private func completeMathCommand(_ sender: Any?) { complete(sender) }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(proofreadSelectedText(_:)) {
            return !hasMarkedText() && selectedRange().length > 0 && selectedRange().length <= 2000 && WritingProofreading.enabled
        }
        if menuItem.action == #selector(completeMathCommand(_:)) {
            guard !hasMarkedText(), let context = MathCompletion.context(string, selection: selectedRange()) else { return false }
            return !MathCompletion.suggestions(context).isEmpty
        }
        return super.validateMenuItem(menuItem)
    }
}

private extension NSFont {
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> NSFont { fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var source: String
    let controller: MarkdownEditorController
    let size: CGFloat
    let serif: Bool
    var texTheme: TeXEditorTheme? = nil
    var documentID: String? = nil
    var externalRanges: [NSRange] = []
    var showExternalEdits = false
    func makeNSView(context: Context) -> NSScrollView { controller.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) {
        controller.texTheme = texTheme
        controller.externalRanges = externalRanges; controller.showExternalEdits = showExternalEdits
        let binding = _source
        controller.changed = { binding.wrappedValue = $0 }; controller.update(source, size: size, serif: serif, document: documentID)
    }
}
