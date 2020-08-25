import XCTest
@testable import HdrHistogram

final class HdrHistogramTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(HdrHistogram().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
