import SwiftUI

struct ReferencePaperSearch: View {
    @ObservedObject var model: ReferenceModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var query = ""
        @Published var papers: [ReferencePaperLookup.Paper] = []
        @Published var selected: UUID?
        @Published var pdfs: [URL] = []
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
            HStack {
                TextField("DOI or title", text: $state.query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button(state.loading ? "Searching…" : "Search", action: search).disabled(state.loading || state.adding || state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(spacing: 8) {
                    if state.searched && state.papers.isEmpty && !state.loading { Text("No matching papers").foregroundStyle(.secondary).padding(40) }
                    ForEach(state.papers) { paper in
                        Button { state.selected = paper.id; findPDF(paper) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(paper.record.displayTitle).font(RemileType.callout.weight(.medium)).lineLimit(2)
                                Text([ReferenceText.shortAuthors(paper.record.authors), paper.record.year, ReferenceColumn.publication.value(paper.record)].filter { !$0.isEmpty }.joined(separator: " · ")).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(state.selected == paper.id ? RemileStyle.accent.opacity(0.14) : RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(state.adding)
                    }
                }.padding(.vertical, 3).scrollContentGutter()
            }.frame(maxHeight: .infinity)
            if chosen != nil {
                if state.findingPDF { HStack { ProgressView().controlSize(.small); Text("Looking for an open PDF…").foregroundStyle(.secondary) }.font(RemileType.caption) }
                else if let url = state.pdfs.first {
                    HStack { Toggle("Include PDF", isOn: $state.includePDF); Spacer(); Text(url.host ?? "").font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1) }.disabled(state.adding)
                } else { Text(state.pdfMessage ?? "No open PDF found. Metadata can still be added.").font(RemileType.caption).foregroundStyle(.secondary) }
            }
            if let error = state.error ?? model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { state.searchTask?.cancel(); state.pdfTask?.cancel(); state.addTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                Text("Crossref · OpenAlex").font(RemileType.small).foregroundStyle(.secondary)
                Button(state.adding ? "Adding…" : "Add") { add() }.disabled(chosen == nil || state.adding || state.findingPDF || model.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 510).background(RemileStyle.background).tint(RemileStyle.accent)
            .onDisappear { state.searchTask?.cancel(); state.pdfTask?.cancel(); state.addTask?.cancel() }
    }
    private func search() {
        guard !state.loading && !state.adding else { return }
        state.pdfTask?.cancel(); state.pdfs = []; state.selected = nil; state.error = nil; state.loading = true; state.searched = true; state.papers = []
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
        state.pdfTask?.cancel(); state.pdfs = []; state.pdfMessage = nil; state.findingPDF = true; state.includePDF = true
        state.pdfTask = Task { @MainActor in
            do {
                let urls = try await ReferencePaperLookup.openPDFs(doi: paper.record.fields["doi"] ?? ""); try Task.checkCancellation()
                guard state.selected == paper.id else { return }; state.pdfs = urls; state.findingPDF = false
            } catch {
                if !Task.isCancelled && state.selected == paper.id { state.findingPDF = false; state.pdfMessage = "PDF lookup unavailable. Metadata can still be added." }
            }
        }
    }
    private func add() {
        guard let paper = chosen, !state.adding else { return }
        state.adding = true; state.error = nil
        let urls = state.includePDF ? state.pdfs : []
        state.addTask = Task { @MainActor in
            do {
                let pdf = urls.isEmpty ? nil : try await ReferencePaperLookup.download(urls)
                try Task.checkCancellation()
                model.addFetched(paper.record, pdf: pdf, completion: { dismiss() }, failure: { state.adding = false })
            } catch {
                if !Task.isCancelled { state.error = error.localizedDescription; state.adding = false }
            }
        }
    }
}
