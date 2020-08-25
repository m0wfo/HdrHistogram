import XCTest
@testable import HdrHistogram

final class HdrHistogramTests: XCTestCase {

    func testEmptyHistogram() throws {
        let histogram = try! Histogram(lowestDiscernableValue: 1, highestTrackableValue: 10, numberOfSignificantValueDigits: 1)

        XCTAssertNil(histogram.minValue)
        XCTAssertEqual(0, histogram.maxValue)
        XCTAssertEqual(0, histogram.totalCount)

        XCTAssertEqual(100.0, histogram.percentileAtOrBelowValue(value: 0))
    }

    func testRecordValue() throws {
        let histogram = try! Histogram(lowestDiscernableValue: 1, highestTrackableValue: 3600 * 1000 * 1000, numberOfSignificantValueDigits: 3)

        histogram.recordValue(4)

        XCTAssertEqual(1, histogram[4])
        XCTAssertEqual(1, histogram.totalCount)
        XCTAssertEqual(4, histogram.maxValue)
    }

    func testValueAtPercentileMatchesPercentile() throws {

    }
}
