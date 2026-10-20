import SwiftUI
import UniformTypeIdentifiers

struct TeXFileNode: Identifiable {
    let path: String
    let name: String
    var children: [TeXFileNode]?
    var id: String { path }
    static func tree(_ paths: [String], prefix: String = "") -> [Self] {
        let groups = Dictionary(grouping: paths) { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? "" }
        return groups.keys.sorted { a, b in
            let aFolder = groups[a]!.contains { $0 != prefix + a }, bFolder = groups[b]!.contains { $0 != prefix + b }
            return aFolder == bFolder ? a.localizedStandardCompare(b) == .orderedAscending : aFolder
        }.map { name in
            let path = prefix + name, descendants = groups[name]!.filter { $0 != path }
            return Self(path: path, name: name, children: descendants.isEmpty ? nil : tree(descendants, prefix: path + "/"))
        }
    }
}

struct TeXProjectSidebar: View {
    @ObservedObject var project: TeXProject
    @StateObject private var state = SidebarState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    private final class SidebarState: ObservableObject { @Published var settings = false; @Published var outline = true; @Published var files = true; @Published var nodes: [TeXFileNode] = [] }
    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup("Files", isExpanded: $state.files) { EmptyView() }.font(RemileType.callout.weight(.semibold)).padding(12)
            Divider()
            if state.files { ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.nodes) { node in TeXFileRow(node: node, project: project) }
                }.padding(8)
            }.onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                HomeFileDrop.receive(providers) { project.drop($0, into: "") }; return true
            } }
            Divider()
            DisclosureGroup("Outline", isExpanded: $state.outline) {
                if project.outline.isEmpty {
                    Text("No headings in this file").font(RemileType.small).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } else { ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(project.outline) { item in
                            Button { project.visit(file: project.selected, line: item.id) } label: { Text(item.title).font(RemileType.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, CGFloat(item.level) * 14).padding(.vertical, 5) }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(180, CGFloat(project.outline.count) * 40)) }
            }.font(RemileType.callout).padding(10)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                EditorSidebarBrand(compact: state.files)
                Button { state.settings.toggle() } label: { Label("Project settings", systemImage: "gearshape").font(RemileType.callout).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(RemileToolStyle())
                    .popover(isPresented: $state.settings, arrowEdge: .trailing) { TeXProjectSettings(project: project).frame(width: 440, height: 540) }
            }.padding(12)
            if !state.files { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(RemileStyle.sidebar)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.files)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.outline)
            .onAppear { state.nodes = TeXFileNode.tree(project.treeFiles) }
            .onChange(of: project.treeFiles) { state.nodes = TeXFileNode.tree(project.treeFiles) }
    }
}

private struct TeXFileRow: View {
    let node: TeXFileNode
    var depth: Int = 0
    @ObservedObject var project: TeXProject
    @StateObject private var state = RowState()
    private final class RowState: ObservableObject { @Published var expanded = true; @Published var rename = false }
    var body: some View {
        if let children = node.children {
            VStack(alignment: .leading, spacing: 2) {
                Button { state.expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.expanded ? "chevron.down" : "chevron.right").font(.system(size: 10)).frame(width: 10)
                        Image(systemName: "folder")
                        InlineName(value: node.name, editing: $state.rename) { project.rename(node.path, to: $0) }.font(RemileType.callout)
                    }.padding(.leading, CGFloat(depth) * 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).contextMenu { fileMenu }
                    .onDrag { NSItemProvider(object: project.root.appendingPathComponent(node.path) as NSURL) }
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in HomeFileDrop.receive(providers) { project.drop($0, into: node.path) }; return true }
                if state.expanded { ForEach(children) { child in TeXFileRow(node: child, depth: depth + 1, project: project) } }
            }
        } else {
            Button { if project.buffers[node.path] != nil { project.selected = node.path } } label: {
                HStack(spacing: 6) { Image(systemName: symbol); InlineName(value: node.name, editing: $state.rename) { project.rename(node.path, to: $0) } }.padding(.leading, CGFloat(depth) * 16 + 16).font(RemileType.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
                    .background(project.selected == node.path ? RemileStyle.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain).foregroundStyle(project.buffers[node.path] == nil ? RemileStyle.ink.opacity(0.5) : RemileStyle.ink).help(node.path)
                .contextMenu { fileMenu }
                .onDrag { NSItemProvider(object: project.root.appendingPathComponent(node.path) as NSURL) }
        }
    }
    @ViewBuilder private var fileMenu: some View {
        Button("Rename") { state.rename = true }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.root.appendingPathComponent(node.path)]) }
        Divider()
        Button("Move to Trash", role: .destructive) { project.trash(node.path) }.disabled(node.path == project.main)
    }
    private var symbol: String { node.path.hasSuffix(".bib") ? "books.vertical" : node.path.hasSuffix(".pdf") ? "doc.richtext" : "doc.text" }
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
