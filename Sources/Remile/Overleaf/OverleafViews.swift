import SwiftUI

struct OverleafBar: View {
    @ObservedObject var library: OverleafLibrary
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    @ObservedObject private var live: OverleafOnlineWorkspace
    @State private var accounts = false
    @Environment(\.scenePhase) private var scenePhase
    init(library: OverleafLibrary, project: TeXProject, connection: OverleafConnection) {
        self.library = library; self.project = project; self.connection = connection; live = project.liveWorkspace
    }
    var body: some View {
        HStack(spacing: RemileControl.spacing) {
            OverleafSyncModePicker(isLive: live.enabled, canStart: true, switching: false, choose: changeMode)
            Spacer(minLength: RemileControl.spacing)
            status.lineLimit(1).font(RemileType.caption).layoutPriority(-1)
            if live.connecting { ProgressView().controlSize(.small) }
            Button { Task { await live.retry() } } label: { SymbolIcon(systemName: "arrow.triangle.2.circlepath") }
                .disabled(!live.enabled || live.connecting || live.reviewing || NetworkAccess.offline || library.offlineMode)
                .accessibilityLabel("Sync now").remileHelp("Sync saved changes with Overleaf")
            if live.requiresGitReview {
                Button("Review changes") { Task { await live.reviewGit() } }.disabled(live.connecting)
            }
            Menu {
                Button("Overleaf projects") { library.openLibrary() }
                Button("Git token…") { accounts = true }
                Button("Open in browser") { NSWorkspace.shared.open(connection.webURL) }
                if let recovery = live.recoveryDirectory { Button("Recovery copies") { NSWorkspace.shared.open(recovery) } }
            } label: { SymbolIcon(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: RemileControl.toolHit, height: RemileControl.toolHit).accessibilityLabel("Connection options")
        }.buttonStyle(RemileToolStyle()).foregroundStyle(RemileStyle.ink)
            .padding(.horizontal, RemileControl.spacing * 2).frame(height: 48).background(RemileStyle.editorBar)
            .sheet(isPresented: $accounts) { OverleafAccountManager(library: library, selected: connection.profileID, requestGitToken: true, prepareRemoval: { _ in false }) { accounts = false } }
            .onAppear {
                project.canReviewChanges = live.connected && !live.syncingFiles && !live.reviewing && live.pendingDocumentCount == 0
                project.decideReviewChange = { [weak live] change, accept in
                    guard let live else { throw OverleafGit.Failure("Open the project to review changes.") }
                    try await live.decideReviewChange(change, accept: accept)
                }
                if OverleafSyncPreference.live(connection.id) { live.connectVisible(project: project, library: library, connection: connection) }
            }
            .onDisappear { live.setVisible(false); project.canReviewChanges = false }
            .onChange(of: scenePhase) { phase in
                if phase == .active { live.foregrounded() }
            }
            .onChange(of: live.connected && !live.syncingFiles && !live.reviewing && live.pendingDocumentCount == 0 && live.issue == nil && !project.compiling) { project.canReviewChanges = $0 }
            .onChange(of: library.statuses[connection.id] == .online && library.review == nil) { ready in
                if ready, live.enabled, live.requiresGitReview {
                    Task { await live.start(project: project, library: library, connection: connection); await live.retry() }
                }
            }
            .onChange(of: project.editRevision) { live.edited() }
            .onChange(of: project.fileRevision) { live.edited() }
            .onChange(of: library.hasNetwork) { Task { await live.networkChanged() } }
            .onChange(of: library.offlineMode || NetworkAccess.offline) { Task { await live.networkChanged() } }
    }
    @ViewBuilder private var status: some View {
        if project.dirty { Text("Unsaved changes").foregroundStyle(RemileStyle.secondaryInk).help("These changes have not been saved on this Mac.") }
        else if !live.enabled { Text("Saved on this Mac").foregroundStyle(RemileStyle.secondaryInk) }
        else if !library.hasNetwork || library.offlineMode || NetworkAccess.offline { Text("Saved locally · offline").foregroundStyle(RemileStyle.secondaryInk) }
        else if live.connecting { Text("Syncing…") }
        else if live.requiresGitReview { Text("Review needed").foregroundStyle(RemileStyle.warning) }
        else if let issue = live.issue { Text(live.pauseReason).foregroundStyle(RemileStyle.warning).help(issue) }
        else if live.pendingDocumentCount > 0 { Text("Saved locally · waiting to sync").foregroundStyle(RemileStyle.secondaryInk) }
        else if let date = live.lastConfirmedAt { Text("Synced " + date.formatted(date: .omitted, time: .standard)).foregroundStyle(RemileStyle.success) }
        else { Text("Checking changes…").foregroundStyle(RemileStyle.secondaryInk) }
    }
    private func changeMode(_ online: Bool) {
        OverleafSyncPreference.choose(online, for: connection.id)
        Task {
            if online { await live.start(project: project, library: library, connection: connection) }
            else { await live.stop() }
        }
    }
}

struct OverleafSyncModePicker: View {
    let isLive: Bool
    let canStart: Bool
    let switching: Bool
    var allowsGit = true
    var localOnly = false
    let choose: (Bool) -> Void
    var body: some View {
        HStack(spacing: 2) {
            mode("Online", online: true)
            mode("On-device", online: false)
        }.padding(3).background(RemileStyle.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: RemileRadius.control))
            .fixedSize().accessibilityElement(children: .contain).accessibilityLabel("Sync mode")
    }
    private func mode(_ title: String, online: Bool) -> some View {
        Button { choose(online) } label: {
            Text(title).font(RemileType.caption.weight(isLive == online ? .semibold : .regular))
                .foregroundStyle(isLive == online ? RemileStyle.ink : RemileStyle.secondaryInk)
                .frame(width: 80, height: RemileControl.toolHit).contentShape(Rectangle())
                .background(isLive == online ? RemileStyle.ink.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: RemileRadius.control))
        }.buttonStyle(.plain).accessibilityAddTraits(isLive == online ? .isSelected : [])
            .remileHelp(online ? "Sync through Git when connected" : "Keep working locally without syncing")
    }
}

struct OverleafComparison: View {
    @ObservedObject var library: OverleafLibrary
    let review: OverleafGit.Review
    let reload: (URL) -> Void
    @StateObject private var state = State()
    @MainActor private final class State: ObservableObject { @Published var path: String?; @Published var choices: [String: Bool] = [:]; @Published var combined = false; @Published var files = true }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var selected: OverleafGit.Change? { review.changes.first { $0.path == state.path } ?? review.changes.first }
    private var unresolved: Bool { review.changes.contains { $0.conflict && state.choices[$0.path] == nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if !review.changes.isEmpty {
                    Button { state.files.toggle() } label: { SymbolIcon(systemName: "sidebar.left") }
                        .buttonStyle(RemileToolStyle()).remileHelp(state.files ? "Hide changed files" : "Show changed files")
                        .accessibilityLabel("Toggle changed files").accessibilityValue(state.files ? "Expanded" : "Collapsed")
                }
                Text("Compare changes").font(RemileType.heading); Spacer(); Text(review.connection.name).foregroundStyle(.secondary).lineLimit(1)
            }
            if review.changes.isEmpty { SymbolLabel("Everything matches", systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).padding(.vertical, 24) }
            else {
                ReaderSplit(isPresented: state.files, initial: 200, minimum: 160, maximum: 320, minimumContent: 480, label: "changed files", pane: {
                    VStack(alignment: .leading, spacing: 10) {
                    Text("Files · \(review.changes.count)").font(RemileType.caption).foregroundStyle(.secondary)
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(review.changes) { change in
                        Button { state.path = change.path } label: { HStack { Text(change.path).lineLimit(2); Spacer(); if change.conflict { SymbolIcon(systemName: state.choices[change.path] == nil ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(.red) } }.padding(7).frame(maxWidth: .infinity, alignment: .leading).background(selected?.path == change.path ? RemileStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                    } } }
                    }.padding(.trailing, 8)
                }, content: {
                    if let selected {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(selected.path).font(RemileType.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle); Spacer(); Toggle("Combined preview", isOn: $state.combined).toggleStyle(.button).font(RemileType.caption) }
                            if state.combined {
                                sourceColumn("Combined", selected.conflict ? (state.choices[selected.path].map { $0 ? selected.local : selected.remote } ?? selected.result) : selected.result)
                            } else {
                                HStack(spacing: 12) { sourceColumn("Local", selected.local, other: selected.remote); sourceColumn("Overleaf", selected.remote, other: selected.local) }
                            }
                            if selected.conflict {
                                Text("Overlapping edits. Choose the version to keep.").font(RemileType.caption)
                                HStack { Button("Keep local") { state.choices[selected.path] = true }; Button("Use Overleaf") { state.choices[selected.path] = false }; if let local = state.choices[selected.path] { SymbolLabel(local ? "Local selected" : "Overleaf selected", systemImage: "checkmark").font(RemileType.caption) } }
                            } else { SymbolLabel("Changes combine safely", systemImage: "checkmark.circle.fill").font(RemileType.caption).foregroundStyle(RemileStyle.success) }
                        }.padding(.leading, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }).animation(reduceMotion ? nil : RemileMotion.panel, value: state.files)
            }
            if let error = library.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning) }
            HStack {
                Button("Cancel") { library.dismissReview() }.keyboardShortcut(.cancelAction).disabled(library.busy)
                Spacer()
                if library.busy { ProgressView().controlSize(.small) }
                if !review.changes.isEmpty {
                    Button("Update local") { finish(false) }.disabled(unresolved || library.busy || library.offlineMode)
                    if review.localChanges { Button("Publish reviewed changes") { finish(true) }.disabled(unresolved || library.busy || library.offlineMode) }
                } else { Button("Done") { library.dismissReview() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(24)
            .frame(minWidth: 760, idealWidth: 1200, maxWidth: .infinity, minHeight: 480, idealHeight: 760, maxHeight: .infinity)
            .background(RemileStyle.background).background(ComparisonWindowSizing())
            .interactiveDismissDisabled(library.busy)
    }
    private func sourceColumn(_ title: String, _ text: String, other: String? = nil) -> some View {
        let lines = Array(text.components(separatedBy: "\n").prefix(2000))
        let compared = other.map { Array($0.components(separatedBy: "\n").prefix(2000)) }
        let changed = Set(compared?.difference(from: lines).compactMap { change -> Int? in if case .remove(let offset, _, _) = change { return offset }; return nil } ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(RemileType.callout.weight(.semibold))
            GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) { Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing); Text(line.isEmpty ? " " : line).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2).background(changed.contains(index) ? (title == "Local" ? RemileStyle.warning : RemileStyle.success).opacity(0.17) : .clear)
                    }
                    if text.components(separatedBy: "\n").count > 2000 { Text("First 2,000 lines shown").foregroundStyle(.secondary) }
                }.font(.system(size: 12, design: .monospaced)).frame(minWidth: max(0, viewport.size.width - 16), alignment: .leading).padding(8)
            }
            }.background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func finish(_ publish: Bool) { Task { await library.finish(choices: state.choices, publish: publish, reload: reload) } }
}

/// Applies only to the comparison's own hosting window, leaving the document window unchanged.
private struct ComparisonWindowSizing: NSViewRepresentable {
    final class Surface: NSView {
        private weak var configured: NSWindow?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.configured !== window else { return }
                self.configured = window
                window.styleMask.insert(.resizable)
                let screen = window.screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
                window.contentMinSize = NSSize(width: 760, height: 480)
                window.setContentSize(NSSize(width: min(1200, screen.width - 80), height: min(760, screen.height - 100)))
            }
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}
}
