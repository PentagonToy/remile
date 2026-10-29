import XCTest
@testable import Remile

final class ReferenceColumnWidthTests: XCTestCase {
    let columns = ReferenceColumn.visible(ReferenceColumn.defaults)
    func testOversizedSavedTitleFitsSmallPane() {
        let saved = ["title": 1200.0, "publication": 240.0]
        for width in [634.0, 666, 700, 900] {
            let fitted = ReferenceColumnWidths.fitted(available: width, columns: columns, saved: saved)
            XCTAssertEqual(columns.reduce(130.0) { $0 + fitted[$1.rawValue]! }, width, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(fitted["title"]!, 180)
            XCTAssertGreaterThanOrEqual(fitted["publication"]!, 120)
            XCTAssertTrue(fitted.values.allSatisfy { $0.isFinite })
        }
        XCTAssertEqual(saved["title"], 1200)
    }
    func testWidePaneRestoresSavedWidths() {
        let fitted = ReferenceColumnWidths.fitted(available: 2000, columns: columns, saved: ["title": 1200, "publication": 240])
        XCTAssertEqual(fitted["title"], 1200)
        XCTAssertEqual(fitted["publication"], 240)
    }
    func testBelowMinimumKeepsReadableColumns() {
        let fitted = ReferenceColumnWidths.fitted(available: 300, columns: columns, saved: ["title": 1200])
        XCTAssertEqual(fitted["title"], 180)
        XCTAssertEqual(fitted["author"], 88)
        XCTAssertEqual(fitted["publication"], 120)
    }
}
