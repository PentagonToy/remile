import SwiftUI
import PDFKit

struct PDFPagesPanel: View {
    let document: PDFDocument
    let currentPage: Int
    let select: (Int) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = min(160, max(64, geometry.size.width - 52))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(0..<document.pageCount, id: \.self) { index in
                            Button { select(index + 1) } label: {
                                VStack(spacing: 8) {
                                    if let page = document.page(at: index) {
                                        PDFPageThumbnail(page: page, size: CGSize(width: width, height: width * 1.34))
                                            .padding(4)
                                            .background(currentPage == index + 1 ? RemileStyle.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(currentPage == index + 1 ? RemileStyle.accent : Color.clear, lineWidth: 1))
                                    }
                                    Text("\(index + 1)").font(RemileType.caption).monospacedDigit()
                                        .foregroundStyle(currentPage == index + 1 ? RemileStyle.ink : Color.secondary)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(currentPage == index + 1 ? RemileStyle.accent.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                }.frame(maxWidth: .infinity).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index + 1).accessibilityLabel("Go to page \(index + 1)")
                        }
                    }.padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 18)
                }.onAppear { proxy.scrollTo(currentPage, anchor: .center) }
                    .onChange(of: currentPage) { _, page in proxy.scrollTo(page, anchor: .center) }
            }
        }
    }
}

struct PDFPageThumbnail: View {
    let page: PDFPage
    var size = CGSize(width: 66, height: 86)
    @StateObject private var state = ThumbnailState()
    private final class ThumbnailState: ObservableObject { @Published var image: NSImage? }
    var body: some View {
        Group {
            if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.quaternary) }
        }.frame(width: size.width, height: size.height)
            .task(id: "\(ObjectIdentifier(page)):\(page.rotation):\(size.width):\(size.height)") {
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                state.image = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
            }
            .onDisappear { state.image = nil }
    }
}

struct PDFOutlinePanel: View {
    let document: PDFDocument
    let select: (PDFDestination) -> Void
    struct Entry: Identifiable {
        let outline: PDFOutline; let depth: Int
        var id: ObjectIdentifier { ObjectIdentifier(outline) }
    }
    static func entries(_ document: PDFDocument) -> [Entry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [Entry] = []
        func visit(_ node: PDFOutline, depth: Int) {
            guard depth < 16, result.count < 2000 else { return }
            for index in 0..<node.numberOfChildren {
                guard result.count < 2000, let child = node.child(at: index) else { break }
                result.append(Entry(outline: child, depth: depth)); visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0); return result
    }
    var body: some View {
        let entries = Self.entries(document)
        if entries.isEmpty { ContentUnavailableView("No outline", systemImage: "list.bullet").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else {
            List(entries) { entry in
                Button {
                    if let destination = entry.outline.destination ?? (entry.outline.action as? PDFActionGoTo)?.destination { select(destination) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.outline.label ?? "Untitled section").font(RemileType.callout).lineLimit(3).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let page = entry.outline.destination?.page, page.document === document, document.index(for: page) != NSNotFound { Text("\(document.index(for: page) + 1)").font(RemileType.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }.padding(.leading, CGFloat(entry.depth) * 12).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
}
