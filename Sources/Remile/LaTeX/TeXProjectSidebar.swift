import SwiftUI

struct TeXFileNode: Identifiable {
    let path: String
    let name: String
    var children: [TeXFileNode]?
    var id: String { path }
    static func tree(_ paths: [String], folders: [String] = [], prefix: String = "") -> [Self] {
        let groups = Dictionary(grouping: Array(Set(paths + folders))) { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? "" }
        return groups.keys.sorted { a, b in
            let aFolder = folders.contains(prefix + a) || groups[a]!.contains { $0 != prefix + a }, bFolder = folders.contains(prefix + b) || groups[b]!.contains { $0 != prefix + b }
            return aFolder == bFolder ? a.localizedStandardCompare(b) == .orderedAscending : aFolder
        }.map { name in
            let path = prefix + name, descendants = groups[name]!.filter { $0 != path }
            return Self(path: path, name: name, children: folders.contains(path) || !descendants.isEmpty ? tree(descendants, folders: folders.filter { $0.hasPrefix(path + "/") }, prefix: path + "/") : nil)
        }
    }
}

final class TeXSidebarState: ObservableObject {
    @Published var settings = false
    @Published var outline = true
    @Published var files = true
    @Published var filesHeight: CGFloat?
    var dragOrigin: CGFloat?
}

struct TeXProjectSidebar: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state: TeXSidebarState
    @AppStorage("latex.showCollections") private var showCollections = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(project: TeXProject, state: TeXSidebarState = TeXSidebarState()) { self.project = project; _state = StateObject(wrappedValue: state) }
    var body: some View {
        VStack(spacing: 0) {
                GeometryReader { geometry in
                    let available = max(0, geometry.size.height - 8)
                    let minimum = min(100, available / 2)
                    let header = min(45, available / 2)
                    let split = min(available - minimum, max(minimum, state.filesHeight ?? available - 200))
                    let height = !state.files ? header : !state.outline ? available - header : split
                    let outlineHeight = !state.outline ? header : available - height
                    VStack(spacing: 0) {
                        filesPane.frame(height: height).clipped()
                        ZStack { Color.clear; Divider() }.frame(height: 8).contentShape(Rectangle())
                            .background(TeXSidebarResizeCursor().allowsHitTesting(false))
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tex.sidebar.split")).onChanged { event in
                                guard state.files && state.outline else { return }
                                if state.dragOrigin == nil { state.dragOrigin = height }
                                state.filesHeight = min(available - minimum, max(minimum, (state.dragOrigin ?? height) + event.translation.height))
                            }.onEnded { _ in state.dragOrigin = nil })
                            .accessibilityElement().accessibilityLabel("Resize Files and Outline").accessibilityValue("\(Int(height)) points")
                            .accessibilityAdjustableAction { direction in state.filesHeight = min(available - minimum, max(minimum, height + (direction == .increment ? 20 : -20))) }
                            .allowsHitTesting(state.files && state.outline).accessibilityHidden(!state.files || !state.outline)
                            .remileHelp("Drag to resize Files and Outline")
                        outlinePane.frame(height: outlineHeight, alignment: .top).clipped()
                        if !state.files && !state.outline { Spacer(minLength: 0) }
                    }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .coordinateSpace(name: "tex.sidebar.split").transaction { if state.dragOrigin != nil { $0.animation = nil } }
                }
            Divider()
            EditorSidebarFooter(compact: state.files || state.outline, title: "Settings") { state.settings.toggle() }
                .accessibilityLabel("LaTeX settings").remileHelp("LaTeX settings")
                .sheet(isPresented: $state.settings) { TeXProjectSettings(project: project).frame(width: 560, height: 560) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(RemileStyle.sidebar)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.files)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.outline)
            .onChange(of: state.files) { state.dragOrigin = nil }
            .onChange(of: state.outline) { state.dragOrigin = nil }
    }
    private var filesPane: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                filesHeader(compact: false)
                filesHeader(compact: true)
            }.padding(.horizontal, 12).frame(height: 44)
            Divider()
            if state.files {
                if let draft = project.newItemDraft { TeXSidebarCreation(project: project, draft: draft).id(draft.id) }
                TeXFileTree(project: project, showCollections: showCollections)
                TeXFileTrashTarget(project: project).frame(height: 32)
            }
        }
    }
    private func filesHeader(compact: Bool) -> some View {
        HStack(spacing: 4) {
            DisclosureGroup("Files", isExpanded: $state.files) { EmptyView() }.font(RemileType.callout.weight(.semibold))
            if !compact {
                if project.selected != project.main {
                    Button { project.visit(file: project.main) } label: { SymbolIcon(systemName: "doc.text").frame(width: 22, height: 22) }
                        .buttonStyle(.plain).remileHelp("Open main document").accessibilityLabel("Open main document")
                }
                Toggle(isOn: $showCollections) { SymbolIcon(systemName: "square.stack.3d.up").frame(width: 22, height: 22) }
                    .toggleStyle(.button).buttonStyle(.plain).remileHelp("Show collections").accessibilityLabel("Show collections")
            }
            Button { state.files = true; project.chooseFiles() } label: { SymbolIcon(systemName: "tray.and.arrow.up").frame(width: 22, height: 22) }
                .buttonStyle(.plain).disabled(project.compiling).remileHelp("Add files to this folder").accessibilityLabel("Add files")
            Menu {
                Button("New file") { state.files = true; project.newFile() }
                Button("New folder") { state.files = true; project.newFolder() }
                Button("New collection") { state.files = true; showCollections = true; project.addCollection() }
                if compact {
                    Divider()
                    Toggle("Show collections", isOn: $showCollections)
                    Button("Open main document") { project.visit(file: project.main) }
                }
            } label: { SymbolIcon(systemName: "plus").frame(width: 20, height: 22) }
                .menuStyle(.borderlessButton).tint(RemileStyle.ink).fixedSize().remileHelp("New file, folder or collection")
        }
    }
    private var outlinePane: some View {
        VStack(spacing: 0) {
            Button { state.outline.toggle() } label: {
                HStack(spacing: 6) { SymbolIcon(systemName: state.outline ? "chevron.down" : "chevron.right"); Text("Outline").font(RemileType.callout.weight(.semibold)); Spacer(minLength: 0) }
                    .frame(height: 44).padding(.horizontal, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(state.outline ? "Expanded" : "Collapsed").remileHelp("Project headings, including linked LaTeX files")
            Divider()
            if state.outline {
                if project.outline.isEmpty {
                    Text("No project headings").font(RemileType.small).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 12)
                } else { ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(project.outline) { item in
                            Button { project.visit(file: item.file, line: item.line) } label: { Text(item.title).font(RemileType.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(item.level) * 14).padding(.vertical, 5) }.buttonStyle(.plain).remileHelp(item.file + ":" + String(item.line + 1))
                        }
                    }.padding(.horizontal, 12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

}

private struct TeXProjectSettings: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool
    @ObservedObject var project: TeXProject
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("LaTeX settings").font(RemileType.heading); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).focused($closeFocused) }.padding(20)
            HStack {
                Text("Main document")
                Picker("Main document", selection: $project.main) { ForEach(project.files.filter { $0.hasSuffix(".tex") }, id: \.self) { Text($0).tag($0) } }.labelsHidden()
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            TeXSettings(project: project)
        }.font(RemileType.control).buttonStyle(RemileActionStyle()).background(RemileStyle.background).defaultFocus($closeFocused, true)
    }
}

private struct TeXSidebarCreation: View {
    @ObservedObject var project: TeXProject
    let draft: TeXProject.NewItemDraft
    @StateObject private var state = EntryState()
    private final class EntryState: ObservableObject { @Published var name = ""; var finished = false }
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SymbolIcon(systemName: draft.symbol).foregroundStyle(RemileStyle.accent).frame(width: 17)
                TextField(draft.placeholder, text: $state.name).textFieldStyle(.plain).focused($focused)
                    .accessibilityLabel(draft.placeholder).onSubmit { commit() }.onExitCommand { cancel() }
            }.padding(5).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 5))
            if let error = project.newItemError { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
        }.background(InlineEditBoundary(cancel: { cancel() }) { leave() }).padding(.horizontal, 12).padding(.vertical, 6)
            .onAppear { state.name = draft.initialName; state.finished = false; focused = true }
            .onDisappear { if InlineNamePolicy.isEmpty(state.name) { cancel() } else if isRename { commit() } }
            .remileHelp(isRename ? "Return or click elsewhere to save · Esc cancels" : "Return confirms. Click elsewhere or press Esc to cancel.")
    }
    private var isRename: Bool { switch draft.kind { case .rename, .renameCollection: return true; default: return false } }
    private func cancel() { state.finished = true; if project.newItemDraft?.id == draft.id { project.cancelNewItem() } }
    private func leave() { if isRename { commit() } else { cancel() } }
    private func commit() {
        guard !state.finished, project.newItemDraft?.id == draft.id else { return }
        guard !InlineNamePolicy.isEmpty(state.name) else { cancel(); return }
        state.finished = true
        if !project.finishNewItem(state.name) { state.finished = false; focused = true }
    }
}

private struct TeXSidebarResizeCursor: NSViewRepresentable {
    final class Region: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) { view.window?.invalidateCursorRects(for: view) }
}
