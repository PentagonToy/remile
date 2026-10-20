import AppKit
import PDFKit

/// An owned selection, captured when the menu opens rather than when an action runs.
@MainActor
struct PDFSelectionContext {
    let document: PDFDocument
    let selection: PDFSelection
    let text: String
    let pageIndices: [Int]

    init?(selection: PDFSelection?, document: PDFDocument?) {
        guard let document, !document.isLocked, let original = selection,
              let selection = original.copy() as? PDFSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !selection.pages.isEmpty, selection.pages.allSatisfy({ $0.document === document }) else { return nil }
        let indices = selection.pages.map { document.index(for: $0) }
        guard indices.allSatisfy({ $0 != NSNotFound && $0 >= 0 && $0 < document.pageCount }) else { return nil }
        self.document = document; self.selection = selection; self.text = text
        pageIndices = indices.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    func isValid(in view: PDFView) -> Bool {
        view.document === document && !document.isLocked && !selection.pages.isEmpty &&
        selection.pages.allSatisfy { page in
            page.document === document && document.index(for: page) != NSNotFound
        } && selection.pages.map { document.index(for: $0) }.reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        } == pageIndices
    }
}

/// Callers own persistence and presentation; these actions never write a PDF themselves.
@MainActor
struct PDFSelectionActions {
    var highlight: ((PDFSelectionContext, HighlightColor) -> Void)?
    var addNote: ((PDFSelectionContext) -> Void)?
    var ask: ((PDFSelectionContext) -> Void)?
    var translate: ((PDFSelectionContext) -> Void)?
    var canAnnotate: ((PDFSelectionContext) -> Bool)?
}

/// Reader and Search use the same explicit native menu, without swizzling PDFKit.
@MainActor
final class PDFSelectionView: PDFView {
    var selectionActions = PDFSelectionActions()

    override func menu(for event: NSEvent) -> NSMenu? {
        if PDFSelectionContext(selection: currentSelection, document: document) == nil {
            let point = convert(event.locationInWindow, from: nil)
            if let page = page(for: point, nearest: false), page.document === document,
               let word = page.selectionForWord(at: convert(point, to: page)) {
                setCurrentSelection(word, animate: false)
            }
        }
        return selectionMenu(for: currentSelection)
    }

    func selectionMenu(for selection: PDFSelection?) -> NSMenu {
        let context = PDFSelectionContext(selection: selection, document: document)
        let menu = NSMenu(title: "Selection"); menu.autoenablesItems = false
        menu.addItem(item("Copy", action: .copy, context: context))
        menu.addItem(.separator())
        let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
        let colours = NSMenu(title: "Highlight"); colours.autoenablesItems = false
        for colour in HighlightColor.allCases {
            let option = item(colour.name, action: .highlight(colour), context: context)
            option.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                colour.color.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill(); return true
            }
            option.image?.isTemplate = false
            colours.addItem(option)
        }
        highlight.submenu = colours; highlight.isEnabled = colours.items.contains { $0.isEnabled }
        menu.addItem(highlight)
        menu.addItem(item("Add Note…", action: .note, context: context))
        menu.addItem(.separator())
        menu.addItem(item("Ask about Selection (on-device)", action: .ask, context: context))
        menu.addItem(item("Translate Selection…", action: .translate, context: context))
        return menu
    }

    private func item(_ title: String, action: SelectionCommand.Action, context: PDFSelectionContext?) -> NSMenuItem {
        let command = SelectionCommand(view: self, context: context, action: action)
        let item = NSMenuItem(title: title, action: #selector(SelectionCommand.invoke(_:)), keyEquivalent: "")
        item.target = command
        // NSMenuItem.target is weak. Ownership belongs to the menu item, not a process-wide registry.
        item.representedObject = command; item.isEnabled = command.isEnabled
        return item
    }
}

@MainActor
private final class SelectionCommand: NSObject {
    enum Action { case copy, highlight(HighlightColor), note, ask, translate }
    weak var view: PDFSelectionView?
    let context: PDFSelectionContext?
    let action: Action
    init(view: PDFSelectionView, context: PDFSelectionContext?, action: Action) {
        self.view = view; self.context = context; self.action = action
    }
    var isEnabled: Bool {
        guard let view, let context, context.isValid(in: view), context.document.allowsCopying else { return false }
        switch action {
        case .copy: return true
        case .ask: return view.selectionActions.ask != nil
        case .translate: return view.selectionActions.translate != nil
        case .highlight, .note:
            guard !context.document.isEncrypted, context.document.allowsCommenting,
                  view.selectionActions.canAnnotate?(context) ?? true else { return false }
            if case .note = action { return view.selectionActions.addNote != nil }
            return view.selectionActions.highlight != nil
        }
    }
    @objc func invoke(_ sender: NSMenuItem) {
        // Recheck identity and permissions even if the menu was enabled before a document changed.
        guard isEnabled, let view, let context else { return }
        switch action {
        case .copy:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(context.selection.string ?? context.text, forType: .string)
        case .highlight(let colour): view.selectionActions.highlight?(context, colour)
        case .note: view.selectionActions.addNote?(context)
        case .ask: view.selectionActions.ask?(context)
        case .translate: view.selectionActions.translate?(context)
        }
    }
}
