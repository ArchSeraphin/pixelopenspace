import Foundation

/// Furniture of a post (7.4.3): the desk and the chair, each generated in its four facings with `Draw.isoBox`
/// (a mirror would put the light on the wrong side, 7.2). The facing of a post object is the gaze of the seated
/// agent: row A looks `ne`, row B looks `sw` (décision 2).
///
/// Desk (`light`, `dark`; 64×56, anchor (32, 40) at the centre of its tile): a 24-px-high top over the whole depth
/// of the tile, so the desks of rows A and B meet back to back (bench, 3.8); metal legs at the corners and a modesty
/// panel on the side away from the agent. Écart to 7.4: 56 rows instead of 48, which a top 24 px high over a full
/// tile needs. Chair (`slate`, `hue0` … `hue9`, each also `.jacket`; 32×40, anchor (16, 36) at the centre of its
/// tile): star base, gas lift, seat at 16 px, backrest on the side of the agent's back; the `.jacket` variants (an
/// offline agent) hang a jacket over a lower backrest, its back (ne, nw) or its open front (se, sw) toward the
/// viewer, camel, or navy on the warm chairs (Tomate, Mandarine, Cacao).
///
/// The offset helpers place the items of a post on the desk top; all are px from the desk anchor, for the desk
/// sprite of the same facing.
public enum FurnitureSprites {
    public static func all() -> [SpriteDef] { catalog }

    /// The monitor of row A sits 6 px (3 units) toward the clearance tile (+i), so the avatar's head does not hide
    /// the screen (7.4.3, to be checked at the milestone).
    public static let rowAAisleShift = PixelPoint(6, 3)

    /// Where the monitor's anchor goes (px from the desk anchor): the desk-top point under its stand, behind the
    /// keyboard, with the aisle shift of row A (`ne`).
    public static func monitorOffset(facing: Facing) -> PixelPoint {
        let p = DeskLayout.deskTop(DeskLayout.monitor, facing: facing)
        return facing == .ne ? PixelPoint(p.x + rowAAisleShift.x, p.y + rowAAisleShift.y) : p
    }

    /// Where `lamp.desk`'s anchor goes (px from the desk anchor): back corner on the clearance side.
    public static func lampOffset(facing: Facing) -> PixelPoint {
        DeskLayout.anchorOffset(DeskItemSprites.lampPlacement(facing: facing), facing: facing)
    }

    /// Where `light.cone`'s anchor goes (px from the desk anchor), for a lit `lamp.desk` placed with `lampOffset`:
    /// the desk-top point at local `DeskItemSprites.lightPoolCell`, under the centre of the lamp's base, so that the
    /// pool lies on the desk top and on the bench of the facing desk, its checkered edge just past the clearance side.
    public static func lightConeOffset(facing: Facing) -> PixelPoint {
        DeskLayout.deskTop(DeskItemSprites.lightPoolCell, facing: facing)
    }

    /// Where `keyboard`'s anchor goes (px from the desk anchor): centred, near the agent's edge.
    public static func keyboardOffset(facing: Facing) -> PixelPoint {
        DeskLayout.anchorOffset(DeskItemSprites.keyboardPlacement(facing: facing), facing: facing)
    }

    /// Where `mug`'s anchor goes (px from the desk anchor): front corner away from the aisle.
    public static func mugOffset(facing: Facing) -> PixelPoint {
        DeskLayout.anchorOffset(DeskItemSprites.mugPlacement(facing: facing), facing: facing)
    }

    /// Where `papers`' anchor goes (px from the desk anchor): front corner on the aisle side.
    public static func papersOffset(facing: Facing) -> PixelPoint {
        DeskLayout.anchorOffset(DeskItemSprites.papersPlacement(facing: facing), facing: facing)
    }

    /// Where `desk.queue`'s anchor goes (px from the desk anchor): middle of the side away from the aisle.
    public static func queueOffset(facing: Facing) -> PixelPoint {
        DeskLayout.anchorOffset(DeskItemSprites.queuePlacement(facing: facing), facing: facing)
    }

    // MARK: Catalog

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        for facing in Facing.allCases {
            defs.append(desk(material: "light", ramp: .woodLight, facing: facing))
            defs.append(desk(material: "dark", ramp: .woodDark, facing: facing))
            for (name, ramp) in chairRamps {
                defs.append(chair(variant: name, ramp: ramp, jacket: false, facing: facing))
                defs.append(chair(variant: name + ".jacket", ramp: ramp, jacket: true, facing: facing))
            }
        }
        return defs.sorted { $0.key < $1.key }
    }()

    static let deskSize = (width: 64, height: 56)
    static let deskAnchor = PixelPoint(32, 40)
    static let chairSize = (width: 32, height: 40)
    static let chairAnchor = PixelPoint(16, 36)

    /// Painted metal (desk legs, slate chair, lamp, keyboard): stone / slate / shade.
    static let metal = Ramp(top: Palette.color(.stone), left: Palette.color(.slate), right: Palette.color(.shade),
                            outline: Palette.color(.ink), highlight: Palette.color(.mist))
    static let chairRamps: [(String, Ramp)] = [("slate", metal)] + (0..<10).map { ("hue\($0)", Ramp.hue($0)) }

    // MARK: Desk

    static func desk(material: String, ramp: Ramp, facing: Facing) -> SpriteDef {
        var canvas = SceneryKit.Canvas(width: deskSize.width, height: deskSize.height, anchor: deskAnchor)
        let legHeight = IsoMath.deskTopHeight - 3
        var parts: [(SceneryKit.Box, Ramp)] = [
            (DeskLayout.box(a: -7..<7, b: -8..<8, z: legHeight, height: 3, facing: facing), ramp),
            // Modesty panel on the far side from the agent, hanging under the top.
            (DeskLayout.box(a: -6..<6, b: -8..<(-7), z: 6, height: legHeight - 6, facing: facing), ramp),
        ]
        for a in [-7, 6] {
            for b in [-8, 7] {
                parts.append((DeskLayout.box(a: a..<(a + 1), b: b..<(b + 1), z: 0, height: legHeight, facing: facing), metal))
            }
        }
        let probes = canvas.boxes(parts)
        return SpriteDef(key: SpriteKey("desk", variant: material, facing: facing), category: .furniture,
                         anchor: deskAnchor, frames: [canvas.image], outlineColors: [ramp.outline], lightProbe: probes[0])
    }

    // MARK: Chair

    static func chair(variant: String, ramp: Ramp, jacket: Bool, facing: Facing) -> SpriteDef {
        var canvas = SceneryKit.Canvas(width: chairSize.width, height: chairSize.height, anchor: chairAnchor)
        // Star base: two 2:1 spokes under the gas lift, casters at their ends.
        canvas.line(from: (-3, 0), steps: 6, alongI: true, color: Palette.color(.shade))
        canvas.line(from: (0, -3), steps: 6, alongI: false, color: Palette.color(.shade))
        let i0 = canvas.point(u: -3, v: 0), j0 = canvas.point(u: 0, v: -3)
        for (x, y) in [(i0.x, i0.y), (i0.x + 1, i0.y), (i0.x + 10, i0.y + 5), (i0.x + 11, i0.y + 5),
                       (j0.x - 1, j0.y), (j0.x - 2, j0.y), (j0.x - 11, j0.y + 5), (j0.x - 12, j0.y + 5)] {
            canvas.image.set(x, y, Palette.color(.ink))
        }
        func local(_ a: Range<Int>, _ b: Range<Int>, _ z: Int, _ height: Int) -> SceneryKit.Box {
            DeskLayout.box(a: a, b: b, z: z, height: height, facing: facing)
        }
        // The backrest rises to 30 px; under a jacket it stops at 24, so that the jacket's collar and shoulders
        // stand above it and stay inside the frame when the backrest is away from the viewer (sw, se).
        let parts: [(SceneryKit.Box, Ramp)] = [
            (SceneryKit.Box(u: -1, v: -1, z: 2, w: 1, d: 1, height: 11), .neutral),
            (local(-3..<3, -3..<3, 13, 3), ramp),
            (local(-3..<3, 2..<3, 16, jacket ? 8 : 14), ramp),
        ]
        let probes = canvas.boxes(parts)
        guard jacket else {
            return SpriteDef(key: SpriteKey("chair", variant: variant, facing: facing), category: .furniture,
                             anchor: chairAnchor, frames: [canvas.image], outlineColors: [ramp.outline],
                             lightProbe: probes.last!)
        }
        // Hung by its shoulders over the backrest. The side the viewer sees is drawn front-on (`jacketBack` behind
        // the backrest, `jacketFront` before it) and pasted on the plane of that side, sheared like a left face (ne,
        // sw: lit) or a right face (se, nw: in shade), 2 px wider than the backrest on each side for the sleeves:
        // the drawing alone gives the silhouette (collar above the backrest, sleeves apart from the body, the chair
        // showing between them), so no box is drawn for the cloth.
        let cloth = jacketRamp(for: variant)
        let seenFromBehind = !facing.isTowardViewer
        let (drawingMap, plane, row) = seenFromBehind
            ? (jacketBack, local(-3..<3, 3..<4, 10, 16), -3) : (jacketFront, local(-3..<3, 1..<2, 16, 10), -4)
        let face: SceneryKit.Face = facing == .ne || facing == .sw ? .left : .right
        let drawing = drawingMap.render { slot in jacketPaint(slot, cloth: cloth, shaded: face == .right) }
        let at = canvas.paste(drawing, on: plane, face: face, column: -2, row: row)
        // Light probe on the cloth: the lit outer column of the left sleeve against the dark one of the right sleeve.
        func column(_ x: Int) -> PixelRect {
            let shift = face == .left ? x / 2 : (drawing.width - 1 - x) / 2
            return PixelRect(x: at.x + x, y: at.y + shift + jacketProbeRows.lowerBound, width: 1,
                             height: jacketProbeRows.count)
        }
        return SpriteDef(key: SpriteKey("chair", variant: variant, facing: facing), category: .furniture,
                         anchor: chairAnchor, frames: [canvas.image], outlineColors: [ramp.outline, cloth.outline],
                         lightProbe: LightProbe(left: column(1), right: column(14)))
    }

    /// Rows of both jacket drawings where column 1 is `L` and column 14 is `D`.
    static let jacketProbeRows = 5..<10

    /// The back of the jacket, front-drawn (16 × 19, from the collar, 29 px above the floor, to the hem, 10 px): the
    /// dark collar band above sloping shoulders, the two sleeves hanging along the sides, apart from the body below
    /// the elbows, down to their dark cuffs, the back flaring a little down to a vent and a darker hem. `L` light,
    /// `P` base, `D` dark, `o` outline.
    static let jacketBack = PixelMap("""
        .....oooooo.....
        ....oDDDDDDo....
        ..ooLDDDDDDLoo..
        .oLLLLLLLLLLLLo.
        oLLPPPPPPPPPPPDo
        oLPoPPPPPPPPoPDo
        oLPoPPPPPPPPoPDo
        oLPoPPPPPPPPoPDo
        oLPooPPPPPPooPDo
        oLPo.oPPPPo.oPDo
        oLPo.oPPPPo.oPDo
        oDDo.oPPPPo.oDDo
        oooo.oPPPPo.oooo
        ....oPPPPPPo....
        ...oPPPPPPPPo...
        ...oPPPPoPPPo...
        ..oPPPPPoPPPPo..
        ..oDDDDDoDDDDo..
        ..oooooooooooo..
        """)

    /// The front of the jacket, front-drawn (16 × 14, from the collar, 30 px above the floor, to the seat, 16 px):
    /// the collar points, the opening on the dark lining (`5`), the lapels meeting in a V, the buttoned closing (`2`
    /// buttons), two pocket flaps, the sleeves along the sides down to their dark cuffs.
    static let jacketFront = PixelMap("""
        ....ooo..ooo....
        ..ooLLo55oLLoo..
        .oLLLLo55oLLLDo.
        oLLPPLo55oLPPPDo
        oLPPPPLooLPPPPDo
        oLPoPPPoPPPPoPDo
        oLPoPPPo2PPPoPDo
        oLPoPPPoPPPPoPDo
        oLPoooPo2PoooPDo
        oLPoPPPoPPPPoPDo
        oDDoPPPoPPPPoDDo
        oooPPPPoPPPPPooo
        ..oPPPPoPPPPPo..
        ..oooooooooooo..
        """)

    /// Jacket colours: on a face toward the viewer's left (lit) the light, base and dark tones of the cloth; on a
    /// face toward the right (in shade) one step darker. `5` is the lining, `2` the buttons.
    static func jacketPaint(_ slot: Slot, cloth: Ramp, shaded: Bool) -> RGBA8? {
        switch slot {
        case .hueLight: return shaded ? cloth.left : cloth.top
        case .hueBase: return shaded ? cloth.right : cloth.left
        case .hueDark: return shaded ? cloth.outline : cloth.right
        case .role(.ink): return cloth.outline
        case .role(.shade): return Palette.color(.shade)
        case .role(.mist): return Palette.color(.mist)
        default: return nil
        }
    }

    /// A camel jacket; navy on the warm chairs (Tomate, Mandarine, Cacao), whose colour camel would match.
    static func jacketRamp(for variant: String) -> Ramp {
        ["hue0", "hue1", "hue8"].contains { variant.hasPrefix($0) } ? navy : camel
    }

    static let camel = Ramp(top: Palette.color(.woodLight), left: Palette.color(.woodMid), right: Palette.color(.woodDark),
                            outline: Palette.color(.hairDark), highlight: Palette.color(.paper))
    static let navy = Ramp(top: Palette.color(.uiTitle), left: Palette.color(.skyNight), right: Palette.color(.shade),
                           outline: Palette.color(.ink), highlight: Palette.color(.stone))
}

/// The layout of a post in local coordinates, shared by the desk, the chair and the desk items: `a` runs along
/// the row toward the clearance tile, `b` from the desk toward the seated agent (and the chair's back), in iso
/// units from the centre of the tile (1 unit = 2 px across, 1 px down; a tile is 16 units).
enum DeskLayout {
    /// Unit cells (a, b) of a local rectangle to (u, v) cells of the floor grid for the agent's gaze:
    /// ne (a, b), sw (a, −b), se (−b, a), nw (b, a). ne and nw (sw and se) are mirror images.
    static func box(a: Range<Int>, b: Range<Int>, z: Int, height: Int, facing: Facing) -> SceneryKit.Box {
        let (u, v) = cells(a: a, b: b, facing: facing)
        return SceneryKit.Box(u: u.lowerBound, v: v.lowerBound, z: z, w: u.count, d: v.count, height: height)
    }

    static func cells(a: Range<Int>, b: Range<Int>, facing: Facing) -> (u: Range<Int>, v: Range<Int>) {
        let flipped = (-b.upperBound)..<(-b.lowerBound)
        switch facing {
        case .ne: return (a, b)
        case .sw: return (a, flipped)
        case .se: return (flipped, a)
        case .nw: return (b, a)
        }
    }

    /// A local point (a, b) as a floor point (u, v).
    static func point(a: Int, b: Int, facing: Facing) -> (u: Int, v: Int) {
        switch facing {
        case .ne: return (a, b)
        case .sw: return (a, -b)
        case .se: return (-b, a)
        case .nw: return (b, a)
        }
    }

    /// The monitor's stand, centred on the row, behind the keyboard.
    static let monitor = (a: 0, b: -2)

    /// Px from the desk anchor of the desk-top point at local (a, b).
    static func deskTop(_ local: (a: Int, b: Int), facing: Facing) -> PixelPoint {
        let (u, v) = point(a: local.a, b: local.b, facing: facing)
        return PixelPoint(2 * u - 2 * v, u + v - IsoMath.deskTopHeight)
    }

    /// Px from the desk anchor where an item's anchor goes, the item's image being placed so that the box it was
    /// drawn from (`placement.box`, footprint on the desk top) lands at its local cells.
    static func anchorOffset(_ placement: DeskItemSprites.Placement, facing: Facing) -> PixelPoint {
        let (u, v) = cells(a: placement.a, b: placement.b, facing: facing)
        let floor = PixelPoint(2 * u.lowerBound - 2 * v.lowerBound, u.lowerBound + v.lowerBound - IsoMath.deskTopHeight)
        // The item image has the footprint's back corner at `placement.corner` (px from its top-left).
        return PixelPoint(floor.x - placement.corner.x + placement.anchor.x,
                          floor.y - placement.corner.y + placement.anchor.y)
    }
}

/// Drawing helpers shared by the decor sprite sets (floors, walls, furniture, desk items, decor, lights).
enum SceneryKit {
    /// An iso box on a canvas: footprint w × d units from its back corner (u, v) (lowest u and v), bottom z px
    /// above the floor, `height` px tall.
    struct Box: Hashable, Sendable {
        var u: Int, v: Int, z: Int, w: Int, d: Int, height: Int

        /// Disjoint boxes: `self` is nearer the viewer when it lies beyond `other` along u, v or z, the three axes
        /// pointing toward the viewer in this projection.
        func isInFront(of other: Box) -> Bool {
            u >= other.u + other.w || v >= other.v + other.d || z >= other.z + other.height
        }
    }

    /// Back-to-front order of disjoint boxes: each one after every box it is in front of (and not behind); ties
    /// keep the list order, so the result is deterministic.
    static func paintersOrder(_ boxes: [Box]) -> [Int] {
        var remaining = Array(boxes.indices), order: [Int] = []
        while !remaining.isEmpty {
            let ready = remaining.firstIndex { i in
                !remaining.contains { j in
                    j != i && boxes[i].isInFront(of: boxes[j]) && !boxes[j].isInFront(of: boxes[i])
                }
            } ?? 0
            order.append(remaining.remove(at: ready))
        }
        return order
    }

    enum Face: Sendable { case left, right }

    /// A sprite canvas whose anchor is a floor point. (u, v) are iso units from it along i and j (1 unit = 2 px
    /// across and 1 px down), z a height in px; a floor point is the corner between pixels, like the anchors.
    struct Canvas: Sendable {
        var image: PixelImage
        let anchor: PixelPoint

        init(width: Int, height: Int, anchor: PixelPoint) {
            image = PixelImage(width: width, height: height)
            self.anchor = anchor
        }

        func point(u: Int, v: Int, z: Int = 0) -> PixelPoint {
            PixelPoint(anchor.x + 2 * u - 2 * v, anchor.y + u + v - z)
        }

        /// Top-left of `Draw.isoBox` for `box`: its top vertex (column 2d of the image) over the back corner.
        func origin(of box: Box) -> PixelPoint {
            let corner = point(u: box.u, v: box.v, z: box.z)
            return PixelPoint(corner.x - 2 * box.d, corner.y - box.height)
        }

        /// Draws the lit box; returns its light probe in canvas coordinates. Traps when the box leaves the canvas:
        /// the art is static, a clipped sprite must fail the first test that draws it.
        @discardableResult
        mutating func box(_ box: Box, ramp: Ramp) -> LightProbe {
            let drawn = Draw.isoBox(w: box.w, d: box.d, height: box.height, ramp: ramp)
            let o = origin(of: box)
            precondition(fits(drawn.image, at: o), "box \(box) leaves the \(image.width)×\(image.height) canvas")
            image.blit(drawn.image, x: o.x, y: o.y)
            return SceneryKit.offset(drawn.lightProbe, by: o)
        }

        /// Draws disjoint boxes back to front (`paintersOrder`); returns their probes in the list order.
        @discardableResult
        mutating func boxes(_ parts: [(Box, Ramp)]) -> [LightProbe] {
            var probes = [LightProbe?](repeating: nil, count: parts.count)
            for index in SceneryKit.paintersOrder(parts.map(\.0)) {
                probes[index] = box(parts[index].0, ramp: parts[index].1)
            }
            return probes.map { $0! }
        }

        /// Pastes a front-drawn image on a face of `box`, sheared like that face (left face: each column pair 1 px
        /// lower to the right, like the ne wall; right face: to the left, like the nw wall), its column 0 on face
        /// column `column` and its row 0 `row` px under the face's top edge. Widths and `column` are even.
        /// Returns the top-left of the sheared image.
        @discardableResult
        mutating func paste(_ front: PixelImage, on box: Box, face: Face, column: Int, row: Int) -> PixelPoint {
            precondition(column % 2 == 0 && front.width % 2 == 0, "even placement keeps the 2:1 steps aligned")
            let o = origin(of: box)
            let at: PixelPoint
            let sheared: PixelImage
            switch face {
            case .left:
                at = PixelPoint(o.x + column, o.y + row + box.d + 1 + column / 2)
                sheared = Draw.shearToWall(front, wall: .ne)
            case .right:
                at = PixelPoint(o.x + 2 * box.w + column, o.y + row + box.w + 1 + (2 * box.d - column - front.width) / 2)
                sheared = Draw.shearToWall(front, wall: .nw)
            }
            precondition(fits(sheared, at: at), "pasted image leaves the canvas")
            image.blit(sheared, x: at.x, y: at.y)
            return at
        }

        /// Whether the opaque pixels of `piece`, its top-left at `at`, all fall inside the canvas.
        func fits(_ piece: PixelImage, at: PixelPoint) -> Bool {
            guard let bounds = piece.opaqueBounds else { return true }
            return at.x + bounds.x >= 0 && at.y + bounds.y >= 0 && at.x + bounds.x + bounds.width <= image.width
                && at.y + bounds.y + bounds.height <= image.height
        }

        /// A 2:1 floor line of `steps` units from the floor point (u, v), toward +i (down right) or +j (down left).
        mutating func line(from start: (Int, Int), steps: Int, alongI: Bool, color: RGBA8) {
            let p = point(u: start.0, v: start.1)
            Draw.line2to1(into: &image, from: PixelPoint(alongI ? p.x : p.x - 1, p.y), steps: steps,
                          rightward: alongI, downward: true, color: color)
        }
    }

    static func offset(_ probe: LightProbe, by o: PixelPoint) -> LightProbe {
        LightProbe(left: offset(probe.left, by: o), right: offset(probe.right, by: o))
    }

    static func offset(_ rect: PixelRect, by o: PixelPoint) -> PixelRect {
        PixelRect(x: rect.x + o.x, y: rect.y + o.y, width: rect.width, height: rect.height)
    }
}
