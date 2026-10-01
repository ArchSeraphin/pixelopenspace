import Foundation

/// One 8-bit RGBA pixel, non-premultiplied. Sprites only use alpha 0 or 255 (7.3).
public struct RGBA8: Hashable, Comparable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `hex` is 0xRRGGBB.
    public init(hex: UInt32, alpha: UInt8 = 255) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF), a: alpha)
    }

    /// (0, 0, 0, 0): the only transparent value a sprite or a scene ever writes.
    public static let clear = RGBA8(r: 0, g: 0, b: 0, a: 0)

    public var isOpaque: Bool { a == 255 }

    /// "#RRGGBB", upper case (alpha left out).
    public var hexString: String {
        let digits = Array("0123456789ABCDEF")
        var out = "#"
        for channel in [r, g, b] {
            out.append(digits[Int(channel >> 4)])
            out.append(digits[Int(channel & 0xF)])
        }
        return out
    }

    /// Integer Rec. 709 luma: 2126·r + 7152·g + 722·b. Every "lighter than" rule compares this value.
    public var luma: Int { 2126 * Int(r) + 7152 * Int(g) + 722 * Int(b) }

    /// By (r, g, b, a): only used to produce sorted, deterministic outputs.
    public static func < (lhs: RGBA8, rhs: RGBA8) -> Bool {
        (lhs.r, lhs.g, lhs.b, lhs.a) < (rhs.r, rhs.g, rhs.b, rhs.a)
    }
}

public struct PixelPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

public struct PixelRect: Hashable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && py >= y && px < x + width && py < y + height
    }
}

public struct EdgeInsets: Hashable, Sendable {
    public var top: Int, left: Int, bottom: Int, right: Int

    public init(_ all: Int) {
        self.init(top: all, left: all, bottom: all, right: all)
    }

    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// A width × height grid of booleans (alpha masks, face masks of `Draw.isoBox`).
public struct BitMask: Hashable, Sendable {
    public let width: Int, height: Int
    private var bits: [Bool]

    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "negative mask size")
        self.width = width
        self.height = height
        bits = Array(repeating: false, count: width * height)
    }

    /// `bits` is row-major, top row first; precondition: count == width·height.
    public init(width: Int, height: Int, bits: [Bool]) {
        precondition(width >= 0 && height >= 0 && bits.count == width * height, "mask size mismatch")
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// False out of bounds; writes out of bounds are ignored.
    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return bits[y * width + x]
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            bits[y * width + x] = newValue
        }
    }

    public var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Bounding rect of the set bits; nil when none is set.
    public var bounds: PixelRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bits[y * width + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Same size required for the set operations below.
    public func union(_ other: BitMask) -> BitMask { combined(other) { $0 || $1 } }
    public func intersection(_ other: BitMask) -> BitMask { combined(other) { $0 && $1 } }
    public func subtracting(_ other: BitMask) -> BitMask { combined(other) { $0 && !$1 } }

    private func combined(_ other: BitMask, _ op: (Bool, Bool) -> Bool) -> BitMask {
        precondition(width == other.width && height == other.height, "mask sizes differ")
        return BitMask(width: width, height: height, bits: zip(bits, other.bits).map(op))
    }
}

public enum StackAxis: Sendable { case horizontal, vertical }

/// An RGBA image in memory, pure Swift and deterministic: the output of every sprite generator and of the
/// scene compositor. Blends use integer arithmetic only, so Linux and macOS produce the same bytes.
public struct PixelImage: Hashable, Sendable {
    public let width: Int, height: Int
    /// Row-major, top row first.
    public private(set) var pixels: [RGBA8]

    public init(width: Int, height: Int, fill: RGBA8 = .clear) {
        precondition(width >= 0 && height >= 0, "negative image size")
        self.width = width
        self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    /// Precondition: pixels.count == width·height.
    public init(width: Int, height: Int, pixels: [RGBA8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Precondition: in bounds.
    public subscript(x: Int, y: Int) -> RGBA8 {
        get {
            precondition(x >= 0 && y >= 0 && x < width && y < height, "pixel (\(x), \(y)) outside \(width)×\(height)")
            return pixels[y * width + x]
        }
        set {
            precondition(x >= 0 && y >= 0 && x < width && y < height, "pixel (\(x), \(y)) outside \(width)×\(height)")
            pixels[y * width + x] = newValue
        }
    }

    /// Ignored out of bounds (clipping).
    public mutating func set(_ x: Int, _ y: Int, _ color: RGBA8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color
    }

    /// Clipped to the image.
    public mutating func fill(_ rect: PixelRect, _ color: RGBA8) {
        let x0 = max(rect.x, 0), y0 = max(rect.y, 0)
        let x1 = min(rect.x + rect.width, width), y1 = min(rect.y + rect.height, height)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 { pixels[row + x] = color }
        }
    }

    /// Copies the pixels of `src` that are not fully transparent (sprites: the opaque ones), its top-left at
    /// (x, y); clipped.
    public mutating func blit(_ src: PixelImage, x: Int, y: Int) {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(x + src.width, width), y1 = min(y + src.height, height)
        guard x0 < x1, y0 < y1 else { return }
        for dy in y0..<y1 {
            let srcRow = (dy - y) * src.width - x, dstRow = dy * width
            for dx in x0..<x1 {
                let p = src.pixels[srcRow + dx]
                if p.a != 0 { pixels[dstRow + dx] = p }
            }
        }
    }

    /// Same size. Each non-transparent pixel s of `layer` over d: (s·α + d·(255 − α) + 127) / 255 per channel,
    /// alpha included (an opaque destination stays opaque). Over a fully transparent destination, the result
    /// is s with alpha α. Shadows use it once, over the whole shadow layer (7.3, rule 4).
    public mutating func composite(_ layer: PixelImage, alpha: UInt8) {
        precondition(layer.width == width && layer.height == height, "layer size differs")
        let a = Int(alpha), inv = 255 - Int(alpha)
        @inline(__always) func blend(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
            UInt8((Int(sc) * a + Int(dc) * inv + 127) / 255)
        }
        for index in pixels.indices {
            let s = layer.pixels[index]
            guard s.a != 0 else { continue }
            let d = pixels[index]
            if d.a == 0 {
                pixels[index] = RGBA8(r: s.r, g: s.g, b: s.b, a: alpha)
                continue
            }
            pixels[index] = RGBA8(r: blend(s.r, d.r), g: blend(s.g, d.g), b: blend(s.b, d.b), a: blend(255, d.a))
        }
    }

    /// Same size, additive. Each non-transparent pixel s of `layer`: min(255, d + (s·α + 127) / 255) per colour
    /// channel; alpha unchanged, and fully transparent destination pixels stay untouched (night lights, 7.8).
    public mutating func add(_ layer: PixelImage, alpha: UInt8) {
        precondition(layer.width == width && layer.height == height, "layer size differs")
        let a = Int(alpha)
        @inline(__always) func lit(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
            UInt8(min(255, Int(dc) + (Int(sc) * a + 127) / 255))
        }
        for index in pixels.indices {
            let s = layer.pixels[index]
            let d = pixels[index]
            guard s.a != 0, d.a != 0 else { continue }
            pixels[index] = RGBA8(r: lit(s.r, d.r), g: lit(s.g, d.g), b: lit(s.b, d.b), a: d.a)
        }
    }

    /// Each non-transparent pixel: f = 255 − ((255 − c)·α + 127) / 255, then (d·f + 127) / 255 per colour
    /// channel; alpha unchanged (night veil, 7.8).
    public mutating func multiply(by color: RGBA8, alpha: UInt8) {
        let a = Int(alpha)
        @inline(__always) func factor(_ c: UInt8) -> Int { 255 - ((255 - Int(c)) * a + 127) / 255 }
        let fr = factor(color.r), fg = factor(color.g), fb = factor(color.b)
        for index in pixels.indices {
            let d = pixels[index]
            guard d.a != 0 else { continue }
            pixels[index] = RGBA8(r: UInt8((Int(d.r) * fr + 127) / 255), g: UInt8((Int(d.g) * fg + 127) / 255),
                                  b: UInt8((Int(d.b) * fb + 127) / 255), a: d.a)
        }
    }

    /// Horizontal flip.
    public func mirrored() -> PixelImage {
        var out = self
        for y in 0..<height {
            let row = y * width
            for x in 0..<width { out.pixels[row + x] = pixels[row + width - 1 - x] }
        }
        return out
    }

    /// Nearest neighbour, factor ≥ 1: every pixel becomes a factor × factor block.
    public func scaled(by factor: Int) -> PixelImage {
        precondition(factor >= 1, "scale factor must be at least 1")
        guard factor > 1 else { return self }
        let outWidth = width * factor
        var out = [RGBA8]()
        out.reserveCapacity(outWidth * height * factor)
        var row = [RGBA8](repeating: .clear, count: outWidth)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixels[y * width + x]
                for k in 0..<factor { row[x * factor + k] = p }
            }
            for _ in 0..<factor { out.append(contentsOf: row) }
        }
        return PixelImage(width: outWidth, height: height * factor, pixels: out)
    }

    /// `rect` may extend past the source: pixels outside it are clear.
    public func cropped(_ rect: PixelRect) -> PixelImage {
        var out = PixelImage(width: max(rect.width, 0), height: max(rect.height, 0))
        out.blitRaw(self, x: -rect.x, y: -rect.y)
        return out
    }

    /// Copies every source pixel, transparent ones included; clipped.
    private mutating func blitRaw(_ src: PixelImage, x: Int, y: Int) {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(x + src.width, width), y1 = min(y + src.height, height)
        guard x0 < x1, y0 < y1 else { return }
        for dy in y0..<y1 {
            let srcRow = (dy - y) * src.width - x, dstRow = dy * width
            for dx in x0..<x1 { pixels[dstRow + dx] = src.pixels[srcRow + dx] }
        }
    }

    /// Exact colour replacement; colours missing from `map` are kept.
    public func recolored(_ map: [RGBA8: RGBA8]) -> PixelImage {
        PixelImage(width: width, height: height, pixels: pixels.map { map[$0] ?? $0 })
    }

    /// Corners kept, edges and centre repeated (never stretched) to width × height. Preconditions: the target
    /// holds the corners; a source centre of at least 1 px wherever the target needs one.
    public func nineSlice(insets: EdgeInsets, width outWidth: Int, height outHeight: Int) -> PixelImage {
        let centreW = width - insets.left - insets.right, centreH = height - insets.top - insets.bottom
        precondition(centreW >= 0 && centreH >= 0, "insets larger than the source")
        precondition(outWidth >= insets.left + insets.right && outHeight >= insets.top + insets.bottom,
                     "target smaller than its corners")
        precondition(centreW > 0 || outWidth == insets.left + insets.right, "no source centre to repeat across")
        precondition(centreH > 0 || outHeight == insets.top + insets.bottom, "no source centre to repeat down")
        @inline(__always) func source(_ t: Int, outSize: Int, near: Int, far: Int, centre: Int, size: Int) -> Int {
            if t < near { return t }
            if t >= outSize - far { return size - (outSize - t) }
            return near + (t - near) % centre
        }
        var out = PixelImage(width: outWidth, height: outHeight)
        for y in 0..<outHeight {
            let sy = source(y, outSize: outHeight, near: insets.top, far: insets.bottom, centre: centreH, size: height)
            for x in 0..<outWidth {
                let sx = source(x, outSize: outWidth, near: insets.left, far: insets.right, centre: centreW, size: width)
                out.pixels[y * outWidth + x] = pixels[sy * width + sx]
            }
        }
        return out
    }

    /// Pixels whose alpha is not 0.
    public func alphaMask() -> BitMask {
        BitMask(width: width, height: height, bits: pixels.map { $0.a != 0 })
    }

    /// Bounds of the pixels whose alpha is not 0; nil when the image is fully transparent.
    public var opaqueBounds: PixelRect? { alphaMask().bounds }

    /// Opaque colours (alpha 255), sorted.
    public var distinctColors: [RGBA8] { Set(pixels.filter(\.isOpaque)).sorted() }

    /// 4·width·height bytes, R G B A per pixel, rows top to bottom (PNGEncoder input).
    public var rgbaBytes: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(pixels.count * 4)
        for p in pixels { bytes.append(contentsOf: [p.r, p.g, p.b, p.a]) }
        return bytes
    }

    /// FNV-1a 64 of width and height (each a UInt32, little endian) then rgbaBytes: 16 lowercase hex digits
    /// (golden files).
    public var fingerprint: String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        @inline(__always) func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        for value in [UInt32(truncatingIfNeeded: width), UInt32(truncatingIfNeeded: height)] {
            for shift in stride(from: 0, to: 32, by: 8) { mix(UInt8((value >> UInt32(shift)) & 0xFF)) }
        }
        for p in pixels {
            mix(p.r)
            mix(p.g)
            mix(p.b)
            mix(p.a)
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Mean luma of the opaque pixels inside `rect` (clipped); nil when there is none.
    public func meanLuma(in rect: PixelRect) -> Double? {
        var sum = 0, count = 0
        let x0 = max(rect.x, 0), y0 = max(rect.y, 0)
        let x1 = min(rect.x + rect.width, width), y1 = min(rect.y + rect.height, height)
        if x0 < x1, y0 < y1 {
            for y in y0..<y1 {
                for x in x0..<x1 where pixels[y * width + x].isOpaque {
                    sum += pixels[y * width + x].luma
                    count += 1
                }
            }
        }
        return count == 0 ? nil : Double(sum) / Double(count)
    }

    /// Mean luma of the opaque pixels under `mask` (top-left aligned); nil when there is none.
    public func meanLuma(in mask: BitMask) -> Double? {
        var sum = 0, count = 0
        for y in 0..<min(height, mask.height) {
            for x in 0..<min(width, mask.width) where mask[x, y] && pixels[y * width + x].isOpaque {
                sum += pixels[y * width + x].luma
                count += 1
            }
        }
        return count == 0 ? nil : Double(sum) / Double(count)
    }

    /// Images side by side (horizontal, aligned top) or one under the other (vertical, aligned left), `spacing`
    /// px apart, on `background`. An empty list gives a 0×0 image.
    public static func stacked(_ images: [PixelImage], axis: StackAxis, spacing: Int,
                               background: RGBA8 = .clear) -> PixelImage {
        guard !images.isEmpty else { return PixelImage(width: 0, height: 0) }
        let gaps = spacing * (images.count - 1)
        let width: Int, height: Int
        switch axis {
        case .horizontal:
            width = images.reduce(0) { $0 + $1.width } + gaps
            height = images.map(\.height).max() ?? 0
        case .vertical:
            width = images.map(\.width).max() ?? 0
            height = images.reduce(0) { $0 + $1.height } + gaps
        }
        var out = PixelImage(width: width, height: height, fill: background)
        var offset = 0
        for image in images {
            switch axis {
            case .horizontal:
                out.blit(image, x: offset, y: 0)
                offset += image.width + spacing
            case .vertical:
                out.blit(image, x: 0, y: offset)
                offset += image.height + spacing
            }
        }
        return out
    }
}
