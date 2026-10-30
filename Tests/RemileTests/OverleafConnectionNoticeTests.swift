import AppKit
import SwiftUI
import XCTest
@testable import Remile

final class OverleafConnectionNoticeTests: XCTestCase {
    @MainActor func testDecliningOrDismissingDoesNotOpenTheConnection() throws {
        try withUnacceptedNotice { library, defaults in
            library.openLibrary()
            XCTAssertTrue(library.connectionNoticePresented)
            XCTAssertFalse(library.browsing)
            library.respondToConnectionNotice(agree: false)
            library.finishConnectionNotice()
            XCTAssertFalse(OverleafConnectionNotice.accepted(in: defaults))
            XCTAssertFalse(library.browsing)
            XCTAssertFalse(library.presented)
            var opened = false
            library.requestConnection { opened = true }
            library.connectionNoticePresented = false
            library.finishConnectionNotice()
            XCTAssertFalse(opened)
        }
    }
    @MainActor func testAgreeContinuesAfterDismissalAndIsRemembered() throws {
        _ = NSApplication.shared
        try withUnacceptedNotice { library, defaults in
            library.openLibrary(add: true)
            XCTAssertTrue(library.connectionNoticePresented)
            XCTAssertFalse(library.presented)
            library.respondToConnectionNotice(agree: true)
            XCTAssertTrue(OverleafConnectionNotice.accepted(in: defaults))
            XCTAssertFalse(library.presented)
            library.finishConnectionNotice()
            XCTAssertTrue(library.presented)
            library.presented = false
            library.openLibrary()
            XCTAssertFalse(library.connectionNoticePresented)
            XCTAssertTrue(library.browsing)
            library.browsing = false
            library.finishConnectionNotice()
            XCTAssertFalse(library.browsing)
        }
    }
    @MainActor private func withUnacceptedNotice(_ work: (OverleafLibrary, UserDefaults) throws -> Void) throws {
        let suite = "local.remile.tests.overleaf-notice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try work(OverleafLibrary(directory: root, connectionNoticeDefaults: defaults), defaults)
    }
    @MainActor func testNoticeAndNativeLeafRenderInBothAppearances() throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let root = OverleafConnectionNotice(agree: {}, disagree: {}).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 440, height: 270)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["REMILE_OVERLEAF_NOTICE_CAPTURE"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("notice-\(dark ? "dark" : "light").png"))
            }
            let mark = NSHostingView(rootView: OverleafMark().foregroundStyle(RemileStyle.ink).padding(12).background(RemileStyle.background).environment(\.colorScheme, dark ? .dark : .light))
            mark.appearance = host.appearance
            mark.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
            mark.layoutSubtreeIfNeeded()
            let symbol = try XCTUnwrap(mark.bitmapImageRepForCachingDisplay(in: mark.bounds))
            mark.cacheDisplay(in: mark.bounds, to: symbol)
            if let directory = ProcessInfo.processInfo.environment["REMILE_OVERLEAF_NOTICE_CAPTURE"] {
                try XCTUnwrap(symbol.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("leaf-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
