import AppKit
import SwiftUI
import PDFKit

@_cdecl("__isPlatformVersionAtLeast")
public func performanceHostVersion(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ value: Bool, _ title: String) { precondition(value, title); checks += 1; print("PASS: " + title); fflush(stdout) }
@MainActor final class Probe: ObservableObject { @Published var shown = false; var makes = 0; var widths: [Int] = [] }
struct CanvasProbe: NSViewRepresentable {
    let probe: Probe
    final class Surface: NSView {
        let probe: Probe
        init(_ probe: Probe) { self.probe = probe; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); if newSize.width > 1 { probe.widths.append(Int(newSize.width.rounded())) } }
    }
    func makeNSView(context: Context) -> Surface { probe.makes += 1; return Surface(probe) }
    func updateNSView(_ view: Surface, context: Context) {}
}
struct SplitFixture: View {
    @ObservedObject var probe: Probe
    let document: PDFDocument
    var body: some View {
        ReaderSplit(isPresented: probe.shown, animatesResizing: false, pane: { if probe.shown { PDFPagesPanel(document: document, currentPage: 1, select: { _ in }) } }, content: { CanvasProbe(probe: probe) })
    }
}
struct TourFixture: View {
    let progress: WelcomeTourProgress
    var body: some View {
        VStack(spacing: 12) { ForEach(WelcomeTour.steps, id: \.target) { step in Text(step.title).frame(maxWidth: .infinity, minHeight: 36).tourTarget(step.target) } }
            .padding(24).frame(width: 800, height: 700).modifier(WelcomeTour(enabled: true, openGuide: {}, progress: progress))
    }
}
@MainActor final class NavigationProbe: ObservableObject {
    @Published var page = false
    @Published var disclosure = false
    var outer: [Bool] = []
    var inner: [Bool] = []
    var local: [Bool] = []
}
struct NavigationTransactionProbe: NSViewRepresentable {
    let value: Bool
    let record: (Bool) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { record(context.transaction.animation != nil) }
}
struct NavigationFixture: View {
    @ObservedObject var probe: NavigationProbe
    var body: some View {
        HStack {
            NavigationTransactionProbe(value: probe.page) { probe.outer.append($0) }
            VStack {
                NavigationTransactionProbe(value: probe.page) { probe.inner.append($0) }
                NavigationTransactionProbe(value: probe.disclosure) { probe.local.append($0) }
                    .animation(RemileMotion.disclosure, value: probe.disclosure)
            }.modifier(RemileNavigationContent())
        }.animation(RemileMotion.navigation, value: probe.page)
    }
}
Task { @MainActor in
    let defaults = UserDefaults.standard, original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var preferences = original; preferences[AnimationPolicy.preference] = true; preferences["welcome.tourCompleted.v1"] = true
    defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    do {
        let navigation = NavigationProbe(), navigationHost = NSHostingView(rootView: NavigationFixture(probe: navigation))
        navigationHost.frame = .init(x: 0, y: 0, width: 800, height: 500)
        navigationHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        navigation.outer = []; navigation.inner = []; navigation.local = []
        navigation.page = true; navigationHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        check(navigation.outer.contains(true), "The page surface retains its navigation animation")
        check(!navigation.inner.isEmpty && !navigation.inner.contains(true), "Navigation does not animate internal content layout")
        navigation.local = []; navigation.disclosure = true; navigationHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        check(navigation.local.contains(true), "Local disclosures retain their own animation inside the page")
        let cache = PDFThumbnailCache(), size = CGSize(width: 160, height: 214)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 428, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: size); image.addRepresentation(bitmap)
        var pages: [PDFPage] = []
        for _ in 0..<40 { pages.append(PDFPage(image: image)!) }
        cache.insert(image, for: pages[0], size: size, revision: "one")
        check(cache.image(for: pages[0], size: size, revision: "one") === image, "Reopening a thumbnail reuses its bitmap")
        check(cache.image(for: pages[0], size: size, revision: "two") == nil, "Document edits invalidate stale thumbnails")
        pages[0].rotation = 90
        check(cache.image(for: pages[0], size: size, revision: "one") == nil, "Page rotation invalidates the cached orientation")
        for page in pages { cache.insert(image, for: page, size: size, revision: "one") }
        check(cache.bytes <= PDFThumbnailCache.byteLimit && cache.count <= PDFThumbnailCache.countLimit, "Thumbnail retention respects both byte and item limits")
        check(cache.image(for: pages[1], size: size, revision: "one") == nil, "Old thumbnails are evicted instead of growing without limit")
        let document = PDFDocument(); document.insert(pages.last!, at: 0)
        let probe = Probe(), host = NSHostingView(rootView: SplitFixture(probe: probe, document: document))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: 1100, height: 700)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40))
        for _ in 0..<12 {
            probe.shown = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(8))
            probe.shown = false; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(160))
        check(probe.makes == 1, "Repeated PDF sidebar toggles keep the same document canvas")
        check(Set(probe.widths).count <= 4, "PDF toggles do not send a sequence of animated widths to the document")
        check(PDFThumbnailCache.shared.count == 0, "Rapidly hidden panes do not render delayed off-screen thumbnails")
        let presentation = PDFSidebarPresentation()
        presentation.setShown(true, animated: true)
        check(presentation.mounted && !presentation.visible, "Opening reserves document space once before the sidebar reveal")
        presentation.appeared()
        check(presentation.visible, "The mounted sidebar animates its appearance independently")
        presentation.setShown(false, animated: true)
        check(presentation.mounted && !presentation.visible, "Closing keeps the sidebar mounted only for its visual fade")
        presentation.setShown(true, animated: true)
        try await Task.sleep(for: .milliseconds(220))
        check(presentation.mounted && presentation.visible, "Reopening cancels stale hide completion during rapid toggles")
        presentation.setShown(false, animated: false)
        check(!presentation.mounted, "Disabled motion closes without a delayed document resize")
        let tour = WelcomeTourProgress(); tour.replay = true
        let tourHost = NSHostingView(rootView: TourFixture(progress: tour))
        window.setContentSize(.init(width: 800, height: 700)); window.contentView = tourHost; tourHost.frame = .init(x: 0, y: 0, width: 800, height: 700)
        tourHost.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40))
        let start = ContinuousClock.now
        tour.step = 1
        tourHost.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
        check(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || tour.transitioning, "Tour ignores repeated Next presses while animation is enabled")
        while tour.transitioning { try await Task.sleep(for: .milliseconds(20)) }
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        check(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || seconds >= 0.55, "Tour gives each animated transition at least 600 ms of room")
        preferences[AnimationPolicy.preference] = false
        defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        let quiet = WelcomeTourProgress(); quiet.replay = true
        let quietHost = NSHostingView(rootView: TourFixture(progress: quiet))
        window.contentView = quietHost; quietHost.frame = tourHost.frame; quietHost.layoutSubtreeIfNeeded()
        quiet.step = 1; try await Task.sleep(for: .milliseconds(50))
        check(!quiet.transitioning, "Disabled animations do not impose an artificial navigation delay")
        let report: [String: Any] = ["checks": checks, "canvasInstances": probe.makes, "distinctWidths": Array(Set(probe.widths)).sorted(), "cacheBytes": cache.bytes, "cacheItems": cache.count, "tourTransitionSeconds": seconds]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        window.orderOut(nil)
        print("Passed \(checks) reader performance checks"); exit(0)
    } catch { print("FAILED: \(error)"); exit(1) }
}
app.run()
