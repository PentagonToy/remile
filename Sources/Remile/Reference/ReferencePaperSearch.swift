import SwiftUI

struct ReferencePaperSearch: View {
    @ObservedObject var model: ReferenceModel
    @ObservedObject private var network = NetworkAccessState.shared
    var target: ReferenceRecord? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var query = ""
        @Published var papers: [ReferencePaperLookup.Paper] = []
        @Published var selected: UUID?
        @Published var pdfs: [URL] = []
        @Published var fetched: ReferencePDFResolver.Found?
        @Published var includePDF = true
        @Published var loading = false
        @Published var findingPDF = false
        @Published var adding = false
        @Published var searched = false
        @Published var error: String?
        @Published var pdfMessage: String?
        var searchTask: Task<Void, Never>?
        var pdfTask: Task<Void, Never>?
        var addTask: Task<Void, Never>?
    }
    private var chosen: ReferencePaperLookup.Paper? { state.papers.first { $0.id == state.selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find a paper").font(.title2.weight(.semibold))
            if let target { Text("Attach to: " + target.displayTitle).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack {
                TextField("DOI or title", text: $state.query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button(state.loading ? "Searching…" : "Search", action: search).disabled(state.loading || state.adding || state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if state.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if state.searched && state.papers.isEmpty {
                Text("No matching papers").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.papers) { paper in
                        Button { state.selected = paper.id; findPDF(paper) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(paper.record.displayTitle).font(RemileType.callout.weight(.medium)).lineLimit(2)
                                Text([paper.record.shortContributors, paper.record.year, ReferenceColumn.publication.value(paper.record)].filter { !$0.isEmpty }.joined(separator: " · ")).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(state.selected == paper.id ? RemileStyle.accent.opacity(0.14) : RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(state.adding)
                    }
                }.padding(.vertical, 3).scrollContentGutter()
            }.frame(maxHeight: .infinity) }
            if chosen != nil {
                if state.findingPDF { HStack { ProgressView().controlSize(.small); Text("Looking for a PDF…").foregroundStyle(.secondary) }.font(RemileType.caption) }
                else if let url = state.pdfs.first {
                    HStack { Toggle("Include PDF", isOn: $state.includePDF); Spacer(); Text(url.isFileURL ? url.lastPathComponent : [url.host ?? "", state.fetched?.version ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1) }.disabled(state.adding)
                } else { Text(state.pdfMessage ?? (target == nil ? "No open PDF found. Metadata can still be added." : "No open PDF found. Search by DOI or title, or add a local PDF.")).font(RemileType.caption).foregroundStyle(.secondary) }
            }
            if let error = state.error ?? model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { state.searchTask?.cancel(); state.pdfTask?.cancel(); state.addTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                if let target { Button("Add local PDF…") { model.chooseFiles(target: target); dismiss() }.disabled(state.adding || model.busy) }
                Spacer()
                Button(state.adding ? "Adding…" : target == nil ? "Add" : "Attach PDF") { add() }.disabled(chosen == nil || state.adding || state.findingPDF || model.busy || (target != nil && (!state.includePDF || state.pdfs.isEmpty))).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 510).background(RemileStyle.background).tint(RemileStyle.accent)
            .onAppear {
                if let target { state.query = target.fields["doi"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? target.title; state.papers = [.init(record: target)]; state.selected = target.id; findPDF(.init(record: target)) }
            }
            .onDisappear { state.searchTask?.cancel(); state.pdfTask?.cancel(); state.addTask?.cancel(); state.fetched = nil; state.pdfs = [] }
    }
    private func search() {
        guard !state.loading && !state.adding else { return }
        state.pdfTask?.cancel(); state.pdfs = []; state.fetched = nil; state.selected = nil; state.error = nil; state.loading = true; state.searched = true; state.papers = []
        let query = state.query
        state.searchTask = Task { @MainActor in
            defer { state.loading = false }
            do {
                let papers = try await ReferencePaperLookup.search(query); try Task.checkCancellation()
                state.papers = papers
                if let first = papers.first { state.selected = first.id; findPDF(first) }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { state.error = error.localizedDescription } }
        }
    }
    private func findPDF(_ paper: ReferencePaperLookup.Paper) {
        state.pdfTask?.cancel(); state.pdfs = []; state.fetched = nil; state.pdfMessage = nil; state.findingPDF = true; state.includePDF = true
        let open = RemileWindows.shared.models.compactMap { $0.reader.url } + RemileWindows.shared.models.compactMap { $0.selectedHit.map { URL(fileURLWithPath: $0.path) } }
        let known = model.records.filter { $0.trashed == nil && ReferencePaperLookup.matches(paper.record, fields: $0.fields) }.flatMap(\.attachments).map { model.repository.attachmentURL($0) }
        state.pdfTask = Task { @MainActor in
            do {
                let local = try await Task.detached { try ReferencePaperLookup.localPDFs(for: paper.record, candidates: Array((open + known).prefix(20))) }.value
                try Task.checkCancellation()
                if !local.isEmpty { guard state.selected == paper.id else { return }; state.pdfs = local; state.findingPDF = false; return }
                let found = try await ReferencePDFResolver.resolve(paper.record); try Task.checkCancellation()
                guard state.selected == paper.id else { return }; state.fetched = found; state.pdfs = [found.source]; state.findingPDF = false
            } catch {
                if !Task.isCancelled && state.selected == paper.id { state.findingPDF = false; state.pdfMessage = error.localizedDescription }
            }
        }
    }
    private func add() {
        guard let paper = chosen, !state.adding else { return }
        state.adding = true; state.error = nil
        let urls = state.includePDF ? state.pdfs : []
        let fetched = state.includePDF ? state.fetched : nil
        state.addTask = Task { @MainActor in
            do {
                let pdf: Data?
                if let local = urls.first, local.isFileURL {
                    pdf = try await Task.detached { () throws -> Data in
                        guard let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ReferencePaperLookup.pdfLimit else { throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
                        let handle = try FileHandle(forReadingFrom: local); defer { try? handle.close() }
                        let data = try handle.read(upToCount: ReferencePaperLookup.pdfLimit + 1) ?? Data()
                        guard data.count <= ReferencePaperLookup.pdfLimit else { throw ReferenceFailure("Choose a PDF smaller than 25 MB.") }
                        guard try ReferencePDFResolver.validate(data, for: paper.record) else { throw ReferenceFailure("The local PDF could not be matched. Check the file before attaching it.") }
                        return data
                    }.value
                } else { pdf = fetched?.data }
                try Task.checkCancellation()
                if let target {
                    guard let pdf else { throw ReferenceFailure("Choose a PDF before attaching it.") }
                    model.attachFetched(pdf, to: target, completion: { dismiss() }, failure: { state.adding = false })
                } else { model.addFetched(paper.record, pdf: pdf, completion: { dismiss() }, failure: { state.adding = false }) }
            } catch {
                if !Task.isCancelled { state.error = error.localizedDescription; state.adding = false }
            }
        }
    }
}
