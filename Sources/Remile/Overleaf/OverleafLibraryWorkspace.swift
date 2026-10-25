import SwiftUI

/// Browse saved local projects separately from the account/import flow.
struct OverleafLibraryWorkspace: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var query = ""
        @Published var selectedTag = "all"
        @Published var accountID: UUID?
        @Published var refreshing = false
        @Published var managingAccounts = false
        @Published var signIn = false
        @Published var removing: OverleafConnection?
    }
    @AppStorage("overleaf.library.sort") private var sort = "Manual"

    private var accountProjects: [OverleafConnection] { library.projects.filter { state.accountID == nil || $0.profileID == state.accountID } }
    private func untagged(_ project: OverleafConnection) -> Bool { library.tags[project.id]?.isEmpty == true && !library.unavailableTags.contains(project.id) }
    private var tags: [OverleafWebClient.Tag] {
        var unique: [String: OverleafWebClient.Tag] = [:]
        for project in accountProjects { for tag in library.tags[project.id] ?? [] { unique[tag.id] = tag } }
        return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var projects: [OverleafConnection] {
        let result = accountProjects.filter { project in
            let labels = library.tags[project.id] ?? []
            let matchesTag = state.selectedTag == "all" || (state.selectedTag == "untagged" ? untagged(project) : (state.selectedTag == "unknown" ? library.tags[project.id] == nil || library.unavailableTags.contains(project.id) : labels.contains { $0.id == state.selectedTag }))
            return matchesTag && (state.query.isEmpty || ([project.name, project.account] + labels.map(\.name)).contains { $0.localizedCaseInsensitiveContains(state.query) })
        }
        if sort == "Name" { return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if sort == "Account" { return result.sorted { ($0.account + " " + $0.name).localizedStandardCompare($1.account + " " + $1.name) == .orderedAscending } }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(compact: false)
                header(compact: true)
            }.padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            ReaderSplit(sizing: .sidebar, minimum: ReaderSidebar.minimum, maximum: ReaderSidebar.maximum, minimumContent: 320, label: "Overleaf tags", pane: { tagList }, content: { projectList })
        }.frame(maxWidth: .infinity, maxHeight: .infinity).font(RemileType.control).background(RemileStyle.background)
            .navigationTitle("Overleaf library")
            .sheet(isPresented: $state.managingAccounts) { OverleafAccountManager(library: library, selected: state.accountID, prepareRemoval: prepareRemoval) { state.managingAccounts = false } }
            .onChange(of: library.accounts.map(\.id)) { if !library.accounts.contains(where: { $0.id == state.accountID }) { state.accountID = nil } }
            .sheet(isPresented: $state.signIn, onDismiss: { Task { await refresh() } }) {
                if let profile = library.tagSignInProfile { OverleafSignIn(profile: profile) { state.signIn = false } }
            }
            .task { if !library.offlineMode && !NetworkAccess.offline && library.hasNetwork { await refresh() } }
            .onChange(of: state.accountID) { state.selectedTag = "all" }
            .onChange(of: tags.map(\.id)) { if state.selectedTag != "all" && state.selectedTag != "untagged" && state.selectedTag != "unknown" && !tags.contains(where: { $0.id == state.selectedTag }) { state.selectedTag = "all" } }
            .confirmationDialog("Remove from local library?", isPresented: Binding(get: { state.removing != nil }, set: { if !$0 { state.removing = nil } }), titleVisibility: .visible) {
                Button("Move local copy to Trash", role: .destructive) {
                    if let project = state.removing, prepareRemoval(library.root(project)) { library.remove(project) }
                    state.removing = nil
                }
            } message: { Text("The local project, including unpublished edits, moves to Trash. The online project stays in place.") }
    }
    private func header(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Button { library.browsing = false } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back").remileHelp("Return to workspace")
            Text("Overleaf library").font(RemileType.heading).fixedSize()
            Spacer(minLength: 8)
            Button { Task { await refresh() } } label: {
                if state.refreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.disabled(state.refreshing || library.offlineMode || NetworkAccess.offline).accessibilityLabel("Refresh project tags").remileHelp("Refresh Overleaf tags")
            Button { library.openLibrary(add: true) } label: {
                if compact { Image(systemName: "plus") } else { Label("Add projects", systemImage: "plus") }
            }.disabled(library.busy).accessibilityLabel("Add Overleaf projects")
        }.buttonStyle(RemileToolStyle())
    }
    private var tagList: some View {
        VStack(spacing: 0) {
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
                Menu {
                        Button("All accounts") { state.accountID = nil }
                        ForEach(library.accounts) { account in Button(account.name) { state.accountID = account.id } }
                        Divider()
                        Button("Manage accounts…") { state.managingAccounts = true }
                    } label: { Text(library.accounts.first(where: { $0.id == state.accountID })?.name ?? "Accounts").lineLimit(1) }
                    .menuStyle(.borderlessButton).font(RemileType.small).fixedSize()
                    .padding(.horizontal, 10).padding(.bottom, 10).accessibilityLabel("Account filter and management")
                tagButton("All projects", id: "all", count: accountProjects.count)
                Text("Tags").font(RemileType.caption.weight(.semibold)).foregroundStyle(RemileStyle.secondaryInk).padding(.top, 18).padding(.horizontal, 10)
                ForEach(tags) { tag in
                    tagButton(tag.name, id: tag.id, count: accountProjects.filter { library.tags[$0.id]?.contains(where: { $0.id == tag.id }) == true }.count, color: OverleafTagMark.tint(tag.color))
                }
                tagButton("Untagged", id: "untagged", count: accountProjects.filter(untagged).count)
                let unknown = accountProjects.filter { library.tags[$0.id] == nil || library.unavailableTags.contains($0.id) }.count
                if unknown > 0 { tagButton("Tags unavailable", id: "unknown", count: unknown) }
              }.padding(12).scrollContentGutter()
            }
            Divider()
            EditorSidebarBrand(compact: false).padding(12).fixedSize(horizontal: false, vertical: true)
        }.background(RemileStyle.sidebar)
    }
    private func tagButton(_ name: String, id: String, count: Int, color: Color? = nil) -> some View {
        Button { state.selectedTag = id } label: {
            HStack(spacing: 8) {
                if let color { Capsule().fill(color).frame(width: 3, height: 18) }
                Text(name).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            }.padding(10).contentShape(Rectangle()).background(state.selectedTag == id ? RemileStyle.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityValue(state.selectedTag == id ? "Selected" : "")
    }
    private var projectList: some View {
        GeometryReader { geometry in
            let visible = projects
            let columns = max(1, min(visible.count, min(4, Int(max(0, geometry.size.width - 38) / 270))))
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Find a project", text: $state.query).textFieldStyle(.roundedBorder)
                    Text("Sort").fixedSize()
                    Picker("Sort", selection: $sort) { Text("Manual").tag("Manual"); Text("Name").tag("Name"); Text("Account").tag("Account") }.labelsHidden().frame(width: 108).padding(.trailing, -8)
                }
                if let error = library.error ?? library.tagError {
                    HStack {
                        Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled)
                        Spacer(minLength: 8)
                        if library.tagSignInProfile != nil { Button("Connect Overleaf") { state.signIn = true } }
                    }
                }
                if visible.isEmpty {
                    ContentUnavailableView(library.projects.isEmpty ? "No saved projects" : "No matching projects", systemImage: "books.vertical", description: Text(library.projects.isEmpty ? "Use Add projects to bring an Overleaf project here." : "Choose another account, tag or search term."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, project in
                                card(project)
                                    .draggable("remile-overleaf-project:" + project.id.uuidString)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let item = items.first, item.hasPrefix("remile-overleaf-project:"), let id = UUID(uuidString: String(item.dropFirst(24))) else { return false }
                                        sort = "Manual"; return library.moveProject(id, before: project.id)
                                    }
                                    .contextMenu {
                                        Button("Open") { openProject(project) }
                                        OverleafProjectIDButton(project: project)
                                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root(project)]) }
                                        Divider()
                                        Button("Move earlier") { sort = "Manual"; _ = library.moveProject(project.id, before: visible[index - 1].id) }.disabled(index == 0)
                                        Button("Move later") { sort = "Manual"; _ = library.moveProject(project.id, before: index + 2 < visible.count ? visible[index + 2].id : nil) }.disabled(index == visible.count - 1)
                                        Divider()
                                        Button("Remove from library…", role: .destructive) { state.removing = project }.disabled(library.busy)
                                    }
                            }
                        }.padding(.bottom, 12).scrollContentGutter()
                    }.smoothScrolling()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(20)
        }
    }
    private func card(_ project: OverleafConnection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            OverleafTagMark(tags: library.tags[project.id] ?? [])
            Button { openProject(project) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name).font(RemileType.heading).lineLimit(2)
                    Text(project.account).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                    if let tags = library.tags[project.id], !tags.isEmpty { Text(tags.map(\.name).joined(separator: " · ")).font(RemileType.small).foregroundStyle(RemileStyle.secondaryInk).lineLimit(1) }
                }.frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(library.busy)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.card))
    }
    private func openProject(_ project: OverleafConnection) { library.browsing = false; open(library.root(project)) }
    private func refresh() async {
        guard !state.refreshing else { return }; state.refreshing = true
        await library.refreshProjectTags()
        state.refreshing = false
    }
}
