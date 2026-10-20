import SwiftUI
import AppKit

@MainActor final class EditorWritingReview: ObservableObject {
    struct Issue: Identifiable { let range: NSRange; let message: String; let replacement: String?; var alternatives: [String] = []; var id: Int { range.location } }
    @Published var issues: [Issue] = []
    @Published var checking = false
    @Published var presented = false
    private var suggestion: NSPopover?
    private var synonymTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var source = ""
    func check(_ source: String, enabled: Bool, language: String, editor: MarkdownEditorController) async {
        dismissSuggestion()
        let token = UUID(); generation = token; self.source = source
        issues = []; editor.writingRanges = []; checking = enabled
        guard enabled, !source.isEmpty else { checking = false; editor.writingRanges = []; return }
        do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
        guard !Task.isCancelled else { return }
        let excluded = EditorSpellcheck.excluded(source), masked = NSMutableString(string: source)
        for range in excluded { masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length)) }
        var options: [NSSpellChecker.OptionKey: Any] = [:]
        if language != "Automatic" { options[.orthography] = NSOrthography.defaultOrthography(forLanguage: language) }
        let text = masked as String
        let tag = editor.textView?.spellCheckerDocumentTag ?? 0
        NSSpellChecker.shared.requestChecking(of: text, range: NSRange(location: 0, length: masked.length), types: NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue, options: options, inSpellDocumentWithTag: tag) { [weak self, weak editor] _, results, _, _ in
            Task { @MainActor in
                guard let self, self.generation == token, let editor else { return }
                var issues: [Issue] = []
                for result in results where EditorSpellcheck.accepts(result.range, excluded: excluded) {
                    if result.resultType == .spelling {
                        let replacements = NSSpellChecker.shared.guesses(forWordRange: result.range, in: source, language: language == "Automatic" ? nil : language, inSpellDocumentWithTag: tag) ?? []
                        issues.append(.init(range: result.range, message: "Spelling", replacement: replacements.first, alternatives: Array(replacements.prefix(3))))
                    } else if result.resultType == .grammar {
                        for detail in result.grammarDetails ?? [] {
                            guard let relative = detail[NSGrammarRange] as? NSValue else { continue }
                            let range = NSRange(location: result.range.location + relative.rangeValue.location, length: relative.rangeValue.length)
                            guard NSMaxRange(range) <= (source as NSString).length, EditorSpellcheck.accepts(range, excluded: excluded) else { continue }
                            issues.append(.init(range: range, message: "Grammar", replacement: (detail[NSGrammarCorrections] as? [String])?.first, alternatives: Array(((detail[NSGrammarCorrections] as? [String]) ?? []).prefix(3))))
                        }
                    }
                }
                for range in EditorSpellcheck.sentenceOpenings(source) where !issues.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    let word = (source as NSString).substring(with: range)
                    issues.append(.init(range: range, message: "Grammar", replacement: word.prefix(1).uppercased() + word.dropFirst()))
                }
                var seen = Set<Int>()
                self.issues = Array(issues.sorted { $0.range.location < $1.range.location }.filter { seen.insert($0.range.location).inserted }.prefix(100))
                self.checking = false; editor.writingRanges = self.issues.map(\.range)
            }
        }
    }
    func dismissSuggestion() { synonymTask?.cancel(); synonymTask = nil; suggestion?.close(); suggestion = nil }
    func showSuggestion(at range: NSRange, in view: NSTextView, editor: MarkdownEditorController) -> Bool {
        guard view.string == source, !checking, view.window != nil else { return false }
        let issue = issues.first(where: { NSLocationInRange(range.location, $0.range) || NSIntersectionRange($0.range, range).length > 0 })
        let word = issue == nil ? EditorSynonyms.word(at: range.location, in: source) : nil
        guard issue != nil || (word != nil && UserDefaults.standard.string(forKey: "assistant.provider") != "Off") else { return false }
        if let word, issues.contains(where: { NSIntersectionRange(word.range, $0.range).length > 0 }) { return false }
        dismissSuggestion()
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let state = WritingWordState()
        state.title = issue?.message ?? "Synonyms"
        state.choices = issue.map { $0.alternatives.isEmpty ? $0.replacement.map { [$0] } ?? [] : $0.alternatives } ?? []
        let target = issue?.range ?? word!.range, expected = source
        popover.contentViewController = NSHostingController(rootView: WritingWordSuggestion(state: state) { [weak self, weak editor] replacement in
            guard let self else { return }
            editor?.replaceWritingIssue(target, with: replacement, source: expected); self.dismissSuggestion()
        })
        guard let layout = view.layoutManager, let container = view.textContainer else { return false }
        let glyphs = layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        var anchor = layout.boundingRect(forGlyphRange: glyphs, in: container)
        anchor.origin.x += view.textContainerOrigin.x; anchor.origin.y += view.textContainerOrigin.y
        let visible = view.visibleRect
        let centre = max(visible.minX + 118, min(visible.maxX - 118, anchor.midX))
        anchor.origin.x = centre - anchor.width / 2
        suggestion = popover; popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        let wantsGPT = UserDefaults.standard.string(forKey: "assistant.provider") == "ChatGPT" && (UserDefaults.standard.object(forKey: issue == nil ? "chatgpt.synonyms" : "chatgpt.grammar") as? Bool ?? true) && AIUsage.shared.reason == nil
        if wantsGPT || word != nil {
            state.loading = true
            synonymTask = Task { @MainActor [weak self, weak popover] in
                do {
                    let choices: [String]
                    if wantsGPT {
                        let raw = expected as NSString, start = max(0, target.location - 240), end = min(raw.length, NSMaxRange(target) + 240)
                        let context = raw.substring(with: NSRange(location: start, length: end - start))
                        choices = try await WritingAlternatives.choices(text: raw.substring(with: target), context: context, correction: issue != nil)
                    } else if let word { choices = try await EditorSynonyms.suggest(word) }
                    else { choices = [] }
                    guard !Task.isCancelled, self?.suggestion === popover else { return }
                    if !choices.isEmpty { state.choices = choices }; state.loading = false
                } catch {
                    guard !Task.isCancelled, self?.suggestion === popover else { return }
                    if let word, let choices = try? await EditorSynonyms.suggest(word) { state.choices = choices }
                    state.loading = false; state.detail = state.choices.isEmpty ? "No suggestions" : nil
                }
            }
        }
        return true
    }

}

struct EditorWritingReviewButton: View {
    @ObservedObject var review: EditorWritingReview
    let editor: MarkdownEditorController
    var body: some View {
        Button { review.presented.toggle() } label: {
            HStack(spacing: 4) { Image(systemName: "text.badge.checkmark"); if !review.issues.isEmpty { Text("\(review.issues.count)").monospacedDigit() } }
        }.remileHelp("Spelling and grammar").accessibilityLabel("Spelling and grammar")
            .popover(isPresented: $review.presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Spelling and grammar").font(RemileType.heading)
                    if review.checking { ProgressView("Checking…").controlSize(.small) }
                    else if review.issues.isEmpty { Text("No suggestions").foregroundStyle(.secondary) }
                    else { ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(review.issues) { issue in
                                VStack(alignment: .leading, spacing: 5) {
                                    Button(issue.message) { editor.selectWritingIssue(issue.range, source: review.source) }.buttonStyle(.plain)
                                    if let replacement = issue.replacement { Button("Use “\(replacement)”") { editor.replaceWritingIssue(issue.range, with: replacement, source: review.source); review.presented = false } }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 280) }
                }.padding(18).frame(width: 320).background(RemileStyle.background)
            }
    }
}

@MainActor private final class WritingWordState: ObservableObject {
    @Published var title = ""
    @Published var choices: [String] = []
    @Published var loading = false
    @Published var detail: String?
}
private struct WritingWordSuggestion: View {
    @ObservedObject var state: WritingWordState
    let apply: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title).font(RemileType.caption).foregroundStyle(.secondary)
            if state.loading { ProgressView().controlSize(.small).accessibilityLabel("Finding synonyms") }
            else if state.choices.isEmpty { Text(state.detail ?? "No suggestions").font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(state.choices.enumerated()), id: \.offset) { _, choice in
                Button { apply(choice) } label: { Text(choice).font(RemileType.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }.padding(14).frame(width: 220).background(RemileStyle.background)
    }
}
