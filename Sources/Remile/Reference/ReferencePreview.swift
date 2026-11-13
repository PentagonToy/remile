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
        @Published var requestedPage: Int?
        @Published var preview: Preview?
        @Published var failedRequest: Request?
        @Published var editingField: String?
        @Published var draft = ""
        @Published var abstractExpanded = false
        var saving = false
        var snapshot: ReferenceRecord?
        let renderer = ReferenceThumbnailRenderer()
    }
    private struct Request: Equatable {
        let attachment: UUID
        let digest: String
        let page: Int

        func matches(_ other: Request?) -> Bool {
            attachment == other?.attachment && digest == other?.digest
        }
    }
    private struct Preview {
        let request: Request
        let page: ReferenceThumbnailRenderer.Page
    }
    private var attachment: ReferenceAttachment? {
        guard let id = state.attachmentID ?? model.previewAttachments[record.id] else { return record.attachments.first }
        return record.attachments.first { $0.matches(id) } ?? record.attachments.first
    }
    var body: some View {
        let attachment = attachment
        let request = attachment.map {
            Request(attachment: $0.id, digest: $0.sha256,
                    page: state.requestedPage ?? model.previewPages[$0.id] ?? 0)
        }
        let preview = state.preview.flatMap { $0.request.matches(request) ? $0.page : nil }
        return ScrollView {
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
                    Picker("PDF", selection: Binding(get: { self.attachment?.id }, set: {
                        state.requestedPage = nil
                        state.attachmentID = $0
                        model.previewAttachments[record.id] = $0
                    })) {
                        ForEach(record.attachments) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                if let preview, let attachment {
                    let index = min(request?.page ?? preview.index, preview.count - 1)
                    HStack(spacing: RemileControl.spacing) {
                        pageButton(-1, index: index, count: preview.count, attachment: attachment.id)
                        Button { model.openAttachment(attachment, from: record, page: preview.index, openPDF: openPDF) } label: {
                            Image(decorative: preview.image, scale: 1).resizable().scaledToFit()
                                .frame(maxWidth: 150, maxHeight: 160).shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                        }.buttonStyle(.plain).accessibilityLabel("Open PDF").remileHelp("Open PDF")
                        pageButton(1, index: index, count: preview.count, attachment: attachment.id)
                    }.frame(maxWidth: .infinity).frame(height: 165)
                    Text("\(preview.index + 1) / \(preview.count)").font(RemileType.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if request != nil, request != state.failedRequest {
                    ProgressView().frame(height: 150)
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
                    if let request, request == state.failedRequest {
                        Text("This PDF is unavailable. Add another copy to keep reading.")
                            .font(RemileType.small).foregroundStyle(.secondary)
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
        }.onDisappear { commit() }.background(RemileStyle.sidebar)
            .task(id: request) { await load(request, attachment: attachment) }
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
    private func pageButton(_ offset: Int, index: Int, count: Int, attachment: UUID) -> some View {
        let next = index + offset
        let title = offset < 0 ? "Previous preview page" : "Next preview page"
        return Button {
            model.previewPages[attachment] = next
            state.requestedPage = next
        } label: {
            SymbolIcon(systemName: offset < 0 ? "chevron.left" : "chevron.right")
        }.buttonStyle(RemileToolStyle()).disabled(next < 0 || next >= count)
            .accessibilityLabel(title).remileHelp(title)
    }
    private func load(_ request: Request?, attachment: ReferenceAttachment?) async {
        guard !Task.isCancelled else { return }
        state.failedRequest = nil
        guard let request, let attachment else {
            state.preview = nil
            await state.renderer.clear()
            return
        }
        if state.preview?.request.matches(request) == false { state.preview = nil }
        let url = model.repository.attachmentURL(attachment)
        do {
            let page = try await state.renderer.render(url: url, digest: request.digest, page: request.page)
            try Task.checkCancellation()
            state.preview = Preview(request: request, page: page)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            state.preview = nil
            state.failedRequest = request
        }
    }
}

actor ReferenceThumbnailRenderer {
    struct Page: Sendable {
        let image: CGImage
        let index: Int
        let count: Int
    }

    private var source: URL?
    private var digest: String?
    private var document: PDFDocument?

    func clear() {
        guard !Task.isCancelled else { return }
        document = nil
        source = nil
        digest = nil
    }

    func render(url: URL, digest: String, page: Int) throws -> Page {
        try Task.checkCancellation()
        if url != source || digest != self.digest || document == nil {
            clear()
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let bytes, bytes <= 200_000_000,
                  let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
                throw ReferenceFailure("This PDF is unavailable.")
            }
            try Task.checkCancellation()
            document = pdf
            source = url
            self.digest = digest
        }
        guard let document else { throw ReferenceFailure("This PDF is unavailable.") }
        let count = document.pageCount
        let index = min(max(0, page), count - 1)
        try Task.checkCancellation()
        let thumbnail = document.page(at: index)?.thumbnail(of: CGSize(width: 150, height: 160), for: .cropBox)
        guard let image = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ReferenceFailure("This PDF page is unavailable.")
        }
        return Page(image: image, index: index, count: count)
    }
}
