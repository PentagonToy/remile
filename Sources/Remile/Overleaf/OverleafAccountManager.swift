import SwiftUI

/// Account identity, access preferences and credentials have one home.
struct OverleafAccountManager: View {
    @ObservedObject var library: OverleafLibrary
    let prepareRemoval: (URL) -> Bool
    let close: () -> Void
    @StateObject private var draft: Draft
    private final class Draft: ObservableObject {
        @Published var selected: UUID?
        @Published var name = ""
        @Published var adding = false
        @Published var signIn = false
        @Published var removing = false
        @Published var showGit = false
        @Published var token = ""
        @Published var tokenSaved = false
    }
    init(library: OverleafLibrary, selected: UUID?, requestGitToken: Bool = false, prepareRemoval: @escaping (URL) -> Bool, close: @escaping () -> Void) {
        self.library = library; self.prepareRemoval = prepareRemoval; self.close = close
        let initial = Draft(); initial.selected = library.accounts.first(where: { $0.id == selected })?.id ?? library.accounts.first?.id
        initial.name = library.accounts.first(where: { $0.id == initial.selected })?.name ?? ""
        initial.adding = library.accounts.isEmpty; initial.showGit = requestGitToken
        _draft = StateObject(wrappedValue: initial)
    }
    private var account: OverleafLibrary.Account? { library.accounts.first { $0.id == draft.selected } }
    private var projectCount: Int { library.projects.filter { $0.profileID == draft.selected }.count }
    private func choose(_ id: UUID) {
        draft.adding = false; draft.selected = id; draft.name = library.accounts.first { $0.id == id }?.name ?? ""
        draft.token = ""; draft.tokenSaved = false; library.error = nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Overleaf accounts").font(RemileType.heading)
                Spacer()
                if library.busy { ProgressView().controlSize(.small) }
                Button("Close", action: close).keyboardShortcut(.cancelAction).disabled(library.busy)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(library.accounts) { account in
                                Button { choose(account.id) } label: {
                                    Text(account.name).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(draft.selected == account.id ? RemileStyle.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: RemileRadius.control))
                                }.buttonStyle(.plain).accessibilityValue(draft.selected == account.id ? "Selected" : "")
                            }
                        }.scrollContentGutter()
                    }
                    Button { draft.adding = true; draft.selected = nil; draft.name = ""; draft.token = ""; library.error = nil } label: { SymbolLabel("Add account", systemImage: "plus") }
                }.padding(14).frame(width: 174).background(RemileStyle.sidebar)
                Divider()
                VStack(spacing: 0) {
                    Form {
                        Section("Account") {
                            HStack(spacing: 8) {
                                Text("Name").frame(width: 60, alignment: .leading)
                                TextField("Account name", text: $draft.name).labelsHidden().multilineTextAlignment(.leading).textFieldStyle(.roundedBorder).onSubmit(save)
                                if !draft.adding { Button("Save", action: save).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name == account?.name) }
                            }
                            if account != nil { HStack { Text("Local projects"); Spacer(); Text("\(projectCount)").foregroundStyle(.secondary).monospacedDigit() } }
                        }
                        if let account {
                            Section("Access") {
                                HStack {
                                    Text("Plan"); Spacer()
                                    RemileSegmentedControl(title: "Overleaf plan", selection: Binding<OverleafLibrary.Plan?>(get: { account.plan }, set: { if let plan = $0 { library.setPlan(plan, premiumProjectAccess: account.premiumProjectAccess == true, for: account.id) } }), options: account.plan == nil ? [nil, .free, .premium] : [.free, .premium], label: { $0?.rawValue ?? "Choose" }).frame(width: account.plan == nil ? 240 : 180)
                                }
                                if account.plan == .free {
                                    Toggle("Access to Premium-owned projects", isOn: Binding(get: { account.premiumProjectAccess == true }, set: { library.setPlan(.free, premiumProjectAccess: $0, for: account.id) }))
                                        .toggleStyle(.checkbox).remileHelp("Enable Git for projects owned by an Overleaf Premium subscriber.")
                                }
                                HStack { Text("Overleaf login"); Spacer(); Button("Sign in…") { draft.signIn = true } }
                                if account.allowsGit {
                                    DisclosureGroup("Git token", isExpanded: $draft.showGit) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            SecureField("New Git token", text: $draft.token).labelsHidden().textFieldStyle(.roundedBorder).onSubmit(saveToken)
                                            HStack {
                                                Link("Get a token", destination: URL(string: "https://www.overleaf.com/user/settings")!)
                                                Spacer()
                                                if draft.tokenSaved { SymbolLabel("Saved", systemImage: "checkmark").foregroundStyle(RemileStyle.success) }
                                                Button("Save token", action: saveToken).disabled(draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                            }
                                        }.padding(.leading, 18).padding(.top, 10)
                                    }.remileHelp(RemileHints.overleafToken)
                                }
                            }
                        } else {
                            Section { Button("Add and connect", action: save).buttonStyle(RemileActionStyle(emphasis: .primary)).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        }
                        if let error = library.error { Section { Text(error).font(RemileType.small).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) } }
                    }.formStyle(.grouped).scrollContentBackground(.hidden)
                    if account != nil {
                        Divider()
                        HStack {
                            Button(role: .destructive) { draft.removing = true } label: { SymbolLabel("Remove account…", systemImage: "trash") }
                            Spacer()
                        }.padding(.horizontal, 20).padding(.vertical, 12)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.disabled(library.busy)
        }.frame(width: 680, height: 500).font(RemileType.control).buttonStyle(RemileActionStyle()).controlSize(.regular)
            .background(RemileStyle.background).foregroundStyle(RemileStyle.ink).tint(RemileStyle.accent)
            .interactiveDismissDisabled(library.busy)
            .sheet(isPresented: $draft.signIn) { if let id = draft.selected { OverleafSignIn(profile: id) { draft.signIn = false } } }
            .alert("Remove \(account?.name ?? "account") from remile?", isPresented: $draft.removing) {
                Button("Cancel", role: .cancel) { }
                Button("Remove account", role: .destructive) {
                    guard let id = draft.selected else { return }
                    Task {
                        if await library.removeAccount(id, prepare: prepareRemoval) {
                            if let first = library.accounts.first { choose(first.id) } else { draft.selected = nil; draft.name = ""; draft.adding = true }
                        }
                    }
                }
            } message: { Text("This deletes \(projectCount) local projects and their history, including unpublished edits. Projects on Overleaf are kept.") }
            .onDisappear { draft.token = "" }
    }
    private func saveToken() {
        guard let account, !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if library.saveAccount(name: account.name, token: draft.token) != nil { draft.token = ""; draft.tokenSaved = true }
    }
    private func save() {
        if draft.adding {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !library.accounts.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { library.error = "An account already uses this name."; return }
            if let saved = library.saveAccount(name: name, token: "", plan: .free) { choose(saved.id); draft.signIn = true }
        } else if let id = draft.selected { _ = library.renameAccount(id, to: draft.name) }
    }
}
