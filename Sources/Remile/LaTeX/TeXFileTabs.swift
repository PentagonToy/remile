import SwiftUI

/// File names and order only. All tabs share the project's existing editor and buffers.
struct TeXFileTabs: View {
    @ObservedObject var project: TeXProject
    var notice: String? = nil
    let showFiles: () -> Void
    @StateObject private var drag = TeXFileTabDragState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AnimationPolicy.preference) private var animations = true
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: RemileControl.spacing) {
                GeometryReader { geometry in tabs(width: geometry.size.width) }
                if let notice { Text(notice).font(RemileType.caption).foregroundStyle(RemileStyle.accent) }
                Divider().frame(height: RemileControl.separatorHeight).accessibilityHidden(true)
                ReaderThemeButton()
            }.padding(.horizontal, DocumentTabMetrics.inset)
                .frame(height: DocumentTabMetrics.height).background(RemileStyle.editorBar)
        }
    }
    private func tabs(width: CGFloat) -> some View {
        let gap = DocumentTabMetrics.spacing
        let viewport = max(0, width - RemileControl.toolHit - RemileControl.spacing)
        let gaps = CGFloat(max(0, project.openFiles.count - 1)) * gap
        let tabWidth = min(DocumentTabMetrics.maximumWidth, max(DocumentTabMetrics.minimumWidth, (viewport - gaps) / CGFloat(max(1, project.openFiles.count))))
        let contentWidth = CGFloat(project.openFiles.count) * tabWidth + gaps
        return HStack(spacing: RemileControl.spacing) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: gap) {
                        ForEach(project.openFiles, id: \.self) { file in
                            tab(file, width: tabWidth).id(file)
                        }
                    }.padding(.vertical, DocumentTabMetrics.spacing)
                        .animation(reduceMotion || !animations ? nil : .easeInOut(duration: 0.18), value: project.openFiles)
                }.frame(width: min(contentWidth, viewport))
                    .onAppear { proxy.scrollTo(project.selected) }
                    .onChange(of: project.selected) { _, file in proxy.scrollTo(file) }
                    .onChange(of: width) { _, _ in proxy.scrollTo(project.selected) }
                    .onChange(of: project.openFiles) { _, _ in proxy.scrollTo(project.selected) }
            }
            Menu {
                ForEach(Array(project.files.filter { !project.openFiles.contains($0) }.prefix(40)), id: \.self) { file in
                    Button(file) { project.selected = file }
                }
                Divider()
                Button("New file…") { project.newFile(); showFiles() }
                Button("Show project files") { showFiles() }
            } label: { SymbolIcon(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                .accessibilityLabel("Open a project file").remileHelp("Open a project file")
            Spacer(minLength: 0)
        }
    }
    private func tab(_ file: String, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text((file as NSString).lastPathComponent).font(RemileType.control)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, DocumentTabMetrics.inset).frame(height: DocumentTabMetrics.labelHeight)
                .accessibilityHidden(true)
                .overlay { TeXFileTabSurface(project: project, file: file, drag: drag, rename: {
                    project.newItemDraft = .init(kind: .rename(file)); showFiles()
                }) }
            Button { project.closeFileTab(file) } label: { SymbolIcon(systemName: "xmark").foregroundStyle(.secondary) }
                .buttonStyle(RemileToolStyle()).disabled(project.openFiles.count == 1)
                .accessibilityLabel("Close \((file as NSString).lastPathComponent)")
                .remileHelp("Close tab. Keep the file and its edits in the project.")
        }.frame(width: width)
            .foregroundStyle(file == project.selected ? RemileStyle.ink : RemileStyle.secondaryInk)
            .background(file == project.selected ? RemileStyle.ink.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: DocumentTabMetrics.radius))
            .overlay(alignment: drag.after ? .trailing : .leading) {
                Capsule().fill(RemileStyle.accent).frame(width: DocumentTabMetrics.markerWidth, height: DocumentTabMetrics.markerHeight)
                    .opacity(drag.target == file ? 1 : 0).allowsHitTesting(false)
            }
            .opacity(drag.source == file ? 0.45 : 1)
    }
}
