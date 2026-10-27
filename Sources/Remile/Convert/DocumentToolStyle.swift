import SwiftUI

struct DocumentToolHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            SymbolIcon(systemName: symbol)
                .foregroundStyle(RemileStyle.accent).frame(width: 44, height: 44)
                .background(RemileStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(RemileType.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct DocumentToolEmptyState: View {
    let symbols: [String]
    let title: String
    let detail: String
    let button: String
    let formats: String
    let choose: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: -10) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                    SymbolIcon(systemName: symbol, slot: RemileSymbol.emptySlot).font(.system(size: RemileSymbol.emptySize)).foregroundStyle(RemileStyle.accent)
                        .frame(width: 66, height: 80).background(RemileStyle.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RemileStyle.accent.opacity(0.12)))
                        .rotationEffect(.degrees(Double(index) * 10 - Double(symbols.count - 1) * 5))
                }
            }.padding(.bottom, 8).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(detail).font(RemileType.callout).foregroundStyle(.secondary).lineSpacing(4)
            }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(button, action: choose).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            Text(formats).font(RemileType.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(RemileStyle.accent.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
            .padding(24)
    }
}
