import SwiftUI

struct OverleafProjects: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    @StateObject private var state = State()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class State: ObservableObject {
        @Published var accountID: UUID?
        @Published var accountName = "Personal"
        @Published var token = ""
        @Published var credentials = false
        @Published var signIn = false
        @Published var loading = false
        var loadID = UUID()
        @Published var needsConnection = false
        @Published var pendingProject: (id: String, name: String)?
        @Published var catalog: [OverleafWebClient.Project] = []
        @Published var query = ""
        @Published var selected: String?
        @Published var url = ""
        @Published var name = ""
        @Published var link = false
        @Published var error: String?
        @Published var removing: OverleafConnection?
    }
    private var account: OverleafLibrary.Account? { library.accounts.first { $0.id == state.accountID } }
    private var available: [OverleafWebClient.Project] { state.catalog.filter { item in !library.projects.contains { $0.projectID == item.id && $0.profileID == account?.id } && (state.query.isEmpty || item.name.localizedCaseInsensitiveContains(state.query)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Overleaf projects").font(RemileType.heading); Spacer()
                if library.busy || state.loading { ProgressView().controlSize(.small) }
                Button("Done") { library.presented = false }.keyboardShortcut(.cancelAction).disabled(library.busy)
            }
            HStack(spacing: 12) {
                Picker("Account", selection: $state.accountID) {
                    Text("Choose account").tag(UUID?.none)
                    ForEach(library.accounts) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 230)
                Button("Add account") { state.accountID = nil; state.accountName = ""; state.credentials = true }
                Button("Git token") { state.credentials.toggle() }.bubbleHelp(RemileHints.overleafToken).disabled(account == nil)
                Spacer()
                Button(state.needsConnection ? "Connect Overleaf" : "Connection") { state.signIn = true }.disabled(account == nil || state.loading)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.remileHelp("Refresh available projects").disabled(account == nil || state.loading)
            }
            if state.credentials || library.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if account == nil { TextField("Account name", text: $state.accountName) }
                    else { Text(state.accountName).font(RemileType.callout.weight(.semibold)) }
                    if account != nil {
                        SecureField("Git authentication token", text: $state.token).bubbleHelp(RemileHints.overleafToken)
                        Link("Get a Git token", destination: URL(string: "https://www.overleaf.com/user/settings")!).font(RemileType.caption).bubbleHelp(RemileHints.overleafToken)
                    }
                    HStack {
                        Text(account == nil ? "Connect to browse projects. Add a Git token to import." : "The Git token is saved in Keychain for this account.").font(RemileType.small).foregroundStyle(.secondary)
                        Spacer()
                        Button(account == nil ? "Connect Overleaf" : "Save token") {
                            let newAccount = account == nil
                            if let saved = library.saveAccount(name: state.accountName, token: state.token) {
                                state.accountID = saved.id; state.token = ""; state.credentials = false
                                if newAccount { state.signIn = true }
                                else if let pending = state.pendingProject { state.pendingProject = nil; add(id: pending.id, name: pending.name) }
                            }
                        }.disabled(state.accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (account != nil && state.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }.padding(14).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8)).transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available projects").font(RemileType.callout.weight(.semibold))
                    TextField("Find a project", text: $state.query)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(available) { item in
                                HStack(spacing: 8) {
                                    OverleafTagMark(tags: item.tags)
                                    Button { state.selected = item.id } label: { Text(item.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                                }.padding(10).background(state.selected == item.id ? RemileStyle.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            if available.isEmpty { Text(state.catalog.isEmpty ? "Connect Overleaf to browse your projects." : "All matching projects are in your library.").font(RemileType.caption).foregroundStyle(.secondary).padding(10) }
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack { Spacer(); Button { if let item = available.first(where: { $0.id == state.selected }) { add(id: item.id, name: item.name) } } label: { Image(systemName: "arrow.right").padding(8) }.remileHelp("Add selected project to library").disabled(library.busy || account == nil || !available.contains { $0.id == state.selected }); Spacer() }.frame(width: 40)
                VStack(alignment: .leading, spacing: 12) {
                    Text("In your library").font(RemileType.callout.weight(.semibold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(library.projects) { project in
                                HStack(spacing: 10) {
                                    OverleafTagMark(tags: library.tags[project.id] ?? [])
                                    Button { library.presented = false; library.browsing = false; open(library.root(project)) } label: {
                                        VStack(alignment: .leading, spacing: 4) { Text(project.name).lineLimit(2); Text(project.account).font(RemileType.small).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    Button { state.removing = project } label: { Image(systemName: "minus.circle") }.remileHelp("Remove from local library").disabled(library.busy)
                                }.padding(10).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                            }
                            if library.projects.isEmpty { Text("Choose a project on the left to keep it here.").font(RemileType.caption).foregroundStyle(.secondary).padding(10) }
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: 260)
            Divider()
            DisclosureGroup("Add project by link", isExpanded: $state.link) {
                HStack { TextField("Overleaf project link", text: $state.url); TextField("Name", text: $state.name).frame(width: 170); Button("Add") { if let id = OverleafConnection.projectID(state.url) { add(id: id, name: state.name) } }.disabled(library.busy || account == nil || OverleafConnection.projectID(state.url) == nil) }.padding(.top, 10)
            }.font(RemileType.caption)
            if let error = library.error ?? state.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled) }
        }.padding(24).frame(width: 820).background(RemileStyle.background).interactiveDismissDisabled(library.busy)
            .animation(reduceMotion ? nil : RemileMotion.panel, value: state.credentials)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.link)
            .task { state.accountID = library.accounts.first?.id; state.link = library.adding }
            .task(id: state.accountID) {
                state.loadID = UUID(); state.catalog = []; state.selected = nil; state.pendingProject = nil; state.error = nil; state.needsConnection = false
                state.token = ""
                if let account { state.accountName = account.name; if !state.signIn { await load() } }
                else { state.loading = false }
            }
            .sheet(isPresented: $state.signIn, onDismiss: { Task { await load() } }) { if let account { OverleafSignIn(profile: account.id) { state.signIn = false } } }
            .confirmationDialog("Remove from local library?", isPresented: Binding(get: { state.removing != nil }, set: { if !$0 { state.removing = nil } }), titleVisibility: .visible) {
                Button("Move local copy to Trash", role: .destructive) { if let project = state.removing, prepareRemoval(library.root(project)) { library.remove(project) }; state.removing = nil }
            } message: { Text("Unpublished local edits move to Trash with the cache. The online project and saved account stay in place.") }
    }
    private func load() async {
        guard let account else { return }; state.loading = true; state.error = nil
        let loadID = UUID(); state.loadID = loadID
        defer { if state.loadID == loadID { state.loading = false } }
        do { let catalog = try await OverleafWebClient.projects(account.id); if !Task.isCancelled, state.loadID == loadID, state.accountID == account.id { state.catalog = catalog; state.needsConnection = false; library.rememberTags(catalog, profile: account.id) } }
        catch {
            guard !Task.isCancelled, state.loadID == loadID, state.accountID == account.id else { return }
            state.error = error.localizedDescription
            state.needsConnection = (error as? OverleafWebClient.Failure)?.needsConnection == true
        }
    }
    private func add(id: String, name: String) {
        guard let account else { return }
        library.error = nil; state.error = nil
        if OverleafCredential.availability(account.id) == .missing {
            state.pendingProject = (id, name); state.credentials = true
            state.error = "Add a Git token once to bring projects into your library."; return
        }
        Task { await library.connect(url: "https://www.overleaf.com/project/" + id, name: name, account: account.name, token: ""); if library.error == nil { library.rememberTags(state.catalog, profile: account.id); state.url = ""; state.name = ""; state.selected = nil } }
    }
}
