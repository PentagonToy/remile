import SwiftUI
import AppKit

@MainActor final class EditorWritingReview: ObservableObject {
    struct Issue: Identifiable { let range: NSRange; let message: String; var replacement: String?; var alternatives: [String] = []; var id: Int { range.location } }
    @Published var issues: [Issue] = []
    @Published var checking = false
    @Published var presented = false
    private var suggestion: NSPopover?
    private var proofreadingTask: Task<Void, Never>?
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
                for result in results.prefix(100) where EditorSpellcheck.accepts(result.range, excluded: excluded) {
                    if result.resultType == .spelling {
                        let choices = NSSpellChecker.shared.guesses(forWordRange: result.range, in: source, language: language == "Automatic" ? nil : language, inSpellDocumentWithTag: tag) ?? []
                        issues.append(.init(range: result.range, message: "Spelling", replacement: choices.first, alternatives: Array(choices.prefix(3))))
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
    func dismissSuggestion() { proofreadingTask?.cancel(); proofreadingTask = nil; suggestion?.close(); suggestion = nil }
    func proofread(_ range: NSRange, in view: NSTextView, editor: MarkdownEditorController) {
        guard range.location != NSNotFound, range.length > 0, range.length <= 2000, NSMaxRange(range) <= (view.string as NSString).length, WritingProofreading.enabled else { return }
        dismissSuggestion()
        let expected = view.string, selected = (view.string as NSString).substring(with: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let state = WritingWordState(); state.title = "Grammar · " + WritingProofreading.provider; state.width = 360
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: WritingWordSuggestion(state: state) { [weak self, weak editor] replacement in
            editor?.replaceWritingIssue(range, with: replacement, source: expected); self?.dismissSuggestion()
        })
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        var anchor = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        anchor.origin.x += view.textContainerOrigin.x; anchor.origin.y += view.textContainerOrigin.y
        anchor = anchor.intersection(view.visibleRect)
        guard !anchor.isEmpty else { return }
        suggestion = popover; popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        guard EditorSpellcheck.accepts(range, excluded: EditorSpellcheck.excluded(expected)) else { state.detail = "Select prose without code, maths or TeX commands."; return }
        state.loading = true
        proofreadingTask = Task { @MainActor [weak self, weak popover, weak view] in
            do {
                let result = try await WritingProofreading.suggest(text: selected)
                let choices = result.choices
                guard !Task.isCancelled, self?.suggestion === popover, view?.string == expected else { return }
                state.title = "Grammar · " + result.provider
                state.choices = Array(choices.filter { !$0.isEmpty && $0 != selected && $0.utf16.count <= 4000 && !$0.contains("\\") && !$0.contains("$") && !$0.lowercased().contains("<source") && !$0.lowercased().contains("</source") }.prefix(3))
                state.loading = false
                state.detail = "No grammar changes suggested."
            } catch {
                guard !Task.isCancelled, self?.suggestion === popover else { return }
                state.loading = false; state.detail = error.localizedDescription
            }
        }
    }

}

struct EditorWritingReviewButton: View {
    @AppStorage("editor.language") private var language = "Automatic"
    @ObservedObject var review: EditorWritingReview
    let editor: MarkdownEditorController
    var reveal: () -> Void = {}
    var body: some View {
        Button { review.presented.toggle() } label: {
            HStack(spacing: 4) { Image(systemName: "text.badge.checkmark"); if !review.issues.isEmpty { Text("\(review.issues.count)").monospacedDigit() } }
        }.remileHelp("Spelling and grammar").accessibilityLabel("Spelling and grammar")
            .popover(isPresented: $review.presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Spelling and grammar").font(RemileType.heading)
                    Picker("Writing language", selection: $language) {
                        Text("Automatic").tag("Automatic")
                        ForEach(NSSpellChecker.shared.availableLanguages.sorted(), id: \.self) { value in Text(EditorLanguageSettings.languageTitle(value)).tag(value) }
                    }
                    if review.checking { ProgressView("Checking…").controlSize(.small) }
                    else if review.issues.isEmpty { Text("No suggestions").foregroundStyle(.secondary) }
                    else { ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(review.issues) { issue in
                                VStack(alignment: .leading, spacing: 5) {
                                    let source = review.source as NSString
                                    let valid = issue.range.location >= 0 && NSMaxRange(issue.range) <= source.length
                                    let phrase = valid ? source.substring(with: issue.range) : issue.message
                                    Button {
                                        reveal()
                                        Task { @MainActor in
                                            await Task.yield()
                                            editor.selectWritingIssue(issue.range, source: review.source)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(phrase).font(RemileType.callout.weight(.medium)).lineLimit(2)
                                            Text(issue.message).font(RemileType.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain).remileHelp("Show in source")
                                    if let replacement = issue.replacement {
                                        Button("Use “\(replacement)”") {
                                            reveal()
                                            Task { @MainActor in
                                                await Task.yield()
                                                editor.replaceWritingIssue(issue.range, with: replacement, source: review.source)
                                                review.presented = false
                                            }
                                        }
                                    }
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
    var width: CGFloat = 220
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
            if state.loading { ProgressView().controlSize(.small).accessibilityLabel("Finding writing suggestions") }
            else if state.choices.isEmpty { Text(state.detail ?? "No suggestions").font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(Array(state.choices.enumerated()), id: \.offset) { _, choice in
                Button { apply(choice) } label: { Text(choice).font(RemileType.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }.padding(14).frame(width: state.width).background(RemileStyle.background)
    }
}
