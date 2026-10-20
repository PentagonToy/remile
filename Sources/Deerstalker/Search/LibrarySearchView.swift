import SwiftUI

struct LibrarySearchView: View {
    @ObservedObject var model: HomeModel
    let open: (URL) -> Void
    var goHome: (() -> Void)? = nil
    private var assistant: DocumentAssistant { model.assistant }
    @StateObject private var citationState = CitationState()
    private final class CitationState: ObservableObject { @Published var focus: AssistantCitation? }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: Binding<String?> {
        Binding(get: { model.selectedHit?.id }, set: { id in model.selectResult(model.results.first { $0.id == id }) })
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                preview
                if model.askPresented {
                    AssistantPanel(assistant: assistant, passages: assistantHits.map(\.assistantPassage), topic: model.query, select: { source in
                        if let hit = model.results.first(where: { $0.id == source.location.id }) { model.selectResult(hit) }
                        else if let folder = model.summary.folders.first(where: { source.location.path.hasPrefix($0.path + "/") }) {
                            model.selectResult(LibraryHit(path: source.location.path, folderID: folder.id, page: source.location.unit, excerpt: source.text, score: 0, sectionTitle: source.location.label))
                        } else { model.error = "This source is no longer in the library."; return }
                        citationState.focus = AssistantCitation(location: source.location, text: source.text)
                    }) { toggleAssistant() }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }.sheet(isPresented: $model.libraryPresented) { LibraryManager(model: model) }
            .onDisappear { model.cancelExploration() }
            .onChange(of: model.exploring) { if model.exploring { assistant.cancel() } }
            .onChange(of: model.query) { assistant.cancel(); citationState.focus = nil }
            .onChange(of: model.libraryRevision) { assistant.cancel(); citationState.focus = nil }
            .onChange(of: model.documentFilter) { assistant.cancel(); citationState.focus = nil }
            .onChange(of: model.results.map(\.id)) { assistant.cancel(); citationState.focus = nil }
            .onChange(of: model.selectedHit?.id) { if citationState.focus?.location.id != model.selectedHit?.id { citationState.focus = nil } }
            .background(DeerStyle.background).tint(DeerStyle.accent).frame(minWidth: model.askPresented ? 1160 : 940, minHeight: 640)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let goHome {
                Button(action: goHome) { Label("Home", systemImage: "chevron.left") }.buttonStyle(DeerPressStyle()).help("Back to Home")
            }
            Text("Search").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your library", text: $model.query).textFieldStyle(.plain)
                    .onChange(of: model.query) { model.search() }.onSubmit { model.search() }
                if model.searching || model.exploring { ProgressView().controlSize(.small) }
                if !model.query.isEmpty { Button { model.query = ""; model.search() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search") }
            }.padding(11).background(DeerStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            if model.exploring { Button("Stop", action: model.cancelExploration) }
            else { Button { model.explore() } label: { Label("Explore", systemImage: "sparkle.magnifyingglass") }.disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.summary.folders.isEmpty).help("Find related concepts with on-device Apple Intelligence") }
            Button { toggleAssistant() } label: { Label("Ask", systemImage: "sparkles") }.help("Ask about search results · Apple Intelligence")
            Button { model.libraryPresented = true } label: { Label("Library", systemImage: "books.vertical") }.help("Manage indexed folders")
        }.padding(18)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.summary.folders.count) \(model.summary.folders.count == 1 ? "folder" : "folders")")
                Spacer()
                Text("\(model.summary.documents) documents")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 14)
            if model.indexing {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).padding(.horizontal, 14)
                    Text(progress.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 14)
                } else { ProgressView("Preparing index…").controlSize(.small).padding(.horizontal, 14) }
            }
            if model.exploring { ProgressView("Exploring concepts…").controlSize(.small).padding(.horizontal, 14) }
            if !model.exploredQueries.isEmpty {
                HStack {
                    Label("Related results", systemImage: "sparkles").help(model.exploredQueries.joined(separator: " · "))
                    Spacer(); Button("Keywords") { model.search() }.buttonStyle(.plain)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            if !model.spellingSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Did you mean?").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.spellingSuggestions, id: \.self) { suggestion in Button(suggestion) { model.query = suggestion; model.search() }.buttonStyle(.bordered) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            if let error = model.queryError { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14) }
            if model.summary.folders.isEmpty {
                ContentUnavailableView { Label("Build your library", systemImage: "books.vertical") } actions: {
                    Button("Add to Library…", action: model.addFolder).buttonStyle(.borderedProminent)
                }
            } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search your library", systemImage: "text.magnifyingglass")
            } else if model.searching {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.results.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                HStack {
                    Text("\(model.resultGroups.count) \(model.resultGroups.count == 1 ? "document" : "documents") · \(model.visibleHits.count) \(model.visibleHits.count == 1 ? "match" : "matches")")
                    Spacer()
                    if model.results.count == 200 { Text("Top 200") }
                    Picker("Sort matches", selection: $model.resultOrder) {
                        ForEach(SearchResultOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize().help("Sort matches")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                if model.resultGroups.isEmpty {
                    ContentUnavailableView("No matching documents", systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    ScrollViewReader { proxy in
                        List(selection: selection) {
                            ForEach(model.resultGroups) { group in
                                DisclosureGroup(isExpanded: Binding(get: { model.expandedDocuments.contains(group.path) }, set: { expanded in
                                    if expanded { model.expandedDocuments.insert(group.path) } else { model.expandedDocuments.remove(group.path) }
                                })) {
                                    ForEach(group.hits) { hit in
                                        HStack {
                                            Text(hit.location).font(.callout.weight(model.selectedHit?.id == hit.id ? .semibold : .regular))
                                            Spacer()
                                            if let rank = group.rank(for: hit) { rankBadge(rank) }
                                            if model.selectedHit?.id == hit.id { Image(systemName: "arrow.right").font(.caption).foregroundStyle(DeerStyle.accent) }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(model.selectedHit?.id == hit.id ? DeerStyle.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                            .contentShape(Rectangle()).onTapGesture { model.selectResult(hit) }.tag(hit.id)
                                            .help(hit.excerpt).accessibilityElement(children: .ignore).accessibilityLabel("\(hit.name), \(hit.location), relevance position \(group.rank(for: hit) ?? 0)")
                                    }
                                } label: {
                                    Button { model.selectResult(group.hits.first) } label: {
                                        HStack(spacing: 10) {
                                            if let hit = group.hits.first { SearchCover(hit: hit, revision: model.libraryRevision) }
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(alignment: .top, spacing: 6) {
                                                    Text(group.name).font(.headline).lineLimit(2)
                                                    Spacer(minLength: 0)
                                                    rankBadge(group.bestRank, best: true)
                                                }
                                                Text("\(group.hits.count) \(group.hits.count == 1 ? "match" : "matches") · \(group.hits.first?.isMarkdown == true ? "Markdown" : "PDF")").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(.vertical, 8).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(group.path).accessibilityLabel("\(group.name), best relevance position \(group.bestRank), \(group.hits.count) matches")
                                }
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                            .animation(reduceMotion ? nil : DeerMotion.panel, value: model.expandedDocuments)
                            .onChange(of: model.selectedHit?.id) { _, id in
                                if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                            }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter documents", text: $model.documentFilter).textFieldStyle(.plain).onChange(of: model.documentFilter) { model.filterDocuments() }
                    if !model.documentFilter.isEmpty { Button { model.documentFilter = ""; model.filterDocuments() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(10).background(DeerStyle.surface, in: RoundedRectangle(cornerRadius: 8)).padding([.horizontal, .bottom], 10)

            }
        }.frame(minWidth: 260, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
    }
    private var preview: some View {
        VStack(spacing: 0) {
            if let position = model.resultPosition {
                HStack {
                    Text("Result \(position + 1) of \(model.visibleHits.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.moveResult(-1) } label: { Image(systemName: "chevron.up") }.disabled(position == 0).help("Previous result").accessibilityLabel("Previous result")
                    Button { model.moveResult(1) } label: { Image(systemName: "chevron.down") }.disabled(position + 1 == model.visibleHits.count).help("Next result").accessibilityLabel("Next result")
                }.padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if model.selectedHit?.isMarkdown == true {
                SearchMarkdownPreview(hit: model.selectedHit!, query: model.selectedHit?.matchQuery ?? model.query, revision: model.libraryRevision, open: open, citation: activeCitation)
            } else { SearchPDFPreview(hit: model.selectedHit, query: model.selectedHit?.matchQuery ?? model.query, revision: model.libraryRevision, open: open, citation: activeCitation) }
        }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rankBadge(_ rank: Int, best: Bool = false) -> some View {
        Text(best ? "Best #\(rank)" : "#\(rank)")
            .font(.caption2.weight(.medium)).monospacedDigit().fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(rank <= 3 ? DeerStyle.accent : DeerStyle.ink.opacity(0.7))
            .background(DeerStyle.accent.opacity(rank <= 3 ? 0.16 : 0.07), in: Capsule())
            .help("Relevance position \(rank)").accessibilityHidden(true)
    }

    private var activeCitation: AssistantCitation? {
        guard citationState.focus?.location.id == model.selectedHit?.id else { return nil }
        return citationState.focus
    }

    private var assistantHits: [LibraryHit] {
        guard let selected = model.selectedHit else { return model.visibleHits }
        return [selected] + model.visibleHits.filter { $0.id != selected.id }
    }

    private func toggleAssistant() {
        if model.askPresented { assistant.cancel() }
        withAnimation(reduceMotion ? nil : DeerMotion.panel) { model.askPresented.toggle() }
    }

}
