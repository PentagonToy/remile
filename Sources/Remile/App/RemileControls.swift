import SwiftUI

/// Window controls share one readable type size and hit area. Document type stays independent.
enum RemileControl {
    static let height: CGFloat = 28
    static let spacing: CGFloat = 8
    static let rowSpacing: CGFloat = 12
    static let toolHit: CGFloat = 32
    static let iconSlot: CGFloat = 20
    static let separatorHeight: CGFloat = 18
}

enum DocumentTabMetrics {
    static let height: CGFloat = 38
    static let labelHeight: CGFloat = 30
    static let minimumWidth: CGFloat = 92
    static let maximumWidth: CGFloat = 220
    static let spacing: CGFloat = 4
    static let inset: CGFloat = 10
    static let radius: CGFloat = 6
    static let markerWidth: CGFloat = 3
    static let markerHeight: CGFloat = 24
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
        HStack(spacing: RemileControl.spacing) {
            configuration.icon.frame(width: RemileControl.iconSlot, height: RemileControl.iconSlot)
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
        SymbolIcon(systemName: action == .save ? "square.and.arrow.down" : "tray.and.arrow.up",
                   opticalOffset: action == .save ? RemileSymbol.saveOffset : 0)
            .font(.system(size: action == .save ? RemileSymbol.saveSize : RemileSymbol.exportSize))
            .foregroundStyle(RemileStyle.ink).accessibilityHidden(true)
    }
}


enum RemileSymbol {
    static let size: CGFloat = 14
    static let smallSize: CGFloat = 10
    static let emptySlot: CGFloat = 44
    static let emptySize: CGFloat = 32
    static let saveSize: CGFloat = 15
    static let exportSize: CGFloat = 13
    static let saveOffset: CGFloat = -1.5
    static let statusDotSize: CGFloat = 5
    static let statusDotInset: CGFloat = 1
    static let statusDotBorder: CGFloat = 1
}

/// All app-owned SF Symbols share a centred slot and rendering configuration.
struct SymbolIcon: View {
    let systemName: String
    var slot: CGFloat = RemileControl.iconSlot
    var opticalOffset: CGFloat = 0
    var body: some View {
        Image(systemName: systemName)
            .fontWeight(.regular).imageScale(.medium).symbolRenderingMode(.monochrome)
            .offset(y: opticalOffset)
            .frame(width: slot, height: slot, alignment: .center)
    }
    static func nativeImage(systemName: String, description: String?) -> NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: RemileSymbol.size, weight: .regular, scale: .medium))
    }
}

/// Labels retain native title-only and icon-only styles while sharing the symbol renderer.
struct SymbolLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View { Label { Text(title) } icon: { SymbolIcon(systemName: systemImage) } }
}

struct SymbolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: RemileControl.spacing) { configuration.icon; configuration.title }
    }
}

struct WorkspaceBackButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { SymbolIcon(systemName: "chevron.left").frame(width: RemileControl.toolHit, height: RemileControl.toolHit).contentShape(Rectangle()) }
            .buttonStyle(RemileToolStyle()).accessibilityLabel(title).remileHelp(title)
    }
}
