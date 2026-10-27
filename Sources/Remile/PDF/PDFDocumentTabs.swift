import SwiftUI

/// Only tab labels are rendered here. Existing window sessions own the PDF data.
struct PDFDocumentTabs: View {
    let reader: ReadingSession?
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
            }.padding(.horizontal, 10).frame(height: 38).background(RemileStyle.editorBar)
        }
    }

    private func documentTabs(for reader: ReadingSession, availableWidth: CGFloat) -> some View {
        let tabs = windows.documentTabs(for: reader)
        let selectedID = tabs.first(where: \.selected)?.id
        let spacing: CGFloat = 4
        let viewportWidth = max(0, availableWidth - RemileControl.toolHit - RemileControl.spacing)
        let gaps = CGFloat(max(0, tabs.count - 1)) * spacing
        let tabWidth = min(220, max(92, (viewportWidth - gaps) / CGFloat(max(1, tabs.count))))
        let contentWidth = CGFloat(tabs.count) * tabWidth + gaps

        return HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(tabs) { tab in
                            HStack(spacing: 2) {
                                Button { windows.selectDocumentTab(tab.id) } label: {
                                    Text(tab.title).font(RemileType.control).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 10).frame(height: 30).contentShape(Rectangle())
                                }.buttonStyle(.plain).remileHelp(tab.url.path)
                                    .accessibilityLabel(tab.title)
                                    .accessibilityAddTraits(tab.selected ? .isSelected : [])
                                Button { windows.closeDocumentTab(tab.id) } label: {
                                    SymbolIcon(systemName: "xmark")
                                        .foregroundStyle(.secondary).frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Close \(tab.title)")
                            }
                            .frame(width: tabWidth)
                            .foregroundStyle(tab.selected ? RemileStyle.ink : RemileStyle.ink.opacity(0.65))
                            .background(tab.selected ? RemileStyle.ink.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .id(tab.id)
                        }
                    }.padding(.vertical, 4)
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
