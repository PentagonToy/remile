import AppKit
import PDFKit
import Security
import XCTest
import SwiftUI

@testable import Remile

final class RemarkableExtensionTests: XCTestCase {
    @MainActor func testSSHDeviceSnapshotRendersWhenSupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["REMILE_SSH_EVIDENCE"] else {
            throw XCTSkip("Supply a read-only device snapshot to verify its native PDF rendering.")
        }
        let root = URL(fileURLWithPath: path)
        let reply = try JSONDecoder().decode(RemarkableCloudReply.self, from: Data(contentsOf: root.appendingPathComponent("device-reply.json")))
        let directory = try String(contentsOf: root.appendingPathComponent("device-directory.txt"), encoding: .utf8)
        let file = try RemarkablePDF.render(reply, in: URL(fileURLWithPath: directory))
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertEqual(pdf.pageCount, reply.pages?.count)
        if let name = reply.background, let original = PDFDocument(url: URL(fileURLWithPath: directory).appendingPathComponent(name)) {
            for (index, page) in (reply.pages ?? []).enumerated() where page.svg == nil {
                guard let sourceIndex = page.backgroundPage else { continue }
                XCTAssertEqual(pdf.page(at: index)?.bounds(for: .mediaBox), original.page(at: sourceIndex)?.bounds(for: .mediaBox))
                XCTAssertEqual(pdf.page(at: index)?.string, original.page(at: sourceIndex)?.string)
            }
        }
        let page = try XCTUnwrap(pdf.page(at: 0))
        let thumbnail = page.thumbnail(of: NSSize(width: 480, height: 720), for: .mediaBox)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumbnail.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("device-preview.png"))
    }
    func testExtensionRequiresExplicitEnablementAndCanBeDisabledAgain() throws {
        let suite = "local.remile.tests.extensions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try RemarkableExtensionAccess.requireEnabled(in: defaults))
        defaults.set(true, forKey: RemarkableExtensionAccess.enabledKey)
        XCTAssertThrowsError(try RemarkableExtensionAccess.requireEnabled(in: defaults))
        defaults.set(RemarkableExtensionAccess.consentVersion, forKey: RemarkableExtensionAccess.consentKey)
        XCTAssertNoThrow(try RemarkableExtensionAccess.requireEnabled(in: defaults))
        defaults.set(false, forKey: RemarkableExtensionAccess.enabledKey)
        XCTAssertThrowsError(try RemarkableExtensionAccess.requireEnabled(in: defaults))
    }
    @MainActor func testExtensionCardRendersBothSwitchStates() throws {
        _ = NSApplication.shared
        let suite = "local.remile.tests.extension-card." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for active in [false, true] {
            defaults.set(active, forKey: RemarkableExtensionAccess.enabledKey)
            defaults.set(RemarkableExtensionAccess.consentVersion, forKey: RemarkableExtensionAccess.consentKey)
            let root = ExtensionsWorkspace(references: ReferenceModel(), showReference: {})
                .defaultAppStorage(defaults).frame(width: 520, height: 280).background(RemileStyle.background)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 280)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["REMILE_FOLDER_CAPTURE"] {
                let file = URL(fileURLWithPath: directory).appendingPathComponent(active ? "card-on.png" : "card-off.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }
    func testSavedCredentialCanBeReadBack() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.remile.tests.remarkable." + UUID().uuidString,
            kSecAttrAccount as String: "synthetic-device",
        ]
        defer { _ = KeychainAccess.remove(matching: query) }
        let token = "synthetic-test-token"
        let status = KeychainAccess.store(Data(token.utf8), matching: query, attributes: [:])
        XCTAssertEqual(status, errSecSuccess)
        guard status == errSecSuccess else { return }
        XCTAssertTrue(RemarkableCredentials.exists(matching: query))
        XCTAssertEqual(RemarkableCredentials.read(matching: query), token)
    }
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remarkable-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func testReceivedPathsStayInsidePrivateDirectory() throws {
        XCTAssertEqual(try RemarkablePDF.child("ink.svg", in: folder).lastPathComponent, "ink.svg")
        XCTAssertThrowsError(try RemarkablePDF.child("../outside.pdf", in: folder))
        XCTAssertThrowsError(try RemarkablePDF.child("/etc/passwd", in: folder))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("escape"), withDestinationURL: folder.deletingLastPathComponent())
        XCTAssertThrowsError(try RemarkablePDF.child("escape/other.pdf", in: folder))
    }
    func testMovePreviewPageCountAndBounds() throws {
        let svg =
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"20\" viewBox=\"0 0 30 20\"><path d=\"M0 0 L30 20\" fill=\"none\" stroke=\"black\"/></svg>"
        try Data(svg.utf8).write(to: folder.appendingPathComponent("ink.svg"))
        let source = #"{"ok":true,"pages":[{"id":"one","svg":"ink.svg","bounds":[0,0,30,20]},{"id":"two"}]}"#
        let reply = try JSONDecoder().decode(RemarkableCloudReply.self, from: Data(source.utf8))
        let file = try RemarkablePDF.render(reply, in: folder)
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertEqual(pdf.pageCount, 2)
        let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 954 * 72.0 / 226, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 1696 * 72.0 / 226, accuracy: 0.01)
    }
    func testOlderNotebookCanvasDoesNotClipWideInk() throws {
        let svg =
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"-230 -30 460 630\"><path d=\"M-230 -30 L230 600\" stroke=\"black\"/></svg>"
        try Data(svg.utf8).write(to: folder.appendingPathComponent("wide.svg"))
        let source = #"{"ok":true,"pages":[{"id":"wide","svg":"wide.svg","bounds":[-230,-30,460,630]}]}"#
        let reply = try JSONDecoder().decode(RemarkableCloudReply.self, from: Data(source.utf8))
        let url = try RemarkablePDF.render(reply, in: folder)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 460, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 630, accuracy: 0.01)
    }
    func testMissingInkAndInvalidBackgroundFail() throws {
        for source in [
            #"{"ok":true,"pages":[]}"#,
            #"{"ok":true,"pages":[{"id":"one","svg":"missing.svg","bounds":[0,0,10,10]}]}"#,
            #"{"ok":true,"pages":[{"id":"one","backgroundPage":0}],"background":"missing.pdf"}"#,
        ] {
            let reply = try JSONDecoder().decode(RemarkableCloudReply.self, from: Data(source.utf8))
            XCTAssertThrowsError(try RemarkablePDF.render(reply, in: folder))
        }
    }
    func testMixedDocumentPreservesUnmarkedPageBoxesRotationAndAnnotations() throws {
        let document = PDFDocument()
        for _ in 0..<2 {
            let image = NSImage(size: NSSize(width: 600, height: 800))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill(); image.unlockFocus()
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount)
        }
        let first = try XCTUnwrap(document.page(at: 0))
        first.rotation = 90
        first.setBounds(CGRect(x: 10, y: 20, width: 500, height: 700), for: .cropBox)
        first.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 50, height: 10), forType: .highlight, withProperties: nil))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Synthetic paper"]
        XCTAssertTrue(document.write(to: folder.appendingPathComponent("source.pdf")))
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 20"><path d="M0 0 L30 20" stroke="black"/></svg>"#.utf8).write(to: folder.appendingPathComponent("ink.svg"))
        let data = #"{"ok":true,"background":"source.pdf","pages":[{"id":"one","backgroundPage":0},{"id":"two","backgroundPage":1,"svg":"ink.svg","bounds":[0,0,30,20]}]}"#
        let reply = try JSONDecoder().decode(RemarkableCloudReply.self, from: Data(data.utf8))
        let result = try XCTUnwrap(PDFDocument(url: RemarkablePDF.render(reply, in: folder)))
        let preserved = try XCTUnwrap(result.page(at: 0))
        XCTAssertEqual(preserved.bounds(for: .mediaBox), first.bounds(for: .mediaBox))
        XCTAssertEqual(preserved.bounds(for: .cropBox), first.bounds(for: .cropBox))
        XCTAssertEqual(preserved.rotation, 90)
        XCTAssertEqual(preserved.annotations.count, first.annotations.count)
        XCTAssertEqual(result.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Synthetic paper")
        XCTAssertNotEqual(result.page(at: 1)?.bounds(for: .mediaBox), first.bounds(for: .mediaBox))
    }
}
