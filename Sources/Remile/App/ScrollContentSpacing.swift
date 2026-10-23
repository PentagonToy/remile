import SwiftUI

/// Space inside the scrolling viewport, reserved even for overlay scrollbars.
enum ScrollContentSpacing {
    static let gutter: CGFloat = 18
}

extension View {
    func scrollContentGutter() -> some View { padding(.trailing, ScrollContentSpacing.gutter) }
}
