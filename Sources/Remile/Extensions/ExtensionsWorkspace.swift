import AppKit
import PDFKit
import SwiftUI

@MainActor
final class RemarkableExtensionModel: ObservableObject {
    @Published var documents: [RemarkableCloudItem] = []
    @Published var connected = false
    @Published private(set) var hasSavedConnection = RemarkableCredentials.exists()
    @Published var busy = false
    @Published var error: String?
    private var received: URL?
    private var receivedFields: [String: String] = [:]
    private var receivedID: String?
    private var receivedItem: RemarkableCloudItem?
    @Published var phase = ""
    private let worker = RemarkableCloudWorker()
    private var task: Task<Void, Never>?
    private var leaving = false
    private let credentials = RemarkableCredentialSession()
    private var folder: URL?
    init() {
        if hasSavedConnection {
            UserDefaults.standard.set(true, forKey: "extensions.remarkable.connected")
        }
    }

    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        do { try RemarkableExtensionAccess.requireEnabled() } catch { self.error = error.localizedDescription; return }
        busy = true
        error = nil
        task = Task { @MainActor [weak self] in
            defer {
                self?.busy = false
                self?.task = nil
                self?.phase = ""
                if self?.leaving == true { self?.clearReceived() }
            }
            do { try await work() } catch is CancellationError {} catch { self?.error = error.localizedDescription }
        }
    }
    func connectSSH(python: String, host: String, password: String) {
        let configuration = ["transport": "ssh", "host": host, "password": password]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration),
              let code = String(data: data, encoding: .utf8) else { return }
        run { [self] in
            phase = "Connecting…"
            let result = try await worker.call(python: python, operation: "pair", code: code)
            guard let token = result.token else {
                throw ReferenceFailure("The device connection could not be saved.")
            }
            try RemarkableCredentials.save(token)
            credentials.remember(token)
            hasSavedConnection = true
            UserDefaults.standard.set(true, forKey: "extensions.remarkable.connected")
            documents = (result.documents ?? []).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            connected = true
        }
    }
    func reload(python: String, interactive: Bool = false) {
        run { [self] in try await refresh(python: python, interactive: interactive) }
    }
    private func accessToken(interactive: Bool = false) -> String? {
        credentials.read(interactive: interactive)
    }
    private func refresh(python: String, interactive: Bool = false) async throws {
        guard let token = accessToken(interactive: interactive) else {
            hasSavedConnection = RemarkableCredentials.exists()
            connected = false
            throw ReferenceFailure(
                hasSavedConnection ? "Allow access to the saved connection, then try again." : "Enter the device address and SSH password.")
        }
        phase = "Loading documents…"
        let result = try await worker.call(python: python, operation: "list", token: token)
        try Task.checkCancellation()
        documents = (result.documents ?? []).filter { UUID(uuidString: $0.id) != nil }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        connected = true
    }
    func connectFolders(_ selected: Set<String>, python: String, to references: ReferenceModel, completion: @escaping () -> Void) {
        guard !selected.isEmpty else { return }
        begin()
        run { [self] in
            try await refresh(python: python, interactive: true)
            let scopes = try RemarkableFolderSelection.scopes(selected, items: documents)
            phase = "Connecting folders…"
            let saved: Bool = await withCheckedContinuation { continuation in
                references.connectRemarkableFolders(scopes) { continuation.resume(returning: $0) }
            }
            guard saved else { throw ReferenceFailure(references.error ?? "Could not connect these folders.") }
            guard let library = references.libraries.first(where: { $0.source == "remarkable" && $0.trashed == nil }) else { throw ReferenceFailure("The connected library is unavailable.") }
            try Task.checkCancellation()
            try await syncLibrary(library, python: python, to: references)
            references.selectRemarkableLibrary()
            completion()
        }
    }
    func updateLibrary(_ library: ReferenceLibrary, python: String, to references: ReferenceModel) {
        begin()
        run { [self] in
            try await refresh(python: python, interactive: true)
            try await syncLibrary(library, python: python, to: references)
        }
    }
    private func syncLibrary(_ library: ReferenceLibrary, python: String, to references: ReferenceModel) async throws {
        let records = references.records.filter { $0.library == library.id }
        let hidden = Set(references.libraries.filter { $0.trashed != nil }.map(\.id))
        let wanted = RemarkableFolderSelection.updateIDs(library, records: records, items: documents, hidden: hidden)
        let available = Set(documents.filter { !$0.isFolder }.map(\.id))
        let chosen = wanted.intersection(available)
        let current = Dictionary(records.filter { $0.trashed == nil }.compactMap { record -> (String, String)? in
            guard let source = record.remarkable else { return nil }
            return (source.id, source.revision)
        }, uniquingKeysWith: { first, _ in first })
        let changed = Set(documents.filter { chosen.contains($0.id) && ($0.revision.isEmpty || current[$0.id] != $0.revision) }.map(\.id))
        if !changed.isEmpty { try await importSelection(changed, python: python, to: references, updating: true) }
        let unrecognised = records.filter {
            guard let source = $0.remarkable else { return false }
            return chosen.contains(source.id) && !changed.contains(source.id) && ReferenceRecognition.automaticEligible($0)
        }
        references.recognise(unrecognised)
        let folders = Set(documents.filter(\.isFolder).map(\.id)).union([RemarkableFolderScope.unfiledID])
        let missing = library.remarkableFolders?.contains { !folders.contains($0.id) } == true || !wanted.isSubset(of: available)
        references.notice = missing ? "reMarkable library updated. Unavailable sources were kept." : "reMarkable library updated."
    }
    private func importSelection(_ ids: Set<String>, python: String, to references: ReferenceModel, updating: Bool = false) async throws {
        guard let token = accessToken(interactive: true) else {
            throw ReferenceFailure("Unlock the saved reMarkable connection.")
        }
        phase = "Preparing selected documents…"
        guard !ids.isEmpty, ids.count <= 5000 else { throw ReferenceFailure("Choose documents from the current list.") }
        var items: [RemarkableCloudItem] = []
        for batch in RemarkableCloudItem.selectionBatches(ids) {
            try Task.checkCancellation()
            let reply = try await worker.call(python: python, operation: "describe", token: token, ids: batch)
            guard let described = reply.documents, described.count == batch.count, Set(described.map(\.id)) == Set(batch) else {
                throw ReferenceFailure("The selected document list changed. Try again.")
            }
            items.append(contentsOf: described)
        }
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            try RemarkableExtensionAccess.requireEnabled()
            if received == nil || receivedID != item.id || receivedItem?.revision != item.revision {
                try await download(item, python: python)
            }
            guard let file = received else { throw ReferenceFailure("The selected PDF is unavailable.") }
            phase = "Adding \(index + 1) of \(items.count)…"
            try RemarkableExtensionAccess.requireEnabled()
            let root = references.libraries.first { $0.source == "remarkable" && $0.trashed == nil }?.id
            let existing = references.records.first { $0.library == root && $0.trashed == nil && $0.remarkable?.id == item.id }
            let isNew = existing == nil
            let unrecognisedPDF = item.fileType == "pdf" && existing.map {
                ReferenceKind.classify($0) == .note || ReferencePDFMetadata.placeholderTitle($0.title, journal: $0.fields["journal"])
            } == true
            let success: Bool = await withCheckedContinuation { continuation in
                let current = RemarkableCloudItem(
                    id: item.id, title: item.title, revision: receivedItem?.revision ?? item.revision,
                    createdTime: item.createdTime, fileType: item.fileType, fields: item.fields)
                references.importRemarkable(current, file: file, fields: receivedFields, recogniseAfterImport: !updating || isNew || unrecognisedPDF) {
                    continuation.resume(returning: $0)
                }
            }
            guard success else {
                throw ReferenceFailure(references.error ?? "Could not add this document to Reference.")
            }
            clearReceived()
        }
        if !updating { references.selectRemarkableLibrary() }
    }
    private func download(_ item: RemarkableCloudItem, python: String) async throws {
        guard let token = accessToken() else {
            throw ReferenceFailure("Reconnect your reMarkable device.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remile-remarkable-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            phase = "Downloading document…"
            let reply = try await worker.call(
                python: python, operation: "receive", token: token, id: item.id, directory: directory)
            phase = "Preparing PDF…"
            let render = Task.detached(priority: .utility) {
                let file = try RemarkablePDF.render(reply, in: directory)
                var fields: [String: String] = [:]
                if let name = reply.background,
                    let pdf = PDFDocument(url: try RemarkablePDF.child(name, in: directory))
                {
                    fields = ReferencePDFMetadata.fields(pdf, fallback: item.title)
                }
                return (file, fields)
            }
            let rendered = try await withTaskCancellationHandler(
                operation: { try await render.value }, onCancel: { render.cancel() })
            try Task.checkCancellation()
            clearReceived()
            folder = directory
            received = rendered.0
            receivedFields = rendered.1
            receivedID = item.id
            receivedItem = RemarkableCloudItem(
                id: item.id, title: item.title, revision: reply.revision ?? item.revision)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func disconnect() {
        guard !busy else { return }
        do {
            try RemarkableCredentials.remove()
            credentials.clear()
            hasSavedConnection = false
            UserDefaults.standard.set(false, forKey: "extensions.remarkable.connected")
            connected = false
            documents = []
            clearReceived()
        } catch { self.error = error.localizedDescription }
    }
    func clearReceived() {
        received = nil
        receivedID = nil
        receivedFields = [:]
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
    func cancel() { task?.cancel() }
    func begin() { leaving = false }
    func leave() {
        leaving = true
        if !UserDefaults.standard.bool(forKey: RemarkableExtensionAccess.enabledKey) { credentials.clear() }
        cancel()
        if !busy { clearReceived() }
    }
}

enum RemarkableRuntime {
    static var python: String {
        let saved = UserDefaults.standard.string(forKey: "extensions.remarkable.python") ?? ""
        if !saved.isEmpty && FileManager.default.isExecutableFile(atPath: saved) { return saved }
        let installed = RemarkableToolInstaller.installedPython
        if !installed.isEmpty { return installed }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/local.remile.app/Extensions/reMarkable/Runtime/bin/python3"
            ).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : ""
    }
}

enum RemarkableExtensionSheet: String, Identifiable {
    case consent, setup, connection
    var id: String { rawValue }
}

enum ExtensionCardLayout {
    static func count(for width: CGFloat) -> Int { max(1, min(3, Int((max(0, width - 72) + 24) / 264))) }
}

struct ExtensionsWorkspace: View {
    @ObservedObject var references: ReferenceModel
    let showReference: () -> Void
    @StateObject private var cloud = RemarkableExtensionModel()
    @AppStorage(RemarkableExtensionAccess.enabledKey) private var enabled = false
    @AppStorage(RemarkableExtensionAccess.consentKey) private var consent = 0
    @State private var sheet: RemarkableExtensionSheet?
    @State private var confirming = false
    @State private var removing = false
    @State private var setupError: String?
    private var active: Bool { enabled && consent == RemarkableExtensionAccess.consentVersion }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: RemileControl.rowSpacing * 2) {
                    Text("Extensions").font(.largeTitle.weight(.semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: RemileControl.rowSpacing * 2), count: ExtensionCardLayout.count(for: geometry.size.width)), alignment: .leading, spacing: RemileControl.rowSpacing * 2) {
                        remarkableCard
                        ZoteroExtensionCard(references: references, showReference: showReference)
                    }.frame(maxWidth: 1008, alignment: .leading)
                }.padding(RemileControl.rowSpacing * 3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.contextMenu {
            if cloud.hasSavedConnection { Button("Disconnect reMarkable") { cloud.disconnect() } }
        }.sheet(item: $sheet) { page in
            switch page {
            case .consent:
                RemarkableConsent(agree: {
                    consent = RemarkableExtensionAccess.consentVersion
                    enabled = true
                    sheet = RemarkableRuntime.python.isEmpty ? .setup : nil
                }, disagree: { enabled = false; cloud.leave(); sheet = nil })
            case .setup: RemarkableSetup { sheet = nil }
            case .connection: RemarkableConnection(model: cloud, references: references, showReference: showReference)
            }
        }.alert("Turn off reMarkable?", isPresented: $confirming) {
            Button("Turn off") {
                enabled = false
                cloud.leave()
                sheet = nil
                UserDefaults.standard.removeObject(forKey: "extensions.remarkable.python")
                removing = true
                Task {
                    defer { removing = false }
                    do { try await RemarkableToolStorage.shared.removeInstalled() }
                    catch { setupError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Connection tools will be deleted. Enabling again requires a download. Imported references and PDFs will remain.") }
        .alert("Connection tools", isPresented: Binding(get: { setupError != nil }, set: { if !$0 { setupError = nil } })) {
            Button("OK") { setupError = nil }
        } message: { Text(setupError ?? "") }
    }
    private var remarkableCard: some View {
        HStack(spacing: RemileControl.spacing) {
            Button {
                if !active { sheet = .consent }
                else { sheet = RemarkableRuntime.python.isEmpty ? .setup : .connection }
            } label: {
                HStack(spacing: RemileControl.spacing) {
                    SymbolIcon(systemName: "scribble.variable")
                    Text("reMarkable").font(RemileType.heading)
                }.frame(maxWidth: .infinity, minHeight: RemileControl.toolHit, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled).remileHelp("Choose reMarkable folders")
            Toggle("reMarkable", isOn: Binding(get: { active }, set: { value in
                if !value { confirming = true }
                else if consent != RemarkableExtensionAccess.consentVersion { sheet = .consent }
                else { enabled = true; if RemarkableRuntime.python.isEmpty { sheet = .setup } }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Enable reMarkable").disabled(removing)
        }.padding(RemileControl.rowSpacing * 2).frame(maxWidth: .infinity, alignment: .leading)
            .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: RemileRadius.card))
    }
}

struct RemarkableConnection: View {
    @ObservedObject var model: RemarkableExtensionModel
    @ObservedObject var references: ReferenceModel
    let showReference: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("extensions.remarkable.python") private var python = ""
    @AppStorage("extensions.remarkable.ssh.host") private var host = ""
    @State private var password = ""
    @State private var pairing = false
    @State private var showSetup = false
    @State private var query = ""
    @State private var selection: Set<String> = []
    @AppStorage(RemarkableExtensionAccess.enabledKey) private var enabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: RemileControl.rowSpacing) {
            HStack(spacing: RemileControl.spacing) {
                Text("reMarkable").font(RemileType.heading)
                Spacer()
                connectionMenu
                Button("Done") { dismiss() }.buttonStyle(RemileActionStyle(emphasis: .quiet))
                    .keyboardShortcut(.cancelAction).disabled(working)
            }
            if model.connected {
                TextField("Find a folder", text: $query).textFieldStyle(.roundedBorder)
                RemarkableFolderPicker(items: model.documents, query: query, busy: model.busy, selection: $selection)
            } else if model.hasSavedConnection && !pairing {
                if !model.busy {
                    Button("Retry connection") { model.reload(python: python, interactive: true) }
                }
            } else {
                TextField("Device address", text: $host).textFieldStyle(.roundedBorder)
                HStack {
                    SecureField("SSH password", text: $password).onSubmit(connect)
                    Button("Connect", action: connect).disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || python.isEmpty || model.busy)
                }
                if model.hasSavedConnection {
                    Button("Use saved connection") { model.reload(python: python, interactive: true) }.disabled(
                        model.busy)
                }
            }
            if model.connected || working { connectionFooter }
            if let error = model.error ?? references.error {
                Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(
                    horizontal: false, vertical: true)
            }
        }.padding(RemileControl.rowSpacing * 2)
            .frame(width: model.connected ? 820 : 420)
            .background(RemileStyle.background).tint(RemileStyle.accent)
            .interactiveDismissDisabled(model.busy || references.busy)
            .sheet(isPresented: $showSetup, onDismiss: { python = RemarkableRuntime.python }) { RemarkableSetup { showSetup = false } }
            .task {
                model.begin()
                if python.isEmpty { python = RemarkableRuntime.python }
                let repository = references.repository
                do {
                    let saved = try await Task.detached(priority: .userInitiated) { try repository.libraries().first { $0.source == "remarkable" && $0.trashed == nil }?.remarkableFolders ?? [] }.value
                    guard !Task.isCancelled else { return }
                    selection = Set(saved.map(\.id))
                } catch { model.error = error.localizedDescription; return }
                if model.hasSavedConnection && !python.isEmpty { model.reload(python: python, interactive: true) }
            }
            .onChange(of: model.documents) { _, documents in
                let ids = Set(documents.filter(\.isFolder).map(\.id)).union([RemarkableFolderScope.unfiledID])
                selection.formIntersection(ids)
                selection = RemarkableFolderSelection.canonical(selection, items: documents)
            }
            .onChange(of: model.busy) { _, busy in
                if !busy && model.connected {
                    let ids = Set(model.documents.filter(\.isFolder).map(\.id)).union([RemarkableFolderScope.unfiledID])
                    selection.formIntersection(ids)
                }
            }
            .onChange(of: enabled) { _, active in
                if !active { model.leave(); dismiss() }
            }
            .onDisappear { model.leave() }
    }
    private var working: Bool { model.busy || references.busy }
    private var connectionMenu: some View {
        Menu {
            if model.connected {
                Button("Refresh") { model.reload(python: python, interactive: true) }.disabled(working)
                Divider()
            }
            if model.hasSavedConnection {
                Button("Change device…") { pairing = true; model.connected = false }.disabled(working)
            }
            Button("Connection tools…") { showSetup = true }.disabled(working)
        } label: {
            SymbolIcon(systemName: "ellipsis").frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                .contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Connection options").remileHelp("Connection options")
    }
    private var connectionFooter: some View {
        HStack(spacing: RemileControl.spacing) {
            if working {
                ProgressView().controlSize(.small)
                Text(model.phase.isEmpty ? "Adding to Reference…" : model.phase).font(RemileType.caption)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text(selection.count == 1 ? "1 folder" : "\(selection.count) folders")
                    .font(RemileType.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy {
                Button("Cancel") { model.cancel() }.buttonStyle(RemileActionStyle())
            } else if model.connected {
                Button("Add to Reference") {
                    model.connectFolders(selection, python: python, to: references) {
                        dismiss()
                        showReference()
                    }
                }.buttonStyle(RemileActionStyle(emphasis: .primary))
                    .disabled(selection.isEmpty || references.busy)
            }
        }.frame(minHeight: RemileControl.toolHit)
    }
    private func connect() {
        let entered = password
        password = ""
        model.connectSSH(python: python, host: host.trimmingCharacters(in: .whitespacesAndNewlines), password: entered)
    }

}
