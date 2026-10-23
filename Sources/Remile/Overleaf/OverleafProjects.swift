import SwiftUI

struct OverleafProjects: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    @StateObject private var state = State()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private final class State: ObservableObject {
        @Published var panelSize = CGSize(width: 986, height: 600)
        @Published var accountID: UUID?
        var previousAccountID: UUID?
        @Published var accountName = "Personal"
        @Published var plan: OverleafLibrary.Plan = .free
        @Published var premiumProjectAccess = false
        @Published var premiumNotice = false
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
    private var allowsGit: Bool { account?.allowsGit ?? (state.plan == .premium || state.premiumProjectAccess) }
    private var planSelection: Binding<OverleafLibrary.Plan?> {
        Binding(get: { account == nil ? state.plan : account?.plan }, set: { value in
            guard let value else { return }
            state.plan = value
            if let account { library.setPlan(value, premiumProjectAccess: account.premiumProjectAccess == true, for: account.id) }
        })
    }
    var body: some View {
        ScrollView { contents }
            .frame(width: state.panelSize.width, height: state.panelSize.height)
            .background(RemileStyle.background)
            .background(OverleafImportSizing { state.panelSize = $0 }.frame(width: 0, height: 0))
    }
    private var accountPicker: some View {
        HStack(spacing: 12) {
            Text("Account").fixedSize(horizontal: true, vertical: false)
            Picker("Account", selection: $state.accountID) {
                Text("Choose account").tag(UUID?.none)
                ForEach(library.accounts) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().frame(width: 160)
        }
    }
    private var addAccount: some View {
        Button("Add account") { state.previousAccountID = state.accountID; state.accountID = nil; state.accountName = ""; state.plan = .free; state.premiumProjectAccess = false; state.credentials = true }
    }
    private var tokenControl: some View {
        Button("Git token") { if allowsGit { state.credentials.toggle() } else { state.premiumNotice = true } }
            .opacity(allowsGit ? 1 : 0.45).remileHelp(allowsGit ? RemileHints.overleafToken : OverleafLibrary.premiumHint).disabled(account == nil)
            .popover(isPresented: $state.premiumNotice) { HelpBubbleContent(text: OverleafLibrary.premiumHint) }
    }
    private var connectionControls: some View {
        HStack(spacing: 12) {
            Button(state.needsConnection ? "Connect Overleaf" : "Connection") { state.signIn = true }.disabled(account == nil || state.loading)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.remileHelp("Refresh available projects").disabled(account == nil || state.loading)
        }
    }
    private var contents: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Overleaf projects").font(RemileType.heading); Spacer()
                if library.busy || state.loading { ProgressView().controlSize(.small) }
                Button("Done") { library.presented = false }.keyboardShortcut(.cancelAction).disabled(library.busy)
            }
            if state.panelSize.width < 820 {
                VStack(spacing: 12) {
                    HStack { accountPicker; Spacer(); addAccount }
                    HStack { tokenControl; Spacer(); connectionControls }
                }
            } else {
                HStack(spacing: 12) { accountPicker; addAccount; tokenControl; Spacer(); connectionControls }
            }
            HStack(spacing: 14) {
                Text("Plan").fixedSize(horizontal: true, vertical: false)
                Picker("Plan", selection: planSelection) {
                    if account != nil && account?.plan == nil { Text("Choose plan").tag(OverleafLibrary.Plan?.none) }
                    ForEach(OverleafLibrary.Plan.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.pickerStyle(.segmented).labelsHidden().remileHelp("Choose your Overleaf plan. Overleaf checks project access.").frame(width: account != nil && account?.plan == nil ? 280 : 180)
                if planSelection.wrappedValue == .free {
                    Toggle("Premium project access", isOn: Binding(get: { account == nil ? state.premiumProjectAccess : account?.premiumProjectAccess == true }, set: { value in
                        state.premiumProjectAccess = value
                        if let account { library.setPlan(.free, premiumProjectAccess: value, for: account.id) }
                    })).toggleStyle(.checkbox).font(RemileType.caption)
                        .remileHelp("Enable Git for projects owned by an Overleaf Premium subscriber.")
                }
                Spacer()
            }.disabled(library.busy).accessibilityLabel("Overleaf plan preference")
            Divider()
            if state.credentials || library.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if account == nil {
                        HStack { TextField("Account name", text: $state.accountName); Button("Cancel") { state.credentials = false; state.accountID = state.previousAccountID ?? library.accounts.first?.id } .disabled(library.accounts.isEmpty) }
                    }
                    else { Text(state.accountName).font(RemileType.callout.weight(.semibold)) }
                    if allowsGit {
                        SecureField("Git authentication token", text: $state.token).remileHelp(RemileHints.overleafToken)
                        Link("Get a Git token", destination: URL(string: "https://www.overleaf.com/user/settings")!).font(RemileType.caption).remileHelp(RemileHints.overleafToken)
                    }
                    HStack {
                        Text(allowsGit ? (account == nil ? "Use a Git token to import by link." : "Save a Git token in Keychain for this account.") : "Use Live to edit projects without a Git token.").font(RemileType.small).foregroundStyle(.secondary)
                        Spacer()
                        Button(account == nil ? (!allowsGit || state.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Connect Overleaf" : "Save account") : "Save token") {
                            let newAccount = account == nil
                            let hasToken = !state.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            if let saved = library.saveAccount(name: state.accountName, token: allowsGit ? state.token : "", plan: account == nil ? state.plan : account?.plan, premiumProjectAccess: account == nil ? state.premiumProjectAccess : account?.premiumProjectAccess) {
                                state.accountID = saved.id; state.token = ""; state.credentials = false
                                if newAccount && (!allowsGit || !hasToken) { state.signIn = true }
                                else if let pending = state.pendingProject { state.pendingProject = nil; add(id: pending.id, name: pending.name) }
                            }
                        }.disabled(library.busy || state.accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (account != nil && state.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }.padding(14).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8)).transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available projects").font(RemileType.callout.weight(.semibold))
                    TextField("Find a project", text: $state.query)
                    if available.isEmpty {
                        VStack(spacing: 12) {
                            if state.loading { ProgressView().controlSize(.small) }
                            else { Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(RemileStyle.secondaryInk) }
                            Text(state.loading ? "Loading projects…" : (state.catalog.isEmpty ? (account == nil ? "Add an account to browse projects." : "Connect Overleaf to browse projects.") : (state.query.isEmpty ? "All projects are in your library." : "No matching projects.")))
                                .font(RemileType.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
                    } else { ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(available) { item in
                                HStack(spacing: 8) {
                                    OverleafTagMark(tags: item.tags)
                                    Button { state.selected = item.id } label: { Text(item.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                                }.padding(10).background(state.selected == item.id ? RemileStyle.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack { Spacer(); Button { if let item = available.first(where: { $0.id == state.selected }) { add(id: item.id, name: item.name) } } label: { Image(systemName: "arrow.right").padding(8) }.accessibilityLabel("Add selected project to local library").disabled(library.busy || account == nil || !available.contains { $0.id == state.selected }); Spacer() }.frame(width: 40)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Local library").font(RemileType.callout.weight(.semibold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(library.projects.filter { $0.profileID == account?.id }) { project in
                                HStack(spacing: 10) {
                                    OverleafTagMark(tags: library.tags[project.id] ?? [])
                                    Button { library.presented = false; library.browsing = false; open(library.root(project)) } label: {
                                        VStack(alignment: .leading, spacing: 4) { Text(project.name).lineLimit(2); Text(project.account).font(RemileType.small).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    Button { state.removing = project } label: { Image(systemName: "minus.circle") }.remileHelp("Remove from local library").disabled(library.busy)
                                }.padding(10).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                            }
                            if !library.projects.contains(where: { $0.profileID == account?.id }) { Text("Choose a project on the left to keep it here.").font(RemileType.caption).foregroundStyle(.secondary).padding(10) }
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: max(180, state.panelSize.height - 250 - (state.credentials || library.accounts.isEmpty ? 160 : 0) - (state.link ? 46 : 0) - (state.panelSize.width < 820 ? 40 : 0) - (library.error != nil || state.error != nil ? 42 : 0)))
            Divider()
            DisclosureGroup("Add project by link", isExpanded: $state.link) {
                HStack { TextField("Overleaf project link", text: $state.url); TextField("Name", text: $state.name).frame(width: 170); Button("Add") { if let id = OverleafConnection.projectID(state.url) { add(id: id, name: state.name) } }.accessibilityLabel("Add project to local library").disabled(library.busy || account == nil || OverleafConnection.projectID(state.url) == nil) }.padding(.top, 10)
            }.font(RemileType.caption)
            if let error = library.error ?? state.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled) }
        }.padding(24).frame(maxWidth: .infinity).background(RemileStyle.background).interactiveDismissDisabled(library.busy)
            .animation(reduceMotion ? nil : RemileMotion.panel, value: state.credentials)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.link)
            .task { state.accountID = library.accounts.first?.id; state.link = false }
            .task(id: state.accountID) {
                state.loadID = UUID(); state.catalog = []; state.selected = nil; state.pendingProject = nil; state.error = nil; state.needsConnection = false
                state.token = ""
                if let account { state.credentials = false; state.accountName = account.name; if !state.signIn { await load() } }
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
        do { let catalog = try await OverleafWebClient.projects(account.id); if !Task.isCancelled, state.loadID == loadID, state.accountID == account.id { state.catalog = catalog; state.needsConnection = false; library.rememberTags(catalog, profile: account.id); if catalog.contains(where: { !$0.tagsLoaded }) { state.error = "Could not refresh tags. Saved tags are shown." } } }
        catch {
            guard !Task.isCancelled, state.loadID == loadID, state.accountID == account.id else { return }
            state.needsConnection = (error as? OverleafWebClient.Failure)?.needsConnection == true
            state.error = state.needsConnection ? nil : error.localizedDescription
        }
    }
    private func add(id: String, name: String) {
        guard let account else { return }
        library.error = nil; state.error = nil
        if account.allowsGit && OverleafCredential.availability(account.id) == .missing {
            state.pendingProject = (id, name); state.credentials = true
            state.error = "Add a Git token once to bring projects into your library."; return
        }
        Task { await library.connect(url: "https://www.overleaf.com/project/" + id, name: name, account: account.name, token: ""); if library.error == nil { library.rememberTags(state.catalog, profile: account.id); state.url = ""; state.name = ""; state.selected = nil } }
    }
}
