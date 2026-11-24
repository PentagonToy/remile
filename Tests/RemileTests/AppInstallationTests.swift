import XCTest
@testable import Remile

final class AppInstallationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remile-install-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func application(in folder: URL, name: String = "remile.app", version: String = "1", identifier: String = AppInstallation.identifier) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleVersion": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data(version.utf8).write(to: contents.appendingPathComponent("fixture.txt"))
        return url
    }
    private func contents(_ application: URL) throws -> String {
        try String(contentsOf: application.appendingPathComponent("Contents/fixture.txt"), encoding: .utf8)
    }
    func testOnlyReadOnlyAppBundlesOfferInstallation() {
        let app = URL(fileURLWithPath: "/Volumes/Installer/remile.app")
        XCTAssertTrue(AppInstallation.shouldOffer(application: app, readOnlyVolume: true))
        XCTAssertFalse(AppInstallation.shouldOffer(application: app, readOnlyVolume: false))
        XCTAssertFalse(AppInstallation.shouldOffer(application: URL(fileURLWithPath: "/tmp/Remile"), readOnlyVolume: true))
        XCTAssertFalse(AppInstallation.shouldOffer(application: URL(string: "https://example.org/remile.app")!, readOnlyVolume: true))
    }
    func testFreshInstallCopiesWithoutChangingTheSource() throws {
        let root = try directory(), source = try application(in: root)
        let destination = root.appendingPathComponent("Applications/remile.app")
        let staged = try AppInstallation.stage(source: source, destination: destination, validate: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try AppInstallation.commit(staged: staged, destination: destination, validate: { _ in })
        XCTAssertEqual(try contents(destination), "1")
        XCTAssertEqual(try contents(source), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testReplacementKeepsOldAppUntilCommitAndLeavesNoBackup() throws {
        let root = try directory(), source = try application(in: root, version: "2")
        let folder = root.appendingPathComponent("Applications")
        let destination = try application(in: folder)
        let staged = try AppInstallation.stage(source: source, destination: destination, validate: { _ in })
        XCTAssertEqual(try contents(destination), "1")
        try AppInstallation.commit(staged: staged, destination: destination, validate: { _ in })
        XCTAssertEqual(try contents(destination), "2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["remile.app"])
    }
    func testFailedVerificationKeepsOldAppAndRemovesPartialCopy() throws {
        let root = try directory(), source = try application(in: root, version: "2")
        let folder = root.appendingPathComponent("Applications"), destination = try application(in: folder)
        XCTAssertThrowsError(try AppInstallation.stage(source: source, destination: destination, validate: { _ in throw CocoaError(.fileReadCorruptFile) }))
        XCTAssertEqual(try contents(destination), "1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["remile.app"])
        let staged = try AppInstallation.stage(source: source, destination: destination, validate: { _ in })
        defer { try? FileManager.default.removeItem(at: staged) }
        XCTAssertThrowsError(try AppInstallation.commit(staged: staged, destination: destination, validate: { _ in throw CocoaError(.fileReadCorruptFile) }))
        XCTAssertEqual(try contents(destination), "1")
    }
    func testOtherApplicationsAndSymlinksAreNotReplaced() throws {
        let root = try directory(), source = try application(in: root)
        let other = try application(in: root.appendingPathComponent("Other"), identifier: "example.another-app")
        XCTAssertThrowsError(try AppInstallation.stage(source: source, destination: other, validate: { _ in }))
        let destination = root.appendingPathComponent("Link/remile.app")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: other)
        XCTAssertThrowsError(try AppInstallation.stage(source: source, destination: destination, validate: { _ in }))
        XCTAssertEqual(try contents(other), "1")
        XCTAssertTrue(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
    func testItemAppearingBeforeCommitIsNotOverwritten() throws {
        let root = try directory(), source = try application(in: root)
        let folder = root.appendingPathComponent("Applications"), destination = folder.appendingPathComponent("remile.app")
        let staged = try AppInstallation.stage(source: source, destination: destination, validate: { _ in })
        defer { try? FileManager.default.removeItem(at: staged) }
        try Data("Unrelated file".utf8).write(to: destination)
        XCTAssertThrowsError(try AppInstallation.commit(staged: staged, destination: destination, validate: { _ in }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Unrelated file")
    }
    func testUnsignedAppIsRejectedAndNewerBuildIsRecognised() throws {
        let root = try directory(), source = try application(in: root, version: "9")
        let newer = try application(in: root, name: "Newer.app", version: "10")
        XCTAssertThrowsError(try AppInstallation.verify(source))
        XCTAssertTrue(AppInstallation.isNewer(installed: try XCTUnwrap(Bundle(url: newer)), source: try XCTUnwrap(Bundle(url: source))))
        XCTAssertFalse(AppInstallation.isNewer(installed: try XCTUnwrap(Bundle(url: source)), source: try XCTUnwrap(Bundle(url: newer))))
    }
}
