import XCTest
@testable import Remile

final class InlineWordCompletionTests: XCTestCase {
    func testSentenceStartAddsMissingSpaceAndCapitalisesOneWord() {
        XCTAssertEqual(InlineWordCompletion(before: "Fuel-bound nitrogen.")?.insertion(for: "turbulence affects"), " Turbulence")
        XCTAssertEqual(InlineWordCompletion(before: "Fuel-bound nitrogen. ")?.insertion(for: "turbulence"), "Turbulence")
        XCTAssertEqual(InlineWordCompletion(before: "The flame ")?.insertion(for: "propagates"), "propagates")
    }

    func testPartiallyTypedWordInsertsOnlyMatchingSuffix() {
        let context = InlineWordCompletion(before: "Fuel-bound nitrogen. Tu")
        XCTAssertEqual(context?.prefix, "Tu")
        XCTAssertEqual(context?.insertion(for: "turbulence chemistry"), "rbulence")
        XCTAssertNil(context?.insertion(for: "flame"))
        XCTAssertNil(context?.insertion(for: "Tu"))
        XCTAssertNil(context?.insertion(for: "\\turbulence"))
        XCTAssertNil(InlineWordCompletion(before: "\\text")?.insertion(for: "textbook"))
    }
}
