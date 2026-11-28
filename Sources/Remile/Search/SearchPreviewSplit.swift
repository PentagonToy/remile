import SwiftUI

/// Keep the PDF's identity and document alive when Ask opens or closes.
struct SearchPreviewSplit<Assistant: View, Preview: View>: View {
    var askPresented: Bool
    var label = "Ask panel"
    var revealToken = ""
    @ViewBuilder var assistant: () -> Assistant
    @ViewBuilder var preview: () -> Preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ReaderSplit(side: .trailing, isPresented: askPresented, animatesResizing: false, initial: 320, minimum: 260, maximum: 440, minimumContent: 280, label: label, revealToken: revealToken, pane: {
            ZStack {
                if askPresented { assistant().modifier(RemileNavigationContent()).transition(RemileMotion.arrival) }
            }.animation(reduceMotion ? nil : RemileMotion.panel, value: askPresented)
        }, content: {
            preview().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        })
    }
}
