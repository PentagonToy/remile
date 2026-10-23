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
        @Published var page = 0
        @Published var loading = false
        @Published var error: String?
        @Published var editingField: String?
        @Published var draft = ""
        var saving = false
        var snapshot: ReferenceRecord?
        var generation = UUID()
    }
    private struct Loaded: @unchecked Sendable { let document: PDFDocument }
    private var attachment: ReferenceAttachment? { record.attachments.first { $0.id == (state.attachmentID ?? model.previewAttachments[record.id]) } ?? record.attachments.first }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if record.attachments.count > 1 {
                    Picker("PDF", selection: Binding(get: { attachment?.id }, set: { state.attachmentID = $0; model.previewAttachments[record.id] = $0 })) {
                        ForEach(record.attachments) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                if state.loading { ProgressView().frame(height: 150) }
                else if let document = state.document, let attachment {
                    HStack(spacing: 12) {
                        Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 30) }.disabled(state.page == 0).accessibilityLabel("Previous preview page")
                        Button { model.readingAttachment = attachment.id; openPDF(model.repository.attachmentURL(attachment), state.page) } label: {
                            if let image = document.page(at: state.page)?.thumbnail(of: NSSize(width: 150, height: 160), for: .cropBox) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 150, maxHeight: 160).shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Open PDF").remileHelp("Open PDF")
                        Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 30) }.disabled(state.page + 1 >= document.pageCount).accessibilityLabel("Next preview page")
                    }.frame(maxWidth: .infinity).frame(height: 165)
                    Text("\(state.page + 1) / \(document.pageCount)").font(RemileType.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext").font(.system(size: 24, weight: .light)).foregroundStyle(RemileStyle.accent)
                        Text(state.error ?? "No PDF attached").font(RemileType.caption).foregroundStyle(.secondary)
                        if record.trashed == nil { Button("Add PDF…", action: addFiles).buttonStyle(.borderless) }
                    }.frame(maxWidth: .infinity).frame(height: 100)
                }
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(ReferenceMetadata.rows(record).enumerated()), id: \.element.id) { index, row in
                        HStack(alignment: .top, spacing: 12) {
                            Text(row.label).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
                            if state.editingField == row.id {
                                TextField(row.label, text: $state.draft).textFieldStyle(.roundedBorder)
                                    .focused($editingFocus, equals: row.id).disabled(model.busy)
                                    .onAppear { editingFocus = row.id }
                                    .onSubmit { commit() }
                                    .onExitCommand { state.editingField = nil; state.snapshot = nil }
                                    .background(InlineEditBoundary(cancel: { state.editingField = nil; state.snapshot = nil }) { commit() })
                                    .remileHelp("Return or click elsewhere to save · Esc cancels")
                            } else {
                                Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle()).highPriorityGesture(TapGesture(count: 2).onEnded { edit(row) })
                                    .accessibilityAction(named: "Edit value") { edit(row) }
                            }
                        }.font(RemileType.caption).padding(.vertical, 7).padding(.horizontal, 2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.contextMenu {
                    Button("Copy BibTeX", systemImage: "doc.on.clipboard") { model.copy([record]) }
                    if !record.attachments.isEmpty && record.trashed == nil {
                        Button(record.attachments.count == 1 ? "Remove attachment" : "Remove attachments…", systemImage: "trash", action: removeFiles)
                    }
                }
            }.padding(14).scrollContentGutter()
        }.onDisappear { commit() }.background(RemileStyle.sidebar).task(id: attachment?.id) { await load() }
    }
    private func edit(_ row: ReferenceMetadataRow) {
        guard record.trashed == nil, !model.showingTrash, !model.busy, !state.saving, record.fields[row.id] != nil else { return }
        state.snapshot = record; state.draft = record.fields[row.id] ?? ""; state.editingField = row.id
    }
    private func commit() {
        guard var draft = state.snapshot, let field = state.editingField, !state.saving else { return }
        do {
            let value = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if field == "title", value.isEmpty { throw ReferenceFailure("Add a title before saving.") }
            draft.fields[field] = value.isEmpty ? nil : value
            _ = try ReferenceBibTeX.export([draft])
            if draft.fields == state.snapshot?.fields { state.editingField = nil; state.snapshot = nil; return }
            state.saving = true
            model.save(draft, existing: true, selectAfterSave: false, onFailure: { state.saving = false }) {
                state.saving = false; state.editingField = nil; state.snapshot = nil
            }
        } catch { model.error = error.localizedDescription }
    }
    private func move(_ offset: Int) {
        guard let document = state.document, let attachment else { return }
        state.page = min(max(0, state.page + offset), document.pageCount - 1)
        model.previewPages[attachment.id] = state.page
    }
    private func load() async {
        let generation = UUID(); state.generation = generation
        state.document = nil; state.error = nil
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
        } catch is CancellationError { }
        catch { if !Task.isCancelled { state.error = "This PDF is unavailable. Add another copy to keep reading." } }
    }
}
