import SwiftUI
import AppKit
import QuartzCore

/// Native selection and drag sessions; internal drags never expose a file URL to the editor.
struct TeXFileTree: NSViewRepresentable {
    @ObservedObject var project: TeXProject
    var showCollections = true
    func makeCoordinator() -> Coordinator { Coordinator(project, showCollections: showCollections) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView(); outline.headerView = nil; outline.rowHeight = 31; outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true; outline.style = .sourceList; outline.backgroundColor = .clear
        let column = NSTableColumn(identifier: .init("files")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.delegate = context.coordinator; outline.dataSource = context.coordinator
        outline.registerForDraggedTypes([Coordinator.type, .fileURL]); outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.documentView = outline
        context.coordinator.outline = outline; context.coordinator.reload()
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.project = project; context.coordinator.showCollections = showCollections; context.coordinator.reload() }
    @MainActor final class Node: NSObject {
        let key: String, title: String
        let group: UUID?
        let file: String?
        let folder: Bool
        var children: [Node]
        init(key: String, title: String, group: UUID? = nil, file: String? = nil, folder: Bool = false, children: [Node] = []) { self.key = key; self.title = title; self.group = group; self.file = file; self.folder = folder; self.children = children }
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        static let type = NSPasteboard.PasteboardType("local.remile.tex-items")
        var showCollections: Bool
        var project: TeXProject
        weak var outline: NSOutlineView?
        private var roots: [Node] = []
        private var signature = ""
        private var reloading = false
        private var lastOpened = ""
        private var expanded = Set<String>()
        private var menuPrepared = false
        private var context: Node?
        init(_ project: TeXProject, showCollections: Bool) { self.project = project; self.showCollections = showCollections }
        func reload() {
            guard let outline else { return }
            let current = project.main + "\n" + String(showCollections) + project.treeFolders.joined(separator: "|") + project.treeFiles.joined(separator: "|") + String(decoding: (try? JSONEncoder().encode(project.collections)) ?? Data(), as: UTF8.self)
            guard current != signature else {
                if lastOpened != project.selected {
                    lastOpened = project.selected
                    if let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? Node)?.file == project.selected }) { reloading = true; outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); reloading = false }
                }
                return
            }; let animated = !signature.isEmpty; signature = current; reloading = true
            let selected = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.key })
            func file(_ item: TeXFileNode) -> Node { Node(key: "file:" + item.path, title: item.name, file: item.path, folder: item.children != nil, children: (item.children ?? []).map(file)) }
            func groups(_ parent: UUID?, seen: Set<UUID> = []) -> [Node] {
                project.collections.filter { $0.parent == parent && !seen.contains($0.id) }.map { group in
                    let paths = group.paths.filter { project.treeFiles.contains($0) }
                    return Node(key: group.id.uuidString, title: group.name, group: group.id, children: groups(group.id, seen: seen.union([group.id])) + paths.map { Node(key: "file:" + $0, title: ($0 as NSString).lastPathComponent, file: $0) })
                }
            }
            let grouped = showCollections ? Set(project.collections.flatMap(\.paths)) : []
            roots = (showCollections ? groups(nil) : []) + TeXFileNode.tree(project.treeFiles.filter { !grouped.contains($0) }, folders: project.treeFolders).map(file)
            outline.reloadData()
            func restore(_ nodes: [Node]) {
                for node in nodes {
                    if node.group.flatMap({ id in project.collections.first { $0.id == id }?.expanded }) ?? expanded.contains(node.key) { outline.expandItem(node) }
                    restore(node.children)
                }
            }
            restore(roots)
            if lastOpened != project.selected {
                func reveal(_ nodes: [Node]) -> Bool {
                    for node in nodes { if node.file == project.selected { return true }; if reveal(node.children) { outline.expandItem(node); return true } }; return false
                }
                _ = reveal(roots)
            }
            let changedSource = lastOpened != project.selected
            let rows = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? Node).map { changedSource ? $0.file == project.selected : selected.contains($0.key) } ?? false })
            outline.selectRowIndexes(rows, byExtendingSelection: false); lastOpened = project.selected; reloading = false
            if animated && AnimationPolicy.enabled() {
                outline.alphaValue = 0.76
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.32; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); outline.animator().alphaValue = 1 }
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { guard let item = item as? Node else { return false }; return item.group != nil || item.folder }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = NSTableCellView(), label = NSTextField(labelWithString: node.title), icon = NSImageView()
            let isMain = node.file == project.main && !node.folder
            label.textColor = isMain ? NSColor(RemileStyle.accent) : .labelColor
            label.setAccessibilityHelp(isMain ? "Main document used for compilation" : nil)
            label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let ext = ((node.file ?? "") as NSString).pathExtension.lowercased()
            let symbol = ["pdf": "doc.richtext", "png": "photo", "jpg": "photo", "jpeg": "photo", "svg": "photo", "eps": "photo", "bib": "books.vertical", "sty": "curlybraces", "cls": "curlybraces"][ext] ?? "doc.text"
            icon.image = SymbolIcon.nativeImage(systemName: node.group != nil ? "square.stack.3d.up" : node.folder ? "folder" : symbol, description: node.group != nil ? "Virtual collection" : "File")
            icon.contentTintColor = node.group != nil ? NSColor(RemileStyle.accent) : .secondaryLabelColor
            let stack = NSStackView(views: [icon, label]); stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            if node.group != nil { let badge = NSTextField(labelWithString: "collection"); badge.font = .systemFont(ofSize: 9); badge.textColor = .secondaryLabelColor; badge.setContentHuggingPriority(.required, for: .horizontal); stack.addArrangedSubview(badge) }
            cell.addSubview(stack); cell.textField = label; cell.imageView = icon
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.toolTip = node.group != nil ? "Virtual collection · files stay in place" : isMain ? "Main document · " + project.main : node.file
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline, outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? Node, let path = node.file else { return }
            project.selected = path
        }
        func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, value: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, value: false) }
        private func expansion(_ notification: Notification, value: Bool) {
            guard !reloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
            if value { expanded.insert(node.key) } else { expanded.remove(node.key) }
            if let id = node.group, let index = project.collections.firstIndex(where: { $0.id == id }), project.collections[index].expanded != value {
                var groups = project.collections; groups[index].expanded = value; project.updateCollections(groups)
            }
        }
        private typealias Payload = TeXFileDragPayload
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            let selected = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? Node }
            let nodes = selected.contains(where: { $0.key == node.key }) ? selected : [node]
            let payload = Payload(project: project.identity, groups: nodes.compactMap(\.group), files: nodes.filter { $0.group == nil }.compactMap(\.file))
            guard let bytes = try? JSONEncoder().encode(payload) else { return nil }
            let result = NSPasteboardItem(); result.setData(bytes, forType: Self.type); return result
        }
        private func payload(_ info: NSDraggingInfo) -> Payload? {
            guard let bytes = info.draggingPasteboard.data(forType: Self.type), bytes.count < 256_000, let payload = try? JSONDecoder().decode(Payload.self, from: bytes), payload.project == project.identity else { return nil }; return payload
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard !project.compiling else { return [] }
            let node = item as? Node
            if let payload = payload(info) {
                guard node == nil || node?.group != nil || node?.folder == true else { return [] }
                if node?.folder == true || !showCollections {
                    guard payload.groups.isEmpty, !payload.files.contains(where: { node?.file == $0 || node?.file?.hasPrefix($0 + "/") == true }) else { return [] }
                } else if TeXCollections.moving(Set(payload.groups), under: node?.group, groups: project.collections) == nil { return [] }
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex); return .move
            }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]), node == nil || node?.folder == true else { return [] }
            return .copy
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard !project.compiling else { return false }
            let node = item as? Node
            if let payload = payload(info) {
                if node?.folder == true || !showCollections {
                    for path in TeXFileSystem.topLevel(payload.files) { let target = [node?.file, (path as NSString).lastPathComponent].compactMap { $0 }.joined(separator: "/"); if path != target { project.move(path, to: target) } }
                } else {
                    guard let groups = TeXCollections.moving(Set(payload.groups), under: node?.group, groups: project.collections) else { return false }
                    let paths = project.treeFiles.filter { path in payload.files.contains { path == $0 || path.hasPrefix($0 + "/") } }
                    project.updateCollections(TeXCollections.assigning(paths, to: node?.group, groups: groups, allowed: Set(project.treeFiles)))
                }
                reload(); return true
            }
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            project.drop(urls, into: node?.file ?? ""); return true
        }
        func menuDidClose(_ menu: NSMenu) { menuPrepared = false }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !menuPrepared else { return }; menuPrepared = true
            menu.removeAllItems(); guard let outline else { return }; let node = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? Node : nil; context = node
            func add(_ title: String, _ selector: Selector) { let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; if title == "Copy relative path" { item.toolTip = "Omits .tex for \\input. Image and PDF extensions stay." }; menu.addItem(item) }
            guard let node else {
                add("New file", #selector(newFile)); add("New folder", #selector(newFolder)); add("New collection", #selector(newCollection)); return
            }
            if node.group != nil {
                add("Rename", #selector(renameGroup)); add("Add files…", #selector(addFiles))
                add("New collection inside", #selector(newCollection)); menu.addItem(.separator()); add("Remove collection", #selector(removeGroup))
            } else if let path = node.file {
                add("Rename", #selector(renameFile)); add("Copy relative path", #selector(copyPath)); add("Reveal in Finder", #selector(revealFile))
                if project.connected && !node.folder { add("Download…", #selector(downloadFile)) }
                if !node.folder { add("Duplicate", #selector(duplicateFiles)) }
                if node.folder { menu.addItem(.separator()); add("New file", #selector(newFile)); add("New folder", #selector(newFolder)) }
                if showCollections && !project.collections.isEmpty {
                    let submenu = NSMenu()
                    for group in project.collections { let item = NSMenuItem(title: group.name, action: #selector(moveFiles(_:)), keyEquivalent: ""); item.target = self; item.representedObject = group.id.uuidString; submenu.addItem(item) }
                    let ungroup = NSMenuItem(title: "Ungrouped files", action: #selector(moveFiles(_:)), keyEquivalent: ""); ungroup.target = self; submenu.addItem(ungroup)
                    let item = NSMenuItem(title: "Move to collection", action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item)
                }
                if path != project.main { menu.addItem(.separator()); add("Move to Trash", #selector(trashFile)) }
            }
        }

        private var selectedPaths: [String] {
            guard let outline else { return [] }; let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
            return (selected.contains(where: { $0.key == context?.key }) ? selected : context.map { [$0] } ?? []).compactMap(\.file)
        }
        @objc private func newFile() {
            let parent = context?.folder == true ? context?.file ?? "" : ((context?.file ?? "") as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.project.newFile(in: parent) }
        }
        @objc private func newFolder() {
            let parent = context?.folder == true ? context?.file ?? "" : ((context?.file ?? "") as NSString).deletingLastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.project.newFolder(in: parent) }
        }
        @objc private func newCollection() {
            let parent = context?.group
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in UserDefaults.standard.set(true, forKey: "latex.showCollections"); self?.project.addCollection(parent: parent) }
        }
        @objc private func copyPath() { let paths = selectedPaths.map(TeXFileSystem.reference); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string) }
        @objc private func duplicateFiles() { project.duplicate(selectedPaths) }
        @objc private func addFiles() { if let id = context?.group { project.chooseCollectionFiles(id) } }
        @objc private func addGroup() { project.addCollection(parent: context?.group) }
        @objc private func removeGroup() { if let id = context?.group { project.updateCollections(TeXCollections.removing(id, groups: project.collections)) } }
        @objc private func renameGroup() { beginRename() }
        @objc private func moveFiles(_ sender: NSMenuItem) {
            guard let outline else { return }
            let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
            let nodes = selected.contains(where: { $0.key == context?.key }) ? selected : context.map { [$0] } ?? []
            project.updateCollections(TeXCollections.assigning(project.treeFiles.filter { path in nodes.compactMap(\.file).contains { path == $0 || path.hasPrefix($0 + "/") } }, to: (sender.representedObject as? String).flatMap(UUID.init(uuidString:)), groups: project.collections, allowed: Set(project.treeFiles)))
        }
        @objc private func renameFile() { beginRename() }
        private func beginRename() {
            guard !project.compiling, let node = context else { return }
            // Let native menu tracking finish before the name field takes focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !self.project.compiling else { return }
                self.project.newItemError = nil
                if let id = node.group { self.project.newItemDraft = .init(kind: .renameCollection(id, node.title)) }
                else if let path = node.file { self.project.newItemDraft = .init(kind: .rename(path)) }
            }
        }

        @objc private func downloadFile() {
            guard let path = context?.file else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = (path as NSString).lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                let source = try TeXFileSystem.url(path, root: project.root)
                guard source.standardizedFileURL != destination.standardizedFileURL else { return }
                let data = try project.buffers[path].map { Data($0.utf8) } ?? Data(contentsOf: source)
                try data.write(to: destination, options: .atomic)
            } catch { project.message = "Download failed: " + error.localizedDescription }
        }
        @objc private func revealFile() { if let path = context?.file { NSWorkspace.shared.activateFileViewerSelecting([project.root.appendingPathComponent(path)]) } }
        @objc private func trashFile() { project.trash(selectedPaths) }
    }
}

private struct TeXFileDragPayload: Codable {
    let project: UUID
    let groups: [UUID]
    let files: [String]
}

struct TeXFileTrashTarget: NSViewRepresentable {
    @ObservedObject var project: TeXProject
    func makeNSView(context: Context) -> TeXTrashDropView { TeXTrashDropView(project: project) }
    func updateNSView(_ view: TeXTrashDropView, context: Context) { view.project = project; view.needsDisplay = true }
}

final class TeXTrashDropView: NSView {
    var project: TeXProject
    private var targeted = false { didSet { needsDisplay = true } }
    init(project: TeXProject) {
        self.project = project; super.init(frame: .zero)
        registerForDraggedTypes([TeXFileTree.Coordinator.type])
        toolTip = "Drop project files here to move them to Trash"
        setAccessibilityElement(true); setAccessibilityLabel("Drop files to Trash")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func paths(_ info: NSDraggingInfo) -> [String]? {
        guard !project.compiling, let data = info.draggingPasteboard.data(forType: TeXFileTree.Coordinator.type), data.count < 256_000,
              let payload = try? JSONDecoder().decode(TeXFileDragPayload.self, from: data), payload.project == project.identity,
              payload.groups.isEmpty, !payload.files.isEmpty,
              payload.files.allSatisfy({ project.treeFiles.contains($0) || project.treeFolders.contains($0) }),
              !payload.files.contains(where: { project.main == $0 || project.main.hasPrefix($0 + "/") }) else { return nil }
        return TeXFileSystem.topLevel(payload.files)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { targeted = paths(sender) != nil; return targeted ? .move : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { paths(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let paths = paths(sender) else { targeted = false; return false }
        targeted = false
        // Finish AppKit's drag session before opening the existing confirmation sheet.
        let targetProject = project
        DispatchQueue.main.async { targetProject.trash(paths) }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let colour = targeted ? NSColor(RemileStyle.accent) : NSColor.secondaryLabelColor
        if targeted { colour.withAlphaComponent(0.1).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 3), xRadius: 6, yRadius: 6).fill() }
        let text = "Drop to Trash" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: colour]
        let size = text.size(withAttributes: attributes), width = size.width + 22
        let x = (bounds.width - width) / 2
        let icon = SymbolIcon.nativeImage(systemName: "trash", description: nil)?.withSymbolConfiguration(.init(paletteColors: [colour]))
        icon?.draw(in: NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14))
        text.draw(at: NSPoint(x: x + 22, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
