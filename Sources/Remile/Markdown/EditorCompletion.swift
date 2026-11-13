import AppKit
import WebKit

/// Local, deterministic completion shared by Markdown mathematics and TeX projects.
enum EditorCompletion {
    struct Item: Equatable { let label: String; let insertion: String; var caret: Int? = nil; var referenceID: UUID? = nil; var detail: String? = nil; var annotation: String? = nil }
    struct Context { let range: NSRange; let items: [Item] }
    static let environments = ["align", "align*", "aligned", "equation", "equation*", "gather", "gather*", "itemize", "enumerate", "description", "figure", "table", "tabular", "cases", "matrix", "pmatrix", "bmatrix", "split", "document", "abstract"]
    private static let texCommands = MathCompletion.commands + ["item ", "includegraphics{}", "includesvg{}", "section{}", "subsection{}", "subsubsection{}", "chapter{}", "part{}", "paragraph{}", "caption{}", "label{}", "ref{}", "eqref{}", "autoref{}", "cref{}", "pageref{}", "cite{}", "citep{}", "citet{}", "parencite{}", "textcite{}", "texttt{}", "emph{}", "input{}", "include{}", "subfile{}", "usepackage{}", "documentclass{}", "bibliography{}", "bibliographystyle{}", "addbibresource{}", "printbibliography", "newcommand{}{}", "renewcommand{}{}", "newenvironment{}{}{}", "DeclareMathOperator{}{}", "title{}", "author{}", "date{}", "maketitle", "tableofcontents", "footnote{}", "url{}", "href{}{}", "centering", "hline", "toprule", "midrule", "bottomrule", "textwidth", "linewidth", "newpage", "clearpage", "vspace{}", "hspace{}"].map { "\\" + $0 }
    private static let commandPrefix = try! NSRegularExpression(pattern: #"(?<!\\)(?:\\\\)*(\\[A-Za-z@]*)$"#)
    private static let environmentPrefix = try! NSRegularExpression(pattern: #"(?<!\\)\\(begin|end)\{([A-Za-z*]*)$"#)

    static func commandRange(_ prefix: String, text: NSString, cursor: Int, explicit: Bool = false) -> NSRange? {
        let length = prefix.utf16.count
        guard let match = commandPrefix.firstMatch(in: prefix, range: NSRange(location: 0, length: length)) else { return nil }
        let commandLength = match.range(at: 1).length
        guard explicit || commandLength > 1 else { return nil }
        if cursor < text.length {
            let next = text.character(at: cursor)
            if (65...90).contains(next) || (97...122).contains(next) || next == 64 { return nil }
        }
        return NSRange(location: cursor - commandLength, length: commandLength)
    }

    static func commandName(_ template: String) -> Substring {
        template.prefix { $0 != "{" && !$0.isWhitespace }
    }

    static func commandItem(_ template: String, text: NSString, cursor: Int, detail: String? = nil) -> Item {
        let name = commandName(template)
        if template.hasSuffix("{}"), cursor < text.length, text.character(at: cursor) == 123 {
            return Item(label: template, insertion: String(name), caret: name.utf16.count + 1, detail: detail)
        }
        return Item(label: template, insertion: template, caret: MathCompletion.insertionSelection(template, location: 0).location, detail: detail)
    }

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
    static func environmentContext(_ names: [String], name: String, text: NSString, cursor: Int, expand: Bool, indent: String, limit: Int) -> Context? {
        let matches = names.filter { $0.hasPrefix(name) }.prefix(limit)
        guard !matches.isEmpty else { return nil }
        let closing = cursor < text.length && text.character(at: cursor) == 125 ? 1 : 0
        let tail = text.substring(with: NSRange(location: cursor + closing, length: min(1000, text.length - cursor - closing)))
        let items = matches.map { environment -> Item in
            let end = "\\end{\(environment)}"
            guard expand, !tail.contains(end) else { return Item(label: environment, insertion: environment + "}") }
            let body = indent + "    " + (["itemize", "enumerate", "description"].contains(environment) ? "\\item " : "")
            let first = environment + "}\n" + body
            return Item(label: environment, insertion: first + "\n" + indent + end, caret: first.utf16.count)
        }
        return Context(range: NSRange(location: cursor - name.utf16.count, length: name.utf16.count + closing), items: items)
    }

    static func context(_ source: String, selection: NSRange, tex: Bool, explicit: Bool = false) -> Context? {
        let value = source as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= value.length else { return nil }
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
        let environment = environmentPrefix.firstMatch(in: prefix, range: NSRange(location: 0, length: units.count))
        let command = commandRange(prefix, text: value, cursor: selection.location, explicit: explicit)
        guard environment != nil || command != nil else { return nil }
        guard tex || (selection.location <= 200_000 && MathCompletion.insideMath(Array(value.substring(to: selection.location).utf16))) else { return nil }
        if let match = environment {
            let raw = prefix as NSString
            let name = raw.substring(with: match.range(at: 2))
            let opening = raw.substring(with: match.range(at: 1)) == "begin"
            let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
            if let context = environmentContext(available, name: name, text: value, cursor: selection.location,
                                                expand: tex && opening, indent: indent, limit: 8) { return context }
        }
        guard let command else { return nil }
        let typed = value.substring(with: command)
        let name = typed.dropFirst()
        var items: [Item] = []
        if "begin".hasPrefix(name), name != "begin" { items.append(Item(label: "\\begin{…}", insertion: selection.location < value.length && value.character(at: selection.location) == 123 ? "\\begin" : "\\begin{}", caret: 7)) }
        for environment in available where name.count >= 2 && environment.hasPrefix(name) {
            let body = ["itemize", "enumerate", "description"].contains(environment) ? "    \\item " : "    "
            let insertion = "\\begin{\(environment)}\n" + body + "\n\\end{\(environment)}"
            items.append(Item(label: environment + " block", insertion: insertion, caret: ("\\begin{\(environment)}\n" + body as NSString).length))
        }
        let commands = tex ? texCommands : MathCompletion.commands
        for template in commands where template.hasPrefix(typed) && template != typed {
            items.append(commandItem(template, text: value, cursor: selection.location))
        }
        guard !items.isEmpty else { return nil }
        items.sort { a, b in
            let aCommand = a.label.hasPrefix("\\"), bCommand = b.label.hasPrefix("\\")
            let aExact = commandName(a.label) == typed, bExact = commandName(b.label) == typed
            if aExact != bExact { return aExact }
            return aCommand == bCommand ? a.label < b.label : aCommand
        }
        return Context(range: command, items: Array(items.prefix(8)))
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
    private var footer: NSView?
    private var mathPreview: CompletionMathPreview?
    private var previewedTemplate: String?
    var visible: Bool { panel?.isVisible == true }
    func show(in view: NSTextView, tex: Bool, custom: EditorCompletion.Context? = nil, prepare: ((EditorCompletion.Item) throws -> Void)? = nil, failure: ((String) -> Void)? = nil, explicit: Bool = false) {
        guard view.window?.firstResponder === view, !view.hasMarkedText(), let context = custom ?? EditorCompletion.context(view.string, selection: view.selectedRange(), tex: tex, explicit: explicit), let window = view.window else { dismiss(); return }
        self.prepare = prepare; self.failure = failure
        self.view = view; self.context = context; source = view.string; caret = view.selectedRange(); index = 0
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = view.effectiveAppearance
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let hasDetails = context.items.contains { $0.detail != nil || $0.annotation != nil }
        let labelWidth = context.items.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = hasDetails ? min(520, max(300, window.frame.width * 0.38)) : min(520, max(180, ceil(labelWidth) + 66))
        panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.backgroundColor = .clear
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 0; stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        buttons = context.items.enumerated().map { number, item in
            let button = NSButton(title: item.label, target: self, action: #selector(choose(_:))); button.tag = number; button.isBordered = false; button.alignment = .left; button.font = font
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true; button.widthAnchor.constraint(equalToConstant: width - 10).isActive = true
            let preview = MathMarkup.completionPreview(item.label)
            let suffix = item.annotation ?? preview
            if let suffix {
                button.title = ""
                let label = CompletionRowLabel(labelWithString: item.label), badge = CompletionRowLabel(labelWithString: suffix)
                label.font = button.font; label.lineBreakMode = .byTruncatingMiddle
                let isMath = item.annotation == nil
                badge.font = .systemFont(ofSize: isMath ? 17 : 11)
                badge.textColor = .secondaryLabelColor; badge.alignment = .right
                for field in [label, badge] { field.translatesAutoresizingMaskIntoConstraints = false; field.setAccessibilityElement(false); button.addSubview(field) }
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10), badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
                    badge.centerYAnchor.constraint(equalTo: button.centerYAnchor), badge.widthAnchor.constraint(equalToConstant: isMath ? 42 : 92)])
            }
            button.toolTip = [item.label, suffix, item.detail].compactMap { $0 }.joined(separator: "\n"); button.setAccessibilityLabel("Complete " + item.label); button.setAccessibilityValue(suffix); stack.addArrangedSubview(button); return button
        }
        let hasMathTemplates = context.items.contains { $0.mathPreviewTemplate != nil }
        let detailHeight: CGFloat = context.items.contains { $0.annotation != nil } ? 104 : 54
        detail = nil
        footer = nil
        previewedTemplate = nil
        if hasDetails || hasMathTemplates {
            let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
            let container = NSView()
            container.widthAnchor.constraint(equalToConstant: width - 18).isActive = true
            container.heightAnchor.constraint(equalToConstant: detailHeight).isActive = true
            stack.addArrangedSubview(container)
            footer = container
        }
        if let footer, hasDetails {
            let field = NSTextField(wrappingLabelWithString: ""); field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor
            field.maximumNumberOfLines = detailHeight > 54 ? 6 : 3
            install(field, in: footer)
            detail = field
        }
        let background = NSVisualEffectView(); background.material = .popover; background.state = .active; background.wantsLayer = true; background.layer?.cornerRadius = 7
        background.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor), stack.topAnchor.constraint(equalTo: background.topAnchor), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        panel.contentView = background
        let rect = view.firstRect(forCharacterRange: caret, actualRange: nil), height = CGFloat(context.items.count * 27 + 10) + (footer == nil ? 0 : detailHeight + 1)
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let below = rect.minY - height - 3
        let y = below >= screen.minY ? below : max(screen.minY, min(rect.maxY + 3, screen.maxY - height))
        panel.setFrame(NSRect(x: min(max(screen.minX, rect.minX), screen.maxX - width), y: y, width: width, height: height), display: false)
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
        guard let context, context.items.indices.contains(index) else { return }
        let item = context.items[index]
        let text = item.detail ?? ""
        detail?.stringValue = text; detail?.toolTip = text
        showMathPreview(item.mathPreviewTemplate)
    }

    private func showMathPreview(_ template: String?) {
        guard let footer else { return }
        if let template, template == previewedTemplate, mathPreview?.superview === footer {
            mathPreview?.isHidden = false
            detail?.isHidden = true
            return
        }
        guard let template, let markup = try? MathMarkup.render(template, display: true) else {
            mathPreview?.isHidden = true
            detail?.isHidden = false
            return
        }
        let web: CompletionMathPreview
        if let mathPreview {
            web = mathPreview
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            web = CompletionMathPreview(frame: .zero, configuration: configuration)
            web.navigationDelegate = web
            web.setAccessibilityLabel("Equation template")
            mathPreview = web
        }
        if web.superview !== footer { install(web, in: footer) }
        let dark = panel?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let html = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        body { margin: 0; height: 100vh; display: grid; place-items: center; overflow: hidden;
               background: Canvas; color: CanvasText; font-size: 22px; }
        math { margin: 0; }
        </style><body>\(markup)</body>
        """
        previewedTemplate = template
        web.display(html)
        web.isHidden = false
        detail?.isHidden = true
    }

    private func install(_ view: NSView, in container: NSView) {
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
    func dismiss() {
        panel?.orderOut(nil)
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel = nil
        context = nil
        view = nil
        source = ""
        caret = NSRange()
        prepare = nil
        failure = nil
        buttons = []
        detail = nil
        footer = nil
        mathPreview = nil
        previewedTemplate = nil
    }
}

private extension EditorCompletion.Item {
    var mathPreviewTemplate: String? {
        guard detail == nil, annotation == nil else { return nil }
        return MathCompletion.previewTemplate(label)
    }
}

private final class CompletionMathPreview: WKWebView, WKNavigationDelegate {
    private var pendingNavigation: WKNavigation?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func display(_ html: String) {
        alphaValue = 0
        pendingNavigation = loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === pendingNavigation else { return }
        pendingNavigation = nil
        alphaValue = 1
    }
}

/// Labels keep the whole completion row clickable.
private final class CompletionRowLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
