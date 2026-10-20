import SwiftUI
import AppKit

@MainActor final class EditorWritingReview: ObservableObject {
    struct Issue: Identifiable { let range: NSRange; let message: String; let replacement: String?; var id: Int { range.location } }
    @Published var issues: [Issue] = []
    @Published var checking = false
    @Published var presented = false
    private var generation = UUID()
    private(set) var source = ""
    func check(_ source: String, enabled: Bool, language: String, editor: MarkdownEditorController) async {
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
                        let replacement = NSSpellChecker.shared.guesses(forWordRange: result.range, in: source, language: language == "Automatic" ? nil : language, inSpellDocumentWithTag: tag)?.first
                        issues.append(.init(range: result.range, message: "Check spelling", replacement: replacement))
                    } else if result.resultType == .grammar {
                        for detail in result.grammarDetails ?? [] {
                            guard let relative = detail[NSGrammarRange] as? NSValue else { continue }
                            let range = NSRange(location: result.range.location + relative.rangeValue.location, length: relative.rangeValue.length)
                            guard NSMaxRange(range) <= (source as NSString).length, EditorSpellcheck.accepts(range, excluded: excluded) else { continue }
                            issues.append(.init(range: range, message: detail[NSGrammarUserDescription] as? String ?? "Check grammar", replacement: (detail[NSGrammarCorrections] as? [String])?.first))
                        }
                    }
                }
                for range in EditorSpellcheck.sentenceOpenings(source) where !issues.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    let word = (source as NSString).substring(with: range)
                    issues.append(.init(range: range, message: "Capitalise the sentence opening", replacement: word.prefix(1).uppercased() + word.dropFirst()))
                }
                var seen = Set<Int>()
                self.issues = Array(issues.sorted { $0.range.location < $1.range.location }.filter { seen.insert($0.range.location).inserted }.prefix(100))
                self.checking = false; editor.writingRanges = self.issues.map(\.range)
            }
        }
    }
}

struct EditorWritingReviewButton: View {
    @ObservedObject var review: EditorWritingReview
    let editor: MarkdownEditorController
    var body: some View {
        Button { review.presented.toggle() } label: {
            HStack(spacing: 4) { Image(systemName: "text.badge.checkmark"); if !review.issues.isEmpty { Text("\(review.issues.count)").monospacedDigit() } }
        }.help("Spelling and grammar").accessibilityLabel("Spelling and grammar")
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
