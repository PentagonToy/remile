import SwiftUI

/// Window controls share one readable type size and hit area. Document type stays independent.
enum RemileControl {
    static let height: CGFloat = 28
    static let spacing: CGFloat = 8
    static let rowSpacing: CGFloat = 12
}

struct RemileActionStyle: ButtonStyle {
    enum Emphasis: Equatable { case standard, primary, quiet }
    var emphasis: Emphasis = .standard
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(RemileType.control)
            .padding(.horizontal, emphasis == .quiet ? 6 : 10)
            .frame(minWidth: RemileControl.height, minHeight: RemileControl.height)
            .foregroundStyle(configuration.role == .destructive ? RemileStyle.warning : emphasis == .primary ? RemileStyle.onAccent : RemileStyle.ink)
            .background(emphasis == .primary ? RemileStyle.accent : emphasis == .quiet ? .clear : RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .contentShape(RoundedRectangle(cornerRadius: RemileRadius.control))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

/// A short, mutually exclusive choice. Real buttons retain focus, keyboard and accessibility support.
struct RemileSegmentedControl<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [Selection]
    let label: (Selection) -> String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option)).font(RemileType.control).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: RemileControl.height)
                        .background(selection == option ? RemileStyle.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                }.buttonStyle(.plain).accessibilityLabel(label(option))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }.background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Keep the value beside its native arrows while the setting name stays on the left.
struct RemileSettingsStepper<Value: Strideable & Comparable>: View where Value.Stride: SignedNumeric {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let formatted: String
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 8) {
                Text(formatted).monospacedDigit().fixedSize().accessibilityHidden(true)
                Stepper(title, value: $value, in: range).labelsHidden().fixedSize()
                    .accessibilityLabel(title).accessibilityValue(formatted)
            }.fixedSize()
        }
    }
}
