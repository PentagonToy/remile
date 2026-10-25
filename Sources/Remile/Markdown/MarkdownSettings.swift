import SwiftUI

/// The editor and app settings present the same preferences.
struct MarkdownSettingsForm: View {
    @AppStorage("markdown.lineNumbers") private var numbers = false
    @AppStorage("markdown.fontSize") private var size = 18.0
    @AppStorage("markdown.spellcheck") private var spelling = true
    @AppStorage("markdown.livePreview") private var live = true
    @AppStorage("markdown.autoPair") private var autoPair = true
    @AppStorage("reader.markdownSerif") private var serif = false
    @AppStorage(ReaderZoom.preference) private var zoom = 100
    var body: some View {
        Form {
            Section("Editor") {
                RemileSettingsStepper(title: "Source text", value: $size, range: 11...32, formatted: "\(Int(size)) pt")
                Toggle("Line numbers", isOn: $numbers)
                Toggle("Check spelling and grammar", isOn: $spelling)
                Toggle("Pair brackets and math delimiters", isOn: $autoPair)
            }
            Section("Preview") {
                Toggle("Live preview", isOn: $live)
                Toggle("Serif text", isOn: $serif)
                Picker("Default zoom", selection: $zoom) { ForEach([75, 90, 100, 110, 125, 150, 200], id: \.self) { Text("\($0)%").tag($0) } }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).font(RemileType.control).toggleStyle(.switch)
    }
}

struct MarkdownSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Markdown settings").font(RemileType.heading).padding([.horizontal, .top], 20)
            MarkdownSettingsForm()
        }.frame(width: 440, height: 460).background(RemileStyle.background)
    }
}
