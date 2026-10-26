import SwiftUI

struct TeXAskPanel: View {
    @ObservedObject var project: TeXProject
    @ObservedObject var assistant: DocumentAssistant
    let connection: OverleafConnection?
    let archiveRead: (OverleafThreadArchive) -> Void
    let close: () -> Void
    @StateObject private var state = PanelState()
    private final class PanelState: ObservableObject {
        @Published var draftReview = false
        @Published var feedback = false
        @Published var loading = false
        @Published var message: String?
        var task: Task<Void, Never>?
    }
    var body: some View {
        VStack(spacing: 0) {
            if state.draftReview {
                HStack {
                    Button { state.draftReview = false } label: { Label("Ask", systemImage: "chevron.left") }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Close Ask")
                }.buttonStyle(RemileToolStyle()).padding(10)
                Divider()
                ManuscriptReviewPanel(project: project)
            } else {
                AssistantPanel(assistant: assistant, passages: [], topic: project.displayName, select: reveal, close: close, retrieve: retrieve, composerActions: AnyView(composerActions))
            }
        }.background(RemileStyle.surface).onDisappear { state.task?.cancel() }
    }
    private var composerActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            action("Review manuscript", symbol: "doc.text.magnifyingglass", help: "Use the saved manuscript review criteria") { state.draftReview = true }
            if connection != nil {
                action(state.loading ? "Reading feedback…" : "Attach Overleaf feedback", symbol: "text.bubble", help: "Attach comments, tracked changes and source excerpts to your question", loading: state.loading) { attachFeedback() }
                    .disabled(state.loading || assistant.working)
            }
            if state.feedback {
                HStack(spacing: 8) {
                    Label("Overleaf feedback attached", systemImage: "checkmark").font(RemileType.caption)
                    Button { state.feedback = false } label: { Image(systemName: "xmark").font(RemileType.caption) }
                        .buttonStyle(.plain).remileHelp("Remove Overleaf feedback").accessibilityLabel("Remove Overleaf feedback")
                }.foregroundStyle(RemileStyle.secondaryInk).padding(.top, 3)
            }
            if let message = state.message {
                Text(message).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func action(_ title: String, symbol: String, help: String, loading: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                if loading { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol).foregroundStyle(RemileStyle.accent) }
                Text(title)
            }.font(RemileType.caption).padding(.horizontal, 11).padding(.vertical, 7)
                .contentShape(Capsule())
        }.buttonStyle(AskActionStyle()).remileHelp(help)
    }
    private func attachFeedback() {
        guard let connection, !state.loading else { return }
        state.loading = true; state.message = nil
        state.task = Task { @MainActor in
            defer { state.loading = false; state.task = nil }
            do {
                let snapshot = try await OverleafReviewService.read(connection, paths: project.treeFiles, main: project.main)
                project.overleafReview = snapshot; archiveRead(snapshot.archive)
                state.feedback = true; state.message = snapshot.warning
                if assistant.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistant.question = "Review the supplied Overleaf comments and tracked changes against the source excerpts. Prioritise issues and suggest source-linked next steps."
                }
            } catch is CancellationError { }
            catch { state.message = error.localizedDescription }
        }
    }
    private func retrieve(_ question: String) async throws -> [AssistantPassage] {
        let source = project.buffers.sorted { $0.key < $1.key }.flatMap { path, text -> [AssistantPassage] in
            let lines = text.components(separatedBy: "\n")
            return stride(from: 0, to: lines.count, by: 16).map { index in
                AssistantPassage(location: .init(path: path, unit: index + 1, label: "\(path) · Line \(index + 1)"), text: lines[index..<min(lines.count, index + 16)].joined(separator: "\n"))
            }
        }
        var feedback: [AssistantPassage] = []
        if state.feedback, let snapshot = project.overleafReview {
            for thread in snapshot.archive.threads.sorted(by: { !$0.resolved && $1.resolved }) {
                let anchor = snapshot.anchors[thread.id]
                let messages = thread.messages.map { $0.author + ": " + $0.text }.joined(separator: "\n")
                feedback.append(.init(location: .init(path: "review-comment:" + thread.id, unit: (anchor?.line ?? 0) + 1, label: "Comment · " + (anchor.map { "\($0.file):\($0.line + 1)" } ?? "Unlocated")), text: "Thread \(thread.id) · \(thread.resolved ? "resolved" : "open")\n" + messages + sourceQuote(anchor)))
            }
            for change in snapshot.changes {
                feedback.append(.init(location: .init(path: "review-change:" + change.id, unit: change.anchor.line + 1, label: "Change · \(change.anchor.file):\(change.anchor.line + 1)"), text: "Change \(change.changeID) · \(change.insertion ? "added" : "deleted")\n" + change.text + sourceQuote(change.anchor)))
            }
        }
        return feedback + AssistantRetrieval.rank(source, question: question)
    }
    private func sourceQuote(_ anchor: OverleafReviewSnapshot.Anchor?) -> String {
        guard let anchor else { return "\nSource location unavailable." }
        let text = anchor.source as NSString
        let start = max(0, anchor.offset - 250), end = min(text.length, anchor.offset + min(anchor.length, 1000) + 250)
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return "\nSource \(anchor.file):\(anchor.line + 1) · SHA-256 \(SourceDigest.sha256(anchor.source))\n" + text.substring(with: range)
    }
    private func reveal(_ evidence: AssistantEvidence) {
        let path = evidence.location.path
        let anchor: OverleafReviewSnapshot.Anchor?
        if path.hasPrefix("review-comment:") { anchor = project.overleafReview?.anchors[String(path.dropFirst("review-comment:".count))] }
        else if path.hasPrefix("review-change:") { anchor = project.overleafReview?.changes.first { $0.id == String(path.dropFirst("review-change:".count)) }?.anchor }
        else {
            guard project.buffers[path] != nil else { return }
            project.visit(file: path, line: max(0, evidence.location.unit - 1)); return
        }
        guard let location = anchor?.location(in: project.buffers) else { state.message = "Source changed. Refresh feedback before navigating."; return }
        project.selected = location.file; project.sourceJump = .init(location: location, highlight: path.hasPrefix("review-comment:") ? .comment : .change)
    }
}

private struct AskActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(RemileStyle.ink)
            .background(RemileStyle.ink.opacity(configuration.isPressed ? 0.12 : 0.035), in: Capsule())
            .overlay(Capsule().stroke(RemileStyle.accent.opacity(configuration.isPressed ? 0.7 : 0.3), lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
    }
}
