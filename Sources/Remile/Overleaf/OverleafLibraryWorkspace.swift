import SwiftUI

/// Browse the account catalogue alongside downloaded projects.
struct OverleafLibraryWorkspace: View {
    @ObservedObject var library: OverleafLibrary
    let open: (URL) -> Void
    let prepareRemoval: (URL) -> Bool
    let isOpen: (URL) -> Bool
    let didRemove: (URL) -> Void
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var query = ""
        @Published var selectedTag = "all"
        @Published var accountID: UUID?
        @Published var managingAccounts = false
        var tokenAccount: UUID?
        @Published var managingSpace = false
        var initialSpaceSelection: UUID?
        @Published var selection: String?
        @Published var downloading: String?
        @Published var refresh = 0
        @Published var loading = false
        @Published var connection: OverleafLibrary.Account?
        @Published var failedAccounts: [OverleafLibrary.Account] = []
        @Published var catalogueIssue: String?
    }
    @ObservedObject private var network = NetworkAccessState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AnimationPolicy.preference) private var animations = true
    @AppStorage("overleaf.library.sort") private var sort = "Manual"
    @AppStorage("overleaf.library.list") private var listLayout = false

    private struct Card: Identifiable {
        let profile: UUID
        let projectID: String
        let name: String
        let account: String
        let tags: [OverleafWebClient.Tag]?
        let local: OverleafConnection?
        var id: String { profile.uuidString + "/" + projectID }
    }

    private var accountProjects: [Card] {
        var cards = library.projects.map { project in
            Card(profile: project.profileID, projectID: project.projectID, name: project.name,
                 account: project.account, tags: library.tags[project.id],
                 local: project)
        }
        var seen = Set(cards.map(\.id))
        for account in library.accounts {
            for item in library.catalogue[account.id] ?? [] {
                let card = Card(profile: account.id, projectID: item.id, name: item.name, account: account.name,
                                tags: item.tagsLoaded || !item.tags.isEmpty ? item.tags : nil, local: nil)
                if seen.insert(card.id).inserted { cards.append(card) }
            }
        }
        return cards.filter { state.accountID == nil || $0.profile == state.accountID }
    }

    private func untagged(_ card: Card) -> Bool { card.tags?.isEmpty == true }

    private func tags(for projects: [Card]) -> [(tag: OverleafWebClient.Tag, count: Int)] {
        var entries: [String: (tag: OverleafWebClient.Tag, count: Int)] = [:]
        for card in projects {
            var seen = Set<String>()
            for tag in card.tags ?? [] where seen.insert(tag.id).inserted {
                entries[tag.id] = (tag, (entries[tag.id]?.count ?? 0) + 1)
            }
        }
        return entries.values.sorted {
            let order = $0.tag.name.localizedStandardCompare($1.tag.name)
            return order == .orderedSame ? $0.tag.id < $1.tag.id : order == .orderedAscending
        }
    }

    private func visibleProjects(in projects: [Card]) -> [Card] {
        let result = projects.filter { card in
            let labels = card.tags ?? []
            let matchesTag = state.selectedTag == "all" || (state.selectedTag == "untagged" ? untagged(card) : (state.selectedTag == "unknown" ? card.tags == nil : labels.contains { $0.id == state.selectedTag }))
            return matchesTag && (state.query.isEmpty || ([card.name, card.account] + labels.map(\.name)).contains { $0.localizedCaseInsensitiveContains(state.query) })
        }
        if sort == "Name" { return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        if sort == "Account" { return result.sorted { ($0.account + " " + $0.name).localizedStandardCompare($1.account + " " + $1.name) == .orderedAscending } }
        return result
    }
    private var canConnect: Bool { library.hasNetwork && !network.offline }
    private struct CatalogueRequest: Equatable {
        let accounts: [UUID]
        let online: Bool
        let refresh: Int
    }
    private var catalogueRequest: CatalogueRequest {
        .init(accounts: library.accounts.map(\.id), online: canConnect, refresh: state.refresh)
    }

    private func refreshCatalogue(_ request: CatalogueRequest) async {
        state.loading = request.online && !request.accounts.isEmpty
        guard state.loading else { return }
        state.catalogueIssue = nil
        state.failedAccounts = []
        defer { if request == catalogueRequest, !Task.isCancelled { state.loading = false } }
        for account in library.accounts {
            guard !Task.isCancelled, request == catalogueRequest else { return }
            do {
                let listed = try await OverleafWebClient.projects(account.id)
                guard !Task.isCancelled, request == catalogueRequest else { return }
                try library.rememberCatalogue(listed, profile: account.id)
            } catch {
                guard !Task.isCancelled, request == catalogueRequest else { return }
                if (error as? OverleafWebClient.Failure)?.needsConnection == true { state.failedAccounts.append(account) }
                else { state.catalogueIssue = error.localizedDescription }
            }
        }
    }
    var body: some View {
        let projects = accountProjects
        let tags = tags(for: projects)
        let visible = visibleProjects(in: projects)
        let request = catalogueRequest
        return VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            ReaderSplit(sizing: .sidebar, minimum: ReaderSidebar.minimum, maximum: ReaderSidebar.maximum, minimumContent: 320, label: "Overleaf tags", pane: { tagList(tags, projects: projects) }, content: { projectList(visible) })
        }.frame(maxWidth: .infinity, maxHeight: .infinity).font(RemileType.control).background(RemileStyle.background)
            .navigationTitle("Overleaf library")
            .sheet(isPresented: $state.managingAccounts, onDismiss: { state.tokenAccount = nil }) {
                OverleafAccountManager(library: library, selected: state.tokenAccount ?? state.accountID,
                                       requestGitToken: state.tokenAccount != nil, prepareRemoval: prepareRemoval) {
                    state.managingAccounts = false
                }
            }
            .onChange(of: library.accounts.map(\.id)) { if !library.accounts.contains(where: { $0.id == state.accountID }) { state.accountID = nil } }
            .onChange(of: state.accountID) { state.selectedTag = "all" }
            .onChange(of: tags.map { $0.tag.id }) { _, ids in
                if !["all", "untagged", "unknown"].contains(state.selectedTag), !ids.contains(state.selectedTag) {
                    state.selectedTag = "all"
                }
            }
            .onAppear { library.watchReachability() }
            .task(id: request) { await refreshCatalogue(request) }
            .sheet(item: $state.connection) { account in
                OverleafSignIn(profile: account.id, catalogue: true, onConnected: { state.refresh += 1 }) { state.connection = nil }
            }
            .sheet(isPresented: $state.managingSpace) {
                OverleafLocalCopies(library: library, initialSelection: state.initialSpaceSelection,
                                    isOpen: isOpen, didRemove: didRemove)
            }
    }
    private func manageSpace(_ project: OverleafConnection? = nil) {
        state.initialSpaceSelection = project?.id
        state.managingSpace = true
    }

    private var header: some View {
        HStack(spacing: RemileControl.spacing) {
            WorkspaceBackButton(title: "Return to workspace") { library.browsing = false }
            Text("Overleaf library").font(RemileType.heading).fixedSize()
            Spacer(minLength: 8)
            if state.loading { ProgressView().controlSize(.small).accessibilityLabel("Refreshing Overleaf projects") }
            Button { state.refresh += 1 } label: { SymbolIcon(systemName: "arrow.clockwise") }
                .disabled(!canConnect || state.loading || library.accounts.isEmpty)
                .accessibilityLabel("Refresh Overleaf projects").remileHelp("Refresh projects")
            Button("Free Up Space…") { manageSpace() }
                .buttonStyle(RemileActionStyle(emphasis: .quiet))
                .disabled(library.busy || library.projects.isEmpty)
                .fixedSize()
            Button { library.openLibrary(add: true) } label: {
                SymbolIcon(systemName: "plus")
            }.disabled(library.busy).accessibilityLabel("Add Overleaf projects").remileHelp("Add Overleaf projects")
        }.buttonStyle(RemileToolStyle())
    }
    private func tagList(_ tags: [(tag: OverleafWebClient.Tag, count: Int)], projects: [Card]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
                Menu {
                        Button("All accounts") { state.accountID = nil }
                        ForEach(library.accounts) { account in Button(account.name) { state.accountID = account.id } }
                        Divider()
                        Button("Manage accounts…") { state.managingAccounts = true }
                    } label: { Text(library.accounts.first(where: { $0.id == state.accountID })?.name ?? "Accounts").lineLimit(1) }
                    .menuStyle(.borderlessButton).tint(RemileStyle.ink).font(RemileType.small).fixedSize()
                    .padding(.horizontal, 10).padding(.bottom, 10).accessibilityLabel("Account filter and management")
                tagButton("All projects", id: "all", count: projects.count)
                Text("Tags").font(RemileType.caption.weight(.semibold)).foregroundStyle(RemileStyle.secondaryInk).padding(.top, 18).padding(.horizontal, 10)
                ForEach(tags, id: \.tag.id) { item in
                    tagButton(item.tag.name, id: item.tag.id, count: item.count, color: OverleafTagMark.tint(item.tag.color))
                }
                tagButton("Untagged", id: "untagged", count: projects.lazy.filter(untagged).count)
                let unknown = projects.lazy.filter { $0.tags == nil }.count
                if unknown > 0 { tagButton("Tags unavailable", id: "unknown", count: unknown) }
              }.padding(12).scrollContentGutter()
            }
            Divider()
            EditorSidebarBrand(compact: false).padding(12).fixedSize(horizontal: false, vertical: true)
        }.background(RemileStyle.sidebar)
    }
    private func tagButton(_ name: String, id: String, count: Int, color: Color? = nil) -> some View {
        Button { state.selectedTag = id } label: {
            HStack(spacing: RemileControl.spacing) {
                if let color { Capsule().fill(color).frame(width: 3, height: 18) }
                Text(name).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
            }.padding(10).contentShape(Rectangle()).background(state.selectedTag == id ? RemileStyle.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityValue(state.selectedTag == id ? "Selected" : "")
    }
    private func projectList(_ visible: [Card]) -> some View {
        GeometryReader { geometry in
            let inset: CGFloat = 20
            let width = geometry.size.width - 2 * inset - ScrollContentSpacing.gutter
            let columns = listLayout ? 1 : max(1, min(visible.count, 4, Int(max(0, width) / 270)))
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .trailing, spacing: RemileControl.spacing) {
                    projectSearch
                    projectControls(visible)
                }.scrollContentGutter()
                if let message = library.error ?? state.catalogueIssue {
                    Text(message).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled)
                }
                if !state.failedAccounts.isEmpty && canConnect {
                    if let account = state.failedAccounts.first, state.failedAccounts.count == 1 {
                        Button("Connect Overleaf…") { state.connection = account }
                    } else {
                        Menu("Connect Overleaf…") {
                            ForEach(state.failedAccounts) { account in
                                Button(account.name) { state.connection = account }
                            }
                        }.fixedSize()
                    }
                }
                if visible.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: listLayout ? 8 : 14) {
                            ForEach(visible) { item in card(item, visible: visible) }
                        }.padding(.bottom, 12).scrollContentGutter()
                    }.smoothScrolling()
                        .keyframeAnimator(initialValue: 1.0, trigger: layoutMotion) { cards, opacity in
                            cards.opacity(opacity)
                        } keyframes: { _ in
                            if layoutMotion != nil {
                                MoveKeyframe(0.76)
                                LinearKeyframe(1.0, duration: 0.16)
                            } else {
                                MoveKeyframe(1.0)
                            }
                        }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(inset)
        }
    }

    private var layoutMotion: Bool? { animations && !reduceMotion ? listLayout : nil }

    private var projectSearch: some View {
        TextField("Find a project", text: $state.query).textFieldStyle(.roundedBorder)
    }

    private func projectControls(_ visible: [Card]) -> some View {
        HStack {
            Picker("Sort", selection: $sort) {
                Text("Manual").tag("Manual")
                Text("Name").tag("Name")
                Text("Account").tag("Account")
            }.labelsHidden().frame(width: 106)
            Picker("Project view", selection: $listLayout) {
                SymbolIcon(systemName: "square.grid.2x2").accessibilityLabel("Grid").tag(false)
                SymbolIcon(systemName: "list.bullet").accessibilityLabel("List").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 78)
            let selected = visible.first { $0.id == state.selection }
            Menu {
                if let selected { actions(selected, visible: visible) }
            } label: { SymbolIcon(systemName: "ellipsis") }
                .accessibilityLabel("Selected project actions").disabled(selected == nil)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if state.loading {
            ProgressView("Finding projects…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.accounts.isEmpty {
            ContentUnavailableView {
                Label("No Overleaf accounts", systemImage: "books.vertical")
            } actions: {
                Button("Add account…") { state.managingAccounts = true }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(accountProjects.isEmpty ? "No projects available" : "No matching projects", systemImage: "books.vertical")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func actions(_ item: Card, visible: [Card]) -> some View {
        if item.local != nil || canConnect {
            Button("Open") { activate(item, openAfterDownload: true) }.disabled(library.busy)
        }
        if let project = item.local {
            OverleafProjectIDButton(project: project)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root(project)]) }
            let local = visible.compactMap(\.local)
            if let index = local.firstIndex(where: { $0.id == project.id }) {
                Divider()
                if index > 0 {
                    Button("Move earlier") { sort = "Manual"; _ = library.moveProject(project.id, before: local[index - 1].id) }
                }
                if index + 1 < local.count {
                    Button("Move later") { sort = "Manual"; _ = library.moveProject(project.id, before: index + 2 < local.count ? local[index + 2].id : nil) }
                }
            }
            Divider()
            Button("Free Up Space…") { manageSpace(project) }
                .disabled(library.busy || !canConnect || project.liveOnly == true)
        } else {
            Button("Download for Offline Use") { activate(item, openAfterDownload: false) }
                .disabled(library.busy || !canConnect)
        }
        if let url = URL(string: "https://www.overleaf.com/project/" + item.projectID), canConnect {
            Button("Open in Overleaf") { NSWorkspace.shared.open(url) }
        }
    }

    @ViewBuilder private func card(_ item: Card, visible: [Card]) -> some View {
        let content = cardContent(item).contextMenu { actions(item, visible: visible) }
        if let project = item.local {
            content.draggable("remile-overleaf-project:" + project.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let value = items.first, value.hasPrefix("remile-overleaf-project:"),
                          let id = UUID(uuidString: String(value.dropFirst(24))) else { return false }
                    sort = "Manual"
                    return library.moveProject(id, before: project.id)
                }
        } else { content }
    }

    private func cardContent(_ item: Card) -> some View {
        let labels = item.tags ?? []
        let status = state.downloading == item.id ? "Downloading…" : item.local == nil ? "Cloud only" : "On this Mac"
        return HStack(alignment: listLayout ? .center : .top, spacing: RemileControl.spacing) {
            OverleafTagMark(tags: labels)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(RemileType.heading).lineLimit(listLayout ? 1 : 2, reservesSpace: !listLayout)
                if listLayout {
                    Text(([item.account] + labels.map(\.name)).joined(separator: " · ")).font(RemileType.caption)
                        .foregroundStyle(RemileStyle.secondaryInk).lineLimit(1)
                } else {
                    Text(item.account).font(RemileType.caption).foregroundStyle(RemileStyle.secondaryInk)
                    if !labels.isEmpty {
                        Text(labels.map(\.name).joined(separator: " · ")).font(RemileType.small)
                            .foregroundStyle(RemileStyle.secondaryInk).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        storageIcon(item, status: status).fixedSize()
                    }
                }
            }
            if listLayout {
                Spacer(minLength: 0)
                storageIcon(item, status: status).fixedSize()
            }
        }
        .padding(listLayout ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: listLayout ? 64 : 150, alignment: listLayout ? .center : .topLeading)
        .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: RemileRadius.card)
                .strokeBorder(state.selection == item.id ? RemileStyle.accent : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.selection = item.id; activate(item, openAfterDownload: true) }
        .onTapGesture { state.selection = item.id }
        .focusable()
        .onKeyPress(.return) { state.selection = item.id; activate(item, openAfterDownload: true); return .handled }
        .onKeyPress(.space) { state.selection = item.id; return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(([item.name, item.account] + labels.map(\.name)).joined(separator: ", "))
        .accessibilityValue(status)
        .accessibilityAddTraits(state.selection == item.id ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { state.selection = item.id; activate(item, openAfterDownload: true) }
        .help(item.name)
    }

    @ViewBuilder private func storageIcon(_ item: Card, status: String) -> some View {
        HStack(spacing: 4) {
            if state.downloading == item.id { ProgressView().controlSize(.mini) }
            else { SymbolIcon(systemName: item.local == nil ? "cloud" : "checkmark.circle") }
            Text(status).font(RemileType.caption)
        }.foregroundStyle(RemileStyle.secondaryInk)
    }

    private func activate(_ item: Card, openAfterDownload: Bool) {
        guard !library.busy, state.downloading == nil else { return }
        if let project = item.local {
            open(library.root(project))
            return
        }
        guard canConnect else {
            library.error = "Connect to the internet to download this project."
            return
        }
        guard library.allowsGit(item.profile) else {
            library.error = OverleafLibrary.premiumHint
            return
        }
        guard OverleafCredential.availability(item.profile) != .missing else {
            state.tokenAccount = item.profile
            state.managingAccounts = true
            return
        }
        state.downloading = item.id
        Task {
            defer { state.downloading = nil }
            await library.connect(url: "https://www.overleaf.com/project/" + item.projectID, name: item.name, account: item.account, token: "", profile: item.profile)
            library.rememberTags(library.catalogue[item.profile] ?? [], profile: item.profile)
            if openAfterDownload, library.browsing, library.error == nil,
               let project = library.projects.first(where: { $0.profileID == item.profile && $0.projectID == item.projectID }) {
                open(library.root(project))
            }
        }
    }
}
