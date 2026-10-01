import Foundation
import Testing
@testable import PixelCore

@Suite struct PixelImageTests {
    static let ink = Palette.color(.ink)
    static let paper = Palette.color(.paper)
    static let stone = Palette.color(.stone)
    static let leaf = Palette.color(.leaf)

    /// Deterministic test image whose every pixel is distinct.
    static func gradient(width: Int, height: Int) -> PixelImage {
        var image = PixelImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { image[x, y] = RGBA8(r: UInt8(x * 7 % 256), g: UInt8(y * 11 % 256), b: UInt8((x + y) % 256)) }
        }
        return image
    }

    @Test func initFillAndSubscript() {
        var image = PixelImage(width: 3, height: 2, fill: Self.paper)
        #expect(image.width == 3 && image.height == 2)
        #expect(image.pixels.count == 6)
        #expect(image.pixels.allSatisfy { $0 == Self.paper })
        image[2, 1] = Self.ink
        #expect(image[2, 1] == Self.ink)
        #expect(image.pixels[5] == Self.ink, "row-major, top row first")
        #expect(PixelImage(width: 2, height: 2).pixels.allSatisfy { $0 == .clear })
        let explicit = PixelImage(width: 2, height: 1, pixels: [Self.ink, Self.paper])
        #expect(explicit[0, 0] == Self.ink && explicit[1, 0] == Self.paper)
    }

    @Test func setAndFillAreClipped() {
        var image = PixelImage(width: 4, height: 4)
        image.set(-1, 0, Self.ink)
        image.set(4, 0, Self.ink)
        image.set(0, 4, Self.ink)
        #expect(image.pixels.allSatisfy { $0 == .clear })
        image.set(3, 3, Self.ink)
        #expect(image[3, 3] == Self.ink)
        image.fill(PixelRect(x: -2, y: 2, width: 4, height: 10), Self.paper)
        for y in 0..<4 {
            for x in 0..<4 {
                let inside = x < 2 && y >= 2
                #expect((image[x, y] == Self.paper) == inside, "(\(x), \(y))")
            }
        }
    }

    @Test func blitIsClippedAndSkipsClearPixels() {
        var src = PixelImage(width: 3, height: 3, fill: Self.ink)
        src[1, 1] = .clear
        var dst = PixelImage(width: 4, height: 4, fill: Self.paper)
        dst.blit(src, x: 2, y: -1)
        // Rows 0 and 1 of dst receive rows 1 and 2 of src, columns 2 and 3 receive columns 0 and 1.
        #expect(dst[2, 0] == Self.ink)
        #expect(dst[3, 0] == Self.paper, "src (1, 1) is clear: the destination shows through")
        #expect(dst[2, 1] == Self.ink && dst[3, 1] == Self.ink)
        #expect(dst[1, 0] == Self.paper && dst[2, 2] == Self.paper)
        var far = PixelImage(width: 2, height: 2, fill: Self.paper)
        far.blit(src, x: 5, y: 5)
        far.blit(src, x: -3, y: -3)
        #expect(far.pixels.allSatisfy { $0 == Self.paper })
    }

    @Test func compositeUsesIntegerFormula() {
        // ink #1C1B2E over floorLight #D7D0C0 at 77, by hand: (s * 77 + d * 178 + 127) / 255.
        // r: (28 * 77 + 215 * 178 + 127) / 255 = 40553 / 255 = 159
        // g: (27 * 77 + 208 * 178 + 127) / 255 = 39230 / 255 = 153
        // b: (46 * 77 + 192 * 178 + 127) / 255 = 37845 / 255 = 148
        var floor = PixelImage(width: 2, height: 1, fill: Palette.color(.floorLight))
        var layer = PixelImage(width: 2, height: 1)
        layer[0, 0] = Self.ink
        floor.composite(layer, alpha: Palette.shadowAlpha)
        #expect(floor[0, 0] == RGBA8(r: 159, g: 153, b: 148))
        #expect(floor[1, 0] == Palette.color(.floorLight), "clear layer pixels leave the destination alone")
    }

    @Test func compositeOverClearKeepsTheSourceColour() {
        var dst = PixelImage(width: 1, height: 1)
        dst.composite(PixelImage(width: 1, height: 1, fill: Self.ink), alpha: 77)
        #expect(dst[0, 0] == RGBA8(r: 0x1C, g: 0x1B, b: 0x2E, a: 77))
    }

    @Test func addIsCappedAt255() {
        // lampWarm (255, 190, 115) at 89 over (250, 100, 0): r 250 + 89 capped, g 100 + 66, b 0 + 40.
        var dst = PixelImage(width: 2, height: 1, fill: RGBA8(r: 250, g: 100, b: 0))
        dst[1, 0] = .clear
        let light = PixelImage(width: 2, height: 1, fill: Palette.color(.lampWarm))
        dst.add(light, alpha: Palette.lightPoolAlpha)
        #expect(dst[0, 0] == RGBA8(r: 255, g: 166, b: 40))
        #expect(dst[1, 0] == .clear, "light never shows on a clear pixel")
    }

    @Test func multiplyIsExact() {
        // nightVeil (58, 63, 110) at 140: f = 255 - ((255 - c) * 140 + 127) / 255 = (147, 150, 175);
        // over floorLight (215, 208, 192): (d * f + 127) / 255 = (124, 122, 132).
        var image = PixelImage(width: 2, height: 1, fill: Palette.color(.floorLight))
        image[1, 0] = .clear
        image.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
        #expect(image[0, 0] == RGBA8(r: 124, g: 122, b: 132))
        #expect(image[1, 0] == .clear)
        var white = PixelImage(width: 1, height: 1, fill: RGBA8(r: 255, g: 255, b: 255))
        white.multiply(by: Self.ink, alpha: 0)
        #expect(white[0, 0] == RGBA8(r: 255, g: 255, b: 255), "alpha 0 is the identity")
    }

    @Test func mirrorTwiceIsIdentity() {
        let image = Self.gradient(width: 5, height: 3)
        let mirrored = image.mirrored()
        #expect(mirrored.mirrored() == image)
        for y in 0..<3 { for x in 0..<5 { #expect(mirrored[x, y] == image[4 - x, y]) } }
    }

    @Test func scaledIsNearestNeighbour() {
        let image = Self.gradient(width: 4, height: 3)
        let big = image.scaled(by: 3)
        #expect(big.width == 12 && big.height == 9)
        for y in 0..<9 { for x in 0..<12 { #expect(big[x, y] == image[x / 3, y / 3]) } }
        #expect(image.scaled(by: 1) == image)
    }

    @Test func croppedPadsWithClear() {
        let image = Self.gradient(width: 4, height: 4)
        let crop = image.cropped(PixelRect(x: 2, y: -1, width: 4, height: 3))
        #expect(crop.width == 4 && crop.height == 3)
        #expect(crop[0, 1] == image[2, 0] && crop[1, 2] == image[3, 1])
        #expect(crop[0, 0] == .clear && crop[2, 1] == .clear)
    }

    @Test func recolored() {
        var image = PixelImage(width: 2, height: 1, fill: Self.ink)
        image[1, 0] = Self.paper
        let out = image.recolored([Self.ink: Self.stone])
        #expect(out[0, 0] == Self.stone && out[1, 0] == Self.paper)
    }

    @Test func nineSliceKeepsCornersAndRepeatsEdges() {
        // 5×5 source, insets 2: corners 2×2, edges and centre 1 px wide, each region its own colour.
        var src = PixelImage(width: 5, height: 5, fill: Self.leaf)        // centre
        let corner = [Self.ink, Self.paper, Self.stone, Palette.color(.slate)]
        let edge = Palette.color(.cork)
        for y in 0..<5 {
            for x in 0..<5 {
                let left = x < 2, right = x > 2, top = y < 2, bottom = y > 2
                if top && left { src[x, y] = corner[0] } else if top && right { src[x, y] = corner[1] }
                else if bottom && left { src[x, y] = corner[2] } else if bottom && right { src[x, y] = corner[3] }
                else if top || bottom || left || right { src[x, y] = edge }
            }
        }
        src[1, 1] = Palette.color(.chalk)     // a corner detail that must survive untouched
        let out = src.nineSlice(insets: EdgeInsets(2), width: 9, height: 7)
        #expect(out.width == 9 && out.height == 7)
        #expect(out.cropped(PixelRect(x: 0, y: 0, width: 2, height: 2)) == src.cropped(PixelRect(x: 0, y: 0, width: 2, height: 2)))
        #expect(out.cropped(PixelRect(x: 7, y: 5, width: 2, height: 2)) == src.cropped(PixelRect(x: 3, y: 3, width: 2, height: 2)))
        #expect(out[1, 1] == Palette.color(.chalk))
        for x in 2..<7 { #expect(out[x, 0] == edge && out[x, 6] == edge) }
        for y in 2..<5 { #expect(out[0, y] == edge && out[8, y] == edge) }
        for y in 2..<5 { for x in 2..<7 { #expect(out[x, y] == Self.leaf) } }
        #expect(src.nineSlice(insets: EdgeInsets(2), width: 5, height: 5) == src)
    }

    @Test func nineSliceTilesAPattern() {
        // Centre of two columns (ink, paper): repeated, never stretched.
        var src = PixelImage(width: 4, height: 1, fill: Self.stone)
        src[1, 0] = Self.ink
        src[2, 0] = Self.paper
        let out = src.nineSlice(insets: EdgeInsets(top: 0, left: 1, bottom: 0, right: 1), width: 7, height: 1)
        #expect(out.pixels == [Self.stone, Self.ink, Self.paper, Self.ink, Self.paper, Self.ink, Self.stone])
    }

    @Test func masksBoundsAndColours() {
        var image = PixelImage(width: 5, height: 4)
        #expect(image.opaqueBounds == nil)
        #expect(image.alphaMask().count == 0)
        image[1, 2] = Self.paper
        image[3, 1] = Self.ink
        image[3, 2] = Self.paper
        let mask = image.alphaMask()
        #expect(mask.width == 5 && mask.height == 4)
        #expect(mask.count == 3)
        #expect(mask[1, 2] && mask[3, 1] && !mask[0, 0])
        #expect(!mask[-1, 0] && !mask[5, 0] && !mask[0, 9], "false out of bounds")
        #expect(image.opaqueBounds == PixelRect(x: 1, y: 1, width: 3, height: 2))
        #expect(image.distinctColors == [Self.ink, Self.paper].sorted())
    }

    @Test func meanLuma() {
        var image = PixelImage(width: 4, height: 1)
        image[0, 0] = Self.stone
        image[1, 0] = Self.stone
        image[2, 0] = Self.ink
        #expect(image.meanLuma(in: PixelRect(x: 0, y: 0, width: 2, height: 1)) == Double(Self.stone.luma))
        #expect(image.meanLuma(in: PixelRect(x: 1, y: 0, width: 3, height: 1)) == Double(Self.stone.luma + Self.ink.luma) / 2)
        #expect(image.meanLuma(in: PixelRect(x: 3, y: 0, width: 5, height: 5)) == nil, "no opaque pixel")
    }

    @Test func rgbaBytesAreRowMajor() {
        var image = PixelImage(width: 2, height: 1)
        image[0, 0] = RGBA8(r: 1, g: 2, b: 3, a: 255)
        #expect(image.rgbaBytes == [1, 2, 3, 255, 0, 0, 0, 0])
    }

    @Test func fingerprintIsFNV1a() {
        // Reference values: FNV-1a 64 over width and height (UInt32 little endian) then the RGBA bytes.
        let one = PixelImage(width: 1, height: 1, fill: Self.ink)
        #expect(one.fingerprint == "2a4ae9dedbb9e95f")
        var two = PixelImage(width: 2, height: 1)
        two[0, 0] = Self.ink
        #expect(two.fingerprint == "508260cb28fc2b94")
        #expect(PixelImage(width: 0, height: 0).fingerprint == "a8c7f832281a39c5")
    }

    @Test func fingerprintIsStableAndDiscriminating() {
        let image = Self.gradient(width: 7, height: 5)
        #expect(image.fingerprint == Self.gradient(width: 7, height: 5).fingerprint)
        #expect(image.fingerprint.count == 16)
        #expect(image.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
        var changed = image
        changed[3, 2] = Self.ink
        #expect(changed.fingerprint != image.fingerprint)
        let wide = PixelImage(width: 2, height: 1, fill: Self.ink), tall = PixelImage(width: 1, height: 2, fill: Self.ink)
        #expect(wide.fingerprint != tall.fingerprint, "the shape is part of the fingerprint")
    }

    @Test func stackedHorizontally() {
        let a = PixelImage(width: 2, height: 3, fill: Self.ink), b = PixelImage(width: 3, height: 1, fill: Self.paper)
        let out = PixelImage.stacked([a, b], axis: .horizontal, spacing: 1, background: Self.stone)
        #expect(out.width == 6 && out.height == 3)
        #expect(out[0, 0] == Self.ink && out[1, 2] == Self.ink)
        #expect(out[2, 0] == Self.stone, "spacing")
        #expect(out[3, 0] == Self.paper && out[5, 0] == Self.paper)
        #expect(out[3, 1] == Self.stone, "aligned top")
    }

    @Test func stackedVertically() {
        let a = PixelImage(width: 2, height: 1, fill: Self.ink), b = PixelImage(width: 4, height: 2, fill: Self.paper)
        let out = PixelImage.stacked([a, b], axis: .vertical, spacing: 2)
        #expect(out.width == 4 && out.height == 5)
        #expect(out[0, 0] == Self.ink && out[2, 0] == .clear, "aligned left")
        #expect(out[0, 1] == .clear && out[0, 2] == .clear)
        #expect(out[3, 3] == Self.paper && out[0, 4] == Self.paper)
        #expect(PixelImage.stacked([], axis: .vertical, spacing: 3).width == 0)
    }

    @Test func bitMaskBasics() {
        var mask = BitMask(width: 3, height: 2)
        #expect(mask.count == 0)
        mask[2, 1] = true
        mask[0, 0] = true
        mask[5, 5] = true      // ignored out of bounds
        #expect(mask.count == 2)
        #expect(mask[2, 1] && !mask[1, 1])
        #expect(mask.bounds == PixelRect(x: 0, y: 0, width: 3, height: 2))
        var other = BitMask(width: 3, height: 2)
        other[1, 1] = true
        other[0, 0] = true
        #expect(mask.union(other).count == 3)
        #expect(mask.intersection(other).count == 1)
        #expect(mask.subtracting(other).count == 1)
        #expect(BitMask(width: 2, height: 1, bits: [true, false])[0, 0])
    }
}
