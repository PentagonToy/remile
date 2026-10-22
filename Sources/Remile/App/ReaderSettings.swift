import SwiftUI

private final class SettingsPresentation: ObservableObject {
    @Published var section = "General"
}

struct ReaderSettings: View {
    @AppStorage("markdown.autoPair") private var autoPair = true
    @AppStorage("markdown.livePreview") private var livePreview = true
    @AppStorage("editor.sidebarArtwork") private var sidebarArtwork = true
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @AppStorage(ReaderScrolling.preference) private var elasticScrolling = true
    @AppStorage(PaperSize.preference) private var paper = PaperSize.a4.rawValue
    @AppStorage(PaperSize.landscapePreference) private var landscape = false
    @AppStorage("reader.markdownSerif") private var serif = false
    @AppStorage(ReaderAppearance.preference) private var appearance = ReaderAppearance.system.rawValue
    @AppStorage(ReaderZoom.preference) private var markdownZoom = 100
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var windows = RemileWindows.shared
    @StateObject private var presentation = SettingsPresentation()

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.system(size: 24, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    category("General", symbol: "slider.horizontal.3")
                    category("AI", symbol: "sparkles")
                    category("Search", symbol: "magnifyingglass")
                    category("LaTeX", symbol: "doc.text")
                    Spacer()
                }.padding(14).frame(width: 155).frame(maxHeight: .infinity).background(RemileStyle.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(presentation.section).font(.system(size: 21, weight: .semibold)).padding(.horizontal, 22).padding(.top, 20)
                    if presentation.section == "General" { Form {
                        Section("Version & updates") { RemileUpdateSettings() }
                        Section("Appearance") {
                            Toggle("Sidebar artwork", isOn: $sidebarArtwork)
                            Toggle("Animations", isOn: $animations)
                            Picker("Theme", selection: $appearance) {
                                ForEach(ReaderAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                            }.pickerStyle(.segmented)
                        }
                        Section("Network") { OfflineModeControl(); SettingsHint("Pause online services. Keep working locally.") }
                        Section("Reading") {
                            Toggle("Serif text in Markdown", isOn: $serif)
                            Toggle("Elastic scrolling", isOn: $elasticScrolling)
                            Picker("Default Markdown zoom", selection: $markdownZoom) {
                                ForEach([75, 90, 100, 110, 125, 150, 200], id: \.self) { Text("\($0)%").tag($0) }
                            }

                        }
                        Section("Language") { EditorLanguageSettings() }
                        Section("Markdown editor") {
                            Toggle("Live preview", isOn: $livePreview)
                            Toggle("Pair brackets and math delimiters", isOn: $autoPair)
                        }
                        Section("PDF") {
                            Picker("Default paper", selection: $paper) {
                                ForEach(PaperSize.allCases) { size in Text(size.rawValue + " · " + size.dimensions).tag(size.rawValue) }
                            }
                            Picker("Orientation", selection: $landscape) {
                                Text("Portrait").tag(false)
                                Text("Landscape").tag(true)
                            }.pickerStyle(.segmented)
                        }
                    }.formStyle(.grouped).scrollContentBackground(.hidden) }
                    else if presentation.section == "Search" { LibrarySearchSettings() }
                    else if presentation.section == "LaTeX" { TeXSettings(project: windows.active?.texProject) }
                    else { Form {
                        Section("AI assistance") { ChatGPTSettings(showsHeading: false) }
                    }.formStyle(.grouped).scrollContentBackground(.hidden) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(RemileStyle.background).smoothScrolling()
            }
        }.frame(width: 720, height: 560).background(RemileStyle.background).presentationBackground(RemileStyle.background)
    }
    private func category(_ name: String, symbol: String) -> some View {
        Button { presentation.section = name } label: {
            Label(name, systemImage: symbol).font(RemileType.body).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(presentation.section == name ? RemileStyle.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityValue(presentation.section == name ? "Selected" : "")
    }

}

struct LibrarySearchSettings: View {
    @AppStorage(SearchBoostPolicy.preference) private var boostingEnabled = true
    @AppStorage(SearchQuestion.spellingPreference) private var spellingSuggestions = true
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
            Section("Your library") {
                SettingsHint("Manage folders and refresh files in Library.")
                SettingsHint("Search stays on this Mac.")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
