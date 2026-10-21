import SwiftUI

struct OverleafBar: View {
    @ObservedObject var library: OverleafLibrary
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    private var offline: Bool { library.offlineMode || NetworkAccess.offline || !library.hasNetwork || library.statuses[connection.id] == .offline }
    var body: some View {
        HStack(spacing: 12) {
            Label("Private sync", systemImage: "eye.slash").lineLimit(1).font(RemileType.caption).foregroundStyle(offline ? RemileStyle.warning : RemileStyle.success).bubbleHelp("Git sync does not join Overleaf’s live presence channel. Published edits still appear in project history.")
            Spacer()
            if library.busy { ProgressView().controlSize(.small).bubbleHelp("Checking project changes") }
            else if !library.offlineMode, library.hasNetwork, OverleafCredential.locked(connection.profileID) { Label("Connection locked", systemImage: "lock").foregroundStyle(RemileStyle.warning).bubbleHelp("Your work is saved on this Mac. Unlock the saved connection to check Overleaf changes.") }
            else if offline { Label(library.pendingFiles.contains(connection.id) ? "Changes saved locally" : "Offline", systemImage: "icloud.slash").foregroundStyle(RemileStyle.warning).bubbleHelp("Your work stays on this Mac. Check changes when you reconnect.") }
            else if library.statuses[connection.id] == .conflict { Label("Conflicting edits", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).bubbleHelp("Overlapping edits need your choice before syncing.") }
            else if library.statuses[connection.id] == .changes { Label("Changes to review", systemImage: "circle.fill").foregroundStyle(RemileStyle.warning).bubbleHelp("Review local and Overleaf changes before applying or publishing.") }
            else if library.pendingFiles.contains(connection.id) { Label("Changes saved locally", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(RemileStyle.accent).bubbleHelp("Your edits will sync after a short pause while this project is online.") }
            else if let date = library.syncedAt[connection.id] {
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Label(OverleafLibrary.syncAge(date, now: tick.date), systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).bubbleHelp("Last matched: " + date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Button { library.offlineMode.toggle() } label: {
                Label(library.offlineMode ? "Offline" : "Online", systemImage: library.offlineMode ? "icloud.slash" : "cloud")
            }.foregroundStyle(library.offlineMode ? RemileStyle.ink : RemileStyle.accent)
                .bubbleHelp(library.offlineMode ? "Offline: edits stay on this Mac. Switch online to send your changes automatically." : "Online: your edits sync after a short pause. Changes on Overleaf wait for your review. Sync stops when you leave this project.")
                .accessibilityValue(library.offlineMode ? "Offline" : "Online").disabled(library.busy)
            if OverleafCredential.locked(connection.profileID) { Button("Unlock") { Task { await library.unlock(connection) } }.disabled(library.busy).bubbleHelp("Allow this app to use the saved Git connection in Keychain") }
            Button("Check changes") { guard project.save() else { return }; Task { await library.check(connection) } }.disabled(NetworkAccess.offline || library.offlineMode || library.busy || project.compiling)
            Button { library.commentsProject = connection } label: { Image(systemName: "text.bubble") }.bubbleHelp("Comments and export").disabled(library.offlineMode || library.busy)
            Button { library.openLibrary() } label: { Image(systemName: "books.vertical") }.bubbleHelp("Overleaf library").disabled(library.busy)
        }.font(RemileType.caption).padding(.horizontal, 16).padding(.vertical, 8).background(RemileStyle.editorBar)
            .modifier(OverleafAutoSync(library: library, project: project, connection: connection))
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
                    Button { state.files.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(RemileToolStyle()).bubbleHelp(state.files ? "Hide changed files" : "Show changed files")
                        .accessibilityLabel("Toggle changed files").accessibilityValue(state.files ? "Expanded" : "Collapsed")
                }
                Text("Compare changes").font(RemileType.heading); Spacer(); Text(review.connection.name).foregroundStyle(.secondary).lineLimit(1)
            }
            if review.changes.isEmpty { Label("Everything matches", systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).padding(.vertical, 24) }
            else {
                ReaderSplit(isPresented: state.files, initial: 200, minimum: 160, maximum: 320, minimumContent: 480, label: "changed files", pane: {
                    VStack(alignment: .leading, spacing: 10) {
                    Text("Files · \(review.changes.count)").font(RemileType.caption).foregroundStyle(.secondary)
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(review.changes) { change in
                        Button { state.path = change.path } label: { HStack { Text(change.path).lineLimit(2); Spacer(); if change.conflict { Image(systemName: state.choices[change.path] == nil ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(.red) } }.padding(7).frame(maxWidth: .infinity, alignment: .leading).background(selected?.path == change.path ? RemileStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
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
                                HStack { Button("Keep local") { state.choices[selected.path] = true }; Button("Use Overleaf") { state.choices[selected.path] = false }; if let local = state.choices[selected.path] { Label(local ? "Local selected" : "Overleaf selected", systemImage: "checkmark").font(RemileType.caption) } }
                            } else { Label("Changes combine safely", systemImage: "checkmark.circle.fill").font(RemileType.caption).foregroundStyle(RemileStyle.success) }
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
