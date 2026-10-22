import AppKit
import SwiftUI

@_cdecl("__isPlatformVersionAtLeast")
public func hostVersionAtLeast(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: Int(a), minorVersion: Int(b), patchVersion: Int(c))) ? 1 : 0 }
struct FrameProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier(name); return view }
    func updateNSView(_ view: NSView, context: Context) {}
}
func find(_ name: String, in view: NSView) -> NSView? { if view.identifier?.rawValue == name { return view }; return view.subviews.lazy.compactMap { find(name, in: $0) }.first }
var passed = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); passed += 1; print("PASS: " + label) }
let output = URL(fileURLWithPath: CommandLine.arguments[1]), app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var metrics: [String: Any] = [:]
        for equal in [false, true] {
            // Native view frames expose the actual split, independently of preferred-width arithmetic.
            let probed = NSHostingView(rootView: ReaderSplit(sizing: equal ? .equal : .sidebar, minimum: equal ? 280 : ReaderSidebar.minimum, maximum: equal ? .greatestFiniteMagnitude : ReaderSidebar.maximum, minimumContent: 280, pane: { Color.red.overlay(FrameProbe(name: "left")) }, content: { Color.blue.overlay(FrameProbe(name: "right")) }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = probed; window.orderFront(nil)
            for size in [CGFloat(900), 1200, 1800, 1050] {
                window.setContentSize(NSSize(width: size, height: 500)); probed.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); probed.layoutSubtreeIfNeeded()
                let left = find("left", in: probed)!.bounds.width, right = find("right", in: probed)!.bounds.width
                check(abs(left + right + 14 - size) < 1, "Both panes fill the available width at \(size)")
                if equal { check(abs(left - right) < 1, "Markdown starts and resizes equally at \(size)") }
                else { check(abs(left - ReaderSidebar.preferredWidth(in: size)) < 1, "Navigation uses the shared responsive width at \(size)") }
                metrics[(equal ? "equal" : "sidebar") + String(Int(size))] = ["left": left, "right": right]
            }
            window.orderOut(nil)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[2]), source = try String(contentsOf: url, encoding: .utf8)
        let controller = MarkdownEditorController(), scroll = controller.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll; controller.update(source, size: 17, serif: false)
        let review = EditorWritingReview(), start = Date()
        await review.check(source, enabled: true, language: "Automatic", editor: controller)
        let deadline = Date().addingTimeInterval(45)
        while review.checking && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        check(!review.checking && !review.issues.isEmpty, "Stress-document spelling check completes")
        check(review.issues.count <= 100, "Only the bounded issue list is retained")
        let spelling = review.issues.filter { $0.message == "Spelling" }
        check(!spelling.isEmpty && spelling.allSatisfy { $0.replacement == nil && $0.alternatives.isEmpty }, "Background checks do not prepare word alternatives")
        check(controller.textView?.string == source, "Reviewing the stress document preserves its source")
        metrics["spellCheckSeconds"] = Date().timeIntervalSince(start); metrics["issues"] = review.issues.count; metrics["sourceBytes"] = source.utf8.count
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("metrics.json"))
        print("Passed \(passed) reading layout and stress checks"); exit(0)
    } catch { print("FAILED:", error); exit(1) }
}
app.run()
