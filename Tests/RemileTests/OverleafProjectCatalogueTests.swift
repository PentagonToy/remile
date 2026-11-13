import Foundation
import XCTest
@testable import Remile

final class OverleafProjectCatalogueTests: XCTestCase {
    @MainActor func testPickerPresentationUpdatesForSearchAccountAndConnectedProjects() {
        let first = UUID(), second = UUID()
        let tag = OverleafWebClient.Tag(id: "research", name: "Research", color: nil)
        let paper = OverleafWebClient.Project(id: "paper", name: "First paper", tags: [tag])
        let note = OverleafWebClient.Project(id: "note", name: "Unfiled note")
        let catalogue = [paper, note]
        let connection = OverleafConnection(id: UUID(), profileID: first, projectID: paper.id,
                                            name: paper.name, account: "First", branch: "main")
        let presentation = OverleafProjects.CataloguePresentation()

        let grouped = presentation.results(for: catalogue, profile: second, connected: [connection], query: "")
        XCTAssertEqual(grouped.groups.map(\.id), [.tag(tag.id), .untagged])
        let filtered = presentation.results(for: catalogue, profile: second, connected: [connection], query: "research")
        XCTAssertEqual(filtered.projects, [paper])
        XCTAssertTrue(filtered.groups.isEmpty)

        let remaining = presentation.results(for: catalogue, profile: first, connected: [connection], query: "")
        XCTAssertEqual(remaining.projects, [note])
        XCTAssertTrue(remaining.groups.isEmpty)
        let refreshed = presentation.results(for: catalogue, profile: first, connected: [], query: "")
        XCTAssertEqual(refreshed.projects, catalogue)
        let untagged = OverleafWebClient.Project(id: paper.id, name: paper.name)
        let updated = presentation.results(for: [untagged, note], profile: first, connected: [], query: "")
        XCTAssertTrue(updated.groups.isEmpty)
    }

    func testCatalogueFetchResumesOnlyWhenTheListNeedsLoading() {
        let profile = UUID()
        let initial = OverleafProjects.CatalogueLoad(profile: profile, revision: 0, online: true)
        let offline = OverleafProjects.CatalogueLoad(profile: profile, revision: 0, online: false)
        let refresh = OverleafProjects.CatalogueLoad(profile: profile, revision: 1, online: true)
        let otherAccount = OverleafProjects.CatalogueLoad(profile: UUID(), revision: 0, online: true)
        let noAccount = OverleafProjects.CatalogueLoad(profile: nil, revision: 0, online: true)

        XCTAssertFalse(noAccount.shouldFetch(after: nil))
        XCTAssertFalse(offline.shouldFetch(after: nil))
        XCTAssertTrue(initial.shouldFetch(after: nil))
        XCTAssertFalse(initial.shouldFetch(after: initial))
        XCTAssertTrue(refresh.shouldFetch(after: initial))
        XCTAssertTrue(otherAccount.shouldFetch(after: initial))
    }

    @MainActor func testCreatingAnotherWindowPreservesAnExistingReviewStage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let review = root.appendingPathComponent("Reviews/current-review")
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = review.appendingPathComponent("main.tex")
        try "Review in progress".write(to: draft, atomically: true, encoding: .utf8)

        let secondWindow = OverleafLibrary(directory: root)

        XCTAssertEqual(secondWindow.directory, root)
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "Review in progress")
    }

    @MainActor func testUnchangedCatalogueKeepsSavedTagFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = OverleafConnection(id: UUID(), projectID: String(repeating: "a", count: 24),
                                             name: "Sample", account: "Fixture", branch: "main")
        try JSONEncoder().encode([connection]).write(to: root.appendingPathComponent("projects.json"))
        let library = OverleafLibrary(directory: root)
        let tag = OverleafWebClient.Tag(id: "research", name: "Research", color: nil)
        let project = OverleafWebClient.Project(id: connection.projectID, name: connection.name, tags: [tag], tagsLoaded: true)
        let file = root.appendingPathComponent("project-tags.json")
        library.rememberTags([project], profile: connection.profileID)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: file.path)

        library.rememberTags([project], profile: connection.profileID)

        XCTAssertEqual(library.tags[connection.id], [tag])
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, earlier)
    }

    @MainActor func testPrivateWebEndpointsFailClosed() async {
        do {
            _ = try await OverleafWebClient.request("/user/settings", profile: UUID())
            XCTFail("The catalogue exception must not allow unrelated browser endpoints")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Source sync uses Git")) }
    }

    @MainActor func testCancelledCatalogueDoesNotPublishALateList() async throws {
        let task = Task {
            try await OverleafWebClient.projects(UUID(), onList: { _ in
                XCTFail("Cancelled request must not publish its results")
            }) { path, _ in
                XCTAssertEqual(path, "/user/projects")
                withUnsafeCurrentTask { $0?.cancel() }
                return Data(#"{"projects":[]}"#.utf8)
            }
        }
        do {
            _ = try await task.value
            XCTFail("The caller should receive cancellation")
        } catch is CancellationError {}
    }

    @MainActor func testSignInCatalogueValidationHonoursCancellation() async throws {
        let bytes = Data(#"{"projects":[]}"#.utf8)
        try await OverleafWebClient.validateProjectList(bytes)
        let task = Task { try await OverleafWebClient.validateProjectList(bytes) }
        task.cancel()
        do {
            try await task.value
            XCTFail("A closed sign-in must discard validation")
        } catch is CancellationError {}
    }
    @MainActor func testCatalogueReadsListAndOptionalTagsOnce() async throws {
        let profile = UUID()
        var calls: [String] = []
        let id = String(repeating: "a", count: 24)
        let payload = Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Sample\"}]}".utf8)
        let projects = try await OverleafWebClient.projects(profile, onList: { listed in
            calls.append("list ready")
            XCTAssertEqual(listed.map(\.name), ["Sample"])
            XCTAssertEqual(listed.first?.tagsLoaded, false)
        }) { path, receivedProfile in
            calls.append(path)
            XCTAssertEqual(receivedProfile, profile)
            if path == "/tag" {
                return Data("[{\"_id\":\"tag-1\",\"name\":\"Research\",\"color\":\"#123456\",\"project_ids\":[\"\(id)\"]}]".utf8)
            }
            return payload
        }
        XCTAssertEqual(calls, ["/user/projects", "list ready", "/tag"])
        XCTAssertEqual(projects.map(\.name), ["Sample"])
        XCTAssertEqual(projects[0].tags.first?.color, "#123456")
    }
    @MainActor func testClosingPickerAfterListDoesNotStartTagRequest() async throws {
        let id = String(repeating: "c", count: 24)
        let task = Task {
            try await OverleafWebClient.projects(UUID(), onList: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }) { path, _ in
                XCTAssertEqual(path, "/user/projects")
                return Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Sample\"}]}".utf8)
            }
        }
        do {
            _ = try await task.value
            XCTFail("A closed picker must cancel the remaining request")
        } catch is CancellationError { }
    }
    @MainActor func testTagFailureDoesNotHideProjects() async throws {
        let id = String(repeating: "b", count: 24)
        var calls: [String] = []
        let projects = try await OverleafWebClient.projects(UUID(), request: { path, _ in
            calls.append(path)
            if path == "/tag" { throw OverleafWebClient.Failure.unavailable }
            return Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Still available\"}]}".utf8)
        })
        XCTAssertEqual(projects.map(\.name), ["Still available"])
        XCTAssertFalse(projects[0].tagsLoaded)
        XCTAssertEqual(calls, ["/user/projects", "/tag"])
    }
    @MainActor func testEmptyListDoesNotFetchTags() async throws {
        let projects = try await OverleafWebClient.projects(UUID(), onList: { XCTAssertTrue($0.isEmpty) }) { path, _ in
            XCTAssertEqual(path, "/user/projects")
            return Data(#"{"projects":[]}"#.utf8)
        }
        XCTAssertTrue(projects.isEmpty)
    }
    func testProjectTagGroupsKeepEveryMembershipAndUntaggedLast() {
        let alpha = OverleafWebClient.Tag(id: "alpha", name: "Alpha", color: "#123456")
        let beta = OverleafWebClient.Tag(id: "beta", name: "Beta", color: nil)
        let shared = OverleafWebClient.Project(id: "shared", name: "Shared", tags: [beta, alpha])
        let plain = OverleafWebClient.Project(id: "plain", name: "Plain")
        let groups = OverleafProjects.grouped([plain, shared])
        XCTAssertEqual(groups.map(\.id), [.tag("alpha"), .tag("beta"), .untagged])
        XCTAssertEqual(groups.map { $0.projects.map(\.id) }, [["shared"], ["shared"], ["plain"]])
        XCTAssertTrue(OverleafProjects.grouped([]).isEmpty)
    }
    func testTagSearchAndRefreshKeepOnlyKnownMetadata() {
        let tag = OverleafWebClient.Tag(id: "tag", name: "Research", color: "#123456")
        let old = OverleafWebClient.Project(id: "one", name: "Paper", tags: [tag])
        let missing = OverleafWebClient.Project(id: "one", name: "Renamed", tagsLoaded: false)
        let retained = OverleafProjects.retainingTags([missing], previous: [old])[0]
        XCTAssertEqual(retained.name, "Renamed")
        XCTAssertEqual(retained.tags, [tag])
        XCTAssertFalse(retained.tagsLoaded)
        XCTAssertTrue(OverleafProjects.matches(retained, query: "research"))
        XCTAssertFalse(OverleafProjects.matches(retained, query: "unrelated"))
        XCTAssertTrue(OverleafProjects.retainingTags([missing], previous: [])[0].tags.isEmpty, "Another account must not inherit tags")
        let explicitlyRemoved = OverleafWebClient.Project(id: "one", name: "Paper", tagsLoaded: true)
        XCTAssertTrue(OverleafProjects.retainingTags([explicitlyRemoved], previous: [old])[0].tags.isEmpty)
    }
    func testRepeatedTagRowsKeepTheFirstMembershipForEachProject() throws {
        let data = Data(#"""
        [
          {"_id":"one","name":"Zulu","color":"#123456","project_ids":["a","a"]},
          {"_id":"two","name":"Beta","project_ids":["a","b"]},
          {"_id":"one","name":"Alpha","project_ids":["a","b","b"]},
          {"_id":"three","name":"Beta","project_ids":["a","b"]}
        ]
        """#.utf8)
        let tags = try OverleafWebClient.parseTags(data)
        XCTAssertEqual(tags["a"]?.map(\.id), ["two", "three", "one"])
        XCTAssertEqual(tags["a"]?.map(\.name), ["Beta", "Beta", "Zulu"])
        XCTAssertEqual(tags["a"]?.last?.color, "#123456")
        XCTAssertEqual(tags["b"]?.map(\.name), ["Alpha", "Beta", "Beta"])
    }
    func testCatalogueReadExceptionIsExact() {
        XCTAssertTrue(OverleafWebClient.allowedReadPath("/user/projects"))
        XCTAssertTrue(OverleafWebClient.allowedReadPath("/tag"))
        XCTAssertFalse(OverleafWebClient.allowedReadPath("/user/projects", document: true))
        for path in ["/tag?all=true", "/user/settings", "/user/projects?all=true", "/user/projects/", "/user/projects/../settings", "/socket.io/1/"] {
            XCTAssertFalse(OverleafWebClient.allowedReadPath(path))
        }
    }
    @MainActor func testOnlyReviewReadPathsAreAllowed() {
        let id = String(repeating: "a", count: 24)
        XCTAssertTrue(OverleafWebClient.reviewPath("/project/" + id + "/threads"))
        XCTAssertTrue(OverleafWebClient.reviewPath("/project/" + id + "/ranges"))
        XCTAssertTrue(OverleafWebClient.reviewPath("/project/" + id + "/changes/users"))
        XCTAssertTrue(OverleafWebClient.reviewPath("/Project/" + id + "/doc/" + id + "/download", document: true))
        for path in ["/user/projects", "/tag", "/project/" + id + "/compile", "/socket.io/1/", "/project/" + id + "/threads?next=1"] {
            XCTAssertFalse(OverleafWebClient.reviewPath(path))
        }
    }
}
