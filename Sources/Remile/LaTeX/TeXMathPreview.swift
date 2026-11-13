import SwiftUI
import WebKit

@MainActor
final class TeXMathPreviewState: ObservableObject {
    nonisolated static let preference = "latex.equationPreview"
    struct Content: Equatable {
        let document: String
        let markup: String
        var updating = false
    }

    @Published private(set) var content: Content?
    private var lastFormula: TeXMathEditing.Formula?
    private var lastDocument: String?
    private var task: Task<Void, Never>?

    func schedule(in view: NSTextView, document: String) {
        task?.cancel()
        task = Task { @MainActor [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, let view, view.window?.firstResponder === view, !view.hasMarkedText() else {
                self?.clear()
                return
            }
            let source = view.string, selection = view.selectedRange()
            let previous = self.lastDocument == document ? self.lastFormula : nil
            let scan = Task.detached(priority: .userInitiated) {
                let formula = TeXMathEditing.formula(source, selection: selection)
                guard let formula, formula != previous, !Task.isCancelled else { return (formula, nil as String?) }
                let markup = try? MathMarkup.render(formula.source, display: formula.display,
                                                    highlightOffset: formula.highlightOffset)
                return (formula, markup)
            }
            let (formula, markup) = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, view.window?.firstResponder === view, !view.hasMarkedText() else { return }
            guard let formula else { self.clear(); return }
            if previous == formula { return }
            self.lastFormula = formula
            self.lastDocument = document
            var next = markup.map { Content(document: document, markup: $0) }
            if next == nil, previous?.start == formula.start {
                next = self.content
                next?.updating = true
            }
            if self.content != next { self.content = next }
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        lastFormula = nil
        lastDocument = nil
        if content != nil { content = nil }
    }
}

struct TeXMathPreviewStrip: View {
    @ObservedObject var state: TeXMathPreviewState
    let document: String
    let paper: Bool
    let availableHeight: CGFloat
    @Environment(\.colorScheme) private var scheme
    @State private var fittedHeight: CGFloat = 0
    private static let minimumHeight: CGFloat = 44
    private static let previewShare: CGFloat = 0.45

    var body: some View {
        if let content = state.content, content.document == document {
            let maximumHeight = floor(availableHeight * Self.previewShare)
            TeXMathWebView(markup: content.markup, dark: !paper && scheme == .dark, fittedHeight: $fittedHeight)
                .frame(height: max(Self.minimumHeight, min(fittedHeight, maximumHeight)))
                .opacity(content.updating ? 0.45 : 1)
                .accessibilityLabel(content.updating ? "Previous equation preview" : "Equation preview")
        }
    }
}

private struct TeXMathWebView: NSViewRepresentable {
    let markup: String
    let dark: Bool
    @Binding var fittedHeight: CGFloat

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var markup: String?
        var dark = false
        var revision = ""
        var fittedHeight: Binding<CGFloat>?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let size = message.body as? [String: Any],
                  size["revision"] as? String == revision, let measured = size["height"] as? Double,
                  measured.isFinite else { return }
            let value = CGFloat(ceil(measured))
            if fittedHeight?.wrappedValue != value { fittedHeight?.wrappedValue = value }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let world = WKContentWorld.defaultClient
        configuration.userContentController.add(context.coordinator, contentWorld: world, name: "equationSize")
        configuration.userContentController.addUserScript(WKUserScript(source: """
        const equation = document.querySelector('math');
        if (equation) {
            const inset = 12;
            let naturalSize;
            let reportedHeight;
            const fit = () => {
                const width = innerWidth - 2 * inset;
                const height = innerHeight - 2 * inset;
                if (width <= 0 || height <= 0) return;
                if (!naturalSize) {
                    const size = equation.getBoundingClientRect();
                    if (!size.width || !size.height) return;
                    naturalSize = size;
                }
                const widthScale = Math.min(1, width / naturalSize.width);
                const fittedHeight = Math.ceil(naturalSize.height * widthScale + 2 * inset);
                const scale = Math.min(widthScale, height / naturalSize.height);
                equation.style.transform = `translate(-50%, -50%) scale(${scale})`;
                if (fittedHeight === reportedHeight) return;
                reportedHeight = fittedHeight;
                window.webkit.messageHandlers.equationSize.postMessage({
                    revision: document.body.dataset.revision, height: fittedHeight
                });
            };
            addEventListener('resize', fit);
            fit();
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setAccessibilityLabel("Equation preview")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.fittedHeight = $fittedHeight
        guard coordinator.markup != markup || coordinator.dark != dark else { return }
        coordinator.markup = markup
        coordinator.dark = dark
        let revision = UUID().uuidString
        coordinator.revision = revision
        let background = dark ? RemileStyle.slate : RemileStyle.paper
        let ink = dark ? RemileStyle.ivory : RemileStyle.slate
        let html = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        html, body { overflow: hidden; }
        body { margin: 0; min-height: 100vh;
               background: \(Self.css(background)); color: \(Self.css(ink)); }
        math { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
               font-size: 22px; width: max-content; margin: 0; }
        .active-equation-row > mtd { background: rgba(146, 107, 50, 0.19); }
        </style><body data-revision="\(revision)">\(markup)</body>
        """
        web.underPageBackgroundColor = background
        web.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "equationSize", contentWorld: .defaultClient)
    }

    private static func css(_ colour: NSColor) -> String {
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        return "rgb(\(Int((255 * rgb.redComponent).rounded())), \(Int((255 * rgb.greenComponent).rounded())), \(Int((255 * rgb.blueComponent).rounded())))"
    }
}
