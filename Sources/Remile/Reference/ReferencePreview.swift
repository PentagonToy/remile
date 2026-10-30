import SwiftUI
import PDFKit

struct ReferencePreview: View {
    let record: ReferenceRecord
    @ObservedObject var model: ReferenceModel
    let openPDF: (URL, Int) -> Void
    let addFiles: () -> Void
    var removeFiles: () -> Void = {}
    @StateObject private var state = Presentation()
    @FocusState private var editingFocus: String?
    private final class Presentation: ObservableObject {
        @Published var attachmentID: UUID?
        @Published var document: PDFDocument?
        @Published var thumbnail: NSImage?
        @Published var page = 0
        @Published var loading = false
        @Published var error: String?
        @Published var editingField: String?
        @Published var draft = ""
        @Published var abstractExpanded = false
        var saving = false
        var snapshot: ReferenceRecord?
        var generation = UUID()
    }
    private struct Loaded: @unchecked Sendable { let document: PDFDocument }
    private var attachment: ReferenceAttachment? {
        guard let id = state.attachmentID ?? model.previewAttachments[record.id] else { return record.attachments.first }
        return record.attachments.first { $0.matches(id) } ?? record.attachments.first
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                titleHeading
                let linked = model.linkedRemarkable(record)
                if !linked.isEmpty {
                    VStack(alignment: .leading, spacing: RemileControl.spacing) {
                        Text("reMarkable").font(RemileType.caption).foregroundStyle(.secondary)
                        ForEach(linked) { source in
                            HStack {
                                Button {
                                    model.selectLibrary(source.library)
                                    model.selected = source.id; model.selectedIDs = [source.id]
                                } label: { SymbolLabel(source.displayTitle, systemImage: "scribble.variable").lineLimit(2) }
                                    .buttonStyle(.plain).remileHelp("View reMarkable notes")
                                Spacer(minLength: 0)
                            }.contextMenu {
                                Button("Disconnect") { model.connectRemarkable(source, to: record, disconnect: true) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()

                if record.attachments.count > 1 {
                    Picker("PDF", selection: Binding(get: { attachment?.id }, set: { state.attachmentID = $0; model.previewAttachments[record.id] = $0 })) {
                        ForEach(record.attachments) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                if state.loading { ProgressView().frame(height: 150) }
                else if let document = state.document, let attachment {
                    HStack(spacing: 12) {
                        Button { move(-1) } label: { SymbolIcon(systemName: "chevron.left").frame(width: 24, height: 30) }.disabled(state.page == 0).accessibilityLabel("Previous preview page")
                        Button { model.openAttachment(attachment, from: record, page: state.page, openPDF: openPDF) } label: {
                            if let image = state.thumbnail {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 150, maxHeight: 160).shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Open PDF").remileHelp("Open PDF")
                        Button { move(1) } label: { SymbolIcon(systemName: "chevron.right").frame(width: 24, height: 30) }.disabled(state.page + 1 >= document.pageCount).accessibilityLabel("Next preview page")
                    }.frame(maxWidth: .infinity).frame(height: 165)
                    Text("\(state.page + 1) / \(document.pageCount)").font(RemileType.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        SymbolIcon(systemName: "paperclip").accessibilityHidden(true)
                        Text("Attachment").font(RemileType.small)
                        Spacer(minLength: 4)
                        if record.trashed == nil {
                            Button("Attach…", action: addFiles).buttonStyle(RemileActionStyle(emphasis: .quiet))
                                .remileHelp("Attach a local PDF to this reference")
                        }
                    }.foregroundStyle(RemileStyle.secondaryInk).frame(maxWidth: .infinity).padding(.vertical, 4)
                    if let error = state.error {
                        Text(error).font(RemileType.small).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                VStack(spacing: 0) {
                    ForEach(ReferenceMetadata.rows(record).filter { $0.id != "title" }) { row in
                        if row.id == "abstract" {
                            DisclosureGroup("Abstract", isExpanded: $state.abstractExpanded) {
                                Text(row.value).font(RemileType.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).lineSpacing(3).padding(.top, 6)
                            }.font(RemileType.caption).padding(.vertical, 10)
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Text(row.label).font(RemileType.small).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(width: 78, alignment: .trailing)
                                if row.id == "kind", record.trashed == nil, !model.showingTrash {
                                    Menu {
                                        ForEach(ReferenceKind.allCases, id: \.self) { kind in
                                            Button(kind.label) { model.save(kind.applying(to: record), existing: true, selectAfterSave: false) }
                                        }
                                    } label: {
                                        Text(row.value).frame(maxWidth: .infinity, alignment: .leading)
                                    }.menuStyle(.borderlessButton).disabled(model.busy || state.editingField != nil || state.saving)
                                        .accessibilityLabel("Type").remileHelp("Change reference type")
                                } else if state.editingField == row.id {
                                    TextField(row.label, text: $state.draft).textFieldStyle(.roundedBorder)
                                        .focused($editingFocus, equals: row.id).disabled(model.busy)
                                        .onAppear { editingFocus = row.id }
                                        .onSubmit { commit() }
                                        .onExitCommand { state.editingField = nil; state.snapshot = nil }
                                        .background(InlineEditBoundary(cancel: { state.editingField = nil; state.snapshot = nil }) { commit() })
                                        .remileHelp("Return or click elsewhere to save · Esc cancels")
                                } else {
                                    Text(row.value).textSelection(.enabled).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle()).highPriorityGesture(TapGesture(count: 2).onEnded { edit(row) })
                                        .accessibilityAction(named: "Edit value") { edit(row) }
                                }
                            }.font(RemileType.caption).padding(.vertical, 7).padding(.horizontal, 2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.contextMenu {
                    Button("Copy BibTeX", systemImage: "doc.on.clipboard") { model.copy([record]) }
                    if !record.attachments.isEmpty && record.trashed == nil {
                        Button(record.attachments.count == 1 ? "Remove attachment" : "Remove attachments…", systemImage: "trash", action: removeFiles)
                    }
                }
            }.padding(14).scrollContentGutter()
        }.onDisappear { commit() }.background(RemileStyle.sidebar).task(id: attachment.map { $0.id.uuidString + ":" + $0.sha256 }) { await load() }
    }
    private var titleHeading: some View {
                Group {
                    if state.editingField == "title" {
                        TextField("Title", text: $state.draft, axis: .vertical).textFieldStyle(.roundedBorder)
                            .focused($editingFocus, equals: "title").disabled(model.busy)
                            .onAppear { editingFocus = "title" }.onSubmit { commit() }
                            .onExitCommand { state.editingField = nil; state.snapshot = nil }
                            .background(InlineEditBoundary(cancel: { state.editingField = nil; state.snapshot = nil }) { commit() })
                    } else {
                        Text(record.displayTitle).textSelection(.enabled)
                            .contentShape(Rectangle()).highPriorityGesture(TapGesture(count: 2).onEnded { editTitle() })
                            .accessibilityAction(named: "Edit title") { editTitle() }
                    }
                }.font(.system(size: 15, weight: .medium)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)

    }
    private func editTitle() {
        if let row = ReferenceMetadata.rows(record).first(where: { $0.id == "title" }) { edit(row) }
    }
    private func edit(_ row: ReferenceMetadataRow) {
        guard record.trashed == nil, !model.showingTrash, !model.busy, !state.saving, row.id == "key" || record.fields[row.id] != nil else { return }
        state.snapshot = record; state.draft = row.id == "key" ? record.citationKey : record.fields[row.id] ?? ""; state.editingField = row.id
    }
    private func commit() {
        guard var draft = state.snapshot, let field = state.editingField, !state.saving else { return }
        do {
            let value = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if field == "title", value.isEmpty { throw ReferenceFailure("Add a title before saving.") }
            if field == "key" {
                guard !value.isEmpty, ReferenceBibTeX.validToken(value) else { throw ReferenceFailure("Enter a valid citation key.") }
                draft.key = value
            } else { draft.fields[field] = value.isEmpty ? nil : value }
            _ = try ReferenceBibTeX.export([draft])
            if draft.fields == state.snapshot?.fields && draft.key == state.snapshot?.key { state.editingField = nil; state.snapshot = nil; return }
            state.saving = true
            model.save(draft, existing: true, selectAfterSave: false, renameKey: field == "key", onFailure: { state.saving = false }) {
                state.saving = false; state.editingField = nil; state.snapshot = nil
            }
        } catch { model.error = error.localizedDescription }
    }
    private func move(_ offset: Int) {
        guard let document = state.document, let attachment else { return }
        state.page = min(max(0, state.page + offset), document.pageCount - 1)
        model.previewPages[attachment.id] = state.page
        refreshThumbnail()
    }
    private func refreshThumbnail() {
        state.thumbnail = state.document?.page(at: state.page)?.thumbnail(of: NSSize(width: 150, height: 160), for: .cropBox)
    }
    private func load() async {
        let generation = UUID(); state.generation = generation
        state.document = nil; state.thumbnail = nil; state.error = nil
        guard let attachment else { state.loading = false; return }
        let url = model.repository.attachmentURL(attachment); state.loading = true
        defer { if state.generation == generation { state.loading = false } }
        do {
            let worker = Task.detached(priority: .userInitiated) { () throws -> Loaded in
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? Int.max) <= 200_000_000, let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw ReferenceFailure("This PDF is unavailable.") }
                try Task.checkCancellation(); return Loaded(document: pdf)
            }
            let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); guard state.generation == generation else { return }
            state.document = loaded.document; state.page = min(model.previewPages[attachment.id] ?? 0, loaded.document.pageCount - 1)
            refreshThumbnail()
        } catch is CancellationError { }
        catch { if !Task.isCancelled { state.error = "This PDF is unavailable. Add another copy to keep reading." } }
    }
}
