import Foundation

/// Floor tiles and floor markers (7.4.1): 64×32 diamonds (rows 4y + 4 px wide, 7.3) anchored at their centre.
///
/// A tile pixel is located by p = x + 2y − 30, which grows along i, and q = 2y − x + 33, which grows along j:
/// both run from 0 on the back edges (upper left for p, upper right for q) to 65 on the front edges, 4 steps per
/// iso unit; a 1-px iso line is 2 steps. Mirroring a tile swaps p and q. Diamonds overlap their neighbours by
/// their front 2 steps (p or q ≥ 64), which the next tile drawn covers.
///
/// - `floor.hall` (`n0` … `n2`): parquet of planks along i, seams in `floorDark`, staggered end joints and a knot.
/// - `floor.corridor` (`n0`, `n1`): large slabs, a joint along the two back edges; `n1` adds a few scuffs.
/// - `floor.carpet` (`hueN.plain`, `hueN.stripes`): the project hue's light tone with a discreet motif in its base
///   tone (a small 50 % checkerboard patch, or two stripes along i, the axis of the rows of posts).
/// - `floor.carpet.edge.*` and `.corner.*` (`hueN`): the island border, a dark line then a band of the base tone,
///   on the named side; `.w`, `.e` and `corner.w` are mirrors of `.n`, `.s` and `corner.e`.
/// - `floor.hover` (2 × 4 fps): a dotted `chalk` outline whose dashes march; `floor.dropTarget` (4 × 8 fps):
///   two `chalk` rings moving inward.
public enum FloorSprites {
    public static func all() -> [SpriteDef] { catalog }

    static let anchor = PixelPoint(32, 16)
    static let diamond = Draw.isoDiamondMask(width: 64)

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        for n in 0..<3 { defs.append(flat("floor.hall", variant: "n\(n)", hall(n))) }
        for n in 0..<2 { defs.append(flat("floor.corridor", variant: "n\(n)", corridor(n))) }
        for hue in 0..<10 {
            let variant = "hue\(hue)"
            defs.append(flat("floor.carpet", variant: variant + ".plain", carpet(hue, stripes: false)))
            defs.append(flat("floor.carpet", variant: variant + ".stripes", carpet(hue, stripes: true)))
            let drawn: [(SpriteID, [CarpetEdge])] = [
                ("floor.carpet.edge.n", [.back(.q)]), ("floor.carpet.edge.s", [.front(.q)]),
                ("floor.carpet.corner.n", [.back(.p), .back(.q)]), ("floor.carpet.corner.e", [.front(.p), .back(.q)]),
                ("floor.carpet.corner.s", [.front(.p), .front(.q)]),
            ]
            for (id, edges) in drawn {
                defs.append(flat(id, variant: variant, border(hue, edges: edges)))
            }
            for (id, source) in [("floor.carpet.edge.w", "floor.carpet.edge.n"), ("floor.carpet.edge.e", "floor.carpet.edge.s"),
                                 ("floor.carpet.corner.w", "floor.carpet.corner.e")] as [(SpriteID, SpriteID)] {
                let sourceKey = SpriteKey(source, variant: variant)
                let image = defs.first { $0.key == sourceKey }!.frames[0]
                defs.append(SpriteDef(key: SpriteKey(id, variant: variant), category: .floors,
                                      anchor: PixelPoint(64 - anchor.x, anchor.y), frames: [image.mirrored()],
                                      derivation: .mirror, source: sourceKey))
            }
        }
        defs.append(SpriteDef(key: SpriteKey("floor.hover"), category: .floors, anchor: anchor,
                              frames: (0..<2).map(hover), holds: AnimationClock.holds(fps: 4, frames: 2)))
        defs.append(SpriteDef(key: SpriteKey("floor.dropTarget"), category: .floors, anchor: anchor,
                              frames: (0..<4).map(dropTarget), holds: AnimationClock.holds(fps: 8, frames: 4)))
        return defs.sorted { $0.key < $1.key }
    }()

    private static func flat(_ id: SpriteID, variant: String, _ image: PixelImage) -> SpriteDef {
        SpriteDef(key: SpriteKey(id, variant: variant), category: .floors, anchor: anchor, frames: [image])
    }

    /// Paints every pixel of the diamond: `paint(p, q, x, y)`.
    static func tile(_ paint: (_ p: Int, _ q: Int, _ x: Int, _ y: Int) -> RGBA8?) -> PixelImage {
        var image = PixelImage(width: 64, height: 32)
        for y in 0..<32 {
            for x in 0..<64 where diamond[x, y] {
                if let color = paint(x + 2 * y - 30, 2 * y - x + 33, x, y) { image[x, y] = color }
            }
        }
        return image
    }

    // MARK: Hall and corridors

    /// End joints of the four planks (first p of the joint), per noise variant; and a knot (p, q) per variant.
    private static let hallJoints: [[Int]] = [[14, 42, 26, 54], [34, 8, 50, 20], [46, 24, 6, 36]]
    private static let hallKnots: [(Int, Int)] = [(36, 24), (18, 42), (56, 8)]

    static func hall(_ n: Int) -> PixelImage {
        let light = Palette.color(.floorLight), dark = Palette.color(.floorDark)
        return tile { p, q, _, _ in
            let plank = min(q, 63) / 16, inPlank = q - 16 * plank
            if q < 64 && inPlank < 2 { return dark }                                    // seam between planks
            let joint = hallJoints[n][plank]
            if p == joint || p == joint + 1 { return dark }                            // end of a plank
            let knot = hallKnots[n]
            if (p == knot.0 || p == knot.0 + 1) && q == knot.1 { return dark }
            return light
        }
    }

    private static let corridorScuffs: [(Int, Int)] = [(20, 40), (21, 40), (46, 18), (47, 18), (48, 52)]

    static func corridor(_ n: Int) -> PixelImage {
        let light = Palette.color(.floorLight), dark = Palette.color(.floorDark)
        return tile { p, q, _, _ in
            if p < 2 || q < 2 { return dark }                                          // joints of the slab
            if n == 1 && corridorScuffs.contains(where: { $0.0 == p && $0.1 == q }) { return dark }
            return light
        }
    }

    // MARK: Carpets

    enum Axis { case p, q }
    /// The side of an island edge: the back edges (p or q near 0) or the front ones (near 65).
    enum CarpetEdge {
        case back(Axis), front(Axis)

        /// Distance in steps from this edge; the front edges count their 2 overlap steps as 0.
        func distance(p: Int, q: Int) -> Int {
            switch self {
            case .back(let axis): return axis == .p ? p : q
            case .front(let axis): return max(0, 63 - (axis == .p ? p : q))
            }
        }
    }

    /// The light tone, with the plain motif (a 4×4-unit patch of 50 % checkerboard at the centre) or two stripes.
    static func carpet(_ hue: Int, stripes: Bool) -> PixelImage {
        let tones = Palette.hue(hue)
        return tile { p, q, x, y in
            if stripes { return (13..<17).contains(q) || (45..<49).contains(q) ? tones.base : tones.light }
            return motif(p: p, q: q, x: x, y: y) ? tones.base : tones.light
        }
    }

    static func motif(p: Int, q: Int, x: Int, y: Int) -> Bool {
        (25..<41).contains(p) && (25..<41).contains(q) && (x + y) % 2 == 0
    }

    /// A plain carpet tile with the island border along `edges`: 2 steps of the dark tone, then 6 of the base tone.
    static func border(_ hue: Int, edges: [CarpetEdge]) -> PixelImage {
        let tones = Palette.hue(hue)
        return tile { p, q, x, y in
            let d = edges.map { $0.distance(p: p, q: q) }.min()!
            if d < 2 { return tones.dark }
            if d < 8 { return tones.base }
            return motif(p: p, q: q, x: x, y: y) ? tones.base : tones.light
        }
    }

    // MARK: Markers

    /// Pixels of the diamond with a 4-neighbour outside it.
    static func ring(_ x: Int, _ y: Int) -> Bool {
        diamond[x, y] && (!diamond[x - 1, y] || !diamond[x + 1, y] || !diamond[x, y - 1] || !diamond[x, y + 1])
    }

    /// Dashes of one 2:1 step (2 px) every other step; frame 1 lights the other steps.
    static func hover(_ frame: Int) -> PixelImage {
        let chalk = Palette.color(.chalk)
        return tile { _, _, x, y in ring(x, y) && (x / 2) % 2 == frame ? chalk : nil }
    }

    /// Two rings 8 steps apart, 2 steps further inside at each frame.
    static func dropTarget(_ frame: Int) -> PixelImage {
        let chalk = Palette.color(.chalk)
        return tile { p, q, _, _ in
            let d = min(p, q, 65 - p, 65 - q)
            return d < 16 && (d - 2 * frame + 8) % 8 < 2 ? chalk : nil
        }
    }
}
