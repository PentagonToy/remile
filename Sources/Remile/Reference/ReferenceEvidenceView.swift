import SwiftUI
import PDFKit

/// A source sheet leaves the manuscript, caret and scroll position in place.
struct ReferenceEvidenceView: View {
    let record: ReferenceRecord
    var format: ReferenceCitation.Format = .latex
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    @StateObject private var assistant = DocumentAssistant()
    @MainActor private final class Presentation: ObservableObject {
        @Published var attachment: UUID?
        @Published var data: Data?
        @Published var url: URL?
        @Published var error: String?
        @Published var loading = false
        @Published var ask = false
        @Published var passages: [ReferencePassage] = []
        @Published var saving = false
        @Published var message: String?
        var saveTask: Task<Void, Never>?
        let reader = ReferencePDFReader()
        let context = PDFAssistantContext()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Reference").font(.title2.weight(.semibold)); Spacer(); Button("Done") { assistant.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
            Text(record.displayTitle).font(.headline).textSelection(.enabled)
            Text([record.displayContributors, record.year, record.citationKey].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if record.attachments.isEmpty { Text("No verified PDF attached to this entry.").foregroundStyle(.secondary) }
            else {
                HStack {
                    Picker("PDF", selection: $state.attachment) {
                        Text("Choose an attachment").tag(Optional<UUID>.none)
                        ForEach(record.attachments) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button { state.ask.toggle() } label: { Label("Ask about source", systemImage: "sparkles") }
                }
            }
            if let error = state.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            if state.loading { ProgressView() }
            HStack {
                Button("Save selected passage") { savePassage() }.disabled(state.data == nil || state.saving)
                Button("Copy citation") {
                    do {
                        let citation = try ReferenceCitation.text(record, format: format)
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(citation, forType: .string)
                        state.message = "Citation copied."
                    } catch { state.message = error.localizedDescription }
                }
                if state.saving { ProgressView().controlSize(.small) }
                if let message = state.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if !state.passages.isEmpty {
                DisclosureGroup("Saved passages (\(state.passages.count))") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.passages) { passage in
                                Button {
                                    guard record.attachments.contains(where: { $0.id == passage.attachment && $0.sha256 == passage.sha256 }) else { state.message = "The saved PDF is no longer attached."; return }
                                    state.reader.pending = passage
                                    if state.attachment == passage.attachment { state.reader.reveal(passage) }
                                    else { state.attachment = passage.attachment }
                                } label: {
                                    Text("PDF page \(passage.page) · " + passage.text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.trailing, 18)
                    }.frame(maxHeight: 120)
                }
            }
            HStack(spacing: 0) {
                if let data = state.data { ReferencePDFPreview(data: data, reader: state.reader, source: record.attachments.first(where: { $0.id == state.attachment })).id(state.attachment).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView("Source preview", systemImage: "doc.richtext").frame(maxWidth: .infinity, maxHeight: .infinity) }
                if state.ask {
                    Divider()
                    AssistantPanel(assistant: assistant, passages: [], topic: record.displayTitle, select: { state.reader.go($0.location.unit) }, close: { state.ask = false }, retrieve: { question in
                        guard let data = state.data, let url = state.url else {
                            return [AssistantPassage(location: .init(path: "reference:" + record.id.uuidString, unit: 0, label: "Bibliographic metadata only"), text: "Metadata only, not evidence of the paper's findings.\n" + (try ReferenceExport.bibtex([record])))]
                        }
                        let selected = (try? state.reader.selection()).flatMap { selection in state.reader.view?.currentSelection?.string.map { (page: selection.page, text: $0) } }
                        return try await state.context.passages(data: data, password: "", path: url.path, question: question, currentPage: state.reader.page, selection: selected, progress: { _ in })
                    }).frame(width: 350)
                }
            }
            Text("Read-only source. Ask sends retrieved passages to the selected AI provider when you submit a question.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 780, idealWidth: 1000, minHeight: 580, idealHeight: 700).background(RemileStyle.background).tint(RemileStyle.accent)
            .task {
                do {
                    let id = record.id
                    let worker = Task.detached(priority: .userInitiated) { try ReferencePassages.list(recordID: id) }
                    let passages = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    if !Task.isCancelled { state.passages = passages }
                } catch { if !Task.isCancelled, !record.attachments.isEmpty { state.message = error.localizedDescription } }
            }
            .task(id: state.attachment) {
                assistant.useHistory("reference:" + record.id.uuidString + ":" + (state.attachment?.uuidString ?? "metadata")); state.data = nil; state.url = nil; state.error = nil
                guard let id = state.attachment else { state.loading = false; return }
                state.loading = true
                do {
                    let recordID = record.id
                    let worker = Task.detached(priority: .userInitiated) { try ReferenceEvidence.attachment(recordID: recordID, attachmentID: id) }
                    let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    state.data = loaded.data; state.url = loaded.url
                } catch { if !Task.isCancelled { state.error = error.localizedDescription } }
                if !Task.isCancelled { state.loading = false }
            }.onDisappear { assistant.cancel(); state.saveTask?.cancel(); state.reader.view?.document = nil; state.data = nil; state.url = nil }
    }
    private func savePassage() {
        do {
            let selected = try state.reader.selection()
            guard let id = state.attachment, let attachment = record.attachments.first(where: { $0.id == id }) else { return }
            state.saving = true; state.message = nil
            state.saveTask = Task { @MainActor in
                do {
                    let recordID = record.id
                    let worker = Task.detached(priority: .userInitiated) { try ReferencePassages.save(recordID: recordID, attachmentID: id, expectedSHA256: attachment.sha256, page: selected.page, range: selected.range) }
                    let passage = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    if !Task.isCancelled {
                        if !state.passages.contains(where: { $0.id == passage.id }) { state.passages.append(passage) }
                        state.message = "Passage saved."
                    }
                } catch { if !Task.isCancelled { state.message = error.localizedDescription } }
                state.saving = false; state.saveTask = nil
            }
        } catch { state.message = error.localizedDescription }
    }
}
@MainActor final class ReferencePDFReader {
    weak var view: PDFView?
    var pending: ReferencePassage?
    var source: ReferenceAttachment?
    var page: Int { guard let view, let current = view.currentPage, let document = view.document else { return 1 }; return document.index(for: current) + 1 }
    func go(_ page: Int) { if let document = view?.document, let target = document.page(at: max(0, page - 1)) { view?.go(to: target) } }
    func selection() throws -> (page: Int, range: NSRange) {
        guard let document = view?.document, document.allowsCopying, let selected = view?.currentSelection, selected.pages.count == 1, let page = selected.pages.first, selected.numberOfTextRanges(on: page) == 1 else { throw ReferenceFailure("Select a passage on one PDF page.") }
        return (document.index(for: page) + 1, selected.range(at: 0, on: page))
    }
    func reveal(_ passage: ReferencePassage) {
        guard source?.id == passage.attachment, source?.sha256 == passage.sha256, let document = view?.document, passage.page > 0, passage.page <= document.pageCount, let page = document.page(at: passage.page - 1), let raw = page.string as NSString?, passage.start >= 0, passage.length > 0, passage.start <= raw.length, passage.length <= raw.length - passage.start,
              raw.substring(with: NSRange(location: passage.start, length: passage.length)) == passage.text else { return }
        go(passage.page)
        view?.setCurrentSelection(page.selection(for: NSRange(location: passage.start, length: passage.length)), animate: false)
        view?.scrollSelectionToVisible(nil); pending = nil
    }
}
struct ReferencePDFPreview: NSViewRepresentable {
    let data: Data
    let reader: ReferencePDFReader
    var source: ReferenceAttachment? = nil
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data); reader.view = view; reader.source = source
        if let pending = reader.pending { reader.reveal(pending) }
        return view
    }
    // Attachment changes remove and recreate this view. Streaming Ask updates must not compare PDF bytes.
    func updateNSView(_ view: PDFView, context: Context) {}
    static func dismantleNSView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
