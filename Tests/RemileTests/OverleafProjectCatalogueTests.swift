import Foundation
import XCTest
@testable import Remile

final class OverleafProjectCatalogueTests: XCTestCase {
    @MainActor func testPrivateWebEndpointsFailClosed() async {
        do {
            _ = try await OverleafWebClient.request("/user/settings", profile: UUID())
            XCTFail("The catalogue exception must not allow unrelated browser endpoints")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Source sync uses Git")) }
    }
    @MainActor func testCatalogueReadsListAndOptionalTagsOnce() async throws {
        let profile = UUID()
        var calls: [String] = []
        let id = String(repeating: "a", count: 24)
        let payload = Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Sample\"}]}".utf8)
        let projects = try await OverleafWebClient.projects(profile) { path, receivedProfile in
            calls.append(path)
            XCTAssertEqual(receivedProfile, profile)
            if path == "/tag" {
                return Data("[{\"_id\":\"tag-1\",\"name\":\"Research\",\"color\":\"#123456\",\"project_ids\":[\"\(id)\"]}]".utf8)
            }
            return payload
        }
        XCTAssertEqual(calls, ["/user/projects", "/tag"])
        XCTAssertEqual(projects.map(\.name), ["Sample"])
        XCTAssertEqual(projects[0].tags.first?.color, "#123456")
    }
    @MainActor func testTagFailureDoesNotHideProjects() async throws {
        let id = String(repeating: "b", count: 24)
        var calls: [String] = []
        let projects = try await OverleafWebClient.projects(UUID()) { path, _ in
            calls.append(path)
            if path == "/tag" { throw OverleafWebClient.Failure.unavailable }
            return Data("{\"projects\":[{\"_id\":\"\(id)\",\"name\":\"Still available\"}]}".utf8)
        }
        XCTAssertEqual(projects.map(\.name), ["Still available"])
        XCTAssertFalse(projects[0].tagsLoaded)
        XCTAssertEqual(calls, ["/user/projects", "/tag"])
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
