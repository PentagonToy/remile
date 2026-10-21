import SwiftUI

struct AssistantHistorySettings: View {
    @AppStorage(AssistantResponseDetail.preference) private var detail = AssistantResponseDetail.mid.rawValue
    @AppStorage(AssistantHistoryRetention.preference) private var retention = AssistantHistoryRetention.days30.rawValue
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject { @Published var confirm = false; @Published var message: String? }
    var body: some View {
        DisclosureGroup("Responses & history") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Answer detail", selection: $detail) {
                    ForEach(AssistantResponseDetail.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Picker("Keep conversations", selection: $retention) {
                    ForEach(AssistantHistoryRetention.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }.onChange(of: retention) {
                    do { try AssistantHistory.applyRetention(); state.message = nil }
                    catch { state.message = "Unable to update Ask history." }
                }
                HStack { Text("Saved on this Mac").foregroundStyle(.secondary); Spacer(); Button("Clear History…", role: .destructive) { state.confirm = true } }
                if let message = state.message { Text(message).font(RemileType.caption).foregroundStyle(.secondary) }
            }.padding(.top, 10).padding(.leading, 18)
        }.confirmationDialog("Clear all Ask conversations?", isPresented: $state.confirm) {
            Button("Clear History", role: .destructive) {
                do { try AssistantHistory.clearAll(); state.message = "History cleared." }
                catch { state.message = "Unable to clear Ask history." }
            }
        } message: { Text("This removes saved conversations from this Mac.") }
    }
}
