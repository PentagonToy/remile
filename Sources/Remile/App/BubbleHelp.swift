import SwiftUI

/// Short hover help with native popover anchoring and an explicit keyboard/VoiceOver action.
private struct BubbleHelp: ViewModifier {
    let text: String
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var shown = false; var waiting: Task<Void, Never>? }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.onHover { inside in
            state.waiting?.cancel()
            if inside {
                state.waiting = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { state.shown = true }
                }
            } else { state.shown = false }
        }
        .popover(isPresented: $state.shown, arrowEdge: .bottom) {
            Text(text).font(RemileType.caption).fixedSize(horizontal: false, vertical: true)
                .padding(13).frame(width: 290, alignment: .leading).background(RemileStyle.background)
                .accessibilityAddTraits(.isStaticText)
        }
        .accessibilityHint(text).accessibilityAction(named: "Show help") { state.shown.toggle() }
        .onDisappear { state.waiting?.cancel(); state.shown = false }
    }
}
extension View {
    func bubbleHelp(_ text: String) -> some View { modifier(BubbleHelp(text: text)) }
}
