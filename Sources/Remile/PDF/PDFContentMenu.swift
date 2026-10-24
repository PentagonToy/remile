import AppKit
import PDFKit

/// Context actions share the extraction backend. Only an explicit copy starts recognition.
@MainActor
final class PDFContentMenu: NSObject {
    enum Action { case image(CGRect), table(CGPoint, CGRect?) }
    private weak var view: PDFView?
    private var task: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var generation = UUID()
    private var notice: NSVisualEffectView?
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    init(view: PDFView) { self.view = view }
    deinit { task?.cancel(); dismissal?.cancel() }

    func insert(in menu: NSMenu, page: PDFPage, imageBounds: CGRect?, point: CGPoint, selection: CGRect?) {
        guard page.document === view?.document, let document = page.document, !document.isLocked, document.allowsCopying else { return }
        var items: [NSMenuItem] = []
        if let bounds = imageBounds { items.append(command("Copy Image", page: page, action: .image(bounds))) }
        if #available(macOS 26.0, *) { items.append(command("Copy Table", page: page, action: .table(point, selection))) }
        guard !items.isEmpty else { return }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
    }
    private func command(_ title: String, page: PDFPage, action: Action) -> NSMenuItem {
        let command = PDFContentMenuAction(owner: self, page: page, action: action)
        let item = NSMenuItem(title: title, action: #selector(PDFContentMenuAction.invoke(_:)), keyEquivalent: "")
        item.target = command; item.representedObject = command
        return item
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; dismissal?.cancel(); dismissal = nil
        progress.stopAnimation(nil); notice?.removeFromSuperview(); notice = nil
    }
    fileprivate func perform(page: PDFPage, action: Action) {
        guard page.document === view?.document else { return }
        cancel()
        do {
            let snapshot = try PDFContentRegions.Snapshot(page)
            let reference = page.pageRef, token = generation, clipboardRevision = NSPasteboard.general.changeCount
            if case .table = action { showNotice("Copying table…", busy: true) }
            task = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let bytes: Data, type: NSPasteboard.PasteboardType
                    switch action {
                    case .image(let bounds):
                        bytes = try PDFContentRegions.png(snapshot, bounds: bounds); type = .png
                    case .table(let point, let selection):
                        let tables = try await PDFTableRegions.recognise(snapshot)
                        let table = try PDFTableRegions.target(in: tables, point: point, selection: selection)
                        bytes = Data(table.tsv.utf8); type = .string
                    }
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == token, let view = self.view else { return }
                        self.task = nil
                        guard page.document === view.document, page.document?.allowsCopying == true,
                              page.pageRef === reference, page.rotation == snapshot.rotation, page.bounds(for: .cropBox) == snapshot.bounds else {
                            self.finish("The page changed. Copy again."); return
                        }
                        guard NSPasteboard.general.changeCount == clipboardRevision else { self.finish("Copy cancelled. Clipboard changed."); return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(bytes, forType: type)
                        if case .table = action { self.finish("Table copied.") } else { self.cancel() }
                    }
                } catch is CancellationError { }
                catch {
                    let message = error.localizedDescription
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.task = nil; self.finish(message)
                    }
                }
            }
        } catch { finish(error.localizedDescription) }
    }
    private func showNotice(_ text: String, busy: Bool) {
        guard let view else { return }
        if notice == nil {
            let notice = NSVisualEffectView(); notice.material = .hudWindow; notice.blendingMode = .withinWindow
            notice.wantsLayer = true; notice.layer?.cornerRadius = 10; notice.translatesAutoresizingMaskIntoConstraints = false
            progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
            cancelButton.target = self; cancelButton.action = #selector(cancelCopy(_:)); cancelButton.bezelStyle = .rounded
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            status.preferredMaxLayoutWidth = max(160, min(320, view.bounds.width - 140))
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [progress, status, cancelButton]); row.spacing = 8; row.translatesAutoresizingMaskIntoConstraints = false
            notice.addSubview(row); view.addSubview(notice)
            NSLayoutConstraint.activate([
                notice.centerXAnchor.constraint(equalTo: view.centerXAnchor), notice.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
                notice.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
                row.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -12),
                row.topAnchor.constraint(equalTo: notice.topAnchor, constant: 8), row.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -8)
            ])
            self.notice = notice
        }
        status.stringValue = text; cancelButton.isHidden = !busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    private func finish(_ message: String) {
        showNotice(message, busy: false)
        let token = generation
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.cancel()
        }
    }
    @objc private func cancelCopy(_ sender: Any?) { cancel() }
}

@MainActor
private final class PDFContentMenuAction: NSObject {
    weak var owner: PDFContentMenu?
    let page: PDFPage
    let action: PDFContentMenu.Action
    let reference: CGPDFPage?
    let crop: CGRect
    let rotation: Int
    init(owner: PDFContentMenu, page: PDFPage, action: PDFContentMenu.Action) {
        self.owner = owner; self.page = page; self.action = action
        reference = page.pageRef; crop = page.bounds(for: .cropBox); rotation = page.rotation
    }
    @objc func invoke(_ sender: Any?) {
        guard page.pageRef === reference, page.rotation == rotation, page.bounds(for: .cropBox) == crop else { return }
        owner?.perform(page: page, action: action)
    }
}
