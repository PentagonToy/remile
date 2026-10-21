import SwiftUI

struct LibrarySearchView: View {
    @AppStorage("assistant.provider") private var assistantProvider = "Apple Intelligence"
    @AppStorage(SearchBoostPolicy.preference) private var boostingEnabled = true
    @ObservedObject private var network = NetworkAccessState.shared
    @AppStorage(SearchQuestion.spellingPreference) private var offerCorrections = true
    @ObservedObject var model: HomeModel
    let open: (URL) -> Void
    var goHome: (() -> Void)? = nil
    private var assistant: DocumentAssistant { model.assistant }
    @StateObject private var citationState = CitationState()
    private final class CitationState: ObservableObject { @Published var focus: AssistantCitation?; @Published var selectedPassages: [AssistantPassage] = []; @Published var compactPreview = false; @Published var settingsPresented = false }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: Binding<String?> {
        Binding(get: { model.selectedHit?.id }, set: { id in selectResult(model.results.first { $0.id == id }) })
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                if model.searching || model.exploring {
                    SearchWaitingView(startedAt: model.searchStartedAt).frame(width: geometry.size.width, height: geometry.size.height)
                } else if geometry.size.width < 780 {
                    VStack(spacing: 0) {
                        Picker("Search pane", selection: $citationState.compactPreview) { Text("Results").tag(false); Text("Preview").tag(true) }.labelsHidden().pickerStyle(.segmented).padding(10)
                        if citationState.compactPreview { previewAndAsk } else { sidebar }
                    }
                } else { ReaderSplit(initial: 300, minimum: 260, maximum: 360, minimumContent: model.askPresented ? 820 : 480, label: "search results", pane: { sidebar }, content: { previewAndAsk }) }
            }
        }.sheet(isPresented: $model.libraryPresented) { LibraryManager(model: model) }
            .sheet(isPresented: $citationState.settingsPresented) { searchSettings }
            .onChange(of: boostingEnabled) { model.invalidateSearch() }
            .onChange(of: network.offline) { model.invalidateSearch() }
            .onChange(of: assistantProvider) { model.invalidateSearch() }
            .onChange(of: offerCorrections) { model.invalidateSearch() }
            .onChange(of: model.resultOrder) { model.filterDocuments() }
            .onAppear { model.resumeSearch() }
            .onDisappear { model.cancelExploration() }
            .onChange(of: model.exploring) { if model.exploring { assistant.cancel() } }
            .onChange(of: model.query) { assistant.cancel(); citationState.focus = nil; citationState.selectedPassages = []; citationState.compactPreview = false }
            .onChange(of: model.libraryRevision) { assistant.cancel(); citationState.focus = nil; citationState.selectedPassages = [] }
            .onChange(of: model.documentFilter) { assistant.cancel(); citationState.focus = nil }
            .onChange(of: model.results.map(\.id)) { assistant.cancel(); citationState.focus = nil }
            .onChange(of: model.selectedHit?.path) { citationState.selectedPassages = [] }
            .onChange(of: model.selectedHit?.id) { if citationState.focus?.location.id != model.selectedHit?.id { citationState.focus = nil } }
            .background(RemileStyle.background).tint(RemileStyle.accent).frame(minWidth: 560, minHeight: 450)
    }

    private var searchSettings: some View {
        VStack(spacing: 0) {
            HStack { Text("Search settings").font(.title2.weight(.semibold)); Spacer(); Button("Done") { citationState.settingsPresented = false }.keyboardShortcut(.cancelAction) }.padding(22)
            Divider()
            LibrarySearchSettings()
        }.frame(width: 540, height: 600).background(RemileStyle.background).tint(RemileStyle.accent)
    }

    @ViewBuilder private var previewAndAsk: some View {
        if model.askPresented {
            ReaderSplit(side: .trailing, initial: 360, minimum: 320, maximum: 440, minimumContent: 480, preferPaneWhenNarrow: true, label: "Ask panel", pane: { searchAssistant }, content: { preview })
        } else { preview }
    }
    private var searchAssistant: some View {
        AssistantPanel(assistant: assistant, passages: citationState.selectedPassages + assistantHits.map(\.assistantPassage).filter { passage in !citationState.selectedPassages.contains { $0.id == passage.id } }, topic: model.query, select: { source in
            if let hit = model.results.first(where: { $0.id == source.location.id }) { model.selectResult(hit) }
            else if let folder = model.summary.folders.first(where: { source.location.path.hasPrefix($0.path + "/") }) {
                model.selectResult(LibraryHit(path: source.location.path, folderID: folder.id, page: source.location.unit, excerpt: source.text, score: 0, sectionTitle: source.location.label))
            } else { model.error = "This source is no longer in the library."; return }
            citationState.focus = AssistantCitation(location: source.location, text: source.text)
        }, close: { toggleAssistant() }, retrieve: { question in
            let hits = assistantHits
            let context = assistantProvider == "ChatGPT" && AIUsage.shared.reason == nil ? try await model.index.answerContext(hits) : hits
            let ranked = AssistantRetrieval.rank(context.map(\.assistantPassage), question: question)
            return citationState.selectedPassages + ranked.filter { passage in !citationState.selectedPassages.contains { $0.id == passage.id } }
        }, selection: citationState.selectedPassages.isEmpty ? nil : citationState.selectedPassages.map(\.text).joined(separator: "\n"), clearSelection: { citationState.selectedPassages = [] })
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { homeButton; Text("Search").font(.title2.weight(.semibold)); queryField; aiActions; libraryButton }
            VStack(spacing: 10) {
                HStack { homeButton; Text("Search").font(.title2.weight(.semibold)); Spacer(); libraryButton }
                HStack(spacing: 10) { queryField; aiActions.labelStyle(.iconOnly) }
            }
        }.padding(18)
    }
    @ViewBuilder private var homeButton: some View {
            if let goHome {
                Button(action: goHome) { Label("Home", systemImage: "chevron.left") }.buttonStyle(RemilePressStyle()).remileHelp("Back to Home")
            }
    }
    private var queryField: some View {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your library", text: $model.query).textFieldStyle(.plain)
                    .onChange(of: model.query) { model.editSearch() }.onSubmit { model.search(immediate: true) }
                if model.searching || model.exploring { ProgressView().controlSize(.small) }
                if !model.query.isEmpty { Button { model.query = ""; model.invalidateSearch() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).remileHelp("Clear search") }
            }.padding(11).frame(minWidth: 180).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 9))
    }
    private var aiActions: some View {
            AIToolGroup {
            if model.exploring { Button("Stop", action: model.cancelExploration) }
            else { Button { model.explore() } label: { Label("Explore", systemImage: "sparkle.magnifyingglass") }.disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.summary.folders.isEmpty || assistantProvider == "Off" || network.offline).remileHelp("Find related concepts · " + assistantProvider) }
            AIProviderButton()
            Button { toggleAssistant() } label: { Label("Ask", systemImage: "text.bubble") }.remileHelp("Ask about search results · " + assistantProvider)
            }
    }
    private var libraryButton: some View {
        Button { model.libraryPresented = true } label: { Label("Library", systemImage: "books.vertical") }.remileHelp("Manage indexed folders")
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.summary.folders.count) \(model.summary.folders.count == 1 ? "folder" : "folders")")
                Spacer()
                Text("\(max(0, model.summary.documents - model.summary.failed)) indexed")
            }.font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 14)
                .lineLimit(1)
            if model.indexing {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).padding(.horizontal, 14)
                    Text("\(progress.completed) of \(progress.total) · \(progress.name)").font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 14)
                } else { ProgressView("Preparing index…").controlSize(.small).padding(.horizontal, 14) }
            }
            if model.summary.needsOCR > 0 || model.summary.failed > 0 || model.searchDuration != nil {
                Button { model.libraryPresented = true } label: {
                    Label(coverageTitle, systemImage: "info.circle").font(RemileType.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(model.summary.failed > 0 ? RemileStyle.warning : RemileStyle.ink.opacity(0.7)).padding(.horizontal, 14)
                    .remileHelp("\(model.summary.needsOCR) pages have no indexed text. Some may be blank or need OCR. \(model.summary.failed) documents were not indexed. Open Library for details. Time is the latest submitted search.")
            }
            if model.exploring { ProgressView("Exploring concepts…").controlSize(.small).padding(.horizontal, 14) }
            if !model.exploredQueries.isEmpty {
                HStack {
                    Label("Related results", systemImage: "sparkles").remileHelp(model.exploredQueries.joined(separator: " · "))
                    Spacer(); Button("Search again") { model.search(immediate: true) }.buttonStyle(.plain)
                }.font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            if model.boostApplied {
                Label("Boosted with Apple Intelligence", systemImage: "sparkles")
                    .font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                    .remileHelp("Apple Intelligence suggested related retrieval phrases on this Mac. Your original question remains part of the ranking.")
            }
            if !model.spellingSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Did you mean?").font(RemileType.caption).foregroundStyle(.secondary)
                    ForEach(model.spellingSuggestions, id: \.self) { suggestion in Button(suggestion) { model.query = suggestion; model.search(immediate: true) }.buttonStyle(.bordered) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            if let error = model.queryError { Text(error).font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 14) }
            if model.summary.folders.isEmpty {
                ContentUnavailableView { Label("Build your library", systemImage: "books.vertical") } actions: {
                    Button("Add to Library…", action: model.addFolder).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Enter a search", systemImage: "text.magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.searching {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.hasSubmittedSearch {
                ContentUnavailableView("Press Return to search", systemImage: "return").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.results.isEmpty {
                ContentUnavailableView { Label("No matches", systemImage: "magnifyingglass") } description: {
                    Text(model.indexing ? "Indexing is still in progress." : "Search covers indexed PDF and Markdown text.")
                } actions: { Button("Check Library") { model.libraryPresented = true } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("\(model.resultGroups.count) \(model.resultGroups.count == 1 ? "document" : "documents") · \(model.visibleHits.count) \(model.visibleHits.count == 1 ? "match" : "matches")")
                    .font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 14)
                HStack {
                    Picker("Sort matches", selection: $model.resultOrder) {
                        ForEach(SearchResultOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize().remileHelp("Sort matches")
                    Spacer(minLength: 4)
                    if model.results.count == 200 { Text("Top 200 matches").lineLimit(1).remileHelp("Showing the top 200 matches. Refine your search to find more specific passages.") }
                }.font(RemileType.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
                if model.resultGroups.isEmpty {
                    ContentUnavailableView("No matching documents", systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    ScrollViewReader { proxy in
                        List(selection: selection) {
                            if model.resultOrder == .rank {
                                ForEach(model.rankedHits) { entry in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("#\(entry.rank)").monospacedDigit().foregroundStyle(RemileStyle.accent).frame(minWidth: 30, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.hit.name).font(RemileType.callout).lineLimit(2)
                                            Text(entry.hit.location).font(RemileType.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .background(model.selectedHit?.id == entry.id ? RemileStyle.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                        .contentShape(Rectangle()).onTapGesture { selectResult(entry.hit) }.tag(entry.id)
                                        .remileHelp(entry.hit.excerpt).accessibilityElement(children: .ignore)
                                        .accessibilityLabel("Rank \(entry.rank), \(entry.hit.name), \(entry.hit.location)")
                                }
                            } else {
                            ForEach(model.resultGroups) { group in
                                DisclosureGroup(isExpanded: Binding(get: { model.expandedDocuments.contains(group.path) }, set: { expanded in
                                    if expanded { model.expandedDocuments.insert(group.path) } else { model.expandedDocuments.remove(group.path) }
                                })) {
                                    ForEach(group.hits) { hit in
                                        HStack {
                                            Text(hit.location).font(.callout.weight(model.selectedHit?.id == hit.id ? .semibold : .regular))
                                            Spacer()
                                            if let rank = group.rank(for: hit) { rankBadge(rank) }
                                            if model.selectedHit?.id == hit.id { Image(systemName: "arrow.right").font(RemileType.caption).foregroundStyle(RemileStyle.accent) }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(model.selectedHit?.id == hit.id ? RemileStyle.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                            .contentShape(Rectangle()).onTapGesture { selectResult(hit) }.tag(hit.id)
                                            .remileHelp(hit.excerpt).accessibilityElement(children: .ignore).accessibilityLabel("\(hit.name), \(hit.location), relevance position \(group.rank(for: hit) ?? 0)")
                                    }
                                } label: {
                                    Button { selectResult(group.hits.first) } label: {
                                        HStack(spacing: 10) {
                                            if let hit = group.hits.first { SearchCover(hit: hit, revision: model.libraryRevision) }
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(alignment: .top, spacing: 6) {
                                                    Text(group.name).font(RemileType.heading).lineLimit(2)
                                                    Spacer(minLength: 0)
                                                    rankBadge(group.bestRank, best: true)
                                                }
                                                Text("\(group.hits.count) \(group.hits.count == 1 ? "match" : "matches") · \(group.hits.first?.isMarkdown == true ? "Markdown" : "PDF")").font(RemileType.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(.vertical, 8).contentShape(Rectangle())
                                    }.buttonStyle(.plain).remileHelp(group.path).accessibilityLabel("\(group.name), best relevance position \(group.bestRank), \(group.hits.count) matches")
                                }
                            }
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                            .animation(reduceMotion ? nil : RemileMotion.panel, value: model.expandedDocuments)
                            .onChange(of: model.selectedHit?.id) { _, id in
                                if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                            }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter documents", text: $model.documentFilter).textFieldStyle(.plain).onChange(of: model.documentFilter) { model.filterDocuments() }
                    if !model.documentFilter.isEmpty { Button { model.documentFilter = ""; model.filterDocuments() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(10).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8)).padding([.horizontal, .bottom], 10)

            }
            Divider()
            Button { citationState.settingsPresented = true } label: {
                Label("Settings", systemImage: "gearshape").font(RemileType.callout).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(RemileToolStyle()).padding(12).accessibilityLabel("Search settings").remileHelp("Search settings")
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var coverageTitle: String {
        guard let duration = model.searchDuration else { return "Index coverage" }
        return "Index coverage · " + String(format: "%.2f s", duration)
    }
    private func selectResult(_ hit: LibraryHit?) { model.selectResult(hit); if hit != nil { citationState.compactPreview = true } }
    private var preview: some View {
        VStack(spacing: 0) {
            if let position = model.resultPosition {
                HStack {
                    Text("Result \(position + 1) of \(model.visibleHits.count)").font(RemileType.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.moveResult(-1) } label: { Image(systemName: "chevron.up") }.disabled(position == 0).remileHelp("Previous result").accessibilityLabel("Previous result")
                    Button { model.moveResult(1) } label: { Image(systemName: "chevron.down") }.disabled(position + 1 == model.visibleHits.count).remileHelp("Next result").accessibilityLabel("Next result")
                }.padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if model.selectedHit?.isMarkdown == true {
                SearchMarkdownPreview(hit: model.selectedHit!, query: model.selectedHit?.matchQuery ?? model.query, revision: model.libraryRevision, open: open, citation: activeCitation)
            } else { SearchPDFPreview(hit: model.selectedHit, query: model.selectedHit?.matchQuery ?? model.query, revision: model.libraryRevision, open: open, citation: activeCitation, askSelection: { context in
                guard let hit = model.selectedHit else { return }
                assistant.cancel(); citationState.selectedPassages = context.passages(path: hit.path)
                if assistant.question.isEmpty { assistant.question = "Explain the selected passage." }
                withAnimation(reduceMotion ? nil : RemileMotion.panel) { model.askPresented = true }
            }, editing: model.pdfSearchEditing) }
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rankBadge(_ rank: Int, best: Bool = false) -> some View {
        Text(best ? "Best #\(rank)" : "#\(rank)")
            .font(.caption2.weight(.medium)).monospacedDigit().fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(rank <= 3 ? RemileStyle.accent : RemileStyle.ink.opacity(0.7))
            .background(RemileStyle.accent.opacity(rank <= 3 ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 4))
            .remileHelp("Relevance position \(rank)").accessibilityHidden(true)
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
        withAnimation(reduceMotion ? nil : RemileMotion.panel) { model.askPresented.toggle() }
    }

}
