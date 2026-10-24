import SwiftUI
import CryptoKit

struct TeXChatGPTReview: View {
    @ObservedObject var project: TeXProject
    let diagnostic: TeXDiagnostic
    @ObservedObject private var connection = ChatGPTConnection.shared
    @StateObject private var state = State()
    @Environment(\.dismiss) private var dismiss
    private final class State: ObservableObject {
        @Published var busy = false
        @Published var error: String?
        @Published var edit: ChatGPTEdit?
        @Published var settings = false
        var file = ""
        var before = ""
        var task: Task<Void, Never>?
        var key = ""
        var buffers: [String: String] = [:]
        var log = ""
        var main = ""
    }
    private var focus: TeXDiagnostic { TeXDiagnostics.repairFocus(diagnostic, entries: project.diagnostics) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { GPTMark(); Text("LaTeX suggestion").font(RemileType.heading); Spacer(); Button("Done") { state.task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
            if state.busy { ProgressView("Asking ChatGPT…").frame(maxWidth: .infinity, minHeight: 100) }
            else if let edit = state.edit {
                Text(state.file).font(RemileType.caption).foregroundStyle(.secondary)
                Text(edit.reason).font(RemileType.callout).textSelection(.enabled)
                HStack(alignment: .top) { preview("Current", edit.before, colour: RemileStyle.warning); preview("Suggested", edit.after, colour: RemileStyle.success) }.frame(height: 150)
                HStack { Text("Review before applying.").font(RemileType.caption).foregroundStyle(.secondary); Spacer(); Button("Apply and compile") { apply(edit) }.disabled(project.compiling || project.buffers != state.buffers || project.log != state.log || project.main != state.main) }
            } else {
                Text(focus.displayMessage).font(RemileType.callout).fixedSize(horizontal: false, vertical: true)
                if focus.id != diagnostic.id { Text("Checking an earlier cause first.").font(RemileType.caption).foregroundStyle(.secondary) }
                HStack {
                    if !connection.connected { Button("Connect ChatGPT") { state.settings = true } }
                    else { Button("Suggest fix") { request() }.disabled(project.compiling || AIUsage.shared.reason != nil) }
                    Spacer()
                }
            }
            if let error = state.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }.padding(18).frame(width: 460).background(RemileStyle.background)
            .task { if connection.connected { request() } }
            .sheet(isPresented: $state.settings) { ChatGPTSettings() }
            .onDisappear { state.task?.cancel() }
    }
    private func preview(_ label: String, _ source: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(RemileType.caption.weight(.semibold)); ScrollView([.horizontal, .vertical]) { Text(source).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }.background(colour.opacity(0.09), in: RoundedRectangle(cornerRadius: 6)) }.frame(maxWidth: .infinity)
    }
    private func request() {
        guard !state.busy, !project.compiling, AIUsage.shared.reason == nil else { return }
        let entries = project.diagnostics
        let focus = TeXDiagnostics.repairFocus(diagnostic, entries: entries)
        var file = focus.file ?? project.main
        if file.hasPrefix("./") { file = String(file.dropFirst(2)) }
        if project.buffers[file] == nil { file = project.main }
        guard let source = project.buffers[file] else { return }
        state.file = file; state.before = source; state.error = nil
        state.buffers = project.buffers; state.log = project.log; state.main = project.main
        let input = TeXDiagnostics.repairEvidence(selected: diagnostic, focus: focus, entries: entries, file: file, excerpt: Self.excerpt(source, line: focus.line), main: project.main, preamble: project.buffers[project.main] ?? "")
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return }
        state.key = connection.model + file + SHA256.hash(data: Data((source + String(decoding: data, as: UTF8.self)).utf8)).map { String(format: "%02x", $0) }.joined()
        if let edit = TeXFixCache.entries.first(where: { $0.key == state.key })?.edit { state.edit = edit; return }
        state.busy = true
        state.task = Task {
            defer { state.busy = false }
            do {
                let response = try await connection.respond(String(decoding: data, as: UTF8.self), instructions: AssistantPrompts.latexRepair)
                try Task.checkCancellation()
                guard project.buffers == state.buffers, project.log == state.log, project.main == state.main else { throw ChatGPTIdentity.Failure("The source changed. Request a new suggestion.") }
                if let reply = try? JSONDecoder().decode(ChatGPTEdit.self, from: Data(response.utf8)), reply.before == reply.after, !reply.reason.isEmpty {
                    state.error = String(reply.reason.prefix(2000)); return
                }
                let edit = try ChatGPTEdit.parse(response, source: source)
                state.edit = edit; TeXFixCache.entries.append((state.key, edit)); TeXFixCache.entries = Array(TeXFixCache.entries.suffix(8))
            } catch is CancellationError { }
            catch { state.error = error.localizedDescription }
        }
    }
    static func excerpt(_ source: String, line: Int?) -> String {
        if source.utf8.count <= 12_000 { return source }
        let lines = source.components(separatedBy: "\n"), index = max(0, min(lines.count - 1, (line ?? 1) - 1))
        return AssistantEvidence.bounded(lines[max(0, index - 30)..<min(lines.count, index + 31)].joined(separator: "\n"), bytes: 12_000)
    }
    private func apply(_ edit: ChatGPTEdit) {
        do {
            guard project.buffers == state.buffers, project.log == state.log, project.main == state.main, !project.compiling else { throw ChatGPTIdentity.Failure("The source changed. Request a new suggestion.") }
            let after = try edit.applying(to: state.before)
            guard project.applyTool(file: state.file, before: state.before, after: after, name: "ChatGPT LaTeX fix") else { throw ChatGPTIdentity.Failure(project.message ?? "Could not apply this edit.") }
            project.markExternalEdit(file: state.file, before: state.before, after: after)
            project.compile(); dismiss()
        } catch { state.error = error.localizedDescription }
    }
}

@MainActor private enum TeXFixCache { static var entries: [(key: String, edit: ChatGPTEdit)] = [] }
