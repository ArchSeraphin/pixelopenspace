import Foundation

/// The two back walls and what stands on them (7.4.2). Facings name the wall (3.8): `ne` runs along j = 0 and turns
/// its face toward +j (left tone of `Ramp.wall`, lit), `nw` runs along i = 0 and faces +i (right tone, darker).
///
/// A wall piece of width W (a multiple of 32: one tile edge per 32 px) is W / 2 + 96 px tall: every column holds
/// 96 rows (an 8-row cap, the wall top seen 4 units thick, then the face, a wooden baseboard and the floor line),
/// shifted 1 px per column pair to follow the floor edge (ne: down to the right, nw: down to the left). Its anchor
/// is the floor point under its middle, (W / 2, W / 4 + 96): (16, 104) for a segment. Wall objects (window, socket,
/// convector, cork board, elevator doors) are drawn from the front, then sheared with `Draw.shearToWall`.
///
/// Écarts to 7.4: `elevator` is anchored at (32, 112), the floor point under the middle of its 2 tiles, like
/// (16, 104) for one tile; `board.cork` is a 6-tile wall piece, 192×192 anchored at (96, 144), so that 4 rows of
/// 12 sheared mini post-its fit on it (décision 8).
public enum WallSprites {
    public static func all() -> [SpriteDef] { catalog }

    /// The 48 slots of the cork board of that wall, row-major (4 rows of 12): where `postit.mini`'s anchor goes, in
    /// px from the top-left of `board.cork` for that wall.
    public static func boardSlots(wall: WallSide) -> [PixelPoint] {
        var slots: [PixelPoint] = []
        for row in 0..<boardRows {
            for column in 0..<boardColumns {
                let front = boardSlotFront(row: row, column: column)
                let x = boardX + front.x
                let top = shearedTop(x: x, childWidth: 8, pieceWidth: boardWidth, wall: wall) + boardRow + front.y
                slots.append(PixelPoint(x + 4, top + 12))
            }
        }
        return slots
    }

    /// Where `elevator.led`'s anchor goes, in px from the top-left of `elevator`: on the dark housing above the doors.
    public static let elevatorLEDPoint: PixelPoint = {
        let doors = elevatorDoorsOrigin
        let x = doors.x + ledFront.x
        let y = doors.y + ledFront.y + (doorsFrontWidth - ledFront.x - ledWidth) / 2
        return PixelPoint(x + 3, y + 8)
    }()

    // MARK: Catalog

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        for wall in WallSide.allCases {
            let facing: Facing = wall == .ne ? .ne : .nw
            for style in ["plain", "socket", "baseboard"] {
                defs.append(SpriteDef(key: SpriteKey("wall.segment", variant: style, facing: facing), category: .walls,
                                      anchor: segmentAnchor, frames: [segment(style, wall: wall)]))
            }
            for sky in ["day", "dusk", "night"] {
                defs.append(SpriteDef(key: SpriteKey("wall.window", variant: sky, facing: facing), category: .walls,
                                      anchor: segmentAnchor, frames: [window(sky, wall: wall)]))
            }
            defs.append(SpriteDef(key: SpriteKey("board.cork", facing: facing), category: .walls,
                                  anchor: PixelPoint(boardWidth / 2, boardWidth / 4 + columnRows), frames: [board(wall: wall)]))
        }
        defs.append(SpriteDef(key: SpriteKey("wall.corner"), category: .walls, anchor: PixelPoint(8, 104), frames: [corner()]))
        defs.append(pillar())
        defs.append(elevator())
        defs.append(SpriteDef(key: SpriteKey("elevator.led"), category: .walls, anchor: PixelPoint(3, 8),
                              frames: [led(lit: true), led(lit: false)], holds: AnimationClock.holds(fps: 2, frames: 2)))
        return defs.sorted { $0.key < $1.key }
    }()

    // MARK: Wall pieces

    static let columnRows = 96
    static let capRows = 8
    static let segmentAnchor = PixelPoint(16, 104)

    /// Rows a column moves down at x on a piece `width` wide (the floor edge, 2:1).
    static func shift(_ x: Int, width: Int, wall: WallSide) -> Int { wall == .ne ? x / 2 : (width - 1 - x) / 2 }

    static func faceTone(_ wall: WallSide) -> RGBA8 { wall == .ne ? Ramp.wall.left : Ramp.wall.right }

    /// Row r (0 ..< 96) of every column: outline, cap, face, baseboard (lit edge, then wood), floor line.
    static func columnTone(_ r: Int, wall: WallSide) -> RGBA8 {
        switch r {
        case 0, columnRows - 1: return Palette.color(.ink)
        case 1..<capRows: return Ramp.wall.top
        case columnRows - 5: return Palette.color(wall == .ne ? .woodLight : .woodMid)
        case (columnRows - 4)..<(columnRows - 1): return Palette.color(wall == .ne ? .woodMid : .woodDark)
        default: return faceTone(wall)
        }
    }

    static func piece(width: Int, wall: WallSide) -> PixelImage {
        var image = PixelImage(width: width, height: width / 2 + columnRows)
        for x in 0..<width {
            let s = shift(x, width: width, wall: wall)
            for r in 0..<columnRows { image[x, s + r] = columnTone(r, wall: wall) }
        }
        return image
    }

    /// Top row of the sheared image of a front child `childWidth` wide whose column 0 is on piece column x
    /// (x and the widths even), for row 0 at the top of the columns.
    static func shearedTop(x: Int, childWidth: Int, pieceWidth: Int, wall: WallSide) -> Int {
        wall == .ne ? shift(x, width: pieceWidth, wall: wall) : shift(x + childWidth - 1, width: pieceWidth, wall: wall)
    }

    /// Pastes a front-drawn object on a piece: column 0 on piece column x (even), row 0 `row` px under the top of
    /// the columns.
    static func paste(_ front: PixelImage, on piece: inout PixelImage, x: Int, row: Int, wall: WallSide) {
        precondition(x % 2 == 0 && front.width % 2 == 0 && piece.width % 2 == 0, "even placement keeps 2:1 steps aligned")
        let y = row + shearedTop(x: x, childWidth: front.width, pieceWidth: piece.width, wall: wall)
        precondition(x + front.width <= piece.width && row + front.height <= columnRows, "object off the wall piece")
        piece.blit(Draw.shearToWall(front, wall: wall), x: x, y: y)
    }

    // MARK: Segments

    static func segment(_ style: String, wall: WallSide) -> PixelImage {
        var image = piece(width: 32, wall: wall)
        switch style {
        case "socket": paste(socket, on: &image, x: 12, row: 80, wall: wall)
        case "baseboard": paste(convector, on: &image, x: 4, row: 82, wall: wall)
        default: break
        }
        return image
    }

    /// A power socket: plate lit from the top left, two holes.
    static let socket = PixelMap("""
        122223
        2o22o3
        2o22o3
        222223
        333334
        """).renderDecor()

    /// A low convector along the baseboard: chalk top, mist body with slate slats.
    static let convector: PixelImage = {
        var image = PixelImage(width: 24, height: 8, fill: Palette.color(.mist))
        for x in 0..<24 {
            image[x, 0] = Palette.color(.chalk)
            image[x, 7] = Palette.color(.slate)
            for y in 2..<6 where x % 3 == 2 { image[x, y] = Palette.color(.slate) }
        }
        for y in 0..<8 { image[23, y] = Palette.color(.slate) }
        return image
    }()

    // MARK: Windows

    static let windowSize = (width: 20, height: 40)

    static func window(_ sky: String, wall: WallSide) -> PixelImage {
        var image = piece(width: 32, wall: wall)
        paste(windowFront(sky, wall: wall), on: &image, x: 6, row: 18, wall: wall)
        return image
    }

    /// Frame lit from the top left (lighter on the lit wall), mullion and transom, the frame's shadow along the top
    /// and left of the pane, a sill. Day: clouds; dusk: bands from blue to warm; night: plain (the compositor adds
    /// the stars).
    static func windowFront(_ sky: String, wall: WallSide) -> PixelImage {
        let (w, h) = windowSize
        let frame = Palette.color(wall == .ne ? .chalk : .mist)
        let reveal = Palette.color(wall == .ne ? .mist : .stone)
        var image = PixelImage(width: w, height: h, fill: frame)
        let pane = 3..<(h - 6)
        for y in pane {
            for x in 3..<(w - 3) { image[x, y] = skyColor(sky, row: y - pane.lowerBound, rows: pane.count) }
        }
        for y in pane { image[9, y] = frame; image[10, y] = frame }
        for x in 3..<(w - 3) { image[x, 14] = frame; image[x, 15] = frame }
        for x in 3..<(w - 3) where x != 9 && x != 10 { image[x, 3] = reveal; image[x, 16] = reveal }
        for y in pane where y != 14 && y != 15 { image[3, y] = reveal; image[11, y] = reveal }
        if sky == "day" {
            for (x, y) in [(5, 6), (6, 6), (7, 6), (6, 5), (13, 21), (14, 21), (15, 21), (16, 21), (14, 20), (15, 20)] {
                image[x, y] = Palette.color(.chalk)
            }
        }
        for x in 0..<w {
            image[x, h - 5] = Palette.color(.chalk)
            for y in (h - 4)..<(h - 1) { image[x, y] = Palette.color(.paper) }
        }
        return Draw.outline(image, color: Palette.color(.ink))
    }

    static func skyColor(_ sky: String, row: Int, rows: Int) -> RGBA8 {
        switch sky {
        case "day": return Palette.color(.skyDay)
        case "night": return Palette.color(.skyNight)
        default:
            let bands: [RGBA8] = [Palette.color(.uiTitle), Palette.color(.thinkLilac), Palette.hue(7).light,
                                  Palette.color(.lampWarm)]
            return bands[min(bands.count - 1, row * bands.count / rows)]
        }
    }

    // MARK: Corner and pillar

    /// The inside corner at the top vertex of tile (0, 0): the 8 columns of each wall around it (left: nw, right:
    /// ne), the same pixels as the two segments of that tile, plus a shaded seam on the nw side. Draw it after them.
    static func corner() -> PixelImage {
        var image = PixelImage(width: 16, height: 112)
        image.blit(piece(width: 32, wall: .nw).cropped(PixelRect(x: 24, y: 0, width: 8, height: 112)), x: 0, y: 8)
        image.blit(piece(width: 32, wall: .ne).cropped(PixelRect(x: 0, y: 0, width: 8, height: 112)), x: 8, y: 8)
        for r in capRows..<(columnRows - 5) { image[7, 8 + r] = Palette.color(.shade) }
        return image
    }

    /// A free-standing pillar: an 8×8-unit box 80 px tall, with a baseboard like the walls.
    static func pillar() -> SpriteDef {
        var canvas = SceneryKit.Canvas(width: 32, height: 96, anchor: PixelPoint(16, 88))
        let box = SceneryKit.Box(u: -4, v: -4, z: 0, w: 8, d: 8, height: 80)
        let drawn = Draw.isoBox(w: box.w, d: box.d, height: box.height, ramp: .wall)
        var image = drawn.image
        for (mask, light, wood) in [(drawn.left, PaletteRole.woodLight, PaletteRole.woodMid),
                                    (drawn.right, .woodMid, .woodDark)] {
            for x in 0..<image.width {
                guard let bottom = (0..<image.height).last(where: { mask[x, $0] }) else { continue }
                image[x, bottom - 4] = Palette.color(light)
                for y in (bottom - 3)..<bottom { image[x, y] = Palette.color(wood) }
            }
        }
        let o = canvas.origin(of: box)
        canvas.image.blit(image, x: o.x, y: o.y)
        let probe = SceneryKit.offset(drawn.lightProbe, by: o)
        let trimmed = LightProbe(left: PixelRect(x: probe.left.x, y: probe.left.y, width: probe.left.width, height: 40),
                                 right: PixelRect(x: probe.right.x, y: probe.right.y, width: probe.right.width, height: 40))
        return SpriteDef(key: SpriteKey("pillar"), category: .walls, anchor: canvas.anchor, frames: [canvas.image],
                         lightProbe: trimmed)
    }

    // MARK: Elevator

    /// The portal stands 2 units out of the nw wall over 24 units (most of the two tiles), 76 px tall.
    static let portal = SceneryKit.Box(u: 0, v: -12, z: 0, w: 2, d: 24, height: 76)
    static let portalRamp = Ramp(top: Palette.color(.chalk), left: Palette.color(.mist), right: Palette.color(.stone),
                                 outline: Palette.color(.ink), highlight: Palette.color(.chalk))
    static let elevatorAnchor = PixelPoint(32, 112)
    static let doorsFrontWidth = 40
    static let doorsColumn = 4
    static let doorsRow = 2
    static let ledWidth = 6
    /// The LED's front top-left in the doors' front image (on the housing, x even).
    static let ledFront = PixelPoint(16, 4)

    /// Top-left of the sheared doors image in the elevator sprite.
    static let elevatorDoorsOrigin: PixelPoint = {
        let canvas = SceneryKit.Canvas(width: 64, height: 128, anchor: elevatorAnchor)
        let o = canvas.origin(of: portal)
        return PixelPoint(o.x + 2 * portal.w + doorsColumn,
                          o.y + doorsRow + portal.w + 1 + (2 * portal.d - doorsColumn - doorsFrontWidth) / 2)
    }()

    static func elevator() -> SpriteDef {
        var frames: [PixelImage] = []
        var probe = LightProbe(left: PixelRect(x: 0, y: 0, width: 0, height: 0), right: PixelRect(x: 0, y: 0, width: 0, height: 0))
        for k in 0..<6 {
            var canvas = SceneryKit.Canvas(width: 64, height: 128, anchor: elevatorAnchor)
            canvas.image = piece(width: 64, wall: .nw)
            let boxProbe = canvas.box(portal, ramp: portalRamp)
            let at = canvas.paste(doorsFront(opening: k), on: portal, face: .right, column: doorsColumn, row: doorsRow)
            precondition(at == elevatorDoorsOrigin, "doors origin")
            // Left: the lit jamb (the box's own probe); right: the bare face left of the doors.
            let o = canvas.origin(of: portal)
            probe = LightProbe(left: boxProbe.left,
                               right: PixelRect(x: o.x + 2 * portal.w + 1, y: o.y + portal.w + 1 + portal.d + 4, width: 2, height: 40))
            frames.append(canvas.image)
        }
        return SpriteDef(key: SpriteKey("elevator", facing: .nw), category: .walls, anchor: elevatorAnchor, frames: frames,
                         holds: AnimationClock.holds(fps: 12, frames: 6), loops: false, lightProbe: probe)
    }

    /// Front of the doors (40×72): slate jamb, two mist doors that slide 3 px a frame into the walls, the shade
    /// interior with its floor, the dark LED housing above, a call button on the right.
    static func doorsFront(opening k: Int) -> PixelImage {
        var image = PixelImage(width: doorsFrontWidth, height: 72)
        let slate = Palette.color(.slate), mist = Palette.color(.mist), chalk = Palette.color(.chalk)
        image.fill(PixelRect(x: 2, y: 12, width: 36, height: 60), slate)
        image.fill(PixelRect(x: 4, y: 14, width: 32, height: 58), Palette.color(.shade))
        image.fill(PixelRect(x: 4, y: 69, width: 32, height: 3), Palette.color(.stone))
        let shift = 3 * k
        for (from, to) in [(4, 19 - shift), (20 + shift, 35)] where from <= to {
            image.fill(PixelRect(x: from, y: 14, width: to - from + 1, height: 58), mist)
            for y in 14..<72 { image[from, y] = chalk }
        }
        if shift < 16 {
            for y in 14..<72 { image[19 - shift, y] = slate; image[20 + shift, y] = slate }
        }
        image.fill(PixelRect(x: 14, y: 3, width: 10, height: 8), Palette.color(.ink))
        image.fill(PixelRect(x: 37, y: 36, width: 2, height: 6), Palette.color(.ink))
        image[37, 38] = chalk
        return image
    }

    /// Lit: a lampWarm arrow pointing up; off: the same arrow in stone. Front 6×5, sheared for the nw wall.
    static func led(lit: Bool) -> PixelImage {
        let front = PixelMap("""
            ..ww..
            .wwww.
            wwwwww
            ..ww..
            ..ww..
            """).render { slot in slot == .clear ? nil : Palette.color(lit ? .lampWarm : .stone) }
        return Draw.shearToWall(front, wall: .nw)
    }

    // MARK: Cork board

    static let boardWidth = 192
    static let boardX = 4
    static let boardRow = 16
    static let boardRows = 4
    static let boardColumns = 12
    static let boardFrontSize = (width: 184, height: 60)

    /// Top-left of slot (row, column) in the board's front image: 8×8 post-its, 14 px apart across, 12 down.
    static func boardSlotFront(row: Int, column: Int) -> PixelPoint { PixelPoint(10 + 14 * column, 8 + 12 * row) }

    static func board(wall: WallSide) -> PixelImage {
        var image = piece(width: boardWidth, wall: wall)
        paste(boardFront(), on: &image, x: boardX, row: boardRow, wall: wall)
        return image
    }

    /// Wooden frame lit from the top left around cork mottled with woodMid and woodDark, plain cork under the slots.
    static func boardFront() -> PixelImage {
        let (w, h) = boardFrontSize
        var image = PixelImage(width: w, height: h, fill: Palette.color(.woodMid))
        for x in 1..<(w - 1) { image[x, 1] = Palette.color(.woodLight) }
        for y in 1..<(h - 1) { image[1, y] = Palette.color(.woodLight) }
        for x in 1..<(w - 1) { image[x, h - 2] = Palette.color(.woodDark) }
        for y in 2..<(h - 1) { image[w - 2, y] = Palette.color(.woodDark) }
        var slots = BitMask(width: w, height: h)
        for row in 0..<boardRows {
            for column in 0..<boardColumns {
                let p = boardSlotFront(row: row, column: column)
                for y in p.y..<(p.y + 8) { for x in p.x..<(p.x + 8) { slots[x, y] = true } }
            }
        }
        for y in 4..<(h - 4) {
            for x in 4..<(w - 4) {
                image[x, y] = Palette.color(slots[x, y] ? .cork : corkSpeck(x, y))
            }
        }
        for y in 3..<(h - 3) { image[3, y] = Palette.color(.woodDark) }
        for x in 3..<(w - 3) { image[x, 3] = Palette.color(.woodDark) }
        return Draw.outline(image, color: Palette.color(.hairDark))
    }

    /// Mottled cork (7.1): an integer hash of the position, about one pixel in eight a woodMid or woodDark speck.
    static func corkSpeck(_ x: Int, _ y: Int) -> PaletteRole {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        switch h % 24 {
        case 0, 1: return .woodMid
        case 2: return .woodDark
        default: return .cork
        }
    }
}
