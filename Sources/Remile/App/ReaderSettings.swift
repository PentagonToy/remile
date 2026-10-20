import SwiftUI

private final class SettingsPresentation: ObservableObject {
    @Published var historyMessage: String?
    @Published var confirmClear = false
    @Published var section = "General"
}

struct ReaderSettings: View {
    @AppStorage("markdown.autoPair") private var autoPair = true
    @AppStorage("markdown.livePreview") private var livePreview = true
    @AppStorage(ReaderScrolling.preference) private var elasticScrolling = true
    @AppStorage(PaperSize.preference) private var paper = PaperSize.a4.rawValue
    @AppStorage(PaperSize.landscapePreference) private var landscape = false
    @AppStorage("reader.markdownSerif") private var serif = false
    @AppStorage(ReaderAppearance.preference) private var appearance = ReaderAppearance.system.rawValue
    @AppStorage(ReaderZoom.preference) private var markdownZoom = 100
    @AppStorage(AssistantResponseDetail.preference) private var responseDetail = AssistantResponseDetail.mid.rawValue
    @AppStorage(AssistantHistoryRetention.preference) private var retention = AssistantHistoryRetention.days30.rawValue
    @StateObject private var presentation = SettingsPresentation()

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.system(size: 24, weight: .semibold)); Spacer() }.padding(22)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    category("General", symbol: "slider.horizontal.3")
                    category("Ask", symbol: "sparkles")
                    category("LaTeX", symbol: "doc.text")
                    Spacer()
                }.padding(14).frame(width: 155).frame(maxHeight: .infinity).background(RemileStyle.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(presentation.section).font(.system(size: 21, weight: .semibold)).padding(.horizontal, 22).padding(.top, 20)
                    if presentation.section == "General" { Form {
                        Section("Appearance") {
                            Picker("Theme", selection: $appearance) {
                                ForEach(ReaderAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                            }.pickerStyle(.segmented)
                        }
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
                    else if presentation.section == "LaTeX" { TeXSettings() }
                    else { Form {
                        Section("Responses") {
                            Picker("Detail", selection: $responseDetail) {
                                ForEach(AssistantResponseDetail.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                            }.pickerStyle(.segmented)
                        }
                        Section("Conversation history") {
                            Picker("Keep conversations", selection: $retention) {
                                ForEach(AssistantHistoryRetention.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                            }.onChange(of: retention) {
                                do { try AssistantHistory.applyRetention(); presentation.historyMessage = nil }
                                catch { presentation.historyMessage = "Unable to update Ask history." }
                            }
                            HStack {
                                Text("Saved locally on this Mac").foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear History…", role: .destructive) { presentation.confirmClear = true }
                            }
                            if let message = presentation.historyMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.formStyle(.grouped).scrollContentBackground(.hidden) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 720, height: 560).background(RemileStyle.background)
            .confirmationDialog("Clear all Ask conversations?", isPresented: $presentation.confirmClear) {
                Button("Clear History", role: .destructive) {
                    do { try AssistantHistory.clearAll(); presentation.historyMessage = "History cleared." }
                    catch { presentation.historyMessage = "Unable to clear Ask history." }
                }
            } message: { Text("This removes saved conversations from this Mac.") }
    }
    private func category(_ name: String, symbol: String) -> some View {
        Button { presentation.section = name } label: {
            Label(name, systemImage: symbol).font(RemileType.body).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(presentation.section == name ? RemileStyle.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityValue(presentation.section == name ? "Selected" : "")
    }

}
