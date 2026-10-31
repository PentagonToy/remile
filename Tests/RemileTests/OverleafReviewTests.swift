import Foundation
import XCTest
@testable import Remile

final class OverleafReviewTests: XCTestCase {
    func testReviewDatesAcceptFractionalAndWholeSeconds() throws {
        let whole = try XCTUnwrap(OverleafReviewSnapshot.date("2026-10-31T06:35:00Z"))
        let fraction = try XCTUnwrap(OverleafReviewSnapshot.date("2026-10-31T06:35:00.123Z"))
        XCTAssertEqual(fraction.timeIntervalSince(whole), 0.123, accuracy: 0.001)
        XCTAssertNil(OverleafReviewSnapshot.date("not a date"))
    }
    func testChangeAuthorsUseNamesWithoutEmailFallback() throws {
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24), name: "Fixture", account: "Test", branch: "main")
        let archive = try OverleafThreadArchive.parse(Data("{}".utf8), project: connection)
        var snapshot = OverleafReviewSnapshot(archive: archive)
        let payload = Data(#"{"pathname":"main.tex","lines":["body"],"ranges":{"changes":[{"id":"c1","op":{"p":0,"d":"old"},"metadata":{"user_id":"u1"}},{"id":"c2","op":{"p":0,"d":"old"},"metadata":{"user_id":"u2"}}]}}"#.utf8)
        try snapshot.include(payload, documentID: "doc1")
        try snapshot.includeAuthors(Data(#"[{"id":"u1","first_name":"Hanseul","last_name":"Kang","email":"private@example.com"},{"id":"u2","email":"private@example.com"}]"#.utf8))
        XCTAssertEqual(snapshot.changes.first?.author, "Hanseul Kang")
        XCTAssertNil(snapshot.changes.last?.author)
        let exported = String(decoding: try snapshot.export(json: true), as: UTF8.self)
        XCTAssertTrue(exported.contains("Hanseul Kang"))
        XCTAssertFalse(exported.contains("private@example.com"))
    }
    private struct Fixture {
        let project: OverleafConnection
        let data: Data
        let archive: OverleafThreadArchive
        let document: Data
        let review: OverleafReviewSnapshot
        let anchor: OverleafReviewSnapshot.Anchor
        init() throws {
            let project = OverleafConnection(id: UUID(), projectID: "6ad72e207e5cd74f01fe6b18", name: "Example", account: "Personal", branch: "master")
            let data = Data(#"{"thread1":{"resolved":true,"resolved_at":"2026-10-20T09:00:00Z","messages":[{"id":"m1","content":"A note with <html> and [links](https://example.com)","timestamp":"2026-10-20T08:00:00Z","user":{"name":"Alex","email":"private@example.com"},"user_id":"user1"},{"id":"m2","content":"A reply","timestamp":"2026-10-20T08:30:00Z","user_id":"user2"}]}}"#.utf8)
            let archive = try OverleafThreadArchive.parse(data, project: project)
            let document = Data(#"{"pathname":"/chapters/method.tex","version":12,"lines":["😀 heading","Some adaptive text."],"ranges":{"comments":[{"op":{"t":"thread1","p":16,"c":"adaptive"}},{"op":{"t":"bad","p":1,"c":"x"}}],"changes":[{"id":"added","metadata":{"ts":"2026-10-26T06:00:00Z"},"op":{"p":16,"i":"adaptive"}},{"id":"deleted","op":{"p":16,"d":"old"}}]}}"#.utf8)
            var review = OverleafReviewSnapshot(archive: archive)
            try review.include(document, documentID: "doc1")
            let anchor = try XCTUnwrap(review.anchors["thread1"])
            self.project = project; self.data = data; self.archive = archive
            self.document = document; self.review = review; self.anchor = anchor
        }
    }
    func testArchiveAnchorsAndSafePaths() throws {
        let f = try Fixture()
        let project = f.project, archive = f.archive
        var review = f.review
        let anchor = f.anchor
        XCTAssertTrue(archive.threads.count == 1 && archive.threads[0].messages.count == 2)
        XCTAssertTrue(archive.threads[0].resolved && archive.threads[0].resolvedAt == "2026-10-20T09:00:00Z")
        XCTAssertTrue(archive.threads[0].messages[0].author == "Alex")
        let json = try archive.data(json: true), markdown = String(decoding: try archive.data(json: false), as: UTF8.self)
        XCTAssertTrue(!String(decoding: json, as: UTF8.self).contains("private@example.com"))
        XCTAssertTrue(markdown.contains("Reply") && markdown.contains("&lt;html&gt;") && markdown.contains("\\[links\\]"))
        let decoded = try JSONDecoder().decode(OverleafThreadArchive.self, from: json)
        XCTAssertTrue(decoded.threads[0].messages[1].id == "m2")
        let empty = try OverleafThreadArchive.parse(Data("{}".utf8), project: project)
        XCTAssertTrue(empty.threads.isEmpty)
        var rejected = false
        do { _ = try OverleafThreadArchive.parse(Data(#"{"thread1":{"messages":[{"content":"missing identity"}]}}"#.utf8), project: project) } catch { rejected = true }
        XCTAssertTrue(rejected)

        XCTAssertTrue(archive.threads[0].messages[1].author == "Contributor")
        let named = try OverleafThreadArchive.parse(Data(#"{"t":{"messages":[{"id":"m","content":"Hello","user":{"first_name":"Alex","last_name":"Toy"}}]}}"#.utf8), project: project)
        XCTAssertTrue(named.threads[0].messages[0].author == "Alex Toy")
        XCTAssertTrue(anchor.file == "chapters/method.tex" && anchor.line == 1 && anchor.version == 12)
        XCTAssertTrue(anchor.location(in: [anchor.file: anchor.source])?.range == NSRange(location: 16, length: 8))
        XCTAssertTrue(anchor.location(in: [anchor.file: "changed"]) == nil && review.anchors["bad"] == nil)
        XCTAssertTrue(review.changes.count == 2 && review.changes[0].insertion && !review.changes[1].insertion)
        let ids = try OverleafReviewSnapshot.documents(Data(#"[{"id":"doc1","ranges":{"changes":[{}]}},{"id":"empty","ranges":{}}]"#.utf8))
        XCTAssertTrue(ids == ["doc1"])
        let wrapped = try OverleafReviewSnapshot.documents(Data(#"{"docs":[{"id":"doc1","ranges":{"comments":[{}]}}]}"#.utf8))
        XCTAssertTrue(wrapped == ids)
        XCTAssertTrue(!OverleafReviewSnapshot.validID("../escape") && !OverleafReviewSnapshot.validID("doc?peek=false"))
        var unsafe = false
        do { try review.include(Data(#"{"pathname":"../escape","lines":[],"ranges":{}}"#.utf8), documentID: "doc") } catch { unsafe = true }
        XCTAssertTrue(unsafe)
        let precise = TeXSync.SourceLocation(file: "main.tex", line: 1, range: NSRange(location: 2, length: 1))
        XCTAssertTrue(TeXSync.relocate(precise, from: "a\nb\nc", to: "a\nb\nc") == precise)
        let shifted = TeXSync.relocate(precise, from: "a\nb\nc", to: "new\na\nb\nc")
        XCTAssertTrue(shifted.line == 2 && shifted.range == nil)
        XCTAssertTrue(TeXSync.relocate(.init(file: "main.tex", line: 100), from: "a\nb", to: "a").line == 0)
    }
    func testSourceMappingExportsAndGroupedChangeIdentity() throws {
        let f = try Fixture()
        let archive = f.archive, review = f.review, anchor = f.anchor, document = f.document
        let download = try JSONSerialization.data(withJSONObject: ["text": anchor.source, "disposition": "attachment; filename*=UTF-8''method.tex"])
        let rawRanges = try JSONSerialization.jsonObject(with: document) as! [String: Any]
        var downloaded = OverleafReviewSnapshot(archive: archive)
        try downloaded.includeDownload(download, ranges: rawRanges["ranges"] as! [String: Any], documentID: "doc1", paths: [anchor.file])
        XCTAssertTrue(downloaded.anchors["thread1"]?.file == anchor.file && downloaded.changes.count == 2)
        var ambiguous = OverleafReviewSnapshot(archive: archive)
        try ambiguous.includeDownload(download, ranges: rawRanges["ranges"] as! [String: Any], documentID: "doc1", paths: ["one/method.tex", "two/method.tex"])
        XCTAssertTrue(ambiguous.anchors["thread1"]?.localPathKnown == false && ambiguous.warning != nil)
        let jsonReview = try JSONSerialization.jsonObject(with: review.export(json: true)) as! [String: Any]
        XCTAssertTrue((jsonReview["changes"] as? [[String: Any]])?.count == 2 && jsonReview["sourceLocations"] != nil)
        let markdownReview = String(decoding: try review.export(json: false), as: UTF8.self)
        XCTAssertTrue(markdownReview.contains("## Comments") && markdownReview.contains("## Changes") && markdownReview.contains("Line 2"))
        let exportedReview = try review.export(json: true)
        let exportedObject = try JSONSerialization.jsonObject(with: exportedReview) as! [String: Any]
        let exportedLocations = exportedObject["sourceLocations"] as! [String: [String: Any]]
        XCTAssertTrue(exportedLocations["thread1"]?["sourceSHA256"] as? String == SourceDigest.sha256(anchor.source))
        XCTAssertTrue(exportedLocations["thread1"]?["source"] == nil && exportedLocations["thread1"]?["context"] != nil)
        let rejectedInsertion = try review.changes[0].rejectedSource()
        XCTAssertTrue(rejectedInsertion == "😀 heading\nSome  text.")
        let rejectedDeletion = try review.changes[1].rejectedSource()
        XCTAssertTrue(rejectedDeletion == "😀 heading\nSome oldadaptive text.")
        let currentRows = try JSONSerialization.data(withJSONObject: [["id": "doc1", "ranges": rawRanges["ranges"]!]])
        let currentChange = try review.changes[0].isCurrent(in: currentRows)
        XCTAssertTrue(currentChange)
        let disappearedChange = try review.changes[0].isCurrent(in: Data("[]".utf8))
        XCTAssertTrue(!disappearedChange)

        var groupedRows = rawRanges["ranges"] as! [String: Any]
        groupedRows["changes"] = [["id": "added", "op": ["p": 16, "i": "adaptive"]], ["id": "added", "op": ["p": 16, "i": "adaptive"]]]
        let groupedData = try JSONSerialization.data(withJSONObject: [["id": "doc1", "ranges": groupedRows]])
        let groupedIsCurrent = try review.changes[0].isCurrent(in: groupedData)
        XCTAssertTrue(!groupedIsCurrent)
        var groupedSnapshot = OverleafReviewSnapshot(archive: archive)
        let groupedDocument = try JSONSerialization.data(withJSONObject: ["pathname": anchor.file, "lines": anchor.source.components(separatedBy: "\n"), "ranges": groupedRows])
        try groupedSnapshot.include(groupedDocument, documentID: "doc1")
        XCTAssertTrue(groupedSnapshot.changes.count == 2 && Set(groupedSnapshot.changes.map(\.id)).count == 2 && groupedSnapshot.changes.allSatisfy { !$0.singleRange })
    }
    func testReviewPackageSeparatesSnapshotsAndRejectsTraversal() throws {
        let f = try Fixture()
        let project = f.project, review = f.review, anchor = f.anchor
        let packageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: packageFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageFolder) }
        let packageURL = packageFolder.appendingPathComponent("review.zip")
        try OverleafReviewPackage.write(review, sources: [anchor.file: "A newer local source"], to: packageURL)
        let readPackage = Process(), packagePipe = Pipe()
        readPackage.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); readPackage.arguments = ["-p", packageURL.path, "Review/manifest.json"]
        readPackage.standardOutput = packagePipe; readPackage.standardError = FileHandle.nullDevice
        try readPackage.run()
        let manifestBytes = packagePipe.fileHandleForReading.readDataToEndOfFile(); readPackage.waitUntilExit()
        let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
        XCTAssertTrue(readPackage.terminationStatus == 0 && manifest["differentSources"] as? [String] == [anchor.file])
        XCTAssertTrue(manifest["projectReference"] as? String == "overleaf:" + project.projectID)
        var unsafePackage = false
        do { try OverleafReviewPackage.write(review, sources: ["../escape.tex": "bad"], to: packageFolder.appendingPathComponent("unsafe.zip")) } catch { unsafePackage = true }
        XCTAssertTrue(unsafePackage && !FileManager.default.fileExists(atPath: packageFolder.appendingPathComponent("escape.tex").path))
    }
    @MainActor func testScopedReadsPartialAuthenticationAndCancellation() async throws {
        let f = try Fixture()
        let project = f.project, anchor = f.anchor, data = f.data
        let rawRanges = try JSONSerialization.jsonObject(with: f.document) as! [String: Any]
        let download = try JSONSerialization.data(withJSONObject: ["text": anchor.source, "disposition": "attachment; filename*=UTF-8''method.tex"])
        var calls: [String] = []
        let ranges = try JSONSerialization.data(withJSONObject: [["id": "doc1", "ranges": rawRanges["ranges"]!]])
        let loaded = try await OverleafReviewService.read(project, paths: [anchor.file], main: "main.tex", request: { path, _, isDocument in
            calls.append(path)
            if path.hasSuffix("/threads") { return data }
            if path.hasSuffix("/ranges") { return ranges }
            if path.hasSuffix("/changes/users") { return Data("[]".utf8) }
            XCTAssertTrue(isDocument && path.hasSuffix("/doc/doc1/download"))
            return download
        })
        XCTAssertTrue(loaded.anchors["thread1"]?.file == anchor.file && loaded.changes.count == 2 && loaded.main == "main.tex" && calls.count == 5)
        var rangeReads = 0
        let changed = try await OverleafReviewService.read(project, paths: [anchor.file], request: { path, _, _ in
            if path.hasSuffix("/threads") { return data }
            if path.hasSuffix("/ranges") { rangeReads += 1; return rangeReads == 1 ? ranges : Data("[]".utf8) }
            return download
        })
        XCTAssertTrue(changed.warning != nil && changed.anchors.isEmpty && changed.changes.isEmpty)
        let partial = try await OverleafReviewService.read(project, paths: [anchor.file], request: { path, _, _ in
            if path.hasSuffix("/threads") { return data }
            throw OverleafWebClient.Failure.signIn
        })
        XCTAssertTrue(partial.archive.threads.count == 1 && partial.needsConnection && partial.warning != nil)
        let cancelled = Task { @MainActor in
            try await OverleafReviewService.read(project, paths: [], request: { _, _, _ in try await Task.sleep(for: .seconds(100)); return Data() })
        }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled review completed") } catch is CancellationError { }
    }
}
