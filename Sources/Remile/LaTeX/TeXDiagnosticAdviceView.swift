import SwiftUI

struct TeXDiagnosticAdviceView: View {
    @ObservedObject var project: TeXProject
    @ObservedObject private var connection = ChatGPTConnection.shared
    @ObservedObject private var usage = AIUsage.shared
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    @StateObject private var state = State()
    @MainActor private final class State: ObservableObject {
        @Published var busy = false
        @Published var advice: TeXDiagnosticAdvice?
        @Published var error: String?
        @Published var model = ""
        var task: Task<Void, Never>?
        func cancel() { task?.cancel(); task = nil; busy = false }
    }
    var body: some View {
        if provider == "ChatGPT" {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack {
                    Label("AI help", systemImage: "sparkles").font(RemileType.callout.weight(.semibold))
                    Spacer()
                    if state.busy { ProgressView().controlSize(.small); Button("Cancel") { state.cancel() } }
                    else { Button(state.advice == nil ? "Ask ChatGPT" : "Ask again") { request() }.disabled(project.compiling || usage.active || usage.reason != nil).remileHelp(usage.reason ?? "Send error summaries to the selected ChatGPT model") }
                }
                if let advice = state.advice {
                    TeXDiagnosticAdviceContent(advice: advice, model: state.model)
                } else if let reason = usage.reason { Text(reason).font(RemileType.caption).foregroundStyle(.secondary) }
                if let error = state.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            }.onDisappear { state.cancel() }
                .onChange(of: project.log) { state.cancel(); state.advice = nil; state.error = nil }
                .onChange(of: provider) { state.cancel(); state.advice = nil }
                .onChange(of: connection.model) { state.cancel(); state.advice = nil }
        }
    }
    private func request() {
        guard provider == "ChatGPT", !state.busy, !project.compiling, !usage.active, usage.reason == nil else { return }
        guard !connection.model.isEmpty else { state.error = "Choose a ChatGPT model in Settings."; return }
        let log = project.log, diagnostics = project.diagnostics, directory = TeXConfiguration.current.directory, model = connection.model
        state.busy = true; state.error = nil; state.advice = nil; state.model = model
        state.task = Task { @MainActor in
            defer { if !Task.isCancelled { state.busy = false } }
            do {
                let files = TeXSetupIssue.detect(log)?.files ?? []
                let resolution = files.isEmpty ? nil : await TeXPackageResolver.shared.resolve(files: files, directory: directory)
                try Task.checkCancellation()
                let input = try TeXDiagnosticAdvice.input(log: log, diagnostics: diagnostics, directory: directory, resolution: resolution)
                let output = try await connection.respond(input, instructions: TeXDiagnosticAdvice.instructions)
                try Task.checkCancellation()
                guard project.log == log, connection.model == model else { return }
                state.advice = try TeXDiagnosticAdvice.parse(output)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { state.error = error.localizedDescription } }
        }
    }
}

struct TeXDiagnosticAdviceContent: View {
    let advice: TeXDiagnosticAdvice
    let model: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI suggestion · " + model).font(RemileType.caption).foregroundStyle(.secondary)
            Text(advice.summary).font(RemileType.callout).textSelection(.enabled)
            ForEach(Array(advice.steps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). " + step).font(RemileType.callout).textSelection(.enabled) }
            ForEach(advice.commands, id: \.self) { TeXGuidanceCommand(command: $0) }
            if !advice.commands.isEmpty { Text("Review commands before running them.").font(RemileType.caption).foregroundStyle(.secondary) }
        }
    }
}
