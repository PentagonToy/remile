import SwiftUI

struct WriterColumns: View {
    @ObservedObject var model: WriterModel
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            if compact { Text("Columns").foregroundStyle(.secondary) }
            ForEach(1...2, id: \.self) { count in
                Button {
                    var page = model.pageStyle; page.columns = count; model.setPageStyle(page)
                } label: {
                    Group {
                        if compact {
                            HStack(spacing: 5) { symbol(count); Text(String(count)) }.padding(.horizontal, 7).frame(height: 26)
                        } else {
                            VStack(spacing: 8) { symbol(count).scaleEffect(1.3).frame(height: 28); Text(count == 1 ? "1 column" : "2 columns") }
                                .frame(maxWidth: .infinity).frame(height: 66)
                        }
                    }
                    .foregroundStyle(RemileStyle.ink)
                    .background(model.pageStyle.columnCount == count ? RemileStyle.accent.opacity(0.15) : RemileStyle.editorBar, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(count == 1 ? "1 column" : "2 columns")
                    .accessibilityAddTraits(model.pageStyle.columnCount == count ? .isSelected : [])
                    .remileHelp(count == 1 ? "One column for this document" : "Two columns for this document")
            }
        }.font(RemileType.small)
    }
    private func symbol(_ count: Int) -> some View {
        Image(systemName: count == 1 ? "rectangle" : "rectangle.split.2x1")
            .font(RemileType.control).symbolRenderingMode(.monochrome)
            .frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
