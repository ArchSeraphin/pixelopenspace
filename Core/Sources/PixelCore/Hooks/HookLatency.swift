import Foundation

/// Nearest-rank percentile: the smallest value such that at least `p` % of the values are less than or equal to it
/// (rank ceil(p × n / 100), never interpolated, so always one of the values).
public enum Percentile {
    /// `p` is clamped to 0...100 (NaN counts as 0); p = 0 gives the minimum. nil when `values` is empty.
    public static func nearestRank<T: Comparable>(_ p: Double, of values: [T]) -> T? {
        nearestRank(p, ofSorted: values.sorted())
    }

    /// Same, for values already sorted in ascending order.
    public static func nearestRank<T: Comparable>(_ p: Double, ofSorted sorted: [T]) -> T? {
        guard !sorted.isEmpty else { return nil }
        let percent = p.isNaN ? 0 : min(max(p, 0), 100)
        // p × n is exact for whole percents, so ceil does not suffer from 0.95 × 100 = 94.999….
        let rank = Int((percent * Double(sorted.count) / 100).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// Hook → screen latency (proposal 7, MVP acceptance criterion 2: "p95 visé < 150 ms"). For each accepted hook
/// event, the gap between the helper's `ts_ns` and the moment the app applied the new state, both read on the same
/// monotonic clock (`HookWire.monotonicNanos()`). Keeps the last `capacity` gaps (a sliding window).
/// Pure: the caller passes both clock readings.
public struct LatencyWindow: Sendable {
    public static let defaultCapacity = 500
    /// Beyond a minute, a gap is a clock mismatch (an envelope stamped on another boot, a forged timestamp), not a
    /// latency: it is ignored rather than allowed to spoil the p95.
    public static let maxPlausibleNs: UInt64 = 60 * 1_000_000_000

    public let capacity: Int
    /// Ring buffer of gaps in nanoseconds; once full, `nextIndex` is the oldest one.
    private var ring: [UInt64] = []
    private var nextIndex = 0

    /// `capacity` is at least 1.
    public init(capacity: Int = LatencyWindow.defaultCapacity) {
        self.capacity = max(1, capacity)
        ring.reserveCapacity(self.capacity)
    }

    public var count: Int { ring.count }

    /// Gaps in nanoseconds, oldest first.
    public var samples: [UInt64] {
        guard ring.count == capacity, nextIndex > 0 else { return ring }
        return Array(ring[nextIndex...]) + Array(ring[..<nextIndex])
    }

    /// Records `appliedNs - sentNs`, dropping the oldest gap once full. Returns false, recording nothing, when the
    /// envelope had no timestamp (`sentNs` = 0, `HookDecoder`'s default), when it is after `appliedNs` (not the same
    /// clock), or when the gap exceeds `maxPlausibleNs`.
    @discardableResult
    public mutating func record(sentNs: UInt64, appliedNs: UInt64) -> Bool {
        guard sentNs > 0, appliedNs >= sentNs else { return false }
        let gap = appliedNs - sentNs
        guard gap <= Self.maxPlausibleNs else { return false }
        if ring.count < capacity {
            ring.append(gap)
        } else {
            ring[nextIndex] = gap
        }
        nextIndex = (nextIndex + 1) % capacity
        return true
    }

    /// p50 and p95 of the window; nil while it is empty.
    public var summary: LatencySummary? {
        let sorted = ring.sorted()
        guard let p50 = Percentile.nearestRank(50, ofSorted: sorted),
              let p95 = Percentile.nearestRank(95, ofSorted: sorted) else { return nil }
        return LatencySummary(p50Ns: p50, p95Ns: p95, count: sorted.count)
    }
}

/// What Réglages › Avancé shows: "p50 12 ms · p95 40 ms · 500 mesures".
public struct LatencySummary: Equatable, Sendable {
    /// MVP acceptance criterion 2: the p95 must stay under 150 ms.
    public static let targetP95Ns: UInt64 = 150_000_000

    public var p50Ns: UInt64
    public var p95Ns: UInt64
    /// Measurements in the window.
    public var count: Int

    public init(p50Ns: UInt64, p95Ns: UInt64, count: Int) {
        self.p50Ns = p50Ns
        self.p95Ns = p95Ns
        self.count = count
    }

    public var meetsTarget: Bool { p95Ns < Self.targetP95Ns }

    /// "p50 12 ms · p95 40 ms · 500 mesures".
    public var text: String {
        let measurements = count == 1 ? "1 mesure" : "\(count) mesures"
        return "p50 \(Self.millisecondsText(p50Ns)) · p95 \(Self.millisecondsText(p95Ns)) · \(measurements)"
    }

    /// Rounded to the nearest millisecond ("12 ms"); under half a millisecond, "< 1 ms".
    public static func millisecondsText(_ nanoseconds: UInt64) -> String {
        let milliseconds = nanoseconds / 1_000_000 + (nanoseconds % 1_000_000 >= 500_000 ? 1 : 0)
        return milliseconds == 0 ? "< 1 ms" : "\(milliseconds) ms"
    }
}
