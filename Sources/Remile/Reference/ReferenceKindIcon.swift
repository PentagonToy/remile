import SwiftUI

struct ReferenceKindIcon: View {
    let kind: ReferenceKind
    var hasAttachment = false
    var body: some View {
        SymbolIcon(systemName: kind.symbol).symbolRenderingMode(.monochrome)
            .frame(width: 18, height: 18).foregroundStyle(RemileStyle.accent)
            .overlay(alignment: .bottomTrailing) {
                if hasAttachment {
                    Circle().fill(RemileStyle.accent).frame(width: 5, height: 5)
                        .padding(2).background(RemileStyle.background, in: Circle()).offset(x: 4, y: 3)
                }
            }.accessibilityLabel(kind.label + (hasAttachment ? ", PDF attached" : ""))
    }
}
