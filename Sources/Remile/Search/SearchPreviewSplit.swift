import SwiftUI

/// Keep the PDF's identity and document alive when Ask opens or closes.
struct SearchPreviewSplit<Assistant: View, Preview: View>: View {
    var askPresented: Bool
    var label = "Ask panel"
    @ViewBuilder var assistant: () -> Assistant
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        ReaderSplit(side: .trailing, isPresented: askPresented, initial: 320, minimum: 260, maximum: 440, minimumContent: 280, label: label, pane: {
            if askPresented { assistant() }
        }, content: {
            preview().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        })
    }
}
