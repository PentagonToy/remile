import SwiftUI

struct OverleafBar: View {
    @ObservedObject var library: OverleafLibrary
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    @ObservedObject private var live: OverleafLiveWorkspace
    init(library: OverleafLibrary, project: TeXProject, connection: OverleafConnection) {
        self.library = library; self.project = project; self.connection = connection; self.live = project.liveWorkspace
    }
    @StateObject private var presentation = LivePresentation()
    private final class LivePresentation: ObservableObject { @Published var connection = false; @Published var review = false; @Published var issue = false; @Published var settings = false; @Published var switching = false; @Published var premium = false }
    private var allowsGit: Bool { library.allowsGit(connection) }
    private var offline: Bool { library.offlineMode || NetworkAccess.offline || !library.hasNetwork || library.statuses[connection.id] == .offline }
    private var liveOffline: Bool { library.offlineMode || NetworkAccess.offline || !library.hasNetwork }
    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 12) {
            OverleafSyncModePicker(isLive: live.enabled, canStart: !library.busy && !project.compiling && !liveOffline, switching: presentation.switching || live.connecting, allowsGit: allowsGit, localOnly: connection.liveOnly == true, choose: changeMode)
            Spacer(minLength: 8)
            syncStatus(compact: geometry.size.width < 760)
                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            if !live.enabled {
                Button { if connection.liveOnly == true { changeMode(true) } else if allowsGit { Task { await library.check(connection, save: project.save) } } else { presentation.premium = true } } label: {
                    if geometry.size.width < 760 { Image(systemName: "arrow.triangle.2.circlepath") }
                    else { Text(connection.liveOnly == true ? "Connect Live" : "Check changes").padding(.horizontal, 6) }
                }.buttonStyle(RemileToolStyle()).accessibilityLabel(connection.liveOnly == true ? "Connect Live" : "Check changes").opacity(allowsGit || connection.liveOnly == true ? 1 : 0.45).remileHelp(connection.liveOnly == true ? "Connect project changes to Overleaf" : (allowsGit ? "Review local and Overleaf changes" : OverleafLibrary.premiumHint))
                    .popover(isPresented: $presentation.premium) { HelpBubbleContent(text: OverleafLibrary.premiumHint) }
                    .disabled(liveOffline || library.busy || project.compiling)
            }
            Divider().frame(height: 18).padding(.horizontal, 2)
            HStack(spacing: 4) {
                Button { library.openLibrary() } label: { Image(systemName: "folder") }
                    .accessibilityLabel("Overleaf projects").remileHelp("Overleaf projects").disabled(library.busy)
                Button { presentation.settings.toggle() } label: {
                    if !live.enabled && allowsGit && OverleafCredential.locked(connection.profileID) {
                        if geometry.size.width < 760 { Image(systemName: "lock") }
                        else { Label("Unlock", systemImage: "lock").padding(.horizontal, 6) }
                    } else { Image(systemName: "person.crop.circle") }
                }.accessibilityLabel(!live.enabled && allowsGit && OverleafCredential.locked(connection.profileID) ? "Unlock connection" : "Connection settings")
                    .remileHelp("Connection settings").popover(isPresented: $presentation.settings) { connectionSettings }
            }.buttonStyle(RemileToolStyle()).font(.system(size: 15))
        }.font(RemileType.caption).foregroundStyle(RemileStyle.ink).padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(height: 48).background(RemileStyle.editorBar)
            .modifier(OverleafAutoSync(library: library, project: project, connection: connection))
            .sheet(isPresented: $presentation.connection, onDismiss: { if live.enabled { Task { await live.retry() } } }) { OverleafSignIn(profile: connection.profileID) { presentation.connection = false } }
            .sheet(isPresented: $presentation.review) {
                if let conflict = live.conflict { OverleafLiveReview(conflict: conflict, choose: { text in presentation.review = false; Task { await live.choose(text: text) } }, close: { presentation.review = false }) }
            }
            .onAppear {
                project.canReviewChanges = live.connected && !live.connecting && !live.syncingFiles && live.pendingDocumentCount == 0 && live.issue == nil && !project.compiling && !library.busy
                project.decideReviewChange = { [weak live] change, accept in
                    guard let live else { throw OverleafGit.Failure("Reconnect Live sync to review changes.") }
                    try await live.decideReviewChange(change, accept: accept)
                }
            }
            .onChange(of: live.connected && !live.connecting && !live.syncingFiles && live.pendingDocumentCount == 0 && live.issue == nil && !project.compiling && !library.busy) { project.canReviewChanges = $0 }
            .onChange(of: liveOffline) { _ in Task { await live.networkChanged() } }
            .onAppear {
                live.setVisible(true)
                if OverleafSyncPreference.live(connection.id), !liveOffline { live.connectVisible(project: project, library: library, connection: connection) }
            }
            .onDisappear { project.canReviewChanges = false; project.decideReviewChange = nil; live.setVisible(false) }
    }
    private func changeMode(_ isLive: Bool) {
        guard isLive != live.enabled, (!presentation.switching && !live.connecting) || (!isLive && live.connecting) else { return }
        guard !isLive || (!library.busy && !project.compiling && !liveOffline) else { return }
        OverleafSyncPreference.choose(isLive, for: connection.id)
        presentation.switching = true
        Task {
            defer { presentation.switching = false }
            if isLive { await live.start(project: project, library: library, connection: connection) }
            else { await live.stop() }
        }
    }
    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection").font(RemileType.callout.weight(.semibold))
            Text(connection.account).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            Toggle("Work offline", isOn: Binding(get: { library.offlineMode }, set: { offline in
                if offline && live.enabled { Task { await live.suspend(); library.offlineMode = true } }
                else { library.offlineMode = offline }
            })).toggleStyle(.switch).controlSize(.small).disabled(library.busy || presentation.switching)
            Divider()
            if !live.enabled && allowsGit && OverleafCredential.locked(connection.profileID) {
                Button("Unlock Git connection") { Task { await library.unlock(connection) } }.disabled(library.busy)
            }
            Button("Account plan…") { presentation.settings = false; library.openLibrary(add: true) }.disabled(library.busy)
            Button("Manage account…") { presentation.settings = false; presentation.connection = true }.disabled(liveOffline)
        }.padding(18).frame(width: 260, alignment: .leading).background(RemileStyle.background)
    }
    @ViewBuilder private func syncStatus(compact: Bool) -> some View {
            if live.enabled {
                if liveOffline { Label("Saved locally · offline", systemImage: "icloud.slash").foregroundStyle(RemileStyle.secondaryInk) }
                else if live.connecting || live.reconnecting { ProgressView().controlSize(.small); Text(live.syncingFiles ? "Checking files…" : live.reconnecting ? "Reconnecting…" : "Connecting…") }
                else if let issue = live.issue {
                    Button {
                        if live.conflict != nil { presentation.review = true }
                        else { Task { await live.retry() } }
                    } label: { Label(compact ? "Paused" : "Paused · " + live.pauseReason, systemImage: "arrow.clockwise") }
                        .foregroundStyle(RemileStyle.warning).remileHelp(issue)
                        .disabled(liveOffline || project.compiling).accessibilityHint("Reconnect and check the latest files")
                    if let recovery = live.recoveryDirectory { Button("Recovery copies") { NSWorkspace.shared.open(recovery) } }
                    if live.conflict != nil { Button("Review edits") { presentation.review = true } }
                    else if live.requiresGitReview && connection.liveOnly == true { Button("Work locally") { Task { await live.stop() } } }
                    else if live.requiresGitReview { Button(compact ? "Review Git" : "Stop live and review Git") { if allowsGit { Task { await live.reviewGit() } } else { presentation.premium = true } }.opacity(allowsGit ? 1 : 0.45).disabled(liveOffline || project.compiling).remileHelp(allowsGit ? "Stop live sync and review project file changes through Git" : OverleafLibrary.premiumHint).popover(isPresented: $presentation.premium) { HelpBubbleContent(text: OverleafLibrary.premiumHint) } }
                } else if live.connected {
                    if live.pendingDocumentCount > 0 {
                        Label("Confirming · \(live.pendingDocumentCount) \(live.pendingDocumentCount == 1 ? "file" : "files")", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(RemileStyle.accent)
                    } else if let date = live.lastConfirmedAt {
                        Label(compact ? "Confirmed" : "Confirmed " + date.formatted(date: .omitted, time: .standard), systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success)
                            .remileHelp("All connected text files match the confirmed Overleaf state.")
                    } else { Text("Checking changes…").foregroundStyle(RemileStyle.secondaryInk) }
                } else { Text("Live sync paused").foregroundStyle(RemileStyle.warning) }
            } else if library.busy { ProgressView().controlSize(.small).remileHelp("Checking project changes") }
            else if !allowsGit { Label("Local only", systemImage: "desktopcomputer").foregroundStyle(RemileStyle.secondaryInk).remileHelp("Your edits stay on this Mac. Use Live to sync project changes.") }
            else if !library.offlineMode, library.hasNetwork, OverleafCredential.locked(connection.profileID) { Label(compact ? "Locked" : "Connection locked", systemImage: "lock").foregroundStyle(RemileStyle.warning).remileHelp("Your work is saved on this Mac. Unlock the saved connection to check Overleaf changes.") }
            else if offline { Label(library.pendingFiles.contains(connection.id) ? "Changes saved locally" : "Offline", systemImage: "icloud.slash").foregroundStyle(RemileStyle.warning).remileHelp("Your work stays on this Mac. Check changes when you reconnect.") }
            else if library.statuses[connection.id] == .conflict { Label("Conflicting edits", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).remileHelp("Overlapping edits need your choice before syncing.") }
            else if library.statuses[connection.id] == .changes { Label("Changes to review", systemImage: "circle.fill").foregroundStyle(RemileStyle.warning).remileHelp("Review local and Overleaf changes before applying or publishing.") }
            else if library.pendingFiles.contains(connection.id) { Label("Changes saved locally", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(RemileStyle.accent).remileHelp("Your edits will sync after a short pause while this project is online.") }
            else if let date = library.syncedAt[connection.id] {
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Label(OverleafLibrary.syncAge(date, now: tick.date), systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).remileHelp("Last matched: " + date.formatted(date: .abbreviated, time: .shortened))
                }
            }
    }
}

/// Two explicit modes with equal hit areas and independently available actions.
struct OverleafSyncModePicker: View {
    let isLive: Bool
    let canStart: Bool
    let switching: Bool
    var allowsGit = true
    var localOnly = false
    let choose: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            mode("Live", live: true, help: "Text edits sync live. File updates sync automatically.")
            mode(localOnly ? "Local" : "Private", live: false, help: localOnly ? "Keep working on this Mac. Choose Live to sync project changes." : (allowsGit ? "Local edits sync through Git. Remote changes wait for review." : "Work locally. Git sync requires Overleaf Premium."))
        }.padding(3).background(RemileStyle.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(RemileStyle.ink.opacity(0.08), lineWidth: 1))
            .fixedSize().accessibilityElement(children: .contain).accessibilityLabel("Sync mode")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isLive)
            .onMoveCommand { direction in
                if direction == .left && canStart && !switching { choose(true) }
                else if direction == .right { choose(false) }
            }
    }
    private func mode(_ title: String, live: Bool, help: String) -> some View {
        Button { if live != isLive { choose(live) } } label: {
            Text(title).font(RemileType.caption.weight(isLive == live ? .semibold : .regular))
                .foregroundStyle(isLive == live ? RemileStyle.ink : RemileStyle.secondaryInk)
                .frame(width: 76, height: 28).contentShape(Rectangle())
                .background(isLive == live ? RemileStyle.ink.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).disabled((switching && (live || !isLive)) || (live && !isLive && !canStart))
            .accessibilityLabel(title + " sync").accessibilityAddTraits(isLive == live ? .isSelected : [])
            .remileHelp(help)
    }
}

struct OverleafLiveReview: View {
    let conflict: OverleafLiveWorkspace.Conflict
    let choose: (String) -> Void
    let close: () -> Void
    private let changes: [OverleafLive.Edit]
    private let lineNumbers: [Int]
    @StateObject private var selection = Selection()
    private final class Selection: ObservableObject { @Published var remote: [Int: Bool] = [:] }
    init(conflict: OverleafLiveWorkspace.Conflict, choose: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.conflict = conflict; self.choose = choose; self.close = close
        let edits = (try? OverleafLiveText.edits(from: conflict.local, to: conflict.remote.text)) ?? []
        self.changes = edits
        let units = conflict.local.utf16
        var cursor = units.startIndex, offset = 0, line = 1, numbers: [Int] = []
        for edit in edits {
            while offset < edit.offset, cursor < units.endIndex {
                if units[cursor] == 10 { line += 1 }
                units.formIndex(after: &cursor); offset += 1
            }
            numbers.append(line)
        }
        self.lineNumbers = numbers
    }
    private var resolved: Bool { !changes.isEmpty && changes.indices.allSatisfy { selection.remote[$0] != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Review live edits").font(RemileType.heading); Spacer(); Text(conflict.path).lineLimit(1) }
            Text("Choose each changed section. Newer edits are checked again before applying.").font(RemileType.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(changes.indices, id: \.self) { index in
                        let edit = changes[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Section \(index + 1) · local line \(lineNumbers[index])").font(RemileType.caption).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 12) {
                                section("Local draft", text: edit.deleted, index: index, remote: false)
                                section("Overleaf", text: edit.inserted, index: index, remote: true)
                            }
                        }
                    }
                }.padding(.trailing, 8)
            }
            HStack {
                Button("Later", action: close); Spacer()
                Button("Use all Overleaf") { choose(conflict.remote.text) }
                Button("Keep all local") { choose(conflict.local) }
                Button("Apply sections") {
                    if let result = try? OverleafLiveText.replacing(conflict.local, edits: changes.enumerated().compactMap { selection.remote[$0.offset] == true ? $0.element : nil }) { choose(result) }
                }.disabled(!resolved).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 900, height: 580).background(RemileStyle.background)
    }
    private func context(_ index: Int, before: Bool) -> String {
        let edit = changes[index], local = conflict.local
        let offset = edit.offset + (before ? 0 : edit.deleted.utf16.count)
        let boundary = String.Index(utf16Offset: offset, in: local)
        if before { return String(local[..<boundary].suffix(80)).components(separatedBy: "\n").last ?? "" }
        return String(local[boundary...].prefix(80)).components(separatedBy: "\n").first ?? ""
    }
    private func section(_ title: String, text: String, index: Int, remote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { selection.remote[index] = remote } label: {
                Label(title, systemImage: selection.remote[index] == remote ? "checkmark.circle.fill" : "circle")
            }.buttonStyle(.plain).font(RemileType.callout.weight(.semibold))
            Text("\(Text(context(index, before: true)).foregroundColor(RemileStyle.secondaryInk))\(Text(text.isEmpty ? "(No text)" : text).foregroundColor(RemileStyle.ink))\(Text(context(index, before: false)).foregroundColor(RemileStyle.secondaryInk))")
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background((remote ? RemileStyle.success : RemileStyle.warning).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection.remote[index] == remote ? RemileStyle.accent : .clear, lineWidth: 1))
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
                        .buttonStyle(RemileToolStyle()).remileHelp(state.files ? "Hide changed files" : "Show changed files")
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
