import Foundation

/// State overlays, bubbles, tool icons and badges shown above an agent (7.4.5). Each state has its own shape
/// (7.9: never colour alone); alertYellow only appears in the waiting sprites. Overlays stay above the night veil.
public enum OverlaySprites {
    public static func all() -> [SpriteDef] { catalog }

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        let bang = bangFrames()
        defs.append(overlay("ov.bang", anchor: PixelPoint(6, 24), frames: bang, fps: 8))
        defs.append(overlay("ov.bang", variant: "xl", anchor: PixelPoint(12, 48), frames: bang.map { $0.scaled(by: 2) }, fps: 8))
        defs.append(overlay("ov.bang.halo", anchor: PixelPoint(16, 16), frames: [halo(0), halo(1)], fps: 4))
        defs.append(overlay("ov.dots", anchor: PixelPoint(10, 14), frames: (0..<3).map(dots), fps: 3))
        for icon in ToolIcon.allCases {
            defs.append(overlay(icon.spriteID, anchor: PixelPoint(8, 16), frames: [toolBubble(icon)]))
        }
        defs.append(overlay("ov.zzz", anchor: PixelPoint(4, 16), frames: (0..<3).map(zzz), fps: 2))
        defs.append(overlay("ov.storm", anchor: PixelPoint(14, 18), frames: (0..<4).map(storm), fps: 6))
        defs.append(overlay("ov.check", anchor: PixelPoint(6, 12), frames: checkFrames(), fps: 12, loops: false))
        defs.append(overlay("ov.stale", anchor: PixelPoint(5, 14), frames: [stale(lift: 0), stale(lift: 1)], fps: 2))
        defs.append(overlay("ov.background", anchor: PixelPoint(6, 16), frames: (0..<4).map(hourglass), fps: 2))
        defs.append(overlay("ov.quota", anchor: PixelPoint(7, 14), frames: [quota(0), quota(1)], fps: 1))
        defs.append(overlay("ov.draft", anchor: PixelPoint(5, 10), frames: [draft()]))
        defs.append(overlay("ov.edgeArrow", anchor: PixelPoint(8, 8), frames: [edgeArrow(lift: 0), edgeArrow(lift: 1)], fps: 4))
        defs.append(overlay("ov.degraded", anchor: PixelPoint(6, 12), frames: [degraded()]))
        defs.append(overlay("ov.unsafe", anchor: PixelPoint(6, 12), frames: [unsafe()]))
        defs.append(overlay("ov.external", anchor: PixelPoint(6, 12), frames: [external()]))
        defs.append(overlay("ov.selection", anchor: PixelPoint(18, 9), frames: [selection(0), selection(1)], fps: 3))
        return defs.sorted { $0.key < $1.key }
    }()

    private static func overlay(_ id: SpriteID, variant: String? = nil, anchor: PixelPoint, frames: [PixelImage],
                                fps: Double = 0, loops: Bool = true) -> SpriteDef {
        SpriteDef(key: SpriteKey(id, variant: variant), category: .overlays, anchor: anchor, frames: frames,
                  holds: AnimationClock.holds(fps: fps, frames: frames.count), loops: loops)
    }

    private static let yellow = Palette.color(.alertYellow)
    private static let orange = Palette.color(.alertOrange)
    private static let ink = Palette.color(.ink)
    private static let chalk = Palette.color(.chalk)

    // MARK: Waiting: "!", its halo

    /// The "!": alertYellow, alertOrange outline, a chalk highlight down the left (light from the top left).
    private static let bangGlyph = OverlayArt.map([
        "...YYYYYY...",
        "..Y1yyyyyY..",
        ".Y1yyyyyyyY.",
        ".Y1yyyyyyyY.",
        ".Y1yyyyyyyY.",
        "..Y1yyyyyY..",
        "..Y1yyyyyY..",
        "..Y1yyyyyY..",
        "...Y1yyyY...",
        "...Y1yyyY...",
        "...Y1yyyY...",
        "....YyyY....",
        ".....YY.....",
        "............",
        "............",
        "....YYYY....",
        "...Y1yyyY...",
        "...Y1yyyY...",
        "...YyyyyY...",
        "....YYYY....",
    ])

    /// Bounce: resting on the anchor line (key pose), then 2 and 4 px up, then 2 px up.
    private static func bangFrames() -> [PixelImage] {
        [0, 2, 4, 2].map { lift in
            var image = PixelImage(width: 12, height: 24)
            image.blit(bangGlyph, x: 0, y: 24 - bangGlyph.height - lift)
            return image
        }
    }

    /// A 2-px yellow ring and a dotted orange ring that pulse outward.
    private static func halo(_ frame: Int) -> PixelImage {
        var image = PixelImage(width: 32, height: 32)
        let (inner, outer) = frame == 0 ? (22, 28) : (26, 32)
        let dotted = OverlayArt.ring(diameter: outer, thickness: 1)
        OverlayArt.paint(dotted, into: &image, at: OverlayArt.centred(outer, in: 32), color: orange) { ($0 + $1) % 2 == 0 }
        OverlayArt.paint(OverlayArt.ring(diameter: inner, thickness: 2), into: &image, at: OverlayArt.centred(inner, in: 32),
                         color: yellow)
        return image
    }

    // MARK: Thinking

    /// Lilac thought bubble, its dots lighting up one by one; frame 0 shows the full "…".
    private static func dots(_ frame: Int) -> PixelImage {
        let lit = [3, 1, 2][frame]
        var rows = [
            "...oooooooooooooo...",
            "..ovvvvvvvvvvvvvvo..",
            ".ovvvvvvvvvvvvvvvvo.",
            ".ovvvvvvvvvvvvvvvvo.",
            ".ovvv11vv22vv33vvvo.",
            ".ovvv11vv22vv33vvvo.",
            ".ovvvvvvvvvvvvvvvvo.",
            ".ovvvvvvvvvvvvvvvvo.",
            "..ovvvvvvvvvvvvvvo..",
            "...oooooooooooooo...",
            "....................",
            ".........oo.........",
            "........ovvo........",
            ".........oo.........",
        ]
        rows = rows.map { row in
            String(row.map { c -> Character in
                guard let index = Int(String(c)), (1...3).contains(index) else { return c }
                return index <= lit ? "D" : "v"
            })
        }
        return OverlayArt.map(rows, legend: ["D": .role(.chalk)])
    }

    // MARK: Tools

    /// The white bubble of every tool icon: body 16×13, tail toward the head; the icon goes at (2, 1), 12×12.
    private static let bubble = OverlayArt.map([
        "..oooooooooooo..",
        ".o111111111111o.",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        "o11111111111111o",
        ".o111111111111o.",
        "..ooooo11ooooo..",
        "......o11o......",
        ".......oo.......",
    ])

    private static func toolBubble(_ icon: ToolIcon) -> PixelImage {
        var image = bubble
        image.blit(toolIcon(icon), x: 2, y: 1)
        return image
    }

    /// Generic, original pictograms (12×12): sheet, pencil, prompt, magnifier, globe, figure, plug, "?", gear.
    static func toolIcon(_ icon: ToolIcon) -> PixelImage {
        switch icon {
        case .read:
            return OverlayArt.map([
                "..oooooo....",
                "..o6666oo...",
                "..o6666o2o..",
                "..o6666oooo.",
                "..o6666666o.",
                "..o6444446o.",
                "..o6666666o.",
                "..o6444466o.",
                "..o6666666o.",
                "..o6444446o.",
                "..o6666666o.",
                "..ooooooooo.",
            ])
        case .edit:
            return OverlayArt.pencil(size: 12)
        case .bash:
            return OverlayArt.map([
                "............",
                "oooooooooooo",
                "o3333333333o",
                "o5555555555o",
                "o5g55555555o",
                "o55g5555555o",
                "o555g555555o",
                "o55g5555555o",
                "o5g55ggg555o",
                "o5555555555o",
                "oooooooooooo",
                "............",
            ])
        case .search:
            return OverlayArt.map([
                "..oooo......",
                ".o11kko.....",
                "o1kkkkko....",
                "o1kkkkko....",
                "okkkkkko....",
                "okkkkkko....",
                ".okkkkoo....",
                "..oooo99o...",
                "......o99o..",
                ".......o99o.",
                "........o99o",
                ".........oo.",
            ])
        case .web:
            return OverlayArt.map([
                "....oooo....",
                "..ook1kkoo..",
                ".okffkkkkko.",
                ".offffkkffo.",
                "okffffkkfffo",
                "okkfffkkkffo",
                "okkkfkkkkkko",
                "okkkkkfffkko",
                ".okkkkffffo.",
                ".okkkkkffko.",
                "..ookkkkoo..",
                "....oooo....",
            ])
        case .subagent:
            return OverlayArt.map([
                "....oooo....",
                "...ommmmo...",
                "...oxxxxo...",
                "...oxxxxo...",
                "....oooo....",
                "...oBBBBo...",
                "..oBBBBBBo..",
                "..oBoBBoBo..",
                "...oBBBBo...",
                "...o4oo4o...",
                "...o4oo4o...",
                "...oo..oo...",
            ], legend: ["x": .role(.skin1), "B": .role(.uiTitle)])
        case .mcp:
            return OverlayArt.map([
                "..ooo..ooo..",
                "..o2o..o2o..",
                "..o2o..o2o..",
                ".oooooooooo.",
                ".o22333334o.",
                ".o23333334o.",
                ".o23333334o.",
                ".oo333333oo.",
                "..oo3333oo..",
                "....o33o....",
                "....o44o....",
                "....o44o....",
            ])
        case .question:
            return OverlayArt.map([
                "...oooooo...",
                "..okBBBBBo..",
                ".okBoooBBBo.",
                ".oBo...oBBo.",
                ".ooo..oBBBo.",
                ".....oBBBo..",
                "....oBBBo...",
                "....oBBo....",
                "....oooo....",
                "....oooo....",
                "....oBBo....",
                "....oooo....",
            ], legend: ["B": .role(.uiTitle)])
        case .other:
            return OverlayArt.gear()
        }
    }

    // MARK: Asleep, error, done, no news

    /// "Z z z" rising up-right, chalk with an ink outline; frame 0 shows all three, then they appear one by one.
    private static func zzz(_ frame: Int) -> PixelImage {
        let letters: [(glyph: [String], at: PixelPoint)] = [
            (["###", ".#.", "###"], PixelPoint(0, 11)),
            (["####", "..#.", ".#..", "####"], PixelPoint(4, 6)),
            (["#####", "...#.", "..#..", ".#...", "#####"], PixelPoint(9, 0)),
        ]
        let shown = [3, 1, 2][frame]
        var image = PixelImage(width: 16, height: 16)
        for (glyph, at) in letters.prefix(shown).reversed() {
            image.blit(PixelFont.ringed(OverlayArt.glyph(glyph, color: chalk), color: ink), x: at.x, y: at.y)
        }
        return image
    }

    /// A storm cloud, lit from the top left, and a red bolt. Frames: bolt, flash, then rain twice.
    private static func storm(_ frame: Int) -> PixelImage {
        var image = PixelImage(width: 28, height: 18)
        image.blit(cloud(flash: frame == 1), x: 0, y: 0)
        switch frame {
        case 0, 1:
            image.blit(bolt(flash: frame == 1), x: 10, y: 8)
        default:
            let drops = frame == 2 ? [(7, 13), (13, 15), (19, 13)] : [(10, 14), (16, 13), (21, 15)]
            for (x, y) in drops {
                image[x, y] = Palette.color(.skyDay)
                image[x, y + 1] = Palette.color(.skyDay)
                image[x - 1, y + 2] = Palette.color(.skyDay)
            }
        }
        return image
    }

    /// Three overlapping puffs and a flat base, 26×11, ringed with ink to 28×13.
    private static func cloud(flash: Bool) -> PixelImage {
        let puffs: [(cx: Int, cy: Int, r: Int)] = [(14, 14, 10), (26, 10, 12), (38, 14, 10)]   // doubled coordinates
        var body = PixelImage(width: 26, height: 11)
        for v in 0..<11 {
            for u in 0..<26 {
                let inPuff = puffs.contains { p in
                    let dx = 2 * u + 1 - p.cx, dy = 2 * v + 1 - p.cy
                    return dx * dx + dy * dy <= p.r * p.r
                }
                let inBase = u >= 3 && u <= 22 && v >= 7
                guard inPuff || inBase else { continue }
                let role: PaletteRole
                if v >= 8 { role = flash ? .mist : .slate }
                else if v + u / 4 <= 4 { role = .mist }
                else { role = .stone }
                body[u, v] = Palette.color(role)
            }
        }
        return PixelFont.ringed(body, color: ink)
    }

    private static func bolt(flash: Bool) -> PixelImage {
        var fill = OverlayArt.glyph([
            "...###",
            "..###.",
            ".###..",
            "######",
            "...##.",
            "..##..",
            ".##...",
            ".#....",
        ], color: Palette.color(.errorRed))
        if flash { for (x, y) in [(3, 1), (2, 2), (2, 3), (3, 3), (3, 4), (2, 5)] { fill[x, y] = chalk } }
        return PixelFont.ringed(fill, color: ink)
    }

    private static let check = OverlayArt.map([
        "............",
        "............",
        ".........FFF",
        "........F1GF",
        ".......FGGGF",
        "FFF...FGGGF.",
        "F1GF.FGGGF..",
        "FGGGFGGGF...",
        ".FGGGGGF....",
        "..FGGGF.....",
        "...FGF......",
        "....F.......",
    ])

    /// Pop: the check, the check with sparks, the check again (a one-shot that ends on the key pose).
    private static func checkFrames() -> [PixelImage] {
        var sparks = check
        for (x, y) in [(10, 0), (5, 2), (1, 3), (11, 7), (7, 10)] { sparks[x, y] = chalk }
        return [check, sparks, check]
    }

    /// "?" in mist with an ink outline, bobbing by 1 px.
    private static func stale(lift: Int) -> PixelImage {
        let glyph = OverlayArt.map([
            "..oooooo..",
            ".o112222o.",
            "o12ooo222o",
            "o2o..o222o",
            "ooo.o222o.",
            "...o222o..",
            "...o22o...",
            "...o22o...",
            "...oooo...",
            "...oooo...",
            "...o22o...",
            "...oooo...",
        ])
        var image = PixelImage(width: 10, height: 14)
        image.blit(glyph, x: 0, y: 14 - glyph.height - lift)
        return image
    }

    // MARK: Background task, usage limit, draft

    /// Hourglass between wooden caps; the sand runs down over 4 frames (frame 0 is mid-flow).
    private static func hourglass(_ frame: Int) -> PixelImage {
        // Interior span of each glass row (rows 4 to 11), then the sand of each frame.
        let spans: [Int: ClosedRange<Int>] = [4: 3...8, 5: 3...8, 6: 4...7, 7: 5...6, 8: 5...6, 9: 4...7, 10: 3...8, 11: 3...8]
        let sand: [[Int: ClosedRange<Int>]] = [
            [6: 4...7, 7: 5...6, 8: 5...5, 9: 5...5, 10: 5...5, 11: 3...8],
            [6: 5...6, 7: 5...6, 8: 5...5, 9: 5...5, 10: 4...7, 11: 3...8],
            [7: 5...6, 8: 5...5, 9: 4...7, 10: 3...8, 11: 3...8],
            [5: 3...8, 6: 4...7, 7: 5...6, 10: 5...6, 11: 4...7],
        ]
        var rows = [".oooooooooo.", ".o88888888o.", ".o99999999o.", ".oooooooooo."]
        for y in 4...11 {
            let span = spans[y]!
            var row = Array(repeating: Character("."), count: 12)
            row[span.lowerBound - 1] = "o"
            row[span.upperBound + 1] = "o"
            for x in span {
                if let grains = sand[frame][y], grains.contains(x) { row[x] = "w" }
                else { row[x] = x == span.lowerBound && y <= 6 ? "1" : "2" }
            }
            rows.append(String(row))
        }
        rows += [".oooooooooo.", ".o88888888o.", ".o99999999o.", ".oooooooooo."]
        return OverlayArt.map(rows)
    }

    /// Clock with a warm rim (the usage limit, never the storm): the minute hand moves.
    private static func quota(_ frame: Int) -> PixelImage {
        let minute: [PixelPoint] = frame == 0 ? [PixelPoint(7, 3), PixelPoint(7, 4), PixelPoint(7, 5)]
                                              : [PixelPoint(8, 5), PixelPoint(9, 4), PixelPoint(10, 3)]
        return OverlayArt.clock(diameter: 14, hands: minute + [PixelPoint(8, 7), PixelPoint(9, 7)])
    }

    /// "✎": a small pencil over a written line.
    private static func draft() -> PixelImage {
        var image = OverlayArt.pencil(size: 10)
        for x in 0...5 { image[x, 9] = Palette.color(.slate) }
        return image
    }

    // MARK: Off-screen arrow, signs, selection

    /// Pin pointing up with an ink "!", symmetric (the scene rotates it by 45° steps); nudges toward its tip.
    private static func edgeArrow(lift: Int) -> PixelImage {
        let glyph = OverlayArt.map([
            ".......YY.......",
            "......YyyY......",
            ".....YyyyyY.....",
            "....YyyyyyyY....",
            "...YyyyyyyyyY...",
            "..YyyyyyyyyyyY..",
            ".YyyyyyooyyyyyY.",
            ".YyyyyyooyyyyyY.",
            "YyyyyyyooyyyyyyY",
            "YyyyyyyooyyyyyyY",
            "YyyyyyyyyyyyyyyY",
            ".YyyyyyooyyyyyY.",
            ".YyyyyyyyyyyyyY.",
            "..YyyyyyyyyyyY..",
            "...YYYYYYYYYY...",
        ])
        var image = PixelImage(width: 16, height: 16)
        image.blit(glyph, x: 0, y: 1 - lift)
        return image
    }

    /// Degraded mode: an orange diamond sign with an ink zigzag (the state is only inferred).
    private static func degraded() -> PixelImage {
        OverlayArt.map([
            ".....oo.....",
            "....oYYo....",
            "...oYYYYo...",
            "..oYYYYYYo..",
            ".oYYoYYoYYo.",
            "oYYoYooYoYYo",
            "oYoYYYYYYoYo",
            ".oYYYYYYYYo.",
            "..oYYYYYYo..",
            "...oYYYYo...",
            "....oYYo....",
            ".....oo.....",
        ])
    }

    /// bypassPermissions: an open padlock, red body, the shackle lifted out on the right.
    private static func unsafe() -> PixelImage {
        OverlayArt.map([
            "...oooooo...",
            "..o222222o..",
            "..o2oooo2o..",
            "..o2o..o2o..",
            "..o2o..ooo..",
            "..o2o.......",
            ".oooooooooo.",
            ".o1rrrrrrro.",
            ".orrroorrro.",
            ".orrroorrro.",
            ".orrrrrrrro.",
            ".oooooooooo.",
        ])
    }

    /// External session: a paper box with a blue arrow leaving it toward the top right.
    private static func external() -> PixelImage {
        var image = PixelImage(width: 12, height: 12)
        // The box, x 0…7, y 4…11.
        image.blit(OverlayArt.map([
            "oooooooo",
            "o666666o",
            "o666666o",
            "o666666o",
            "o666666o",
            "o662222o",
            "o622222o",
            "oooooooo",
        ]), x: 0, y: 4)
        // The arrow: a 2-px shaft from the box centre, a corner head at the top right, ringed with ink.
        var arrow = PixelImage(width: 10, height: 10)
        let blue = Palette.color(.uiTitle), light = Palette.color(.skyDay)
        for (x, y) in [(3, 1), (4, 1), (5, 1), (6, 1), (6, 2), (6, 3), (6, 4)] { arrow[x + 1, y] = blue }
        for k in 0..<5 {
            arrow[1 + 5 - k, 2 + k] = k == 0 ? blue : light
            arrow[1 + 5 - k, 3 + k] = blue
        }
        image.blit(PixelFont.ringed(arrow, color: ink).cropped(PixelRect(x: 0, y: 0, width: 12, height: 12)), x: 1, y: -1)
        return image
    }

    /// Selection ring on the floor: the outline of the tile diamond, dashed chalk and ink, marching by one dash.
    private static func selection(_ frame: Int) -> PixelImage {
        let ring = OverlayArt.outerRing(Draw.isoDiamondMask(width: 36))
        var image = PixelImage(width: 36, height: 18)
        for y in 0..<ring.height {
            for x in 0..<ring.width where ring[x, y] {
                image[x, y] = (x / 4 + frame) % 2 == 0 ? chalk : ink
            }
        }
        return image
    }
}

/// Drawing helpers of the overlay, effect and HUD sprite sets.
enum OverlayArt {
    /// A decor map rendered with `SlotPaint.decor` (no project hue).
    static func map(_ rows: [String], legend: [Character: Slot] = [:]) -> PixelImage {
        PixelMap(rows.joined(separator: "\n"), legend: legend).renderDecor()
    }

    /// "#" cells in `color`, others clear.
    static func glyph(_ rows: [String], color: RGBA8) -> PixelImage {
        let width = rows[0].count
        var image = PixelImage(width: width, height: rows.count)
        for (y, row) in rows.enumerated() {
            precondition(row.count == width, "ragged glyph \(rows)")
            for (x, c) in row.enumerated() where c == "#" { image[x, y] = color }
        }
        return image
    }

    /// Integer disc filling diameter × diameter (Draw.ellipse).
    static func disc(diameter: Int) -> BitMask {
        Draw.ellipse(width: diameter, height: diameter, fill: Palette.color(.ink)).alphaMask()
    }

    /// Pixels of `mask` with a 4-neighbour outside it.
    static func outerRing(_ mask: BitMask) -> BitMask {
        var ring = BitMask(width: mask.width, height: mask.height)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] {
                if !mask[x - 1, y] || !mask[x + 1, y] || !mask[x, y - 1] || !mask[x, y + 1] { ring[x, y] = true }
            }
        }
        return ring
    }

    /// The `thickness` outer rings of a disc.
    static func ring(diameter: Int, thickness: Int) -> BitMask {
        var rest = disc(diameter: diameter)
        var band = BitMask(width: diameter, height: diameter)
        for _ in 0..<thickness {
            let outer = outerRing(rest)
            band = band.union(outer)
            rest = rest.subtracting(outer)
        }
        return band
    }

    /// Top-left that centres a `size` square in a `canvas` square.
    static func centred(_ size: Int, in canvas: Int) -> PixelPoint { PixelPoint((canvas - size) / 2, (canvas - size) / 2) }

    static func paint(_ mask: BitMask, into image: inout PixelImage, at origin: PixelPoint, color: RGBA8,
                      where keep: (Int, Int) -> Bool = { _, _ in true }) {
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] && keep(origin.x + x, origin.y + y) {
                image.set(origin.x + x, origin.y + y, color)
            }
        }
    }

    /// Round clock: ink outline, lampWarm rim, chalk face, slate hour marks, ink centre and hands.
    static func clock(diameter: Int, hands: [PixelPoint]) -> PixelImage {
        let face = disc(diameter: diameter)
        let outline = outerRing(face)
        let rim = outerRing(face.subtracting(outline))
        var image = PixelImage(width: diameter, height: diameter)
        paint(face, into: &image, at: PixelPoint(0, 0), color: Palette.color(.chalk))
        paint(rim, into: &image, at: PixelPoint(0, 0), color: Palette.color(.lampWarm))
        paint(outline, into: &image, at: PixelPoint(0, 0), color: Palette.color(.ink))
        let lo = diameter / 2 - 1, hi = diameter / 2, inner = 2, outer = diameter - 3
        for (x, y) in [(lo, inner), (hi, inner), (lo, outer), (hi, outer), (inner, lo), (inner, hi), (outer, lo), (outer, hi)] {
            image[x, y] = Palette.color(.slate)
        }
        for (x, y) in [(lo, lo), (hi, lo), (lo, hi), (hi, hi)] { image[x, y] = Palette.color(.ink) }
        for p in hands { image[p.x, p.y] = Palette.color(.ink) }
        return image
    }

    /// A pencil at 45°, eraser up-right, graphite tip down-left, in `size` × `size`: two diagonal lines
    /// x + y = size − 2 (lit) and size − 1, then a 4-neighbour ink outline.
    static func pencil(size: Int) -> PixelImage {
        let lit = size - 2
        let tMax = size / 2, tMin = -(size - 4)
        var fill = PixelImage(width: size, height: size)
        for t in tMin...tMax {
            for line in [lit, lit + 1] where (line + t) % 2 == 0 {
                let x = (line + t) / 2, y = line - x
                guard x >= 0, y >= 0, x < size, y < size else { continue }
                let shade = line != lit
                let role: PaletteRole
                switch t {
                case (tMax - 1)...: role = .errorRed                         // eraser
                case (tMax - 3)...: role = shade ? .stone : .mist             // ferrule
                case (tMin + 3)...: role = shade ? .uiTitle : .skyDay         // body
                case (tMin + 1)...: role = shade ? .woodMid : .woodLight      // sharpened wood
                default: role = .ink                                          // graphite
                }
                fill[x, y] = Palette.color(role)
            }
        }
        var out = fill
        for y in 0..<size {
            for x in 0..<size where fill[x, y].a == 0 {
                let near = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
                    nx >= 0 && ny >= 0 && nx < size && ny < size && fill[nx, ny].a != 0
                }
                if near { out[x, y] = Palette.color(.ink) }
            }
        }
        return out
    }

    /// Gear: a ring with 8 teeth around a hole, lit from the top left (mist, stone, slate), ink outline.
    static func gear() -> PixelImage {
        map([
            ".....oo.....",
            "..o.o22o.o..",
            ".o2oo22oo3o.",
            "..o222223o..",
            ".oo22oo33oo.",
            "o222o..o333o",
            "o223o..o344o",
            ".oo33oo34oo.",
            "..o333344o..",
            ".o3oo44oo4o.",
            "..o.o44o.o..",
            ".....oo.....",
        ])
    }
}
