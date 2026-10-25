import SwiftUI
import PDFKit

struct RecentReadingRow: View {
    let url: URL
    var openedAt: Date? = nil
    var displayName: String? = nil
    var overleaf = false
    @StateObject private var hover = Hover()
    private final class Hover: ObservableObject { @Published var active = false }
    @StateObject private var preview = Preview()
    private final class Preview: ObservableObject { @Published var image: NSImage? }
    private var isTeX: Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    @Environment(\.colorScheme) private var scheme
    private var tag: String { isTeX ? "TeX" : url.pathExtension.lowercased() == "pdf" ? "PDF" : url.pathExtension.lowercased() == "docx" ? "DOCX" : "MD" }
    private var kind: String { isTeX ? (overleaf ? "Overleaf" : "Local LaTeX") : tag == "PDF" ? "PDF" : tag == "DOCX" ? "Word" : "Markdown" }
    private var tint: Color {
        if isTeX { return scheme == .dark ? Color(red: 0.55, green: 0.76, blue: 0.66) : Color(red: 0.16, green: 0.43, blue: 0.33) }
        if tag == "MD" { return scheme == .dark ? Color(red: 0.57, green: 0.70, blue: 0.90) : Color(red: 0.20, green: 0.37, blue: 0.60) }
        if tag == "DOCX" { return scheme == .dark ? Color(red: 0.82, green: 0.64, blue: 0.74) : Color(red: 0.53, green: 0.33, blue: 0.43) }
        return RemileStyle.accent
    }
    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let thumbnail = preview.image { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: "doc.text").font(.system(size: 30)).foregroundStyle(tint).padding(.bottom, 8) }
            }.frame(width: 44, height: 58).background(RemileStyle.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottom) { Text(tag).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.5).foregroundStyle(scheme == .dark ? Color(nsColor: RemileStyle.slate) : .white).frame(width: 48, height: 19).background(tint, in: RoundedRectangle(cornerRadius: 3)).offset(y: 1) }.accessibilityLabel(kind + " document")
                .overlay(alignment: .topTrailing) {
                    if isTeX && overleaf {
                        Image(systemName: "leaf.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 22, height: 22).background(RemileStyle.background, in: Circle()).offset(x: 7, y: -5)
                            .remileHelp("Overleaf project").accessibilityLabel("Overleaf")
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName ?? url.lastPathComponent).font(.system(size: 17, weight: .medium)).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let openedAt { Text(Self.relativeDate(openedAt)) }
                }.font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)

        }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
            .background(hover.active ? DocumentTone.surface(pdf: url.pathExtension.lowercased() == "pdf") : Color.clear, in: RoundedRectangle(cornerRadius: RemileRadius.card))
            .onHover { hover.active = $0 }
            .task(id: url) {
                guard url.pathExtension.lowercased() == "pdf" else { return }
                preview.image = await Task.detached(priority: .utility) {
                    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil as NSImage? }
                    return withExtendedLifetime(document) { page.thumbnail(of: NSSize(width: 88, height: 116), for: .cropBox) }
                }.value
            }
    }
    static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

}
