import SwiftUI
import UniformTypeIdentifiers

struct OverleafReviewPanel: View {
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    var archiveRead: (OverleafThreadArchive) -> Void = { _ in }
    @StateObject private var state = ReviewState()
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
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Overleaf review").font(RemileType.callout.weight(.semibold))
                Spacer(minLength: 4)
                if state.busy { ProgressView().controlSize(.small) }
                Button { state.refreshID = UUID() } label: { SymbolIcon(systemName: "arrow.clockwise") }.disabled(state.busy || state.applying).remileHelp("Refresh review").accessibilityLabel("Refresh review")
                Menu {
                    Button("Export all as Markdown…") { export(json: false) }
                    Button("Export all as JSON…") { export(json: true) }
                    Button("Review package with sources…") { exportPackage() }
                } label: { SymbolIcon(systemName: "square.and.arrow.up") }.disabled(state.snapshot == nil || state.busy || state.applying).remileHelp("Export all comments and changes").accessibilityLabel("Export review")
            }.buttonStyle(RemileToolStyle())
            RemileSegmentedControl(title: "Review entries", selection: $state.tab, options: [false, true], label: { $0 ? "Changes · \(state.snapshot?.changes.count ?? 0)" : "Comments · \(state.snapshot?.archive.threads.count ?? 0)" })
            if let failure = state.failure { Text(failure).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            if state.needsSignIn { Button("Connect Overleaf") { state.signIn = true } }
            if let warning = state.snapshot?.warning { Text(warning).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk) }
            if !state.tab { Toggle("Show resolved", isOn: $state.resolved).toggleStyle(.checkbox).font(RemileType.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let snapshot = state.snapshot {
                        if state.tab {
                            if snapshot.changes.isEmpty { empty(snapshot.warning == nil ? "No tracked changes" : "Changes unavailable") }
                            ForEach(snapshot.changes) { change in
                                VStack(alignment: .leading, spacing: 8) {
                                    SymbolLabel(change.insertion ? "Added" : "Deleted", systemImage: change.insertion ? "plus" : "minus").foregroundStyle(change.insertion ? RemileStyle.success : RemileStyle.warning)
                                    location(change.anchor, highlight: .change)
                                    Text(change.text)
                                    if let timestamp = change.timestamp { date(timestamp) }
                                    HStack {
                                        Button("Accept") { decide(change, accept: true) }.remileHelp("Keep this change in Overleaf")
                                        Button("Reject") { decide(change, accept: false) }.remileHelp("Restore the source before this change")
                                    }.buttonStyle(RemileToolStyle()).disabled(state.applying || state.busy || !change.singleRange || !project.canReviewChanges || change.anchor.location(in: project.buffers) == nil)
                                    if !change.singleRange { Text("Grouped change · decide in Overleaf").foregroundStyle(RemileStyle.secondaryInk) }
                                    else if !project.canReviewChanges { Text("Requires confirmed Live sync").foregroundStyle(RemileStyle.secondaryInk) }
                                }.font(RemileType.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RemileStyle.success.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle()).onTapGesture { navigate(change.anchor, highlight: .change) }
                            }
                        } else {
                            let threads = snapshot.archive.threads.filter { state.resolved || !$0.resolved }
                            if threads.isEmpty { empty(state.resolved ? "No comments" : "No open comments") }
                            ForEach(threads) { thread in
                                VStack(alignment: .leading, spacing: 8) {
                                    if thread.resolved { SymbolLabel("Resolved", systemImage: "checkmark.bubble").foregroundStyle(RemileStyle.secondaryInk) }
                                    if let anchor = snapshot.anchors[thread.id] { location(anchor, highlight: .comment) }
                                    else { Text("Source location unavailable").foregroundStyle(RemileStyle.secondaryInk) }
                                    ForEach(thread.messages) { message in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(message.author).fontWeight(.semibold)
                                            Text(message.text)
                                            if let timestamp = message.timestamp { date(timestamp) }
                                        }
                                    }
                                }.font(RemileType.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RemileStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle()).onTapGesture { if let anchor = snapshot.anchors[thread.id] { navigate(anchor, highlight: .comment) } }
                            }
                        }
                    } else if !state.busy { empty("Review unavailable") }
                }.padding(.trailing, 18)
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(RemileStyle.sidebar)
            .onDisappear { state.operation?.cancel() }
            .task(id: state.refreshID) { await refresh() }
            .sheet(isPresented: $state.signIn, onDismiss: { state.refreshID = UUID() }) { OverleafSignIn(profile: connection.profileID) { state.signIn = false } }
    }
    private func empty(_ text: String) -> some View { Text(text).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk).padding(.vertical, 18) }
    @ViewBuilder private func date(_ value: String) -> some View {
        if let date = ISO8601DateFormatter().date(from: value) { Text(date, format: .dateTime.day().month(.abbreviated).hour().minute()).foregroundStyle(RemileStyle.secondaryInk) }
    }
    private func location(_ anchor: OverleafReviewSnapshot.Anchor, highlight: TeXProject.SourceJump.Highlight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                navigate(anchor, highlight: highlight)
            } label: { Text("\(anchor.file) · Line \(anchor.line + 1)").multilineTextAlignment(.leading) }.buttonStyle(.plain).foregroundStyle(RemileStyle.accent).disabled(anchor.location(in: project.buffers) == nil)
            if anchor.location(in: project.buffers) == nil { Text(anchor.localPathKnown ? "Source changed · refresh after sync" : "Local source path unavailable").foregroundStyle(RemileStyle.secondaryInk) }
        }
    }
    private func navigate(_ anchor: OverleafReviewSnapshot.Anchor, highlight: TeXProject.SourceJump.Highlight) {
        guard let target = anchor.location(in: project.buffers) else { return }
        project.selected = target.file; project.sourceJump = .init(location: target, highlight: highlight)
    }
    private func export(json: Bool) {
        guard let snapshot = state.snapshot else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = json ? [.json] : [.remileMarkdown]
        panel.nameFieldStringValue = connection.name.replacingOccurrences(of: "/", with: "-") + " review." + (json ? "json" : "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try snapshot.export(json: json).write(to: url, options: .atomic) }
        catch { state.failure = error.localizedDescription }
    }
    private func exportPackage() {
        guard let snapshot = state.snapshot else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
        panel.title = "Export review and text sources"
        panel.nameFieldStringValue = connection.name.replacingOccurrences(of: "/", with: "-") + " review.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sources = project.buffers
        state.busy = true
        Task { @MainActor in
            defer { state.busy = false }
            do { try await Task.detached(priority: .utility) { try OverleafReviewPackage.write(snapshot, sources: sources, to: url, replacing: true) }.value }
            catch { state.failure = error.localizedDescription }
        }
    }
    private func decide(_ change: OverleafReviewSnapshot.Change, accept: Bool) {
        guard !state.applying, let operation = project.decideReviewChange else { return }
        state.applying = true; state.failure = nil
        state.operation = Task { @MainActor in
            defer { state.applying = false; state.operation = nil }
            do {
                try await operation(change, accept)
                await refresh()
            } catch is CancellationError { }
            catch { state.failure = error.localizedDescription }
        }
    }
    private func refresh() async {
        state.busy = true; state.failure = nil; state.needsSignIn = false
        defer { state.busy = false }
        do {
            let snapshot = try await OverleafReviewService.read(connection, paths: project.treeFiles, main: project.main)
            guard !Task.isCancelled else { return }
            archiveRead(snapshot.archive)
            state.snapshot = snapshot; project.overleafReview = snapshot
            state.needsSignIn = snapshot.needsConnection
        } catch is CancellationError { }
        catch { if !Task.isCancelled { state.failure = error.localizedDescription; state.needsSignIn = (error as? OverleafWebClient.Failure)?.needsConnection == true } }
    }
}
