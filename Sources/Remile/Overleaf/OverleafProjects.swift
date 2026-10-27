import SwiftUI

/// Import projects here. Account preferences and credentials stay in the shared account window.
struct OverleafProjects: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    @StateObject private var state: State
    init(library: OverleafLibrary, open: @escaping (URL) -> Void, prepareRemoval: @escaping (URL) -> Bool) {
        self.library = library; self.open = open; self.prepareRemoval = prepareRemoval
        let initial = State(); initial.panelSize = library.importSize; initial.accountID = library.accounts.first?.id
        _state = StateObject(wrappedValue: initial)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class State: ObservableObject {
        @Published var panelSize = CGSize(width: 986, height: 600)
        @Published var accountID: UUID?
        @Published var managingAccounts = false
        @Published var signIn = false
        @Published var loading = false
        var loadID = UUID()
        @Published var needsConnection = false
        @Published var pendingProject: (profile: UUID, id: String, name: String)?
        @Published var catalog: [OverleafWebClient.Project] = []
        @Published var query = ""
        @Published var pane = "Available"
        @Published var selected: String?
        @Published var url = ""
        @Published var name = ""
        @Published var link = false
        @Published var error: String?
        @Published var removing: OverleafConnection?
    }
    private var account: OverleafLibrary.Account? { library.accounts.first { $0.id == state.accountID } }
    private var available: [OverleafWebClient.Project] {
        state.catalog.filter { item in !library.projects.contains { $0.projectID == item.id && $0.profileID == account?.id } && (state.query.isEmpty || item.name.localizedCaseInsensitiveContains(state.query)) }
    }
    private var local: [OverleafConnection] { library.projects.filter { $0.profileID == account?.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Overleaf projects").font(RemileType.heading)
                Spacer()
                if library.busy || state.loading { ProgressView().controlSize(.small) }
                Button("Close") { library.presented = false }.keyboardShortcut(.cancelAction).disabled(library.busy)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { accountControls; Spacer(); connectionControls }
                VStack(alignment: .leading, spacing: 12) { accountControls; HStack { Spacer(); connectionControls } }
            }
            Divider()
            if state.panelSize.width < 640 {
                RemileSegmentedControl(title: "Project list", selection: $state.pane, options: ["Available", "Local library"], label: { $0 })
                if state.pane == "Available" { availablePane } else { localPane }
            } else {
                HStack(alignment: .top, spacing: 24) { availablePane; localPane }.frame(maxHeight: .infinity)
            }
            Divider()
            DisclosureGroup("Add by link", isExpanded: $state.link) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { linkFields }
                    VStack(alignment: .leading, spacing: 12) { linkFields }
                }.padding(.leading, 18).padding(.top, 12)
            }
            if let error = library.error ?? state.error { Text(error).font(RemileType.small).foregroundStyle(RemileStyle.warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }.padding(24).font(RemileType.control).buttonStyle(RemileActionStyle()).controlSize(.regular)
            .frame(width: state.panelSize.width, height: state.panelSize.height).background(RemileStyle.background)
            .interactiveDismissDisabled(library.busy)
            .background(OverleafImportSizing { size in var transaction = Transaction(); transaction.disablesAnimations = true; withTransaction(transaction) { state.panelSize = size } }.frame(width: 0, height: 0))
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.link)
            .task(id: state.accountID) {
                state.loadID = UUID(); state.catalog = []; state.selected = nil; state.pendingProject = nil; state.error = nil; state.needsConnection = false
                if account != nil && !state.signIn { await load() } else { state.loading = false }
            }
            .sheet(isPresented: $state.managingAccounts, onDismiss: accountsClosed) {
                OverleafAccountManager(library: library, selected: state.accountID, requestGitToken: state.pendingProject != nil, prepareRemoval: prepareRemoval) { state.managingAccounts = false }
            }
            .sheet(isPresented: $state.signIn, onDismiss: { Task { await load() } }) { if let account { OverleafSignIn(profile: account.id) { state.signIn = false } } }
            .confirmationDialog("Remove from local library?", isPresented: Binding(get: { state.removing != nil }, set: { if !$0 { state.removing = nil } }), titleVisibility: .visible) {
                Button("Move local copy to Trash", role: .destructive) { if let project = state.removing, prepareRemoval(library.root(project)) { library.remove(project) }; state.removing = nil }
            } message: { Text("Unpublished local edits move to Trash with the cache. The online project and saved account stay in place.") }
    }
    private var availablePane: some View {
        VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Available projects", count: available.count)
                    TextField("Find a project", text: $state.query).textFieldStyle(.roundedBorder)
                    if available.isEmpty { emptyCatalog }
                    else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(available) { item in
                                    Button { add(id: item.id, name: item.name) } label: {
                                        HStack(spacing: 10) {
                                            OverleafTagMark(tags: item.tags)
                                            Text(item.name).multilineTextAlignment(.leading).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            if library.busy && state.selected == item.id { ProgressView().controlSize(.small) }
                                            else { SymbolIcon(systemName: "plus.circle").foregroundStyle(RemileStyle.accent) }
                                        }.padding(10).frame(minHeight: 40).contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(library.busy || account == nil)
                                        .background(state.selected == item.id ? RemileStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                                        .accessibilityLabel("Add " + item.name + " to local library").remileHelp("Add to local library")
                                }
                            }.scrollContentGutter()
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var localPane: some View {
        VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Local library", count: local.count)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(local) { project in
                                HStack(spacing: 10) {
                                    OverleafTagMark(tags: library.tags[project.id] ?? [])
                                    Button { library.presented = false; library.browsing = false; open(library.root(project)) } label: {
                                        Text(project.name).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain).remileHelp("Open project")
                                    Button { state.removing = project } label: { SymbolIcon(systemName: "trash") }
                                        .buttonStyle(RemileCompactToolStyle()).remileHelp("Remove from local library").accessibilityLabel("Remove " + project.name + " from local library").disabled(library.busy)
                                }.padding(10).frame(minHeight: 40).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                            }
                            if local.isEmpty { Text("Add a project from the list.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        }.scrollContentGutter()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var accountControls: some View {
        HStack(spacing: 12) {
            Text("Account")
            Menu {
                ForEach(library.accounts) { account in Button(account.name) { state.accountID = account.id } }
            } label: {
                HStack(spacing: 8) { Text(account?.name ?? "Choose account").lineLimit(1); Spacer(minLength: 0); SymbolIcon(systemName: "chevron.down") }.frame(width: 160)
            }.menuStyle(.borderlessButton).tint(RemileStyle.ink).menuIndicator(.hidden).buttonStyle(RemileActionStyle()).disabled(library.accounts.isEmpty || library.busy)
                .accessibilityLabel("Account").accessibilityValue(account?.name ?? "None")
            Button(library.accounts.isEmpty ? "Add account…" : "Manage…") { state.managingAccounts = true }.disabled(library.busy)
        }
    }
    private var connectionControls: some View {
        HStack(spacing: 8) {
            Button { Task { await load() } } label: { SymbolIcon(systemName: "arrow.clockwise") }
                .accessibilityLabel("Refresh projects").remileHelp("Refresh available projects").disabled(account == nil || state.loading || library.busy)
        }
    }
    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack { Text(title).font(RemileType.section); Spacer(); Text("\(count)").font(RemileType.small).foregroundStyle(.secondary).monospacedDigit() }
    }
    private var emptyCatalog: some View {
        VStack(spacing: 12) {
            if state.loading { ProgressView().controlSize(.small) }
            else { SymbolIcon(systemName: "books.vertical", slot: RemileSymbol.emptySlot).font(.system(size: RemileSymbol.emptySize)).foregroundStyle(RemileStyle.secondaryInk) }
            Text(state.loading ? "Loading projects…" : (state.catalog.isEmpty ? (account == nil ? "Add an account to browse projects." : "Connect Overleaf to browse projects.") : (state.query.isEmpty ? "All projects are in your library." : "No matching projects.")))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if state.needsConnection { Button("Sign in…") { state.signIn = true } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
    }
    @ViewBuilder private var linkFields: some View {
        TextField("Overleaf project link", text: $state.url).textFieldStyle(.roundedBorder)
        TextField("Name", text: $state.name).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
        Button("Add") { if let id = OverleafConnection.projectID(state.url) { add(id: id, name: state.name) } }.disabled(library.busy || account == nil || OverleafConnection.projectID(state.url) == nil)
    }
    private func accountsClosed() {
        if !library.accounts.contains(where: { $0.id == state.accountID }) { state.accountID = library.accounts.first?.id }
        let pending = state.pendingProject; state.pendingProject = nil
        if let pending, let account, pending.profile == account.id,
           !account.allowsGit || OverleafCredential.availability(account.id) == .available {
            add(id: pending.id, name: pending.name)
        } else { Task { await load() } }
    }
    private func load() async {
        guard let account else { return }; state.loading = true; state.error = nil
        let loadID = UUID(); state.loadID = loadID
        defer { if state.loadID == loadID { state.loading = false } }
        do { let catalog = try await OverleafWebClient.projects(account.id); if !Task.isCancelled, state.loadID == loadID, state.accountID == account.id { state.catalog = catalog; state.needsConnection = false; library.rememberTags(catalog, profile: account.id); if catalog.contains(where: { !$0.tagsLoaded }) { state.error = "Could not refresh tags. Saved tags are shown." } } }
        catch {
            guard !Task.isCancelled, state.loadID == loadID, state.accountID == account.id else { return }
            state.needsConnection = (error as? OverleafWebClient.Failure)?.needsConnection == true
            state.error = state.needsConnection ? nil : error.localizedDescription
        }
    }
    private func add(id: String, name: String) {
        guard let account, !library.busy else { return }
        library.error = nil; state.error = nil; state.selected = id
        if account.allowsGit && OverleafCredential.availability(account.id) == .missing {
            state.pendingProject = (account.id, id, name); state.managingAccounts = true
            state.error = "Save a Git token in account settings to add this project."; return
        }
        Task { await library.connect(url: "https://www.overleaf.com/project/" + id, name: name, account: account.name, token: ""); if library.error == nil { library.rememberTags(state.catalog, profile: account.id); state.url = ""; state.name = ""; state.selected = nil } }
    }
}
