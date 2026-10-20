import SwiftUI

private final class SettingsPresentation: ObservableObject {
    @Published var historyMessage: String?
    @Published var confirmClear = false
    @Published var section = "General"
}

struct ReaderSettings: View {
    @AppStorage(ReaderAppearance.preference) private var appearance = ReaderAppearance.system.rawValue
    @AppStorage(ReaderZoom.preference) private var markdownZoom = 100
    @AppStorage(AssistantResponseDetail.preference) private var responseDetail = AssistantResponseDetail.mid.rawValue
    @AppStorage(AssistantHistoryRetention.preference) private var retention = AssistantHistoryRetention.days30.rawValue
    @StateObject private var presentation = SettingsPresentation()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Picker("Settings section", selection: $presentation.section) {
                    Text("General").tag("General")
                    Text("Ask").tag("Ask")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }.padding(20)
            Divider()
            if presentation.section == "General" { Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(ReaderAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                }
                Section("Reading") {
                    Picker("Default Markdown zoom", selection: $markdownZoom) {
                        ForEach([75, 90, 100, 110, 125, 150, 200], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Text("Applies to new Markdown views. Use −, + or Fit in any document to adjust its view.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped) }
            else { Form {
                Section("Responses") {
                    Picker("Detail", selection: $responseDetail) {
                        ForEach(AssistantResponseDetail.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Text("Ask runs on this Mac with Apple Intelligence. Higher detail allows longer answers.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            }.formStyle(.grouped) }
        }.frame(width: 560, height: 400)
            .confirmationDialog("Clear all Ask conversations?", isPresented: $presentation.confirmClear) {
                Button("Clear History", role: .destructive) {
                    do { try AssistantHistory.clearAll(); presentation.historyMessage = "History cleared." }
                    catch { presentation.historyMessage = "Unable to clear Ask history." }
                }
            } message: { Text("This removes saved conversations from this Mac.") }
    }
}
