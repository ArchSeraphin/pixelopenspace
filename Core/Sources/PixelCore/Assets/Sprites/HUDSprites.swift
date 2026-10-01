import Foundation

/// Labels and status glyphs of the scene (7.4.2, 7.4.10): island sign, desk nameplate, queue badge, status icons
/// and minimap pieces. Text is drawn with `PixelFont`, on a plate or with an ink outline (7.2); every state has its
/// own glyph, never colour alone (7.9).
public enum HUDSprites {
    /// Characters of a sign before the ellipsis (7.4.2).
    public static let signMaxCharacters = 10
    /// Rows of the sign board (the post and foot are below it).
    public static let signBoardHeight = 20
    public static let nameplateInsets = EdgeInsets(3)
    public static let minimapFrameInsets = EdgeInsets(4)
    public static let minimapViewportInsets = EdgeInsets(2)

    public static func all() -> [SpriteDef] { catalog }

    /// Island sign (front panel, never sheared): hue plate + name in chalk with an ink outline, fitted to 10 characters.
    public static func sign(name: String, hue: Int) -> PixelImage {
        var image = signPlate(hue: hue)
        let shown = PixelFont.fitted(PixelFont.normalized(name), maxCharacters: signMaxCharacters)
        guard !shown.isEmpty else { return image }
        let text = PixelFont.render(shown, color: chalk, outline: ink)
        // Centre the capitals and their outline (text rows 2…8) between the top highlight and the bottom bevel.
        let interiorTop = 2, interiorRows = signBoardHeight - 5
        let y = interiorTop + (interiorRows - (PixelFont.capHeight + 2)) / 2 - PixelFont.accentRows
        image.blit(text, x: (image.width - text.width) / 2, y: y)
        return image
    }

    /// desk.nameplate 9-slice sized to the text (chalk text on the plate); `off`: the "OFF" variant (greyed plate,
    /// mist text). Width: text + 3 + 3; height: the capitals (or the full line when the text has accents) + 3 + 3.
    public static func nameplate(_ text: String, off: Bool) -> PixelImage {
        let glyphs = PixelFont.render(text, color: Palette.color(off ? .mist : .chalk))
        let accented = (0..<PixelFont.accentRows).contains { y in (0..<glyphs.width).contains { glyphs[$0, y].a != 0 } }
        let top = accented ? 0 : PixelFont.accentRows
        let rows = PixelFont.lineHeight - top
        let insets = nameplateInsets
        let source = off ? nameplateOff : nameplateNormal
        var plate = source.nineSlice(insets: insets, width: glyphs.width + insets.left + insets.right,
                                     height: rows + insets.top + insets.bottom)
        plate.blit(glyphs, x: insets.left, y: insets.top - top)
        return plate
    }

    /// "1"…"9", then "plus" (counts below 1 show "1").
    public static func queueBadgeKey(count: Int) -> SpriteKey {
        SpriteKey("desk.queueBadge", variant: count >= 10 ? "plus" : "\(max(count, 1))")
    }

    /// "hud.state.<kind>".
    public static func stateKey(_ kind: AgentStateKind) -> SpriteKey { SpriteKey(SpriteID("hud.state.\(kind.rawValue)")) }

    /// "minimap.dot.<kind>".
    public static func minimapDotKey(_ kind: AgentStateKind) -> SpriteKey { SpriteKey(SpriteID("minimap.dot.\(kind.rawValue)")) }

    // MARK: Catalogue

    private static let chalk = Palette.color(.chalk)
    private static let ink = Palette.color(.ink)

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        for hue in 0..<Palette.projectHues.count {
            defs.append(SpriteDef(key: SpriteKey("sign.island", variant: "hue\(hue)"), category: .hud,
                                  anchor: PixelPoint(32, 38), frames: [signPlate(hue: hue)], lightProbe: postProbe))
        }
        defs.append(hud(SpriteKey("desk.nameplate", variant: "normal"), anchor: PixelPoint(8, 8), nameplateNormal))
        defs.append(hud(SpriteKey("desk.nameplate", variant: "off"), anchor: PixelPoint(8, 8), nameplateOff))
        for variant in (1...9).map(String.init) + ["plus"] {
            defs.append(hud(SpriteKey("desk.queueBadge", variant: variant), anchor: PixelPoint(4, 8), queueBadge(variant)))
        }
        for kind in AgentStateKind.allCases {
            defs.append(hud(stateKey(kind), anchor: PixelPoint(6, 12), stateIcon(kind)))
            defs.append(hud(minimapDotKey(kind), anchor: PixelPoint(2, 2), minimapDot(kind)))
        }
        defs.append(hud(SpriteKey("minimap.frame"), anchor: PixelPoint(0, 0), minimapFrame))
        defs.append(hud(SpriteKey("minimap.viewport"), anchor: PixelPoint(0, 0), minimapViewport))
        return defs.sorted { $0.key < $1.key }
    }()

    private static func hud(_ key: SpriteKey, anchor: PixelPoint, _ image: PixelImage) -> SpriteDef {
        SpriteDef(key: key, category: .hud, anchor: anchor, frames: [image])
    }

    // MARK: Island sign

    /// The post is a small lit volume: its left half stone, its right half slate.
    private static let postProbe = LightProbe(left: PixelRect(x: 30, y: 22, width: 2, height: 10),
                                              right: PixelRect(x: 32, y: 22, width: 2, height: 10))

    /// 64×40: a board in the project hue (dark outline, light top and left edges, dark bevel below and right),
    /// on a two-tone post standing on a small iso foot. No text.
    private static func signPlate(hue: Int) -> PixelImage {
        let tones = Palette.hue(hue)
        var image = PixelImage(width: 64, height: 40)
        let board = signBoardHeight
        for y in 0..<board {
            for x in 0..<64 {
                let corner = (x == 0 || x == 63) && (y == 0 || y == board - 1)
                if corner { continue }
                let color: RGBA8
                if x == 0 || x == 63 || y == 0 || y == board - 1 { color = tones.dark }
                else if y == board - 2 || x == 62 { color = tones.dark }
                else if y == 1 || x == 1 { color = tones.light }
                else { color = tones.base }
                image[x, y] = color
            }
        }
        // Foot: a flat neutral slab; the post stands on its centre.
        image.blit(Draw.isoBox(w: 3, d: 3, height: 1, ramp: .neutral).image, x: 26, y: 33)
        for y in board..<37 {
            image[29, y] = ink
            image[30, y] = Palette.color(.stone)
            image[31, y] = Palette.color(.stone)
            image[32, y] = Palette.color(.slate)
            image[33, y] = Palette.color(.slate)
            image[34, y] = ink
        }
        return image
    }

    // MARK: Desk labels

    private static let nameplateNormal = OverlayArt.map([
        ".oooooooooooooo.",
        "o44444444444444o",
        "o45555555555555o",
        "o45555555555555o",
        "o45555555555555o",
        "o45555555555555o",
        "oooooooooooooooo",
        ".oooooooooooooo.",
    ])

    private static let nameplateOff = OverlayArt.map([
        ".oooooooooooooo.",
        "o33333333333333o",
        "o34444444444444o",
        "o34444444444444o",
        "o34444444444444o",
        "o34444444444444o",
        "oooooooooooooooo",
        ".oooooooooooooo.",
    ])

    /// Round blue badge with a chalk digit (or "+").
    private static func queueBadge(_ variant: String) -> PixelImage {
        var image = OverlayArt.map([
            ".oooooo.",
            "oBBBBBBo",
            "oBBBBBBo",
            "oBBBBBBo",
            "oBBBBBBo",
            "oBBBBBBo",
            "oBBBBBBo",
            ".oooooo.",
        ], legend: ["B": .role(.uiTitle)])
        let label = PixelFont.render(variant == "plus" ? "+" : variant, color: chalk)
        image.blit(label, x: 2, y: 1 - PixelFont.accentRows)
        return image
    }

    // MARK: Status icons (12×12)

    private static func stateIcon(_ kind: AgentStateKind) -> PixelImage {
        switch kind {
        case .offline:
            return power()
        case .launching:
            // ⏏: the agent arrives by the elevator.
            var image = PixelImage(width: 12, height: 12)
            let eject = OverlayArt.glyph([
                "....##....",
                "...####...",
                "..######..",
                ".########.",
                "##########",
                "..........",
                "##########",
                "##########",
            ], color: Palette.color(.skyDay))
            image.blit(PixelFont.ringed(eject, color: ink), x: 0, y: 2)
            return image
        case .idle:
            var image = PixelImage(width: 12, height: 12)
            let big = OverlayArt.glyph(["#####", "...#.", "..#..", ".#...", "#####"], color: Palette.color(.mist))
            let small = OverlayArt.glyph(["####", "..#.", ".#..", "####"], color: Palette.color(.mist))
            image.blit(PixelFont.ringed(big, color: ink), x: 0, y: 5)
            image.blit(PixelFont.ringed(small, color: ink), x: 6, y: 0)
            return image
        case .thinking:
            return OverlayArt.map([
                "............",
                "..oooooooo..",
                ".ovvvvvvvvo.",
                "ovvvvvvvvvvo",
                "ov11v11v11vo",
                "ov11v11v11vo",
                "ovvvvvvvvvvo",
                ".ovvvvvvvvo.",
                "..oooooooo..",
                "...oo.......",
                "..ovvo......",
                "...oo.......",
            ])
        case .working:
            return OverlayArt.map([
                "oooooooooooo",
                "o5gggg55555o",
                "o5555555555o",
                "o555ggggg55o",
                "o5555555555o",
                "o555ggg1555o",
                "o5555555555o",
                "oooooooooooo",
                ".....oo.....",
                "....o33o....",
                "..oo3333oo..",
                "..oooooooo..",
            ])
        case .waitingInput:
            return OverlayArt.map([
                "...YYYYYY...",
                "...Y1yyyY...",
                "...Y1yyyY...",
                "...Y1yyyY...",
                "....YyyY....",
                "....YyyY....",
                "....YyyY....",
                ".....YY.....",
                "............",
                "....YYYY....",
                "....YyyY....",
                "....YYYY....",
            ])
        case .waitingBackground:
            return OverlayArt.map([
                ".oooooooooo.",
                ".o88888888o.",
                ".oooooooooo.",
                "..o1wwww2o..",
                "...o2ww2o...",
                "....owwo....",
                "....o2wo....",
                "...o2ww2o...",
                "..o2wwww2o..",
                ".oooooooooo.",
                ".o88888888o.",
                ".oooooooooo.",
            ])
        case .quotaPaused:
            return OverlayArt.clock(diameter: 12, hands: [PixelPoint(6, 3), PixelPoint(6, 4), PixelPoint(7, 6), PixelPoint(8, 6)])
        case .done:
            return OverlayArt.map([
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
        case .error:
            let cross = OverlayArt.glyph([
                "##......##",
                "###....###",
                ".###..###.",
                "..######..",
                "...####...",
                "...####...",
                "..######..",
                ".###..###.",
                "###....###",
                "##......##",
            ], color: Palette.color(.errorRed))
            return PixelFont.ringed(cross, color: ink)
        }
    }

    /// ⏻: a broken ring and a bar, in stone (offline).
    private static func power() -> PixelImage {
        let outer = OverlayArt.disc(diameter: 10)
        var inner = BitMask(width: 10, height: 10)
        let hole = OverlayArt.disc(diameter: 6)
        for y in 0..<6 { for x in 0..<6 where hole[x, y] { inner[x + 2, y + 2] = true } }
        var fill = PixelImage(width: 10, height: 10)
        for y in 0..<10 {
            for x in 0..<10 {
                let ring = outer[x, y] && !inner[x, y]
                let gap = (3...6).contains(x) && y <= 3
                let bar = (4...5).contains(x) && y <= 5
                if bar || (ring && !gap) { fill[x, y] = Palette.color(.stone) }
            }
        }
        return PixelFont.ringed(fill, color: ink)
    }

    // MARK: Minimap

    /// 5×5 glyph per state, so that a dot never relies on its colour (7.9).
    private static func minimapDot(_ kind: AgentStateKind) -> PixelImage {
        let rows: [String]
        switch kind {
        case .offline: rows = ["..3..", "3.3.3", "3...3", "3...3", ".333."]          // ⏻
        case .launching: rows = ["..k..", ".kkk.", "kkkkk", ".....", "kkkkk"]        // ⏏
        case .idle: rows = ["22222", "...2.", "..2..", ".2...", "22222"]             // z
        case .thinking: rows = [".vvv.", "vvvvv", "vvvvv", ".vvv.", "v...."]         // thought bubble
        case .working: rows = [".g.g.", "ggggg", ".g.g.", "ggggg", ".g.g."]          // #
        case .waitingInput: rows = [".yyY.", ".yyY.", "..y..", ".....", "..y.."]     // !
        case .waitingBackground: rows = ["88888", ".8w8.", "..w..", ".8w8.", "88888"] // ⧗
        case .quotaPaused: rows = [".www.", "w.w.w", "w.www", "w...w", ".www."]      // ◷
        case .done: rows = ["....G", "...GG", "G.GG.", "GGG..", ".G..."]             // ✓
        case .error: rows = ["rr.rr", ".rrr.", "..r..", ".rrr.", "rr.rr"]            // ✖
        }
        return OverlayArt.map(rows)
    }

    private static let minimapFrame = OverlayArt.map([
        ".oooooooooooooo.",
        "o11111111111112o",
        "o12222222222224o",
        "o12oooooooooo24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12o55555555o24o",
        "o12oooooooooo24o",
        "o12222222222244o",
        "o24444444444444o",
        ".oooooooooooooo.",
    ])

    private static let minimapViewport = OverlayArt.map([
        "oooooooo",
        "o111111o",
        "o1....1o",
        "o1....1o",
        "o1....1o",
        "o1....1o",
        "o111111o",
        "oooooooo",
    ])
}
