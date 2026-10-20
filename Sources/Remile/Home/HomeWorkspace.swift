import AppKit
import SwiftUI

struct HomeWorkspace: View {
    @ObservedObject var model: HomeModel
    var loadOnAppear = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var actions = HomeActions()
    private final class HomeActions: ObservableObject { @Published var clearHistory = false }

    var body: some View {
        ZStack {
            if model.page == .home {
                homeLayout.transition(.opacity.combined(with: .offset(x: -16)))
            } else {
                LibrarySearchView(model: model, open: open, goHome: { navigate(.home) })
                    .transition(.opacity.combined(with: .offset(x: 16)))
            }
        }
        .animation(reduceMotion ? nil : RemileMotion.navigation, value: model.page)
        .background(RemileStyle.background).tint(RemileStyle.accent)
        .frame(minWidth: 1000, minHeight: 650)
        .task { if loadOnAppear { await model.load() } }
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
        .sheet(isPresented: Binding(get: { model.plannedTool != nil }, set: { if !$0 { model.plannedTool = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.plannedTool ?? "").font(.title2.weight(.semibold))
                Text("Coming soon.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { model.plannedTool = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 420)
        }
    }
    private var homeLayout: some View {
        ReaderSplit(initial: 196, minimum: 180, maximum: 260, minimumContent: 720, label: "home sidebar", pane: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(nsImage: RemileArtwork.image("icon", dark: colorScheme == .dark) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().scaledToFit().frame(width: 32, height: 32)
                    Text("remile.").font(RemileType.heading)
                }.padding(.vertical, 22)
                Label("Home", systemImage: "house").font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(RemileStyle.accent.opacity(0.17), in: RoundedRectangle(cornerRadius: 9))
                Button { navigate(.search) } label: { Label("Search", systemImage: "magnifyingglass").font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain)
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1")).font(RemileType.caption).monospacedDigit().foregroundStyle(.secondary).padding(11)
            }.padding(14).frame(maxWidth: .infinity).background(.ultraThinMaterial)
        }, content: { home.frame(maxWidth: .infinity, maxHeight: .infinity) })
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let image = RemileArtwork.image("banner", dark: colorScheme == .dark) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: model.recent.isEmpty ? 240 : 170).accessibilityLabel("remile.")
                }
                HStack {
                    Spacer()
                    Button { if let url = model.chooseDocument() { open(url) } } label: {
                        Label("Open a document", systemImage: "doc.badge.plus").font(RemileType.body).padding(.horizontal, 22).padding(.vertical, 14)
                            .foregroundStyle(colorScheme == .dark ? Color(nsColor: RemileStyle.slate) : .white)
                            .background(RemileStyle.accent, in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                if model.processing { ProgressView(model.message ?? "Working…").controlSize(.small) }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Recently opened").font(RemileType.heading)
                        Spacer()
                        Menu {
                            Button("Clear recent items") { model.clearRecent() }.disabled(model.recent.isEmpty)
                            Divider()
                            Button("Delete local editing history…", role: .destructive) { actions.clearHistory = true }
                        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().help("Recent items and local history")
                    }
                    if model.recent.isEmpty {
                        Text("No recent documents").foregroundStyle(.secondary).font(RemileType.callout).padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(Array(model.recent.prefix(6)), id: \.self) { url in
                            Button { open(url) } label: { RecentReadingRow(url: url, openedAt: model.lastOpened(url)).frame(height: 98).onDrag { NSItemProvider(object: url as NSURL) } }.buttonStyle(RemilePressStyle())
                        }
                    }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Editors").font(RemileType.heading)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        Button { model.newMarkdown() } label: { Label("New Markdown", systemImage: "square.and.pencil").font(RemileType.body).frame(maxWidth: .infinity).padding(.vertical, 8) }
                        Button { model.chooseTeX() } label: { Label("LaTeX Project (Local)", systemImage: "doc.text").font(RemileType.body).frame(maxWidth: .infinity).padding(.vertical, 8) }.help("Open or drop a LaTeX project folder").modifier(ToolFileDrop(model: model, target: .latex))
                        Button { model.plannedTool = "Overleaf Project (Online)" } label: { Label { Text("Overleaf Project (Online)") } icon: { OverleafMark() }.font(RemileType.body).frame(maxWidth: .infinity).padding(.vertical, 8) }
                    }.buttonStyle(RemileEditorButtonStyle())
                }
                Divider().padding(.top, 8)
                Text("Document tools").font(RemileType.heading)
                HStack(spacing: 12) {
                    tool("Convert", symbol: "doc.badge.arrow.up", detail: "Images, Word and Markdown to PDF") { model.presentConversion() }.modifier(ToolFileDrop(model: model, target: .convert))
                    tool("Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Make PDFs smaller") { model.presentCompression() }.modifier(ToolFileDrop(model: model, target: .compress))
                    tool("Combine", symbol: "square.stack", detail: "Combine PDF or Markdown files") { model.create(.combine, open: open) }.modifier(ToolFileDrop(model: model, target: .combine))
                }.disabled(model.processing)
            }.padding(36).frame(maxWidth: 1060, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func tool(_ title: String, symbol: String, detail: String, planned: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(RemileStyle.accent).frame(height: 25)
                    Spacer()
                    if planned { Text("Planned").font(RemileType.small).foregroundStyle(.secondary) }
                }
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 15)).foregroundStyle(.secondary).frame(minHeight: 34, alignment: .topLeading)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
        }.buttonStyle(RemilePressStyle()).accessibilityLabel(title + (planned ? ", planned" : ""))
    }

    private func navigate(_ page: HomeModel.Page) { model.page = page }

    private func open(_ url: URL) { model.open(url) }
}
