import Foundation

/// Test-only PNG reader: signature, chunk CRCs, IHDR (8-bit RGBA), IDAT concatenation, zlib header and Adler32,
/// inflate of stored and fixed-Huffman blocks (dynamic blocks are an error), the five filters.
///
/// It is an oracle for `PNGEncoder` and `Deflate`, so it shares no code with them: its CRC32 is bitwise (no table),
/// its Adler32 takes the modulus at every byte, and it reads Huffman codes bit by bit from the code ranges of
/// RFC 1951 3.2.6 instead of building tables. It is strict: anything our encoder never writes is an error.
enum PNGTestDecoder {
    struct Decoded: Equatable {
        var width: Int
        var height: Int
        var rgba: [UInt8]
        var pixelsPerMeter: Int?
    }

    struct Chunk: Equatable {
        var type: String
        var data: [UInt8]
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// The chunks in file order, after checking the signature, each length and each CRC.
    static func chunks(_ png: [UInt8]) throws -> [Chunk] {
        guard png.count >= signature.count, Array(png[0..<signature.count]) == signature else {
            throw Failure("bad PNG signature")
        }
        var chunks: [Chunk] = []
        var position = signature.count
        while position < png.count {
            guard png.count - position >= 12 else { throw Failure("truncated chunk header at \(position)") }
            let length = Int(bigEndian32(png, position))
            guard length <= 0x7FFF_FFFF, png.count - position - 12 >= length else {
                throw Failure("chunk length \(length) runs past the end")
            }
            let typeBytes = Array(png[(position + 4)..<(position + 8)])
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
                throw Failure("chunk type is not 4 ASCII letters")
            }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let data = Array(png[(position + 8)..<(position + 8 + length)])
            let stored = bigEndian32(png, position + 8 + length)
            guard stored == referenceCRC32(typeBytes + data) else { throw Failure("CRC mismatch in \(type)") }
            chunks.append(Chunk(type: type, data: data))
            position += 12 + length
        }
        return chunks
    }

    static func decode(_ png: [UInt8]) throws -> Decoded {
        let chunks = try chunks(png)
        guard let first = chunks.first, first.type == "IHDR" else { throw Failure("IHDR is not the first chunk") }
        guard let last = chunks.last, last.type == "IEND", last.data.isEmpty else {
            throw Failure("IEND (empty) is not the last chunk")
        }
        let types = chunks.map(\.type)
        guard types.filter({ $0 == "IHDR" }).count == 1, types.filter({ $0 == "IEND" }).count == 1 else {
            throw Failure("IHDR and IEND must appear once")
        }
        for type in types where type.first!.isUppercase && !["IHDR", "IDAT", "IEND"].contains(type) {
            throw Failure("unexpected critical chunk \(type)")
        }
        let idatIndices = types.indices.filter { types[$0] == "IDAT" }
        guard let firstIDAT = idatIndices.first else { throw Failure("no IDAT chunk") }
        guard idatIndices == Array(firstIDAT..<(firstIDAT + idatIndices.count)) else {
            throw Failure("IDAT chunks are not consecutive")
        }

        let header = first.data
        guard header.count == 13 else { throw Failure("IHDR is \(header.count) bytes, not 13") }
        let width = Int(bigEndian32(header, 0))
        let height = Int(bigEndian32(header, 4))
        guard (1...0x7FFF_FFFF).contains(width), (1...0x7FFF_FFFF).contains(height) else {
            throw Failure("bad dimensions \(width)×\(height)")
        }
        guard header[8] == 8, header[9] == 6 else { throw Failure("not 8-bit RGBA (depth \(header[8]), type \(header[9]))") }
        guard header[10] == 0, header[11] == 0, header[12] == 0 else {
            throw Failure("unknown compression, filter method or interlace")
        }

        var pixelsPerMeter: Int?
        let physIndices = types.indices.filter { types[$0] == "pHYs" }
        if let index = physIndices.first {
            guard physIndices.count == 1, index < firstIDAT else { throw Failure("pHYs must appear once, before IDAT") }
            let phys = chunks[index].data
            guard phys.count == 9 else { throw Failure("pHYs is \(phys.count) bytes, not 9") }
            let x = Int(bigEndian32(phys, 0))
            let y = Int(bigEndian32(phys, 4))
            guard phys[8] == 1, x == y, x > 0 else { throw Failure("pHYs is not square pixels per metre") }
            pixelsPerMeter = x
        }

        let stream = idatIndices.flatMap { chunks[$0].data }
        let filtered = try inflateZlib(stream)
        let rgba = try unfilter(filtered, width: width, height: height)
        return Decoded(width: width, height: height, rgba: rgba, pixelsPerMeter: pixelsPerMeter)
    }

    /// The filter type byte of each row, read from the inflated IDAT data.
    static func filterTypes(_ png: [UInt8]) throws -> [UInt8] {
        let decoded = try decode(png)
        let stream = try chunks(png).filter { $0.type == "IDAT" }.flatMap(\.data)
        let filtered = try inflateZlib(stream)
        let rowLength = 1 + 4 * decoded.width
        return (0..<decoded.height).map { filtered[$0 * rowLength] }
    }

    // MARK: - zlib and inflate

    /// A zlib stream (RFC 1950) holding stored and fixed-Huffman deflate blocks, its Adler32 checked.
    static func inflateZlib(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 6 else { throw Failure("zlib stream too short") }
        let cmf = data[0]
        let flg = data[1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7 else { throw Failure("not deflate with a window of at most 32 KiB") }
        guard (Int(cmf) * 256 + Int(flg)) % 31 == 0 else { throw Failure("bad zlib header check bits") }
        guard flg & 0x20 == 0 else { throw Failure("preset dictionary") }

        var reader = BitReader(bytes: data, bitPosition: 16)
        var output: [UInt8] = []
        var isFinal = false
        while !isFinal {
            isFinal = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                reader.alignToByte()
                let length = try reader.bits(16)
                let complement = try reader.bits(16)
                guard length ^ 0xFFFF == complement else { throw Failure("stored block LEN/NLEN mismatch") }
                output += try reader.bytes(length)
            case 1:
                try inflateFixedHuffman(&reader, into: &output)
            case 2:
                throw Failure("dynamic Huffman block")
            default:
                throw Failure("reserved block type 3")
            }
        }
        reader.alignToByte()
        let trailer = reader.bitPosition / 8
        guard trailer + 4 == data.count else { throw Failure("zlib stream does not end with its Adler32") }
        guard bigEndian32(data, trailer) == referenceAdler32(output) else { throw Failure("Adler32 mismatch") }
        return output
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static func inflateFixedHuffman(_ reader: inout BitReader, into output: inout [UInt8]) throws {
        while true {
            let symbol = try literalLengthSymbol(&reader)
            if symbol < 256 {
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            guard symbol <= 285 else { throw Failure("invalid length symbol \(symbol)") }
            let lengthIndex = symbol - 257
            let length = lengthBase[lengthIndex] + (try reader.bits(lengthExtra[lengthIndex]))
            var distanceCode = 0
            for _ in 0..<5 { distanceCode = distanceCode << 1 | (try reader.bits(1)) }
            guard distanceCode < 30 else { throw Failure("invalid distance symbol \(distanceCode)") }
            let distance = distanceBase[distanceCode] + (try reader.bits(distanceExtra[distanceCode]))
            guard distance <= output.count else { throw Failure("distance \(distance) before the start") }
            let start = output.count - distance
            for offset in 0..<length { output.append(output[start + offset]) }
        }
    }

    /// One literal/length symbol of the fixed code, its bits read most significant first (RFC 1951 3.2.6):
    /// 7 bits 0000000-0010111 are 256-279; 8 bits 00110000-10111111 are 0-143 and 11000000-11000111 are 280-287;
    /// 9 bits 110010000-111111111 are 144-255.
    private static func literalLengthSymbol(_ reader: inout BitReader) throws -> Int {
        var code = 0
        for _ in 0..<7 { code = code << 1 | (try reader.bits(1)) }
        if code <= 0b001_0111 { return 256 + code }
        code = code << 1 | (try reader.bits(1))
        if (0x30...0xBF).contains(code) { return code - 0x30 }
        if (0xC0...0xC7).contains(code) { return 280 + code - 0xC0 }
        code = code << 1 | (try reader.bits(1))
        guard (0x190...0x1FF).contains(code) else { throw Failure("invalid 9-bit code \(code)") }
        return 144 + code - 0x190
    }

    private struct BitReader {
        let bytes: [UInt8]
        var bitPosition: Int

        /// `count` bits, least significant first (deflate's order for header fields and extra bits).
        mutating func bits(_ count: Int) throws -> Int {
            var value = 0
            for index in 0..<count {
                let byte = bitPosition >> 3
                guard byte < bytes.count else { throw Failure("deflate data runs past the end") }
                value |= Int((bytes[byte] >> UInt8(bitPosition & 7)) & 1) << index
                bitPosition += 1
            }
            return value
        }

        mutating func alignToByte() { bitPosition = (bitPosition + 7) & ~7 }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            let start = bitPosition >> 3
            guard bytes.count - start >= count else { throw Failure("stored block runs past the end") }
            bitPosition += 8 * count
            return Array(bytes[start..<(start + count)])
        }
    }

    // MARK: - Filters

    private static func unfilter(_ filtered: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let stride = 4 * width
        guard filtered.count == height * (stride + 1) else {
            throw Failure("inflated \(filtered.count) bytes, expected \(height * (stride + 1))")
        }
        var rgba = [UInt8](repeating: 0, count: height * stride)
        for y in 0..<height {
            let filter = filtered[y * (stride + 1)]
            guard filter <= 4 else { throw Failure("unknown filter type \(filter) on row \(y)") }
            for x in 0..<stride {
                let value = filtered[y * (stride + 1) + 1 + x]
                let a = x >= 4 ? rgba[y * stride + x - 4] : 0
                let b = y > 0 ? rgba[(y - 1) * stride + x] : 0
                let c = (x >= 4 && y > 0) ? rgba[(y - 1) * stride + x - 4] : 0
                let predictor: UInt8
                switch filter {
                case 0: predictor = 0
                case 1: predictor = a
                case 2: predictor = b
                case 3: predictor = UInt8((Int(a) + Int(b)) / 2)
                default: predictor = paeth(a, b, c)
                }
                rgba[y * stride + x] = value &+ predictor
            }
        }
        return rgba
    }

    static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a))
        let pb = abs(p - Int(b))
        let pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    // MARK: - Reference checksums

    /// Bitwise CRC-32 (reflected polynomial 0xEDB88320), independent of `CRC32`'s table.
    static func referenceCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// Adler-32 with the modulus taken at every byte, independent of `Adler32`'s deferred reduction.
    static func referenceAdler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }

    static func bigEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}
