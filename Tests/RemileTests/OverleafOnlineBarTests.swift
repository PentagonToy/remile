import AppKit
import SwiftUI
import XCTest
@testable import Remile

final class OverleafOnlineBarTests: XCTestCase {
    @MainActor func testReviewDecisionControlsAppearances() throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            for enabled in [false, true] {
                let view = HStack(spacing: RemileControl.spacing) {
                    SymbolLabel("Added", systemImage: "plus").foregroundStyle(RemileStyle.success)
                    Spacer(minLength: RemileControl.spacing)
                    OverleafReviewDecisionButtons(changeID: "capture") { _ in }.disabled(!enabled)
                }.font(RemileType.caption).padding(RemileControl.rowSpacing)
                    .background(RemileStyle.sidebar).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["REMILE_OVERLEAF_BAR_CAPTURE"] {
                    let name = "review-\(dark ? "dark" : "light")-\(enabled ? "enabled" : "disabled").png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
    @MainActor func testOnlineAndOnDeviceBarsFitBothWidthsAndAppearances() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "\\documentclass{article}\n\\begin{document}A page.\\end{document}".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        let library = OverleafLibrary(directory: root.appendingPathComponent("Library"))
        library.offlineMode = true
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "A paper", account: "Research", branch: "main")
        defer { UserDefaults.standard.removeObject(forKey: "overleaf.prefersLive." + connection.id.uuidString) }
        for online in [true, false] {
            OverleafSyncPreference.choose(online, for: connection.id)
            if online { await project.liveWorkspace.start(project: project, library: library, connection: connection) }
            else { await project.liveWorkspace.stop() }
            for dark in [false, true] {
                for width in [560.0, 1200.0] {
                    let view = OverleafBar(library: library, project: project, connection: connection)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 48)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let directory = ProcessInfo.processInfo.environment["REMILE_OVERLEAF_BAR_CAPTURE"] {
                        let name = "\(online ? "online" : "on-device")-\(dark ? "dark" : "light")-\(Int(width)).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                    XCTAssertEqual(host.bounds.width, width)
                }
            }
        }
        await project.liveWorkspace.stop()
    }
}
