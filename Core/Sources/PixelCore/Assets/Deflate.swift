import Foundation

/// CRC-32 of PNG chunks and zlib.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    /// Table-driven, reflected polynomial 0xEDB88320 (PNG, zlib).
    /// `initial` is the checksum of the bytes that come before (0 to start), so a chunk's CRC over its type and
    /// then its data is `checksum(data, initial: checksum(type))`.
    public static func checksum(_ bytes: [UInt8], initial: UInt32 = 0) -> UInt32 {
        var crc = ~initial
        table.withUnsafeBufferPointer { table in
            bytes.withUnsafeBufferPointer { bytes in
                for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        return ~crc
    }
}

/// Adler-32 of zlib streams (RFC 1950).
public enum Adler32 {
    /// Bytes summed between two reductions modulo 65 521: the most that cannot overflow 32 bits (zlib's NMAX).
    private static let reductionInterval = 5_552

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        bytes.withUnsafeBufferPointer { bytes in
            var index = 0
            while index < bytes.count {
                let end = min(index + reductionInterval, bytes.count)
                while index < end {
                    a &+= UInt32(bytes[index])
                    b &+= a
                    index += 1
                }
                a %= 65_521
                b %= 65_521
            }
        }
        return b << 16 | a
    }
}

public enum DeflateMode: Hashable, Sendable {
    /// Uncompressed blocks (BTYPE 00): fastest, about the input's size.
    case stored
    /// LZ77 matches coded with the fixed Huffman tables (BTYPE 01).
    case fixedHuffman
}

public enum Deflate {
    /// zlib stream (RFC 1950): CMF/FLG, deflate blocks (RFC 1951), Adler32. `.stored`: blocks of ≤ 65 535 bytes.
    /// `.fixedHuffman`: LZ77 (32 KiB window, hash chains on 3-byte prefixes, greedy, matches of 3 to 258) coded with
    /// the fixed Huffman tables (BTYPE 01). Deterministic.
    public static func zlib(_ data: [UInt8], mode: DeflateMode = .fixedHuffman) -> [UInt8] {
        // CMF 0x78: deflate with a 32 KiB window. FLG: no dictionary, level "fastest" (stored) or "fast"
        // (greedy matching), check bits making CMF·256 + FLG a multiple of 31.
        var stream: [UInt8]
        switch mode {
        case .stored:
            stream = [0x78, 0x01]
            stream.reserveCapacity(data.count + 5 * (data.count / maxStoredBlock + 1) + 6)
            appendStoredBlocks(data, to: &stream)
        case .fixedHuffman:
            stream = [0x78, 0x5E]
            stream += fixedHuffmanBlock(LZ77.tokens(data))
        }
        let adler = Adler32.checksum(data)
        stream += [UInt8(adler >> 24), UInt8(truncatingIfNeeded: adler >> 16),
                   UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler)]
        return stream
    }

    static let maxStoredBlock = 65_535

    /// Byte-aligned stored blocks; an empty input still gets one (final, empty) block.
    private static func appendStoredBlocks(_ data: [UInt8], to stream: inout [UInt8]) {
        var start = 0
        repeat {
            let end = min(start + maxStoredBlock, data.count)
            let length = end - start
            let complement = 0xFFFF ^ length
            // BFINAL in bit 0, BTYPE 00, then padding to the byte boundary: the header is one byte.
            stream.append(end == data.count ? 1 : 0)
            stream += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(complement & 0xFF), UInt8(complement >> 8)]
            stream.append(contentsOf: data[start..<end])
            start = end
        } while start < data.count
    }

    /// One final fixed-Huffman block (raw deflate, no zlib wrapper) for these tokens, padded to a whole byte.
    static func fixedHuffmanBlock(_ tokens: [LZ77Token]) -> [UInt8] {
        var writer = DeflateBitWriter()
        writer.write(0b011, count: 3)  // BFINAL 1, then BTYPE 01 least significant bit first.
        FixedHuffman.literalLength.withUnsafeBufferPointer { codes in
            for token in tokens {
                if token.isLiteral {
                    writer.write(codes[Int(token.literal)])
                    continue
                }
                let lengthIndex = Int(FixedHuffman.lengthIndex[token.length])
                writer.write(codes[257 + lengthIndex])
                writer.write(UInt32(token.length - FixedHuffman.lengthBase[lengthIndex]),
                             count: FixedHuffman.lengthExtra[lengthIndex])
                let distanceIndex = FixedHuffman.distanceIndex(token.distance)
                writer.write(FixedHuffman.distance[distanceIndex])
                writer.write(UInt32(token.distance - FixedHuffman.distanceBase[distanceIndex]),
                             count: FixedHuffman.distanceExtra(distanceIndex))
            }
            writer.write(codes[256])  // End of block.
        }
        return writer.finish()
    }
}

/// A literal byte, or a match: copy `length` bytes from `distance` bytes back.
struct LZ77Token: Equatable, Sendable {
    /// 0 for a literal, else 3 to 258.
    private let rawLength: UInt16
    /// The literal byte, or the distance (1 to 32 768).
    private let rawValue: UInt16

    init(literal: UInt8) {
        rawLength = 0
        rawValue = UInt16(literal)
    }

    init(length: Int, distance: Int) {
        precondition((LZ77.minMatch...LZ77.maxMatch).contains(length), "match length out of 3...258")
        precondition((1...LZ77.window).contains(distance), "match distance out of 1...32768")
        rawLength = UInt16(length)
        rawValue = UInt16(distance)
    }

    var isLiteral: Bool { rawLength == 0 }
    /// The byte of a literal (meaningless for a match).
    var literal: UInt8 { UInt8(truncatingIfNeeded: rawValue) }
    /// The match length, 0 for a literal.
    var length: Int { Int(rawLength) }
    /// The match distance, 0 for a literal.
    var distance: Int { isLiteral ? 0 : Int(rawValue) }
}

/// Greedy LZ77 over a 32 KiB window. Each position is hashed on its 3-byte prefix; candidates are walked from the
/// most recent (smallest distance) and a later one is kept only when strictly longer, so equal matches take the
/// cheapest distance. The walk stops at a full-length match or after `maxChain` candidates. Every position, also
/// inside a match, enters its hash chain.
enum LZ77 {
    static let window = 32_768
    static let minMatch = 3
    static let maxMatch = 258
    /// Candidates tried per position: bounds the time spent on data with many equal prefixes.
    static let maxChain = 128
    private static let hashBits = 15

    static func tokens(_ data: [UInt8]) -> [LZ77Token] {
        let count = data.count
        guard count >= minMatch else { return data.map { LZ77Token(literal: $0) } }
        var tokens: [LZ77Token] = []
        tokens.reserveCapacity(count / 4)
        var head = [Int32](repeating: -1, count: 1 << hashBits)
        var previous = [Int32](repeating: -1, count: count)
        let lastHashed = count - minMatch

        data.withUnsafeBufferPointer { bytes in
            head.withUnsafeMutableBufferPointer { head in
                previous.withUnsafeMutableBufferPointer { previous in
                    func hash(_ position: Int) -> Int {
                        let key = UInt32(bytes[position]) << 16 | UInt32(bytes[position + 1]) << 8
                            | UInt32(bytes[position + 2])
                        return Int((key &* 2_654_435_761) >> UInt32(32 - hashBits))
                    }
                    func insert(_ position: Int, hash: Int) {
                        previous[position] = head[hash]
                        head[hash] = Int32(position)
                    }

                    var position = 0
                    while position < count {
                        var bestLength = 0
                        var bestDistance = 0
                        if position <= lastHashed {
                            let key = hash(position)
                            let limit = min(maxMatch, count - position)
                            var candidate = Int(head[key])
                            var tries = maxChain
                            while candidate >= 0, position - candidate <= window, tries > 0 {
                                tries -= 1
                                // A candidate that cannot beat the best differs at the best length.
                                if bytes[candidate + bestLength] == bytes[position + bestLength] {
                                    var length = 0
                                    while length < limit, bytes[candidate + length] == bytes[position + length] {
                                        length += 1
                                    }
                                    if length > bestLength {
                                        bestLength = length
                                        bestDistance = position - candidate
                                        if length == limit { break }
                                    }
                                }
                                candidate = Int(previous[candidate])
                            }
                            insert(position, hash: key)
                        }
                        if bestLength >= minMatch {
                            tokens.append(LZ77Token(length: bestLength, distance: bestDistance))
                            let end = position + bestLength
                            position += 1
                            while position < end {
                                if position <= lastHashed { insert(position, hash: hash(position)) }
                                position += 1
                            }
                        } else {
                            tokens.append(LZ77Token(literal: bytes[position]))
                            position += 1
                        }
                    }
                }
            }
        }
        return tokens
    }
}

/// The fixed Huffman code of RFC 1951 3.2.6, stored bit-reversed: deflate writes Huffman codes most significant
/// bit first into a stream filled least significant bit first.
private enum FixedHuffman {
    /// Literal/length symbols 0 to 287: 0-143 on 8 bits from 00110000, 144-255 on 9 bits from 110010000,
    /// 256-279 on 7 bits from 0000000, 280-287 on 8 bits from 11000000.
    static let literalLength: [HuffmanCode] = (0..<288).map { symbol in
        switch symbol {
        case 0...143: HuffmanCode(code: 0x30 + symbol, length: 8)
        case 144...255: HuffmanCode(code: 0x190 + symbol - 144, length: 9)
        case 256...279: HuffmanCode(code: symbol - 256, length: 7)
        default: HuffmanCode(code: 0xC0 + symbol - 280, length: 8)
        }
    }

    /// Distance symbols 0 to 29, all on 5 bits.
    static let distance: [HuffmanCode] = (0..<30).map { HuffmanCode(code: $0, length: 5) }

    /// Lengths 3 to 258 of symbols 257 to 285; 258 has its own symbol (285), never 284 with extra bits 31.
    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                             35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

    /// Index into `lengthBase` for each length 0 to 258 (0 below 3): the last base not above the length.
    static let lengthIndex: [UInt8] = (0...LZ77.maxMatch).map { length in
        UInt8(lengthBase.lastIndex { $0 <= length } ?? 0)
    }

    /// Distance symbol d covers `distanceBase[d]` to `distanceBase[d] + 2^extra - 1`.
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                               257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

    static func distanceExtra(_ index: Int) -> Int { index < 4 ? 0 : index / 2 - 1 }

    /// Distances 1-4 are symbols 0-3; above, two symbols per power of two of `distance - 1`, told apart by the bit
    /// below its highest one.
    static func distanceIndex(_ distance: Int) -> Int {
        guard distance > 4 else { return distance - 1 }
        let value = distance - 1
        let highBit = Int.bitWidth - 1 - value.leadingZeroBitCount
        return 2 * highBit + ((value >> (highBit - 1)) & 1)
    }
}

/// A Huffman code already bit-reversed for an LSB-first stream.
private struct HuffmanCode {
    let reversed: UInt32
    let length: Int

    init(code: Int, length: Int) {
        var reversed: UInt32 = 0
        for bit in 0..<length { reversed |= UInt32((code >> bit) & 1) << UInt32(length - 1 - bit) }
        self.reversed = reversed
        self.length = length
    }
}

/// Deflate's bit order: values enter least significant bit first, bytes fill from their low bit.
private struct DeflateBitWriter {
    private var bytes: [UInt8] = []
    private var buffer: UInt64 = 0
    private var pending = 0

    mutating func write(_ value: UInt32, count: Int) {
        buffer |= UInt64(value) << UInt64(pending)
        pending += count
        while pending >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: buffer))
            buffer >>= 8
            pending -= 8
        }
    }

    mutating func write(_ code: HuffmanCode) { write(code.reversed, count: code.length) }

    /// The bytes written, the last one padded with zero bits.
    mutating func finish() -> [UInt8] {
        if pending > 0 { bytes.append(UInt8(truncatingIfNeeded: buffer)) }
        buffer = 0
        pending = 0
        return bytes
    }
}
