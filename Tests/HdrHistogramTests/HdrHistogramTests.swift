/*
 Copyright 2021 TupleStream OÜ

 See the LICENSE file for license information
 SPDX-License-Identifier: Apache-2.0
*/
import XCTest
@testable import HdrHistogram

extension Int64 {

    var asDouble: Double {
        get {
            return Double(truncating: self as NSNumber)
        }
    }
}

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
        let histogram = try! Histogram(lowestDiscernableValue: 1, highestTrackableValue: Int64.self.max, numberOfSignificantValueDigits: 2)
        let lengths: [Int64] = [1, 5, 10, 50, 100, 500, 1000, 5000, 10000, 50000, 100000]

        for length in lengths {
            histogram.reset()
            for i in (1...length) {
                histogram.recordValue(i)
            }

            var value: Int64 = 1
            while value < length {
                let calculatedPercentile = 100.0 * Double(value) / length.asDouble
                value = histogram.nextNonEquivalentValue(value)

                let lookupValue = histogram.getValueAtPercentile(calculatedPercentile)
            }
        }
    }
}
