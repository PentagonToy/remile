import SwiftUI

struct OverleafLocalCopies: View {
    @ObservedObject var library: OverleafLibrary
    @ObservedObject private var network = NetworkAccessState.shared
    @Environment(\.dismiss) private var dismiss
    let isOpen: (URL) -> Bool
    let didRemove: (URL) -> Void
    @State private var selection: Set<UUID>
    @State private var checking: String?
    @State private var attempted: [OverleafConnection] = []
    @State private var failures: [UUID: String]?

    init(library: OverleafLibrary, initialSelection: UUID?, isOpen: @escaping (URL) -> Bool, didRemove: @escaping (URL) -> Void) {
        self.library = library
        self.isOpen = isOpen
        self.didRemove = didRemove
        _selection = State(initialValue: initialSelection.map { [$0] } ?? [])
    }

    private var online: Bool { library.hasNetwork && !network.offline }

    var body: some View {
        let projects = library.projects
        let issues = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
            library.localCopyIssue(project, isOpen: isOpen).map { (project.id, $0) }
        })
        let available = Set(projects.map(\.id)).subtracting(issues.keys)
        let selected = projects.filter { selection.contains($0.id) && available.contains($0.id) }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: RemileControl.spacing) {
                Text("Free Up Space").font(RemileType.heading)
                Text(failures == nil
                     ? "Move local copies and their Git recovery history to Trash after checking sync. Your projects stay in Overleaf."
                     : failures?.count == attempted.count ? "Review the details below and try again."
                     : "Empty Trash to reclaim the space used by the local copies.")
                    .font(RemileType.small).foregroundStyle(RemileStyle.secondaryInk)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            if let failures {
                results(failures)
            } else {
                selectionList(projects, issues: issues, available: available)
            }
            Divider()
            footer(selected)
        }
        .frame(width: 470, height: 400)
        .font(RemileType.control).foregroundStyle(RemileStyle.ink).background(RemileStyle.background)
        .buttonStyle(RemileActionStyle())
        .interactiveDismissDisabled(checking != nil)
    }

    private func selectionList(_ projects: [OverleafConnection], issues: [UUID: String], available: Set<UUID>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let allSelected = available.isSubset(of: selection)
            HStack {
                Text("Local copies").font(RemileType.control.weight(.semibold))
                Spacer()
                if !available.isEmpty {
                    Button(allSelected ? "Deselect All" : "Select All") { selection = allSelected ? [] : available }
                        .buttonStyle(RemileActionStyle(emphasis: .quiet)).disabled(checking != nil)
                }
            }.padding(.horizontal, 20).padding(.vertical, RemileControl.spacing)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RemileControl.rowSpacing) {
                    ForEach(projects) { project in
                        Toggle(isOn: Binding(get: { issues[project.id] == nil && selection.contains(project.id) }, set: { selected in
                            if selected { selection.insert(project.id) }
                            else { selection.remove(project.id) }
                        })) {
                            projectLabel(project, detail: issues[project.id])
                        }.toggleStyle(.checkbox).disabled(issues[project.id] != nil || checking != nil)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12).scrollContentGutter()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.smoothScrolling()
        }
    }

    private func projectLabel(_ project: OverleafConnection, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.name).lineLimit(2)
            Text(project.account).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            if let detail { Text(detail).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk) }
        }.accessibilityElement(children: .combine)
    }

    private func results(_ failures: [UUID: String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RemileControl.rowSpacing) {
                let moved = attempted.count - failures.count
                Text("\(moved) moved to Trash").font(RemileType.control.weight(.semibold))
                if !failures.isEmpty {
                    Text("\(failures.count) kept on this Mac").font(RemileType.control.weight(.semibold))
                    ForEach(attempted) { project in
                        if let failure = failures[project.id] { projectLabel(project, detail: failure) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20).scrollContentGutter()
        }.smoothScrolling()
    }

    private func footer(_ selected: [OverleafConnection]) -> some View {
        HStack(spacing: RemileControl.spacing) {
            if let checking {
                ProgressView().controlSize(.small)
                Text("Checking \(checking)…").lineLimit(1).font(RemileType.caption)
            } else if failures == nil {
                Text(online ? "\(selected.count) selected" : "Connect to Overleaf to check sync.")
                    .font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            }
            Spacer(minLength: RemileControl.spacing)
            if failures != nil {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(checking != nil)
                Button("Move to Trash", role: .destructive) { move(selected) }
                    .disabled(selected.isEmpty || checking != nil || !online || library.busy)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func move(_ projects: [OverleafConnection]) {
        attempted = projects
        checking = projects.first?.name
        Task {
            failures = await library.freeSpace(projects, isOpen: isOpen, didRemove: didRemove) { project in
                checking = project.name
            }
            checking = nil
        }
    }
}
