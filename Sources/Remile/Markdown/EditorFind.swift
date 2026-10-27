import AppKit
import SwiftUI

/// One bounded search result over an immutable editor snapshot. No background work while closed.
enum EditorFindEngine {
    static let sourceLimit = 4_000_000
    static let matchLimit = 20_000
    struct Options: Equatable { var caseSensitive = false; var regularExpression = false; var wholeWord = false }
    struct Result {
        let source: String
        let expression: NSRegularExpression?
        let matches: [NSTextCheckingResult]
        let truncated: Bool
        let error: String?
    }
    static func search(_ source: String, query: String, options: Options) -> Result {
        func failure(_ message: String) -> Result { .init(source: "", expression: nil, matches: [], truncated: false, error: message) }
        guard !query.isEmpty else { return .init(source: "", expression: nil, matches: [], truncated: false, error: nil) }
        let text = source as NSString
        guard text.length <= sourceLimit, query.utf16.count <= 2000 else { return failure("Use a shorter document or search term.") }
        var pattern = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = #"(?<![\p{L}\p{N}_])(?:"# + pattern + #")(?![\p{L}\p{N}_])"# }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive]) else { return failure("Check the regular expression.") }
        var matches: [NSTextCheckingResult] = [], truncated = false, stopped = false
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        expression.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: text.length)) { match, _, stop in
            if Task.isCancelled || ContinuousClock.now > deadline { stopped = true; stop.pointee = true; return }
            if let match {
                if matches.count == matchLimit { truncated = true; stop.pointee = true }
                else { matches.append(match) }
            }
        }
        if stopped { return failure("Search took too long. Try a simpler expression.") }
        return .init(source: source, expression: expression, matches: matches, truncated: truncated, error: nil)
    }
    static func replacingAll(_ result: Result, replacement: String, regex: Bool) -> String? {
        guard !result.truncated, result.error == nil, replacement.utf16.count <= 2000 else { return nil }
        let source = result.source as NSString, output = NSMutableString(capacity: (result.source as NSString).length), limit = sourceLimit * 2
        var location = 0
        for match in result.matches {
            guard !Task.isCancelled else { return nil }
            output.append(source.substring(with: NSRange(location: location, length: match.range.location - location)))
            output.append(Self.replacement(replacement, match: match, result: result, regex: regex))
            guard output.length <= limit else { return nil }
            location = NSMaxRange(match.range)
        }
        guard output.length + source.length - location <= limit else { return nil }
        output.append(source.substring(from: location))
        return output as String
    }
    static func replacement(_ replacement: String, match: NSTextCheckingResult, result: Result, regex: Bool) -> String {
        regex ? result.expression!.replacementString(for: match, in: result.source, offset: 0, template: replacement) : replacement
    }
}

@MainActor final class EditorFindState: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published var replacement = ""
    @Published var options = EditorFindEngine.Options() { didSet { schedule() } }
    @Published var visible = false
    @Published var showsReplace = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var count = 0
    @Published private(set) var current = -1
    @Published private(set) var truncated = false
    @Published private(set) var focus = UUID()
    weak var view: NSTextView?
    var layoutChanged: (() -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var result: EditorFindEngine.Result?
    var countLabel: String { busy ? "Searching…" : truncated ? "20,000+" : count == 0 ? "0 matches" : "\(current + 1) / \(count)" }
    var canReplace: Bool { !busy && result?.source == view?.string && count > 0 && view?.isEditable == true && view?.hasMarkedText() == false }
    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .hideFindInterface: close()
        case .hideReplaceInterface: showsReplace = false; layoutChanged?()
        case .showFindInterface, .showReplaceInterface:
            visible = true
            showsReplace = action == .showReplaceInterface || showsReplace
            layoutChanged?(); focus = UUID(); schedule()
        case .nextMatch: move(1)
        case .previousMatch: move(-1)
        case .setSearchString:
            if let view, view.selectedRange().length > 0, view.selectedRange().length <= 2000 {
                query = (view.string as NSString).substring(with: view.selectedRange())
            }
        case .replace: replace(all: false)
        case .replaceAll: replace(all: true)
        case .replaceAndFind: replace(all: false)
        default: break
        }
    }
    func close() {
        task?.cancel(); task = nil; generation = UUID()
        visible = false; busy = false; result = nil; count = 0; current = -1; error = nil
        layoutChanged?()
        if let view { view.window?.makeFirstResponder(view) }
    }
    func sourceChanged() { if visible { schedule() } }
    func toggleReplace() { showsReplace.toggle(); layoutChanged?() }
    private func schedule() {
        task?.cancel(); generation = UUID(); result = nil; error = nil; count = 0; current = -1; truncated = false
        guard visible, let view, !query.isEmpty else { busy = false; return }
        busy = true
        let source = view.string, query = query, options = options, generation = generation
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let work = Task.detached(priority: .userInitiated) { EditorFindEngine.search(source, query: query, options: options) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.generation == generation, self.view?.string == source else { return }
            self.busy = false; self.result = result; self.error = result.error; self.count = result.matches.count; self.truncated = result.truncated
            let caret = self.view?.selectedRange().location ?? 0
            self.current = result.matches.firstIndex(where: { $0.range.location >= caret }) ?? (result.matches.isEmpty ? -1 : 0)
            self.reveal()
        }
    }
    func move(_ offset: Int) {
        guard !busy, let result, result.source == view?.string, count > 0 else { return }
        current = (current + offset + count) % count; reveal()
    }
    private func reveal() {
        guard let result, result.matches.indices.contains(current), let view, view.string == result.source else { return }
        let range = result.matches[current].range
        view.setSelectedRange(range); view.scrollRangeToVisible(range)
    }
    func replace(all: Bool) {
        guard canReplace, let result, let view else { return }
        if all && truncated { error = "Narrow the search before replacing all matches."; return }
        guard !all || !result.matches.isEmpty, result.matches.indices.contains(current) else { return }
        if all {
            task?.cancel(); generation = UUID(); let generation = generation
            let replacement = replacement, regex = options.regularExpression
            busy = true
            task = Task { @MainActor [weak self] in
                let work = Task.detached(priority: .userInitiated) { EditorFindEngine.replacingAll(result, replacement: replacement, regex: regex) }
                let text = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.busy = false
                guard let view = self.view, view.string == result.source else { self.sourceChanged(); return }
                guard let text else { self.error = "Use a shorter replacement or a narrower search."; return }
                self.apply(text, range: NSRange(location: 0, length: (result.source as NSString).length), all: true, to: view)
            }
        } else {
            let match = result.matches[current]
            let text = EditorFindEngine.replacement(replacement, match: match, result: result, regex: options.regularExpression)
            guard text.utf16.count <= EditorFindEngine.sourceLimit else { error = "Use a shorter replacement."; return }
            apply(text, range: match.range, all: false, to: view)
        }
    }
    private func apply(_ text: String, range: NSRange, all: Bool, to view: NSTextView) {
        view.window?.makeFirstResponder(view)
        view.breakUndoCoalescing(); view.insertText(text, replacementRange: range)
        view.undoManager?.setActionName(all ? "Replace All" : "Replace"); view.breakUndoCoalescing()
        sourceChanged()
    }
}

struct EditorFindBar: View {
    @ObservedObject var state: EditorFindState
    @FocusState private var queryFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            GeometryReader { geometry in
                searchRow(compact: geometry.size.width < 560)
            }.frame(height: 40)
            if state.showsReplace {
                HStack(spacing: RemileControl.spacing) {
                    TextField("Replace with", text: $state.replacement).textFieldStyle(.roundedBorder).accessibilityLabel("Replace with").onSubmit { state.replace(all: false) }
                    Button("Replace") { state.replace(all: false) }.disabled(!state.canReplace)
                    Button("Replace All") { state.replace(all: true) }.disabled(!state.canReplace || state.truncated)
                }.padding(.horizontal, RemileControl.spacing).frame(height: 36)
            }
            if let error = state.error { Text(error).font(RemileType.small).foregroundStyle(RemileStyle.warning).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, RemileControl.spacing).frame(height: 24) }
        }.font(RemileType.control).buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink).tint(RemileStyle.ink).background(RemileStyle.editorBar)
            .onAppear { queryFocused = true }.onChange(of: state.focus) { _, _ in queryFocused = true }
            .onChange(of: state.error) { _, _ in state.layoutChanged?() }.onExitCommand { state.close() }
    }
    private func searchRow(compact: Bool) -> some View {
        HStack(spacing: RemileControl.spacing) {
                TextField("Find in document", text: $state.query).textFieldStyle(.roundedBorder).focused($queryFocused)
                    .accessibilityLabel("Find in document").onSubmit { state.move(1) }
                if !compact { HStack(spacing: 0) {
                    mode("Aa", selected: state.options.caseSensitive, help: "Match case") { state.options.caseSensitive.toggle() }
                    mode(".*", selected: state.options.regularExpression, help: "Use a regular expression") { state.options.regularExpression.toggle() }
                    mode("W", selected: state.options.wholeWord, help: "Match whole words") { state.options.wholeWord.toggle() }
                }
                }
                if compact {
                    Menu {
                        Toggle("Match case", isOn: $state.options.caseSensitive)
                        Toggle("Use a regular expression", isOn: $state.options.regularExpression)
                        Toggle("Match whole words", isOn: $state.options.wholeWord)
                        Toggle("Show replace", isOn: $state.showsReplace).onChange(of: state.showsReplace) { _, _ in state.layoutChanged?() }
                    } label: { SymbolIcon(systemName: "slider.horizontal.3") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Search options")
                } else {
                Button { state.toggleReplace() } label: { SymbolIcon(systemName: "arrow.left.arrow.right") }.accessibilityLabel("Show or hide replace").remileHelp("Show or hide replace")
                }
                Divider().frame(height: RemileControl.separatorHeight)
                Button { state.move(-1) } label: { SymbolIcon(systemName: "chevron.up") }.accessibilityLabel("Previous match").disabled(state.count == 0)
                Button { state.move(1) } label: { SymbolIcon(systemName: "chevron.down") }.accessibilityLabel("Next match").disabled(state.count == 0)
                Text(state.countLabel).font(RemileType.small).monospacedDigit().foregroundStyle(RemileStyle.secondaryInk).frame(minWidth: 64)
                Button { state.close() } label: { SymbolIcon(systemName: "xmark") }.accessibilityLabel("Close find").remileHelp("Close find · Escape")
            }.padding(.horizontal, RemileControl.spacing).frame(height: 40)
    }
    private func mode(_ title: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
            .background(selected ? RemileStyle.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .accessibilityLabel(help).accessibilityValue(selected ? "On" : "Off").remileHelp(help)
    }
}
