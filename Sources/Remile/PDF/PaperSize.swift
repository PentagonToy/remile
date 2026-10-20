import SwiftUI
import CoreGraphics

enum PaperSize: String, CaseIterable, Identifiable {
    case a3 = "A3", a4 = "A4", a5 = "A5", b4ISO = "B4 (ISO)", b4JIS = "B4 (JIS)", letter = "Letter"
    static let preference = "pdf.defaultPaperSize"
    static let landscapePreference = "pdf.defaultLandscape"
    var id: String { rawValue }
    var millimetres: CGSize {
        switch self {
        case .a3: return CGSize(width: 297, height: 420)
        case .a4: return CGSize(width: 210, height: 297)
        case .a5: return CGSize(width: 148, height: 210)
        case .b4ISO: return CGSize(width: 250, height: 353)
        case .b4JIS: return CGSize(width: 257, height: 364)
        case .letter: return CGSize(width: 215.9, height: 279.4)
        }
    }
    var dimensions: String {
        let size = millimetres
        func number(_ value: CGFloat) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
        return "\(number(size.width)) × \(number(size.height)) mm"
    }
    func points(landscape: Bool = false) -> CGSize {
        let factor = 72.0 / 25.4, mm = millimetres
        return CGSize(width: (landscape ? mm.height : mm.width) * factor, height: (landscape ? mm.width : mm.height) * factor)
    }
}

struct PDFPageSizeControl: View {
    @ObservedObject var session: PDFSession
    @StateObject private var state = Presentation()
    private final class Presentation: ObservableObject {
        @Published var shown = false
        @Published var paper = PaperSize.a4.rawValue
        @Published var landscape = false
    }
    var body: some View {
        Button {
            state.paper = UserDefaults.standard.string(forKey: PaperSize.preference) ?? PaperSize.a4.rawValue
            state.landscape = UserDefaults.standard.bool(forKey: PaperSize.landscapePreference)
            state.shown.toggle()
        } label: { Label("Page size", systemImage: "arrow.up.left.and.arrow.down.right").frame(height: 32) }
            .remileHelp("Fit all pages to a paper size").accessibilityLabel("Page size")
            .popover(isPresented: $state.shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Page size").font(RemileType.heading)
                    Picker("Paper", selection: $state.paper) { ForEach(PaperSize.allCases) { size in Text("\(size.rawValue) · \(size.dimensions)").tag(size.rawValue) } }
                    Picker("Orientation", selection: $state.landscape) { Text("Portrait").tag(false); Text("Landscape").tag(true) }.pickerStyle(.segmented).labelsHidden()
                    HStack { Spacer(); Button("Fit all pages") { session.fitPages(to: (PaperSize(rawValue: state.paper) ?? .a4).points(landscape: state.landscape)); state.shown = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }.font(RemileType.callout).padding(20).frame(width: 300)
            }
    }
}
