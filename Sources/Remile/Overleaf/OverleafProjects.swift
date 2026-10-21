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
                Text("Overleaf library").font(RemileType.heading); Spacer()
                if library.busy || state.loading { ProgressView().controlSize(.small) }
                Button("Done") { library.presented = false }.keyboardShortcut(.cancelAction).disabled(library.busy)
            }
            HStack(spacing: 12) {
                Picker("Account", selection: $state.accountID) {
                    Text("Choose account").tag(UUID?.none)
                    ForEach(library.accounts) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 230)
                Button("Account and token") { state.credentials.toggle() }
                Spacer()
                Button("Sign in") { state.signIn = true }.disabled(account == nil)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.remileHelp("Refresh available projects").disabled(account == nil || state.loading)
            }
            if state.credentials || library.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Account name", text: $state.accountName)
                    SecureField(account == nil ? "Git authentication token" : "Saved token · paste to replace", text: $state.token)
                    HStack {
                        Link("Get a Git token", destination: URL(string: "https://www.overleaf.com/user/settings")!).font(RemileType.caption)
                        Spacer()
                        Button("Save account") {
                            if let account = library.saveAccount(name: state.accountName, token: state.token) { state.accountID = account.id; state.token = ""; state.credentials = false }
                        }
                    }
                    Text("Saved securely in Keychain and reused for this account’s projects.").font(RemileType.small).foregroundStyle(.secondary)
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
                            if available.isEmpty { Text(state.catalog.isEmpty ? "Sign in to choose from your projects, or add a project link below." : "All matching projects are in your library.").font(RemileType.caption).foregroundStyle(.secondary).padding(10) }
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
                                    Button { library.presented = false; open(library.root(project)) } label: {
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
            .task { state.accountID = library.accounts.first?.id; state.link = library.adding; if account != nil { await load() } }
            .onChange(of: state.accountID) { state.catalog = []; state.selected = nil; if let account { state.accountName = account.name; Task { await load() } } }
            .sheet(isPresented: $state.signIn, onDismiss: { Task { await load() } }) { if let account { OverleafSignIn(profile: account.id) { state.signIn = false } } }
            .confirmationDialog("Remove from local library?", isPresented: Binding(get: { state.removing != nil }, set: { if !$0 { state.removing = nil } }), titleVisibility: .visible) {
                Button("Move local copy to Trash", role: .destructive) { if let project = state.removing, prepareRemoval(library.root(project)) { library.remove(project) }; state.removing = nil }
            } message: { Text("Unpublished local edits move to Trash with the cache. The online project and saved account stay in place.") }
    }
    private func load() async {
        guard let account, !state.loading else { return }; state.loading = true; state.error = nil
        do { let catalog = try await OverleafWebClient.projects(account.id); if state.accountID == account.id { state.catalog = catalog; library.rememberTags(catalog, profile: account.id) } }
        catch { state.error = error.localizedDescription }
        state.loading = false
    }
    private func add(id: String, name: String) {
        guard let account else { return }
        Task { await library.connect(url: "https://www.overleaf.com/project/" + id, name: name, account: account.name, token: ""); if library.error == nil { library.rememberTags(state.catalog, profile: account.id); state.url = ""; state.name = ""; state.selected = nil } }
    }
}
