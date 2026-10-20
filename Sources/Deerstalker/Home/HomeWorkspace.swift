import AppKit
import SwiftUI

struct HomeWorkspace: View {
    @ObservedObject var model: HomeModel
    var loadOnAppear = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.page == .home {
                homeLayout.transition(.opacity.combined(with: .offset(x: -16)))
            } else {
                LibrarySearchView(model: model, open: open, goHome: { navigate(.home) })
                    .transition(.opacity.combined(with: .offset(x: 16)))
            }
        }
        .animation(reduceMotion ? nil : DeerMotion.navigation, value: model.page)
        .background(DeerStyle.background).tint(DeerStyle.accent)
        .frame(minWidth: 1000, minHeight: 650)
        .task { if loadOnAppear { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshRecent() }
        .alert("Unable to complete the task", isPresented: Binding(get: { model.error != nil && !model.libraryPresented }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.convertPresented) { ConvertWorkspace(model: model.conversion) }
        .sheet(isPresented: $model.compressPresented) { CompressWorkspace(model: model.compression) }
        .sheet(isPresented: Binding(get: { model.plannedTool != nil }, set: { if !$0 { model.plannedTool = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.plannedTool ?? "").font(.title2.weight(.semibold))
                Text("Coming soon.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { model.plannedTool = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 420)
        }
    }
    private var homeLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(nsImage: DeerArtwork.image("icon", dark: colorScheme == .dark) ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().scaledToFit().frame(width: 32, height: 32)
                    Text("Deerstalker").font(.headline)
                }.padding(.vertical, 22)
                Label("Home", systemImage: "house").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(DeerStyle.accent.opacity(0.17), in: RoundedRectangle(cornerRadius: 9))
                Button { navigate(.search) } label: { Label("Search", systemImage: "magnifyingglass").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(11) }.buttonStyle(.plain)
                Spacer()
            }.padding(14).frame(width: 178).background(.ultraThinMaterial)
            Divider()
            home.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Deerstalker").font(.system(size: 34, weight: .medium, design: .serif))
                            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1")
                                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text("Pick up where you left off.").font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { if let url = model.chooseDocument() { open(url) } } label: {
                        Label("Open a document", systemImage: "doc.badge.plus").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(.vertical, 16)
                if model.processing { ProgressView(model.message ?? "Working…").controlSize(.small) }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Recently opened").font(.headline)
                    if model.recent.isEmpty {
                        Text("No recent documents").foregroundStyle(.secondary).font(.callout).padding(.vertical, 12)
                    } else {
                        ForEach(Array(model.recent.prefix(8)), id: \.self) { url in
                            Button { open(url) } label: { RecentReadingRow(url: url).onDrag { NSItemProvider(object: url as NSURL) } }.buttonStyle(DeerPressStyle())
                        }
                    }
                }
                Divider().padding(.top, 8)
                Text("Document tools").font(.headline)
                HStack(spacing: 12) {
                    tool("Convert", symbol: "doc.badge.arrow.up", detail: "Images, Word and Markdown to PDF") { model.presentConversion() }.modifier(ToolFileDrop(model: model, target: .convert))
                    tool("Compress", symbol: "arrow.down.right.and.arrow.up.left", detail: "Make PDFs smaller") { model.presentCompression() }.modifier(ToolFileDrop(model: model, target: .compress))
                    tool("Combine", symbol: "square.stack", detail: "Bring PDFs into one document") { model.create(.combine, open: open) }.modifier(ToolFileDrop(model: model, target: .combine))
                }.disabled(model.processing)
            }.padding(36).frame(maxWidth: 1060, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func tool(_ title: String, symbol: String, detail: String, planned: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(DeerStyle.accent).frame(height: 25)
                    Spacer()
                    if planned { Text("Planned").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).frame(minHeight: 34, alignment: .topLeading)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(DeerStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
        }.buttonStyle(DeerPressStyle()).accessibilityLabel(title + (planned ? ", planned" : ""))
    }

    private func navigate(_ page: HomeModel.Page) { model.page = page }

    private func open(_ url: URL) { model.open(url) }
}
