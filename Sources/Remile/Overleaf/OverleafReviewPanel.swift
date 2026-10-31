import SwiftUI
import UniformTypeIdentifiers

struct OverleafReviewPanel: View {
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    var archiveRead: (OverleafThreadArchive) -> Void = { _ in }
    @StateObject private var state = ReviewState()
    @AppStorage(OverleafReviewAccess.key) private var reviewEnabled = false
    private final class ReviewState: ObservableObject {
        @Published var snapshot: OverleafReviewSnapshot?
        @Published var busy = false
        @Published var applying = false
        var operation: Task<Void, Never>?
        @Published var failure: String?
        @Published var tab = false
        @Published var resolved = false
        @Published var refreshID = UUID()
        @Published var signIn = false
        @Published var needsSignIn = false
        @Published var selected: String?
    }
    var body: some View {
        Group {
            if reviewEnabled {
                content
            } else {
                VStack(alignment: .leading, spacing: RemileControl.rowSpacing) {
                    Text("Overleaf review").font(RemileType.callout.weight(.semibold))
                    Text("Review uses an unofficial web connection.")
                        .font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: RemileControl.spacing) {
                        Button("Enable review") { reviewEnabled = true }
                            .buttonStyle(RemileActionStyle(emphasis: .primary))
                        Link(destination: URL(string: "https://www.overleaf.com/legal")!) {
                            Text("Terms").font(RemileType.caption).foregroundStyle(RemileStyle.accent)
                        }.accessibilityLabel("Overleaf terms")
                    }
                }.padding(RemileControl.rowSpacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RemileStyle.sidebar)
            }
        }.onChange(of: reviewEnabled) { _, enabled in
            if !enabled {
                state.operation?.cancel()
                state.snapshot = nil
                project.overleafReview = nil
            }
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Overleaf review").font(RemileType.callout.weight(.semibold))
                Spacer(minLength: 4)
                if state.busy { ProgressView().controlSize(.small) }
                Button {
                    state.refreshID = UUID()
                } label: {
                    SymbolIcon(systemName: "arrow.clockwise")
                }.disabled(state.busy || state.applying).remileHelp("Refresh review").accessibilityLabel(
                    "Refresh review")
                Menu {
                    Button("Disable review connection") { reviewEnabled = false }.disabled(state.applying)
                    Divider()
                    Group {
                        Button("Export all as Markdown…") { export(json: false) }
                        Button("Export all as JSON…") { export(json: true) }
                        Button("Review package with sources…") { exportPackage() }
                    }.disabled(state.snapshot == nil || state.busy || state.applying)
                } label: {
                    SymbolIcon(systemName: "square.and.arrow.up")
                }.remileHelp("Export and review connection").accessibilityLabel("Export and review connection")
            }.buttonStyle(RemileToolStyle())
            RemileSegmentedControl(
                title: "Review entries", selection: $state.tab, options: [false, true],
                label: {
                    $0
                        ? "Changes · \(state.snapshot?.changes.count ?? 0)"
                        : "Comments · \(state.snapshot?.archive.threads.count ?? 0)"
                })
            if let failure = state.failure {
                Text(failure).font(RemileType.caption).foregroundStyle(RemileStyle.warning)
            }
            if state.needsSignIn { Button("Connect Overleaf") { state.signIn = true } }
            if let warning = state.snapshot?.warning {
                Text(warning).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            }
            if !state.tab {
                Toggle("Show resolved", isOn: $state.resolved).toggleStyle(.checkbox).font(RemileType.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let snapshot = state.snapshot {
                        if state.tab {
                            if snapshot.changes.isEmpty {
                                empty(snapshot.warning == nil ? "No tracked changes" : "Changes unavailable")
                            }
                            ForEach(snapshot.changes) { change in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: RemileControl.spacing) {
                                        SymbolLabel(
                                            change.insertion ? "Added" : "Deleted",
                                            systemImage: change.insertion ? "plus" : "minus"
                                        ).foregroundStyle(change.insertion ? RemileStyle.success : RemileStyle.warning)
                                        Spacer(minLength: RemileControl.spacing)
                                        OverleafReviewDecisionButtons(
                                            changeID: change.id, disabledReason: disabledReason(change)
                                        ) { decide(change, accept: $0) }
                                    }
                                    if let author = change.author { Text(author).fontWeight(.semibold) }
                                    if let timestamp = change.timestamp { date(timestamp) }
                                    location(change.anchor, highlight: .change, selection: "change:" + change.id)
                                    Divider().opacity(0.4)
                                    Text(change.text).strikethrough(!change.insertion, color: RemileStyle.deletion)
                                }.font(RemileType.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RemileStyle.success.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .overlay(selectionBorder("change:" + change.id)).contentShape(Rectangle())
                                    .accessibilityAddTraits(state.selected == "change:" + change.id ? .isSelected : [])
                                    .accessibilityAction(named: Text("Show in source")) {
                                        navigate(change.anchor, highlight: .change, selection: "change:" + change.id)
                                    }
                                    .onTapGesture {
                                        navigate(change.anchor, highlight: .change, selection: "change:" + change.id)
                                    }
                            }
                        } else {
                            let threads = snapshot.archive.threads.filter { state.resolved || !$0.resolved }
                            if threads.isEmpty { empty(state.resolved ? "No comments" : "No open comments") }
                            ForEach(threads) { thread in
                                VStack(alignment: .leading, spacing: 8) {
                                    if thread.resolved {
                                        SymbolLabel("Resolved", systemImage: "checkmark.bubble").foregroundStyle(
                                            RemileStyle.secondaryInk)
                                    }
                                    ForEach(thread.messages) { message in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(message.author).fontWeight(.semibold)
                                            if let timestamp = message.timestamp { date(timestamp) }
                                            if message.id == thread.messages.first?.id,
                                                let anchor = snapshot.anchors[thread.id]
                                            {
                                                location(anchor, highlight: .comment, selection: "thread:" + thread.id)
                                            }
                                            Divider().opacity(0.4)
                                            Text(message.text)
                                        }
                                    }
                                }.font(RemileType.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RemileStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .overlay(selectionBorder("thread:" + thread.id)).contentShape(Rectangle())
                                    .accessibilityAddTraits(state.selected == "thread:" + thread.id ? .isSelected : [])
                                    .accessibilityAction(named: Text("Show in source")) {
                                        if let anchor = snapshot.anchors[thread.id] {
                                            navigate(anchor, highlight: .comment, selection: "thread:" + thread.id)
                                        }
                                    }
                                    .onTapGesture {
                                        if let anchor = snapshot.anchors[thread.id] {
                                            navigate(anchor, highlight: .comment, selection: "thread:" + thread.id)
                                        }
                                    }
                            }
                        }
                    } else if !state.busy {
                        empty("Review unavailable")
                    }
                }
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(
            RemileStyle.sidebar
        )
        .onDisappear { state.operation?.cancel() }
        .task(id: state.refreshID) { await refresh() }
        .sheet(isPresented: $state.signIn, onDismiss: { state.refreshID = UUID() }) {
            OverleafSignIn(profile: connection.profileID, projectID: connection.projectID) { state.signIn = false }
        }
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk).padding(.vertical, 18)
    }
    @ViewBuilder private func date(_ value: String) -> some View {
        if let date = OverleafReviewSnapshot.date(value) {
            Text(date, format: .dateTime.day().month(.abbreviated).hour().minute()).foregroundStyle(
                RemileStyle.secondaryInk)
        }
    }
    private func selectionBorder(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 10).stroke(
            state.selected == id ? RemileStyle.accent.opacity(0.5) : .clear, lineWidth: 1
        ).allowsHitTesting(false)
    }
    private func disabledReason(_ change: OverleafReviewSnapshot.Change) -> String? {
        if state.applying { return "Updating the change…" }
        if state.busy { return "Refreshing review…" }
        if !change.singleRange { return "Review this grouped change in Overleaf." }
        if project.compiling { return "Wait for compilation to finish." }
        if project.dirty || project.liveWorkspace.pendingDocumentCount > 0 { return "Wait for saved changes to sync." }
        if !project.canReviewChanges { return "Finish syncing, then refresh review." }
        if change.anchor.location(in: project.buffers) == nil { return "Refresh review to match the current source." }
        return nil
    }
    private func location(
        _ anchor: OverleafReviewSnapshot.Anchor, highlight: TeXProject.SourceJump.Highlight, selection: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                navigate(anchor, highlight: highlight, selection: selection)
            } label: {
                Text(anchor.file).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).foregroundStyle(RemileStyle.accent)
            .disabled(anchor.location(in: project.buffers) == nil)
            .remileHelp(
                anchor.location(in: project.buffers) == nil
                    ? "Available after synchronisation and review refresh" : "Show in source")
        }
    }
    private func navigate(
        _ anchor: OverleafReviewSnapshot.Anchor, highlight: TeXProject.SourceJump.Highlight, selection: String
    ) {
        state.selected = selection
        guard let target = anchor.location(in: project.buffers) else { return }
        project.selected = target.file
        project.sourceJump = .init(location: target, highlight: highlight)
    }
    private func export(json: Bool) {
        guard let snapshot = state.snapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = json ? [.json] : [.remileMarkdown]
        panel.nameFieldStringValue =
            connection.name.replacingOccurrences(of: "/", with: "-") + " review." + (json ? "json" : "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try snapshot.export(json: json).write(to: url, options: .atomic) } catch {
            state.failure = error.localizedDescription
        }
    }
    private func exportPackage() {
        guard let snapshot = state.snapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.title = "Export review and text sources"
        panel.nameFieldStringValue = connection.name.replacingOccurrences(of: "/", with: "-") + " review.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sources = project.buffers
        state.busy = true
        Task { @MainActor in
            defer { state.busy = false }
            do {
                try await Task.detached(priority: .utility) {
                    try OverleafReviewPackage.write(snapshot, sources: sources, to: url, replacing: true)
                }.value
            } catch { state.failure = error.localizedDescription }
        }
    }
    private func decide(_ change: OverleafReviewSnapshot.Change, accept: Bool) {
        guard !state.applying, let operation = project.decideReviewChange else { return }
        state.applying = true
        state.failure = nil
        state.operation = Task { @MainActor in
            defer {
                state.applying = false
                state.operation = nil
            }
            do {
                try await operation(change, accept)
                await refresh()
            } catch is CancellationError {} catch {
                let message = error.localizedDescription
                await refresh()
                state.failure = message
            }
        }
    }
    private func refresh() async {
        state.busy = true
        state.failure = nil
        state.needsSignIn = false
        defer { state.busy = false }
        do {
            let snapshot = try await OverleafReviewService.read(
                connection, paths: project.treeFiles, main: project.main)
            guard !Task.isCancelled else { return }
            archiveRead(snapshot.archive)
            state.snapshot = snapshot
            project.overleafReview = snapshot
            state.needsSignIn = snapshot.needsConnection
        } catch is CancellationError {} catch {
            if !Task.isCancelled {
                state.failure = error.localizedDescription
                state.needsSignIn = (error as? OverleafWebClient.Failure)?.needsConnection == true
            }
        }
    }
}

struct OverleafReviewDecisionButtons: View {
    let changeID: String
    var disabledReason: String? = nil
    let decide: (Bool) -> Void
    var body: some View {
        HStack(spacing: RemileControl.spacing) {
            Button {
                decide(true)
            } label: {
                SymbolIcon(systemName: "checkmark")
            }
            .accessibilityLabel("Accept change")
            .accessibilityIdentifier("overleaf.accept." + changeID)
            .remileHelp(disabledReason ?? "Accept · keep this change in Overleaf")
            Button {
                decide(false)
            } label: {
                SymbolIcon(systemName: "xmark")
            }
            .accessibilityLabel("Reject change")
            .accessibilityIdentifier("overleaf.reject." + changeID)
            .remileHelp(disabledReason ?? "Reject · restore the source before this change")
        }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.accent).disabled(disabledReason != nil)
    }
}
