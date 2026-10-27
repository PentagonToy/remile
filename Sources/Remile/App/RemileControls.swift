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
            .modifier(RemilePointerFeedback())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

/// A short, mutually exclusive choice. Real buttons retain focus, keyboard and accessibility support.
struct RemileSegmentedControl<Selection: Hashable>: View {
    let title: String
    var inToolbar = false
    @Binding var selection: Selection
    let options: [Selection]
    let label: (Selection) -> String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option)).font(RemileType.control).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: RemileControl.height)
                        .background(selection == option ? RemileStyle.accent.opacity(inToolbar ? 0.16 : 0.22) : .clear, in: RoundedRectangle(cornerRadius: inToolbar ? 14 : RemileRadius.control))
                }.buttonStyle(.plain).accessibilityLabel(label(option))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }.padding(inToolbar ? 3 : 0)
            .background(inToolbar ? Color.clear : RemileStyle.surface, in: RoundedRectangle(cornerRadius: inToolbar ? 16 : RemileRadius.control))
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

/// App-owned toolbar controls draw one surface, without an extra system glass group.
struct RemileToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder let content: () -> Content
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: placement) { content().buttonStyle(.plain) }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content().buttonStyle(.plain) }
        }
    }
}

struct RemileNavigationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.frame(width: 20, height: 20)
            configuration.title
        }
    }
}

/// Pointer feedback is transient and local to each rendered control.
struct RemilePointerFeedback: ViewModifier {
    private final class Pointer: ObservableObject { @Published var hovering = false }
    @StateObject private var pointer = Pointer()
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: RemileRadius.control)
                .fill(RemileStyle.ink.opacity(enabled && pointer.hovering ? 0.045 : 0)).allowsHitTesting(false)
        }.onHover { pointer.hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pointer.hovering)
    }
}

/// Optical adjustments keep document actions balanced within fixed hit areas.
struct DocumentActionIcon: View {
    enum Action { case save, export }
    let action: Action
    var body: some View {
        Image(systemName: action == .save ? "square.and.arrow.down" : "tray.and.arrow.up")
            .font(.system(size: action == .save ? 15 : 13, weight: .regular)).imageScale(.medium).symbolRenderingMode(.monochrome)
            .offset(y: action == .save ? -1.5 : 0)
            .foregroundStyle(RemileStyle.ink).frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
