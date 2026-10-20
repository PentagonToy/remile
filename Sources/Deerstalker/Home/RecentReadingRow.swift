import SwiftUI
import PDFKit

struct RecentReadingRow: View {
    let url: URL
    @StateObject private var preview = Preview()
    private final class Preview: ObservableObject { @Published var image: NSImage? }
    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let thumbnail = preview.image { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.plaintext").font(.system(size: 26)).foregroundStyle(DeerStyle.accent) }
            }.frame(width: 44, height: 58).background(.background, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 5) {
                Text(url.lastPathComponent).font(.system(size: 15, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                Text(url.deletingLastPathComponent().path).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 20)
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                Text(date, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
            .background(DeerStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .task(id: url) {
                guard url.pathExtension.lowercased() == "pdf" else { return }
                preview.image = await Task.detached(priority: .utility) {
                    PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: NSSize(width: 88, height: 116), for: .cropBox)
                }.value
            }
    }
}
