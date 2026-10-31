import SwiftUI

/// Git has no account-wide project catalogue. A link is the only import input.
struct OverleafProjects: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    @State private var accountID: UUID?
    @State private var url = ""
    @State private var name = ""
    @State private var accounts = false
    private var account: OverleafLibrary.Account? { library.accounts.first { $0.id == accountID } ?? library.accounts.first }
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.spacing * 2) {
            HStack {
                Text("Add Overleaf project").font(RemileType.heading)
                Spacer()
                Button("Done") { library.presented = false }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Account", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                    ForEach(library.accounts) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(library.accounts.isEmpty ? "Add account…" : "Git token…") { accounts = true }
            }
            TextField("Overleaf project or Git link", text: $url).textFieldStyle(.roundedBorder)
            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            if let error = library.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled) }
            HStack {
                Link("Open Overleaf", destination: URL(string: "https://www.overleaf.com/project")!)
                Spacer()
                if library.busy { ProgressView().controlSize(.small) }
                Button("Add project") {
                    guard let account else { return }
                    Task {
                        await library.connect(url: url, name: name, account: account.name, token: "")
                        if library.error == nil { library.presented = false; library.browsing = true }
                    }
                }.buttonStyle(RemileActionStyle(emphasis: .primary))
                    .disabled(library.busy || account == nil || OverleafConnection.projectID(url) == nil)
            }
        }.padding(24).frame(width: 540).font(RemileType.control).buttonStyle(RemileActionStyle())
            .background(RemileStyle.background).interactiveDismissDisabled(library.busy)
            .sheet(isPresented: $accounts) { OverleafAccountManager(library: library, selected: account?.id, requestGitToken: true, prepareRemoval: prepareRemoval) { accounts = false } }
    }
}
