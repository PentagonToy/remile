import SwiftUI
import PDFKit

struct PDFPagesPanel: View {
    let document: PDFDocument
    let currentPage: Int
    let select: (Int) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        Button { select(index + 1) } label: {
                            HStack(spacing: 14) {
                                if let page = document.page(at: index) { PDFPageThumbnail(page: page, size: CGSize(width: 50, height: 66)) }
                                Text("\(index + 1)").font(RemileType.caption).monospacedDigit()
                                Spacer()
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(currentPage == index + 1 ? RemileStyle.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).id(index + 1).accessibilityLabel("Go to page \(index + 1)")
                    }
                }.padding(8)
            }.onChange(of: currentPage) { _, page in proxy.scrollTo(page, anchor: .center) }
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
            .task(id: "\(ObjectIdentifier(page)):\(page.rotation)") { await Task.yield(); guard !Task.isCancelled else { return }; state.image = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .cropBox) }
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
        if entries.isEmpty { ContentUnavailableView("No outline", systemImage: "list.bullet", description: Text("This PDF has no embedded table of contents. Use Pages or Search.")) }
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
                }.buttonStyle(.plain)
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
}
