import Foundation
import Testing
@testable import PixelCore

@Suite struct DecorLightSpriteTests {
    static let decor = DecorSprites.all()
    static let lights = LightSprites.all()

    @Test func sizesAnchorsAndFrames() {
        DecorSpriteChecks.check(Self.decor, against: [
            DecorSpriteExpectation(id: "decor.plantSmall", width: 16, height: 24, anchor: PixelPoint(8, 23), frames: 2,
                                   holds: [24, 24]),
            DecorSpriteExpectation(id: "decor.coffeeMachine", width: 32, height: 48, anchor: PixelPoint(16, 44), frames: 4,
                                   holds: [4, 4, 4, 4]),
        ])
        DecorSpriteChecks.check(Self.lights, against: [
            DecorSpriteExpectation(id: "shadow.tile", width: 56, height: 28, anchor: PixelPoint(28, 14)),
            DecorSpriteExpectation(id: "shadow.char", width: 20, height: 8, anchor: PixelPoint(10, 4)),
            DecorSpriteExpectation(id: "shadow.small", width: 16, height: 8, anchor: PixelPoint(8, 4)),
            DecorSpriteExpectation(id: "light.cone", width: 28, height: 14, anchor: PixelPoint(14, 7)),
            DecorSpriteExpectation(id: "light.screenGlow", width: 24, height: 16, anchor: PixelPoint(12, 8)),
            DecorSpriteExpectation(id: "fx.star", width: 1, height: 1, anchor: PixelPoint(0, 0), frames: 2, holds: [24, 24],
                                   variants: ["small"]),
            DecorSpriteExpectation(id: "fx.star", width: 3, height: 3, anchor: PixelPoint(1, 1), frames: 2, holds: [24, 24],
                                   variants: ["big"]),
        ])
    }

    @Test func groupsAreSortedWithUniqueKeys() {
        #expect(DecorSpriteChecks.isSortedWithUniqueKeys(Self.decor))
        #expect(DecorSpriteChecks.isSortedWithUniqueKeys(Self.lights))
        #expect(Self.decor.allSatisfy { $0.category == .decor })
        #expect(Self.lights.allSatisfy { $0.category == .lights })
    }

    @Test func shadowsAreOpaqueInk() {
        let ink = Palette.color(.ink)
        for def in Self.lights where def.key.id.rawValue.hasPrefix("shadow.") {
            #expect(def.frames.count == 1)
            #expect(def.frames[0].distinctColors == [ink], "\(def.key.name)")
            #expect(def.frames[0].pixels.allSatisfy { $0.a == 0 || $0 == ink }, "\(def.key.name): opaque, alpha applied at compositing")
            #expect(def.frames[0].opaqueBounds == PixelRect(x: 0, y: 0, width: def.width, height: def.height), "\(def.key.name)")
        }
        // Under furniture: a floor diamond (7.2), the tile one with the 4y + 4 rows of the floor.
        let tile = DecorSpriteChecks.byKey(Self.lights)[SpriteKey("shadow.tile")]!.frames[0]
        #expect(tile.alphaMask() == Draw.isoDiamondMask(width: 56))
    }

    @Test func charShadowIsSymmetricEllipse() {
        let lookup = DecorSpriteChecks.byKey(Self.lights)
        for (id, w, h) in [("shadow.char", 20, 8), ("shadow.small", 16, 8)] {
            let image = lookup[SpriteKey(SpriteID(id))]!.frames[0]
            #expect(image == Draw.ellipse(width: w, height: h, fill: Palette.color(.ink)), "\(id)")
            for y in 0..<h {
                for x in 0..<w {
                    #expect(image[x, y] == image[w - 1 - x, y] && image[x, y] == image[x, h - 1 - y], "\(id) (\(x), \(y))")
                }
            }
        }
    }

    static var cone: SpriteDef { DecorSpriteChecks.byKey(lights)[SpriteKey("light.cone")]! }
    static var glow: SpriteDef { DecorSpriteChecks.byKey(lights)[SpriteKey("light.screenGlow")]! }

    @Test func lightsAreOpaqueSymmetricAndLitAtTheAnchor() {
        #expect(Self.cone.frames[0].distinctColors == [Palette.color(.alertOrange)], "one colour: overlapping pools merge")
        #expect(Set(Self.glow.frames[0].distinctColors) == [Palette.color(.screenGlow), Palette.color(.uiTitle)])
        for def in [Self.cone, Self.glow] {
            let image = def.frames[0]
            #expect(image.pixels.allSatisfy { $0.a == 0 || $0.a == 255 }, "\(def.key.name): opaque, alpha applied at compositing")
            // Centred on its anchor: as many lit pixels on each side of it in every row (up to the checkerboard,
            // whose parity flips in a mirror).
            #expect(def.anchor.x * 2 == image.width, "\(def.key.name)")
            for y in 0..<image.height {
                let left = (0..<def.anchor.x).filter { image[$0, y].a != 0 }.count
                let right = (def.anchor.x..<image.width).filter { image[$0, y].a != 0 }.count
                #expect(abs(left - right) <= 1, "\(def.key.name) row \(y): \(left) | \(right)")
            }
            #expect(image[def.anchor.x, def.anchor.y].a == 255, "\(def.key.name): lit at the anchor")
        }
    }

    /// Night lights at the milestone review: `lampWarm` added at 35 % turned the veiled, shaded Lagune carpet into
    /// a grey mauve (#98939B). The pool's colour stays warm (red above blue) on every carpet field, the desk tops and
    /// the hall floor, in or out of a cast shadow; `lampWarm` does not.
    @Test func lampPoolStaysWarmOnEveryVeiledFloor() {
        let floors: [RGBA8] = Palette.projectHues.map(\.light)
            + ([.woodLight, .woodMid, .floorLight, .floorDark] as [PaletteRole]).map(Palette.color)
        func lit(_ floor: RGBA8, shaded: Bool, by light: RGBA8) -> RGBA8 {
            var image = PixelImage(width: 1, height: 1, fill: floor)
            if shaded { image.composite(PixelImage(width: 1, height: 1, fill: Palette.color(.ink)), alpha: Palette.shadowAlpha) }
            image.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
            image.add(PixelImage(width: 1, height: 1, fill: light), alpha: Palette.lightPoolAlpha)
            return image[0, 0]
        }
        let pool = Self.cone.frames[0].distinctColors
        for light in pool {
            for floor in floors {
                for shaded in [false, true] {
                    let p = lit(floor, shaded: shaded, by: light)
                    #expect(p.r > p.b, "\(floor.hexString)\(shaded ? " shaded" : ""): lit \(p.hexString) is not warm")
                }
            }
        }
        let mauve = lit(Palette.hue(4).light, shaded: true, by: Palette.color(.lampWarm))
        #expect(mauve.r < mauve.b, "the defect this colour avoids")
    }

    /// Mean added luma (0 where transparent) over three rings of the lit ellipse, from the centre out.
    static func ringMeans(_ image: PixelImage) -> [Double] {
        let box = image.opaqueBounds!
        var sums = [0.0, 0.0, 0.0], counts = [0, 0, 0]
        for y in box.y..<(box.y + box.height) {
            for x in box.x..<(box.x + box.width) {
                let dx = Double(2 * (x - box.x) + 1 - box.width) / Double(box.width)
                let dy = Double(2 * (y - box.y) + 1 - box.height) / Double(box.height)
                let r = (dx * dx + dy * dy).squareRoot()
                guard r <= 1 else { continue }
                let ring = min(Int(r * 3), 2)
                sums[ring] += image[x, y].a == 0 ? 0 : Double(image[x, y].luma)
                counts[ring] += 1
            }
        }
        return (0..<3).map { sums[$0] / Double(counts[$0]) }
    }

    /// Soft lights, not hard-edged shapes (the screen glow read as a pane of glass on the desk): the light fades
    /// from the centre to the edge, through the checkerboard and dimmer colours.
    @Test func lightsFadeOut() {
        let glow = Self.ringMeans(Self.glow.frames[0])
        #expect(glow[0] > glow[1] && glow[1] > glow[2], "screen glow \(glow)")
        #expect(glow[2] < glow[0] * 0.4, "screen glow: a faint edge \(glow)")
        let pool = Self.ringMeans(Self.cone.frames[0])
        #expect(pool[0] >= pool[1] && pool[1] > pool[2], "lamp pool \(pool)")
        #expect(pool[2] < pool[0] * 0.75, "lamp pool: a checkered edge \(pool)")
        // The brightest colour never reaches the edge of the glow.
        let image = Self.glow.frames[0], bright = Palette.color(.screenGlow)
        let box = image.opaqueBounds!
        for y in box.y..<(box.y + box.height) {
            let row = (box.x..<(box.x + box.width)).filter { image[$0, y].a != 0 }
            guard let first = row.first, let last = row.last else { continue }
            #expect(image[first, y] != bright && image[last, y] != bright, "row \(y)")
        }
    }

    /// A desk lamp's pool, not a floor spotlight: placed with `lightConeOffset`, its solid part lies on the desk top
    /// or on the bench of the facing desk (local −8 ≤ a ≤ 8, −24 ≤ b ≤ 8), its checkered ring at most 2 units past
    /// an edge, and at least 80 % of it is over the desk tops.
    @Test func lampPoolStaysOnTheDeskTop() {
        let image = Self.cone.frames[0], anchor = Self.cone.anchor
        let solid = Palette.color(.alertOrange)
        for facing in Facing.allCases {
            let offset = FurnitureSprites.lightConeOffset(facing: facing)
            var onDesks = 0, total = 0
            for y in 0..<image.height {
                for x in 0..<image.width where image[x, y].a != 0 {
                    // Pixel centre, px from the desk anchor, then floor units at desk-top height.
                    let px = Double(offset.x - anchor.x + x) + 0.5
                    let py = Double(offset.y - anchor.y + y) + 0.5 + Double(IsoMath.deskTopHeight)
                    let u = (py + px / 2) / 2, v = (py - px / 2) / 2
                    let (a, b): (Double, Double)
                    switch facing {
                    case .ne: (a, b) = (u, v)
                    case .sw: (a, b) = (u, -v)
                    case .se: (a, b) = (v, -u)
                    case .nw: (a, b) = (v, u)
                    }
                    let inside = abs(a) <= 8 && b >= -24 && b <= 8
                    total += 1
                    if inside { onDesks += 1 }
                    let interior = (x > 0 && image[x - 1, y].a != 0) && (x + 1 < image.width && image[x + 1, y].a != 0)
                    if image[x, y] == solid && interior {
                        #expect(abs(a) <= 8.5 && b >= -24 && b <= 8.5, "@\(facing): solid light at (\(a), \(b))")
                    }
                    #expect(abs(a) <= 10 && b >= -26 && b <= 10, "@\(facing): light at (\(a), \(b))")
                }
            }
            #expect(Double(onDesks) >= 0.8 * Double(total), "@\(facing): \(onDesks) of \(total) pixels on the desks")
        }
    }

    @Test func starsTwinkle() {
        let lookup = DecorSpriteChecks.byKey(Self.lights)
        for variant in ["small", "big"] {
            let star = lookup[SpriteKey("fx.star", variant: variant)]!
            #expect(star.frames[0] != star.frames[1], "\(variant)")
            #expect(star.frames[0].distinctColors.contains(Palette.color(.chalk)), "\(variant): frame 0 is bright")
            let lumas = star.frames.map { frame in frame.pixels.filter(\.isOpaque).map(\.luma).reduce(0, +) }
            #expect(lumas[0] > lumas[1], "\(variant): frame 1 is dimmer")
        }
    }

    @Test func plantSwaysAndMachineSteams() {
        let lookup = DecorSpriteChecks.byKey(Self.decor)
        let plant = lookup[SpriteKey("decor.plantSmall")]!
        #expect(plant.frames[0] != plant.frames[1])
        let leaves: Set<RGBA8> = [Palette.color(.leaf), Palette.color(.leafDark), Palette.color(.leafLight)]
        #expect(leaves.isSubset(of: Set(plant.frames[0].distinctColors)))
        let machine = lookup[SpriteKey("decor.coffeeMachine")]!
        #expect(Set(machine.frames).count == 4, "four steam frames")
        // Only the steam moves: the frames differ above the cup, nowhere else.
        let first = machine.frames[0]
        for frame in machine.frames.dropFirst() {
            let changed = (0..<first.height).flatMap { y in (0..<first.width).filter { first[$0, y] != frame[$0, y] }.map { ($0, y) } }
            #expect(!changed.isEmpty)
            #expect(changed.allSatisfy { $0.1 < 40 }, "steam only")
        }
        for def in [plant, machine] {
            let lumas = DecorSpriteChecks.probeLumas(def)
            #expect(lumas != nil, "\(def.key.name) has a light probe")
            if let lumas { #expect(lumas.left > lumas.right, "\(def.key.name)") }
        }
    }

    @Test func everySpriteIsLintClean() {
        let issues = DecorSpriteChecks.lintIssues(Self.decor + Self.lights)
        #expect(issues.isEmpty, "\(issues.prefix(20))")
    }

    @Test func noAlertYellow() {
        #expect(DecorSpriteChecks.yellowSprites(Self.decor + Self.lights).isEmpty)
    }

    @Test func preview() {
        guard DecorSpriteChecks.previewsEnabled else { return }
        DecorSpriteChecks.write("decor-decor", DecorSpriteChecks.sheet(Self.decor), scale: 6)
        DecorSpriteChecks.write("decor-lights", DecorSpriteChecks.sheet(Self.lights), scale: 4)
    }
}
