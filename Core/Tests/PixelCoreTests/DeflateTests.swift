import Foundation
import Testing
@testable import PixelCore

@Suite struct DeflateTests {
    // MARK: - Checksums

    @Test func crc32KnownVectors() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Array("IEND".utf8)) == 0xAE42_6082)
        #expect(CRC32.checksum([]) == 0)
        // `initial` continues a running checksum: chunk CRCs cover the type, then the data.
        #expect(CRC32.checksum(Array("56789".utf8), initial: CRC32.checksum(Array("1234".utf8))) == 0xCBF4_3926)
    }

    @Test func crc32MatchesBitwiseReference() {
        let bytes = seededBytes(10_000, seed: 7)
        #expect(CRC32.checksum(bytes) == PNGTestDecoder.referenceCRC32(bytes))
    }

    @Test func adler32KnownVectors() {
        #expect(Adler32.checksum(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Adler32.checksum([]) == 1)
        // Long runs of 0xFF push both sums past the modulus many times between reductions.
        let ones = [UInt8](repeating: 0xFF, count: 100_000)
        #expect(Adler32.checksum(ones) == PNGTestDecoder.referenceAdler32(ones))
        let random = seededBytes(100_003, seed: 11)
        #expect(Adler32.checksum(random) == PNGTestDecoder.referenceAdler32(random))
    }

    // MARK: - zlib streams

    @Test func roundTripStoredAndFixed() throws {
        for mode in [DeflateMode.stored, .fixedHuffman] {
            for (name, input) in roundTripInputs {
                let stream = Deflate.zlib(input, mode: mode)
                let inflated = try PNGTestDecoder.inflateZlib(stream)
                #expect(inflated == input, "\(mode) \(name)")
            }
        }
    }

    @Test func zlibHeaderIsValid() {
        for mode in [DeflateMode.stored, .fixedHuffman] {
            let stream = Deflate.zlib(Array("îlot".utf8), mode: mode)
            #expect(stream[0] == 0x78, "deflate, 32 KiB window")
            #expect((Int(stream[0]) * 256 + Int(stream[1])) % 31 == 0)
            #expect(stream[1] & 0x20 == 0, "no preset dictionary")
        }
    }

    @Test func storedBlocksHoldAtMost65535Bytes() {
        for count in [0, 1, 65_535, 65_536, 131_070, 131_071] {
            let input = seededBytes(count, seed: UInt64(count))
            let stream = Deflate.zlib(input, mode: .stored)
            let blocks = max(1, (count + 65_534) / 65_535)
            // Header, then per block one header byte and LEN/NLEN, then the bytes, then Adler32.
            #expect(stream.count == 2 + 5 * blocks + count + 4, "\(count) bytes")
        }
    }

    @Test func fixedHuffmanCompressesRuns() {
        let stream = Deflate.zlib([UInt8](repeating: 0, count: 100_000), mode: .fixedHuffman)
        #expect(stream.count < 1_000)
    }

    @Test func outputIsDeterministic() {
        let input = roundTripInputs.flatMap(\.1)
        for mode in [DeflateMode.stored, .fixedHuffman] {
            #expect(Deflate.zlib(input, mode: mode) == Deflate.zlib(input, mode: mode))
        }
    }

    // MARK: - LZ77 and the fixed code, separately

    @Test func lz77TokensReconstructInput() {
        for (name, input) in roundTripInputs {
            let tokens = LZ77.tokens(input)
            var output: [UInt8] = []
            for token in tokens {
                if token.isLiteral {
                    output.append(token.literal)
                    continue
                }
                #expect((3...258).contains(token.length), "\(name)")
                #expect((1...32_768).contains(token.distance), "\(name)")
                guard token.distance <= output.count else {
                    Issue.record("\(name): distance \(token.distance) before the start")
                    return
                }
                let start = output.count - token.distance
                for offset in 0..<token.length { output.append(output[start + offset]) }
            }
            #expect(output == input, "\(name)")
        }
    }

    @Test func lz77IsGreedyOnRuns() {
        let tokens = LZ77.tokens([UInt8](repeating: 0, count: 1_000))
        #expect(tokens == [.init(literal: 0), .init(length: 258, distance: 1), .init(length: 258, distance: 1),
                           .init(length: 258, distance: 1), .init(length: 225, distance: 1)])
    }

    @Test func lz77ReachesTheWindowEdge() {
        let block = seededBytes(32_768, seed: 21)
        let tokens = LZ77.tokens(block + block)
        #expect(tokens.contains { !$0.isLiteral && $0.distance == 32_768 })
        let wider = seededBytes(32_769, seed: 22)
        #expect(LZ77.tokens(wider + wider).allSatisfy { $0.isLiteral || $0.distance <= 32_768 })
    }

    /// Codes every length (3 to 258) and both ends of every distance code (1 to 32 768) through the fixed
    /// Huffman block, whatever the matcher would have chosen.
    @Test func fixedHuffmanCodesEveryLengthAndDistance() throws {
        let prefix = seededBytes(32_768, seed: 33)
        var tokens = prefix.map { LZ77Token(literal: $0) }
        let distances = distanceCodeEnds()
        #expect(distances.count == 60)
        for length in 3...258 {
            tokens.append(LZ77Token(length: length, distance: distances[length % distances.count]))
        }
        for (index, distance) in distances.enumerated() {
            tokens.append(LZ77Token(length: 3 + index * 4, distance: distance))
        }
        for literal in 0...255 { tokens.append(LZ77Token(literal: UInt8(literal))) }

        var expected: [UInt8] = []
        for token in tokens {
            if token.isLiteral {
                expected.append(token.literal)
            } else {
                let start = expected.count - token.distance
                for offset in 0..<token.length { expected.append(expected[start + offset]) }
            }
        }
        let adler = Adler32.checksum(expected)
        let stream = [0x78, 0x5E] + Deflate.fixedHuffmanBlock(tokens)
            + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
        #expect(try PNGTestDecoder.inflateZlib(stream) == expected)
    }

    #if canImport(Darwin)
    /// Cross-check against the system zlib: `NSData` decompresses raw deflate (no zlib header or trailer).
    @Test func systemZlibInflatesSameBytes() throws {
        for mode in [DeflateMode.stored, .fixedHuffman] {
            for (name, input) in roundTripInputs where !input.isEmpty {
                let stream = Deflate.zlib(input, mode: mode)
                let raw = Data(stream[2..<(stream.count - 4)])
                let inflated = try (raw as NSData).decompressed(using: .zlib) as Data
                #expect([UInt8](inflated) == input, "\(mode) \(name)")
            }
        }
    }
    #endif

    // MARK: - Inputs

    private var roundTripInputs: [(String, [UInt8])] {
        let text = Array(String(repeating: "Le poste de Nova attend une réponse, îlot API. ", count: 1_500).utf8)
        let window = seededBytes(32_768, seed: 5)
        let beyond = seededBytes(33_000, seed: 6)
        return [
            ("empty", []),
            ("one byte", [0x42]),
            ("random 100 000", seededBytes(100_000, seed: 1)),
            ("zeros 100 000", [UInt8](repeating: 0, count: 100_000)),
            ("repetitive text", text),
            ("random 65 535", seededBytes(65_535, seed: 2)),
            ("random 65 536", seededBytes(65_536, seed: 3)),
            ("random 131 071", seededBytes(131_071, seed: 4)),
            ("window edge", window + window),
            ("beyond the window", beyond + beyond),
            ("short runs", (0..<20_000).map { UInt8(($0 / 3) % 7) }),
        ]
    }

    /// The first and last distance of each of the 30 distance codes.
    private func distanceCodeEnds() -> [Int] {
        var ends: [Int] = []
        var base = 1
        for code in 0..<30 {
            let extra = code < 4 ? 0 : code / 2 - 1
            ends.append(base)
            ends.append(base + (1 << extra) - 1)
            base += 1 << extra
        }
        return ends
    }
}

/// `count` bytes from a seeded SplitMix64, 8 per draw.
private func seededBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var rng = SplitMix64(seed: seed)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count + 8)
    while bytes.count < count {
        let word = rng.next()
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
    }
    return Array(bytes.prefix(count))
}
