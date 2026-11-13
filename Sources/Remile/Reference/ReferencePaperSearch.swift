import SwiftUI
import UniformTypeIdentifiers

struct ReferencePaperSearch: View {
    @ObservedObject var model: ReferenceModel
    @ObservedObject private var network = NetworkAccessState.shared
    var target: ReferenceRecord? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = Presentation()
    @FocusState private var queryFocused: Bool
    private final class Presentation: ObservableObject {
        @Published var query = ""
        @Published var papers: [ReferencePaperLookup.Paper] = []
        @Published var selected: UUID?
        @Published var pdfs: [URL] = []
        @Published var fetched: ReferencePDFResolver.Found?
        @Published var loading = false
        @Published var findingPDF = false
        @Published var adding = false
        @Published var searched = false
        @Published var error: String?
        @Published var pdfMessage: String?
        @Published var submittedLink: URL?
        @Published var publisher: ReferencePublisherSource?
        var searchTask: Task<Void, Never>?
        var pdfTask: Task<Void, Never>?
        var addTask: Task<Void, Never>?
    }
    private var chosen: ReferencePaperLookup.Paper? { state.papers.first { $0.id == state.selected } }
    private var browserSource: URL? {
        state.submittedLink ?? chosen.flatMap { ReferencePDFResolver.seeds($0.record).first?.url }
    }
    private var publisherSource: ReferencePublisherSource? {
        chosen == nil ? nil : ReferencePublisherSource(browserSource)
    }
    private var canChoosePDF: Bool {
        !state.loading && !state.findingPDF && state.pdfs.isEmpty && (chosen != nil || state.submittedLink != nil)
    }
    private var canAddCitationOnly: Bool {
        target == nil && chosen != nil && !state.loading && !state.findingPDF
    }
    private var primaryActionTitle: String {
        if state.adding { return "Adding…" }
        if !state.pdfs.isEmpty { return target == nil ? "Add PDF to Library" : "Attach PDF" }
        if canAddCitationOnly { return chosen?.record.type == "online" ? "Add Web Page" : "Add without PDF" }
        if canChoosePDF { return publisherSource != nil && !network.offline ? "Get PDF" : "Choose PDF…" }
        return "Attach PDF"
    }
    private func summary(_ record: ReferenceRecord) -> String {
        let contributors = record.shortContributors
        let source = ReferenceColumn.publication.value(record)
        return [contributors, record.year, source == contributors ? "" : source]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        Group {
            if let source = state.publisher, let paper = chosen {
                ReferencePublisherAccess(source: source, record: paper.record, close: { state.publisher = nil }) { found in
                    guard state.selected == paper.id else { return }
                    state.fetched = found
                    state.pdfs = [found.source]
                    state.pdfMessage = nil
                    state.publisher = nil
                }
            } else {
                lookup
            }
        }
        .frame(width: 740, height: 550)
        .background(RemileStyle.background).tint(RemileStyle.accent)
        .onAppear {
            if let target { state.query = target.fields["doi"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? target.title; state.papers = [.init(record: target)]; state.selected = target.id; findPDF(.init(record: target)) }
            else { queryFocused = true }
        }
        .onDisappear { state.searchTask?.cancel(); state.pdfTask?.cancel(); state.addTask?.cancel(); state.fetched = nil; state.pdfs = [] }
    }

    private var lookup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find a paper").font(.title2.weight(.semibold))
            if let target { Text("Attach to: " + target.displayTitle).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack {
                TextField("DOI, title or link", text: $state.query).textFieldStyle(.roundedBorder)
                    .focused($queryFocused).onSubmit { search() }
                Button(state.loading ? "Searching…" : "Search", action: search).disabled(state.loading || state.adding || state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if state.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if state.searched && state.papers.isEmpty {
                Text("No matching papers").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.papers) { paper in
                        Button {
                            guard state.selected != paper.id else { return }
                            state.selected = paper.id
                            findPDF(paper)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(paper.record.displayTitle).font(RemileType.callout.weight(.medium)).lineLimit(2)
                                Text(summary(paper.record)).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(state.selected == paper.id ? RemileStyle.accent.opacity(0.14) : RemileStyle.surface, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(state.adding)
                    }
                }.padding(.vertical, 3).scrollContentGutter()
            }.frame(maxHeight: .infinity) }
            if chosen != nil {
                if state.findingPDF { HStack { ProgressView().controlSize(.small); Text("Looking for a PDF…").foregroundStyle(.secondary) }.font(RemileType.caption) }
                else if let url = state.pdfs.first {
                    SymbolLabel(url.isFileURL ? url.lastPathComponent : "PDF ready", systemImage: "paperclip")
                        .font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help([url.host ?? "", state.fetched?.version ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                } else if let message = state.pdfMessage {
                    Text(message).font(RemileType.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.error ?? model.error { Text(error).font(RemileType.caption).foregroundStyle(RemileStyle.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { state.searchTask?.cancel(); state.pdfTask?.cancel(); state.addTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if canAddCitationOnly || (canChoosePDF && browserSource != nil) {
                    Menu {
                        if canChoosePDF, canAddCitationOnly, let publisher = publisherSource, !network.offline {
                            Button("Get PDF") { state.publisher = publisher }
                        }
                        if canChoosePDF, canAddCitationOnly || (publisherSource != nil && !network.offline) {
                            Button("Choose PDF…", action: chooseLocalPDF)
                        }
                        if canChoosePDF, let link = browserSource {
                            ExternalLink("Open in browser", destination: link)
                        }
                        if canAddCitationOnly, !state.pdfs.isEmpty {
                            Button("Add without PDF") { add(includePDF: false) }
                        }
                    } label: { SymbolIcon(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(RemileStyle.ink)
                        .frame(width: RemileControl.toolHit, height: RemileControl.toolHit)
                        .accessibilityLabel("More actions").remileHelp("More actions")
                        .disabled(state.adding || model.busy)
                }
                if canAddCitationOnly || canChoosePDF || !state.pdfs.isEmpty {
                    Button(primaryActionTitle) {
                        if !state.pdfs.isEmpty {
                            add(includePDF: true)
                        } else if canAddCitationOnly {
                            add(includePDF: false)
                        } else if let publisher = publisherSource, !network.offline {
                            state.publisher = publisher
                        } else {
                            chooseLocalPDF()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.adding || model.busy)
                }
            }
        }.padding(24)
    }
    private func search() {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.loading, !state.adding, !query.isEmpty else { return }
        queryFocused = false
        state.pdfTask?.cancel(); state.pdfs = []; state.fetched = nil; state.selected = nil; state.error = nil; state.loading = true; state.searched = true; state.papers = []
        state.submittedLink = nil; state.findingPDF = false; state.pdfMessage = nil
        state.searchTask = Task { @MainActor in
            defer { state.loading = false }
            do {
                if let scheme = URLComponents(string: query)?.scheme?.lowercased(), ["https", "http", "file"].contains(scheme),
                   !ReferenceDuplicates.normaliseDOI(query).hasPrefix("10.") {
                    guard query.utf8.count <= 16_384, let url = URL(string: query), ReferencePaperLookup.publicURL(url) else {
                        throw ReferenceFailure("Enter a public HTTPS link.")
                    }
                    state.submittedLink = url
                    let publisherPaper: ReferencePaperLookup.Paper?
                    if let target, ReferencePublisherSource(url) != nil {
                        publisherPaper = .init(record: target)
                    } else {
                        publisherPaper = target == nil ? try? await ReferencePaperLookup.publisherPaper(at: url) : nil
                    }
                    try Task.checkCancellation()
                    if let paper = publisherPaper {
                        state.papers = [paper]; state.selected = paper.id
                        findPDF(paper, startingAt: url)
                    } else {
                        let (record, found) = try await ReferencePDFResolver.fromLink(url, target: target)
                        try Task.checkCancellation()
                        state.papers = [.init(record: record)]; state.selected = record.id
                        state.fetched = found; state.pdfs = found.map { [$0.source] } ?? []
                    }
                    return
                }
                let papers = try await ReferencePaperLookup.search(query); try Task.checkCancellation()
                state.papers = papers
                if let first = papers.first { state.selected = first.id; findPDF(first) }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { state.error = state.submittedLink == nil ? error.localizedDescription : (error as? ReferenceFailure)?.localizedDescription ?? "The link could not be opened. Try it in your browser." } }
        }
    }
    private func findPDF(_ paper: ReferencePaperLookup.Paper, startingAt url: URL? = nil) {
        state.pdfTask?.cancel(); state.pdfs = []; state.fetched = nil; state.pdfMessage = nil; state.findingPDF = true
        let open = RemileWindows.shared.models.compactMap { $0.reader.url } + RemileWindows.shared.models.compactMap { $0.selectedHit.map { URL(fileURLWithPath: $0.path) } }
        let known = model.records.filter { $0.trashed == nil && ReferencePaperLookup.matches(paper.record, fields: $0.fields) }.flatMap(\.attachments).map { model.repository.attachmentURL($0) }
        state.pdfTask = Task { @MainActor in
            do {
                let local = try await Task.detached { try ReferencePaperLookup.localPDFs(for: paper.record, candidates: Array((open + known).prefix(20))) }.value
                try Task.checkCancellation()
                guard state.selected == paper.id else { return }
                if !local.isEmpty {
                    state.pdfs = local; state.findingPDF = false; return
                }
                if !NetworkAccess.offline, let publisher = ReferencePublisherSource(url) {
                    state.findingPDF = false; state.publisher = publisher; return
                }
                let found = try await ReferencePDFResolver.resolve(paper.record, startingAt: url); try Task.checkCancellation()
                guard state.selected == paper.id else { return }; state.fetched = found; state.pdfs = [found.source]; state.findingPDF = false
            } catch {
                guard !Task.isCancelled, state.selected == paper.id else { return }
                state.findingPDF = false
                state.pdfMessage = state.submittedLink == nil ? error.localizedDescription : (error as? ReferenceFailure)?.localizedDescription ?? "No accessible PDF found. Try it in your browser."
            }
        }
    }
    private func chooseLocalPDF() {
        guard let paper = chosen else { model.chooseFiles(target: target); dismiss(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.pdfMessage = nil; state.findingPDF = true
        state.pdfTask = Task { @MainActor in
            do {
                let bytes = try await Task.detached { try ReferencePDFResolver.readLocal(url, for: paper.record) }.value
                try Task.checkCancellation()
                guard state.selected == paper.id else { return }
                state.fetched = .init(data: bytes, source: url, version: "")
                state.pdfs = [url]; state.findingPDF = false
            } catch {
                guard !Task.isCancelled, state.selected == paper.id else { return }
                state.pdfMessage = error.localizedDescription; state.findingPDF = false
            }
        }
    }

    private func add(includePDF: Bool) {
        guard let paper = chosen, !state.adding, !includePDF || !state.pdfs.isEmpty else { return }
        state.adding = true; state.error = nil
        let urls = includePDF ? state.pdfs : []
        let fetched = includePDF ? state.fetched : nil
        state.addTask = Task { @MainActor in
            do {
                let pdf: Data?
                if let fetched { pdf = fetched.data }
                else if let local = urls.first, local.isFileURL {
                    pdf = try await Task.detached { try ReferencePDFResolver.readLocal(local, for: paper.record) }.value
                } else { pdf = nil }
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
