import SwiftUI
import PDFKit

actor SearchCoverStore {
    static let shared = SearchCoverStore()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    func image(path: String, revision: UUID) throws -> Data? {
        try Task.checkCancellation()
        let key = path + revision.uuidString
        if let cached = cache[key] { return cached }
        let data: Data? = autoreleasepool {
            guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)), !pdf.isLocked, let page = pdf.page(at: 0) else { return nil }
            let image = page.thumbnail(of: NSSize(width: 96, height: 128), for: .cropBox)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
        try Task.checkCancellation()
        if let data {
            if order.count >= 64 { cache.removeValue(forKey: order.removeFirst()) }
            cache[key] = data; order.append(key)
        }
        return data
    }
}

/// The Markdown cover is authored from native shapes, independent of document content.
struct SearchCover: View {
    let hit: LibraryHit
    let revision: UUID
    @StateObject private var state = State()
    final class State: ObservableObject { @Published var image: NSImage? }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: RemileStyle.paper))
            if hit.isMarkdown {
                VStack(spacing: 5) {
                    Text("M↓").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(RemileStyle.brand)
                    Rectangle().fill(RemileStyle.brand.opacity(0.3)).frame(width: 23, height: 2)
                    Rectangle().fill(RemileStyle.brand.opacity(0.2)).frame(width: 17, height: 2)
                }
            } else if let image = state.image { Image(nsImage: image).resizable().scaledToFit() }
            else { SymbolIcon(systemName: "doc.text").foregroundStyle(RemileStyle.brand) }
        }.frame(width: 40, height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            .task(id: hit.path + revision.uuidString) {
                state.image = nil
                guard !hit.isMarkdown else { return }
                if let data = try? await SearchCoverStore.shared.image(path: hit.path, revision: revision), !Task.isCancelled { state.image = NSImage(data: data) }
            }
    }
}
