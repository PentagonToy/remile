import XCTest

@testable import Remile

final class ReferenceKindTests: XCTestCase {
    func testImportedTypes() {
        let groups: [(ReferenceKind, [String])] = [
            (.webpage, ["online", "www", "electronic", "webpage", "website", "url"]),
            (.newspaper, ["newspaper", "news"]),
            (.report, ["report", "techreport", "TechReport"]),
        ]
        for (kind, types) in groups {
            for type in types {
                XCTAssertEqual(ReferenceKind.classify(ReferenceRecord(type: type)), kind, type)
            }
        }
    }

    func testURLDoesNotOverrideDocumentType() {
        let article = ReferenceRecord(type: "article", fields: ["url": "https://example.com/paper"])
        XCTAssertEqual(ReferenceKind.classify(article), .article)
        XCTAssertEqual(ReferenceKind.classify(ReferenceRecord(type: "misc", fields: article.fields)), .other)
    }

    func testTypeSelectionRoundTripPreservesIdentityAndFields() throws {
        let source = ReferenceRecord(
            type: "article", fields: ["title": "Sample", "url": "https://example.com", "entrysubtype": "preprint"])
        for kind in [ReferenceKind.webpage, .newspaper, .report] {
            let changed = kind.applying(to: source)
            XCTAssertEqual(ReferenceKind.classify(changed), kind)
            XCTAssertEqual(changed.id, source.id)
            XCTAssertEqual(changed.revision, source.revision)
            XCTAssertEqual(changed.fields["title"], source.fields["title"])
            XCTAssertEqual(changed.fields["url"], source.fields["url"])
            let bibtex = try ReferenceBibTeX.export([changed])
            let imported = try XCTUnwrap(ReferenceBibTeX.parse(bibtex).first)
            XCTAssertEqual(ReferenceKind.classify(imported), kind)
        }
        XCTAssertEqual(ReferenceKind.report.bibType, "techreport")
    }
}
