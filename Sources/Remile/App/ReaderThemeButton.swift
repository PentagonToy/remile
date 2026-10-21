import SwiftUI

/// One click changes the document workspace; System remains available in Settings.
struct ReaderThemeButton: View {
    @AppStorage(ReaderAppearance.preference) private var selection = ReaderAppearance.system.rawValue
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button { selection = scheme == .dark ? ReaderAppearance.light.rawValue : ReaderAppearance.dark.rawValue } label: {
            Image(systemName: scheme == .dark ? "sun.max" : "moon")
                .font(.system(size: 16)).frame(width: 28, height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(scheme == .dark ? "Switch to light theme" : "Switch to dark theme")
            .accessibilityValue(selection).remileHelp(scheme == .dark ? "Switch to light theme · System is available in Settings" : "Switch to dark theme · System is available in Settings")
    }
}

struct ReaderThemeFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack { Spacer(); ReaderThemeButton() }.padding(.horizontal, 12).frame(height: 32).background(RemileStyle.editorBar)
        }
    }
}
