import SwiftUI

/// Detail shown only after an explicit click. Hover hints use remileHelp.
struct HelpBubbleContent: View {
    let text: String
    private let style = HelpBubbleStyle.standard
    var body: some View {
        Text(text).font(.system(size: style.fontSize)).fixedSize(horizontal: false, vertical: true)
            .padding(style.padding).frame(width: style.width, alignment: .leading).background(RemileStyle.background)
            .accessibilityAddTraits(.isStaticText)
    }
}
