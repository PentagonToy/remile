import SwiftUI

/// The account list is fetched on demand. Selected projects still connect through Git.
struct OverleafProjects: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    @State private var accountID: UUID?
    @State private var url = ""
    @State private var name = ""
    @State private var accounts = false
    @State private var signIn = false
    @State private var refreshAfterSignIn = false
    @State private var catalogue: [OverleafWebClient.Project] = []
    @State private var catalogueProfile: UUID?
    @State private var query = ""
    @State private var selected: String?
    @State private var loading = false
    @State private var needsConnection = false
    @State private var issue: String?
    @State private var revision = 0
    @State private var byLink = false
    @State private var expandedGroups = Set<Group.ID>()
    @State private var presentation = CataloguePresentation()
    @ObservedObject private var network = NetworkAccessState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var account: OverleafLibrary.Account? { library.accounts.first { $0.id == accountID } ?? library.accounts.first }
    private var online: Bool { !network.offline && library.hasNetwork }
    private var loadKey: CatalogueLoad { .init(profile: account?.id, revision: revision, online: online) }
    @State private var completedLoad: CatalogueLoad?
    private var visibleCatalogue: [OverleafWebClient.Project] {
        catalogueProfile == account?.id ? catalogue : []
    }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: CataloguePresentation.Results {
        presentation.results(for: visibleCatalogue, profile: account?.id, connected: library.projects, query: searchText)
    }
    var body: some View {
        let results = self.results
        let projects = results.projects
        let selection = projects.first { $0.id == selected }
        return VStack(alignment: .leading, spacing: RemileControl.spacing * 2) {
            HStack {
                Text("Add Overleaf project").font(RemileType.heading)
                Spacer()
                Button("Done") { library.presented = false }.keyboardShortcut(.cancelAction).disabled(library.busy)
            }
            HStack {
                Picker("Account", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                    ForEach(library.accounts) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(library.accounts.isEmpty ? "Add account…" : "Git token…") { accounts = true }
                Spacer()
                Button { revision += 1 } label: {
                    if loading && !visibleCatalogue.isEmpty { ProgressView().controlSize(.small) }
                    else { SymbolIcon(systemName: "arrow.clockwise") }
                }
                    .buttonStyle(.plain).frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                    .accessibilityLabel("Refresh projects").remileHelp("Refresh projects")
                    .disabled(!online || loading || account == nil)
            }.disabled(library.busy)
            TextField("Find a project or tag", text: $query).textFieldStyle(.roundedBorder).disabled(library.busy)
                .onSubmit { if !searchText.isEmpty, let first = projects.first { selected = first.id; byLink = false } }
            projectList(results)
            if !online && !visibleCatalogue.isEmpty {
                Text("Offline · showing previously loaded projects.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            } else if online && needsConnection && !visibleCatalogue.isEmpty {
                HStack {
                    Text("Sign in to refresh projects.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                    Spacer()
                    Button("Sign in…") { signIn = true }.disabled(library.busy)
                }
            } else if online, let issue, !needsConnection {
                Text(issue).font(RemileType.caption).foregroundStyle(RemileStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Add by link", isExpanded: $byLink) {
                VStack(spacing: RemileControl.spacing) {
                    TextField("Overleaf project or Git link", text: $url).textFieldStyle(.roundedBorder)
                    TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        ExternalLink("Open Overleaf", destination: URL(string: "https://www.overleaf.com/project")!)
                        Spacer()
                    }
                }.padding(.top, RemileControl.spacing)
            }.disabled(library.busy)
            if let error = library.error {
                Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled)
            }
            HStack {
                if !byLink, let project = selection {
                    Text(project.name).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                        .lineLimit(1).truncationMode(.middle).remileHelp(project.name)
                        .accessibilityLabel("Selected project: " + project.name)
                }
                Spacer(minLength: RemileControl.spacing)
                if library.busy { ProgressView().controlSize(.small) }
                Button("Add project", action: add)
                    .buttonStyle(RemileActionStyle(emphasis: .primary))
                    .disabled(!online || library.busy || account == nil || (byLink ? OverleafConnection.projectID(url) == nil : selection == nil))
            }
        }.padding(RemileControl.spacing * 3).frame(width: 540).font(RemileType.control).buttonStyle(RemileActionStyle())
            .background(RemileStyle.background).interactiveDismissDisabled(library.busy)
            .task(id: loadKey) { [key = loadKey] in
                if key.profile != nil && !network.offline { library.watchReachability() }
                await load(key)
            }
            .onChange(of: selected) { _ in library.error = nil }
            .sheet(isPresented: $accounts) {
                OverleafAccountManager(library: library, selected: account?.id, requestGitToken: true, prepareRemoval: prepareRemoval) { accounts = false }
            }
            .sheet(isPresented: $signIn, onDismiss: {
                if refreshAfterSignIn {
                    refreshAfterSignIn = false
                    revision += 1
                }
            }) {
                if let account {
                    OverleafSignIn(profile: account.id, catalogue: true, onConnected: { refreshAfterSignIn = true }) {
                        signIn = false
                    }
                }
            }
    }
    private func projectList(_ results: CataloguePresentation.Results) -> some View {
        ScrollView {
            LazyVStack(spacing: RemileControl.spacing / 2) {
                if !results.groups.isEmpty {
                    ForEach(results.groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedGroups.contains(group.id) },
                            set: { expanded in
                                if expanded { expandedGroups.insert(group.id) }
                                else { expandedGroups.remove(group.id) }
                            }
                        )) {
                            LazyVStack(spacing: RemileControl.spacing / 2) {
                                ForEach(group.projects) { item in projectRow(item) }
                            }
                        } label: {
                            HStack(spacing: RemileControl.spacing) {
                                if let tag = group.tag {
                                    Capsule().fill(OverleafTagMark.tint(tag.color))
                                        .frame(width: RemileControl.spacing / 2, height: RemileControl.iconSlot)
                                        .accessibilityHidden(true)
                                }
                                Text(group.tag?.name ?? "Untagged").lineLimit(1)
                                Spacer()
                                Text(group.projects.count.formatted()).foregroundStyle(RemileStyle.secondaryInk)
                            }.frame(minHeight: RemileControl.toolHit)
                        }.disabled(library.busy)
                    }
                } else {
                    ForEach(results.projects) { item in projectRow(item) }
                }
            }.padding(.trailing, 18)
        }.frame(height: 240)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: expandedGroups)
            .overlay {
                if !online && account != nil && visibleCatalogue.isEmpty {
                    Text("Projects are unavailable offline.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                } else if loading && visibleCatalogue.isEmpty { ProgressView("Loading projects…") }
                else if needsConnection && visibleCatalogue.isEmpty {
                    VStack(spacing: RemileControl.spacing) {
                        Text("Sign in to see your projects.").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                        Button("Sign in…") { signIn = true }.disabled(library.busy)
                    }
                } else if results.projects.isEmpty {
                    Text(account == nil ? "Add an account to choose a project." :
                            !searchText.isEmpty ? "No matching projects" : "No projects to add")
                        .font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                }
            }
    }
    private func projectRow(_ item: OverleafWebClient.Project) -> some View {
        HStack(spacing: RemileControl.spacing) {
            OverleafTagMark(tags: item.tags).frame(width: RemileControl.toolHit)
            Button { selected = item.id; byLink = false } label: {
                HStack(spacing: RemileControl.spacing) {
                    Text(item.name).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if selected == item.id { SymbolIcon(systemName: "checkmark").foregroundStyle(RemileStyle.accent) }
                }.frame(minHeight: RemileControl.toolHit).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selected == item.id ? .isSelected : [])
        }.padding(RemileControl.spacing).disabled(library.busy)
            .background(selected == item.id ? RemileStyle.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: RemileRadius.control))
    }
    private func load(_ key: CatalogueLoad) async {
        guard key == loadKey, !Task.isCancelled else { return }
        if catalogueProfile != key.profile {
            catalogue = []; selected = nil; expandedGroups = []; catalogueProfile = key.profile
            completedLoad = nil
        }
        guard key.shouldFetch(after: completedLoad), let profile = key.profile else { loading = false; return }
        issue = nil; needsConnection = false
        loading = true
        defer { if key == loadKey, !Task.isCancelled { loading = false } }
        do {
            let projects = try await OverleafWebClient.projects(profile, onList: { listed in
                guard key == loadKey, !Task.isCancelled else { return }
                catalogue = Self.retainingTags(listed, previous: catalogue)
                if !catalogue.contains(where: { $0.id == selected }) { selected = nil }
            })
            try Task.checkCancellation()
            guard key == loadKey else { return }
            if projects.first?.tagsLoaded == true {
                if let project = projects.first(where: { $0.id == selected }) {
                    let groups: [Group.ID] = project.tags.isEmpty ? [.untagged] : project.tags.map { .tag($0.id) }
                    if let first = groups.first, !groups.contains(where: expandedGroups.contains) {
                        expandedGroups.insert(first)
                    }
                }
                catalogue = projects
            }
            completedLoad = key
            library.rememberTags(projects, profile: profile)
        } catch {
            guard key == loadKey, !Task.isCancelled else { return }
            needsConnection = (error as? OverleafWebClient.Failure)?.needsConnection == true
            issue = needsConnection ? "Connect your Overleaf account to choose a project." : error.localizedDescription
        }
    }
    private func add() {
        guard online, let account, !library.busy else { return }
        guard OverleafCredential.availability(account.id) != .missing else { accounts = true; return }
        let item = results.projects.first { $0.id == selected }
        guard byLink || item != nil else { return }
        let projectURL = byLink ? url : item.map { "https://www.overleaf.com/project/" + $0.id } ?? ""
        let projectName = byLink ? name : item?.name ?? ""
        Task {
            await library.connect(url: projectURL, name: projectName, account: account.name, token: "")
            if library.error == nil {
                if !loading { library.rememberTags(catalogue, profile: account.id) }
                library.presented = false
                library.browsing = true
            }
        }
    }
}

// Groups hold lightweight catalogue values, not project files or downloaded contents.
extension OverleafProjects {
    @MainActor final class CataloguePresentation {
        struct Results {
            let projects: [OverleafWebClient.Project]
            let groups: [Group]
        }

        private struct Input: Equatable {
            let catalogue: [OverleafWebClient.Project]
            let profile: UUID?
            let connected: [OverleafConnection]
            let query: String
        }

        private var cached: (Input, Results)?

        func results(for catalogue: [OverleafWebClient.Project], profile: UUID?,
                     connected: [OverleafConnection], query: String) -> Results {
            let input = Input(catalogue: catalogue, profile: profile, connected: connected, query: query)
            if let cached, cached.0 == input { return cached.1 }
            let existing = Set(connected.lazy.filter { $0.profileID == profile }.map(\.projectID))
            let projects = catalogue.filter { !existing.contains($0.id) && OverleafProjects.matches($0, query: query) }
            let groups = query.isEmpty && projects.contains { !$0.tags.isEmpty } ? OverleafProjects.grouped(projects) : []
            let results = Results(projects: projects, groups: groups)
            cached = (input, results)
            return results
        }
    }

    struct CatalogueLoad: Equatable {
        let profile: UUID?
        let revision: Int
        let online: Bool

        func shouldFetch(after completed: Self?) -> Bool {
            online && profile != nil && completed != self
        }
    }

    struct Group: Identifiable {
        enum ID: Hashable { case tag(String), untagged }
        let tag: OverleafWebClient.Tag?
        var projects: [OverleafWebClient.Project] = []
        var id: ID { tag.map { .tag($0.id) } ?? .untagged }
    }
    nonisolated static func matches(_ project: OverleafWebClient.Project, query: String) -> Bool {
        query.isEmpty || project.name.localizedCaseInsensitiveContains(query)
            || project.tags.contains { $0.name.localizedCaseInsensitiveContains(query) }
    }
    nonisolated static func retainingTags(_ projects: [OverleafWebClient.Project], previous: [OverleafWebClient.Project]) -> [OverleafWebClient.Project] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.tags) })
        return projects.map { project in
            var value = project
            if !value.tagsLoaded { value.tags = old[value.id] ?? [] }
            return value
        }
    }
    nonisolated static func grouped(_ projects: [OverleafWebClient.Project]) -> [Group] {
        var tags: [String: Group] = [:]
        var untagged = Group(tag: nil)
        for project in projects {
            if project.tags.isEmpty { untagged.projects.append(project) }
            for tag in project.tags {
                tags[tag.id, default: Group(tag: tag)].projects.append(project)
            }
        }
        var groups = tags.values.sorted { left, right in
            let order = (left.tag?.name ?? "").localizedStandardCompare(right.tag?.name ?? "")
            return order == .orderedSame ? (left.tag?.id ?? "") < (right.tag?.id ?? "") : order == .orderedAscending
        }
        if !untagged.projects.isEmpty { groups.append(untagged) }
        return groups
    }
}
