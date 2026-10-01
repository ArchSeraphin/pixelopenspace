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
            // The anchor is the front corner of the base, in the middle: the shade leans right or left of it.
            DecorSpriteExpectation(id: "lamp.desk", width: 24, height: 17, anchor: PixelPoint(12, 17),
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
        let cream: Set<RGBA8> = [Palette.color(.chalk), Palette.color(.paper)]
        for facing in Facing.allCases {
            let on = lookup[SpriteKey("lamp.desk", variant: "on", facing: facing)]!.frames[0]
            let off = lookup[SpriteKey("lamp.desk", variant: "off", facing: facing)]!.frames[0]
            #expect(on.distinctColors.contains(warm), "on @\(facing)")
            #expect(!off.distinctColors.contains(warm), "off @\(facing)")
            #expect(on.alphaMask() == off.alphaMask(), "same lamp @\(facing)")
            // The whole opening of the shade lights up, not one or two texels (milestone review).
            let changed = zip(on.pixels, off.pixels).filter { $0 != $1 }.count
            #expect(changed >= 8, "@\(facing): only \(changed) pixels differ between on and off")
            #expect(cream.isSubset(of: Set(off.distinctColors)), "@\(facing): a cream shade on a dark neck")
        }
    }

    /// Second render: by day, `~on` and `~off` differed by a few texels of the opening only (at night the pool said
    /// it). Lit, the shade itself glows and the white bulb shows: on the desk top, by day, at least 12 pixels change in
    /// every facing, among them a warm opening of 6 or more and some of the shade's own paper.
    @Test func lampOnAndOffDifferByDay() {
        let lookup = DecorSpriteChecks.byKey(Self.items)
        let warm = Palette.color(.lampWarm), chalk = Palette.color(.chalk)
        for facing in Facing.allCases {
            var day: [PixelImage] = []
            for variant in ["on", "off"] {
                let lamp = lookup[SpriteKey("lamp.desk", variant: variant, facing: facing)]!.frames[0]
                var desk = PixelImage(width: lamp.width, height: lamp.height, fill: Ramp.woodLight.top)
                desk.blit(lamp, x: 0, y: 0)
                day.append(desk)
            }
            let changed = zip(day[0].pixels, day[1].pixels).filter { $0 != $1 }.count
            #expect(changed >= 12, "@\(facing): only \(changed) pixels differ by day")
            #expect(day[0].pixels.filter { $0 == warm }.count >= 6, "@\(facing): a warm opening")
            let lit = day[0].pixels.filter { $0 == chalk }.count, unlit = day[1].pixels.filter { $0 == chalk }.count
            #expect(lit >= unlit + 4, "@\(facing): the shade lights up (\(unlit) → \(lit) chalk pixels)")
        }
    }

    /// Second render: at ×1 the lamp's grey neck and base melted into the stand of the monitor beside it. They are now
    /// another value: much darker than the neutral greys of the monitor's foot, and never its stone.
    @Test func lampStandsApartFromTheMonitorFoot() {
        let lookup = DecorSpriteChecks.byKey(Self.items)
        let shade: Set<RGBA8> = [Palette.color(.chalk), Palette.color(.paper), Palette.color(.mist), Palette.color(.lampWarm),
                                 Palette.color(.ink)]
        let foot = [Ramp.neutral.top, Ramp.neutral.left, Ramp.neutral.right]
        let footLuma = Double(foot.map(\.luma).reduce(0, +)) / Double(foot.count)
        for facing in Facing.allCases {
            for variant in ["on", "off"] {
                let lamp = lookup[SpriteKey("lamp.desk", variant: variant, facing: facing)]!.frames[0]
                // Neck and base: whatever is neither the shade, its opening and bulb when lit, nor the outline.
                let on = lookup[SpriteKey("lamp.desk", variant: "on", facing: facing)]!.frames[0]
                let metal = zip(lamp.pixels, on.pixels).filter { $0.isOpaque && !shade.contains($1) }.map(\.0)
                #expect(metal.count >= 16, "@\(facing)~\(variant): a neck and a base")
                let mean = Double(metal.map(\.luma).reduce(0, +)) / Double(max(metal.count, 1))
                #expect(mean < 0.6 * footLuma, "@\(facing)~\(variant): metal luma \(Int(mean)) against \(Int(footLuma))")
                #expect(!metal.contains(Ramp.neutral.left), "@\(facing)~\(variant): stone, the monitor's foot")
            }
        }
    }

    /// The shade leans toward +a, the clearance side (right of the base on screen for ne and sw, left for se and
    /// nw), and never overlaps the monitor of its desk: leaning the other way, it hid behind the monitor of row A.
    @Test func lampShadeStandsBesideTheMonitor() {
        let items = DecorSpriteChecks.byKey(Self.items), monitors = DecorSpriteChecks.byKey(MonitorSprites.all())
        let shade: Set<RGBA8> = [Palette.color(.chalk), Palette.color(.paper), Palette.color(.lampWarm)]
        let desk = PixelPoint(80, 80)
        func at(_ offset: PixelPoint) -> PixelPoint { PixelPoint(desk.x + offset.x, desk.y + offset.y) }
        for facing in Facing.allCases {
            let lamp = items[SpriteKey("lamp.desk", variant: "on", facing: facing)]!
            let image = lamp.frames[0]
            let pixels = (0..<image.height).flatMap { y in (0..<image.width).filter { shade.contains(image[$0, y]) }.map { (x: $0, y: y) } }
            #expect(pixels.count >= 12, "@\(facing): a shade")
            let meanX = Double(pixels.map(\.x).reduce(0, +)) / Double(pixels.count) + 0.5 - Double(lamp.anchor.x)
            #expect(DeskItemSprites.lampLeansRight(facing) ? meanX > 3 : meanX < -3, "@\(facing): shade at \(meanX)")
            // The monitor of that facing (with its screen in row A), on the same desk.
            var monitor = PixelImage(width: 160, height: 120)
            let monitorPoint = at(FurnitureSprites.monitorOffset(facing: facing))
            if let screenOffset = MonitorSprites.screenOffset(facing: facing) {
                DecorSpriteChecks.place(monitors[SpriteKey("monitor.front", facing: facing)], at: monitorPoint, into: &monitor)
                DecorSpriteChecks.place(monitors[MonitorSprites.screenKey(.working, facing: facing)],
                                        at: PixelPoint(monitorPoint.x + screenOffset.x, monitorPoint.y + screenOffset.y),
                                        into: &monitor)
            } else {
                DecorSpriteChecks.place(monitors[MonitorSprites.ledKey(.working, facing: facing)], at: monitorPoint, into: &monitor)
            }
            #expect(monitor.alphaMask().count > 100, "@\(facing): the monitor is drawn")
            let origin = at(FurnitureSprites.lampOffset(facing: facing))
            let hidden = pixels.filter { monitor[origin.x - lamp.anchor.x + $0.x, origin.y - lamp.anchor.y + $0.y].a != 0 }
            #expect(hidden.isEmpty, "@\(facing): \(hidden.count) pixels of the shade on the monitor")
        }
    }

    /// The offline agent's jacket read as a grey bin at the milestone review. Now: a cloth that stands out from
    /// every chair colour, its collar at the very top of the chair, and drawings with the cues of a jacket (collar
    /// narrower than the shoulders, sleeves hanging apart from the body, lapels open on the lining).
    @Test func jacketReadsAsAJacket() {
        let lookup = DecorSpriteChecks.byKey(Self.furniture)
        func distance(_ a: RGBA8, _ b: RGBA8) -> Double {
            let (dr, dg, db) = (Double(a.r) - Double(b.r), Double(a.g) - Double(b.g), Double(a.b) - Double(b.b))
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        for color in Self.chairColors {
            let chair = color == "slate" ? FurnitureSprites.metal : Ramp.hue(Int(color.dropFirst(3))!)
            let cloth = FurnitureSprites.jacketRamp(for: "\(color).jacket")
            let nearest = [chair.top, chair.left, chair.right].map { distance($0, cloth.left) }.min()!
            #expect(nearest >= 60, "chair~\(color).jacket: cloth \(cloth.left.hexString) too close to the chair (\(nearest))")
            let clothColors: Set<RGBA8> = [cloth.top, cloth.left, cloth.right, cloth.outline]
            for facing in Facing.allCases {
                let image = lookup[SpriteKey("chair", variant: "\(color).jacket", facing: facing)]!.frames[0]
                let top = image.opaqueBounds!.y
                let topRow = (0..<image.width).map { image[$0, top] }.filter(\.isOpaque)
                #expect(Set(topRow).isSubset(of: clothColors), "chair~\(color).jacket@\(facing): the collar tops the chair")
                #expect(image.pixels.contains(cloth.left), "chair~\(color).jacket@\(facing): the cloth shows")
            }
        }
        func width(_ map: PixelMap, _ row: Int) -> Int { (0..<map.width).filter { map[$0, row] != .clear }.count }
        for map in [FurnitureSprites.jacketBack, FurnitureSprites.jacketFront] {
            #expect(width(map, 0) < width(map, 4) / 2, "a collar, narrower than the shoulders")
        }
        let back = FurnitureSprites.jacketBack
        let apart = (0..<back.height).filter { y in back[3, y] != .clear && back[4, y] == .clear && back[5, y] != .clear }
        #expect(apart.count >= 3, "the sleeves hang apart from the body")
        #expect(FurnitureSprites.jacketFront.cells.contains(.role(.shade)), "the lapels open on the lining")
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

    /// Close-ups of the lamps, the jackets and the lit posts of the demonstration island, day and night, with the
    /// lamp pools placed by `lightConeOffset` (preview only).
    @Test func previewLampsJacketsAndNight() {
        guard DecorSpriteChecks.previewsEnabled else { return }
        DecorSpriteChecks.write("lot-a-lamps", Self.lampSheet(), scale: 8)
        DecorSpriteChecks.write("lot-a-jackets", DecorSpriteChecks.sheet(Self.furniture.filter {
            ["slate.jacket", "hue0.jacket", "hue4.jacket", "hue8.jacket", "hue2.jacket"].contains($0.key.variant ?? "")
        }, maxWidth: 150), scale: 6)
        let crop = PixelRect(x: 120, y: 140, width: 380, height: 230)
        for (n, cast) in Showcase.islandCasts().enumerated() {
            for night in [false, true] {
                let image = Self.island(cast, night: night).cropped(crop)
                DecorSpriteChecks.write("lot-a-island\(n + 1)-\(night ? "nuit" : "jour")", image, scale: 3)
            }
        }
    }

    /// The island rendered by the compositor, which places the lamp pools at `lightConeOffset` from each lit desk.
    static func island(_ scene: SceneInput, night: Bool) -> PixelImage {
        SceneCompositor.render(scene, options: RenderOptions(night: night, crop: Showcase.islandCrop()))
    }

    /// Each facing: the lamp off and on over a desk top, then on at night with its pool (preview only).
    static func lampSheet() -> PixelImage {
        let items = DecorSpriteChecks.byKey(Self.items), furniture = DecorSpriteChecks.byKey(Self.furniture)
        let cone = DecorSpriteChecks.byKey(LightSprites.all())[SpriteKey("light.cone")]
        var cells: [PixelImage] = []
        for facing in Facing.allCases {
            var row: [PixelImage] = []
            for state in ["off", "on", "night"] {
                var image = PixelImage(width: 72, height: 56, fill: Palette.hue(4).light)
                let desk = PixelPoint(36, 44)
                DecorSpriteChecks.place(furniture[SpriteKey("desk", variant: "light", facing: facing)], at: desk, into: &image)
                let lamp = FurnitureSprites.lampOffset(facing: facing)
                DecorSpriteChecks.place(items[SpriteKey("lamp.desk", variant: state == "off" ? "off" : "on", facing: facing)],
                                        at: PixelPoint(desk.x + lamp.x, desk.y + lamp.y), into: &image)
                if state == "night" {
                    var glow = PixelImage(width: image.width, height: image.height)
                    let at = FurnitureSprites.lightConeOffset(facing: facing)
                    DecorSpriteChecks.place(cone, at: PixelPoint(desk.x + at.x, desk.y + at.y), into: &glow)
                    image.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
                    image.add(glow, alpha: Palette.lightPoolAlpha)
                }
                row.append(image)
            }
            cells.append(PixelImage.stacked(row, axis: .horizontal, spacing: 2, background: Palette.color(.ink)))
        }
        return PixelImage.stacked(cells, axis: .vertical, spacing: 2, background: Palette.color(.ink))
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
            let pool = FurnitureSprites.lightConeOffset(facing: facing)
            DecorSpriteChecks.place(lights[SpriteKey("light.cone")], at: PixelPoint(desk.x + pool.x, desk.y + pool.y),
                                    into: &glow)
            var night = image
            night.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
            night.add(glow, alpha: Palette.lightPoolAlpha)
            cells.append(PixelImage.stacked([image, night], axis: .vertical, spacing: 2))
        }
        return PixelImage.stacked(cells, axis: .horizontal, spacing: 4, background: Palette.color(.ink))
    }
}
