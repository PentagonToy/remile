import SwiftUI

struct AssistantPanel: View {
    @ObservedObject private var network = NetworkAccessState.shared
    @AppStorage(AIConfiguration.fallbackPreference) private var fallback = true
    @ObservedObject private var usage = AIUsage.shared
    @ObservedObject var assistant: DocumentAssistant
    let passages: [AssistantPassage]
    let topic: String
    let select: (AssistantEvidence) -> Void
    let close: () -> Void
    var retrieve: (@MainActor (String) async throws -> [AssistantPassage])? = nil
    var selection: String? = nil
    var clearSelection: (() -> Void)? = nil
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("assistant.provider") private var provider = "Apple Intelligence"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Ask").font(RemileType.callout.bold())
                Spacer()
                AIProviderButton()
                Button("Clear") { assistant.clear() }
                    .disabled(assistant.turns.isEmpty && assistant.question.isEmpty).remileHelp("Clear conversation").accessibilityLabel("Clear conversation")
                Button { assistant.cancel(); close() } label: { Image(systemName: "xmark") }
                    .remileHelp("Close Ask").accessibilityLabel("Close Ask")
            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 13)
            if assistant.availability != "On-device" {
                Text(assistant.availability).font(RemileType.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if assistant.turns.isEmpty {
                            Text("Ask about this document").font(RemileType.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        ForEach(assistant.turns) { turn in conversation(turn) }
                        if assistant.working {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(assistant.stage).font(RemileType.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Stop") { assistant.cancel() }.font(RemileType.caption)
                            }
                            if let progress = assistant.progress { ProgressView(value: progress).accessibilityLabel("Reading PDF pages") }
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }.padding(14)
                }
                .onChange(of: assistant.turns.count) { scrollToEnd(proxy) }
                .onChange(of: assistant.working) { scrollToEnd(proxy) }
            }
            if let message = assistant.message, assistant.turns.isEmpty {
                Text(message).font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            if let selection {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Label("Selected passage", systemImage: "text.quote"); Spacer(); Button { clearSelection?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).remileHelp("Remove selected passage") }
                    Text(selection).lineLimit(3).foregroundStyle(.secondary)
                }.font(RemileType.caption).padding(10).background(RemileStyle.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Ask", text: $assistant.question, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).padding(.vertical, 7).padding(.leading, 12)
                    .onSubmit { ask() }.accessibilityIdentifier("ask.message")
                Button { ask() } label: {
                    Image(systemName: "arrow.up").font(.body.bold()).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(RemileStyle.brand, in: Circle())
                }.buttonStyle(.plain).padding(4)
                    .disabled(assistant.working || (passages.isEmpty && retrieve == nil))
                    .remileHelp(assistant.question.isEmpty ? "Summarize document" : "Send message").accessibilityLabel("Send message")
            }
            .background(RemileStyle.sidebar, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(RemileStyle.ink.opacity(0.15)))
            .padding(12)
        }.frame(minWidth: 240, idealWidth: 330, maxWidth: 440)
            .background(RemileStyle.surface).onAppear { assistant.useEngine(.selected) }
            .onChange(of: provider) { assistant.useEngine(.selected) }
            .onChange(of: usage.online) { assistant.checkAvailability() }
            .onChange(of: network.offline) { assistant.useEngine(.selected) }
            .onChange(of: fallback) { assistant.useEngine(.selected) }
            .onChange(of: usage.paused) { assistant.checkAvailability() }
            .onChange(of: phase) { if phase == .active { assistant.checkAvailability() } }
    }
    private func conversation(_ turn: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 30)
                Text(turn.question).textSelection(.enabled).padding(.horizontal, 13).padding(.vertical, 10)
                    .foregroundStyle(.white).background(RemileStyle.brand, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("ask.question")
                    .contextMenu { Button("Copy") { copy(turn.question) } }
            }
            if !turn.answer.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 5) {
                            if turn.generalContext { Text("General context") }
                            else if let note = turn.sourceNote { Text(note) }
                            else if !turn.sources.isEmpty { Label("Source linked", systemImage: "link") }
                        }.font(RemileType.caption).foregroundStyle(.secondary)
                        AssistantAnswerText(text: AssistantAnswerDisplay.clean(turn.answer))
                        if !turn.sources.isEmpty {
                            AssistantSources(sources: turn.sources, select: select)
                        }
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background((turn.sources.isEmpty || turn.generalContext ? RemileStyle.sourceUnverified : RemileStyle.sourceLinked).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .contextMenu { Button("Copy") { copy(AssistantAnswerDisplay.clean(turn.answer)) } }
                    Spacer(minLength: 16)
                }
            }
            if let status = turn.status { Text(status).font(RemileType.caption).foregroundStyle(.secondary) }
        }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : RemileMotion.panel) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
    }
    private func ask() {
        guard !assistant.working else { return }
        assistant.useEngine(.selected)
        if let retrieve { assistant.ask(topic: topic, retrieve: retrieve) }
        else { assistant.ask(passages: passages, topic: topic) }
    }
}


private struct AssistantSources: View {
    let sources: [AssistantEvidence]
    let select: (AssistantEvidence) -> Void
    @StateObject private var presentation = Presentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class Presentation: ObservableObject { @Published var expanded = false }
    var body: some View {
        DisclosureGroup(isExpanded: $presentation.expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sources) { source in
                    Button { select(source) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(source.number)] \(source.location.name) · \(source.location.label)").font(.system(size: 13, weight: .medium))
                            Text(source.text).font(RemileType.caption).lineLimit(3).foregroundStyle(.secondary)
                        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).remileHelp("Show cited passage").accessibilityIdentifier("ask.source.\(source.number)")
                }
            }.padding(.top, 8)
        } label: {
            Label("\(sources.count) \(sources.count == 1 ? "source" : "sources")", systemImage: "quote.bubble").font(RemileType.caption)
        }.tint(RemileStyle.accent).accessibilityIdentifier("ask.sources")
            .animation(reduceMotion ? nil : RemileMotion.panel, value: presentation.expanded)
    }
}


/// Native selectable paragraphs preserve readable spacing and lightweight Markdown structure.
private struct AssistantAnswerText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ReadableMath.display(text).components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                let heading = paragraph.hasPrefix("#")
                let content = heading ? paragraph.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression) : paragraph
                Text((try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content))
                    .font(heading ? RemileType.heading : RemileType.body).lineSpacing(5)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
