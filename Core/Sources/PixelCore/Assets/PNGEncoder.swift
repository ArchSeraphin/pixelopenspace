import Foundation

public struct PNGOptions: Hashable, Sendable {
    public var mode: DeflateMode = .fixedHuffman
    /// pHYs chunk when set: square pixels, this many per metre (144 ppp = 5669).
    public var pixelsPerMeter: Int? = nil

    public init(mode: DeflateMode = .fixedHuffman, pixelsPerMeter: Int? = nil) {
        self.mode = mode
        self.pixelsPerMeter = pixelsPerMeter
    }

    /// 144 pixels per inch (a Retina image at 0.5 pt per pixel) in pixels per metre: 144 / 0.0254, rounded down.
    public static let dpi144: Int = 5669
}

/// PNG writer in pure Swift (Linux and macOS), for generated sprites and scenes.
public enum PNGEncoder {
    /// RGBA 8-bit, non-premultiplied, rows top to bottom (4·width·height bytes), colour type 6, no interlace.
    /// Per row, the filter (0 to 4) with the smallest sum of |signed bytes|, lowest type on ties.
    /// Chunks: IHDR, pHYs (optional), one IDAT, IEND. Same input, same bytes.
    public static func encode(width: Int, height: Int, rgba: [UInt8], options: PNGOptions = .init()) -> [UInt8] {
        precondition((1...maxDimension).contains(width) && (1...maxDimension).contains(height),
                     "PNG dimensions must be 1 to 2^31 - 1")
        precondition(rgba.count == 4 * width * height, "rgba must hold 4·width·height bytes")
        var png = signature
        appendChunk("IHDR", bigEndian(width) + bigEndian(height) + [8, 6, 0, 0, 0], to: &png)
        if let pixelsPerMeter = options.pixelsPerMeter {
            precondition((1...maxDimension).contains(pixelsPerMeter), "pixels per metre must be 1 to 2^31 - 1")
            // Unit 1: the metre.
            appendChunk("pHYs", bigEndian(pixelsPerMeter) + bigEndian(pixelsPerMeter) + [1], to: &png)
        }
        let filtered = filterRows(width: width, height: height, rgba: rgba)
        appendChunk("IDAT", Deflate.zlib(filtered, mode: options.mode), to: &png)
        appendChunk("IEND", [], to: &png)
        return png
    }

    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    /// PNG's four-byte integers stop at 2^31 - 1.
    private static let maxDimension = 0x7FFF_FFFF

    /// Length, type, data, then the CRC32 of type and data.
    private static func appendChunk(_ type: String, _ data: [UInt8], to png: inout [UInt8]) {
        let typeBytes = Array(type.utf8)
        png += bigEndian(data.count)
        png += typeBytes
        png += data
        png += bigEndian(Int(CRC32.checksum(data, initial: CRC32.checksum(typeBytes))))
    }

    private static func bigEndian(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// Each row prefixed with its filter type. a, b and c are the left, upper and upper-left bytes of the same
    /// channel (0 outside the image); a filtered byte is the original minus the filter's predictor, modulo 256.
    ///
    /// The loops avoid calls (helpers, generic `abs`, buffer subscripts) on purpose: tests run unoptimized,
    /// where each call per byte costs more than the arithmetic itself.
    static func filterRows(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        let stride = 4 * width
        var output = [UInt8](repeating: 0, count: height * (stride + 1))
        let zeros = [UInt8](repeating: 0, count: stride)
        rgba.withUnsafeBufferPointer { pixelBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                zeros.withUnsafeBufferPointer { zeroBuffer in
                    guard let pixels = pixelBuffer.baseAddress, let output = outputBuffer.baseAddress,
                          let zeroRow = zeroBuffer.baseAddress else { return }
                    for y in 0..<height {
                        let row = pixels + y * stride
                        // The row above the first one is all zeros: Up is None and Paeth is Sub there.
                        let above = y > 0 ? row - stride : zeroRow
                        let filter = cheapestFilter(row: row, above: above, count: stride)
                        let target = output + y * (stride + 1)
                        target[0] = UInt8(filter)
                        apply(filter: filter, row: row, above: above, count: stride, to: target + 1)
                    }
                }
            }
        }
        return output
    }

    /// The filter with the smallest sum of |filtered byte| (bytes read as signed), the lowest type on ties.
    private static func cheapestFilter(row: UnsafePointer<UInt8>, above: UnsafePointer<UInt8>, count: Int) -> Int {
        var none = 0
        var sub = 0
        var up = 0
        var average = 0
        var paeth = 0
        var x = 0
        while x < count {
            let value = Int(row[x])
            let b = Int(above[x])
            let a = x >= 4 ? Int(row[x - 4]) : 0
            let c = x >= 4 ? Int(above[x - 4]) : 0
            // |signed byte| of (value - predictor) mod 256: d if d < 128, else 256 - d.
            none += value < 128 ? value : 256 - value
            var d = (value - a) & 0xFF
            sub += d < 128 ? d : 256 - d
            d = (value - b) & 0xFF
            up += d < 128 ? d : 256 - d
            d = (value - ((a + b) >> 1)) & 0xFF
            average += d < 128 ? d : 256 - d
            let estimate = a + b - c
            let toA = estimate > a ? estimate - a : a - estimate
            let toB = estimate > b ? estimate - b : b - estimate
            let toC = estimate > c ? estimate - c : c - estimate
            let predictor = toA <= toB && toA <= toC ? a : (toB <= toC ? b : c)
            d = (value - predictor) & 0xFF
            paeth += d < 128 ? d : 256 - d
            x += 1
        }
        var best = 0
        var bestSum = none
        if sub < bestSum { best = 1; bestSum = sub }
        if up < bestSum { best = 2; bestSum = up }
        if average < bestSum { best = 3; bestSum = average }
        if paeth < bestSum { best = 4 }
        return best
    }

    /// Writes one row filtered with `filter` (0 None, 1 Sub, 2 Up, 3 Average, 4 Paeth).
    private static func apply(filter: Int, row: UnsafePointer<UInt8>, above: UnsafePointer<UInt8>, count: Int,
                              to target: UnsafeMutablePointer<UInt8>) {
        var x = 0
        switch filter {
        case 0:
            target.update(from: row, count: count)
        case 1:
            while x < count {
                target[x] = x >= 4 ? row[x] &- row[x - 4] : row[x]
                x += 1
            }
        case 2:
            while x < count {
                target[x] = row[x] &- above[x]
                x += 1
            }
        case 3:
            while x < count {
                let a = x >= 4 ? Int(row[x - 4]) : 0
                target[x] = row[x] &- UInt8((a + Int(above[x])) >> 1)
                x += 1
            }
        default:
            while x < count {
                let b = Int(above[x])
                let a = x >= 4 ? Int(row[x - 4]) : 0
                let c = x >= 4 ? Int(above[x - 4]) : 0
                // The neighbour closest to a + b - c: left, then up, then upper-left on ties.
                let estimate = a + b - c
                let toA = estimate > a ? estimate - a : a - estimate
                let toB = estimate > b ? estimate - b : b - estimate
                let toC = estimate > c ? estimate - c : c - estimate
                let predictor = toA <= toB && toA <= toC ? a : (toB <= toC ? b : c)
                target[x] = row[x] &- UInt8(predictor)
                x += 1
            }
        }
    }
}
