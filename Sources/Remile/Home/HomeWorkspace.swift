import AppKit
import SwiftUI

struct HomeWorkspace: View {
    @ObservedObject var model: HomeModel
    var loadOnAppear = true
    var tourProgress: WelcomeTourProgress? = nil
    private var tour: WelcomeTourProgress { tourProgress ?? actions.tour }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var actions = HomeActions()
    private final class HomeActions: ObservableObject { @Published var clearHistory = false; @Published var settings = false; let tour = WelcomeTourProgress() }

    @AppStorage(AnimationPolicy.preference) private var animations = true
    @AppStorage("home.recentExpanded") private var recentExpanded = true

    var body: some View {
        ZStack {
            if model.page == .home {
                homeLayout.transition(.opacity.combined(with: .offset(x: -16)))
            } else if model.page == .writer, let writer = model.writer {
                WriterWorkspace(model: writer, goHome: { if model.closeWriter() { model.page = .home } }).navigationTitle(writer.title)
            } else if model.page == .reference {
                ReferenceWorkspace(model: model.references, goHome: { navigate(.home) }, openPDF: { url, page in
                    ReaderNavigation.shared.reveal(LibraryHit(path: url.path, folderID: "reference", page: page + 1, excerpt: "", score: 0), query: "")
                    model.open(url)
                })
            } else {
                LibrarySearchView(model: model, open: open, goHome: { navigate(.home) })
                    .transition(.opacity.combined(with: .offset(x: 16)))
            }
        }
        .modifier(WelcomeTour(enabled: (loadOnAppear || tourProgress != nil) && model.page == .home && !actions.settings && !model.guidePresented && !model.overleaf.presented, openGuide: { model.guidePresented = true }, progress: tour))
        .animation(reduceMotion || !animations ? nil : RemileMotion.navigation, value: model.page)
        .background(RemileStyle.background).tint(RemileStyle.accent)
        .frame(minWidth: 560, minHeight: 450)
        .task { if loadOnAppear { await model.load() } }
        .sheet(isPresented: $actions.settings) { ReaderSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshRecent() }
        .alert("Unable to complete the task", isPresented: Binding(get: { model.error != nil && !model.libraryPresented }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Delete local editing history?", isPresented: $actions.clearHistory) {
            Button("Cancel", role: .cancel) { }
            Button("Move history to Trash", role: .destructive) {
                do { try TeXHistory.clearAll(); model.texProject?.revisions = [] }
                catch { model.error = error.localizedDescription }
            }
        } message: { Text("Moves remile.’s local LaTeX revisions to Trash. Your documents and project files stay in place.") }

    }
    private var homeLayout: some View {
        ReaderSplit(initial: 180, minimum: 170, maximum: 300, minimumContent: 320, label: "home sidebar", revealToken: "tour-\(tour.step)-\(tour.replay)", pane: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(nsImage: RemileArtwork.image("icon", dark: colorScheme == .dark) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().scaledToFit().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("remile.").font(RemileType.heading).fixedSize()
                        Text("v" + RemileRelease.current).font(RemileType.small).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                }.padding(.vertical, 22)
                SymbolLabel("Home", systemImage: "house").labelStyle(RemileNavigationLabelStyle()).font(RemileType.control.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(RemileStyle.accent.opacity(0.17), in: RoundedRectangle(cornerRadius: 9))
                Button { navigate(.search) } label: { SymbolLabel("Search", systemImage: "magnifyingglass").labelStyle(RemileNavigationLabelStyle()).font(RemileType.control.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain).tourTarget("search")
                Button { navigate(.reference) } label: {
                    Label { Text("Reference").fixedSize(horizontal: false, vertical: true) } icon: { SymbolIcon(systemName: "books.vertical") }
                        .labelStyle(RemileNavigationLabelStyle()).font(RemileType.control.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11)
                }.buttonStyle(.plain).tourTarget("reference")
                Spacer()
                Button { actions.settings = true } label: { SymbolLabel("Settings", systemImage: "gearshape").labelStyle(RemileNavigationLabelStyle()).frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain).tourTarget("settings")
                Button { model.guidePresented = true } label: { SymbolLabel("User guide", systemImage: "book.closed").labelStyle(RemileNavigationLabelStyle()).frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain).remileHelp("A quick guide to remile.").tourTarget("guide")
            }.padding(14).frame(maxWidth: .infinity).background(.ultraThinMaterial)
        }, content: { home.frame(maxWidth: .infinity, maxHeight: .infinity) })
    }

    private var home: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 850
            let narrow = geometry.size.width < 700
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                    RemileBanner().frame(height: compact ? 150 : 170)
                    HStack {
                        Spacer()
                        Button { if let url = model.chooseDocument() { open(url) } } label: {
                            SymbolLabel("Open a document", systemImage: "doc.badge.plus").font(RemileType.body).padding(.horizontal, 20).padding(.vertical, 12)
                                .foregroundStyle(colorScheme == .dark ? Color(nsColor: RemileStyle.slate) : .white)
                                .background(RemileStyle.accent, in: Capsule())
                        }.buttonStyle(.plain).tourTarget("open")
                    }
                    if model.processing { ProgressView(model.message ?? "Working…").controlSize(.small) }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button { withAnimation(reduceMotion || !animations ? nil : RemileMotion.disclosure) { recentExpanded.toggle() } } label: {
                                HStack(spacing: 7) { SymbolIcon(systemName: recentExpanded ? "chevron.down" : "chevron.right"); Text("Recently opened").font(RemileType.heading) }
                            }.buttonStyle(.plain).remileHelp(recentExpanded ? "Collapse recent documents" : "Expand recent documents").accessibilityValue(recentExpanded ? "Expanded" : "Collapsed")
                            Spacer()
                            Menu {
                                Button("Clear recent items") { model.clearRecent() }.disabled(model.recent.isEmpty)
                                Divider()
                                Button("Delete local editing history…", role: .destructive) { actions.clearHistory = true }
                            } label: { SymbolIcon(systemName: "ellipsis").frame(width: 28, height: 26) }.menuStyle(.borderlessButton).tint(RemileStyle.ink).fixedSize().remileHelp("Recent items and local history")
                        }
                        if recentExpanded {
                            if model.recent.isEmpty { Text("Open a document or start with an editor below.").foregroundStyle(.secondary).font(RemileType.callout).padding(.vertical, 12) }
                            else {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: narrow ? 2 : 3), spacing: 6) {
                                    ForEach(Array(model.recent.prefix(narrow && compact ? 4 : 6)), id: \.self) { url in
                                        Button { open(url) } label: { RecentReadingRow(url: url, openedAt: model.lastOpened(url), displayName: model.overleaf.connection(for: url)?.name, overleaf: model.overleaf.connection(for: url) != nil).frame(height: compact ? 68 : 88).onDrag { NSItemProvider(object: url as NSURL) } }.buttonStyle(RemilePressStyle())
                                            .contextMenu {
                                                if let project = model.overleaf.connection(for: url) { OverleafProjectIDButton(project: project) }
                                                Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                                Button("Remove from Recent", systemImage: "clock.badge.xmark") { model.removeRecent(url) }
                                            }
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Editors").font(RemileType.heading)
                        HomeCardLayout(minimumWidth: 160) {
                            Button { model.newWriter() } label: { SymbolLabel("Writer", systemImage: "text.alignleft").frame(maxWidth: .infinity).padding(.vertical, 8) }.remileHelp("New Writer document").tourTarget("writer")
                            Button { model.newMarkdown() } label: { SymbolLabel("Markdown", systemImage: "square.and.pencil").frame(maxWidth: .infinity).padding(.vertical, 8) }.remileHelp("New Markdown document").tourTarget("markdown")
                            Button { model.newTeX() } label: { SymbolLabel("LaTeX", systemImage: "doc.text").frame(maxWidth: .infinity).padding(.vertical, 8) }.remileHelp("New LaTeX project. Drop a folder or source ZIP to open it.").tourTarget("latex").modifier(ToolFileDrop(model: model, target: .latex))
                            Button { model.overleaf.openLibrary() } label: { Label { Text("Overleaf") } icon: { OverleafMark() }.frame(maxWidth: .infinity).padding(.vertical, 8) }.remileHelp("Open Overleaf library").tourTarget("overleaf")
                        }.font(RemileType.callout).labelStyle(HomeEditorLabelStyle()).buttonStyle(RemileEditorButtonStyle()).tourTarget("editors")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Document tools").font(RemileType.heading)
                        HomeCardLayout(minimumWidth: 200) {
                            tool("Convert", symbol: "doc.badge.arrow.up", detail: "Images, Word & Markdown", compact: compact) { model.presentConversion() }.modifier(ToolFileDrop(model: model, target: .convert))
                            tool("Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Smaller PDFs", compact: compact) { model.presentCompression() }.modifier(ToolFileDrop(model: model, target: .compress))
                            tool("Combine", symbol: "square.stack", detail: "PDF or Markdown", compact: compact) { model.create(.combine, open: open) }.modifier(ToolFileDrop(model: model, target: .combine))
                        }.disabled(model.processing).tourTarget("tools")
                    }
                }.padding(compact ? 24 : 32).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize).smoothScrolling()
                .onReceive(tour.$step) { step in
                    guard WelcomeTour.steps.indices.contains(step) else { return }
                    withAnimation(reduceMotion || !animations ? nil : RemileMotion.panel) { scroll.scrollTo(WelcomeTour.steps[step].target, anchor: .center) }
                }
            }
        }
    }

    private func tool(_ title: String, symbol: String, detail: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 7 : 12) {
                SymbolIcon(systemName: symbol).foregroundStyle(RemileStyle.accent).frame(height: 24)
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(RemileType.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 14 : 20)
                .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
        }.buttonStyle(RemilePressStyle()).remileHelp(detail)
    }

    private func navigate(_ page: HomeModel.Page) { guard model.closeWriter(), model.pdfSearchEditing.confirmLeaving() else { return }; model.page = page }

    private func open(_ url: URL) { model.open(url) }
}

/// Keep each name centred independently of its symbol.
private struct HomeEditorLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 20)
            configuration.title.frame(maxWidth: .infinity)
            Color.clear.frame(width: 20, height: 1).accessibilityHidden(true)
        }.padding(.horizontal, 12)
    }
}
