import SwiftUI

private final class SettingsPresentation: ObservableObject {
    @Published var section = "General"
}

struct ReaderSettings: View {
    @AppStorage("editor.sidebarArtwork") private var sidebarArtwork = true
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @AppStorage(ReaderScrolling.preference) private var elasticScrolling = true
    @AppStorage(ReaderAppearance.preference) private var appearance = ReaderAppearance.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var windows = RemileWindows.shared
    @StateObject private var presentation = SettingsPresentation()

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(RemileType.windowTitle); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    category("General", symbol: "slider.horizontal.3")
                    category("Storage", symbol: "externaldrive")
                    Color.clear.frame(height: 8).accessibilityHidden(true)
                    category("Search", symbol: "magnifyingglass")
                    category("PDF", symbol: "doc.richtext")
                    category("Markdown", symbol: "square.and.pencil")
                    category("LaTeX", symbol: "doc.text")
                    Color.clear.frame(height: 8).accessibilityHidden(true)
                    category("AI", symbol: "sparkles")
                    Spacer()
                }.padding(14).frame(width: 166).frame(maxHeight: .infinity).background(RemileStyle.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(presentation.section).font(RemileType.heading).padding(.horizontal, 22).padding(.top, 20)
                    if presentation.section == "General" { Form {
                        Section("Version & updates") { RemileUpdateSettings() }
                        Section("Appearance") {
                            Toggle("Sidebar artwork", isOn: $sidebarArtwork)
                            Toggle("Animations", isOn: $animations)
                            HStack { Text("Theme"); Spacer(); RemileSegmentedControl(title: "Theme", selection: $appearance, options: ReaderAppearance.allCases.map(\.rawValue), label: { $0 }).frame(width: 240) }
                        }
                        Section("Network") { OfflineModeControl(); SettingsHint("Pause online services. Keep working locally.") }
                        Section("Reading") { Toggle("Elastic scrolling", isOn: $elasticScrolling) }
                        Section("Language") { EditorLanguageSettings() }
                    }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control) }
                    else if presentation.section == "Storage" { StorageSettings() }
                    else if presentation.section == "Search" { LibrarySearchSettings() }
                    else if presentation.section == "Markdown" { MarkdownSettingsForm() }
                    else if presentation.section == "PDF" { PDFSettingsForm() }
                    else if presentation.section == "LaTeX" { TeXSettings(project: windows.active?.texProject) }
                    else { Form {
                        Section("AI assistance") { ChatGPTSettings(showsHeading: false) }
                    }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(RemileStyle.background).smoothScrolling()
            }
        }.font(RemileType.control).buttonStyle(RemileActionStyle()).toggleStyle(.switch).frame(width: 720, height: 560).background(RemileStyle.background).presentationBackground(RemileStyle.background)
    }
    private func category(_ name: String, symbol: String) -> some View {
        Button { presentation.section = name } label: {
            Label(name, systemImage: symbol).labelStyle(RemileNavigationLabelStyle()).font(RemileType.control).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(presentation.section == name ? RemileStyle.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityValue(presentation.section == name ? "Selected" : "")
    }

}

struct LibrarySearchSettings: View {
    @AppStorage(SearchBoostPolicy.preference) private var boostingEnabled = true
    @AppStorage(SearchQuestion.spellingPreference) private var spellingSuggestions = true
    @AppStorage(SearchScope.bibliographyPreference) private var includeBibliography = false
    var body: some View {
        Form {
            Section("Search boosting") {
                Toggle("Boost search with Apple Intelligence", isOn: $boostingEnabled)
                SettingsHint("Apple Intelligence expands questions on this Mac.")
                SettingsHint("Offline and Manual use standard search.")
            }
            Section("Suggestions") {
                Toggle("Suggest spelling corrections", isOn: $spellingSuggestions)
                SettingsHint("Choose a correction when no matches are found.")
            }
            Section("Search scope") {
                Toggle("Include bibliography matches", isOn: $includeBibliography)
                SettingsHint("Search detected reference lists as well as the main text.")
            }
            Section("Your library") {
                SettingsHint("Manage folders and refresh files in Library.")
                SettingsHint("Search stays on this Mac.")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control)
    }
}

struct PDFSettingsForm: View {
    @AppStorage(PaperSize.preference) private var paper = PaperSize.a4.rawValue
    @AppStorage(PaperSize.landscapePreference) private var landscape = false
    var body: some View {
        Form {
            Section("Page defaults") {
                Picker("Paper", selection: $paper) { ForEach(PaperSize.allCases) { Text($0.rawValue + " · " + $0.dimensions).tag($0.rawValue) } }
                HStack { Text("Orientation"); Spacer(); RemileSegmentedControl(title: "Orientation", selection: $landscape, options: [false, true], label: { $0 ? "Landscape" : "Portrait" }).frame(width: 220) }
                SettingsHint("Used when creating and exporting PDFs.")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control)
    }
}
