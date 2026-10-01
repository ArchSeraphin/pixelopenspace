import Foundation

/// Objects of the desk and of the cork wall (7.4.3, 7.4.7): keyboard, papers, mug, desk lamp (lit volumes, generated
/// in their four facings), the post-it stuck on a monitor, the queue of post-its, and the mini post-its of the cork
/// wall (drawn from the front, then sheared once per wall).
///
/// Écarts to 7.4: a 2:1 box 14 (12) px wide is at least 7 (6) rows, plus 2 rows of thickness for its light probe, so
/// `keyboard` is 14×9 and `papers` 12×8; `mug~steam` is 6×14, its steam rising above the 6×8 mug.
public enum DeskItemSprites {
    public static func all() -> [SpriteDef] { catalog }

    /// Where an item sits on the desk (local cells, see `DeskLayout`), the back corner of its footprint in its image
    /// (px from the top-left, a corner between pixels) and its anchor: enough to place it on any desk facing.
    struct Placement {
        var a: Range<Int>
        var b: Range<Int>
        var corner: PixelPoint
        var anchor: PixelPoint
    }

    // MARK: Layout on the desk (local a along the row toward the aisle, b toward the agent)

    static let keyboardCells = (a: -3..<2, b: 5..<7)
    static let papersCells = (a: 3..<7, b: 3..<5)
    static let mugCells = (a: -6..<(-5), b: 4..<5)
    static let lampCells = (a: 5..<7, b: -7..<(-5))

    static func keyboardPlacement(facing: Facing) -> Placement {
        let (w, d) = footprint(keyboardCells.a, keyboardCells.b, facing)
        return Placement(a: keyboardCells.a, b: keyboardCells.b, corner: PixelPoint(2 * d, keyboardHeight),
                         anchor: PixelPoint(w + d, w + d + keyboardHeight))
    }

    static func papersPlacement(facing: Facing) -> Placement {
        let (w, d) = footprint(papersCells.a, papersCells.b, facing)
        return Placement(a: papersCells.a, b: papersCells.b, corner: PixelPoint(2 * d, papersHeight),
                         anchor: PixelPoint(w + d, w + d + papersHeight))
    }

    static func mugPlacement(facing: Facing) -> Placement {
        Placement(a: mugCells.a, b: mugCells.b, corner: PixelPoint(mugBodyX(facing) + 2, mugHeight), anchor: PixelPoint(3, 8))
    }

    static func lampPlacement(facing: Facing) -> Placement {
        Placement(a: lampCells.a, b: lampCells.b, corner: lampBaseCorner, anchor: lampAnchor)
    }

    /// The queue sprite has one orientation (3 units along i, 2 along j): local cells chosen per facing to match it.
    static func queuePlacement(facing: Facing) -> Placement {
        let cells: (a: Range<Int>, b: Range<Int>)
        switch facing {
        case .ne, .sw: cells = (-7..<(-4), -2..<0)
        case .se, .nw: cells = (-7..<(-5), -3..<0)
        }
        return Placement(a: cells.a, b: cells.b, corner: queueCorner, anchor: PixelPoint(5, 8))
    }

    private static func footprint(_ a: Range<Int>, _ b: Range<Int>, _ facing: Facing) -> (w: Int, d: Int) {
        let (u, v) = DeskLayout.cells(a: a, b: b, facing: facing)
        return (u.count, v.count)
    }

    // MARK: Catalog

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        for facing in Facing.allCases {
            defs.append(boxItem("keyboard", cells: keyboardCells, height: keyboardHeight, ramp: FurnitureSprites.metal,
                                facing: facing, detail: keyboardKeys))
            defs.append(boxItem("papers", cells: papersCells, height: papersHeight, ramp: paperRamp, facing: facing,
                                detail: paperLines))
            defs.append(mug(facing: facing, steam: false))
            defs.append(mug(facing: facing, steam: true))
            defs.append(lamp(facing: facing, on: true))
            defs.append(lamp(facing: facing, on: false))
        }
        for (variant, tones) in postitTones {
            defs.append(SpriteDef(key: SpriteKey("desk.postit", variant: variant), category: .deskItems,
                                  anchor: PixelPoint(3, 6), frames: [deskPostit(tones)]))
            for wall in WallSide.allCases {
                defs.append(SpriteDef(key: SpriteKey("postit.mini", variant: variant, facing: wall == .ne ? .ne : .nw),
                                      category: .deskItems, anchor: PixelPoint(4, 12),
                                      frames: [Draw.shearToWall(miniPostitFront(tones), wall: wall)]))
            }
        }
        for count in 1...3 {
            defs.append(SpriteDef(key: SpriteKey("desk.queue", variant: "\(count)"), category: .deskItems,
                                  anchor: PixelPoint(5, 8), frames: [queue(count)]))
        }
        return defs.sorted { $0.key < $1.key }
    }()

    // MARK: Keyboard and papers

    static let keyboardHeight = 2
    static let papersHeight = 2
    static let paperRamp = Ramp(top: Palette.color(.chalk), left: Palette.color(.paper), right: Palette.color(.mist),
                                outline: Palette.color(.ink), highlight: Palette.color(.chalk))

    /// A box item: its image is exactly `Draw.isoBox` of its footprint in that facing, plus details on the top.
    static func boxItem(_ id: SpriteID, cells: (a: Range<Int>, b: Range<Int>), height: Int, ramp: Ramp, facing: Facing,
                        detail: (inout PixelImage, BitMask) -> Void) -> SpriteDef {
        let (w, d) = footprint(cells.a, cells.b, facing)
        let box = Draw.isoBox(w: w, d: d, height: height, ramp: ramp)
        var image = box.image
        // Inner top pixels: the top face minus the outline ring and the highlighted front edge.
        var inner = BitMask(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width where box.top[x, y] && image[x, y] == ramp.top { inner[x, y] = true }
        }
        detail(&image, inner)
        return SpriteDef(key: SpriteKey(id, facing: facing), category: .deskItems,
                         anchor: PixelPoint(w + d, w + d + height), frames: [image], lightProbe: box.lightProbe)
    }

    /// Key caps: mist dots on the dark top, every other pixel of every other 2:1 row (a dark keyboard, apart
    /// from the light papers).
    static func keyboardKeys(_ image: inout PixelImage, _ inner: BitMask) {
        for y in 0..<image.height {
            for x in 0..<image.width where inner[x, y] && (x + 2 * y) % 4 == 1 { image[x, y] = Palette.color(.mist) }
        }
    }

    /// Writing on the top sheet: mist dashes on every other row.
    static func paperLines(_ image: inout PixelImage, _ inner: BitMask) {
        for y in 0..<image.height {
            for x in 0..<image.width where inner[x, y] && y % 2 == 1 && x % 4 != 3 { image[x, y] = Palette.color(.mist) }
        }
    }

    // MARK: Mug

    static let mugHeight = 6
    static let mugRamp = Ramp(top: Palette.color(.paper), left: Palette.color(.paper), right: Palette.color(.mist),
                              outline: Palette.color(.ink), highlight: Palette.color(.chalk))

    /// The handle changes side with the facing: right on screen for ne and se, left for sw and nw.
    static func handleOnTheRight(_ facing: Facing) -> Bool { facing == .ne || facing == .se }
    static func mugBodyX(_ facing: Facing) -> Int { handleOnTheRight(facing) ? 0 : 2 }

    static func mug(facing: Facing, steam: Bool) -> SpriteDef {
        let rise = steam ? 6 : 0
        let body = Draw.isoBox(w: 1, d: 1, height: mugHeight, ramp: mugRamp)
        let x0 = mugBodyX(facing)
        var base = PixelImage(width: 6, height: 8 + rise)
        base.blit(body.image, x: x0, y: rise)
        let ink = Palette.color(.ink)
        let handle: [(Int, Int)] = handleOnTheRight(facing) ? [(4, 3), (5, 3), (5, 4), (5, 5), (4, 5)]
            : [(1, 3), (0, 3), (0, 4), (0, 5), (1, 5)]
        for (x, y) in handle { base[x, y + rise] = ink }
        let probe = SceneryKit.offset(body.lightProbe, by: PixelPoint(x0, rise))
        guard steam else {
            return SpriteDef(key: SpriteKey("mug", facing: facing), category: .deskItems, anchor: PixelPoint(3, 8),
                             frames: [base], lightProbe: probe)
        }
        // Two wisps rising and swaying above the mug, one step per frame.
        let wisps: [[(Int, Int, PaletteRole)]] = [
            [(2, 5, .mist), (3, 4, .chalk), (2, 3, .chalk), (3, 1, .mist)],
            [(3, 5, .mist), (2, 4, .chalk), (3, 2, .chalk), (2, 1, .chalk), (2, 0, .mist)],
            [(2, 4, .mist), (3, 3, .chalk), (3, 2, .mist), (2, 0, .chalk)],
        ]
        let frames = wisps.map { dots -> PixelImage in
            var frame = base
            for (x, y, role) in dots { frame[x, y] = Palette.color(role) }
            return frame
        }
        return SpriteDef(key: SpriteKey("mug", variant: "steam", facing: facing), category: .deskItems,
                         anchor: PixelPoint(3, 14), frames: frames, holds: AnimationClock.holds(fps: 4, frames: 3),
                         lightProbe: probe)
    }

    // MARK: Desk lamp

    static let lampAnchor = PixelPoint(6, 17)
    /// The base box (2×2 units, 2 px) has its top-left at (2, 12): its footprint's back corner is at (6, 14).
    static let lampBaseOrigin = PixelPoint(2, 12)
    static let lampBaseCorner = PixelPoint(6, 14)

    /// A post rising from the base, bent over: the shade hangs toward the clearance tile (+a), whose floor receives
    /// the light pool (décision 3), right on screen for ne and sw, left for se and nw. Both are drawn lit from the
    /// top left. `B` is the bulb.
    static let lampHeadRight = PixelMap("""
        ...oooo.....
        ..o3334oo...
        ..o4ooo33oo.
        ..o4o.o3344o
        ..o4o.o3444o
        ..o4o..oBBo.
        ..o4o...oo..
        ..o4o.......
        ..o4o.......
        ..o4o.......
        ..o4o.......
        .o444o......
        """, legend: ["B": .role(.lampWarm)])
    static let lampHeadLeft = PixelMap("""
        .....oooo...
        ...oo3334o..
        .oo33ooo4o..
        o3344o.o4o..
        o3444o.o4o..
        .oBBo..o4o..
        ..oo...o4o..
        .......o4o..
        .......o4o..
        .......o4o..
        .......o4o..
        ......o444o.
        """, legend: ["B": .role(.lampWarm)])

    static func lamp(facing: Facing, on: Bool) -> SpriteDef {
        var image = PixelImage(width: 12, height: 18)
        let base = Draw.isoBox(w: 2, d: 2, height: 2, ramp: FurnitureSprites.metal)
        image.blit(base.image, x: lampBaseOrigin.x, y: lampBaseOrigin.y)
        let map = facing == .ne || facing == .sw ? lampHeadRight : lampHeadLeft
        let bulb = Palette.color(on ? .lampWarm : .shade)
        image.blit(map.render { slot in slot == .role(.lampWarm) ? bulb : SlotPaint.decor(slot, hue: nil) }, x: 0, y: 0)
        return SpriteDef(key: SpriteKey("lamp.desk", variant: on ? "on" : "off", facing: facing), category: .deskItems,
                         anchor: lampAnchor, frames: [image], lightProbe: SceneryKit.offset(base.lightProbe, by: lampBaseOrigin))
    }

    // MARK: Post-its

    /// hue0 … hue9 (light face, base strip, dark edge), then the neutral `paper` post-it.
    static let postitTones: [(String, (light: RGBA8, base: RGBA8, dark: RGBA8))] =
        (0..<10).map { hue in
            let tones = Palette.hue(hue)
            return ("hue\(hue)", (tones.light, tones.base, tones.dark))
        } + [("paper", (Palette.color(.paper), Palette.color(.mist), Palette.color(.stone)))]

    /// 6×6, on a monitor: sticky strip on top, shaded right and bottom edges, a folded corner.
    static func deskPostit(_ tones: (light: RGBA8, base: RGBA8, dark: RGBA8)) -> PixelImage {
        paint(PixelMap("""
            BBBBBD
            LLLLLD
            LLLLLD
            LLLLLD
            LLLLBD
            DDDDD.
            """, legend: ["B": .hueBase, "L": .hueLight, "D": .hueDark]), tones)
    }

    /// 8×8 front of a mini post-it of the cork wall, sheared by the caller.
    static func miniPostitFront(_ tones: (light: RGBA8, base: RGBA8, dark: RGBA8)) -> PixelImage {
        paint(PixelMap("""
            BBBBBBBB
            BBBBBBBD
            LLLLLLLD
            LLLLLLLD
            LLLLLLLD
            LLLLLLLD
            LLLLLLBD
            DDDDDDDD
            """, legend: ["B": .hueBase, "L": .hueLight, "D": .hueDark]), tones)
    }

    private static func paint(_ map: PixelMap, _ tones: (light: RGBA8, base: RGBA8, dark: RGBA8)) -> PixelImage {
        map.render { slot in
            switch slot {
            case .hueBase: return tones.base
            case .hueLight: return tones.light
            case .hueDark: return tones.dark
            default: return nil
            }
        }
    }

    // MARK: Queue

    /// Sheets of 3×2 units, 1 px thick, stacked 1 px apart: sheet k (from the desk) is drawn at row 2 − k.
    static let queueCorner = PixelPoint(4, 3)
    static let queueRamps: [Ramp] = [
        Ramp(top: Palette.color(.paper), left: Palette.color(.mist), right: Palette.color(.stone),
             outline: Palette.color(.slate), highlight: Palette.color(.paper)),
        Ramp(top: Palette.color(.chalk), left: Palette.color(.mist), right: Palette.color(.stone),
             outline: Palette.color(.slate), highlight: Palette.color(.chalk)),
    ]

    static func queue(_ count: Int) -> PixelImage {
        var image = PixelImage(width: 10, height: 8)
        for k in 0..<count {
            let sheet = Draw.isoBox(w: 3, d: 2, height: 1, ramp: queueRamps[k % 2])
            image.blit(sheet.image, x: 0, y: 2 - k)
        }
        return image
    }
}
