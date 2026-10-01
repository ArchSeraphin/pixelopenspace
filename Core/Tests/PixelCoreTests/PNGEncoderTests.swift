import Foundation
import Testing
@testable import PixelCore
#if canImport(ImageIO)
import ImageIO
#endif

@Suite struct PNGEncoderTests {
    @Test func chunksAndCRCs() throws {
        let image = TestImage.random(width: 37, height: 23, seed: 1)
        let cases: [(PNGOptions, [String])] = [
            (PNGOptions(), ["IHDR", "IDAT", "IEND"]),
            (PNGOptions(mode: .stored), ["IHDR", "IDAT", "IEND"]),
            (PNGOptions(pixelsPerMeter: PNGOptions.dpi144), ["IHDR", "pHYs", "IDAT", "IEND"]),
        ]
        for (options, expectedTypes) in cases {
            let png = image.encoded(options)
            #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
            // Walk the layout by hand: length, type, data, CRC32 over type and data.
            var position = 8
            var types: [String] = []
            var chunkData: [String: [UInt8]] = [:]
            while position + 12 <= png.count {
                let length = Int(PNGTestDecoder.bigEndian32(png, position))
                let typeBytes = Array(png[(position + 4)..<(position + 8)])
                let data = Array(png[(position + 8)..<(position + 8 + length)])
                let crc = PNGTestDecoder.bigEndian32(png, position + 8 + length)
                #expect(crc == CRC32.checksum(typeBytes + data))
                #expect(crc == PNGTestDecoder.referenceCRC32(typeBytes + data))
                let type = String(decoding: typeBytes, as: UTF8.self)
                types.append(type)
                chunkData[type] = data
                position += 12 + length
            }
            #expect(position == png.count)
            #expect(types == expectedTypes)
            // Width 37, height 23, bit depth 8, colour type 6 (RGBA), compression 0, filter 0, no interlace.
            #expect(chunkData["IHDR"] == [0, 0, 0, 37, 0, 0, 0, 23, 8, 6, 0, 0, 0])
            #expect(chunkData["IEND"] == [])
            _ = try PNGTestDecoder.chunks(png)
        }
    }

    @Test func roundTripRandomImage() throws {
        let images = [
            TestImage.random(width: 37, height: 23, seed: 2),
            TestImage.pattern(width: 300, height: 200),
            TestImage.random(width: 1, height: 1, seed: 3),
            TestImage.random(width: 1, height: 9, seed: 4),
            TestImage.random(width: 9, height: 1, seed: 5),
        ]
        for image in images {
            for mode in [DeflateMode.stored, .fixedHuffman] {
                let decoded = try PNGTestDecoder.decode(image.encoded(PNGOptions(mode: mode)))
                #expect(decoded == PNGTestDecoder.Decoded(width: image.width, height: image.height, rgba: image.rgba,
                                                          pixelsPerMeter: nil),
                        "\(image.width)×\(image.height) \(mode)")
            }
        }
    }

    /// Same input, same bytes, on every platform: the fingerprints are pinned so a Linux or macOS run that
    /// differs fails here (the CI runs both).
    @Test func deterministicBytes() {
        let image = TestImage.random(width: 37, height: 23, seed: 6)
        for mode in [DeflateMode.stored, .fixedHuffman] {
            #expect(image.encoded(PNGOptions(mode: mode)) == image.encoded(PNGOptions(mode: mode)))
        }
        let fixed = image.encoded(PNGOptions())
        let stored = image.encoded(PNGOptions(mode: .stored))
        let pattern = TestImage.pattern(width: 300, height: 200).encoded(PNGOptions(pixelsPerMeter: PNGOptions.dpi144))
        #expect([fixed.count, stored.count, pattern.count] == Pinned.counts)
        #expect([CRC32.checksum(fixed), CRC32.checksum(stored), CRC32.checksum(pattern)] == Pinned.checksums)
    }

    /// The fixed Huffman code spends at least 13 bits per 258 bytes (length symbol 285, distance 1), so the
    /// 1 049 088 filtered bytes of a 512×512 image cannot go below 6 610 bytes: the bound is 8 KiB, not 4 KiB.
    @Test func flatImageCompresses() throws {
        let image = TestImage.flat(width: 512, height: 512, color: [0x5A, 0x8C, 0x3E, 0xFF])
        let png = image.encoded(PNGOptions())
        #expect(png.count < 8_192)
        #expect(try PNGTestDecoder.decode(png).rgba == image.rgba)
    }

    @Test func physChunkWhenRequested() throws {
        let image = TestImage.pattern(width: 20, height: 10)
        let with = image.encoded(PNGOptions(pixelsPerMeter: PNGOptions.dpi144))
        let phys = try PNGTestDecoder.chunks(with).filter { $0.type == "pHYs" }
        // 5669 = 0x1625 pixels per metre on both axes, unit 1 (metre).
        #expect(phys.map(\.data) == [[0, 0, 0x16, 0x25, 0, 0, 0x16, 0x25, 1]])
        #expect(try PNGTestDecoder.decode(with).pixelsPerMeter == 5_669)
        #expect(PNGOptions.dpi144 == 5_669)

        let without = image.encoded(PNGOptions())
        #expect(try PNGTestDecoder.chunks(without).allSatisfy { $0.type != "pHYs" })
        #expect(try PNGTestDecoder.decode(without).pixelsPerMeter == nil)
    }

    /// Per row, the filter with the smallest sum of |signed bytes|, the lowest type on ties.
    @Test func filterChoiceFollowsHeuristic() throws {
        // A flat image: Sub on the first row (only the first pixel is left), Up after it (all zeros, before Paeth).
        let flat = TestImage.flat(width: 16, height: 6, color: [10, 200, 30, 255])
        #expect(try PNGTestDecoder.filterTypes(flat.encoded(PNGOptions())) == [1, 2, 2, 2, 2, 2])

        for image in [TestImage.random(width: 37, height: 23, seed: 7), TestImage.pattern(width: 300, height: 200)] {
            let chosen = try PNGTestDecoder.filterTypes(image.encoded(PNGOptions()))
            #expect(chosen == image.heuristicFilters())
            #expect(Set(chosen).count > 1, "the images should exercise several filters")
        }
    }

    #if canImport(ImageIO)
    /// Cross-check against the system decoder (and its zlib): alphas are 0 or 255 so premultiplication cannot
    /// change an opaque pixel, and a transparent one keeps alpha 0.
    @Test func imageIODecodesSamePixels() throws {
        let images = [TestImage.random(width: 37, height: 23, seed: 8, binaryAlpha: true),
                      TestImage.pattern(width: 300, height: 200)]
        for image in images {
            for mode in [DeflateMode.stored, .fixedHuffman] {
                let png = image.encoded(PNGOptions(mode: mode))
                let source = try #require(CGImageSourceCreateWithData(Data(png) as CFData, nil))
                let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(decoded.width == image.width && decoded.height == image.height)
                #expect(decoded.bitsPerComponent == 8 && decoded.bitsPerPixel == 32)
                let alphaLast: [CGImageAlphaInfo] = [.last, .premultipliedLast]
                #expect(alphaLast.contains(decoded.alphaInfo), "RGBA byte order expected, got \(decoded.alphaInfo)")
                let data = try #require(decoded.dataProvider?.data) as Data
                let bytes = [UInt8](data)
                var mismatches = 0
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let original = Array(image.rgba[(4 * (y * image.width + x))..<(4 * (y * image.width + x) + 4)])
                        let offset = y * decoded.bytesPerRow + 4 * x
                        let system = Array(bytes[offset..<(offset + 4)])
                        if original[3] == 255 ? system != original : system[3] != 0 { mismatches += 1 }
                    }
                }
                #expect(mismatches == 0, "\(image.width)×\(image.height) \(mode)")
            }
        }
    }
    #endif

    // MARK: - PreviewWriter

    @Test func previewDirectoryComesFromTheEnvironment() {
        #expect(PreviewWriter.directory(in: [:]) == nil)
        #expect(PreviewWriter.directory(in: ["PIXEL_PREVIEW_DIR": ""]) == nil)
        #expect(PreviewWriter.directory(in: ["PIXEL_PREVIEW_DIR": "/tmp/apercus"]) == "/tmp/apercus")
    }

    @Test func previewWriterUpscalesNearest() throws {
        let image = TestImage.random(width: 5, height: 3, seed: 9)
        let directory = NSTemporaryDirectory() + "pixel-preview-tests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        PreviewWriter.write("desk~hue3@ne#0", width: image.width, height: image.height, rgba: image.rgba, scale: 3,
                            to: directory)
        let file = URL(fileURLWithPath: directory).appendingPathComponent("desk~hue3@ne#0.png")
        let decoded = try PNGTestDecoder.decode([UInt8](try Data(contentsOf: file)))
        #expect(decoded.width == 15 && decoded.height == 9)
        for y in 0..<9 {
            for x in 0..<15 {
                let source = 4 * ((y / 3) * image.width + x / 3)
                let target = 4 * (y * 15 + x)
                #expect(decoded.rgba[target..<(target + 4)] == image.rgba[source..<(source + 4)])
            }
        }
        #expect(PreviewWriter.upscale(width: image.width, height: image.height, rgba: image.rgba, scale: 1) == image.rgba)
    }

    // MARK: - Pinned fingerprints

    /// Byte counts and CRC32 of `deterministicBytes`' three encodings (fixed, stored, pattern with pHYs), taken
    /// from bytes that the test decoder, the system zlib and ImageIO all read back. A change to the matcher or to
    /// the filter choice changes them on purpose: update them in the same commit.
    private enum Pinned {
        static let counts = [3_684, 3_495, 24_188]
        static let checksums: [UInt32] = [0x7589_4D11, 0x5F14_DCFC, 0x3258_08C9]
    }
}

/// A test image: RGBA bytes, rows top to bottom.
private struct TestImage {
    var width: Int
    var height: Int
    var rgba: [UInt8]

    func encoded(_ options: PNGOptions) -> [UInt8] {
        PNGEncoder.encode(width: width, height: height, rgba: rgba, options: options)
    }

    /// Seeded noise; with `binaryAlpha`, alpha is 0 or 255 only.
    static func random(width: Int, height: Int, seed: UInt64, binaryAlpha: Bool = false) -> TestImage {
        var rng = SplitMix64(seed: seed)
        var rgba: [UInt8] = []
        for _ in 0..<(width * height) {
            let word = rng.next()
            rgba += [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                     UInt8(truncatingIfNeeded: word >> 16)]
            let alpha = UInt8(truncatingIfNeeded: word >> 24)
            rgba.append(binaryAlpha ? (alpha < 64 ? 0 : 255) : alpha)
        }
        return TestImage(width: width, height: height, rgba: rgba)
    }

    /// Bands, gradients, a checkerboard and transparent holes (alpha 0 or 255): every filter has rows to win.
    static func pattern(width: Int, height: Int) -> TestImage {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(4 * width * height)
        for y in 0..<height {
            for x in 0..<width {
                switch (y / 25) % 4 {
                case 0: rgba += [UInt8(x & 0xFF), UInt8(y & 0xFF), 90, 255]
                case 1: rgba += [40, 120, UInt8((x * 3 + y) & 0xFF), 255]
                case 2: rgba += (x / 4 + y / 4) % 2 == 0 ? [0x2B, 0x3F, 0x78, 255] : [0xF4, 0xE9, 0xD8, 255]
                default: rgba += (x + 2 * y) % 7 == 0 ? [0, 0, 0, 0] : [UInt8((x * y) & 0xFF), 77, UInt8(x & 0xFF), 255]
                }
            }
        }
        return TestImage(width: width, height: height, rgba: rgba)
    }

    static func flat(width: Int, height: Int, color: [UInt8]) -> TestImage {
        TestImage(width: width, height: height, rgba: Array([[UInt8]](repeating: color, count: width * height).joined()))
    }

    /// Reference filter choice, written plainly: the five filtered rows, then the smallest |signed| sum.
    func heuristicFilters() -> [UInt8] {
        let stride = 4 * width
        return (0..<height).map { y in
            var sums = [Int](repeating: 0, count: 5)
            for x in 0..<stride {
                let value = rgba[y * stride + x]
                let a = x >= 4 ? rgba[y * stride + x - 4] : 0
                let b = y > 0 ? rgba[(y - 1) * stride + x] : 0
                let c = (x >= 4 && y > 0) ? rgba[(y - 1) * stride + x - 4] : 0
                let predictors: [UInt8] = [0, a, b, UInt8((Int(a) + Int(b)) / 2), PNGTestDecoder.paeth(a, b, c)]
                for filter in 0..<5 {
                    let signed = Int(Int8(bitPattern: value &- predictors[filter]))
                    sums[filter] += abs(signed)
                }
            }
            return UInt8(sums.firstIndex(of: sums.min()!)!)
        }
    }
}
