import Foundation

/// Fractional order keys: a key can always be made between two others, so reordering or inserting a card
/// rewrites one key only. Keys are base-36 digit strings (`0-9a-z`) compared with `<`, read as fractions
/// 0.d1d2d3… ("i" = 18/36), and never end in "0": "k0" would equal "k" as a fraction while sorting after it,
/// and nothing could be inserted between them.
///
/// Between two keys, the new key is their middle, digit by digit: the shorter key is extended with the minimal
/// digit for `lower` and a virtual maximal+1 digit for `upper`, and a middle taken against a virtual digit is
/// rounded towards the real key. Repeated insertions in one gap grow the keys by one character every 5 or 6
/// insertions, whatever their pattern. At an open end (a nil bound: appending, prepending) the key moves by one
/// digit instead, which grows the keys by one character every 18 insertions.
public enum RankKey {
    static let alphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let base = 36
    /// "i": the middle of the whole range, first key of an empty list.
    private static let midDigit = 18

    /// A key strictly between `lower` and `upper` (nil = open end). Keys use the digits 0-9a-z and compare with `<`.
    /// Precondition: lower < upper when both are given (otherwise returns a key after `lower`).
    /// Always returns a valid key, even for invalid bounds (hand-edited file): see `TaskBoardValidator`.
    public static func between(_ lower: String?, _ upper: String?) -> String {
        let low = trimmed(digits(lower ?? ""))
        guard let upper else { return string(stepAfter(low[...])) }
        let high = trimmed(digits(upper))
        guard !high.isEmpty, low.lexicographicallyPrecedes(high) else { return string(stepAfter(low[...])) }
        if lower == nil { return string(stepBefore(high[...])) }
        return string(middle(low[...], high[...]))
    }

    /// `between(key, nil)`.
    public static func after(_ key: String?) -> String { between(key, nil) }

    /// `between(nil, key)`.
    public static func before(_ key: String?) -> String { between(nil, key) }

    /// n evenly spread keys, ascending (renumbering, imports). The shortest length that fits, never ending in "0".
    public static func spread(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        var length = 1
        var space = base
        while space <= count {
            let (next, overflow) = space.multipliedReportingOverflow(by: base)
            guard !overflow else { break }
            space = next
            length += 1
        }
        let slots = count + 1
        return (1...count).map { i in
            // floor(i × space / (count + 1)) without overflow: 1 ≤ value < space, strictly increasing.
            let (value, _) = slots.dividingFullWidth(i.multipliedFullWidth(by: space))
            var fixed = [Int](repeating: 0, count: length)
            var rest = value
            for position in stride(from: length - 1, through: 0, by: -1) {
                fixed[position] = rest % base
                rest /= base
            }
            return string(trimmed(fixed))
        }
    }

    /// Non-empty, only digits of the alphabet, not ending in "0".
    public static func isValid(_ key: String) -> Bool {
        guard let last = key.unicodeScalars.last, last != "0" else { return false }
        return key.unicodeScalars.allSatisfy { digit(of: $0) != nil }
    }

    // MARK: - Digits

    private static func digit(of scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 48...57: Int(scalar.value) - 48
        case 97...122: Int(scalar.value) - 97 + 10
        default: nil
        }
    }

    /// Digits of a key; characters outside the alphabet are clamped to the nearest digit in string order.
    private static func digits(_ key: String) -> [Int] {
        key.unicodeScalars.map { scalar in
            if let digit = digit(of: scalar) { return digit }
            if scalar.value < 48 { return 0 }
            return scalar.value < 97 ? 9 : base - 1
        }
    }

    /// Trailing zeros removed: "k0" and "k" are the same fraction.
    private static func trimmed(_ digits: [Int]) -> [Int] {
        var digits = digits
        while digits.last == 0 { digits.removeLast() }
        return digits
    }

    private static func string(_ digits: [Int]) -> String {
        String(digits.map { alphabet[$0] })
    }

    // MARK: - Arithmetic on digit strings (no trailing zeros)

    /// A key strictly between `low` and `high`; requires low < high, high non-empty.
    private static func middle(_ low: ArraySlice<Int>, _ high: ArraySlice<Int>) -> [Int] {
        if low.isEmpty { return halfBefore(high) }
        // Common prefix, `low` padded with zeros.
        var n = 0
        while n < high.count, (n < low.count ? low[low.startIndex + n] : 0) == high[high.startIndex + n] { n += 1 }
        if n > 0 {
            // n < high.count, otherwise high <= low.
            return Array(high.prefix(n)) + middle(low.dropFirst(n), high.dropFirst(n))
        }
        let l = low[low.startIndex]
        let h = high[high.startIndex]
        if h - l > 1 { return [(l + h) / 2] }
        // Consecutive first digits: `h` alone when it is shorter than `high`, else `l` and a key after the rest
        // of `low` (bounded by the virtual digit 36).
        if high.count > 1 { return [h] }
        return [l] + halfAfter(low.dropFirst())
    }

    /// Middle between `low` (possibly empty) and a virtual upper digit 36, rounded towards `low`.
    private static func halfAfter(_ low: ArraySlice<Int>) -> [Int] {
        guard let first = low.first else { return [midDigit] }
        if first < base - 1 { return [(first + base) / 2] }
        return [first] + halfAfter(low.dropFirst())
    }

    /// Middle between a virtual lower digit 0 and `high` (non-empty, not ending in zero), rounded towards `high`.
    private static func halfBefore(_ high: ArraySlice<Int>) -> [Int] {
        let first = high[high.startIndex]
        if first > 1 { return [(first + 1) / 2] }
        if first == 1 { return high.count > 1 ? [1] : [0] + halfAfter([]) }
        // A leading zero is never the last digit.
        return [0] + halfBefore(high.dropFirst())
    }

    /// One digit step after `low` (possibly empty = the start): appending.
    private static func stepAfter(_ low: ArraySlice<Int>) -> [Int] {
        guard let first = low.first else { return [midDigit] }
        if first < base - 1 { return [first + 1] }
        return [first] + stepAfter(low.dropFirst())
    }

    /// One digit step before `high` (non-empty, not ending in zero): prepending.
    private static func stepBefore(_ high: ArraySlice<Int>) -> [Int] {
        let first = high[high.startIndex]
        if first > 1 { return [first - 1] }
        if first == 1 { return high.count > 1 ? [1] : [0] + stepAfter([]) }
        // A leading zero is never the last digit.
        return [0] + stepBefore(high.dropFirst())
    }
}
