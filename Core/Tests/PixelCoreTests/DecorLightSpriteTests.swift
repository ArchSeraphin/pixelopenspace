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
            DecorSpriteExpectation(id: "light.cone", width: 48, height: 32, anchor: PixelPoint(24, 16)),
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

    @Test func lightsAreOpaqueWarmOrGlow() {
        let lookup = DecorSpriteChecks.byKey(Self.lights)
        let cone = lookup[SpriteKey("light.cone")]!.frames[0]
        let glow = lookup[SpriteKey("light.screenGlow")]!.frames[0]
        #expect(cone.distinctColors == [Palette.color(.lampWarm)])
        #expect(glow.distinctColors == [Palette.color(.screenGlow)])
        for (name, image) in [("light.cone", cone), ("light.screenGlow", glow)] {
            #expect(image.pixels.allSatisfy { $0.a == 0 || $0.a == 255 }, "\(name): opaque, alpha applied at compositing")
            // Centred on its anchor: symmetric left to right.
            #expect(image == image.mirrored(), "\(name)")
            let w = image.width
            #expect(image[w / 2, image.height / 2].a == 255, "\(name): lit at the anchor")
        }
        // The cone narrows toward the lamp: its top row is narrower than its widest row.
        let rows = (0..<cone.height).map { y in (0..<cone.width).filter { cone[$0, y].a != 0 }.count }
        #expect(rows.first! > 0 && rows.first! < rows.max()!)
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
