import Foundation
import Testing
@testable import PixelCore

/// Linear congruential generator with a fixed seed (Knuth's MMIX constants): deterministic "random" keys.
private struct RankLCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
    mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private let rankAlphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

/// A valid key: 1 to 6 digits, never ending in "0".
private func randomKey(_ rng: inout RankLCG) -> String {
    let length = 1 + rng.next(below: 6)
    var key = ""
    for i in 0..<length {
        let digit = i == length - 1 ? 1 + rng.next(below: 35) : rng.next(below: 36)
        key.append(rankAlphabet[digit])
    }
    return key
}

private func isStrictlyIncreasing(_ keys: [String]) -> Bool {
    zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }
}

@Suite struct RankKeyTests {
    @Test func betweenNilAndNilIsAValidKey() {
        let key = RankKey.between(nil, nil)
        #expect(!key.isEmpty)
        #expect(RankKey.isValid(key))
        #expect(RankKey.after(nil) == key)
        #expect(RankKey.before(nil) == key)
    }

    @Test func betweenRandomPairsIsStrictlyInside() {
        var rng = RankLCG(seed: 20_260_930)
        var checked = 0
        while checked < 500 {
            let x = randomKey(&rng)
            let y = randomKey(&rng)
            guard x != y else { continue }
            let (a, b) = x < y ? (x, y) : (y, x)
            let middle = RankKey.between(a, b)
            #expect(a < middle && middle < b, "between(\(a), \(b)) = \(middle)")
            #expect(RankKey.isValid(middle), "between(\(a), \(b)) = \(middle)")
            checked += 1
        }
    }

    @Test func openEndsGoAfterAndBefore() {
        var rng = RankLCG(seed: 7)
        for _ in 0..<500 {
            let key = randomKey(&rng)
            let after = RankKey.after(key)
            let before = RankKey.before(key)
            #expect(key < after && RankKey.isValid(after), "after(\(key)) = \(after)")
            #expect(before < key && RankKey.isValid(before), "before(\(key)) = \(before)")
            #expect(RankKey.between(key, nil) == after)
            #expect(RankKey.between(nil, key) == before)
        }
    }

    @Test func repeatedInsertionsStayOrdered() {
        // 200 insertions at the head.
        var head = [RankKey.after(nil)]
        for _ in 0..<200 { head.insert(RankKey.before(head[0]), at: 0) }
        #expect(isStrictlyIncreasing(head))
        #expect(head.allSatisfy { $0.count <= 40 && RankKey.isValid($0) })

        // 200 insertions at the end.
        var tail = [RankKey.after(nil)]
        for _ in 0..<200 { tail.append(RankKey.after(tail[tail.count - 1])) }
        #expect(isStrictlyIncreasing(tail))
        #expect(tail.allSatisfy { $0.count <= 40 && RankKey.isValid($0) })

        // 200 insertions between the same two neighbours, right after the lower one…
        var afterLower = ["a", "b"]
        for _ in 0..<200 { afterLower.insert(RankKey.between(afterLower[0], afterLower[1]), at: 1) }
        #expect(isStrictlyIncreasing(afterLower))
        #expect(afterLower.allSatisfy { $0.count <= 40 && RankKey.isValid($0) })

        // …and right before the upper one.
        var beforeUpper = ["a", "b"]
        for _ in 0..<200 {
            let n = beforeUpper.count
            beforeUpper.insert(RankKey.between(beforeUpper[n - 2], beforeUpper[n - 1]), at: n - 1)
        }
        #expect(isStrictlyIncreasing(beforeUpper))
        #expect(beforeUpper.allSatisfy { $0.count <= 40 && RankKey.isValid($0) })
    }

    @Test func alternatingInsertionsStayOrdered() {
        // Each key goes in the middle of the last gap, alternately on its left and right side: the worst case,
        // where a middle gains about 5 bits (one character) every 5 insertions.
        var lower = "a"
        var upper = "b"
        var all = [lower, upper]
        for i in 0..<200 {
            let key = RankKey.between(lower, upper)
            #expect(lower < key && key < upper)
            all.append(key)
            if i.isMultiple(of: 2) { lower = key } else { upper = key }
        }
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0.count <= 45 && RankKey.isValid($0) })
    }

    @Test func insertionsAtRandomPlacesStayOrderedAndShort() {
        var rng = RankLCG(seed: 42)
        var keys: [String] = []
        for _ in 0..<2_000 {
            let position = rng.next(below: keys.count + 1)
            let lower = position == 0 ? nil : keys[position - 1]
            let upper = position == keys.count ? nil : keys[position]
            keys.insert(RankKey.between(lower, upper), at: position)
        }
        #expect(isStrictlyIncreasing(keys))
        #expect(keys.allSatisfy { $0.count <= 12 && RankKey.isValid($0) })
    }

    @Test func spreadIsStrictlyIncreasing() {
        let five = RankKey.spread(5)
        #expect(five.count == 5)
        #expect(isStrictlyIncreasing(five))
        #expect(five.allSatisfy(RankKey.isValid))
        #expect(RankKey.spread(0).isEmpty)
        #expect(RankKey.spread(-3).isEmpty)
        #expect(RankKey.spread(1) == [RankKey.between(nil, nil)])
        for count in [35, 36, 37, 1_000, 5_000] {
            let keys = RankKey.spread(count)
            #expect(keys.count == count)
            #expect(isStrictlyIncreasing(keys))
            #expect(keys.allSatisfy(RankKey.isValid))
        }
    }

    @Test func bothEndsKeepRoomAfterSpread() {
        let keys = RankKey.spread(10)
        #expect(RankKey.before(keys[0]) < keys[0])
        #expect(RankKey.after(keys[9]) > keys[9])
        for (a, b) in zip(keys, keys.dropFirst()) {
            let middle = RankKey.between(a, b)
            #expect(a < middle && middle < b)
        }
    }

    @Test func invalidBoundsFallBackToAKeyAfterLower() {
        #expect(RankKey.between("b", "a") > "b")
        #expect(RankKey.between("k", "k") > "k")
        #expect(RankKey.isValid(RankKey.between("b", "a")))
        // Keys from a hand-edited file never make it crash nor produce an invalid key.
        for (lower, upper) in [("", "a"), ("A", "b"), ("a0", "b"), ("z", "0"), ("é", nil), (nil, "0")] as [(String?, String?)] {
            #expect(RankKey.isValid(RankKey.between(lower, upper)))
        }
    }

    @Test func validity() {
        #expect(RankKey.isValid("i"))
        #expect(RankKey.isValid("0z"))
        #expect(!RankKey.isValid(""))
        #expect(!RankKey.isValid("a0"))
        #expect(!RankKey.isValid("A"))
        #expect(!RankKey.isValid("a b"))
    }
}
