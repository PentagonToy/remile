import AppKit
import SwiftUI
import XCTest
@testable import Remile

final class RemarkableSetupTests: XCTestCase {
    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("others/extensions/remarkable/runtime.json")
    }
    func testPinnedDownloadsRejectUnexpectedOriginsAndManifestPaths() throws {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try RemarkableRuntimeManifest.decode(data)
        XCTAssertEqual(Set(manifest.packages.compactMap(\.name)), ["rmc", "rmscene", "click", "packaging"])
        XCTAssertFalse(RemarkableRuntimeManifest.allowed(URL(string: "http://files.pythonhosted.org/a")!))
        XCTAssertFalse(RemarkableRuntimeManifest.allowed(URL(string: "https://files.pythonhosted.org.attacker.example/a")!))
        XCTAssertFalse(RemarkableRuntimeManifest.allowed(URL(string: "https://user@github.com/a")!))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["id"] = "../outside"
        XCTAssertThrowsError(try RemarkableRuntimeManifest.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testDuplicatePackageNamesCannotReachInstallation() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var packages = try XCTUnwrap(object["packages"] as? [[String: Any]])
        var duplicate = packages[0]
        duplicate["filename"] = "another.whl"
        duplicate["name"] = (packages[0]["name"] as? String)?.uppercased()
        packages.append(duplicate)
        object["packages"] = packages
        XCTAssertThrowsError(try RemarkableRuntimeManifest.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testCancelledInstallCannotPublishItsStagedRuntime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stage = folder.appendingPathComponent("stage")
        let destination = folder.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await RemarkableToolStorage.shared.publish(stage, to: destination)
        }
        do { try await task.value; XCTFail("Cancelled installation must not publish") }
        catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testVerificationRejectsCorruptedAndTruncatedTools() throws {
        let asset = RemarkableRuntimeManifest.Asset(filename: "test", url: URL(string: "https://github.com/a")!, bytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertNoThrow(try RemarkableRuntimeManifest.verify(file, asset: asset))
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try RemarkableRuntimeManifest.verify(file, asset: asset))
        try Data("ab".utf8).write(to: file)
        XCTAssertThrowsError(try RemarkableRuntimeManifest.verify(file, asset: asset))
    }
    func testCancellingSetupTerminatesChildPromptly() async throws {
        let start = Date()
        let task = Task { try await RemarkableToolInstaller.run("/bin/sleep", ["30"], in: FileManager.default.temporaryDirectory) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled child must fail") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    @MainActor func testResponsiveCardsAndConsentRender() throws {
        _ = NSApplication.shared
        let suite = "local.remile.tests.setup." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ExtensionCardLayout.count(for: 480), 1)
        XCTAssertEqual(ExtensionCardLayout.count(for: 760), 2)
        XCTAssertEqual(ExtensionCardLayout.count(for: 1100), 3)
        XCTAssertEqual(ExtensionCardLayout.count(for: 1800), 3)
        for width in [480.0, 760.0, 1100.0] {
            for dark in [false, true] {
                let root = ExtensionsWorkspace(references: ReferenceModel(), showReference: {}).defaultAppStorage(defaults)
                    .frame(width: width, height: 300).background(RemileStyle.background)
                try capture(root, name: "extensions-\(Int(width))-\(dark ? "dark" : "light")", width: width, height: 300, dark: dark)
            }
        }
        for dark in [false, true] {
            try capture(RemarkableConsent(agree: {}, disagree: {}), name: "consent-\(dark)", width: 440, height: 320, dark: dark)
            try capture(RemarkableSetup(done: {}), name: "setup-\(dark)", width: 440, height: 300, dark: dark)
        }
    }
    @MainActor private func capture<V: View>(_ root: V, name: String, width: Double, height: Double, dark: Bool) throws {
        let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["REMILE_SETUP_CAPTURE"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
    func testCleanDownloadInstallAndRelocationWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["REMILE_SETUP_INTEGRATION"] else { throw XCTSkip("Explicit network installation check only") }
        let root = URL(fileURLWithPath: output)
        let manifest = try RemarkableRuntimeManifest.decode(Data(contentsOf: manifestURL))
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var values = old
        values[RemarkableExtensionAccess.enabledKey] = true
        values[RemarkableExtensionAccess.consentKey] = RemarkableExtensionAccess.consentVersion
        values[NetworkAccessGate.preference] = false
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
        let path = try await RemarkableToolInstaller.install(manifest, at: root) { _ in }
        try await RemarkableToolInstaller.check(path, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/python3.12/LICENSE.txt").path))
        let again = try await RemarkableToolInstaller.install(manifest, at: root) { _ in XCTFail("Working runtime must be reused") }
        XCTAssertEqual(path, again)
        let receipt = root.appendingPathComponent("Runtime-" + manifest.id + "/remile-runtime.json")
        let saved = try Data(contentsOf: receipt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["id"] = "failure-fixture"
        var pythonAsset = try XCTUnwrap(object["python"] as? [String: Any])
        pythonAsset["sha256"] = String(repeating: "0", count: 64)
        object["python"] = pythonAsset
        let broken = try RemarkableRuntimeManifest.decode(JSONSerialization.data(withJSONObject: object))
        do { _ = try await RemarkableToolInstaller.install(broken, at: root) { _ in }; XCTFail("Corrupt download must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: receipt), saved)
        try await RemarkableToolInstaller.check(path, in: root)

        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("Setup-") }))
        let imported = root.appendingPathComponent("Imported.pdf")
        try Data("Keep this imported document".utf8).write(to: imported)
        values[RemarkableExtensionAccess.enabledKey] = false
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        try await RemarkableToolStorage.shared.removeInstalled(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))

    }
}
