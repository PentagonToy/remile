import Foundation
let project = OverleafConnection(id: UUID(), projectID: "6ad72e207e5cd74f01fe6b18", name: "Example", account: "Personal", branch: "master")
let data = Data(#"{"thread1":{"resolved":true,"resolved_at":"2026-10-20T09:00:00Z","messages":[{"id":"m1","content":"A note with <html> and [links](https://example.com)","timestamp":"2026-10-20T08:00:00Z","user":{"name":"Alex","email":"private@example.com"},"user_id":"user1"},{"id":"m2","content":"A reply","timestamp":"2026-10-20T08:30:00Z","user_id":"user2"}]}}"#.utf8)
let archive = try OverleafThreadArchive.parse(data, project: project)
precondition(archive.threads.count == 1 && archive.threads[0].messages.count == 2)
precondition(archive.threads[0].resolved && archive.threads[0].resolvedAt == "2026-10-20T09:00:00Z")
precondition(archive.threads[0].messages[0].author == "Alex")
let json = try archive.data(json: true), markdown = String(decoding: try archive.data(json: false), as: UTF8.self)
precondition(!String(decoding: json, as: UTF8.self).contains("private@example.com"))
precondition(markdown.contains("Reply") && markdown.contains("&lt;html&gt;") && markdown.contains("\\[links\\]"))
let decoded = try JSONDecoder().decode(OverleafThreadArchive.self, from: json)
precondition(decoded.threads[0].messages[1].id == "m2")
let empty = try OverleafThreadArchive.parse(Data("{}".utf8), project: project)
precondition(empty.threads.isEmpty)
var rejected = false
do { _ = try OverleafThreadArchive.parse(Data(#"{"thread1":{"messages":[{"content":"missing identity"}]}}"#.utf8), project: project) } catch { rejected = true }
precondition(rejected)
print("Passed Overleaf comments: threads/replies/IDs, resolved state/time, Markdown/JSON, email exclusion, literal content, empty response and malformed-message rejection")

precondition(archive.threads[0].messages[1].author == "Contributor")
let named = try OverleafThreadArchive.parse(Data(#"{"t":{"messages":[{"id":"m","content":"Hello","user":{"first_name":"Alex","last_name":"Toy"}}]}}"#.utf8), project: project)
precondition(named.threads[0].messages[0].author == "Alex Toy")
let document = Data(#"{"pathname":"/chapters/method.tex","version":12,"lines":["😀 heading","Some adaptive text."],"ranges":{"comments":[{"op":{"t":"thread1","p":16,"c":"adaptive"}},{"op":{"t":"bad","p":1,"c":"x"}}],"changes":[{"id":"added","metadata":{"ts":"2026-10-26T06:00:00Z"},"op":{"p":16,"i":"adaptive"}},{"id":"deleted","op":{"p":16,"d":"old"}}]}}"#.utf8)
var review = OverleafReviewSnapshot(archive: archive)
try review.include(document, documentID: "doc1")
let anchor = review.anchors["thread1"]!
precondition(anchor.file == "chapters/method.tex" && anchor.line == 1 && anchor.version == 12)
precondition(anchor.location(in: [anchor.file: anchor.source])?.range == NSRange(location: 16, length: 8))
precondition(anchor.location(in: [anchor.file: "changed"]) == nil && review.anchors["bad"] == nil)
precondition(review.changes.count == 2 && review.changes[0].insertion && !review.changes[1].insertion)
let ids = try OverleafReviewSnapshot.documents(Data(#"[{"id":"doc1","ranges":{"changes":[{}]}},{"id":"empty","ranges":{}}]"#.utf8))
precondition(ids == ["doc1"])
let wrapped = try OverleafReviewSnapshot.documents(Data(#"{"docs":[{"id":"doc1","ranges":{"comments":[{}]}}]}"#.utf8))
precondition(wrapped == ids)
precondition(!OverleafReviewSnapshot.validID("../escape") && !OverleafReviewSnapshot.validID("doc?peek=false"))
var unsafe = false
do { try review.include(Data(#"{"pathname":"../escape","lines":[],"ranges":{}}"#.utf8), documentID: "doc") } catch { unsafe = true }
precondition(unsafe)
let precise = TeXSync.SourceLocation(file: "main.tex", line: 1, range: NSRange(location: 2, length: 1))
precondition(TeXSync.relocate(precise, from: "a\nb\nc", to: "a\nb\nc") == precise)
let shifted = TeXSync.relocate(precise, from: "a\nb\nc", to: "new\na\nb\nc")
precondition(shifted.line == 2 && shifted.range == nil)
precondition(TeXSync.relocate(.init(file: "main.tex", line: 100), from: "a\nb", to: "a").line == 0)
print("Passed review anchors, UTF-16 emoji offsets, tracked insertions/deletions, stale source refusal, safe paths, author names and previous-build line relocation")

let download = try JSONSerialization.data(withJSONObject: ["text": anchor.source, "disposition": "attachment; filename*=UTF-8''method.tex"])
let rawRanges = try JSONSerialization.jsonObject(with: document) as! [String: Any]
var downloaded = OverleafReviewSnapshot(archive: archive)
try downloaded.includeDownload(download, ranges: rawRanges["ranges"] as! [String: Any], documentID: "doc1", paths: [anchor.file])
precondition(downloaded.anchors["thread1"]?.file == anchor.file && downloaded.changes.count == 2)
var ambiguous = OverleafReviewSnapshot(archive: archive)
try ambiguous.includeDownload(download, ranges: rawRanges["ranges"] as! [String: Any], documentID: "doc1", paths: ["one/method.tex", "two/method.tex"])
precondition(ambiguous.anchors["thread1"]?.localPathKnown == false && ambiguous.warning != nil)
print("Passed official source download mapping and ambiguous filename refusal")
let jsonReview = try JSONSerialization.jsonObject(with: review.export(json: true)) as! [String: Any]
precondition((jsonReview["changes"] as? [[String: Any]])?.count == 2 && jsonReview["sourceLocations"] != nil)
let markdownReview = String(decoding: try review.export(json: false), as: UTF8.self)
precondition(markdownReview.contains("## Comments") && markdownReview.contains("## Changes") && markdownReview.contains("Line 2"))
let exportedReview = try review.export(json: true)
let exportedObject = try JSONSerialization.jsonObject(with: exportedReview) as! [String: Any]
let exportedLocations = exportedObject["sourceLocations"] as! [String: [String: Any]]
precondition(exportedLocations["thread1"]?["sourceSHA256"] as? String == SourceDigest.sha256(anchor.source))
precondition(exportedLocations["thread1"]?["source"] == nil && exportedLocations["thread1"]?["context"] != nil)
let rejectedInsertion = try review.changes[0].rejectedSource()
precondition(rejectedInsertion == "😀 heading\nSome  text.")
let rejectedDeletion = try review.changes[1].rejectedSource()
precondition(rejectedDeletion == "😀 heading\nSome oldadaptive text.")
let currentRows = try JSONSerialization.data(withJSONObject: [["id": "doc1", "ranges": rawRanges["ranges"]!]])
let currentChange = try review.changes[0].isCurrent(in: currentRows)
precondition(currentChange)
let disappearedChange = try review.changes[0].isCurrent(in: Data("[]".utf8))
precondition(!disappearedChange)
print("Passed complete review export, bounded source context, inverse edits and stale change identity checks")

var groupedRows = rawRanges["ranges"] as! [String: Any]
groupedRows["changes"] = [["id": "added", "op": ["p": 16, "i": "adaptive"]], ["id": "added", "op": ["p": 16, "i": "adaptive"]]]
let groupedData = try JSONSerialization.data(withJSONObject: [["id": "doc1", "ranges": groupedRows]])
let groupedIsCurrent = try review.changes[0].isCurrent(in: groupedData)
precondition(!groupedIsCurrent)
var groupedSnapshot = OverleafReviewSnapshot(archive: archive)
let groupedDocument = try JSONSerialization.data(withJSONObject: ["pathname": anchor.file, "lines": anchor.source.components(separatedBy: "\n"), "ranges": groupedRows])
try groupedSnapshot.include(groupedDocument, documentID: "doc1")
precondition(groupedSnapshot.changes.count == 2 && Set(groupedSnapshot.changes.map(\.id)).count == 2 && groupedSnapshot.changes.allSatisfy { !$0.singleRange })
print("Passed grouped change identity protection and unique fragment presentation")

@MainActor enum OverleafWebClient {
    enum Failure: Error { case signIn; var needsConnection: Bool { true } }
    static func request(_ path: String, profile: UUID, document: Bool = false) async throws -> Data { fatalError("A test tried to reach a real account") }
}
let packageFolder = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("package-" + UUID().uuidString)
try FileManager.default.createDirectory(at: packageFolder, withIntermediateDirectories: true)
let packageURL = packageFolder.appendingPathComponent("review.zip")
try OverleafReviewPackage.write(review, sources: [anchor.file: "A newer local source"], to: packageURL)
let readPackage = Process(), packagePipe = Pipe()
readPackage.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); readPackage.arguments = ["-p", packageURL.path, "Review/manifest.json"]
readPackage.standardOutput = packagePipe; readPackage.standardError = FileHandle.nullDevice
try readPackage.run()
let manifestBytes = packagePipe.fileHandleForReading.readDataToEndOfFile(); readPackage.waitUntilExit()
let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
precondition(readPackage.terminationStatus == 0 && manifest["differentSources"] as? [String] == [anchor.file])
precondition(manifest["projectReference"] as? String == "overleaf:" + project.projectID)
var unsafePackage = false
do { try OverleafReviewPackage.write(review, sources: ["../escape.tex": "bad"], to: packageFolder.appendingPathComponent("unsafe.zip")) } catch { unsafePackage = true }
precondition(unsafePackage && !FileManager.default.fileExists(atPath: packageFolder.appendingPathComponent("escape.tex").path))
print("Passed source package manifest, separate review snapshots and traversal refusal")

Task { @MainActor in
    do {
        var calls: [String] = []
        let ranges = try JSONSerialization.data(withJSONObject: [["id": "doc1", "ranges": rawRanges["ranges"]!]])
        let loaded = try await OverleafReviewService.read(project, paths: [anchor.file], main: "main.tex", request: { path, _, isDocument in
            calls.append(path)
            if path.hasSuffix("/threads") { return data }
            if path.hasSuffix("/ranges") { return ranges }
            precondition(isDocument && path.hasSuffix("/doc/doc1/download"))
            return download
        })
        precondition(loaded.anchors["thread1"]?.file == anchor.file && loaded.changes.count == 2 && loaded.main == "main.tex" && calls.count == 4)
        var rangeReads = 0
        let changed = try await OverleafReviewService.read(project, paths: [anchor.file], request: { path, _, _ in
            if path.hasSuffix("/threads") { return data }
            if path.hasSuffix("/ranges") { rangeReads += 1; return rangeReads == 1 ? ranges : Data("[]".utf8) }
            return download
        })
        precondition(changed.warning != nil && changed.anchors.isEmpty && changed.changes.isEmpty)
        let partial = try await OverleafReviewService.read(project, paths: [anchor.file], request: { path, _, _ in
            if path.hasSuffix("/threads") { return data }
            throw OverleafWebClient.Failure.signIn
        })
        precondition(partial.archive.threads.count == 1 && partial.needsConnection && partial.warning != nil)
        let cancelled = Task { @MainActor in
            try await OverleafReviewService.read(project, paths: [], request: { _, _, _ in try await Task.sleep(for: .seconds(100)); return Data() })
        }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled review completed") } catch is CancellationError { }
        print("Passed scoped review reads, current range recheck, partial auth state and cancellation without real network access")
        exit(0)
    } catch { print("FAILED review service:", error); exit(1) }
}
RunLoop.main.run()
