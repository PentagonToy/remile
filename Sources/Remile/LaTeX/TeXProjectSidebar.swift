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

struct TeXProjectSidebar: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = SidebarState()
    @AppStorage("latex.showCollections") private var showCollections = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class SidebarState: ObservableObject { @Published var settings = false; @Published var outline = true; @Published var files = true }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DisclosureGroup("Files", isExpanded: $state.files) { EmptyView() }.font(RemileType.callout.weight(.semibold))
                if project.selected != project.main {
                    Button { project.visit(file: project.main) } label: { Image(systemName: "doc.text").frame(width: 22, height: 22) }
                        .buttonStyle(.plain).remileHelp("Open main document · " + project.main).accessibilityLabel("Open main document")
                }
                Toggle(isOn: $showCollections) { Image(systemName: "square.stack.3d.up").frame(width: 22, height: 22) }.toggleStyle(.button).buttonStyle(.plain).remileHelp(showCollections ? "Collections on · click for plain folders" : "Plain folders · click to restore collections").accessibilityLabel("Show collections")
                Menu { Button("New file") { state.files = true; project.newFile() }; Button("New folder") { state.files = true; project.newFolder() }; Button("New collection") { state.files = true; showCollections = true; project.addCollection() } } label: { Image(systemName: "plus").frame(width: 20, height: 22) }.menuStyle(.borderlessButton).fixedSize().remileHelp("New file, folder or virtual collection")
            }.padding(12)
            Divider()
            if state.files {
                if let draft = project.newItemDraft { TeXSidebarCreation(project: project, draft: draft).id(draft.id) }
                TeXFileTree(project: project, showCollections: showCollections)
            }
            Divider()
            DisclosureGroup("Outline", isExpanded: $state.outline) {
                if project.outline.isEmpty {
                    Text("No project headings").font(RemileType.small).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } else { ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(project.outline) { item in
                            Button { project.visit(file: item.file, line: item.line) } label: { Text(item.title).font(RemileType.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(item.level) * 14).padding(.vertical, 5) }.buttonStyle(.plain).remileHelp(item.file + ":" + String(item.line + 1))
                        }
                    }
                }.frame(height: min(180, CGFloat(project.outline.count) * 40)) }
            }.font(RemileType.callout).padding(12).remileHelp("Project headings, including linked LaTeX files")
            if !state.files { Spacer(minLength: 0) }
            Divider()
            EditorSidebarFooter(compact: state.files, title: "Project settings") { state.settings.toggle() }
                .popover(isPresented: $state.settings, arrowEdge: .trailing) { TeXProjectSettings(project: project).frame(width: 440, height: 540) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(RemileStyle.sidebar)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.files)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.outline)
    }
}

private struct TeXProjectSettings: View {
    @ObservedObject var project: TeXProject
    var body: some View {
        VStack(spacing: 0) {
            Text("Project settings").font(RemileType.heading).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            HStack {
                Text("Main document")
                Picker("Main document", selection: $project.main) { ForEach(project.files.filter { $0.hasSuffix(".tex") }, id: \.self) { Text($0).tag($0) } }.labelsHidden()
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            TeXSettings()
        }.background(RemileStyle.background)
    }
}

private struct TeXSidebarCreation: View {
    @ObservedObject var project: TeXProject
    let draft: TeXProject.NewItemDraft
    @StateObject private var state = EntryState()
    private final class EntryState: ObservableObject { @Published var name = "" }
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: draft.symbol).foregroundStyle(RemileStyle.accent).frame(width: 17)
                TextField(draft.placeholder, text: $state.name).textFieldStyle(.plain).focused($focused)
                    .accessibilityLabel(draft.placeholder).onSubmit { commit() }.onExitCommand { project.cancelNewItem() }
            }.padding(5).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 5))
            if let error = project.newItemError { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
        }.padding(.horizontal, 12).padding(.vertical, 6)
            .onAppear { state.name = draft.initialName; focused = true }
            .onChange(of: focused) { if !focused { commit() } }
            .remileHelp("Return confirms the name. Escape or an empty name cancels.")
    }
    private func commit() { guard project.newItemDraft?.id == draft.id else { return }; if !project.finishNewItem(state.name) { focused = true } }
}
