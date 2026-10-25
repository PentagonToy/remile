import SwiftUI

/// The same AI controls are used in Settings and the toolbar sheet.
struct ChatGPTSettings: View {
    var showsHeading = true
    var refreshModelsOnAppear = true
    @ObservedObject private var connection = ChatGPTConnection.shared
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject private var network = NetworkAccessState.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @AppStorage(AIConfiguration.fallbackPreference) private var fallback = true
    @AppStorage(AIConfiguration.writingPreference) private var writing = true
    @AppStorage("chatgpt.dailyLimit") private var dailyLimit = 100
    @AppStorage("chatgpt.grammar") private var grammar = true
    @AppStorage("editor.aiSuggestions") private var completion = false
    private var deviceReady: Bool { AppleIntelligence.status().ready }
    private var canConnect: Bool { usage.online && !network.offline }
    var body: some View {
        if showsHeading {
            ScrollView { content.padding(24) }.font(RemileType.control).buttonStyle(RemileActionStyle()).toggleStyle(.switch).scrollContentBackground(.hidden).smoothScrolling()
                .frame(width: 490, height: 600).background(RemileStyle.background).presentationBackground(RemileStyle.background).modifier(NetworkAccessScope())
        } else { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeading { HStack { Text("AI").font(RemileType.heading); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
            Picker("Use", selection: $provider) {
                ForEach(AIConfiguration.Mode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue).disabled(mode == .device && !deviceReady)
                }
            }
            SettingsHint(description)
            if !deviceReady { SettingsHint("Apple Intelligence is unavailable on this Mac.").remileHelp(AppleIntelligence.status().message) }
            if provider == "ChatGPT" {
                Toggle("Apple Intelligence fallback", isOn: $fallback).disabled(!deviceReady)
                connectionControls
            }
            if provider != "Off" {
                Divider()
                Toggle("Writing suggestions", isOn: $writing)
                SettingsHint("Select text and right-click for suggestions.")
                DisclosureGroup("Writing options") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Grammar suggestions", isOn: $grammar)
                        Toggle("Inline completion on this Mac", isOn: $completion).disabled(!deviceReady || (provider == "ChatGPT" && !fallback))
                        SettingsHint("Apple Intelligence completion · Tab to accept.")
                    }.toggleStyle(.checkbox).padding(.top, 10).padding(.leading, 18).disabled(!writing)
                }
            }
            if provider == "ChatGPT" {
                DisclosureGroup("Usage & connection details") { usageControls.padding(.top, 10).padding(.leading, 18) }
            }
            Divider()
            AssistantHistorySettings()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: provider + String(network.offline)) { if refreshModelsOnAppear, provider == "ChatGPT", connection.connected, connection.models.isEmpty, canConnect { await connection.loadModels() } }
            .onDisappear { if connection.busy { connection.cancelSignIn() } }
    }
    private var description: String {
        if provider == "Off" { return "AI is off. You can still read and edit." }
        if provider == "Apple Intelligence" { return "Questions and suggestions stay on this Mac." }
        if network.offline { return fallback && deviceReady ? "Offline · Apple Intelligence handles requests." : "Offline · ChatGPT requests are paused." }
        return "Questions and document context are sent to ChatGPT."
    }
    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.connected {
                if connection.credentialUnavailable {
                    Button(connection.unlocking ? "Unlocking…" : "Unlock ChatGPT") { Task { await connection.unlock() } }.disabled(connection.unlocking || !canConnect)
                } else if !connection.models.isEmpty {
                    Picker("Model", selection: $connection.model) { ForEach(connection.models) { Text($0.name).tag($0.id) } }
                } else { Label("ChatGPT connected", systemImage: "checkmark.circle").font(RemileType.caption).foregroundStyle(.secondary) }
            } else if !connection.busy {
                Button("Continue with ChatGPT") { Task { await connection.signIn() } }.disabled(!canConnect)
            }
            if connection.busy { HStack { ProgressView().controlSize(.small); Text("Signing in…"); Spacer(); Button("Cancel") { connection.cancelSignIn() } } }
            if let error = connection.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }
    }
    private var usageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if connection.connected {
                Text(connection.name).font(RemileType.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh models") { Task { await connection.loadModels() } }.disabled(!canConnect || connection.credentialUnavailable)
                    Spacer()
                    Button("Disconnect") { connection.disconnect() }.disabled(connection.busy || connection.unlocking)
                }
            }
            Text("Today: \(usage.requests) of \(dailyLimit) requests").font(RemileType.caption).monospacedDigit()
            ProgressView(value: Double(min(usage.requests, dailyLimit)), total: Double(max(1, dailyLimit))).tint(RemileStyle.accent)
            Stepper("Daily limit: \(dailyLimit)", value: $dailyLimit, in: 5...200, step: 5)
            SettingsHint("\(usage.inputTokens + usage.outputTokens) tokens today · remile. limit only.")
            HStack {
                Link("ChatGPT usage & limits", destination: URL(string: "https://chatgpt.com/settings/usage")!).disabled(network.offline)
                Spacer()
                if usage.paused { Button("Resume requests") { usage.resume() } }
            }.font(RemileType.caption)
            Text("No separate API bill from remile.").font(RemileType.caption).foregroundStyle(.secondary).remileHelp(RemileHints.chatGPTPlan)
        }
    }
}
