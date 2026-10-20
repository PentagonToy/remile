import SwiftUI

struct ChatGPTSettings: View {
    var showsHeading = true
    @ObservedObject private var connection = ChatGPTConnection.shared
    @ObservedObject private var usage = AIUsage.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @AppStorage("chatgpt.dailyLimit") private var dailyLimit = 100
    @AppStorage("chatgpt.synonyms") private var synonyms = true
    @AppStorage("chatgpt.grammar") private var grammar = true
    @AppStorage("editor.aiSuggestions") private var completion = false
    var body: some View {
        if showsHeading { ScrollView { content }.scrollContentBackground(.hidden).frame(width: 460, height: 680).background(RemileStyle.background).presentationBackground(RemileStyle.background) }
        else { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeading { HStack { Text("AI").font(RemileType.heading); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
            Picker("Use", selection: $provider) { Text("Apple Intelligence").tag("Apple Intelligence"); Text("ChatGPT").tag("ChatGPT"); Text("Manual · AI off").tag("Off") }
            Text("ChatGPT falls back to this Mac when unavailable.").font(RemileType.caption).foregroundStyle(.secondary).remileHelp("A dot on ChatGPT means connect or unlock. A dot on Apple Intelligence means automatic fallback. Your ChatGPT choice is kept.")
            VStack(alignment: .leading, spacing: 10) {
                Text("Writing suggestions").font(RemileType.callout.weight(.semibold))
                Toggle("Grammar suggestions", isOn: $grammar)
                Toggle("Word alternatives", isOn: $synonyms)
                Toggle("Inline completion on this Mac", isOn: $completion)
                Text("Grammar and word alternatives use the AI selected above. Select text and right-click to review a suggestion.").font(RemileType.caption).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.disabled(provider == "Off")
            Divider()
            HStack { GPTMark(); Text("ChatGPT").font(RemileType.callout.weight(.semibold)); Spacer(); if connection.connected { Label(connection.credentialUnavailable ? "Locked" : "Connected", systemImage: connection.credentialUnavailable ? "lock" : "checkmark.circle.fill").font(RemileType.caption).foregroundStyle(connection.credentialUnavailable ? RemileStyle.warning : RemileStyle.success) } }
            if connection.connected {
                Text(connection.name).font(RemileType.caption).foregroundStyle(.secondary)
                if connection.credentialUnavailable { Text("macOS needs permission to read your saved connection. This can happen after reinstalling remile. The app has no timed lock.").font(RemileType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(connection.unlocking ? "Unlocking…" : "Unlock connection") { Task { await connection.unlock() } }.disabled(connection.unlocking) }
                if !connection.models.isEmpty { Picker("Model", selection: $connection.model) { ForEach(connection.models) { Text($0.name).tag($0.id) } } }
                HStack { Button("Refresh models") { Task { await connection.loadModels() } }.disabled(!usage.online); Spacer(); Button("Disconnect") { connection.disconnect() }.disabled(connection.busy || connection.unlocking) }
            } else if !connection.busy { Button("Continue with ChatGPT") { Task { await connection.signIn() } }.disabled(!usage.online) }
            if connection.busy { HStack { ProgressView().controlSize(.small); Text("Signing in…"); Spacer(); Button("Cancel") { connection.cancelSignIn() } } }
            if let error = connection.error, !(connection.credentialUnavailable && error == "Unlock the connection in Settings.") { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Today in remile.").font(RemileType.callout.weight(.semibold)); Spacer(); Text("\(usage.requests) of \(dailyLimit) requests").font(RemileType.caption).monospacedDigit() }
                ProgressView(value: Double(min(usage.requests, dailyLimit)), total: Double(dailyLimit)).tint(RemileStyle.accent)
                Stepper("Daily limit for remile.: \(dailyLimit)", value: $dailyLimit, in: 5...200, step: 5)
                Text("One question or suggestion uses one request.").font(RemileType.caption).foregroundStyle(.secondary)
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 8) {
                    Text("\(usage.inputTokens + usage.outputTokens) tokens reported today").font(RemileType.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Your ChatGPT allowance is shared with other apps. This bar only shows your remile. limit.").font(RemileType.caption).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 8).padding(.bottom, 4)
                }.font(RemileType.caption)
            }
            HStack {
                Link("ChatGPT usage & limits", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Spacer()
                if usage.paused { Button("Resume requests") { usage.resume() } }
            }.font(RemileType.caption)
            Text("No separate API bill from remile.").italic().foregroundStyle(RemileStyle.accent).remileHelp(RemileHints.chatGPTPlan)
            Text("Credits, if enabled, follow your ChatGPT settings.").font(RemileType.caption).foregroundStyle(.secondary)
        }.padding(showsHeading ? 24 : 0).frame(maxWidth: showsHeading ? 420 : .infinity).background(RemileStyle.background)
            .task { if connection.connected && connection.models.isEmpty && usage.online { await connection.loadModels() } }
            .onDisappear { if connection.busy { connection.cancelSignIn() } }
    }
}
