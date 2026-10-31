import XCTest
import SwiftUI
@testable import Remile

final class OverleafReviewAccessTests: XCTestCase {
    @MainActor func testDisabledReviewNoticeRendersWithoutAConnection() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: OverleafReviewAccess.key)
        defaults.removeObject(forKey: OverleafReviewAccess.key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let previous { defaults.set(previous, forKey: OverleafReviewAccess.key) }
            else { defaults.removeObject(forKey: OverleafReviewAccess.key) }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "\\documentclass{article}\n\\begin{document}Fixture\\end{document}".write(to: root.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        let project = try TeXProject(root, historyEnabled: false)
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "Fixture", account: "Fixture", branch: "main")
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let host = NSHostingView(rootView: OverleafReviewPanel(project: project, connection: connection).frame(width: 280, height: 350))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 350)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["REMILE_REVIEW_ACCESS_CAPTURE"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            }
        }
        XCTAssertNil(project.overleafReview)
    }
    func testReviewRequiresAnExplicitChoiceAndCanBeRevoked() throws {
        let suite = "remile.review-access." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try OverleafReviewAccess.requireEnabled(in: defaults))
        defaults.set(true, forKey: OverleafReviewAccess.key)
        XCTAssertNoThrow(try OverleafReviewAccess.requireEnabled(in: defaults))
        defaults.set(false, forKey: OverleafReviewAccess.key)
        XCTAssertThrowsError(try OverleafReviewAccess.requireEnabled(in: defaults))
    }
    @MainActor func testReviewReadIsBlockedBeforeNetworkOrCredentials() async {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: OverleafReviewAccess.key)
        defaults.removeObject(forKey: OverleafReviewAccess.key)
        defer {
            if let previous { defaults.set(previous, forKey: OverleafReviewAccess.key) }
            else { defaults.removeObject(forKey: OverleafReviewAccess.key) }
        }
        for path in ["/project/" + String(repeating: "a", count: 24) + "/threads",
                     "/Project/" + String(repeating: "a", count: 24) + "/doc/" + String(repeating: "b", count: 24) + "/download"] {
            do {
                _ = try await OverleafWebClient.request(path, profile: UUID(), document: path.hasSuffix("download"))
                XCTFail("Review access must remain disabled")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Enable the review connection")) }
        }
    }
}
