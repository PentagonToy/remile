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
    @State private var catalogue: [OverleafWebClient.Project] = []
    @State private var query = ""
    @State private var selected: String?
    @State private var loading = false
    @State private var needsConnection = false
    @State private var issue: String?
    @State private var revision = 0
    @State private var byLink = false
    @State private var expandedGroups = Set<Group.ID>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var account: OverleafLibrary.Account? { library.accounts.first { $0.id == accountID } ?? library.accounts.first }
    private var loadKey: String { (account?.id.uuidString ?? "") + ":" + String(revision) }
    private var available: [OverleafWebClient.Project] {
        catalogue.filter { item in
            !library.projects.contains { $0.projectID == item.id && $0.profileID == account?.id }
                && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.spacing * 2) {
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
                Button { revision += 1 } label: { SymbolIcon(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                    .accessibilityLabel("Refresh projects").remileHelp("Refresh projects")
                    .disabled(loading || account == nil)
            }.disabled(library.busy)
            TextField("Find a project", text: $query).textFieldStyle(.roundedBorder).disabled(library.busy)
            projectList
            if let issue {
                HStack(alignment: .top) {
                    Text(issue).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                    Spacer()
                    if needsConnection { Button("Sign in…") { signIn = true }.disabled(library.busy) }
                }
            }
            DisclosureGroup("Add by link", isExpanded: $byLink) {
                VStack(spacing: RemileControl.spacing) {
                    TextField("Overleaf project or Git link", text: $url).textFieldStyle(.roundedBorder)
                    TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
                }.padding(.top, RemileControl.spacing)
            }.disabled(library.busy)
            if let error = library.error {
                Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled)
            }
            HStack {
                Link("Open Overleaf", destination: URL(string: "https://www.overleaf.com/project")!)
                Spacer()
                if library.busy { ProgressView().controlSize(.small) }
                Button("Add project", action: add)
                    .buttonStyle(RemileActionStyle(emphasis: .primary))
                    .disabled(library.busy || account == nil || (byLink ? OverleafConnection.projectID(url) == nil : selected == nil))
            }
        }.padding(24).frame(width: 540).font(RemileType.control).buttonStyle(RemileActionStyle())
            .background(RemileStyle.background).interactiveDismissDisabled(library.busy)
            .task(id: loadKey) { await load() }
            .sheet(isPresented: $accounts) {
                OverleafAccountManager(library: library, selected: account?.id, requestGitToken: true, prepareRemoval: prepareRemoval) { accounts = false }
            }
            .sheet(isPresented: $signIn, onDismiss: { revision += 1 }) {
                if let account { OverleafSignIn(profile: account.id, catalogue: true) { signIn = false } }
            }
    }
    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: RemileControl.spacing / 2) {
                if query.isEmpty {
                    ForEach(Self.grouped(available)) { group in
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
                    ForEach(available) { item in projectRow(item) }
                }
            }.padding(.trailing, 18)
        }.frame(height: 240)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: expandedGroups)
            .overlay {
                if loading { ProgressView("Loading projects…") }
                else if available.isEmpty {
                    Text(account == nil ? "Add an account to choose a project." :
                            needsConnection ? "Sign in to choose a project, or add by link." :
                            !query.isEmpty ? "No matching projects" : "No projects to add")
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
    private func load() async {
        catalogue = []; selected = nil; issue = nil; needsConnection = false
        guard let account else { loading = false; return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let projects = try await OverleafWebClient.projects(account.id)
            try Task.checkCancellation()
            catalogue = projects
            library.rememberTags(projects, profile: account.id)
        } catch {
            guard !Task.isCancelled else { return }
            needsConnection = (error as? OverleafWebClient.Failure)?.needsConnection == true
            issue = needsConnection ? "Connect your Overleaf account to choose a project." : error.localizedDescription
        }
    }
    private func add() {
        guard let account, !library.busy else { return }
        guard OverleafCredential.availability(account.id) != .missing else { accounts = true; return }
        let item = catalogue.first { $0.id == selected }
        let projectURL = byLink ? url : item.map { "https://www.overleaf.com/project/" + $0.id } ?? ""
        let projectName = byLink ? name : item?.name ?? ""
        Task {
            await library.connect(url: projectURL, name: projectName, account: account.name, token: "")
            if library.error == nil {
                library.rememberTags(catalogue, profile: account.id)
                library.presented = false
                library.browsing = true
            }
        }
    }
}

// Groups hold lightweight catalogue values, not project files or downloaded contents.
extension OverleafProjects {
    struct Group: Identifiable {
        enum ID: Hashable { case tag(String), untagged }
        let tag: OverleafWebClient.Tag?
        var projects: [OverleafWebClient.Project] = []
        var id: ID { tag.map { .tag($0.id) } ?? .untagged }
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
