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
        private var context: Node?
        init(_ project: TeXProject, showCollections: Bool) { self.project = project; self.showCollections = showCollections }
        func reload() {
            guard let outline else { return }
            let current = String(showCollections) + project.treeFolders.joined(separator: "|") + project.treeFiles.joined(separator: "|") + String(decoding: (try? JSONEncoder().encode(project.collections)) ?? Data(), as: UTF8.self)
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
            let rows = IndexSet((0..<outline.numberOfRows).filter { (outline.item(atRow: $0) as? Node).map { selected.contains($0.key) } ?? false })
            outline.selectRowIndexes(rows, byExtendingSelection: false); lastOpened = project.selected; reloading = false
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
            label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let ext = ((node.file ?? "") as NSString).pathExtension.lowercased()
            let symbol = ["pdf": "doc.richtext", "png": "photo", "jpg": "photo", "jpeg": "photo", "svg": "photo", "eps": "photo", "bib": "books.vertical", "sty": "curlybraces", "cls": "curlybraces"][ext] ?? "doc.text"
            icon.image = NSImage(systemSymbolName: node.group != nil ? "square.stack.3d.up" : node.folder ? "folder" : symbol, accessibilityDescription: node.group != nil ? "Virtual collection" : "File")
            icon.contentTintColor = node.group != nil ? NSColor(RemileStyle.accent) : .secondaryLabelColor
            let stack = NSStackView(views: [icon, label]); stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            if node.group != nil { let badge = NSTextField(labelWithString: "collection"); badge.font = .systemFont(ofSize: 9); badge.textColor = .secondaryLabelColor; badge.setContentHuggingPriority(.required, for: .horizontal); stack.addArrangedSubview(badge) }
            cell.addSubview(stack); cell.textField = label; cell.imageView = icon
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.toolTip = node.group != nil ? "Virtual collection · files stay in place" : node.file
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline, outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? Node, let path = node.file, project.buffers[path] != nil else { return }
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
        private struct Payload: Codable { let project: UUID; let groups: [UUID]; let files: [String] }
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
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); guard let outline else { return }; let node = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? Node : nil; context = node
            func add(_ title: String, _ selector: Selector) { let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; if title == "Copy relative path" { item.toolTip = "Omits .tex for \\input. Image and PDF extensions stay." }; menu.addItem(item) }
            add("New folder…", #selector(newFolder)); add(node?.group == nil ? "New collection…" : "New collection inside…", #selector(newCollection)); menu.addItem(.separator())
            guard let node else { return }
            if node.group != nil { add("Add files…", #selector(addFiles)); add("Rename collection…", #selector(renameGroup)); add("Remove collection", #selector(removeGroup)) }
            else if let path = node.file {
                if !node.folder { add("Copy relative path", #selector(copyPath)); add("Duplicate", #selector(duplicateFiles)) }
                let submenu = NSMenu()
                for group in project.collections { let item = NSMenuItem(title: group.name, action: #selector(moveFiles(_:)), keyEquivalent: ""); item.target = self; item.representedObject = group.id.uuidString; submenu.addItem(item) }
                let ungroup = NSMenuItem(title: "Ungrouped files", action: #selector(moveFiles(_:)), keyEquivalent: ""); ungroup.target = self; submenu.addItem(ungroup)
                if showCollections { let item = NSMenuItem(title: "Move to collection", action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item) }
                add("Reveal in Finder", #selector(revealFile)); add("Rename…", #selector(renameFile))
                if path != project.main { add("Move to Trash", #selector(trashFile)) }
            }
        }
        private var selectedPaths: [String] {
            guard let outline else { return [] }; let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
            return (selected.contains(where: { $0.key == context?.key }) ? selected : context.map { [$0] } ?? []).compactMap(\.file)
        }
        @objc private func newFolder() { project.newFolder(in: context?.folder == true ? context?.file ?? "" : ((context?.file ?? "") as NSString).deletingLastPathComponent) }
        @objc private func newCollection() { UserDefaults.standard.set(true, forKey: "latex.showCollections"); project.addCollection(parent: context?.group) }
        @objc private func copyPath() { let paths = selectedPaths.map(TeXFileSystem.reference); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string) }
        @objc private func duplicateFiles() { project.duplicate(selectedPaths) }
        @objc private func addFiles() { if let id = context?.group { project.chooseCollectionFiles(id) } }
        @objc private func addGroup() { project.addCollection(parent: context?.group) }
        @objc private func removeGroup() { if let id = context?.group { project.updateCollections(TeXCollections.removing(id, groups: project.collections)) } }
        @objc private func renameGroup() { guard let id = context?.group, let name = prompt("Rename collection", value: context?.title ?? ""), let index = project.collections.firstIndex(where: { $0.id == id }) else { return }; var groups = project.collections; groups[index].name = name; project.updateCollections(groups) }
        @objc private func moveFiles(_ sender: NSMenuItem) {
            guard let outline else { return }
            let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
            let nodes = selected.contains(where: { $0.key == context?.key }) ? selected : context.map { [$0] } ?? []
            project.updateCollections(TeXCollections.assigning(project.treeFiles.filter { path in nodes.compactMap(\.file).contains { path == $0 || path.hasPrefix($0 + "/") } }, to: (sender.representedObject as? String).flatMap(UUID.init(uuidString:)), groups: project.collections, allowed: Set(project.treeFiles)))
        }
        private func prompt(_ title: String, value: String) -> String? { let alert = NSAlert(); alert.messageText = title; let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 240, height: 24); alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return nil }; let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); return name.isEmpty ? nil : name }
        @objc private func renameFile() { if let path = context?.file, let name = prompt("Rename", value: context?.title ?? "") { _ = project.rename(path, to: name) } }
        @objc private func revealFile() { if let path = context?.file { NSWorkspace.shared.activateFileViewerSelecting([project.root.appendingPathComponent(path)]) } }
        @objc private func trashFile() { project.trash(selectedPaths) }
    }
}
