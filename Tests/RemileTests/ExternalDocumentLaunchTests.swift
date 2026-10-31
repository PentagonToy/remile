import XCTest
import AppKit
@testable import Remile

final class ExternalDocumentLaunchTests: XCTestCase {
    @MainActor func testWindowAttachmentIsReportedAfterConstruction() {
        _ = NSApplication.shared
        let view = WindowCloseGuard.AttachmentView()
        var attached: NSWindow?
        view.attached = { attached = $0 }
        XCTAssertNil(attached)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        XCTAssertTrue(attached === window)
        window.contentView = nil
        attached = nil
        window.contentView = view
        XCTAssertTrue(attached === window, "Moving back to a window must retry registration")
        window.contentView = nil
    }
    @MainActor func testOrdinaryActionsWaitForTheirWindow() {
        _ = NSApplication.shared
        let windows = RemileWindows()
        var calls = 0
        windows.perform { _ in calls += 1 }
        let home = windows.makeHome(recordRecent: false)
        XCTAssertEqual(calls, 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        windows.register(home, window: window)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testQueuedExternalOpenIsAppliedBeforeWindowRegistration() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("README.md")
        let windows = RemileWindows()
        windows.openExternalDocument(file)
        let home = windows.makeHome(recordRecent: false)
        XCTAssertTrue(home.opening, "The initial surface must show opening, not Home")
        for _ in 0..<100 where home.opening { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(home.error, "A missing file must finish through the normal error path")
        let another = windows.makeHome(recordRecent: false)
        XCTAssertNil(another.reader.url, "Consume the launch request exactly once")
    }
}
