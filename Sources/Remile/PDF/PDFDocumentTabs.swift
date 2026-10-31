import SwiftUI

/// Only tab labels are rendered here. Existing window sessions own the PDF data.
struct PDFDocumentTabs: View {
    let reader: ReadingSession?
    @ObservedObject private var drag = PDFTabDragState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AnimationPolicy.preference) private var animations = true
    private var tabAnimation: Animation? { reduceMotion || !animations ? nil : .easeInOut(duration: 0.18) }
    @ObservedObject private var windows = RemileWindows.shared

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: RemileControl.spacing) {
                if let reader {
                    GeometryReader { geometry in
                        documentTabs(for: reader, availableWidth: geometry.size.width)
                    }
                } else { Spacer(minLength: 0) }
                Divider().frame(height: 16).accessibilityHidden(true)
                ReaderThemeButton()
            }.padding(.horizontal, DocumentTabMetrics.inset).frame(height: DocumentTabMetrics.height).background(RemileStyle.editorBar)
        }
    }

    private func documentTabs(for reader: ReadingSession, availableWidth: CGFloat) -> some View {
        let tabs = windows.documentTabs(for: reader)
        let selectedID = tabs.first(where: \.selected)?.id
        let spacing = DocumentTabMetrics.spacing
        let viewportWidth = max(0, availableWidth - RemileControl.toolHit - RemileControl.spacing)
        let gaps = CGFloat(max(0, tabs.count - 1)) * spacing
        let tabWidth = min(DocumentTabMetrics.maximumWidth, max(DocumentTabMetrics.minimumWidth, (viewportWidth - gaps) / CGFloat(max(1, tabs.count))))
        let contentWidth = CGFloat(tabs.count) * tabWidth + gaps

        return HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(tabs) { tab in
                            HStack(spacing: 2) {
                                Text(tab.title).font(RemileType.control).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, DocumentTabMetrics.inset).frame(height: DocumentTabMetrics.labelHeight).contentShape(Rectangle())
                                    .accessibilityHidden(true)
                                    .overlay { PDFTabDragSurface(id: tab.id, title: tab.title) }
                                Button { windows.closeDocumentTab(tab.id) } label: {
                                    SymbolIcon(systemName: "xmark")
                                        .foregroundStyle(.secondary).frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Close \(tab.title)")
                            }
                            .frame(width: tabWidth)
                            .foregroundStyle(tab.selected ? RemileStyle.ink : RemileStyle.ink.opacity(0.65))
                            .background(tab.selected ? RemileStyle.ink.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: DocumentTabMetrics.radius))
                            .overlay {
                                RoundedRectangle(cornerRadius: DocumentTabMetrics.radius)
                                    .stroke(RemileStyle.accent, lineWidth: 1)
                                    .opacity(drag.feedback?.target == tab.id ? 0.65 : 0)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: drag.feedback?.after == true ? .trailing : .leading) {
                                Capsule().fill(RemileStyle.accent).frame(width: 3, height: 24)
                                    .opacity(drag.feedback?.target == tab.id ? 1 : 0)
                                    .allowsHitTesting(false)
                            }
                            .opacity(drag.feedback?.source == tab.id ? 0.45 : 1)
                            .animation(tabAnimation, value: drag.feedback)
                            .id(tab.id)
                        }
                    }.padding(.vertical, DocumentTabMetrics.spacing)
                        .animation(tabAnimation, value: tabs.map(\.id))
                }
                .frame(width: min(contentWidth, viewportWidth))
                .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: availableWidth) { _, _ in
                    if let selectedID { proxy.scrollTo(selectedID) }
                }
                .onChange(of: tabs.count) { _, _ in
                    if let selectedID { proxy.scrollTo(selectedID) }
                }
            }.padding(.trailing, RemileControl.spacing)
            Button { windows.addDocumentTab(for: reader) } label: {
                SymbolIcon(systemName: "plus").frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
            }.buttonStyle(.plain).accessibilityLabel("Open another document").remileHelp("Open another document")
            Spacer(minLength: 0)
        }
    }
}
