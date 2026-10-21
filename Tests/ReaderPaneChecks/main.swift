import AppKit
import SwiftUI
import PDFKit

// Styling is irrelevant to this lifecycle test; the split implementation is production code.
enum RemileStyle { static let ink = Color.primary; static let accent = Color.yellow }
enum RemileMotion { static let panel = Animation.spring(response: 0.36) }
extension View { func remileHelp(_ text: String) -> some View { help(text) } }
@MainActor final class PaneState: ObservableObject { @Published var ask = true }
struct PanePDF: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.document = document; view.displayMode = .singlePageContinuous
        view.autoScales = false; view.scaleFactor = 1.25; return view
    }
    func updateNSView(_ view: PDFView, context: Context) { }
}
struct PaneHost: View {
    @ObservedObject var state: PaneState
    let document: PDFDocument
    var body: some View {
        ReaderSplit(side: .trailing, isPresented: state.ask, pane: { Text("Ask") }, content: { PanePDF(document: document) })
    }
}
@MainActor func pdf(in view: NSView) -> PDFView? {
    if let pdf = view as? PDFView { return pdf }
    return view.subviews.lazy.compactMap { pdf(in: $0) }.first
}
@MainActor func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<150 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }; return false
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let document = PDFDocument()
    for _ in 0..<8 { let page = PDFPage(); page.setBounds(NSRect(x: 0,y: 0,width: 612,height: 792),for: .mediaBox); document.insert(page,at:document.pageCount) }
    let state = PaneState(), host = NSHostingView(rootView: PaneHost(state: PaneState(),document:document))
    host.rootView = PaneHost(state: state,document:document)
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
    window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
    guard await waitFor({pdf(in: host)?.bounds.width ?? 0 > 100}), let view = pdf(in:host) else { exit(1) }
    view.layoutDocumentView(); view.go(to:document.page(at:4)!)
    guard await waitFor({view.currentPage === document.page(at:4)}) else { exit(1) }
    let width = view.bounds.width
    state.ask = false; host.layoutSubtreeIfNeeded()
    guard await waitFor({view.bounds.width > width}), pdf(in:host) === view, view.currentPage === document.page(at:4), abs(view.scaleFactor-1.25)<0.001 else { print("FAILED closing Ask resets viewport");exit(1) }
    state.ask = true; host.layoutSubtreeIfNeeded()
    guard await waitFor({abs(view.bounds.width-width)<1}), pdf(in:host) === view, view.currentPage === document.page(at:4), abs(view.scaleFactor-1.25)<0.001 else { print("FAILED reopening Ask resets viewport");exit(1) }
    print("Passed Ask close/reopen retains PDFView identity, page 5 and manual zoom")
    window.orderOut(nil);exit(0)
}
app.run()
