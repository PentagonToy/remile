import XCTest
import SwiftUI
@testable import Remile

@MainActor final class TeXFileTabTests: XCTestCase {
    func testTabStripLightDarkAndNarrowCaptures() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["main.tex", "method-with-a-long-file-name.tex", "references.bib"] {
            try "\\documentclass{article}\n\\begin{document}Text\\end{document}".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let project = try TeXProject(root, historyEnabled: false)
        project.selected = "references.bib"; project.selected = "method-with-a-long-file-name.tex"
        for dark in [false, true] {
            for width in [560.0, 1200.0] {
                let host = NSHostingView(rootView: TeXFileTabs(project: project, showFiles: {}).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 39)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["REMILE_SOURCE_TAB_CAPTURE"] {
                    let name = "source-tabs-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
    }
    func testSelectReorderAndCloseKeepUnsavedBuffers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["main.tex", "one.tex", "two.tex"] {
            try "\\documentclass{article}\n\\begin{document}Text\\end{document}".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let project = try TeXProject(root, historyEnabled: false)
        XCTAssertEqual(project.openFiles, [project.main])
        project.selected = "one.tex"; project.selected = "two.tex"; project.selected = "one.tex"
        XCTAssertEqual(project.openFiles, ["main.tex", "one.tex", "two.tex"])
        project.cycleFileTab(forward: false)
        XCTAssertEqual(project.selected, "main.tex")
        project.cycleFileTab(forward: false)
        XCTAssertEqual(project.selected, "two.tex")
        project.cycleFileTab(forward: true)
        XCTAssertEqual(project.selected, "main.tex")
        project.buffers["one.tex"] = "Unsaved writing"
        project.moveFileTab("two.tex", to: "main.tex", after: false)
        XCTAssertEqual(project.openFiles, ["two.tex", "main.tex", "one.tex"])
        XCTAssertEqual(project.selected, "two.tex")
        project.closeFileTab("one.tex")
        XCTAssertEqual(project.buffers["one.tex"], "Unsaved writing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.tex").path))
        XCTAssertTrue(project.closeSelectedFileTab())
        XCTAssertEqual(project.selected, "main.tex")
        project.closeFileTab("main.tex")
        XCTAssertFalse(project.closeSelectedFileTab())
        XCTAssertEqual(project.openFiles, ["main.tex"])
        project.selected = "one.tex"
        XCTAssertEqual(project.buffers["one.tex"], "Unsaved writing")
        XCTAssertEqual(project.openFiles, ["main.tex", "one.tex"])
    }
}
