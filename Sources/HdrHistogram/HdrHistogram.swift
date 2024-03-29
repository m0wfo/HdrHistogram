/*
 Copyright 2021 TupleStream OÜ

 See the LICENSE file for license information
 SPDX-License-Identifier: Apache-2.0
*/
import Foundation

public protocol ValueRecorder {

    func recordValue(_ value: Int64)
}

public class Histogram: CustomStringConvertible, Equatable, ValueRecorder {

    private let lowestDiscernibleValue: Int64
    private let highestTrackableValue: Int64
    private let numberOfSignificantValueDigits: Int32

    private var bucketCount: Int32 = 0

    /**
     * Power-of-two length of linearly scaled array slots in the counts array. Long enough to hold the first sequence of
     * entries that must be distinguished by a single unit (determined by configured precision).
     */
    private var subBucketCount: Int32
    private var countsArrayLength: Int32 = 0
    private var wordSizeInBytes: Int32

    // Number of leading zeros in the largest value that can fit in bucket 0.
    private var leadingZeroCountBase: Int32 = 0
    private var subBucketHalfCountMagnitude: Int32 = 0

    // Largest k such that 2^k <= lowestDiscernibleValue
    private var unitMagnitude: Int32 = 0
    private var subBucketHalfCount: Int32 = 0

    // Biggest value that can fit in bucket 0
    private var subBucketMask: Int64 = 0

    // Lowest unitMagnitude bits are set
    private var unitMagnitudeMask: Int64 = 0
    private var maxRawValue: Int64 = 0
    private var minRawNonZeroValue: Int64 = Int64.self.max

    private var totalRawCount: Int64 = 0
    private var counts: [Int64] = []
    private let normalizingIndexOffset: Int32 = 0

    private var integerToDoubleConversionRatio: Double = 1.0

    public init(lowestDiscernableValue: Int64, highestTrackableValue: Int64, numberOfSignificantValueDigits: Int32) throws {
        precondition(lowestDiscernableValue >= 1, "lowestDiscernibleValue must be >= 1")
        // prevent subsequent multiplication by 2 for highestTrackableValue check from overflowing
        precondition(lowestDiscernableValue < Int64.self.max / 2, "lowestDiscernibleValue must be <= Int64.self.max / 2")
        precondition(highestTrackableValue > lowestDiscernableValue * 2, "highestTrackableValue must be >= 2 * lowestDiscernibleValue")
        precondition(0...5 ~= numberOfSignificantValueDigits, "numberOfSignificantValueDigits must be between 0 and 5")

        self.lowestDiscernibleValue = lowestDiscernableValue
        self.highestTrackableValue = highestTrackableValue
        self.numberOfSignificantValueDigits = numberOfSignificantValueDigits

        self.wordSizeInBytes = 8

        /*
         * Given a 3 decimal point accuracy, the expectation is obviously for "+/- 1 unit at 1000". It also means that
         * it's "ok to be +/- 2 units at 2000". The "tricky" thing is that it is NOT ok to be +/- 2 units at 1999. Only
         * starting at 2000. So internally, we need to maintain single unit resolution to 2x 10^decimalPoints.
         */
        let largestValueWithSingleUnitResolution = Int64(truncating: 2 * pow(10, Int(numberOfSignificantValueDigits)) as NSNumber)

        self.unitMagnitude = Int32(log(Double(integerLiteral: lowestDiscernableValue)) / log(2))
        self.unitMagnitudeMask = (1 << self.unitMagnitude) - 1

        // We need to maintain power-of-two subBucketCount (for clean direct indexing) that is large enough to
        // provide unit resolution to at least largestValueWithSingleUnitResolution. So figure out
        // largestValueWithSingleUnitResolution's nearest power-of-two (rounded up), and use that:
        let subBucketCountMagnitude = Int32(truncating: ceil(log(Double(largestValueWithSingleUnitResolution))/log(2)) as NSNumber)
        self.subBucketHalfCountMagnitude = subBucketCountMagnitude - 1
        self.subBucketCount = 1 << subBucketCountMagnitude
        self.subBucketHalfCount = self.subBucketCount / 2
        self.subBucketMask = Int64((self.subBucketCount - 1) << self.unitMagnitude)

        precondition(subBucketCountMagnitude + self.unitMagnitude <= 62, "subBucketCount entries can't be represented, with unitMagnitude applied, in a positive long")

        self.countsArrayLength = determineArrayLengthNeeded(highestTrackableValue)
        self.bucketCount = getBucketsNeededToCoverValue(highestTrackableValue)

        self.leadingZeroCountBase = 64 - unitMagnitude - subBucketCountMagnitude

        self.counts = Array(repeating: 0, count: Int(countsArrayLength))
    }

    private func determineArrayLengthNeeded(_ highestTrackableValue: Int64) -> Int32 {
        precondition(highestTrackableValue > 2 * self.lowestDiscernibleValue, "highestTrackableValue \(highestTrackableValue) cannot be be < (2 * lowestDiscernibleValue)")

        return getLengthForNumberOfBuckets(numberOfBuckets: getBucketsNeededToCoverValue(highestTrackableValue))
    }

    private func getBucketsNeededToCoverValue(_ value: Int64) -> Int32 {
        // Shift won't overflow because subBucketMagnitude + unitMagnitude <= 62.
        // the k'th bucket can express from 0 * 2^k to subBucketCount * 2^k in units of 2^k
        var smallestUntrackableValue = Int64(self.subBucketCount << self.unitMagnitude)
        // always have at least 1 bucket
        var bucketsNeeded: Int32 = 1

        while smallestUntrackableValue <= value {
            if smallestUntrackableValue > Int64.self.max / 2 {
                // next shift will overflow, meaning that bucket could represent values up to ones greater than
                // Long.MAX_VALUE, so it's the last bucket
                return bucketsNeeded + 1
            }

            smallestUntrackableValue <<= 1
            bucketsNeeded += 1
        }
        return bucketsNeeded
    }

    /**
     * If we have N such that subBucketCount * 2^N > max value, we need storage for N+1 buckets, each with enough
     * slots to hold the top half of the subBucketCount (the lower half is covered by previous buckets), and the +1
     * being used for the lower half of the 0'th bucket. Or, equivalently, we need 1 more bucket to capture the max
     * value if we consider the sub-bucket length to be halved.
     */
    private func getLengthForNumberOfBuckets(numberOfBuckets: Int32) -> Int32 {
        return (numberOfBuckets + 1) * (subBucketHalfCount)
    }

    private func bucketAndSubBucketIndices(_ value: Int64) -> (bucket: Int32, subBucket: Int32) {
        let bucketIndex = getBucketIndex(value)
        let subBucketIndex = getSubBucketIndex(value, bucketIdx: bucketIndex)
        return (bucketIndex, subBucketIndex)
    }

    private func countsArrayIndex(_ value: Int64) -> Int32 {
        precondition(value >= 0, "Histogram recorded value cannot be negative.")
        let indices = bucketAndSubBucketIndices(value)
        return countsArrayIndex(indices.bucket, indices.subBucket)
    }

    private func countsArrayIndex(_ bucketIndex: Int32, _ subBucketIndex: Int32) -> Int32 {
        assert(subBucketIndex < subBucketCount)
        assert(bucketIndex == 0 || (subBucketIndex >= subBucketHalfCount))

        // Calculate the index for the first entry that will be used in the bucket (halfway through subBucketCount).
        // For bucketIndex 0, all subBucketCount entries may be used, but bucketBaseIndex is still set in the middle.
        let bucketBaseIndex = (bucketIndex + 1) << subBucketHalfCountMagnitude
        // Calculate the offset in the bucket. This subtraction will result in a positive value in all buckets except
        // the 0th bucket (since a value in that bucket may be less than half the bucket's 0 to subBucketCount range).
        // However, this works out since we give bucket 0 twice as much space.
        let offsetInBucket = subBucketIndex - subBucketHalfCount
        // The following is the equivalent of ((subBucketIndex  - subBucketHalfCount) + bucketBaseIndex;
        return bucketBaseIndex + offsetInBucket
    }

    private func getBucketIndex(_ value: Int64) -> Int32 {
        // Calculates the number of powers of two by which the value is greater than the biggest value that fits in
        // bucket 0. This is the bucket index since each successive bucket can hold a value 2x greater.
        // The mask maps small values to bucket 0.
        return leadingZeroCountBase - Int32((value | subBucketMask).leadingZeroBitCount)
    }

    private func getSubBucketIndex(_ value: Int64, bucketIdx: Int32) -> Int32 {
        // For bucketIndex 0, this is just value, so it may be anywhere in 0 to subBucketCount.
        // For other bucketIndex, this will always end up in the top half of subBucketCount: assume that for some bucket
        // k > 0, this calculation will yield a value in the bottom half of 0 to subBucketCount. Then, because of how
        // buckets overlap, it would have also been in the top half of bucket k-1, and therefore would have
        // returned k-1 in getBucketIndex(). Since we would then shift it one fewer bits here, it would be twice as big,
        // and therefore in the top half of subBucketCount.
        return Int32(truncatingIfNeeded: value.magnitude >> (bucketIdx + unitMagnitude))
    }

    private func normalizeIndex(index: Int32, offset: Int32, arrayLength: Int32) -> Int {
        if offset == 0 {
            // Fastpath out of normalization. Keeps integer value histograms fast while allowing
            // others (like DoubleHistogram) to use normalization at a cost...
            return Int(index)
        }

        if (index > arrayLength) || (index < 0) {
            // TODO throw
        }

        var normalizedIndex = index - offset
        // The following is the same as an unsigned remainder operation, as long as no double wrapping happens
        // (which shouldn't happen, as normalization is never supposed to wrap, since it would have overflowed
        // or underflowed before it did). This (the + and - tests) seems to be faster than a % op with a
        // correcting if < 0...:
        if normalizedIndex < 0 {
            normalizedIndex += arrayLength
        } else if normalizedIndex >= arrayLength {
            normalizedIndex -= arrayLength
        }

        return Int(normalizedIndex)
    }

    private func valueFromIndex(bucketIndex: Int32, subBucketIndex: Int32) -> Int64 {
        return Int64(subBucketIndex) << (bucketIndex + unitMagnitude)
    }

    private func valueFromIndex(bucketIndex: Int32) -> Int64 {
        var idx = (bucketIndex >> subBucketHalfCountMagnitude) - 1
        var subBucketIndex = (bucketIndex & (subBucketHalfCount - 1)) + subBucketHalfCount
        if idx < 0 {
            subBucketIndex -= subBucketHalfCount
            idx = 0
        }
        return valueFromIndex(bucketIndex: idx, subBucketIndex: subBucketIndex)
    }

    public func getCountAtIndex(_ index: Int32) -> Int64 {
        return counts[normalizeIndex(index: index, offset: normalizingIndexOffset, arrayLength: countsArrayLength)]
    }

    // Swift-ish syntactic sugar for the above function
    public subscript(position: Int32) -> Int64 {
        return getCountAtIndex(position)
    }

    // MARK: Modification

    public func incrementCountAtIndex(_ index: Int32) {
        counts[normalizeIndex(index: index, offset: normalizingIndexOffset, arrayLength: countsArrayLength)] += 1
    }

    private func updateMinAndMax(_ value: Int64) {
        if value > maxRawValue {
            updateMaxValue(value)
        }
        if value < minRawNonZeroValue && value != 0 {
            updateMinNonZeroValue(value)
        }
    }

    public func recordValue(_ value: Int64) {
        let countsIndex = countsArrayIndex(value)
        incrementCountAtIndex(countsIndex)
        updateMinAndMax(value)
        totalRawCount += 1
    }

    private func clearCounts() {
        counts = Array(repeating: 0, count: counts.count)
        totalRawCount = 0
    }

    private func resetMaxValue(_ value: Int64) {
        maxRawValue = value | unitMagnitudeMask
    }

    private func resetMinNonZeroValue(_ value: Int64) {
        let internalValue = value & ~unitMagnitudeMask
        if value == Int64.self.max {
            self.minRawNonZeroValue = value
        } else {
            self.minRawNonZeroValue = internalValue
        }
    }

    public func reset() {
        clearCounts()
        resetMaxValue(0)
        resetMinNonZeroValue(Int64.self.max)
    }

    // MARK: Retrieval

    public var totalCount: Int64 {
        get {
            return self.totalRawCount
        }
    }

    public var maxValue: Int64 {
        get {
            if maxRawValue == 0 {
                return 0
            }
            return nextNonEquivalentValue(maxRawValue) - 1
        }
    }

    public var minValue: Int64? {
        get {
            if getCountAtIndex(0) > 0 || totalCount == 0 {
                return nil
            }
            return minNonZeroValue
        }
    }

    public var minNonZeroValue: Int64? {
        get {
            if minRawNonZeroValue == Int64.self.max {
                return nil
            }
            return nextNonEquivalentValue(minRawNonZeroValue)
        }
    }

    public func percentileAtOrBelowValue(value: Int64) -> Double {
        if self.totalRawCount == 0 {
            return 100
        }

        let targetIndex = min(countsArrayIndex(value), (countsArrayLength - 1))
        var totalToCurrentIndex: Int64 = 0
        for i in (0...targetIndex) {
            totalToCurrentIndex += self[i]
        }

        return (100.0 * Double(truncating: totalToCurrentIndex as NSNumber)) / Double(truncating: totalCount as NSNumber)
    }

    public func getValueAtPercentile(_ percentile: Double) -> Int64 {
        // Truncate to 0..100%, and remove 1 ulp to avoid roundoff overruns into next bucket when we
        // subsequently round up to the nearest integer:
        let requestedPercentile = min(max(nextafter(percentile, -Double.infinity), 0.0), 100.0)
        // derive the count at the requested percentile. We round up to nearest integer to ensure that the
        // largest value that the requested percentile of overall recorded values is <= is actually included
        let fpCountAtPercentile = (requestedPercentile * Double(truncating: totalCount as NSNumber)) / 100.0
        var countAtPercentile = Int64(ceil(fpCountAtPercentile)) // round up
        countAtPercentile = max(countAtPercentile, 1)

        var totalToCurrentIndex: Int64 = 0
        for i in (0...countsArrayLength) {
            totalToCurrentIndex = getCountAtIndex(i)
            if (totalToCurrentIndex >= countAtPercentile) {
                let valueAtIndex = valueFromIndex(bucketIndex: i)
                if percentile == 0.0 {
                    return lowestEquivalentValue(valueAtIndex)
                } else {
                    return highestEquivalentValue(valueAtIndex)
                }
            }
        }
        return 0
    }

    private func updateMaxValue(_ value: Int64) {
        self.maxRawValue = value | unitMagnitudeMask // Max unit-equivalent value
    }

    private func updateMinNonZeroValue(_ value: Int64) {
        if value <= unitMagnitudeMask {
            return // Unit-equivalent to 0.
        }

        self.minRawNonZeroValue = value & ~unitMagnitudeMask
    }

    // MARK: Querying

    private func sizeOfEquivalentValueRange(_ value: Int64) -> Int64 {
        let bucketIndex = getBucketIndex(value)
        return 1 << (unitMagnitude + bucketIndex)
    }

    private func lowestEquivalentValue(_ value: Int64) -> Int64 {
        let indices = bucketAndSubBucketIndices(value)
        return valueFromIndex(bucketIndex: indices.bucket, subBucketIndex: indices.subBucket)
    }

    public func highestEquivalentValue(_ value: Int64) -> Int64 {
        return nextNonEquivalentValue(value) - 1
    }

    public func nextNonEquivalentValue(_ value: Int64) -> Int64 {
        return lowestEquivalentValue(value) + sizeOfEquivalentValueRange(value)
    }

    // MARK: Helpers

    public var description: String {
        get {
            return "TODO"
        }
    }

    public static func == (lhs: Histogram, rhs: Histogram) -> Bool {
        if lhs.lowestDiscernibleValue != rhs.lowestDiscernibleValue ||
            lhs.numberOfSignificantValueDigits != rhs.numberOfSignificantValueDigits ||
            lhs.integerToDoubleConversionRatio != rhs.integerToDoubleConversionRatio {
            return false
        }

        if lhs.totalCount != rhs.totalCount {
            return false
        }

        if lhs.maxValue != rhs.maxValue {
            return false
        }

        if lhs.minNonZeroValue != rhs.minNonZeroValue {
            return false
        }

        // 2 histograms may be equal but have different underlying array sizes. This can happen for instance due to
        // resizing.
        if lhs.countsArrayLength == rhs.countsArrayLength {
            for i in (0...lhs.countsArrayLength) {
                if lhs[i] != rhs[i] {
                    return false
                }
            }
        } else {
            // Comparing the values is valid here because we have already confirmed the histograms have the same total
            // count. It would not be correct otherwise.

            // TODO
        }

        return true
    }
}
