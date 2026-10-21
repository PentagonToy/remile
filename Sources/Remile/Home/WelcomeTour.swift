import SwiftUI

extension Notification.Name { static let remileReplayTour = Notification.Name("remile.replayTour") }

struct TourTarget: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
extension View {
    func tourTarget(_ id: String) -> some View { transformAnchorPreference(key: TourTarget.self, value: .bounds) { targets, anchor in targets[id] = anchor }.id(id) }
}

final class WelcomeTourProgress: ObservableObject { @Published var step = 0; @Published var replay = false }

/// The home screen provides anchors; the tour owns only presentation and completion.
@MainActor struct WelcomeTour: ViewModifier {
    struct Step {
        let target: String, title: String, detail: String
    }
    static let steps = [
        Step(target: "open", title: "Your documents, close at hand", detail: "Open a PDF or Markdown document to read, highlight and ask about it."),
        Step(target: "search", title: "Find the passage", detail: "Add folders to your search library and index them on this Mac. Results take you straight to the matching page."),
        Step(target: "markdown", title: "Write in Markdown", detail: "Start a note and switch between writing and reading. Save your changes to the same file."),
        Step(target: "latex", title: "Work with LaTeX", detail: "Open a project, edit its source and compile a PDF. Errors explain what needs attention."),
        Step(target: "overleaf", title: "Keep Overleaf within reach", detail: "Connect a project. Online sends your local edits automatically; new remote changes wait for review."),
        Step(target: "tools", title: "A few useful tools", detail: "Convert documents, reduce PDF size or combine files when you need to."),
        Step(target: "settings", title: "Make it yours", detail: "Choose appearance, AI, search and typesetting preferences here."),
        Step(target: "guide", title: RemileBrand.tagline, detail: "You can return to the User guide whenever you need a hand. remile.")
    ]
    @AppStorage("welcome.tourCompleted.v1") private var completed = false
    @StateObject private var state: WelcomeTourProgress
    init(enabled: Bool, openGuide: @escaping () -> Void, progress: WelcomeTourProgress? = nil) { self.enabled = enabled; self.openGuide = openGuide; _state = StateObject(wrappedValue: progress ?? WelcomeTourProgress()) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool
    let openGuide: () -> Void
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TourTarget.self) { anchors in
            if enabled && (!completed || state.replay) {
                GeometryReader { proxy in
                    let item = Self.steps[min(state.step, Self.steps.count - 1)]
                    let resolved = anchors[item.target].map { proxy[$0].insetBy(dx: -5, dy: -5) }
                    let visible = resolved.map { $0.intersects(CGRect(origin: .zero, size: proxy.size)) } ?? false
                    let target = visible ? resolved! : CGRect(x: proxy.size.width / 2, y: proxy.size.height / 2, width: 0, height: 0)
                    Group {
                        let width = min(340.0, max(240.0, proxy.size.width - 32))
                        let x = min(max(width / 2 + 16, target.midX), proxy.size.width - width / 2 - 16)
                        let y = target.maxY + 260 < proxy.size.height ? target.maxY + 132 : max(140, target.minY - 132)
                        ZStack(alignment: .topLeading) {
                            SpotlightShape(hole: visible ? target : .zero).fill(.black.opacity(0.56), style: FillStyle(eoFill: true)).contentShape(Rectangle()).onTapGesture {}
                            RoundedRectangle(cornerRadius: 10).stroke(visible ? RemileStyle.accent : .clear, lineWidth: 2).frame(width: target.width, height: target.height).position(x: target.midX, y: target.midY).allowsHitTesting(false)
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Text("\(state.step + 1) of \(Self.steps.count)").foregroundStyle(.secondary).accessibilityIdentifier("tour.step"); Spacer(); Button("Skip") { finish() }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }.font(RemileType.caption)
                                Text(item.title).font(RemileType.heading)
                                Text(item.detail).font(RemileType.callout).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    if state.step > 0 { Button("Back") { state.step -= 1 } }
                                    Spacer()
                                    Button(state.step == Self.steps.count - 1 ? "Done" : "Next") { if state.step == Self.steps.count - 1 { finish() } else { state.step += 1 } }.keyboardShortcut(.defaultAction).accessibilityIdentifier("tour.next")
                                    if state.step == Self.steps.count - 1 { Button("User guide") { finish(); openGuide() } }
                                }
                            }.padding(20).frame(width: width).background(RemileStyle.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(RemileStyle.accent.opacity(0.35))).shadow(color: .black.opacity(0.25), radius: 20, y: 8).position(x: x, y: y)
                        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
                        .animation(reduceMotion ? nil : .timingCurve(0.22, 0.7, 0.25, 1, duration: 0.58), value: state.step)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remileReplayTour)) { _ in state.step = 0; state.replay = true }
    }
    private func finish() { completed = true; state.replay = false; state.step = 0 }
}
private struct SpotlightShape: Shape {
    var hole: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.origin.x, hole.origin.y), .init(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path { var path = Path(rect); path.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10)); return path }
}
