import AppKit

/// Local, deterministic completion shared by Markdown mathematics and TeX projects.
enum EditorCompletion {
    struct Item: Equatable { let label: String; let insertion: String; var caret: Int? = nil; var referenceID: UUID? = nil; var detail: String? = nil; var annotation: String? = nil }
    struct Context { let range: NSRange; let items: [Item] }
    static let environments = ["align", "align*", "aligned", "equation", "equation*", "gather", "gather*", "itemize", "enumerate", "description", "figure", "table", "tabular", "cases", "matrix", "pmatrix", "bmatrix", "split", "document", "abstract"]
    static func closeEnvironment(_ source: String, selection: NSRange) -> MarkdownEditing.Change? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let line = text.lineRange(for: selection), count = selection.location - line.location
        guard count <= 240 else { return nil }
        let prefix = text.substring(with: NSRange(location: line.location, length: count)) as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)\\begin\{([A-Za-z*]+)$"#), let match = regex.firstMatch(in: prefix as String, range: NSRange(location: 0, length: prefix.length)) else { return nil }
        let name = prefix.substring(with: match.range(at: 2)), indent = prefix.substring(with: match.range(at: 1))
        guard environments.contains(name) else { return nil }
        let closing = selection.location < text.length && text.character(at: selection.location) == 125 ? 1 : 0
        let tail = text.substring(with: NSRange(location: selection.location + closing, length: min(1000, text.length - selection.location - closing)))
        guard !tail.contains("\\end{\(name)}") else { return nil }
        let body = indent + "    " + (["itemize", "enumerate", "description"].contains(name) ? "\\item " : "")
        return .init(range: NSRange(location: selection.location, length: closing), text: "}\n" + body + "\n" + indent + "\\end{\(name)}", selection: NSRange(location: selection.location + 2 + (body as NSString).length, length: 0))
    }
    static func context(_ source: String, selection: NSRange, tex: Bool, explicit: Bool = false) -> Context? {
        let value = source as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= value.length else { return nil }
        guard tex || (selection.location <= 200_000 && MathCompletion.insideMath(Array(value.substring(to: selection.location).utf16))) else { return nil }
        let available = tex ? environments : ["align", "aligned", "cases", "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "gathered", "smallmatrix"]
        let start = max(0, selection.location - 240)
        let line = value.substring(with: NSRange(location: start, length: selection.location - start))
        let prefix = line.components(separatedBy: "\n").last ?? ""
        // Avoid comments and escaped commands; only inspect a small line suffix during typing.
        let units = Array(prefix.utf16)
        for i in units.indices where units[i] == 37 {
            var slash = i
            while slash > 0 && units[slash - 1] == 92 { slash -= 1 }
            if (i - slash).isMultiple(of: 2) { return nil }
        }
        if let expression = try? NSRegularExpression(pattern: #"\\(?:begin|end)\{([A-Za-z*]*)$"#), let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
            let raw = prefix as NSString, name = raw.substring(with: match.range(at: 1))
            let closing = selection.location < value.length && value.character(at: selection.location) == 125 ? 1 : 0
            let opening = prefix.contains("\\begin{")
            let tail = value.substring(with: NSRange(location: selection.location + closing, length: min(1000, value.length - selection.location - closing)))
            let items = available.filter { $0.hasPrefix(name) }.map { environment -> Item in
                guard tex, opening, !tail.contains("\\end{\(environment)}") else { return Item(label: environment, insertion: environment + "}") }
                let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
                let body = indent + "    " + (["itemize", "enumerate", "description"].contains(environment) ? "\\item " : "")
                let first = environment + "}\n" + body
                return Item(label: environment, insertion: first + "\n" + indent + "\\end{\(environment)}", caret: (first as NSString).length)
            }
            if !items.isEmpty { return Context(range: NSRange(location: selection.location - (name as NSString).length, length: (name as NSString).length + closing), items: Array(items.prefix(8))) }
        }
        var begin = units.count
        while begin > 0 && ((65...90).contains(units[begin - 1]) || (97...122).contains(units[begin - 1])) { begin -= 1 }
        let name = String(decoding: units[begin...], as: UTF16.self)
        guard name.count >= 2 || (explicit && begin > 0 && units[begin - 1] == 92) else { return nil }
        let hasSlash = begin > 0 && units[begin - 1] == 92
        if hasSlash { begin -= 1; if begin > 0 && units[begin - 1] == 92 { return nil } }
        guard hasSlash else { return nil }
        if selection.location < value.length {
            let next = value.character(at: selection.location)
            if (65...90).contains(next) || (97...122).contains(next) { return nil }
        }
        var items: [Item] = []
        if "begin".hasPrefix(name), name != "begin" { items.append(Item(label: "\\begin{…}", insertion: selection.location < value.length && value.character(at: selection.location) == 123 ? "\\begin" : "\\begin{}", caret: 7)) }
        for environment in available where name.count >= 2 && environment.hasPrefix(name) {
            let body = ["itemize", "enumerate", "description"].contains(environment) ? "    \\item " : "    "
            let insertion = "\\begin{\(environment)}\n" + body + "\n\\end{\(environment)}"
            items.append(Item(label: environment + " block", insertion: insertion, caret: ("\\begin{\(environment)}\n" + body as NSString).length))
        }
        let commands = MathCompletion.commands + (tex ? ["item ", "includegraphics{}", "section{}", "subsection{}", "subsubsection{}", "chapter{}", "part{}", "paragraph{}", "caption{}", "label{}", "ref{}", "eqref{}", "autoref{}", "cref{}", "pageref{}", "cite{}", "citep{}", "citet{}", "parencite{}", "textcite{}", "textbf{}", "textit{}", "texttt{}", "emph{}", "input{}", "include{}", "usepackage{}", "documentclass{}", "bibliography{}", "bibliographystyle{}", "addbibresource{}", "printbibliography", "newcommand{}{}", "renewcommand{}{}", "newenvironment{}{}{}", "DeclareMathOperator{}{}", "title{}", "author{}", "date{}", "maketitle", "tableofcontents", "footnote{}", "url{}", "href{}{}", "centering", "hline", "toprule", "midrule", "bottomrule", "textwidth", "linewidth", "newpage", "clearpage", "vspace{}", "hspace{}"].map { "\\" + $0 } : [])
        for command in commands where command.dropFirst().hasPrefix(name) && command != "\\" + name {
            var insertion = command
            let existingArguments = selection.location < value.length && value.character(at: selection.location) == 123
            if existingArguments { while insertion.hasSuffix("{}") { insertion.removeLast(2) } }
            items.append(Item(label: command, insertion: insertion, caret: existingArguments ? (insertion as NSString).length + 1 : MathCompletion.insertionSelection(insertion, location: 0).location))
        }
        guard !items.isEmpty else { return nil }
        items.sort { a, b in
            let aCommand = a.label.hasPrefix("\\"), bCommand = b.label.hasPrefix("\\")
            return aCommand == bCommand ? a.label < b.label : aCommand
        }
        return Context(range: NSRange(location: selection.location - (units.count - begin), length: units.count - begin), items: Array(items.prefix(8)))
    }
}

@MainActor final class EditorCompletionPanel: NSObject {
    private var panel: NSPanel?
    private weak var view: NSTextView?
    private var context: EditorCompletion.Context?
    private var source = ""
    private var caret = NSRange()
    private var index = 0
    private var prepare: ((EditorCompletion.Item) throws -> Void)?
    private var failure: ((String) -> Void)?
    private var buttons: [NSButton] = []
    private var detail: NSTextField?
    var visible: Bool { panel?.isVisible == true }
    func show(in view: NSTextView, tex: Bool, custom: EditorCompletion.Context? = nil, prepare: ((EditorCompletion.Item) throws -> Void)? = nil, failure: ((String) -> Void)? = nil, explicit: Bool = false) {
        guard view.window?.firstResponder === view, !view.hasMarkedText(), let context = custom ?? EditorCompletion.context(view.string, selection: view.selectedRange(), tex: tex, explicit: explicit), let window = view.window else { dismiss(); return }
        self.prepare = prepare; self.failure = failure
        self.view = view; self.context = context; source = view.string; caret = view.selectedRange(); index = 0
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = view.effectiveAppearance
        let width = min(520, max(300, window.frame.width * 0.38))
        panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.backgroundColor = .clear
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0; stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        buttons = context.items.enumerated().map { number, item in
            let button = NSButton(title: item.label, target: self, action: #selector(choose(_:))); button.tag = number; button.isBordered = false; button.alignment = .left; button.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true; button.widthAnchor.constraint(equalToConstant: width - 10).isActive = true
            if let annotation = item.annotation {
                button.title = ""
                let label = CompletionRowLabel(labelWithString: item.label), badge = CompletionRowLabel(labelWithString: annotation)
                label.font = button.font; label.lineBreakMode = .byTruncatingMiddle
                badge.font = .systemFont(ofSize: 11); badge.textColor = .secondaryLabelColor
                for field in [label, badge] { field.translatesAutoresizingMaskIntoConstraints = false; field.setAccessibilityElement(false); button.addSubview(field) }
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10), badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
                    badge.centerYAnchor.constraint(equalTo: button.centerYAnchor), badge.widthAnchor.constraint(equalToConstant: 92)])
            }
            button.toolTip = [item.label, item.annotation, item.detail].compactMap { $0 }.joined(separator: "\n"); button.setAccessibilityLabel("Complete " + item.label); button.setAccessibilityValue(item.annotation); stack.addArrangedSubview(button); return button
        }
        let detailHeight: CGFloat = context.items.contains { $0.annotation != nil } ? 104 : 54
        detail = nil
        if context.items.contains(where: { $0.detail != nil }) {
            let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
            let field = NSTextField(wrappingLabelWithString: ""); field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor
            field.maximumNumberOfLines = detailHeight > 54 ? 6 : 3; field.widthAnchor.constraint(equalToConstant: width - 18).isActive = true
            field.heightAnchor.constraint(equalToConstant: detailHeight).isActive = true
            stack.addArrangedSubview(field); detail = field
        }
        let background = NSVisualEffectView(); background.material = .popover; background.state = .active; background.wantsLayer = true; background.layer?.cornerRadius = 7
        background.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor), stack.topAnchor.constraint(equalTo: background.topAnchor), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        panel.contentView = background
        let rect = view.firstRect(forCharacterRange: caret, actualRange: nil), height = CGFloat(context.items.count * 27 + 10) + (detail == nil ? 0 : detailHeight + 1)
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: min(max(screen.minX, rect.minX), screen.maxX - width), y: max(screen.minY, rect.minY - height - 3), width: width, height: height), display: false)
        if self.panel !== panel { window.addChildWindow(panel, ordered: .above); self.panel = panel }
        refresh(); panel.orderFront(nil)
    }
    func key(_ event: NSEvent) -> Bool {
        guard visible, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125: index = min(buttons.count - 1, index + 1); refresh(); return true
        case 126: index = max(0, index - 1); refresh(); return true
        case 36, 48: accept(); return true
        case 53: dismiss(); return true
        default: return false
        }
    }
    private func refresh() {
        for (number, button) in buttons.enumerated() { button.contentTintColor = .labelColor; button.wantsLayer = true; button.layer?.backgroundColor = (number == index ? NSColor(RemileStyle.accent).withAlphaComponent(0.18) : .clear).cgColor; button.layer?.cornerRadius = 4 }
        let text = context?.items.indices.contains(index) == true ? context?.items[index].detail ?? "" : ""
        detail?.stringValue = text; detail?.toolTip = text
    }
    @objc private func choose(_ button: NSButton) { index = button.tag; accept() }
    private func accept() {
        guard let view, let context, context.items.indices.contains(index), view.string == source, view.selectedRange() == caret, !view.hasMarkedText() else { dismiss(); return }
        let item = context.items[index]
        do { try prepare?(item) } catch { failure?(error.localizedDescription); dismiss(); return }
        dismiss()
        view.window?.makeFirstResponder(view); view.breakUndoCoalescing(); view.insertText(item.insertion, replacementRange: context.range)
        view.setSelectedRange(NSRange(location: context.range.location + (item.caret ?? (item.insertion as NSString).length), length: 0)); view.undoManager?.setActionName("Complete TeX"); view.breakUndoCoalescing()
    }
    func dismiss() { panel?.orderOut(nil); if let panel { panel.parent?.removeChildWindow(panel) }; panel = nil; context = nil; prepare = nil; failure = nil; buttons = []; detail = nil }
}

/// Labels keep the whole completion row clickable.
private final class CompletionRowLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
