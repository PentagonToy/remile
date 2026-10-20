import SwiftUI

struct OverleafBar: View {
    @ObservedObject var library: OverleafLibrary
    @ObservedObject var project: TeXProject
    let connection: OverleafConnection
    private var offline: Bool { library.offlineMode || !library.hasNetwork || library.statuses[connection.id] == .offline }
    var body: some View {
        HStack(spacing: 12) {
            Label("Private sync", systemImage: "eye.slash").lineLimit(1).font(RemileType.caption).foregroundStyle(offline ? RemileStyle.warning : RemileStyle.success).remileHelp("Git sync does not join Overleaf’s live presence channel. Published edits still appear in project history.")
            Spacer()
            if library.busy { ProgressView().controlSize(.small).remileHelp("Checking project changes") }
            else if !library.offlineMode, library.hasNetwork, OverleafCredential.locked(connection.profileID) { Label("Connection locked", systemImage: "lock").foregroundStyle(RemileStyle.warning).remileHelp("Your work is saved on this Mac. Unlock the saved connection to check Overleaf changes.") }
            else if offline { Label(library.pendingFiles.contains(connection.id) ? "Changes saved locally" : "Offline", systemImage: "cloud.slash").foregroundStyle(RemileStyle.warning).remileHelp("Your work stays on this Mac. Check changes when you reconnect.") }
            else if library.statuses[connection.id] == .conflict { Label("Conflicting edits", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).remileHelp("Overlapping edits need your choice before syncing.") }
            else if library.statuses[connection.id] == .changes || library.pendingFiles.contains(connection.id) { Label("Changes to review", systemImage: "circle.fill").foregroundStyle(RemileStyle.warning).remileHelp("Review local and Overleaf changes before applying or publishing.") }
            else if let date = library.syncedAt[connection.id] {
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Label(OverleafLibrary.syncAge(date, now: tick.date), systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).remileHelp("Last matched: " + date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Toggle(isOn: $library.offlineMode) { Image(systemName: "cloud.slash") }.toggleStyle(.button).remileHelp("Work offline · pause remote requests").disabled(library.busy)
            if OverleafCredential.locked(connection.profileID) { Button("Unlock") { Task { await library.unlock(connection) } }.disabled(library.busy).remileHelp("Allow this app to use the saved Git connection in Keychain") }
            Button("Check changes") { guard project.save() else { return }; Task { await library.check(connection) } }.disabled(library.offlineMode || library.busy || project.compiling)
            Button { library.commentsProject = connection } label: { Image(systemName: "text.bubble") }.remileHelp("Comments and export").disabled(library.offlineMode || library.busy)
            Button { library.openLibrary() } label: { Image(systemName: "books.vertical") }.remileHelp("Overleaf library").disabled(library.busy)
        }.font(RemileType.caption).padding(.horizontal, 16).padding(.vertical, 8).background(RemileStyle.editorBar)
            .task(id: connection.id) {
                while !Task.isCancelled {
                    if library.pendingFiles.contains(connection.id), !library.offlineMode, library.hasNetwork, !library.busy, !project.compiling, library.review == nil, project.save() { await library.check(connection) }
                    else { await library.probe(connection) }; do { try await Task.sleep(for: .seconds(30)) } catch { return } }
            }
            .onChange(of: project.fileRevision) { _, _ in library.pendingFiles.insert(connection.id) }
            .task(id: project.fileRevision) {
                guard project.fileRevision > 0 else { return }
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                guard !Task.isCancelled, !library.busy, library.review == nil, !library.offlineMode, library.hasNetwork, !project.compiling, project.save() else { return }
                await library.check(connection)
            }
    }
}

struct OverleafComparison: View {
    @ObservedObject var library: OverleafLibrary
    let review: OverleafGit.Review
    let reload: (URL) -> Void
    @StateObject private var state = State()
    @MainActor private final class State: ObservableObject { let width = min(820, max(540, (NSApp.keyWindow?.contentView?.bounds.width ?? 868) - 48)); @Published var path: String?; @Published var choices: [String: Bool] = [:]; @Published var combined = false }
    private var selected: OverleafGit.Change? { review.changes.first { $0.path == state.path } ?? review.changes.first }
    private var unresolved: Bool { review.changes.contains { $0.conflict && state.choices[$0.path] == nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Compare changes").font(RemileType.heading); Spacer(); Text(review.connection.name).foregroundStyle(.secondary) }
            if review.changes.isEmpty { Label("Everything matches", systemImage: "checkmark.circle.fill").foregroundStyle(RemileStyle.success).padding(.vertical, 24) }
            else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(review.changes) { change in
                        Button { state.path = change.path } label: { HStack { Text(change.path).lineLimit(2); Spacer(); if change.conflict { Image(systemName: state.choices[change.path] == nil ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(.red) } }.padding(7).frame(maxWidth: .infinity, alignment: .leading).background(selected?.path == change.path ? RemileStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                    } } }.frame(width: 160)
                    if let selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Combined preview", isOn: $state.combined).toggleStyle(.button).font(RemileType.caption)
                            if state.combined {
                                sourceColumn("Combined", selected.conflict ? (state.choices[selected.path].map { $0 ? selected.local : selected.remote } ?? selected.result) : selected.result).frame(height: 210)
                            } else {
                                HStack(spacing: 12) { sourceColumn("Local", selected.local, other: selected.remote); sourceColumn("Overleaf", selected.remote, other: selected.local) }.frame(height: 210)
                            }
                            if selected.conflict {
                                Text("Overlapping edits. Choose the version to keep.").font(RemileType.caption)
                                HStack { Button("Keep local") { state.choices[selected.path] = true }; Button("Use Overleaf") { state.choices[selected.path] = false }; if let local = state.choices[selected.path] { Label(local ? "Local selected" : "Overleaf selected", systemImage: "checkmark").font(RemileType.caption) } }
                            } else { Label("Changes combine safely", systemImage: "checkmark.circle.fill").font(RemileType.caption).foregroundStyle(RemileStyle.success) }
                        }
                    }
                }.frame(height: 320)
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
        }.padding(24).frame(width: state.width).background(RemileStyle.background).interactiveDismissDisabled(library.busy)
    }
    private func sourceColumn(_ title: String, _ text: String, other: String? = nil) -> some View {
        let lines = Array(text.components(separatedBy: "\n").prefix(2000))
        let compared = other.map { Array($0.components(separatedBy: "\n").prefix(2000)) }
        let changed = Set(compared?.difference(from: lines).compactMap { change -> Int? in if case .remove(let offset, _, _) = change { return offset }; return nil } ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(RemileType.callout.weight(.semibold))
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) { Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing); Text(line.isEmpty ? " " : line).textSelection(.enabled) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2).background(changed.contains(index) ? (title == "Local" ? RemileStyle.warning : RemileStyle.success).opacity(0.17) : .clear)
                    }
                    if text.components(separatedBy: "\n").count > 2000 { Text("First 2,000 lines shown").foregroundStyle(.secondary) }
                }.font(.system(size: 12, design: .monospaced)).padding(8)
            }.background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
        }.frame(maxWidth: .infinity)
    }
    private func finish(_ publish: Bool) { Task { await library.finish(choices: state.choices, publish: publish, reload: reload) } }
}
