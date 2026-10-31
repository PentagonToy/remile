import AppKit
import PDFKit
import XCTest
@testable import Remile

@MainActor final class PDFTabOpeningTests: XCTestCase {
    func testPreparedSessionsKeepPreviouslyStoredRecentProjects() {
        let store = UserDefaults.standard
        let keys = ["reader.recentDocuments", "reader.hiddenRecentDocuments", "reader.lastOpened"]
        let previous = keys.map { store.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) } }
        }
        let project = "/tmp/remile-existing-project", markdown = "/tmp/remile-existing-note.md"
        store.set([project, markdown], forKey: keys[0])
        store.set([String](), forKey: keys[1])
        store.set([project: 10.0, markdown: 11.0], forKey: keys[2])
        let model = HomeModel()
        model.recordRecent(URL(fileURLWithPath: "/tmp/remile-new-document.pdf"))
        XCTAssertEqual(Array((store.stringArray(forKey: keys[0]) ?? []).prefix(3)), ["/tmp/remile-new-document.pdf", project, markdown])
        XCTAssertEqual(store.dictionary(forKey: keys[2])?[project] as? Double, 10)
    }
    func testNewTabHasItsDocumentBeforeTheWindowIsRegistered() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 200, height: 240))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 240).fill(); image.unlockFocus()
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let data = try XCTUnwrap(pdf.dataRepresentation())
        let firstURL = root.appendingPathComponent("first.pdf"), secondURL = root.appendingPathComponent("second.pdf")
        try data.write(to: firstURL); try data.write(to: secondURL)
        let windows = RemileWindows()
        let first = HomeModel()
        try first.reader.open(firstURL, data: data, recordRecent: false)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        windows.register(first, window: parent)
        var created: HomeModel?
        var child: NSWindow?
        windows.createWindow = {
            let model = windows.makeHome(recordRecent: false)
            XCTAssertEqual(model.reader.url, secondURL, "No empty Home state may be shown in the new tab")
            XCTAssertFalse(model.opening)
            let window = NSWindow(contentRect: parent.frame, styleMask: [.titled], backing: .buffered, defer: false)
            created = model; child = window; windows.register(model, window: window)
        }
        defer {
            windows.createWindow = nil
            if let child { windows.remove(child); child.orderOut(nil) }
            windows.remove(parent); parent.orderOut(nil)
        }
        XCTAssertTrue(windows.openPDFTab(secondURL, from: first))
        XCTAssertEqual(first.reader.url, firstURL)
        for _ in 0..<100 where created == nil { try await Task.sleep(for: .milliseconds(20)) }
        let second = try XCTUnwrap(created)
        XCTAssertEqual(second.reader.url, secondURL)
        XCTAssertEqual(windows.documentTabs(for: second.reader).count, 2)
        XCTAssertTrue(windows.active === second)
    }
}
