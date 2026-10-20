import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PDFThumbnailOverview: View {
    @ObservedObject var session: PDFSession
    static let pageType = UTType(exportedAs: "local.remile.pdf-page", conformingTo: .data).identifier
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Pages").font(RemileType.heading)
                Spacer()
                Button { session.choosePDFs() } label: { Image(systemName: "doc.badge.plus").frame(width: 32, height: 32) }.remileHelp("Add PDFs")
                Button { session.rotateOverviewPages(clockwise: false) } label: { Image(systemName: "rotate.left").frame(width: 32, height: 32) }.remileHelp("Rotate selected pages left")
                Button { session.rotateOverviewPages(clockwise: true) } label: { Image(systemName: "rotate.right").frame(width: 32, height: 32) }.remileHelp("Rotate selected pages right")
                PDFPageSizeControl(session: session)
            }.buttonStyle(RemileToolStyle()).font(RemileType.callout).disabled(!session.canArrangePages)
                .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            PDFPageCollection(session: session)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(RemileStyle.background)
    }
}

/// AppKit supplies range selection, a stacked drag image, edge scrolling and drop cancellation.
struct PDFPageCollection: NSViewRepresentable {
    @ObservedObject var session: PDFSession
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 182, height: 248)
        layout.minimumInteritemSpacing = 22; layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let collection = PageCollectionView()
        collection.collectionViewLayout = layout; collection.backgroundColors = [.clear]
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.allowsEmptySelection = false
        collection.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        collection.registerForDraggedTypes([NSPasteboard.PasteboardType(PDFThumbnailOverview.pageType), .fileURL])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask([], forLocal: false)
        collection.delegate = context.coordinator; collection.actions = context.coordinator
        let scroll = NSScrollView(); scroll.documentView = collection; scroll.hasVerticalScroller = true
        ReaderScrolling.configure(scroll)
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        context.coordinator.connect(collection); context.coordinator.refresh()
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.refresh() }

    final class Coordinator: NSObject, NSCollectionViewDelegate {
        let session: PDFSession
        weak var collection: PageCollectionView?
        var source: NSCollectionViewDiffableDataSource<Int, ObjectIdentifier>!
        var pages: [PDFPage] = []
        var revision: UUID?
        var updating = false
        init(_ session: PDFSession) { self.session = session }
        func connect(_ collection: PageCollectionView) {
            self.collection = collection
            source = NSCollectionViewDiffableDataSource(collectionView: collection) { [weak self] view, path, id in
                guard let self, let page = self.pages.first(where: { ObjectIdentifier($0) == id }),
                      let item = view.makeItem(withIdentifier: PageItem.identifier, for: path) as? PageItem else { return nil }
                item.configure(page, number: self.session.document.map { $0.index(for: page) + 1 } ?? path.item + 1)
                return item
            }
        }
        func refresh() {
            guard collection != nil, revision != session.pageRevision else { syncSelection(); return }
            updating = true
            let previous = pages.map(ObjectIdentifier.init)
            pages = session.document.map(PDFPageAssembly.pages) ?? []
            var snapshot = NSDiffableDataSourceSnapshot<Int, ObjectIdentifier>()
            snapshot.appendSections([0]); snapshot.appendItems(pages.map(ObjectIdentifier.init))
            revision = session.pageRevision
            let animate = !previous.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            source.apply(snapshot, animatingDifferences: animate) { [weak self] in
                guard let self, let collection = self.collection else { return }
                self.updating = false; self.syncSelection()
                for item in collection.visibleItems() {
                    guard let item = item as? PageItem, let path = collection.indexPath(for: item), self.pages.indices.contains(path.item) else { continue }
                    item.configure(self.pages[path.item], number: path.item + 1)
                }
            }
        }
        func syncSelection() {
            guard !updating, let collection else { return }
            var indexes = Set(pages.enumerated().compactMap { session.selectedOverviewPages.contains(ObjectIdentifier($0.element)) ? IndexPath(item: $0.offset, section: 0) : nil })
            if indexes.isEmpty, pages.indices.contains(session.currentPage - 1) { indexes = [IndexPath(item: session.currentPage - 1, section: 0)] }
            if collection.selectionIndexPaths != indexes { collection.selectionIndexPaths = indexes }
        }
        func selectionChanged() {
            guard !updating, let collection else { return }
            let selected = collection.selectionIndexPaths.sorted().compactMap { pages.indices.contains($0.item) ? pages[$0.item] : nil }
            session.selectedOverviewPages = Set(selected.map(ObjectIdentifier.init))
            if let page = selected.first { session.selectOverviewPage(page) }
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
        func open(_ index: Int) { if pages.indices.contains(index) { session.openOverviewPage(pages[index]) } }
        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { session.canArrangePages }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard pages.indices.contains(indexPath.item), session.canArrangePages else { return nil }
            let item = NSPasteboardItem(); item.setString(session.pageDragToken(pages[indexPath.item]), forType: NSPasteboard.PasteboardType(PDFThumbnailOverview.pageType)); return item
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            draggingSession.draggingFormation = .stack
            draggingSession.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation: NSDragOperation) { collection?.insertion = nil }
        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard session.canArrangePages else { return [] }
            proposedDropOperation.pointee = .before
            collection?.insertion = min(pages.count, proposedDropIndexPath.pointee.item)
            return draggingInfo.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType(PDFThumbnailOverview.pageType)) == true ? .move : .copy
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            collection?.insertion = nil
            let target = pages.indices.contains(indexPath.item) ? pages[indexPath.item] : nil
            let type = NSPasteboard.PasteboardType(PDFThumbnailOverview.pageType)
            let tokens = draggingInfo.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: type) } ?? []
            if !tokens.isEmpty { session.arrangePages(tokens: tokens, before: target); return true }
            let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            session.insertPDFs(urls, before: target); return true
        }
        func menu(at index: Int) -> NSMenu? {
            guard pages.indices.contains(index), let collection else { return nil }
            let path = IndexPath(item: index, section: 0)
            if !collection.selectionIndexPaths.contains(path) { collection.selectionIndexPaths = [path]; selectionChanged() }
            let menu = NSMenu()
            func add(_ title: String, _ selector: Selector) { let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.isEnabled = session.canArrangePages; menu.addItem(item) }
            add("Rotate Left", #selector(rotateLeft)); add("Rotate Right", #selector(rotateRight))
            menu.addItem(.separator()); add("Insert PDFs…", #selector(insert))
            return menu
        }
        @objc private func rotateLeft() { session.rotateOverviewPages(clockwise: false) }
        @objc private func rotateRight() { session.rotateOverviewPages(clockwise: true) }
        @objc private func insert() { session.choosePDFs(before: pages.first { session.selectedOverviewPages.contains(ObjectIdentifier($0)) }) }
    }
}

final class PageCollectionView: NSCollectionView {
    weak var actions: PDFPageCollection.Coordinator?
    var insertion: Int? { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item { actions?.open(index) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let path = selectionIndexPaths.sorted().first { actions?.open(path.item) }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return actions?.menu(at: path.item)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertion = nil; super.draggingExited(sender) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let insertion, let layout = collectionViewLayout else { return }
        let count = numberOfItems(inSection: 0)
        guard count > 0, let attributes = layout.layoutAttributesForItem(at: IndexPath(item: min(insertion, count - 1), section: 0)) else { return }
        let box = attributes.frame
        let x = insertion == count ? box.maxX + 10 : box.minX - 12
        NSColor(RemileStyle.accent).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: box.minY, width: 3, height: box.height - 24), xRadius: 1, yRadius: 1).fill()
    }
}

private final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PDF page")
    let image = NSImageView()
    let number = NSTextField(labelWithString: "")
    private var rendered: ObjectIdentifier?
    private var rotation = -1
    override func loadView() {
        let tile = PageTileView(); tile.changed = { [weak self] in self?.appearance() }
        view = tile; view.wantsLayer = true; view.layer?.cornerRadius = 4
        image.imageScaling = .scaleProportionallyUpOrDown
        number.alignment = .center; number.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        for child in [image, number] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), image.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            image.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), image.heightAnchor.constraint(equalToConstant: 204),
            number.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 8), number.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            number.trailingAnchor.constraint(equalTo: view.trailingAnchor), number.heightAnchor.constraint(equalToConstant: 24)
        ])
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
    }
    override var isSelected: Bool { didSet { appearance() } }
    private func appearance() {
        view.layer?.borderColor = NSColor(RemileStyle.accent).cgColor
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.backgroundColor = isSelected ? NSColor(RemileStyle.accent).withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
        view.setAccessibilityValue(isSelected ? "Selected" : "")
    }
    func configure(_ page: PDFPage, number: Int) {
        self.number.stringValue = "\(number)"; view.setAccessibilityLabel("Page \(number)")
        if rendered != ObjectIdentifier(page) || rotation != page.rotation {
            rendered = ObjectIdentifier(page); rotation = page.rotation
            image.image = page.thumbnail(of: CGSize(width: 332, height: 408), for: .cropBox)
        }
        appearance()
    }
    override func prepareForReuse() { super.prepareForReuse(); image.image = nil; rendered = nil; rotation = -1 }
}

private final class PageTileView: NSView {
    var changed: () -> Void = {}
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); changed() }
}
