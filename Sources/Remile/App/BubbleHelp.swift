import SwiftUI

/// Short hover help with native popover anchoring and an explicit keyboard/VoiceOver action.
private struct BubbleHelp: ViewModifier {
    let text: String
    private let style = HelpBubbleStyle.standard
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var shown = false; var waiting: Task<Void, Never>? }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.onHover { inside in
            state.waiting?.cancel()
            if inside {
                state.waiting = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(style.hoverDelayMilliseconds)) } catch { return }
                    withAnimation(reduceMotion || !animations ? nil : .easeOut(duration: style.animationSeconds)) { state.shown = true }
                }
            } else { state.shown = false }
        }
        .popover(isPresented: $state.shown, arrowEdge: .bottom) {
            HelpBubbleContent(text: text)
        }
        .accessibilityHint(text).accessibilityAction(named: "Show help") { state.shown.toggle() }
        .onDisappear { state.waiting?.cancel(); state.shown = false }
    }
}
struct HelpBubbleContent: View {
    let text: String
    private let style = HelpBubbleStyle.standard
    var body: some View {
        Text(text).font(.system(size: style.fontSize)).fixedSize(horizontal: false, vertical: true)
            .padding(style.padding).frame(width: style.width, alignment: .leading).background(RemileStyle.background)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    func bubbleHelp(_ text: String) -> some View { modifier(BubbleHelp(text: text)) }
}
