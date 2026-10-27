import SwiftUI
import AppKit

enum ReaderSidebar {
    static let minimum: CGFloat = 200
    static let maximum: CGFloat = 440
    static func preferredWidth(in available: CGFloat) -> CGFloat { WorkspaceLayout.navigation(available) }
}

/// Only the central grip resizes a pane. The remaining divider is visual, not a drag target.
struct ReaderSplit<Pane: View, Content: View>: View {
    enum Side { case leading, trailing }
    enum Sizing { case fixed, sidebar, equal, outline, files, results }
    var side: Side = .leading
    var sizing: Sizing = .fixed
    var isPresented = true
    var initial: CGFloat = 280
    var minimum: CGFloat = 240
    var maximum: CGFloat = 440
    var minimumContent: CGFloat = 380
    var preferPaneWhenNarrow = false
    var label = "Sidebar"
    var revealToken = ""
    @ViewBuilder let pane: () -> Pane
    @ViewBuilder let content: () -> Content
    @StateObject private var state = SplitState()
    private final class SplitState: ObservableObject {
        @Published var width: CGFloat?
        var origin: CGFloat?
        @Published var collapsed = 0
    }
    static var handleWidth: CGFloat { 24 }
    static func constrained(_ width: CGFloat, available: CGFloat, minimum: CGFloat, maximum: CGFloat, content: CGFloat) -> CGFloat {
        min(max(minimum, available - handleWidth - content), max(minimum, min(maximum, width)))
    }
    var body: some View {
        GeometryReader { geometry in
            let preferred: CGFloat = switch sizing {
            case .sidebar: WorkspaceLayout.navigation(geometry.size.width)
            case .outline: WorkspaceLayout.outline(geometry.size.width)
            case .files: WorkspaceLayout.files(geometry.size.width)
            case .results: WorkspaceLayout.results(geometry.size.width)
            case .equal: (geometry.size.width - Self.handleWidth) / 2
            case .fixed: initial
            }
            let width = Self.constrained(state.width ?? preferred, available: geometry.size.width, minimum: minimum, maximum: maximum, content: minimumContent)
            let narrow = geometry.size.width < minimum + minimumContent + Self.handleWidth
            let gutter: CGFloat = isPresented ? Self.handleWidth : 0
            let effective: CGFloat = !isPresented ? 0 : state.collapsed < 0 ? 0 : state.collapsed > 0 ? max(0, geometry.size.width - Self.handleWidth) : narrow ? (preferPaneWhenNarrow ? max(0, geometry.size.width - Self.handleWidth) : 0) : width
            let remaining = max(0, geometry.size.width - gutter - effective)
            HStack(spacing: 0) {
                if side == .leading {
                    pane().frame(width: effective, alignment: .leading).clipped().allowsHitTesting(effective > 0).accessibilityHidden(effective == 0)
                    grip(width: width, available: geometry.size.width).frame(width: gutter).clipped().allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
                    content().frame(width: remaining, alignment: .leading).clipped().allowsHitTesting(remaining > 0).accessibilityHidden(remaining == 0)
                } else {
                    content().frame(width: remaining, alignment: .leading).clipped().allowsHitTesting(remaining > 0).accessibilityHidden(remaining == 0)
                    grip(width: width, available: geometry.size.width).frame(width: gutter).clipped().allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
                    pane().frame(width: effective, alignment: .leading).clipped().allowsHitTesting(effective > 0).accessibilityHidden(effective == 0)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .coordinateSpace(name: "reader.split." + label)
                .transaction { if state.origin != nil { $0.animation = nil } }
                .animation(reduceMotion ? nil : RemileMotion.panel, value: state.collapsed)
                .animation(reduceMotion ? nil : RemileMotion.panel, value: isPresented)
                .onAppear {
                    let saved = UserDefaults.standard.double(forKey: WorkspaceLayout.key(label))
                    if saved.isFinite, saved >= minimum, saved <= maximum { state.width = saved }
                }
                .onChange(of: state.width) { if let width = state.width { UserDefaults.standard.set(Double(width), forKey: WorkspaceLayout.key(label)) } }
                .onChange(of: revealToken) { state.collapsed = 0 }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func grip(width: CGFloat, available: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(RemileStyle.accent.opacity(0.16)).frame(width: 1).allowsHitTesting(false)
            if state.collapsed != 0 || available < minimum + minimumContent + Self.handleWidth {
                Button { state.collapsed = state.collapsed == 0 ? (preferPaneWhenNarrow ? -1 : 1) : 0 } label: {
                    SymbolIcon(systemName: (state.collapsed < 0 || (state.collapsed == 0 && !preferPaneWhenNarrow)) == (side == .leading) ? "chevron.right" : "chevron.left").frame(width: 14, height: 40).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).frame(width: Self.handleWidth, height: 44).contentShape(Rectangle()).remileHelp("Restore split view").accessibilityLabel("Restore " + label)
            } else {
            HStack(spacing: 2) {
                ForEach(0..<3) { _ in Capsule().fill(RemileStyle.accent.opacity(0.85)).frame(width: 1, height: 11) }
            }.frame(width: 12, height: 40)
                .background(RemileStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(RemileStyle.accent.opacity(0.30)))
                .frame(width: Self.handleWidth, height: 60).contentShape(Rectangle().inset(by: -5))
                .background(ResizeCursorRegion().allowsHitTesting(false))
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("reader.split." + label)).onChanged { event in
                    if state.origin == nil { state.origin = width }
                    let delta = event.translation.width * (side == .leading ? 1 : -1)
                    state.width = Self.constrained((state.origin ?? width) + delta, available: available, minimum: minimum, maximum: maximum, content: minimumContent)
                }.onEnded { event in
                    let proposed = (state.origin ?? width) + event.translation.width * (side == .leading ? 1 : -1)
                    if proposed < minimum * 0.55 { state.collapsed = -1 }
                    else if proposed > available - Self.handleWidth - minimumContent * 0.45 { state.collapsed = 1 }
                    state.origin = nil
                })
                .accessibilityElement().accessibilityLabel("Resize " + label).accessibilityValue("\(Int(width)) points")
                .accessibilityAdjustableAction { direction in
                    state.width = Self.constrained(width + (direction == .increment ? 20 : -20), available: available, minimum: minimum, maximum: maximum, content: minimumContent)
                }.accessibilityAction(named: "Collapse " + label) { state.collapsed = -1 }.remileHelp("Resize " + label)
            }
        }.frame(width: Self.handleWidth).frame(maxHeight: .infinity)
    }
}
struct ResizeCursorRegion: NSViewRepresentable {
    final class Region: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Region { let view = Region(); view.identifier = NSUserInterfaceItemIdentifier("reader.resize-grip"); return view }
    func updateNSView(_ view: Region, context: Context) { view.window?.invalidateCursorRects(for: view) }
}
