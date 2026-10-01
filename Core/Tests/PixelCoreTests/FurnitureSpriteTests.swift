import Foundation
import Testing
@testable import PixelCore

@Suite struct FurnitureSpriteTests {
    static let furniture = FurnitureSprites.all()
    static let items = DeskItemSprites.all()
    static let chairColors: [String] = ["slate"] + (0..<10).map { "hue\($0)" }

    @Test func sizesAnchorsAndFrames() {
        let four = DecorSpriteChecks.fourFacings
        let chairVariants: [String?] = Self.chairColors.flatMap { [$0, "\($0).jacket"] }
        DecorSpriteChecks.check(Self.furniture, against: [
            // Écart: 56 rows, the desk top stands 24 px high over the whole depth of its tile (bench).
            DecorSpriteExpectation(id: "desk", width: 64, height: 56, anchor: PixelPoint(32, 40),
                                   variants: ["light", "dark"], facings: four),
            DecorSpriteExpectation(id: "chair", width: 32, height: 40, anchor: PixelPoint(16, 36),
                                   variants: chairVariants, facings: four),
        ])
        let postitVariants: [String?] = DecorSpriteChecks.hueVariants + ["paper"]
        DecorSpriteChecks.check(Self.items, against: [
            // Écarts: a 2:1 box 14 or 12 px wide is at least 7 or 6 rows, plus 2 rows of thickness for its light probe.
            DecorSpriteExpectation(id: "keyboard", width: 14, height: 9, anchor: PixelPoint(7, 9), facings: four),
            DecorSpriteExpectation(id: "papers", width: 12, height: 8, anchor: PixelPoint(6, 8), facings: four),
            DecorSpriteExpectation(id: "mug", width: 6, height: 8, anchor: PixelPoint(3, 8), facings: four),
            // Écart: the steam rises above the mug.
            DecorSpriteExpectation(id: "mug", width: 6, height: 14, anchor: PixelPoint(3, 14), frames: 3, holds: [6, 6, 6],
                                   variants: ["steam"], facings: four),
            DecorSpriteExpectation(id: "lamp.desk", width: 12, height: 18, anchor: PixelPoint(6, 17),
                                   variants: ["on", "off"], facings: four),
            DecorSpriteExpectation(id: "desk.postit", width: 6, height: 6, anchor: PixelPoint(3, 6), variants: postitVariants),
            DecorSpriteExpectation(id: "desk.queue", width: 10, height: 8, anchor: PixelPoint(5, 8), variants: ["1", "2", "3"]),
            DecorSpriteExpectation(id: "postit.mini", width: 8, height: 12, anchor: PixelPoint(4, 12), variants: postitVariants,
                                   facings: DecorSpriteChecks.wallFacings),
        ])
    }

    @Test func groupsAreSortedWithUniqueKeys() {
        #expect(DecorSpriteChecks.isSortedWithUniqueKeys(Self.furniture))
        #expect(DecorSpriteChecks.isSortedWithUniqueKeys(Self.items))
        #expect(Self.furniture.allSatisfy { $0.category == .furniture })
        #expect(Self.items.allSatisfy { $0.category == .deskItems })
        #expect((Self.furniture + Self.items).allSatisfy { $0.derivation == nil }, "lit volumes are never mirrored")
    }

    /// Every volume (desk, chair, lamp, keyboard, mug, papers) carries a light probe, left face lighter, in all four
    /// facings, and each facing is drawn on its own (never the mirror of another one).
    @Test func leftFaceLighterInAllFacings() {
        let volumes: Set<SpriteID> = ["desk", "chair", "lamp.desk", "keyboard", "mug", "papers"]
        let defs = (Self.furniture + Self.items).filter { volumes.contains($0.key.id) }
        #expect(Set(defs.map(\.key.id)) == volumes)
        for def in defs {
            let lumas = DecorSpriteChecks.probeLumas(def)
            #expect(lumas != nil, "\(def.key.name) has a light probe")
            if let lumas { #expect(lumas.left > lumas.right, "\(def.key.name): \(lumas)") }
        }
        let lookup = DecorSpriteChecks.byKey(defs)
        for def in defs where def.key.facing == .ne || def.key.facing == .se {
            let other = lookup[SpriteKey(def.key.id, variant: def.key.variant, facing: def.key.facing!.mirrored)]!
            #expect(other.frames[0] != def.frames[0].mirrored(), "\(def.key.name): its mirror facing is drawn, not flipped")
        }
    }

    @Test func chairVariants() {
        let lookup = DecorSpriteChecks.byKey(Self.furniture)
        var images = Set<PixelImage>()
        for color in Self.chairColors {
            for facing in Facing.allCases {
                let bare = lookup[SpriteKey("chair", variant: color, facing: facing)]!.frames[0]
                let jacket = lookup[SpriteKey("chair", variant: "\(color).jacket", facing: facing)]!.frames[0]
                images.insert(bare)
                images.insert(jacket)
                #expect(bare != jacket, "chair~\(color)@\(facing): the jacket shows")
                let tone: RGBA8 = color == "slate" ? Palette.color(.slate) : Palette.hue(Int(color.dropFirst(3))!).base
                #expect(bare.distinctColors.contains(tone), "chair~\(color)@\(facing) in its colour")
            }
        }
        #expect(images.count == 11 * 2 * 4, "11 colours × with or without the jacket × 4 facings, all distinct")
    }

    @Test func lampOnOff() {
        let lookup = DecorSpriteChecks.byKey(Self.items)
        let warm = Palette.color(.lampWarm)
        for facing in Facing.allCases {
            let on = lookup[SpriteKey("lamp.desk", variant: "on", facing: facing)]!.frames[0]
            let off = lookup[SpriteKey("lamp.desk", variant: "off", facing: facing)]!.frames[0]
            #expect(on.distinctColors.contains(warm), "on @\(facing)")
            #expect(!off.distinctColors.contains(warm), "off @\(facing)")
            #expect(on.alphaMask() == off.alphaMask(), "same lamp @\(facing)")
        }
    }

    @Test func deskMaterialsAndFacings() {
        let lookup = DecorSpriteChecks.byKey(Self.furniture)
        for facing in Facing.allCases {
            let light = lookup[SpriteKey("desk", variant: "light", facing: facing)]!.frames[0]
            let dark = lookup[SpriteKey("desk", variant: "dark", facing: facing)]!.frames[0]
            #expect(light.distinctColors.contains(Palette.color(.woodLight)))
            #expect(dark.distinctColors.contains(Palette.color(.woodDark)) && !dark.distinctColors.contains(Palette.color(.paper)))
            #expect(light.alphaMask() == dark.alphaMask(), "@\(facing): same shape")
        }
        // Rows A (ne) and B (sw) meet back to back: the desk fills the depth of its tile.
        let ne = lookup[SpriteKey("desk", variant: "light", facing: .ne)]!.frames[0]
        #expect(ne.opaqueBounds == PixelRect(x: 2, y: 1, width: 60, height: 54))
    }

    @Test func queueAndPostitsFollowTheirVariants() {
        let lookup = DecorSpriteChecks.byKey(Self.items)
        let paper = Palette.color(.paper)
        let counts = (1...3).map { lookup[SpriteKey("desk.queue", variant: "\($0)")]!.frames[0].alphaMask().count }
        #expect(counts[0] < counts[1] && counts[1] < counts[2], "1 to 3 sheets: \(counts)")
        for hue in 0..<10 {
            let tones = Palette.hue(hue)
            let desk = lookup[SpriteKey("desk.postit", variant: "hue\(hue)")]!.frames[0]
            #expect(desk.distinctColors.contains(tones.light) || desk.distinctColors.contains(tones.base), "desk.postit~hue\(hue)")
            for facing in [Facing.ne, .nw] {
                let mini = lookup[SpriteKey("postit.mini", variant: "hue\(hue)", facing: facing)]!.frames[0]
                #expect(Set(mini.distinctColors).isSubset(of: [tones.light, tones.base, tones.dark]), "postit.mini~hue\(hue)@\(facing)")
            }
        }
        #expect(lookup[SpriteKey("desk.postit", variant: "paper")]!.frames[0].distinctColors.contains(paper))
        #expect(lookup[SpriteKey("postit.mini", variant: "paper", facing: .ne)]!.frames[0].distinctColors.contains(paper))
    }

    @Test func mugSteamRises() {
        let lookup = DecorSpriteChecks.byKey(Self.items)
        for facing in Facing.allCases {
            let mug = lookup[SpriteKey("mug", facing: facing)]!.frames[0]
            let steam = lookup[SpriteKey("mug", variant: "steam", facing: facing)]!
            #expect(Set(steam.frames).count == 3, "@\(facing)")
            for frame in steam.frames {
                // The mug itself, at the bottom, is unchanged; the steam is above it.
                #expect(frame.cropped(PixelRect(x: 0, y: 6, width: 6, height: 8)) == mug, "@\(facing)")
                #expect(frame.cropped(PixelRect(x: 0, y: 0, width: 6, height: 6)).alphaMask().count > 0, "@\(facing)")
            }
        }
    }

    /// The helpers place items on the desk top: their anchors land on top-face pixels of the desk sprite.
    @Test func deskItemOffsetsLandOnTheDeskTop() {
        let lookup = DecorSpriteChecks.byKey(Self.furniture)
        let top: Set<RGBA8> = [Ramp.woodLight.top, Ramp.woodLight.highlight]
        for facing in Facing.allCases {
            let desk = lookup[SpriteKey("desk", variant: "light", facing: facing)]!
            let offsets: [(String, PixelPoint)] = [
                ("monitor", FurnitureSprites.monitorOffset(facing: facing)),
                ("lamp", FurnitureSprites.lampOffset(facing: facing)),
                ("keyboard", FurnitureSprites.keyboardOffset(facing: facing)),
                ("mug", FurnitureSprites.mugOffset(facing: facing)),
                ("papers", FurnitureSprites.papersOffset(facing: facing)),
                ("queue", FurnitureSprites.queueOffset(facing: facing)),
            ]
            for (name, offset) in offsets {
                let p = PixelPoint(desk.anchor.x + offset.x, desk.anchor.y + offset.y)
                #expect(p.x > 0 && p.y > 0 && p.x < desk.width && p.y < desk.height, "\(name)@\(facing) inside the desk")
                if p.x > 0 && p.y > 0 && p.x < desk.width && p.y < desk.height {
                    #expect(top.contains(desk.frames[0][p.x, p.y - 1]), "\(name)@\(facing) on the desk top at \(p)")
                }
            }
            #expect(Set(offsets.map { "\($0.1)" }).count == offsets.count, "@\(facing): distinct places")
        }
        // Row A (ne) shows the monitor 6 px toward the aisle (+i) from where the nw layout, mirrored, puts it.
        let ne = FurnitureSprites.monitorOffset(facing: .ne), nw = FurnitureSprites.monitorOffset(facing: .nw)
        #expect(FurnitureSprites.rowAAisleShift == PixelPoint(6, 3))
        #expect(ne == PixelPoint(-nw.x + 6, nw.y + 3))
        let sw = FurnitureSprites.monitorOffset(facing: .sw), se = FurnitureSprites.monitorOffset(facing: .se)
        #expect(sw == PixelPoint(-se.x, se.y), "no shift in row B")
    }

    @Test func everySpriteIsLintClean() {
        let issues = DecorSpriteChecks.lintIssues(Self.furniture + Self.items)
        #expect(issues.isEmpty, "\(issues.prefix(20))")
    }

    @Test func noAlertYellow() {
        #expect(DecorSpriteChecks.yellowSprites(Self.furniture + Self.items).isEmpty)
    }

    @Test func preview() {
        guard DecorSpriteChecks.previewsEnabled else { return }
        DecorSpriteChecks.write("decor-furniture", DecorSpriteChecks.sheet(Self.furniture.filter {
            ["light", "dark", "slate", "slate.jacket", "hue4", "hue4.jacket", "hue0", "hue7.jacket"].contains($0.key.variant ?? "")
        }), scale: 4)
        DecorSpriteChecks.write("decor-deskitems", DecorSpriteChecks.sheet(Self.items.filter {
            !($0.key.variant ?? "").hasPrefix("hue") || ["hue0", "hue4", "hue8"].contains($0.key.variant!)
        }, maxWidth: 400), scale: 6)
        DecorSpriteChecks.write("decor-desks", Self.desks(), scale: 4)
        DecorSpriteChecks.write("decor-chairs", DecorSpriteChecks.sheet(Self.furniture.filter {
            ["slate.jacket", "hue4", "hue4.jacket", "hue8.jacket", "hue0.jacket"].contains($0.key.variant ?? "")
        }, maxWidth: 160), scale: 6)
    }

    /// The four facings of a post: floor, chair, desk and its items placed with the offset helpers (preview only).
    static func desks() -> PixelImage {
        let furniture = DecorSpriteChecks.byKey(Self.furniture), items = DecorSpriteChecks.byKey(Self.items)
        let floor = DecorSpriteChecks.byKey(FloorSprites.all())[SpriteKey("floor.carpet", variant: "hue4.plain")]
        let lights = DecorSpriteChecks.byKey(LightSprites.all())
        var cells: [PixelImage] = []
        for facing in Facing.allCases {
            var image = PixelImage(width: 160, height: 120, fill: Palette.color(.mist))
            let desk = PixelPoint(80, 64)
            let chairStep = facing.opposite.step
            let chair = PixelPoint(desk.x + (chairStep.i - chairStep.j) * 32, desk.y + (chairStep.i + chairStep.j) * 16)
            for (i, j) in [(-1, -1), (0, -1), (-1, 0), (0, 0), (1, 0), (0, 1), (1, 1), (-1, 1), (1, -1)] {
                DecorSpriteChecks.place(floor, at: PixelPoint(desk.x + (i - j) * 32, desk.y + (i + j) * 16), into: &image)
            }
            let chairDef = furniture[SpriteKey("chair", variant: facing == .sw ? "hue4.jacket" : "hue4", facing: facing)]
            let deskDef = furniture[SpriteKey("desk", variant: facing == .se ? "dark" : "light", facing: facing)]
            func item(_ key: SpriteKey, _ offset: PixelPoint) {
                DecorSpriteChecks.place(items[key], at: PixelPoint(desk.x + offset.x, desk.y + offset.y), into: &image)
            }
            let towardViewer = facing.isTowardViewer
            if towardViewer { DecorSpriteChecks.place(chairDef, at: chair, into: &image) }
            DecorSpriteChecks.place(deskDef, at: desk, into: &image)
            item(SpriteKey("lamp.desk", variant: "on", facing: facing), FurnitureSprites.lampOffset(facing: facing))
            item(SpriteKey("papers", facing: facing), FurnitureSprites.papersOffset(facing: facing))
            item(SpriteKey("desk.queue", variant: "3"), FurnitureSprites.queueOffset(facing: facing))
            item(SpriteKey("keyboard", facing: facing), FurnitureSprites.keyboardOffset(facing: facing))
            item(SpriteKey("mug", variant: "steam", facing: facing), FurnitureSprites.mugOffset(facing: facing))
            let monitor = FurnitureSprites.monitorOffset(facing: facing)
            image.fill(PixelRect(x: desk.x + monitor.x - 1, y: desk.y + monitor.y - 1, width: 3, height: 3), Palette.color(.errorRed))
            if !towardViewer { DecorSpriteChecks.place(chairDef, at: chair, into: &image) }
            var glow = PixelImage(width: image.width, height: image.height)
            DecorSpriteChecks.place(lights[SpriteKey("light.cone")], at: PixelPoint(desk.x + 34, desk.y + 6), into: &glow)
            var night = image
            night.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
            night.add(glow, alpha: Palette.lightPoolAlpha)
            cells.append(PixelImage.stacked([image, night], axis: .vertical, spacing: 2))
        }
        return PixelImage.stacked(cells, axis: .horizontal, spacing: 4, background: Palette.color(.ink))
    }
}
