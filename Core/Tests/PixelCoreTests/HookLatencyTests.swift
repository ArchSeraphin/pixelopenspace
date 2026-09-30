import Foundation
import Testing
@testable import PixelCore

@Suite struct PercentileTests {
    @Test func emptyHasNoPercentile() {
        #expect(Percentile.nearestRank(50, of: [Int]()) == nil)
        #expect(Percentile.nearestRank(95, ofSorted: [UInt64]()) == nil)
    }

    @Test func singleValueIsEveryPercentile() {
        for p in [0.0, 1, 50, 95, 100] {
            #expect(Percentile.nearestRank(p, of: [7]) == 7)
        }
    }

    @Test func nearestRankOnOneToHundred() {
        let values = Array(1...100)
        #expect(Percentile.nearestRank(0, of: values) == 1)
        #expect(Percentile.nearestRank(1, of: values) == 1)
        #expect(Percentile.nearestRank(50, of: values) == 50)
        #expect(Percentile.nearestRank(95, of: values) == 95)
        #expect(Percentile.nearestRank(99, of: values) == 99)
        #expect(Percentile.nearestRank(100, of: values) == 100)
    }

    /// Rank = ceil(p × n / 100): never interpolated, always one of the values.
    @Test func rankRoundsUp() {
        let values = Array(1...10)
        #expect(Percentile.nearestRank(50, of: values) == 5)
        #expect(Percentile.nearestRank(51, of: values) == 6)
        #expect(Percentile.nearestRank(95, of: values) == 10)
        #expect(Percentile.nearestRank(90, of: values) == 9)
        #expect(Percentile.nearestRank(95, of: [10, 20, 30]) == 30)
        #expect(Percentile.nearestRank(50, of: [10, 20, 30]) == 20)
        #expect(Percentile.nearestRank(50, of: [10, 20]) == 10)
    }

    @Test func unsortedInputIsSortedFirst() {
        #expect(Percentile.nearestRank(50, of: [9, 1, 5, 3, 7]) == 5)
        #expect(Percentile.nearestRank(95, of: [40, 12, 3, 800, 25]) == 800)
    }

    @Test func percentOutsideRangeIsClamped() {
        let values = [3, 1, 2]
        #expect(Percentile.nearestRank(-10, of: values) == 1)
        #expect(Percentile.nearestRank(250, of: values) == 3)
        #expect(Percentile.nearestRank(.nan, of: values) == 1)
    }
}

@Suite struct LatencyWindowTests {
    private static let ms: UInt64 = 1_000_000
    /// Any monotonic reading: the window only looks at differences.
    private static let base: UInt64 = 5_000_000_000_000

    /// Records gaps of `gapsMs` milliseconds.
    private static func window(_ gapsMs: [UInt64], capacity: Int = LatencyWindow.defaultCapacity) -> LatencyWindow {
        var window = LatencyWindow(capacity: capacity)
        for gap in gapsMs {
            window.record(sentNs: base, appliedNs: base + gap * ms)
        }
        return window
    }

    @Test func emptyWindowHasNoSummary() {
        let window = LatencyWindow()
        #expect(window.capacity == 500)
        #expect(window.count == 0)
        #expect(window.samples.isEmpty)
        #expect(window.summary == nil)
    }

    @Test func recordsTheGapBetweenHelperAndApplication() {
        var window = LatencyWindow()
        let first = window.record(sentNs: Self.base, appliedNs: Self.base + 12 * Self.ms)
        let second = window.record(sentNs: Self.base, appliedNs: Self.base)
        #expect(first && second)
        #expect(window.samples == [12 * Self.ms, 0])
        #expect(window.count == 2)
    }

    /// `ts_ns` = 0: the envelope had no timestamp (`HookDecoder` default), nothing to measure.
    @Test func missingTimestampIsIgnored() {
        var window = LatencyWindow()
        let recorded = window.record(sentNs: 0, appliedNs: Self.base)
        #expect(!recorded)
        #expect(window.count == 0)
    }

    /// A helper reading after the app's own: not the same clock (or a forged value), never a negative latency.
    @Test func timestampFromTheFutureIsIgnored() {
        var window = LatencyWindow()
        let recorded = window.record(sentNs: Self.base + 1, appliedNs: Self.base)
        #expect(!recorded)
        #expect(window.count == 0)
    }

    /// A gap beyond a minute is a clock mismatch (another boot, a forged timestamp), not a latency.
    @Test func implausibleGapIsIgnored() {
        var window = LatencyWindow()
        let atTheLimit = window.record(sentNs: Self.base, appliedNs: Self.base + LatencyWindow.maxPlausibleNs)
        let beyond = window.record(sentNs: Self.base, appliedNs: Self.base + LatencyWindow.maxPlausibleNs + 1)
        #expect(atTheLimit)
        #expect(!beyond)
        #expect(window.samples == [LatencyWindow.maxPlausibleNs])
    }

    @Test func keepsOnlyTheLastFiveHundred() throws {
        let window = Self.window(Array(1...600))
        #expect(window.count == 500)
        #expect(window.samples == (101...600).map { $0 * Self.ms })
        let summary = try #require(window.summary)
        #expect(summary.count == 500)
        // Ranks 250 and 475 of 101...600.
        #expect(summary.p50Ns == 350 * Self.ms)
        #expect(summary.p95Ns == 575 * Self.ms)
    }

    @Test func samplesStayOldestFirstAcrossTheWrap() {
        let window = Self.window([1, 2, 3, 4, 5], capacity: 3)
        #expect(window.samples == [3, 4, 5].map { $0 * Self.ms })
        let exact = Self.window([1, 2, 3], capacity: 3)
        #expect(exact.samples == [1, 2, 3].map { $0 * Self.ms })
    }

    @Test func capacityIsAtLeastOne() {
        let window = Self.window([4, 9], capacity: 0)
        #expect(window.capacity == 1)
        #expect(window.samples == [9 * Self.ms])
    }

    @Test func summaryOfUnorderedGaps() {
        let window = Self.window([40, 12, 3, 800, 25, 12, 9, 14, 30, 11])
        #expect(window.summary == LatencySummary(p50Ns: 12 * Self.ms, p95Ns: 800 * Self.ms, count: 10))
    }
}

@Suite struct LatencySummaryTests {
    private static let ms: UInt64 = 1_000_000

    @Test func textShowsBothPercentilesAndTheCount() {
        let summary = LatencySummary(p50Ns: 12 * Self.ms, p95Ns: 40 * Self.ms, count: 500)
        #expect(summary.text == "p50 12 ms · p95 40 ms · 500 mesures")
    }

    @Test func oneMeasurementIsSingular() {
        let summary = LatencySummary(p50Ns: 8 * Self.ms, p95Ns: 8 * Self.ms, count: 1)
        #expect(summary.text == "p50 8 ms · p95 8 ms · 1 mesure")
    }

    /// Rounded to the nearest millisecond; under half a millisecond reads "< 1 ms", never "0 ms".
    @Test func millisecondsAreRounded() {
        #expect(LatencySummary.millisecondsText(0) == "< 1 ms")
        #expect(LatencySummary.millisecondsText(499_999) == "< 1 ms")
        #expect(LatencySummary.millisecondsText(500_000) == "1 ms")
        #expect(LatencySummary.millisecondsText(12_400_000) == "12 ms")
        #expect(LatencySummary.millisecondsText(12_500_000) == "13 ms")
        #expect(LatencySummary.millisecondsText(1_234_000_000) == "1234 ms")
    }

    /// Acceptance criterion 2 of the MVP: p95 under 150 ms.
    @Test func targetIsAP95UnderOneHundredFiftyMilliseconds() {
        #expect(LatencySummary.targetP95Ns == 150 * Self.ms)
        #expect(LatencySummary(p50Ns: 10 * Self.ms, p95Ns: 149 * Self.ms, count: 3).meetsTarget)
        #expect(!LatencySummary(p50Ns: 10 * Self.ms, p95Ns: 150 * Self.ms, count: 3).meetsTarget)
        #expect(!LatencySummary(p50Ns: 10 * Self.ms, p95Ns: 900 * Self.ms, count: 3).meetsTarget)
    }
}
