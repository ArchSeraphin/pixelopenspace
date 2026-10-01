import Foundation
import Testing
@testable import PixelCore

@Suite struct DrawTests {
    static let ramps: [(String, Ramp)] = [("neutral", .neutral), ("wall", .wall), ("woodLight", .woodLight),
                                          ("woodDark", .woodDark)] + (0..<10).map { ("hue\($0)", Ramp.hue($0)) }
    /// (w, d, height) of the boxes every geometric test runs on.
    static let boxes: [(Int, Int, Int)] = [(16, 16, 0), (16, 16, 8), (8, 4, 12), (3, 5, 2), (1, 1, 3), (12, 6, 24), (2, 9, 5)]

    /// Opaque columns of row y.
    static func row(_ image: PixelImage, _ y: Int) -> [Int] { (0..<image.width).filter { image[$0, y].a != 0 } }

    @Test func diamondRowsAre4yPlus4() {
        let fill = Palette.color(.floorLight)
        for width in [64, 32, 16, 4] {
            let tile = Draw.isoDiamond(width: width, fill: fill)
            #expect(tile.width == width && tile.height == width / 2)
            let half = width / 4
            for y in 0..<tile.height {
                let expected = y < half ? 4 * y + 4 : 4 * (tile.height - 1 - y) + 4
                let columns = Self.row(tile, y)
                #expect(columns.count == expected, "width \(width) row \(y)")
                #expect(columns.first == width / 2 - expected / 2 && columns.last == width / 2 + expected / 2 - 1,
                        "centred and contiguous")
                #expect(columns.allSatisfy { tile[$0, y] == fill })
            }
        }
        #expect(Draw.isoDiamond(width: 64, fill: fill).alphaMask() == Draw.isoDiamondMask(width: 64))
    }

    @Test func boxTopIsTheTileDiamond() {
        let flat = Draw.isoBox(w: 16, d: 16, height: 0, ramp: .neutral)
        #expect(flat.top == Draw.isoDiamondMask(width: 64))
        #expect(flat.image.alphaMask() == Draw.isoDiamondMask(width: 64))
        #expect(flat.left.count == 0 && flat.right.count == 0)
    }

    @Test func boxSizeFormula() {
        for (w, d, h) in Self.boxes {
            let box = Draw.isoBox(w: w, d: d, height: h, ramp: .neutral)
            #expect(box.image.width == 2 * (w + d) && box.image.height == w + d + h, "\(w) \(d) \(h)")
            for mask in [box.top, box.left, box.right] {
                #expect(mask.width == box.image.width && mask.height == box.image.height)
            }
        }
    }

    @Test func boxMasksPartitionTheSilhouette() {
        for (w, d, h) in Self.boxes {
            let box = Draw.isoBox(w: w, d: d, height: h, ramp: .wall)
            #expect(box.top.intersection(box.left).count == 0)
            #expect(box.top.intersection(box.right).count == 0)
            #expect(box.left.intersection(box.right).count == 0)
            #expect(box.top.union(box.left).union(box.right) == box.image.alphaMask(), "\(w) \(d) \(h)")
            #expect(box.top.count == Self.topArea(w: w, d: d))
            #expect(box.left.count == 2 * w * h && box.right.count == 2 * d * h, "each face column is height px tall")
        }
    }

    /// Pixel area of a w × d top face: rows of the 2:1 rhombus.
    static func topArea(w: Int, d: Int) -> Int {
        var area = 0
        for y in 0..<(w + d) {
            let left = y < d ? 2 * d - 2 - 2 * y : 2 * (y - d)
            let right = y < w ? 2 * d + 1 + 2 * y : 2 * (w + d) - 1 - 2 * (y - w)
            area += right - left + 1
        }
        return area
    }

    @Test func boxEdgesStepTwoPixels() {
        // Along every edge of the silhouette, the boundary row changes by 1 every 2 columns: runs of 2 px,
        // except the 4-px run at the top vertex (top boundary) and at the bottom vertex (bottom boundary).
        for (w, d, h) in Self.boxes {
            let mask = Draw.isoBox(w: w, d: d, height: h, ramp: .neutral).image.alphaMask()
            let columns = 0..<mask.width
            let tops = columns.map { x in (0..<mask.height).first { mask[x, $0] }! }
            let bottoms = columns.map { x in (0..<mask.height).last { mask[x, $0] }! }
            for boundary in [tops, bottoms] {
                var runs: [Int] = []
                var start = 0
                for x in 1...boundary.count where x == boundary.count || boundary[x] != boundary[start] {
                    runs.append(x - start)
                    if x < boundary.count { #expect(abs(boundary[x] - boundary[start]) == 1, "steps of 1 row") }
                    start = x
                }
                #expect(runs.filter { $0 == 4 }.count == 1, "\(w) \(d) \(h): one vertex run of 4 px")
                #expect(runs.allSatisfy { $0 == 2 || $0 == 4 }, "\(w) \(d) \(h): \(runs)")
            }
        }
    }

    @Test func boxLeftFaceLighterThanRight() {
        for (name, ramp) in Self.ramps {
            #expect(ramp.left.luma > ramp.right.luma, "\(name)")
            for (w, d, h) in Self.boxes where h >= 2 {
                let box = Draw.isoBox(w: w, d: d, height: h, ramp: ramp)
                let left = box.image.meanLuma(in: box.lightProbe.left)
                let right = box.image.meanLuma(in: box.lightProbe.right)
                #expect(left != nil && right != nil, "\(name) \(w) \(d) \(h): probe samples pixels")
                #expect((left ?? 0) > (right ?? .infinity), "\(name) \(w) \(d) \(h)")
                // Whole faces, outline included, lead to the same verdict.
                #expect(box.image.meanLuma(in: box.left)! > box.image.meanLuma(in: box.right)!, "\(name) \(w) \(d) \(h)")
            }
        }
    }

    @Test func probesSampleTheFaceTones() {
        for (name, ramp) in Self.ramps {
            for (w, d, h) in Self.boxes where h >= 2 {
                let box = Draw.isoBox(w: w, d: d, height: h, ramp: ramp)
                for (rect, mask, tone) in [(box.lightProbe.left, box.left, ramp.left), (box.lightProbe.right, box.right, ramp.right)] {
                    #expect(rect.width > 0 && rect.height > 0, "\(name) \(w) \(d) \(h)")
                    for y in rect.y..<(rect.y + rect.height) {
                        for x in rect.x..<(rect.x + rect.width) {
                            #expect(mask[x, y] && box.image[x, y] == tone, "\(name) \(w) \(d) \(h) at (\(x), \(y))")
                        }
                    }
                }
            }
        }
    }

    @Test func boxIsLitOutlinedAndHighlighted() {
        let ramp = Ramp.woodLight
        let box = Draw.isoBox(w: 8, d: 6, height: 10, ramp: ramp)
        let image = box.image
        // Outer ring in the outline tone.
        #expect(Draw.outline(image, color: ramp.outline) == image)
        // Top centre: the top tone; just above the front edges of the top: the highlight.
        #expect(image[2 * 6, 6] == ramp.top)
        for x in 2..<(image.width - 2) {
            let frontEdge = (0..<image.height).last { box.top[x, $0] }!
            #expect(image[x, frontEdge] == ramp.highlight, "column \(x)")
            #expect(!box.top[x, frontEdge + 1])
        }
        let colours = Set(image.distinctColors)
        #expect(colours == [ramp.top, ramp.left, ramp.right, ramp.outline, ramp.highlight])
    }

    @Test func line2to1StepsAreTwoPixels() {
        let color = Palette.color(.ink)
        for (rightward, downward) in [(true, true), (true, false), (false, true), (false, false)] {
            var image = PixelImage(width: 24, height: 12)
            Draw.line2to1(into: &image, from: PixelPoint(rightward ? 2 : 21, downward ? 1 : 10), steps: 8,
                          rightward: rightward, downward: downward, color: color)
            let rows = (0..<12).map { Self.row(image, $0) }.filter { !$0.isEmpty }
            #expect(rows.count == 8)
            #expect(rows.allSatisfy { $0.count == 2 && $0[1] == $0[0] + 1 }, "every step is exactly 2 px")
            let starts = (0..<12).compactMap { Self.row(image, $0).first }
            for k in 1..<starts.count {
                #expect(abs(starts[k] - starts[k - 1]) == 2, "consecutive steps are 2 px apart")
            }
            // Direction: the pixel at the start point is drawn, and the line moves as asked.
            let first = PixelPoint(rightward ? 2 : 21, downward ? 1 : 10)
            #expect(image[first.x, first.y] == color)
            #expect(image[first.x + (rightward ? 2 : -2), first.y + (downward ? 1 : -1)] == color)
        }
        var clipped = PixelImage(width: 4, height: 4)
        Draw.line2to1(into: &clipped, from: PixelPoint(0, 0), steps: 10, rightward: true, downward: true, color: color)
        #expect(clipped.alphaMask().count == 4, "clipped at the borders")
    }

    @Test func dither50IsACheckerboard() {
        let color = Palette.color(.mist)
        var mask = BitMask(width: 6, height: 4)
        for y in 0..<4 { for x in 0..<5 { mask[x, y] = true } }
        for phase in [0, 1] {
            var image = PixelImage(width: 6, height: 4, fill: Palette.color(.paper))
            Draw.dither50(into: &image, mask: mask, color: color, phase: phase)
            for y in 0..<4 {
                for x in 0..<6 {
                    let dithered = x < 5 && (x + y) % 2 == phase
                    #expect((image[x, y] == color) == dithered, "phase \(phase) (\(x), \(y))")
                }
            }
        }
    }

    @Test func outlineRecolorsTheOuterRing() {
        var image = PixelImage(width: 7, height: 7)
        image.fill(PixelRect(x: 1, y: 1, width: 5, height: 5), Palette.color(.paper))
        let out = Draw.outline(image, color: Palette.color(.ink))
        for y in 0..<7 {
            for x in 0..<7 {
                let inside = (1...5).contains(x) && (1...5).contains(y)
                let ring = inside && (x == 1 || x == 5 || y == 1 || y == 5)
                let expected: RGBA8 = ring ? Palette.color(.ink) : (inside ? Palette.color(.paper) : .clear)
                #expect(out[x, y] == expected, "(\(x), \(y))")
            }
        }
        // A pixel on the image border is on the ring.
        let full = Draw.outline(PixelImage(width: 3, height: 3, fill: Palette.color(.paper)), color: Palette.color(.ink))
        #expect(full[1, 1] == Palette.color(.paper) && full[0, 1] == Palette.color(.ink))
    }

    @Test func ellipseIsSymmetricOnBothAxes() {
        let fill = Palette.color(.ink)
        for (w, h) in [(20, 8), (16, 8), (56, 28), (9, 5)] {
            let ellipse = Draw.ellipse(width: w, height: h, fill: fill)
            #expect(ellipse.width == w && ellipse.height == h)
            for y in 0..<h {
                for x in 0..<w {
                    #expect(ellipse[x, y] == ellipse[w - 1 - x, y] && ellipse[x, y] == ellipse[x, h - 1 - y], "\(w)×\(h) (\(x), \(y))")
                }
            }
            #expect(ellipse.opaqueBounds == PixelRect(x: 0, y: 0, width: w, height: h), "touches its four borders")
            let widths = (0..<h).map { Self.row(ellipse, $0).count }
            for y in 1...((h - 1) / 2) { #expect(widths[y] >= widths[y - 1], "convex rows") }
            for y in 0..<h {
                let columns = Self.row(ellipse, y)
                #expect(columns.count == (columns.last ?? -1) - (columns.first ?? 0) + 1, "contiguous rows")
            }
            #expect(ellipse.distinctColors == [fill])
        }
    }

    @Test func shearToWall() {
        var front = PixelImage(width: 6, height: 3)
        for y in 0..<3 { for x in 0..<6 { front[x, y] = RGBA8(r: UInt8(10 * x), g: UInt8(10 * y), b: 1) } }
        let ne = Draw.shearToWall(front, wall: .ne)
        let nw = Draw.shearToWall(front, wall: .nw)
        for out in [ne, nw] { #expect(out.width == 6 && out.height == 3 + 6 / 2) }
        for y in 0..<3 {
            for x in 0..<6 {
                #expect(ne[x, y + x / 2] == front[x, y], "ne wall: each column pair 1 px lower, rightward")
                #expect(nw[x, y + (5 - x) / 2] == front[x, y], "nw wall: leftward")
            }
        }
        #expect(ne.alphaMask().count == 18 && nw.alphaMask().count == 18)
        #expect(nw == Draw.shearToWall(front.mirrored(), wall: .ne).mirrored())
        // The top edge of a sheared full rectangle is a 2:1 line.
        let sheared = Draw.shearToWall(PixelImage(width: 16, height: 4, fill: Palette.color(.cork)), wall: .ne)
        let tops = (0..<16).map { x in (0..<sheared.height).first { sheared[x, $0].a != 0 }! }
        #expect(tops == (0..<16).map { $0 / 2 })
        #expect(sheared.height == 4 + 8)
    }

    @Test func rampTones() {
        #expect(Ramp.neutral == Ramp(top: Palette.color(.mist), left: Palette.color(.stone), right: Palette.color(.slate),
                                     outline: Palette.color(.ink), highlight: Palette.color(.chalk)))
        #expect(Ramp.wall == Ramp(top: Palette.color(.chalk), left: Palette.color(.stone), right: Palette.color(.slate),
                                  outline: Palette.color(.ink), highlight: Palette.color(.chalk)))
        #expect(Ramp.woodLight == Ramp(top: Palette.color(.woodLight), left: Palette.color(.woodMid),
                                       right: Palette.color(.woodDark), outline: Palette.color(.hairDark),
                                       highlight: Palette.color(.paper)))
        #expect(Ramp.woodDark == Ramp(top: Palette.color(.woodMid), left: Palette.color(.woodDark),
                                      right: Palette.color(.hairDark), outline: Palette.color(.ink),
                                      highlight: Palette.color(.woodLight)))
        let lagune = Palette.hue(4)
        #expect(Ramp.hue(4) == Ramp(top: lagune.light, left: lagune.base, right: lagune.dark, outline: lagune.dark,
                                    highlight: Palette.color(.chalk)))
        for (_, ramp) in Self.ramps {
            for tone in [ramp.top, ramp.left, ramp.right, ramp.outline, ramp.highlight] {
                #expect(Palette.spriteColors.contains(tone))
            }
        }
    }

    @Test func boxIsDeterministic() {
        #expect(Draw.isoBox(w: 7, d: 5, height: 9, ramp: .hue(2)).image == Draw.isoBox(w: 7, d: 5, height: 9, ramp: .hue(2)).image)
    }
}
