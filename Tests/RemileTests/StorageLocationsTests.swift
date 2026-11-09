import Foundation
import SwiftUI
import XCTest
@testable import Remile

final class StorageLocationsTests: XCTestCase {
    @MainActor func testStorageFormRendersAtSettingsWidth() throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let frame = NSRect(x: 0, y: 0, width: 540, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        let view = NSHostingView(rootView: StorageSettings().background(RemileStyle.background).environment(\.colorScheme, .dark))
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let capture = ProcessInfo.processInfo.environment["REMILE_STORAGE_CAPTURE"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture))
        }
    }

    func testStorageAndReferenceChangeIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "remile.test.storage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = directory.appendingPathComponent("first")
        let library = first.appendingPathComponent("Reference")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let catalogue = Data(#"{"schema":1,"records":[]}"#.utf8)
        try catalogue.write(to: library.appendingPathComponent("library.json"))
        try Data(#"{"schema":1}"#.utf8).write(to: first.appendingPathComponent("remile-storage.json"))
        defaults.set(first.path, forKey: StorageLocation.preference)
        defaults.set(library.path, forKey: StoragePaths.referencePreference)

        let machine = StorageLocation.machineID(defaults: defaults)
        let marksPath = StorageLocation.overleafMarksFolder + "/" + machine
        let marks = first.appendingPathComponent(marksPath)
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: marks.appendingPathComponent("marker"))
        let second = directory.appendingPathComponent("second")
        try StoragePaths.scheduleStorage(second, defaults: defaults)
        try StoragePaths.applyPendingStorage(defaults: defaults)
        XCTAssertEqual(StoragePaths.reference(defaults: defaults).path, library.path)
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent(marksPath + "/marker")), Data("fixture".utf8))

        try StoragePaths.scheduleReference(directory, opening: false, defaults: defaults)
        try StoragePaths.applyPendingReference(defaults: defaults)
        let moved = directory.appendingPathComponent("remile-reference")
        XCTAssertEqual(StoragePaths.reference(defaults: defaults).path, moved.path)
        XCTAssertEqual(StorageLocation.root(defaults: defaults).path, second.path)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("library.json")), catalogue)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("library.json")), catalogue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("relocated.json").path))

        try StoragePaths.scheduleReference(library, opening: true, defaults: defaults)
        try StoragePaths.applyPendingReference(defaults: defaults)
        XCTAssertTrue(StoragePaths.isReadOnly(library, defaults: defaults))
        XCTAssertEqual(StorageLocation.root(defaults: defaults).path, second.path)
    }
}
