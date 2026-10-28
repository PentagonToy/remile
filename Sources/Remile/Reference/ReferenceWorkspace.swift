import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ReferenceWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var network = NetworkAccessState.shared
    @ObservedObject var model: ReferenceModel
    let goHome: () -> Void
    var openPDF: (URL, Int) -> Void = { _, _ in }
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var paneReset = UUID()
        @Published var editor: Entry?
        @Published var cleanup = false
        @Published var metadata: ReferenceRecord?
        @Published var paperSearch = false
        @Published var paperTarget: ReferenceRecord?
        @Published var storageID = UUID()
        @Published var windowTarget = false
        @Published var attachments: ReferenceRecord?
        @Published var evidence: ReferenceRecord?
        @Published var dropTarget = false
        @Published var hoveredRecord: UUID?
        @Published var harbourTarget = false
        @Published var previewTarget = false
        @Published var widths = ReferenceColumnWidths.decode(UserDefaults.standard.string(forKey: ReferenceColumnWidths.preference) ?? "{}")
        var widthStarts: [String: Double] = [:]
        @Published var settings = false
        @Published var regenerate = false
        @Published var addingLibrary = false
        @Published var renamingLibrary: ReferenceLibrary?
        @Published var libraryName = ""
        var nameDraftID = UUID()
        var savingName = false
        @Published var deletingLibrary: ReferenceLibrary?
        @Published var duplicateReview: DuplicateGroup?
        @Published var parentLibrary: UUID?
        @Published var emptyTrash = false
    }
    @FocusState private var namingLibrary: Bool
    @AppStorage(ReferenceColumnWidths.preference) private var savedWidths = "{}"
    @AppStorage(ReferenceColumn.preference) private var columnSource = ReferenceColumn.defaults
    @AppStorage("reference.libraryExpanded") private var libraryExpanded = true
    @AppStorage("reference.libraryExpanded.defaultOpen") private var libraryDefaultApplied = false
    @AppStorage("reference.harbourExpanded") private var harbourExpanded = true
    private struct Entry: Identifiable { let id = UUID(); var record: ReferenceRecord?; var citation = "" }
    private struct DuplicateGroup: Identifiable { let id = UUID(); let records: [ReferenceRecord] }
    private var toolbar: some View {
        HStack(spacing: RemileControl.spacing) {
            Button(action: goHome) { SymbolIcon(systemName: "chevron.left") }.buttonStyle(RemileToolStyle()).accessibilityLabel("Back to Home").remileHelp("Back to Home")
            Text("Reference").font(RemileType.heading)
            Spacer()
            Menu {
                Button("Find a paper…") { model.error = nil; state.paperTarget = nil; state.paperSearch = true }
                Button("Import files…") { model.chooseFiles() }
                Button("Add manually…") { model.error = nil; state.editor = Entry() }
                Button("Paste BibTeX…") { model.error = nil; state.editor = Entry(citation: NSPasteboard.general.string(forType: .string) ?? "") }
            } label: { SymbolLabel("Add", systemImage: "plus") }.fixedSize()
            Button { model.undo() } label: { SymbolIcon(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).accessibilityLabel("Undo").remileHelp("Undo the last Reference change")
            Button { model.undo(redo: true) } label: { SymbolIcon(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).accessibilityLabel("Redo").remileHelp("Redo the last Reference change")
            Button { model.error = nil; state.cleanup = true } label: { SymbolLabel("Clean up", systemImage: "wand.and.stars") }.disabled(model.libraryRecords.filter { $0.trashed == nil }.isEmpty || model.showingTrash || model.busy)
            Button { state.regenerate = true } label: { SymbolLabel("Keys", systemImage: "key") }.disabled(model.libraryRecords.allSatisfy { $0.trashed != nil }).remileHelp("Regenerate library citation keys")
        }.font(RemileType.control).buttonStyle(RemileToolStyle()).padding(.horizontal, 16).padding(.vertical, 6).disabled(model.busy)
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar.labelStyle(.iconOnly)
            Divider()
            GeometryReader { window in
                let side = WorkspaceLayout.referenceSide(window.size.width)
                ReaderSplit(initial: side, minimum: 180, maximum: 380, minimumContent: 480, label: "reference libraries", revealToken: state.paneReset.uuidString, pane: { sidebar }, content: {
                    GeometryReader { geometry in
                        if geometry.size.width < 700 {
                            VStack(spacing: 0) { list; Divider(); preview.frame(height: geometry.size.height * 0.48) }
                        } else {
                            ReaderSplit(side: .trailing, initial: side, minimum: 180, maximum: 420, minimumContent: 380, label: "reference preview", revealToken: state.paneReset.uuidString, pane: { preview }, content: { list })
                        }
                    }
                })
            }
            if model.recognising {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up reference details…").font(RemileType.caption)
                    Spacer()
                    Button("Cancel") { model.cancelRecognition() }
                }.padding(8).background(RemileStyle.editorBar)
            }
            if model.busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8) }
            if let error = model.error {
                HStack { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { SymbolIcon(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message") }.padding(10).background(RemileStyle.editorBar)
            }
        }.focusedSceneValue(\.workspaceActions, WorkspaceActions(restorePanes: { state.paneReset = UUID() }))
        .font(RemileType.control).background(RemileStyle.background).tint(RemileStyle.accent)
            .overlay(Color.black.opacity(draggingFiles ? 0.10 : 0).allowsHitTesting(false))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: draggingFiles)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.windowTarget) { receive($0) }
            .onChange(of: savedWidths) { state.widths = ReferenceColumnWidths.decode(savedWidths) }
            .onAppear { ReferenceColumn.applyDefaults(); if !libraryDefaultApplied { libraryExpanded = true; libraryDefaultApplied = true } }
            .task(id: state.storageID) { await model.watch() }
            .onReceive(NotificationCenter.default.publisher(for: StoragePaths.changed)) { _ in state.storageID = UUID(); model.load() }
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: libraryExpanded)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: harbourExpanded)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: state.addingLibrary)
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: model.showingTrash)
            .alert("Regenerate library citation keys?", isPresented: $state.regenerate) {
                Button("Cancel", role: .cancel) { }
                Button("Regenerate all") { model.regenerate() }
            } message: { Text("Citation keys may change. You may need to update citations in existing documents. References in Trash stay unchanged.") }
            .alert("Delete library?", isPresented: Binding(get: { state.deletingLibrary != nil }, set: { if !$0 { state.deletingLibrary = nil } })) {
                Button("Cancel", role: .cancel) { state.deletingLibrary = nil }
                Button("Delete library", role: .destructive) { if let library = state.deletingLibrary { model.deleteLibrary(library) }; state.deletingLibrary = nil }
            } message: { Text("Delete ‘\(state.deletingLibrary?.name ?? "")’ and its metadata? Its references and PDFs move to Reference Trash. Emptying Trash permanently removes its metadata and PDFs that are not used elsewhere.") }
            .alert("Empty Reference Trash?", isPresented: $state.emptyTrash) {
                Button("Cancel", role: .cancel) { }
                Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            } message: { Text("Permanently delete all references, libraries and collections in Trash? Their metadata and unshared PDFs cannot be recovered. PDFs used by active references stay in place.") }
            .sheet(item: $state.attachments) { record in ReferenceAttachments(model: model, recordID: record.id) }
            .sheet(item: $state.evidence) { record in ReferenceEvidenceView(record: record) }
            .sheet(isPresented: $state.paperSearch) { ReferencePaperSearch(model: model, target: state.paperTarget) }
            .sheet(item: $state.metadata) { record in ReferenceCleanupReview(model: model, target: record) }
            .sheet(isPresented: $state.cleanup) { ReferenceCleanupReview(model: model) }
            .sheet(item: $state.editor) { entry in ReferenceEditor(model: model, record: entry.record, citation: entry.citation) }
            .sheet(item: $state.duplicateReview) { group in ReferenceDuplicateReview(model: model, records: group.records) }
    }
    private func addLibrary(parent: UUID? = nil) {
        state.nameDraftID = UUID(); state.savingName = false; state.renamingLibrary = nil
        state.libraryName = ""; state.parentLibrary = parent; state.addingLibrary = true; libraryExpanded = true
    }
    private func renameLibrary(_ library: ReferenceLibrary) {
        state.nameDraftID = UUID(); state.savingName = false; state.addingLibrary = false
        state.libraryName = library.name; state.parentLibrary = library.parentID; state.renamingLibrary = library; libraryExpanded = true
    }
    private func cancelLibraryName() {
        state.nameDraftID = UUID(); state.addingLibrary = false; state.renamingLibrary = nil
        state.libraryName = ""; state.parentLibrary = nil; state.savingName = false; namingLibrary = false
    }
    private func saveLibraryName() {
        guard state.addingLibrary || state.renamingLibrary != nil, !state.savingName else { return }
        guard !InlineNamePolicy.isEmpty(state.libraryName) else { cancelLibraryName(); return }
        guard !model.busy else { return }
        let name = state.libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == state.renamingLibrary?.name { cancelLibraryName(); return }
        let id = state.nameDraftID
        state.savingName = true
        let finished = { if state.nameDraftID == id { cancelLibraryName() } }
        let failed = { if state.nameDraftID == id { state.savingName = false; namingLibrary = true } }
        if let library = state.renamingLibrary { model.renameLibrary(library, to: name, failure: failed, completion: finished) }
        else { model.addLibrary(name, parentID: state.parentLibrary, failure: failed, completion: finished) }
    }
    private var draggingFiles: Bool { !model.showingTrash && (state.windowTarget || state.dropTarget || state.hoveredRecord != nil || state.harbourTarget || state.previewTarget) }
    private func rowTarget(_ id: UUID) -> Binding<Bool> {
        Binding(get: { state.hoveredRecord == id }, set: { active in
            if active { state.hoveredRecord = id }
            else if state.hoveredRecord == id { state.hoveredRecord = nil }
        })
    }
    private func receive(_ providers: [NSItemProvider], target: ReferenceRecord? = nil, pdfOnly: Bool = false) -> Bool {
        guard !model.busy, !model.showingTrash, target?.trashed == nil else { return false }
        let library = model.selectedLibrary
        state.windowTarget = false; state.dropTarget = false; state.hoveredRecord = nil; state.harbourTarget = false; state.previewTarget = false
        HomeFileDrop.receive(providers) { urls in
            guard !pdfOnly || (!urls.isEmpty && urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" })) else { model.error = "Drop PDFs here. Use Add to import BibTeX."; return }
            model.importFiles(urls, target: target, libraryID: library, matchingExisting: true)
        }
        return true
    }
    private var harbour: some View {
        VStack(spacing: 14) {
            if let image = RemileArtwork.image("harbour-focus", dark: scheme == .dark) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 90).accessibilityHidden(true)
            }
            Text("Drop PDFs or BibTeX").font(RemileType.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(14)
            .background(RemileStyle.accent.opacity(draggingFiles ? 0.22 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RemileStyle.accent.opacity(draggingFiles ? 0.95 : 0.24), style: StrokeStyle(lineWidth: 1, dash: state.harbourTarget ? [] : [4, 4])))
            .shadow(color: RemileStyle.accent.opacity(draggingFiles ? 0.32 : 0), radius: 14)
            .contentShape(Rectangle()).accessibilityLabel("Harbour. Drop PDFs or BibTeX into the selected library")
            .remileHelp("Add PDFs or BibTeX to the selected library. Exact PDF matches attach to an existing reference.")
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.harbourTarget) { receive($0) }
            .animation(reduceMotion ? nil : RemileMotion.disclosure, value: draggingFiles)
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            GeometryReader { available in
            let square = max(100, available.size.width - 40)
            let harbourHeight = harbourExpanded ? square + 64 : 44
            let libraryHeight = max(44, available.size.height - harbourHeight)
            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup("Library", isExpanded: $libraryExpanded) {
                        ForEach(model.activeLibraries.filter { $0.parentID == nil }) { library in
                            libraryRow(library)
                            ForEach(model.activeLibraries.filter { $0.parentID == library.id }) { collection in libraryRow(collection).padding(.leading, 18) }
                            if state.addingLibrary && state.parentLibrary == library.id { libraryNameField.padding(.leading, 18) }
                        }
                        if state.addingLibrary && state.parentLibrary == nil { libraryNameField }
                        Button { model.showingTrash = true; model.selected = model.items.first?.id; model.selectedIDs = Set([model.selected].compactMap { $0 }) } label: {
                            HStack { SymbolLabel("Trash", systemImage: "trash"); Spacer(); Text(String(model.trashRecords.count)).foregroundStyle(.secondary) }.padding(10).background(model.showingTrash ? RemileStyle.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).contextMenu {
                            Button("Empty Trash…", systemImage: "trash", role: .destructive) { state.emptyTrash = true }.disabled(model.busy)
                        }
                        if model.showingTrash {
                            ForEach(model.deletedLibraries) { library in
                                Button { } label: { SymbolLabel(library.name, systemImage: "folder").padding(8).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).foregroundStyle(.secondary).contextMenu {
                                    Button("Restore", systemImage: "arrow.uturn.backward") { model.restoreLibrary(library.id) }
                                }
                            }
                        }
                    }.font(RemileType.callout).padding(10)
                }.scrollContentGutter().frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu { Button("Add library…", systemImage: "folder.badge.plus") { addLibrary() } }
            }.frame(height: libraryHeight)
                .contextMenu { Button("Add library…", systemImage: "folder.badge.plus") { addLibrary() } }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup("Harbour", isExpanded: $harbourExpanded) { EmptyView() }
                    .font(RemileType.callout).padding(10).frame(height: 44)
                    .foregroundStyle(draggingFiles ? RemileStyle.accent : RemileStyle.ink)
                if harbourExpanded {
                    Group {
                        if !model.showingTrash { harbour.frame(width: square, height: square) }
                        else { Color.clear.frame(width: square, height: square) }
                    }.frame(maxWidth: .infinity).padding(.bottom, 20)
                }
            }.frame(height: harbourHeight, alignment: .top)
            }
            }
            Divider()
            EditorSidebarFooter(compact: libraryExpanded || harbourExpanded, title: "Settings") { state.settings.toggle() }
                .accessibilityLabel("Reference settings").remileHelp("Reference settings")
                .popover(isPresented: $state.settings, arrowEdge: .trailing) { ReferenceSettings() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(RemileStyle.sidebar)
    }
    private var libraryNameField: some View {
        let id = state.nameDraftID
        let save = { if state.nameDraftID == id { saveLibraryName() } }
        let cancel = { if state.nameDraftID == id { cancelLibraryName() } }
        return TextField(state.parentLibrary == nil ? "Library name" : "Collection name", text: $state.libraryName)
            .textFieldStyle(.roundedBorder).focused($namingLibrary).padding(6)
            .onAppear { DispatchQueue.main.async { if state.nameDraftID == id { namingLibrary = true } } }
            .disabled(model.busy)
            .background(InlineEditBoundary(cancel: cancel, outside: save))
            .onSubmit { save() }
            .onExitCommand(perform: cancel)
            .onDisappear(perform: save)
            .remileHelp("Return or click elsewhere to save · Esc cancels")
            .id(id)
    }
    private func libraryRow(_ library: ReferenceLibrary) -> some View {
        let count = model.libraryCounts[library.id, default: 0]
        return Group {
        if state.renamingLibrary?.id == library.id { libraryNameField }
        else { Button { model.selectLibrary(library.id) } label: {
            HStack { SymbolLabel(library.name, systemImage: library.parentID == nil ? "tray.full" : "folder").lineLimit(1); Spacer(minLength: 2); Text(String(count)).font(RemileType.caption).foregroundStyle(.secondary) }
                .padding(10).background(model.selectedLibrary == library.id && !model.showingTrash ? RemileStyle.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAction(named: "Rename") { renameLibrary(library) }
        }
        }.contextMenu {
            let records = model.contents(library.id).filter { $0.trashed == nil }
            Button("Add library…", systemImage: "folder.badge.plus") { addLibrary() }
            if library.parentID == nil { Button("Add collection…", systemImage: "folder.badge.plus") { addLibrary(parent: library.id) } }
            Button("Rename…", systemImage: "square.and.pencil") { renameLibrary(library) }
            Divider()
            Button("Copy library as BibTeX", systemImage: "doc.on.clipboard") { model.copy(records) }.disabled(records.isEmpty)
            Button("Export library as BibTeX…", systemImage: "square.and.arrow.up") { model.export(records) }.disabled(records.isEmpty)
            Divider()
            Button(library.parentID == nil ? "Delete library…" : "Delete collection…", systemImage: "trash", role: .destructive) { state.deletingLibrary = library }
        }.disabled(model.busy)
    }
    private var list: some View {
        VStack(spacing: 0) {
            TextField("Find a reference", text: $model.query).textFieldStyle(.roundedBorder).padding(14)
            GeometryReader { geometry in
            let visible = ReferenceColumn.visible(columnSource)
            let fitted = ReferenceColumnWidths.fitted(available: geometry.size.width, columns: visible, saved: state.widths)
            let others = visible.filter { $0 != .title }.reduce(0.0) { $0 + (fitted[$1.rawValue] ?? $1.width) }
            let overhead = Double(80 + visible.count * 10)
            let titleWidth = fitted["title"] ?? 180
            ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
            columns(widths: fitted).font(RemileType.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.trailing, ScrollContentSpacing.gutter).padding(.bottom, 8)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 12) {
                    SymbolIcon(systemName: model.showingTrash ? "trash" : "books.vertical").foregroundStyle(RemileStyle.accent)
                    Text(model.showingTrash ? "No deleted references" : model.query.isEmpty ? "A place for your references" : "No matching references").font(RemileType.heading)
                    if !model.showingTrash && model.query.isEmpty { Text("Save a PDF in your browser, then drop it here. You can also import BibTeX.").font(RemileType.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    ScrollView { LazyVStack(alignment: .leading, spacing: 2) { ForEach(model.items) { record in row(record, widths: fitted).id(record.id) } }.padding(10).scrollContentGutter() }
                        .onAppear { if let id = model.selected { scroll.scrollTo(id) } }
                }
            }
            }.frame(width: max(geometry.size.width, titleWidth + others + overhead), height: geometry.size.height)
            }
            }.coordinateSpace(name: "reference.columns")
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .overlay(Rectangle().strokeBorder(RemileStyle.accent.opacity(state.dropTarget ? 0.6 : 0), lineWidth: 2).allowsHitTesting(false))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.dropTarget) { providers in
                receive(providers)
            }
    }
    private func row(_ record: ReferenceRecord, widths: [String: Double]) -> some View {
        Button { let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags; model.select(record.id, extending: flags.contains(.command), range: flags.contains(.shift)) } label: {
            HStack(spacing: 10) {
                ReferenceKindIcon(kind: .classify(record), hasAttachment: !record.attachments.isEmpty).frame(width: 22)
                columnCells(record, widths: widths)
            }.font(RemileType.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                .background(model.selectedIDs.contains(record.id) ? RemileStyle.accent.opacity(0.18) : model.duplicates[record.id] != nil ? RemileStyle.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .opacity(draggingFiles && state.hoveredRecord != record.id ? 0.6 : 1)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(RemileStyle.accent.opacity(state.hoveredRecord == record.id ? 1 : 0), lineWidth: 2).allowsHitTesting(false))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: draggingFiles)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: state.hoveredRecord)
            .contextMenu {
            let chosen = model.contextRecords(record)
            Button("Copy BibTeX", systemImage: "doc.on.clipboard") { model.copy(chosen) }
            Button("Export BibTeX…", systemImage: "square.and.arrow.up") { model.export(chosen) }
            Divider()
            if record.trashed != nil { Button("Restore", systemImage: "arrow.uturn.backward") { if let library = model.libraries.first(where: { ($0.id == record.library || $0.id == record.collectionID) && $0.trashed != nil }) { model.restoreLibrary(library.id) } else { model.trash(record, restore: true) } } }
            else {
                Button("Look up metadata", systemImage: "arrow.triangle.2.circlepath") { model.recognise(model.contextRecords(record)) }.disabled(network.offline || model.busy || !model.contextRecords(record).contains(where: ReferenceRecognition.eligible))
                    .remileHelp(network.offline ? "Turn off Work offline to look up metadata." : "Fill missing fields by DOI, arXiv ID or exact title. Keep existing values.")
                Button("Read metadata…", systemImage: "doc.text.viewfinder") { state.metadata = record }
                Button("Find a paper…", systemImage: "doc.text.magnifyingglass") { model.error = nil; state.paperTarget = record; state.paperSearch = true }
                Button("View source", systemImage: "doc.text.magnifyingglass") { state.evidence = record }.disabled(model.showingTrash)
                Button("Edit…", systemImage: "square.and.pencil") { model.error = nil; state.editor = Entry(record: record) }
                Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(record) }
                if model.activeLibraries.count > 1 {
                    Menu("Add to library") { ForEach(model.activeLibraries.filter { $0.parentID == nil && $0.id != record.library }) { library in Button(library.name) { model.duplicate(record, to: library.id) } } }
                }
                if model.activeLibraries.contains(where: { $0.parentID == record.library }) {
                    Menu("Move to collection") {
                        Button("Library") { model.move(record, to: nil) }
                        ForEach(model.activeLibraries.filter { $0.parentID == record.library }) { collection in Button(collection.name) { model.move(record, to: collection.id) } }
                    }
                }
                if chosen.count > 1 {
                    Button("Merge selected…", systemImage: "square.stack") {
                        if let records = model.selectedDuplicates(record) { state.duplicateReview = DuplicateGroup(records: records) }
                    }.disabled(model.selectedDuplicates(record) == nil)
                } else if let ids = model.duplicates[record.id] {
                    Button("Review duplicates…", systemImage: "square.stack") { state.duplicateReview = DuplicateGroup(records: model.records.filter { ids.contains($0.id) }) }
                }
                Button("Regenerate citation key", systemImage: "key") { model.regenerate(record) }
                if chosen.count > 1 {
                    Button("Lock citation key") { model.setKeyLock(chosen, locked: true) }
                    Button("Unlock citation key") { model.setKeyLock(chosen, locked: false) }
                } else {
                    Button(record.citationKeyLocked == true ? "Unlock citation key" : "Lock citation key") {
                        model.setKeyLock([record], locked: record.citationKeyLocked != true)
                    }
                }
                Button("Add files…", systemImage: "paperclip") { model.chooseFiles(target: record) }
                if !record.attachments.isEmpty { Button(record.attachments.count == 1 ? "Remove attachment" : "Remove attachments…", systemImage: "paperclip.badge.ellipsis") { removeAttachments(record) } }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { model.trash(record) }
            }
        }.disabled(model.busy)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: rowTarget(record.id)) { receive($0, target: record, pdfOnly: true) }
    }
    private func columns(widths: [String: Double]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { Color.clear.frame(width: 22, height: 1); columnCells(nil, widths: widths) }
    }
    @ViewBuilder private func columnCells(_ record: ReferenceRecord?, widths: [String: Double]) -> some View {
        let columns = ReferenceColumn.visible(columnSource)
        ForEach(columns) { column in
            let fitted = widths[column.rawValue] ?? column.width
            Group {
                if let record { Text(column.displayedValue(record)).foregroundStyle(column == .title ? RemileStyle.ink : .secondary) }
                else {
                    Button { model.sort(by: column) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(column == .author && fitted < 110 ? "Author" : column == .publication && fitted < 145 ? "Publication" : column.label)
                            if model.sorting.column == column { SymbolIcon(systemName: model.sorting.ascending ? "chevron.up" : "chevron.down").foregroundStyle(RemileStyle.accent) }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(column.label)
                        .accessibilityValue(model.sorting.column == column ? (model.sorting.ascending ? "Ascending" : "Descending") : "Not sorted")
                        .remileHelp("Sort by " + column.label)
                }
            }.frame(width: fitted, alignment: record.map { column.value($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true ? .center : .leading)
                .overlay(alignment: .trailing) {
                    if record == nil { resize(column, current: fitted) }
                }
        }
    }

    private func resize(_ column: ReferenceColumn, current: Double) -> some View {
        Color.clear.frame(width: 12, height: 28).contentShape(Rectangle())
            .overlay(Rectangle().fill(RemileStyle.ink.opacity(0.15)).frame(width: 1, height: 12))
            .background(ResizeCursorRegion())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("reference.columns")).onChanged { event in
                if state.widthStarts[column.rawValue] == nil { state.widthStarts[column.rawValue] = current }
                state.widths[column.rawValue] = ReferenceColumnWidths.clamp((state.widthStarts[column.rawValue] ?? current) + event.translation.width, column: column)
            }.onEnded { _ in
                state.widthStarts[column.rawValue] = nil; savedWidths = ReferenceColumnWidths.encode(state.widths)
            })
            .onTapGesture(count: 2) { state.widths[column.rawValue] = nil; savedWidths = ReferenceColumnWidths.encode(state.widths) }
            .accessibilityElement().accessibilityLabel("Resize " + column.label).accessibilityValue("\(Int(current)) points")
            .accessibilityAdjustableAction { direction in
                state.widths[column.rawValue] = ReferenceColumnWidths.clamp(current + (direction == .increment ? 20 : -20), column: column)
                savedWidths = ReferenceColumnWidths.encode(state.widths)
            }.remileHelp("Resize " + column.label)
    }
    private func removeAttachments(_ record: ReferenceRecord) {
        model.error = nil
        if record.attachments.count == 1 { model.removeAttachments(Set(record.attachments.map(\.id)), from: record) }
        else { state.attachments = record }
    }
    @ViewBuilder private var preview: some View {
        if let record = model.selection {
            ReferencePreview(record: record, model: model, openPDF: openPDF, addFiles: { model.chooseFiles(target: record) }, removeFiles: { removeAttachments(record) }).id(record.id)
                .overlay(Rectangle().strokeBorder(RemileStyle.accent.opacity(state.previewTarget ? 0.8 : 0), lineWidth: 2).allowsHitTesting(false))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.previewTarget) { receive($0, target: record, pdfOnly: true) }
        } else { Text("Select a reference").font(RemileType.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
