import XCTest
@testable import Remile

final class SearchExpansionTests: XCTestCase {
    private func hit(_ path: String) -> LibraryHit {
        LibraryHit(path: path, folderID: "fixture", page: 1, excerpt: "Fixture", score: -1)
    }
    func testFusionPreservesRankingAndFirstQuery() {
        let first = hit("/first.pdf"), shared = hit("/shared.pdf")
        let result = SearchExpansion.merge([("original", [first, shared]), ("expanded", [shared])])
        XCTAssertEqual(result.map(\.id), [shared.id, first.id])
        XCTAssertEqual(result[0].matchQuery, "original")
        XCTAssertEqual(result[0].score, -(1.5 / 62.0 + 1.0 / 61.0), accuracy: 0.0000001)
    }
    func testFusionIsBoundedAndDeterministic() {
        XCTAssertTrue(SearchExpansion.merge([]).isEmpty)
        let many = (0..<230).map { hit("/\($0).pdf") }
        XCTAssertEqual(SearchExpansion.merge([("query", many)]).count, 200)
        let a = hit("/a.pdf"), b = hit("/b.pdf")
        XCTAssertEqual(SearchExpansion.merge([("original", []), ("query", [a, b]), ("query", [b, a])]).map(\.id), [a.id, b.id])
    }
}
