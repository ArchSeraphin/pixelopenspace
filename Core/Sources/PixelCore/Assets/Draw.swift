import Foundation

/// The five tones of a lit volume (7.2): light comes from the top left, so the top is the lightest face, the
/// face toward +j (left on screen) the middle tone and the face toward +i (right) the darkest.
public struct Ramp: Hashable, Sendable {
    public var top: RGBA8, left: RGBA8, right: RGBA8, outline: RGBA8, highlight: RGBA8

    public init(top: RGBA8, left: RGBA8, right: RGBA8, outline: RGBA8, highlight: RGBA8) {
        self.top = top
        self.left = left
        self.right = right
        self.outline = outline
        self.highlight = highlight
    }

    /// mist / stone / slate, outline ink, highlight chalk.
    public static let neutral = Ramp(top: Palette.color(.mist), left: Palette.color(.stone), right: Palette.color(.slate),
                                     outline: Palette.color(.ink), highlight: Palette.color(.chalk))
    /// chalk / stone / slate, outline ink, highlight chalk.
    public static let wall = Ramp(top: Palette.color(.chalk), left: Palette.color(.stone), right: Palette.color(.slate),
                                  outline: Palette.color(.ink), highlight: Palette.color(.chalk))
    /// woodLight / woodMid / woodDark, outline hairDark, highlight paper.
    public static let woodLight = Ramp(top: Palette.color(.woodLight), left: Palette.color(.woodMid),
                                       right: Palette.color(.woodDark), outline: Palette.color(.hairDark),
                                       highlight: Palette.color(.paper))
    /// woodMid / woodDark / hairDark, outline ink, highlight woodLight.
    public static let woodDark = Ramp(top: Palette.color(.woodMid), left: Palette.color(.woodDark),
                                      right: Palette.color(.hairDark), outline: Palette.color(.ink),
                                      highlight: Palette.color(.woodLight))

    /// light / base / dark of the project hue, outline dark (7.1), highlight chalk.
    public static func hue(_ index: Int) -> Ramp {
        let tones = Palette.hue(index)
        return Ramp(top: tones.light, left: tones.base, right: tones.dark, outline: tones.dark,
                    highlight: Palette.color(.chalk))
    }
}

/// The two back walls (3.8): `nw` runs along i = 0, `ne` along j = 0.
public enum WallSide: String, CaseIterable, Codable, Sendable { case nw, ne }

/// Where the lint samples a lit volume: the left face must be lighter than the right one (7.2).
public struct LightProbe: Hashable, Sendable {
    public var left: PixelRect
    public var right: PixelRect

    public init(left: PixelRect, right: PixelRect) {
        self.left = left
        self.right = right
    }
}

/// A box drawn by `Draw.isoBox`, with the masks of its three faces (taken from the geometry, outline included)
/// and a light probe inside the faces.
public struct IsoBox: Hashable, Sendable {
    public var image: PixelImage
    public var top: BitMask
    public var left: BitMask
    public var right: BitMask
    public var lightProbe: LightProbe

    public init(image: PixelImage, top: BitMask, left: BitMask, right: BitMask, lightProbe: LightProbe) {
        self.image = image
        self.top = top
        self.left = left
        self.right = right
        self.lightProbe = lightProbe
    }
}

/// Geometric primitives of the generator (7.5): every iso edge steps 2 px across for 1 px down, no anti-aliasing.
public enum Draw {
    /// Floor diamond: width multiple of 4, height width / 2; row y < height / 2 is 4y + 4 px wide, centred,
    /// mirrored below (7.3: a 64×32 tile).
    public static func isoDiamond(width: Int, fill: RGBA8) -> PixelImage {
        let mask = isoDiamondMask(width: width)
        var image = PixelImage(width: mask.width, height: mask.height)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] { image[x, y] = fill }
        }
        return image
    }

    public static func isoDiamondMask(width: Int) -> BitMask {
        precondition(width >= 4 && width % 4 == 0, "a diamond width is a positive multiple of 4")
        return topMask(w: width / 4, d: width / 4, imageHeight: width / 2)
    }

    /// Lit box. Footprint in iso units (1 unit = 2 px across, 1 px down), height in px. Image 2(w + d) × (w + d + height).
    /// Top = ramp.top; face toward +j (left on screen) = ramp.left; face toward +i (right) = ramp.right;
    /// 1-px selective outline; highlight on the front edges of the top. isoBox(w: 16, d: 16, height: 0).top
    /// equals isoDiamondMask(width: 64).
    ///
    /// Geometry: the top vertex sits between columns 2d − 1 and 2d, the left vertex in column 0 at row d − 1…d,
    /// the right vertex in the last column at row w − 1…w, the bottom vertex between columns 2w − 1 and 2w.
    /// Columns 0 ..< 2w hold the left face, the others the right face; each face column is `height` px tall,
    /// right under the top. The outline is the outer ring of the silhouette (4-neighbourhood), so every outlined
    /// edge is a clean 2:1 line; the highlight is the lowest top pixel of each column, above the faces.
    /// The light probes are rectangles in the middle of each face, clear of the outline (empty when height < 2).
    public static func isoBox(w: Int, d: Int, height: Int, ramp: Ramp) -> IsoBox {
        precondition(w >= 1 && d >= 1 && height >= 0, "a box needs a footprint of at least 1×1 unit")
        let width = 2 * (w + d), imageHeight = w + d + height
        let top = topMask(w: w, d: d, imageHeight: imageHeight)
        var left = BitMask(width: width, height: imageHeight)
        var right = BitMask(width: width, height: imageHeight)
        var image = PixelImage(width: width, height: imageHeight)
        for y in 0..<imageHeight {
            for x in 0..<width where top[x, y] { image[x, y] = ramp.top }
        }
        for x in 0..<width {
            let bottom = bottomOfTop(x: x, w: w, d: d)
            let isLeft = x < 2 * w
            for y in (bottom + 1)..<(bottom + 1 + height) {
                if isLeft { left[x, y] = true } else { right[x, y] = true }
                image[x, y] = isLeft ? ramp.left : ramp.right
            }
            // Front edge of the top: lit when a face hangs below it.
            if height > 0 { image[x, bottom] = ramp.highlight }
        }
        image = outline(image, color: ramp.outline)
        let probe = LightProbe(left: faceProbe(span: w, other: d, height: height, imageWidth: width, rightFace: false),
                               right: faceProbe(span: d, other: w, height: height, imageWidth: width, rightFace: true))
        return IsoBox(image: image, top: top, left: left, right: right, lightProbe: probe)
    }

    /// Columns of row y of a w × d top face (both inclusive).
    private static func topRow(_ y: Int, w: Int, d: Int) -> (left: Int, right: Int) {
        let left = y < d ? 2 * d - 2 - 2 * y : 2 * (y - d)
        let right = y < w ? 2 * d + 1 + 2 * y : 2 * (w + d) - 1 - 2 * (y - w)
        return (left, right)
    }

    private static func topMask(w: Int, d: Int, imageHeight: Int) -> BitMask {
        var mask = BitMask(width: 2 * (w + d), height: imageHeight)
        for y in 0..<(w + d) {
            let row = topRow(y, w: w, d: d)
            for x in row.left...row.right { mask[x, y] = true }
        }
        return mask
    }

    /// Lowest row of the top face in column x: the front edges L→B (columns < 2w) and R→B.
    private static func bottomOfTop(x: Int, w: Int, d: Int) -> Int {
        x < 2 * w ? d + x / 2 : w + (2 * (w + d) - 1 - x) / 2
    }

    /// Light probe of one face. `span` is the face extent in units (w for the left face, d for the right),
    /// `other` the other one. In face coordinates, column 0 is the outer edge (the outline) and column c starts
    /// right under row other + c / 2; k column pairs give a rectangle of height − k rows clear of the outline.
    private static func faceProbe(span: Int, other: Int, height: Int, imageWidth: Int, rightFace: Bool) -> PixelRect {
        guard height >= 2 else { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        let x0: Int, y0: Int, columns: Int, rows: Int
        if span == 1 {
            (x0, y0, columns, rows) = (1, other + 1, 1, height - 1)
        } else {
            let pairs = max(1, min(span - 1, height / 2))
            let firstPair = 1 + (span - 1 - pairs) / 2
            (x0, y0, columns, rows) = (2 * firstPair, other + firstPair + pairs, 2 * pairs, height - pairs)
        }
        let x = rightFace ? imageWidth - x0 - columns : x0
        return PixelRect(x: x, y: y0, width: columns, height: rows)
    }

    /// 2:1 line: every step is exactly 2 px across and 1 px down (or up). Step k covers the two pixels starting
    /// 2k px from `from` in the horizontal direction, k rows from it; clipped.
    public static func line2to1(into image: inout PixelImage, from: PixelPoint, steps: Int, rightward: Bool,
                                downward: Bool, color: RGBA8) {
        let dx = rightward ? 1 : -1, dy = downward ? 1 : -1
        for k in 0..<max(steps, 0) {
            let x = from.x + 2 * k * dx, y = from.y + k * dy
            image.set(x, y, color)
            image.set(x + dx, y, color)
        }
    }

    /// 50 % checkerboard of `color` over `mask`; `phase` (0 or 1) picks the parity: pixels with
    /// (x + y) % 2 == phase. The only dithering allowed (7.2), on large surfaces.
    public static func dither50(into image: inout PixelImage, mask: BitMask, color: RGBA8, phase: Int) {
        let parity = ((phase % 2) + 2) % 2
        for y in 0..<min(mask.height, image.height) {
            for x in 0..<min(mask.width, image.width) where mask[x, y] && (x + y) % 2 == parity {
                image[x, y] = color
            }
        }
    }

    /// Recolours the outer ring of the opaque area (selective outline of 7.2): every non-transparent pixel with a
    /// 4-neighbour that is transparent or outside the image.
    public static func outline(_ image: PixelImage, color: RGBA8) -> PixelImage {
        var out = image
        func isClear(_ x: Int, _ y: Int) -> Bool {
            x < 0 || y < 0 || x >= image.width || y >= image.height || image[x, y].a == 0
        }
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].a != 0 {
                if isClear(x - 1, y) || isClear(x + 1, y) || isClear(x, y - 1) || isClear(x, y + 1) {
                    out[x, y] = color
                }
            }
        }
        return out
    }

    /// Integer ellipse filling width × height (character shadow 20×8): the pixels whose centre lies inside the
    /// inscribed ellipse, tested as (2x + 1 − W)²·H² + (2y + 1 − H)²·W² ≤ W²·H². Symmetric on both axes.
    public static func ellipse(width: Int, height: Int, fill: RGBA8) -> PixelImage {
        precondition(width >= 1 && height >= 1, "empty ellipse")
        var image = PixelImage(width: width, height: height)
        let w2 = width * width, h2 = height * height, limit = w2 * h2
        for y in 0..<height {
            let dy = 2 * y + 1 - height
            for x in 0..<width {
                let dx = 2 * x + 1 - width
                if dx * dx * h2 + dy * dy * w2 <= limit { image[x, y] = fill }
            }
        }
        return image
    }

    /// Puts a front-drawn object on a back wall: each 2-px column pair moves 1 px down toward the front
    /// (ne wall: rightward, nw wall: leftward). Output height = input height + width / 2.
    /// Column x moves down by x / 2 on the ne wall and by (width − 1 − x) / 2 on the nw wall, so the nw result
    /// is the mirror of the ne result of the mirrored input.
    public static func shearToWall(_ image: PixelImage, wall: WallSide) -> PixelImage {
        var out = PixelImage(width: image.width, height: image.height + image.width / 2)
        for x in 0..<image.width {
            let shift = wall == .ne ? x / 2 : (image.width - 1 - x) / 2
            for y in 0..<image.height { out[x, y + shift] = image[x, y] }
        }
        return out
    }
}
