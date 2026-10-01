import Foundation
import Testing
@testable import PixelCore

@Suite struct HUDSpriteTests {
    static let all = HUDSprites.all()
    static let chalk = Palette.color(.chalk)
    static let ink = Palette.color(.ink)
    static let yellow = Palette.color(.alertYellow)

    static func def(_ key: SpriteKey) -> SpriteDef? { all.first { $0.key == key } }

    // MARK: Table

    @Test func sizesAnchorsAndFrames() throws {
        var expected: [(SpriteKey, Int, Int, PixelPoint)] = []
        for hue in 0..<10 { expected.append((SpriteKey("sign.island", variant: "hue\(hue)"), 64, 40, PixelPoint(32, 38))) }
        for variant in ["normal", "off"] { expected.append((SpriteKey("desk.nameplate", variant: variant), 16, 8, PixelPoint(8, 8))) }
        for variant in (1...9).map(String.init) + ["plus"] {
            expected.append((SpriteKey("desk.queueBadge", variant: variant), 8, 8, PixelPoint(4, 8)))
        }
        for kind in AgentStateKind.allCases {
            expected.append((HUDSprites.stateKey(kind), 12, 12, PixelPoint(6, 12)))
            expected.append((HUDSprites.minimapDotKey(kind), 5, 5, PixelPoint(2, 2)))
        }
        expected.append((SpriteKey("minimap.frame"), 16, 16, PixelPoint(0, 0)))
        expected.append((SpriteKey("minimap.viewport"), 8, 8, PixelPoint(0, 0)))
        for (key, width, height, anchor) in expected {
            let def = try #require(Self.def(key), "\(key.name) missing")
            #expect(def.width == width && def.height == height, "\(key.name): \(def.width)×\(def.height)")
            #expect(def.anchor == anchor, "\(key.name)")
            #expect(def.frames.count == 1 && def.holds.isEmpty, "\(key.name)")
            #expect(def.category == .hud, "\(key.name)")
        }
        #expect(Self.all.count == expected.count, "no sprite outside the table")
        let keys = Self.all.map(\.key)
        #expect(keys == keys.sorted() && Set(keys).count == keys.count)
        #expect(HUDSprites.stateKey(.waitingInput) == SpriteKey("hud.state.waitingInput"))
        #expect(HUDSprites.minimapDotKey(.quotaPaused) == SpriteKey("minimap.dot.quotaPaused"))
    }

    // MARK: Island sign

    @Test func signFitsTenCharacters() throws {
        for name in ["SITE WEB", "DOCUMENTATION", "API · 2", "WWWWWWWWWWWW", "ŒŒŒŒŒŒŒŒŒŒŒ"] {
            let shown = PixelFont.fitted(PixelFont.normalized(name), maxCharacters: HUDSprites.signMaxCharacters)
            #expect(shown.count <= 10)
            // Text plus its ink outline inside the board, clear of the 1-px board outline.
            #expect(PixelFont.width(of: shown) + 2 <= 62, "\(name): \(PixelFont.width(of: shown)) px")
            let sign = HUDSprites.sign(name: name, hue: 4)
            #expect(sign.width == 64 && sign.height == 40)
            let plate = try #require(Self.def(SpriteKey("sign.island", variant: "hue4"))).frames[0]
            // The name only adds chalk text and its ink outline, on the board.
            var changed: [PixelPoint] = []
            for y in 0..<sign.height {
                for x in 0..<sign.width where sign[x, y] != plate[x, y] {
                    #expect(sign[x, y] == Self.chalk || sign[x, y] == Self.ink, "\(name) (\(x), \(y))")
                    changed.append(PixelPoint(x, y))
                }
            }
            #expect(!changed.isEmpty)
            #expect(changed.allSatisfy { $0.x >= 1 && $0.x <= 62 && $0.y >= 1 && $0.y <= HUDSprites.signBoardHeight - 2 },
                    "\(name): text outside the board")
        }
        #expect(HUDSprites.sign(name: "api", hue: 4) == HUDSprites.sign(name: "API", hue: 4))
        #expect(HUDSprites.sign(name: "DOCUMENTATION", hue: 4) == HUDSprites.sign(name: "DOCUMENTA…", hue: 4))
        #expect(HUDSprites.sign(name: "API", hue: 4) != HUDSprites.sign(name: "API", hue: 0))
        #expect(HUDSprites.sign(name: "", hue: 4) == Self.def(SpriteKey("sign.island", variant: "hue4"))?.frames[0])
    }

    @Test func signTextIsCentred() throws {
        let sign = HUDSprites.sign(name: "API", hue: 2)
        let plate = try #require(Self.def(SpriteKey("sign.island", variant: "hue2"))).frames[0]
        var xs: [Int] = []
        for y in 0..<sign.height { for x in 0..<sign.width where sign[x, y] != plate[x, y] { xs.append(x) } }
        let left = try #require(xs.min()), right = try #require(xs.max())
        #expect(abs(left - (63 - right)) <= 1, "left margin \(left), right margin \(63 - right)")
    }

    @Test func signsDifferByHue() {
        let plates = (0..<10).compactMap { Self.def(SpriteKey("sign.island", variant: "hue\($0)"))?.frames[0] }
        #expect(Set(plates).count == 10)
        #expect(Set(plates.map { $0.alphaMask() }).count == 1, "same board, ten hues")
    }

    // MARK: Desk labels

    @Test func nameplateNineSlice() throws {
        let source = try #require(Self.def(SpriteKey("desk.nameplate", variant: "normal"))).frames[0]
        let insets = HUDSprites.nameplateInsets
        #expect(insets == EdgeInsets(3))
        let plate = HUDSprites.nameplate("NOVA", off: false)
        #expect(plate.width == PixelFont.width(of: "NOVA") + insets.left + insets.right)
        #expect(plate.height == PixelFont.capHeight + 6, "caps only: one face row above and below the text")
        let accented = HUDSprites.nameplate("ZÉPHYR", off: false)
        #expect(accented.height == PixelFont.lineHeight + 6, "room for the accents")
        // The plate is the 9-slice of the sprite, with the text in chalk on its face.
        let bare = source.nineSlice(insets: insets, width: plate.width, height: plate.height)
        var textPixels = 0
        for y in 0..<plate.height {
            for x in 0..<plate.width where plate[x, y] != bare[x, y] {
                #expect(plate[x, y] == Self.chalk)
                #expect(x >= insets.left && x < plate.width - insets.right && y >= insets.top && y < plate.height - insets.bottom)
                textPixels += 1
            }
        }
        #expect(textPixels == PixelFont.render("NOVA", color: Self.chalk).alphaMask().count)
        // Corners are kept exactly.
        for (x, y) in [(0, 0), (2, 2), (plate.width - 1, 0), (0, plate.height - 1), (plate.width - 1, plate.height - 1)] {
            let sx = x < 3 ? x : source.width - (plate.width - x)
            let sy = y < 3 ? y : source.height - (plate.height - y)
            #expect(plate[x, y] == source[sx, sy])
        }
        let off = HUDSprites.nameplate("OFF", off: true)
        #expect(off != HUDSprites.nameplate("OFF", off: false))
        #expect(off.width == PixelFont.width(of: "OFF") + 6)
        #expect(!off.distinctColors.contains(Self.chalk), "the OFF plate is greyed out")
        #expect(HUDSprites.nameplate("nova", off: false) == plate)
    }

    @Test func queueBadgeDigits() throws {
        for count in 1...9 { #expect(HUDSprites.queueBadgeKey(count: count) == SpriteKey("desk.queueBadge", variant: "\(count)")) }
        for count in [10, 11, 42, 1000] { #expect(HUDSprites.queueBadgeKey(count: count) == SpriteKey("desk.queueBadge", variant: "plus")) }
        #expect(HUDSprites.queueBadgeKey(count: 0) == SpriteKey("desk.queueBadge", variant: "1"))
        let badges = try ((1...9).map(String.init) + ["plus"]).map { variant in
            try #require(Self.def(SpriteKey("desk.queueBadge", variant: variant)), "\(variant)").frames[0]
        }
        #expect(Set(badges).count == 10)
        #expect(Set(badges.map { $0.alphaMask() }).count == 1, "one badge, ten labels")
        for badge in badges { #expect(badge.distinctColors.contains(Self.chalk), "the label is chalk") }
    }

    // MARK: Status icons and minimap (7.9: never colour alone)

    @Test func hudStatePerKind() throws {
        let icons = try AgentStateKind.allCases.map { kind in try #require(Self.def(HUDSprites.stateKey(kind)), "\(kind)") }
        let masks = icons.map { $0.frames[0].alphaMask() }
        for i in masks.indices {
            for j in masks.indices where j > i {
                #expect(masks[i] != masks[j], "\(icons[i].key.name) and \(icons[j].key.name) share a shape")
            }
        }
        for icon in icons {
            let yellow = icon.frames[0].distinctColors.contains(Self.yellow)
            #expect(yellow == (icon.key == HUDSprites.stateKey(.waitingInput)), "\(icon.key.name)")
        }
    }

    @Test func minimapDotsCarryGlyphs() throws {
        let dots = try AgentStateKind.allCases.map { kind in try #require(Self.def(HUDSprites.minimapDotKey(kind)), "\(kind)") }
        let masks = dots.map { $0.frames[0].alphaMask() }
        #expect(Set(masks).count == AgentStateKind.allCases.count, "10 distinct glyphs")
        for i in masks.indices {
            for j in masks.indices where j > i {
                #expect(masks[i] != masks[j], "\(dots[i].key.name) and \(dots[j].key.name) share a glyph")
            }
        }
        for dot in dots {
            let yellow = dot.frames[0].distinctColors.contains(Self.yellow)
            #expect(yellow == (dot.key == HUDSprites.minimapDotKey(.waitingInput)), "\(dot.key.name)")
        }
    }

    @Test func minimapNineSlices() throws {
        let frame = try #require(Self.def(SpriteKey("minimap.frame"))).frames[0]
        let viewport = try #require(Self.def(SpriteKey("minimap.viewport"))).frames[0]
        let big = frame.nineSlice(insets: HUDSprites.minimapFrameInsets, width: 64, height: 40)
        #expect(big.width == 64 && big.height == 40)
        #expect(big.alphaMask().count > 0)
        let view = viewport.nineSlice(insets: HUDSprites.minimapViewportInsets, width: 20, height: 12)
        #expect(view[10, 6].a == 0, "the viewport is an open rectangle")
        #expect(view[0, 6].a == 255 && view[19, 6].a == 255 && view[10, 0].a == 255 && view[10, 11].a == 255)
    }

    @Test func everySpriteIsLintClean() {
        for def in Self.all {
            let issues = SpriteLint.issues(def)
            #expect(issues.isEmpty, "\(issues)")
        }
    }

    @Test func deterministic() {
        #expect(HUDSprites.all().map(\.frames) == Self.all.map(\.frames))
        #expect(HUDSprites.sign(name: "INFRA", hue: 3) == HUDSprites.sign(name: "INFRA", hue: 3))
    }

    // MARK: Preview

    @Test func preview() {
        guard PreviewWriter.directory(in: ProcessInfo.processInfo.environment) != nil else { return }
        let rows = Self.all.map { def in PixelImage.stacked(def.frames, axis: .horizontal, spacing: 2) }
        var groups: [PixelImage] = []
        var line: [PixelImage] = []
        for row in rows {
            line.append(row)
            if line.count == 10 {
                groups.append(PixelImage.stacked(line, axis: .horizontal, spacing: 4))
                line.removeAll()
            }
        }
        if !line.isEmpty { groups.append(PixelImage.stacked(line, axis: .horizontal, spacing: 4)) }
        let signs = ["API", "SITE WEB", "DOCUMENTATION", "API · 2", "ZÉPHYR", "MOBILE"].enumerated().map {
            HUDSprites.sign(name: $0.element, hue: [4, 0, 2, 4, 6, 7][$0.offset])
        }
        let plates = [HUDSprites.nameplate("NOVA", off: false), HUDSprites.nameplate("ZÉPHYR", off: false),
                      HUDSprites.nameplate("OFF", off: true), HUDSprites.nameplate("KIWI · OFF", off: true)]
        let sheet = PixelImage.stacked(groups + [PixelImage.stacked(signs, axis: .horizontal, spacing: 4),
                                                 PixelImage.stacked(plates, axis: .horizontal, spacing: 4)],
                                       axis: .vertical, spacing: 4, background: Palette.color(.floorDark))
        PreviewWriter.write("hud", width: sheet.width, height: sheet.height, rgba: sheet.rgbaBytes, scale: 4)
        // Zoomed: status icons, minimap dots, badges.
        let zoomed: [(String, [SpriteKey], Int)] = [
            ("hud-states", AgentStateKind.allCases.map(HUDSprites.stateKey), 8),
            ("hud-dots", AgentStateKind.allCases.map(HUDSprites.minimapDotKey), 12),
            ("hud-badges", ((1...9).map(String.init) + ["plus"]).map { SpriteKey("desk.queueBadge", variant: $0) }, 10),
        ]
        for (name, keys, scale) in zoomed {
            let frames = keys.compactMap { Self.def($0)?.frames[0] }
            let row = PixelImage.stacked(frames, axis: .horizontal, spacing: 3, background: Palette.color(.shade))
            PreviewWriter.write(name, width: row.width, height: row.height, rgba: row.rgbaBytes, scale: scale)
        }
        let labels = PixelImage.stacked([PixelImage.stacked(Array(signs.prefix(3)), axis: .horizontal, spacing: 4),
                                         PixelImage.stacked(plates, axis: .horizontal, spacing: 4)],
                                        axis: .vertical, spacing: 4, background: Palette.color(.floorDark))
        PreviewWriter.write("hud-labels", width: labels.width, height: labels.height, rgba: labels.rgbaBytes, scale: 6)
    }
}
