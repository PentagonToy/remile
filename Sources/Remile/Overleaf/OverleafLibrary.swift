import SwiftUI
import WebKit
import Network

@MainActor final class OverleafLibrary: ObservableObject {
    enum Plan: String, Codable, CaseIterable { case free = "Free", premium = "Premium" }
    struct Account: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var plan: Plan? = nil
        var premiumProjectAccess: Bool? = nil
        // Older accounts keep their existing behaviour until a plan is selected.
        var allowsGit: Bool { plan != .free || premiumProjectAccess == true }
    }
    static let premiumHint = "Git requires Overleaf Premium for you or the project owner."
    enum Status { case unchecked, online, offline, changes, conflict }
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var projects: [OverleafConnection] = []
    @Published private(set) var tags: [UUID: [OverleafWebClient.Tag]] = [:]
    @Published private(set) var unavailableTags = Set<UUID>()
    @Published var importSize = CGSize(width: 986, height: 600)
    @Published var connectionNoticePresented = false
    private var pendingConnection: (() -> Void)?
    private var proceedAfterNotice = false
    @Published var presented = false
    @Published var browsing = false
    @Published private(set) var tagSignInProfile: UUID?
    @Published private(set) var tagError: String?
    @Published var busy = false
    @Published var error: String?
    @Published var review: OverleafGit.Review?
    @Published var offlineMode = false
    @Published var comments: [UUID: OverleafThreadArchive] = [:]
    var automaticPaused = Set<UUID>()
    @Published var pendingFiles = Set<UUID>()
    @Published var liveOwned = Set<UUID>()
    @Published var syncedAt: [UUID: Date] = [:]
    @Published var statuses: [UUID: Status] = [:]
    @Published var adding = false
    @Published private(set) var hasNetwork = true
    private let network = NWPathMonitor()
    private var policyObserver: NSObjectProtocol?
    var warmProject: TeXProject?
    var warmExpiry: Task<Void, Never>?
    private var probing = false
    var syncRevision = 0
    let directory: URL
    private let connectionNoticeDefaults: UserDefaults
    init(directory: URL? = nil, connectionNoticeDefaults: UserDefaults = .standard) {
        self.connectionNoticeDefaults = connectionNoticeDefaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.remile.app/Overleaf")
        do { try OverleafAccountEdit.recover(under: self.directory) } catch { self.error = error.localizedDescription }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("projects.json")), let saved = try? JSONDecoder().decode([OverleafConnection].self, from: data) { projects = saved }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("accounts.json")), let saved = try? JSONDecoder().decode([Account].self, from: data) { accounts = saved }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("project-tags.json")), let saved = try? JSONDecoder().decode([UUID: [OverleafWebClient.Tag]].self, from: data) { tags = saved }
        for project in projects { if let date = UserDefaults.standard.object(forKey: "overleaf.synced." + project.id.uuidString) as? Date { syncedAt[project.id] = date } }
        for project in projects where !accounts.contains(where: { $0.id == project.profileID }) { accounts.append(Account(id: project.profileID, name: project.account)) }
        policyObserver = NotificationCenter.default.addObserver(forName: NetworkAccessGate.changed, object: NetworkAccess.gate, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
        // Review copies contain no unique edits. The active local project owns every draft.
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("Reviews"))
        network.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.hasNetwork = path.status == .satisfied } }
        network.start(queue: DispatchQueue(label: "local.remile.overleaf.reachability"))
    }
    deinit { network.cancel(); if let policyObserver { NotificationCenter.default.removeObserver(policyObserver) } }
    static func syncAge(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        return minutes == 0 ? "Synced just now" : "Synced \(minutes) min ago"
    }
    func renameProject(_ id: UUID, to name: String) async throws {
        guard !busy, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var updated = projects; updated[index].name = name
        try persist(updated)
    }
    func title(for root: URL) -> String {
        connection(for: root) == nil ? "LaTeX" : "Overleaf"
    }
    func probe(_ project: OverleafConnection) async {
        guard allowsGit(project), !busy, !probing, !offlineMode, !NetworkAccess.offline, hasNetwork else { return }; probing = true; defer { probing = false }
        let root = root(project), revision = syncRevision
        do {
            let state = try await Task.detached {
                let remote = try OverleafGit.run(["ls-remote", "--exit-code", project.remote, "refs/heads/" + project.branch], at: root, credential: project.profileID).text.split(whereSeparator: \.isWhitespace).first.map(String.init)
                let local = try OverleafGit.run(["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let remote else { throw OverleafGit.Failure("Project revision unavailable.") }
                return (remote != local, try !OverleafGit.run(["status", "--porcelain", "--untracked-files=normal"], at: root).data.isEmpty)
            }.value
            if revision == syncRevision, projects.contains(where: { $0.id == project.id }) {
                if state.0 || state.1 { if statuses[project.id] != .conflict { statuses[project.id] = .changes } }
                else { statuses[project.id] = .online }
            }
        } catch { if revision == syncRevision { statuses[project.id] = .offline } }
    }
    func unlock(_ project: OverleafConnection) async {
        guard !busy else { return }; busy = true; error = nil
        do { _ = try await Task.detached(priority: .userInitiated) { try OverleafCredential.read(project.profileID, interactive: true) }.value }
        catch { self.error = error.localizedDescription }
        busy = false; await probe(project)
    }
    func root(_ project: OverleafConnection) -> URL { directory.appendingPathComponent("Projects/" + project.id.uuidString) }
    func connection(for root: URL) -> OverleafConnection? { projects.first { self.root($0).standardizedFileURL.path == root.standardizedFileURL.path } }
    func savedAccount(_ label: String) -> OverleafConnection? { projects.first { $0.account == label.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func account(_ label: String) -> Account? { accounts.first { $0.name == label.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func requestConnection(_ action: @escaping () -> Void) {
        guard OverleafConnectionNotice.accepted(in: connectionNoticeDefaults) else {
            pendingConnection = action
            proceedAfterNotice = false
            connectionNoticePresented = true
            return
        }
        action()
    }
    func respondToConnectionNotice(agree: Bool) {
        if agree { connectionNoticeDefaults.set(OverleafConnectionNotice.version, forKey: OverleafConnectionNotice.key) }
        proceedAfterNotice = agree
        connectionNoticePresented = false
    }
    func finishConnectionNotice() {
        let action = proceedAfterNotice ? pendingConnection : nil
        pendingConnection = nil
        proceedAfterNotice = false
        action?()
    }
    func openLibrary(add: Bool = false, from window: NSWindow? = nil) {
        requestConnection { [weak self] in self?.showLibrary(add: add, from: window) }
    }
    private func showLibrary(add: Bool, from window: NSWindow?) {
        if add, let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            let parent = window.sheetParent ?? window
            importSize = OverleafImportSizing.fit(parent: parent.contentLayoutRect.size, screen: parent.screen?.visibleFrame.size ?? parent.frame.size)
        }
        adding = add; if add { presented = true } else { presented = false; browsing = true }; error = nil }
    @discardableResult func moveProject(_ id: UUID, before target: UUID?) -> Bool {
        guard id != target, let project = projects.first(where: { $0.id == id }), target == nil || projects.contains(where: { $0.id == target }) else { return false }
        var updated = projects.filter { $0.id != id }
        let index = target.flatMap { target in updated.firstIndex { $0.id == target } } ?? updated.count
        updated.insert(project, at: index)
        do { try persist(updated); return true } catch { self.error = error.localizedDescription; return false }
    }
    func refreshProjectTags() async {
        // Preserve saved labels without contacting unsupported catalog/tag endpoints.
        tagError = nil; tagSignInProfile = nil
    }
    func isFreeLimited(_ project: OverleafConnection) -> Bool {
        accounts.first { $0.id == project.profileID }.map { $0.plan == .free && !$0.allowsGit } ?? false
    }
    func allowsGit(_ project: OverleafConnection) -> Bool { project.liveOnly != true && allowsGit(project.profileID) }
    func allowsGit(_ profile: UUID) -> Bool { accounts.first { $0.id == profile }?.allowsGit ?? true }
    func setPlan(_ plan: Plan, premiumProjectAccess: Bool, for id: UUID) {
        guard !busy, var account = accounts.first(where: { $0.id == id }) else { return }
        account.plan = plan; account.premiumProjectAccess = premiumProjectAccess
        do {
            let updated = accounts.map { $0.id == id ? account : $0 }
            try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
            accounts = updated; error = nil
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func saveAccount(name: String, token: String, plan: Plan? = nil, premiumProjectAccess: Bool? = nil) -> Account? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Name this account."; return nil }
        var account = account(name) ?? Account(id: UUID(), name: name)
        if let plan { account.plan = plan }
        if let premiumProjectAccess { account.premiumProjectAccess = premiumProjectAccess }
        do {
            if !token.isEmpty { try OverleafCredential.store(token, id: account.id) }
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
            accounts = updated; error = nil; return account
        } catch { self.error = error.localizedDescription; return nil }
    }
    @discardableResult func renameAccount(_ id: UUID, to value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        guard !name.isEmpty else { error = "Name this account."; return false }
        guard !accounts.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { error = "An account already uses this name."; return false }
        var updatedAccounts = accounts; updatedAccounts[index].name = name
        let updatedProjects = projects.map { project -> OverleafConnection in
            var value = project; if value.profileID == id { value.account = name }; return value
        }
        do {
            try OverleafAccountEdit.apply(.init(accounts: JSONEncoder().encode(updatedAccounts), projects: JSONEncoder().encode(updatedProjects), removedProjects: [], removedProfile: nil), under: directory)
            accounts = updatedAccounts; projects = updatedProjects; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func removeAccount(_ id: UUID, prepare: (URL) -> Bool) async -> Bool {
        guard !busy, accounts.contains(where: { $0.id == id }) else { return false }
        let owned = projects.filter { $0.profileID == id }
        if let warmProject, owned.contains(where: { root($0).path == warmProject.root.path }) { await discardWarmProject() }
        guard !owned.contains(where: { liveOwned.contains($0.id) }) else { error = "Close this account's open projects before removing it."; return false }
        guard owned.allSatisfy({ prepare(root($0)) }) else { return false }
        busy = true; defer { busy = false }; error = nil
        do {
            let leases = try owned.map { try writerLease($0) }
            defer { withExtendedLifetime(leases) {} }
            let updatedAccounts = accounts.filter { $0.id != id }, updatedProjects = projects.filter { $0.profileID != id }
            let change = OverleafAccountEdit.Change(accounts: try JSONEncoder().encode(updatedAccounts), projects: try JSONEncoder().encode(updatedProjects), removedProjects: owned, removedProfile: id)
            try await OverleafWebIdentity.forget(id)
            try OverleafCredential.erase(id)
            let folder = directory
            try await Task.detached { try OverleafAccountEdit.apply(change, under: folder) }.value
            accounts = updatedAccounts; projects = updatedProjects
            for project in owned {
                tags[project.id] = nil; comments[project.id] = nil; statuses[project.id] = nil; syncedAt[project.id] = nil
                automaticPaused.remove(project.id); pendingFiles.remove(project.id); unavailableTags.remove(project.id)
                UserDefaults.standard.removeObject(forKey: "overleaf.synced." + project.id.uuidString)
            }
            if let data = try? JSONEncoder().encode(tags) { try? data.write(to: directory.appendingPathComponent("project-tags.json"), options: .atomic) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func persist(_ updated: [OverleafConnection]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("projects.json"), options: .atomic)
        projects = updated
    }
    func connect(url: String, name: String, account: String, token: String) async {
        guard !busy else { return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines), existing = self.account(account)
        guard let projectID = OverleafConnection.projectID(url), !account.isEmpty, existing != nil || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter an Overleaf project link, an account label and its Git token."; return }
        if let existing, !existing.allowsGit {
            error = Self.premiumHint; return
        }
        guard !projects.contains(where: { $0.projectID == projectID && $0.account == account && $0.liveOnly != true }) else { error = "This project is already connected for that account."; return }
        busy = true; error = nil
        var project = OverleafConnection(id: UUID(), projectID: projectID, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Overleaf project" : name.trimmingCharacters(in: .whitespacesAndNewlines), account: account.trimmingCharacters(in: .whitespacesAndNewlines), branch: "master")
        if let existing { project.profileID = existing.id }
        let root = root(project)
        do {
            if existing == nil || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let saved = saveAccount(name: account, token: token) else { busy = false; return }
                project.profileID = saved.id
            }
            switch OverleafCredential.availability(project.profileID) {
            case .missing: throw OverleafGit.Failure("Add a Git token to bring this project into your library.")
            case .locked: throw OverleafGit.Failure("Unlock this account’s Git token in Keychain, then retry.")
            case .available: break
            }
            let connection = project
            project.branch = try await Task.detached { try OverleafGit.clone(connection, root: root) }.value
            try persist(projects + [project])
            statuses[project.id] = .online
        } catch {
            if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
            self.error = error.localizedDescription
        }
        busy = false
    }
    func connectLive(projectID: String, name: String, account: Account, download: ((String, UUID) async throws -> Data)? = nil) async {
        error = "Add this project with its Git link and token. Existing local copies are kept."
    }
    func rememberTags(_ catalog: [OverleafWebClient.Project], profile: UUID) {
        for project in projects where project.profileID == profile {
            if let item = catalog.first(where: { $0.id == project.projectID }) {
                if item.tagsLoaded { tags[project.id] = item.tags; unavailableTags.remove(project.id) }
                else { unavailableTags.insert(project.id) }
            }
        }
        if let data = try? JSONEncoder().encode(tags) { try? data.write(to: directory.appendingPathComponent("project-tags.json"), options: .atomic) }
    }
    func remove(_ project: OverleafConnection) {
        if warmProject?.root.path == root(project).path {
            Task { await discardWarmProject(); remove(project) }
            return
        }
        guard !busy, !liveOwned.contains(project.id) else { return }
        do {
            let writer = try writerLease(project); defer { withExtendedLifetime(writer) {} }
            let path = root(project)
            try ManuscriptReviewStore.remove(root: path)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.trashItem(at: path, resultingItemURL: nil) }
            try persist(projects.filter { $0.id != project.id })
            comments.removeValue(forKey: project.id)
            statuses.removeValue(forKey: project.id)
        } catch { self.error = error.localizedDescription }
    }
    func check(_ project: OverleafConnection, save: () -> Bool = { true }) async {
        guard allowsGit(project) else { error = Self.premiumHint; return }
        guard !busy, !liveOwned.contains(project.id), !offlineMode, !NetworkAccess.offline, hasNetwork else { return }
        busy = true; syncRevision += 1; error = nil
        let root = root(project), reviews = directory.appendingPathComponent("Reviews")
        do {
            let writer = try writerLease(project); defer { withExtendedLifetime(writer) {} }
            guard save() else { busy = false; return }
            let prepared = try await Task.detached { try OverleafGit.prepare(project, root: root, reviewRoot: reviews) }.value
            pendingFiles.remove(project.id)
            if prepared.changes.isEmpty {
                if FileManager.default.fileExists(atPath: prepared.stage.path) { try? FileManager.default.removeItem(at: prepared.stage) }
                markSynced(project.id)
            } else { review = prepared; statuses[project.id] = prepared.changes.contains(where: \.conflict) ? .conflict : .changes }
        }
        catch { statuses[project.id] = .offline; self.error = error.localizedDescription }
        busy = false
    }
    func dismissReview() {
        if let stage = review?.stage { try? FileManager.default.removeItem(at: stage) }
        review = nil
    }
    func finish(choices: [String: Bool], publish: Bool, reload: @escaping (URL) -> Void) async {
        guard let review, !busy, !liveOwned.contains(review.connection.id), !offlineMode else { return }
        guard allowsGit(review.connection) else { error = Self.premiumHint; return }
        busy = true; syncRevision += 1; error = nil
        do {
            let writer = try writerLease(review.connection); defer { withExtendedLifetime(writer) {} }
            try await Task.detached { try OverleafGit.finish(review, choices: choices, publish: publish) }.value
            let root = review.root; dismissReview(); reload(root)
            if publish || !review.localChanges { markSynced(review.connection.id) }
            else { statuses[review.connection.id] = .changes }
        } catch { self.error = error.localizedDescription; dismissReview() }
        busy = false
    }
    func markSynced(_ id: UUID) {
        automaticPaused.remove(id)
        statuses[id] = .online; syncedAt[id] = Date(); pendingFiles.remove(id)
        UserDefaults.standard.set(syncedAt[id], forKey: "overleaf.synced." + id.uuidString)
    }
    func writerLease(_ project: OverleafConnection) throws -> OverleafLiveWriterLease {
        let key = OverleafLive.Key(profile: project.profileID, project: project.projectID, document: project.projectID)
        try key.validate()
        return try OverleafLiveWriterLease(file: OverleafLiveJournal.lock(for: key, under: directory.appendingPathComponent("Live")))
    }

}
