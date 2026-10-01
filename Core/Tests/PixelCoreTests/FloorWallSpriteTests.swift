import Foundation
import Testing
@testable import PixelCore

/// What one row of the task 4 sprite tables promises: size, anchor, timing, and the exact keys of an id
/// (every variant × every facing). Several rows may share an id when variants differ in size (mug~steam).
struct DecorSpriteExpectation {
    var id: SpriteID
    var width: Int
    var height: Int
    var anchor: PixelPoint
    var frames = 1
    var holds: [Int] = []
    var loops = true
    var variants: [String?] = [nil]
    var facings: [Facing?] = [nil]

    var keys: [SpriteKey] {
        variants.flatMap { variant in facings.map { SpriteKey(id, variant: variant, facing: $0) } }
    }
}

/// Checks and previews shared by the decor sprite tests (floors, walls, furniture, desk items, decor, lights).
enum DecorSpriteChecks {
    static let hueVariants: [String?] = (0..<10).map { "hue\($0)" }
    static let fourFacings: [Facing?] = [.ne, .nw, .se, .sw]
    static let wallFacings: [Facing?] = [.nw, .ne]

    static func byKey(_ defs: [SpriteDef]) -> [SpriteKey: SpriteDef] {
        Dictionary(defs.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every expected key exists with its size, anchor, frame count, holds and loop flag; no other key exists.
    static func check(_ defs: [SpriteDef], against table: [DecorSpriteExpectation],
                      sourceLocation: SourceLocation = #_sourceLocation) {
        let lookup = byKey(defs)
        var expected = Set<SpriteKey>()
        for row in table {
            for key in row.keys {
                expected.insert(key)
                guard let def = lookup[key] else {
                    Issue.record("missing sprite \(key.name)", sourceLocation: sourceLocation)
                    continue
                }
                #expect(def.width == row.width && def.height == row.height,
                        "\(key.name): \(def.width)×\(def.height), expected \(row.width)×\(row.height)",
                        sourceLocation: sourceLocation)
                #expect(def.anchor == row.anchor, "\(key.name): anchor \(def.anchor)", sourceLocation: sourceLocation)
                #expect(def.frames.count == row.frames, "\(key.name): \(def.frames.count) frames",
                        sourceLocation: sourceLocation)
                #expect(def.holds == row.holds, "\(key.name): holds \(def.holds)", sourceLocation: sourceLocation)
                #expect(def.loops == row.loops, "\(key.name): loops", sourceLocation: sourceLocation)
            }
        }
        let unexpected = Set(defs.map(\.key)).subtracting(expected).map(\.name).sorted()
        #expect(unexpected.isEmpty, "unexpected sprites: \(unexpected.prefix(10))", sourceLocation: sourceLocation)
    }

    static func lintIssues(_ defs: [SpriteDef]) -> [String] { defs.flatMap(SpriteLint.issues) }

    static func yellowSprites(_ defs: [SpriteDef]) -> [String] {
        let yellow = Palette.color(.alertYellow)
        return defs.filter { def in def.frames.contains { $0.pixels.contains(yellow) } }.map(\.key.name)
    }

    static func isSortedWithUniqueKeys(_ defs: [SpriteDef]) -> Bool {
        let keys = defs.map(\.key)
        return keys == keys.sorted() && Set(keys).count == keys.count
    }

    /// Mean luma of the two probe rectangles on frame 0.
    static func probeLumas(_ def: SpriteDef) -> (left: Double, right: Double)? {
        guard let probe = def.lightProbe, let frame = def.frames.first,
              let left = frame.meanLuma(in: probe.left), let right = frame.meanLuma(in: probe.right) else { return nil }
        return (left, right)
    }

    /// Mirrored sprites (`derivation == .mirror`) have the mirrored frames of their source, same timing.
    static func mirrorsMatchSources(_ defs: [SpriteDef]) -> [String] {
        let lookup = byKey(defs)
        var issues: [String] = []
        for def in defs where def.derivation != nil {
            guard def.derivation == .mirror, let sourceKey = def.source, let source = lookup[sourceKey] else {
                issues.append("\(def.key.name): mirror without a source in the group")
                continue
            }
            if def.frames != source.frames.map({ $0.mirrored() }) { issues.append("\(def.key.name): frames") }
            if def.anchor != PixelPoint(source.width - source.anchor.x, source.anchor.y) {
                issues.append("\(def.key.name): anchor")
            }
            if def.holds != source.holds || def.loops != source.loops { issues.append("\(def.key.name): timing") }
        }
        return issues
    }

    // MARK: Previews

    /// Every sprite of `defs`, frames side by side, on a light checkerboard, wrapped into rows.
    static func sheet(_ defs: [SpriteDef], maxWidth: Int = 1200) -> PixelImage {
        let gap = 4
        var rows: [[PixelImage]] = [[]]
        var rowWidth = 0
        for def in defs {
            let cell = PixelImage.stacked(def.frames, axis: .horizontal, spacing: 2)
            if rowWidth + cell.width > maxWidth, !(rows.last?.isEmpty ?? true) {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(cell)
            rowWidth += cell.width + gap
        }
        let lines = rows.map { PixelImage.stacked($0, axis: .horizontal, spacing: gap) }
        let content = PixelImage.stacked(lines, axis: .vertical, spacing: gap)
        var out = checkerboard(width: content.width + 2 * gap, height: content.height + 2 * gap)
        out.blit(content, x: gap, y: gap)
        return out
    }

    static func checkerboard(width: Int, height: Int) -> PixelImage {
        var image = PixelImage(width: width, height: height)
        let a = Palette.color(.paper), b = Palette.color(.mist)
        for y in 0..<height {
            for x in 0..<width { image[x, y] = ((x / 4) + (y / 4)) % 2 == 0 ? a : b }
        }
        return image
    }

    static var previewsEnabled: Bool {
        PreviewWriter.directory(in: ProcessInfo.processInfo.environment) != nil
    }

    static func write(_ name: String, _ image: PixelImage, scale: Int = 3) {
        PreviewWriter.write(name, width: image.width, height: image.height, rgba: image.rgbaBytes, scale: scale)
    }

    /// Draws `def` frame 0 with its anchor at `point` (scene preview helper).
    static func place(_ def: SpriteDef?, at point: PixelPoint, into image: inout PixelImage, frame: Int = 0) {
        guard let def else { return }
        image.blit(def.frames[min(frame, def.frames.count - 1)], x: point.x - def.anchor.x, y: point.y - def.anchor.y)
    }
}

@Suite struct FloorWallSpriteTests {
    static let floors = FloorSprites.all()
    static let walls = WallSprites.all()
    static let tile = PixelPoint(32, 16)

    @Test func sizesAnchorsAndFrames() {
        let hues = DecorSpriteChecks.hueVariants
        let carpetVariants: [String?] = (0..<10).flatMap { hue in ["hue\(hue).plain", "hue\(hue).stripes"] }
        DecorSpriteChecks.check(Self.floors, against: [
            DecorSpriteExpectation(id: "floor.hall", width: 64, height: 32, anchor: Self.tile, variants: ["n0", "n1", "n2"]),
            DecorSpriteExpectation(id: "floor.corridor", width: 64, height: 32, anchor: Self.tile, variants: ["n0", "n1"]),
            DecorSpriteExpectation(id: "floor.carpet", width: 64, height: 32, anchor: Self.tile, variants: carpetVariants),
            DecorSpriteExpectation(id: "floor.carpet.edge.n", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.edge.e", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.edge.s", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.edge.w", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.corner.n", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.corner.e", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.corner.s", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.carpet.corner.w", width: 64, height: 32, anchor: Self.tile, variants: hues),
            DecorSpriteExpectation(id: "floor.hover", width: 64, height: 32, anchor: Self.tile, frames: 2, holds: [6, 6]),
            DecorSpriteExpectation(id: "floor.dropTarget", width: 64, height: 32, anchor: Self.tile, frames: 4,
                                   holds: [3, 3, 3, 3]),
        ])
        let walls = DecorSpriteChecks.wallFacings
        DecorSpriteChecks.check(Self.walls, against: [
            DecorSpriteExpectation(id: "wall.segment", width: 32, height: 112, anchor: PixelPoint(16, 104),
                                   variants: ["plain", "socket", "baseboard"], facings: walls),
            DecorSpriteExpectation(id: "wall.window", width: 32, height: 112, anchor: PixelPoint(16, 104),
                                   variants: ["day", "dusk", "night"], facings: walls),
            DecorSpriteExpectation(id: "wall.corner", width: 16, height: 112, anchor: PixelPoint(8, 104)),
            DecorSpriteExpectation(id: "pillar", width: 32, height: 96, anchor: PixelPoint(16, 88)),
            // Écart: the floor point under the middle of a 2-tile wall piece is (32, 112), like (16, 104) for one tile.
            DecorSpriteExpectation(id: "elevator", width: 64, height: 128, anchor: PixelPoint(32, 112), frames: 6,
                                   holds: [2, 2, 2, 2, 2, 2], loops: false, facings: [.nw]),
            DecorSpriteExpectation(id: "elevator.led", width: 6, height: 8, anchor: PixelPoint(3, 8), frames: 2,
                                   holds: [12, 12]),
            // Écart (décision 8): a 6-tile wall piece holding 4 rows of 12 sheared mini post-its.
            DecorSpriteExpectation(id: "board.cork", width: 192, height: 192, anchor: PixelPoint(96, 144),
                                   facings: walls),
        ])
    }

    @Test func groupsAreSortedWithUniqueKeys() {
        #expect(DecorSpriteChecks.isSortedWithUniqueKeys(Self.floors))
        #expect(DecorSpriteChecks.isSortedWithUniqueKeys(Self.walls))
        #expect(Self.floors.allSatisfy { $0.category == .floors })
        #expect(Self.walls.allSatisfy { $0.category == .walls })
        #expect(FloorSprites.all().map(\.key) == Self.floors.map(\.key), "built once, same order")
    }

    @Test func floorTilesShareTheDiamondMask() {
        let diamond = Draw.isoDiamondMask(width: 64)
        for def in Self.floors {
            for (index, frame) in def.frames.enumerated() {
                let mask = frame.alphaMask()
                if def.key.id == "floor.hover" || def.key.id == "floor.dropTarget" {
                    #expect(mask.subtracting(diamond).count == 0 && mask.count > 0, "\(def.key.name)#\(index) inside the tile")
                } else {
                    #expect(mask == diamond, "\(def.key.name)#\(index)")
                }
            }
        }
    }

    @Test func carpetHasTenHuesTwoMotifs() {
        let carpets = Self.floors.filter { $0.key.id == "floor.carpet" }
        #expect(carpets.count == 20)
        #expect(Set(carpets.map { $0.frames[0] }).count == 20, "20 distinct images")
        let lookup = DecorSpriteChecks.byKey(Self.floors)
        for hue in 0..<10 {
            let tones = Palette.hue(hue)
            for motif in ["plain", "stripes"] {
                let image = lookup[SpriteKey("floor.carpet", variant: "hue\(hue).\(motif)")]!.frames[0]
                #expect(Set(image.distinctColors) == [tones.light, tones.base], "hue\(hue).\(motif): light carpet, base motif")
                let base = image.pixels.filter { $0 == tones.base }.count
                #expect(base > 0 && base * 4 < image.alphaMask().count, "hue\(hue).\(motif): a discreet motif")
            }
            let plain = lookup[SpriteKey("floor.carpet", variant: "hue\(hue).plain")]!.frames[0]
            let stripes = lookup[SpriteKey("floor.carpet", variant: "hue\(hue).stripes")]!.frames[0]
            #expect(plain != stripes)
        }
    }

    @Test func plainCarpetIsDitheredInACheckerboard() {
        let image = DecorSpriteChecks.byKey(Self.floors)[SpriteKey("floor.carpet", variant: "hue4.plain")]!.frames[0]
        let base = Palette.hue(4).base
        let dots = (0..<image.height).flatMap { y in (0..<image.width).filter { image[$0, y] == base }.map { ($0, y) } }
        #expect(!dots.isEmpty)
        // 50 % checkerboard only: one parity, and never two motif pixels side by side.
        #expect(Set(dots.map { ($0.0 + $0.1) % 2 }).count == 1)
        for (x, y) in dots {
            #expect(x + 1 >= image.width || image[x + 1, y] != base, "(\(x), \(y))")
            #expect(y + 1 >= image.height || image[x, y + 1] != base, "(\(x), \(y))")
        }
    }

    @Test func edgeMirrorsAreExact() {
        let lookup = DecorSpriteChecks.byKey(Self.floors)
        for hue in 0..<10 {
            let variant = "hue\(hue)"
            func frame(_ id: SpriteID) -> PixelImage { lookup[SpriteKey(id, variant: variant)]!.frames[0] }
            #expect(frame("floor.carpet.edge.w") == frame("floor.carpet.edge.n").mirrored())
            #expect(frame("floor.carpet.edge.e") == frame("floor.carpet.edge.s").mirrored())
            #expect(frame("floor.carpet.corner.w") == frame("floor.carpet.corner.e").mirrored())
            for id: SpriteID in ["floor.carpet.edge.w", "floor.carpet.edge.e", "floor.carpet.corner.w"] {
                #expect(lookup[SpriteKey(id, variant: variant)]?.derivation == .mirror)
            }
            for id: SpriteID in ["floor.carpet.edge.n", "floor.carpet.edge.s", "floor.carpet.corner.n",
                                 "floor.carpet.corner.e", "floor.carpet.corner.s"] {
                #expect(lookup[SpriteKey(id, variant: variant)]?.derivation == nil, "\(id) is drawn")
            }
            // Each edge carries the island border on its own side: the dark tone lines the named edge.
            let dark = Palette.hue(hue).dark
            #expect(frame("floor.carpet.edge.n")[47, 7] == dark, "n: upper-right edge (j = 0)")
            #expect(frame("floor.carpet.edge.s")[18, 24] == dark, "s: lower-left edge (j = D − 1)")
            #expect(frame("floor.carpet.edge.n")[18, 24] != dark && frame("floor.carpet.edge.s")[47, 7] != dark)
        }
        #expect(DecorSpriteChecks.mirrorsMatchSources(Self.floors).isEmpty, "\(DecorSpriteChecks.mirrorsMatchSources(Self.floors))")
    }

    @Test func hoverAndDropTargetAnimateInChalk() {
        let lookup = DecorSpriteChecks.byKey(Self.floors)
        for id: SpriteID in ["floor.hover", "floor.dropTarget"] {
            let def = lookup[SpriteKey(id)]!
            #expect(def.frames.allSatisfy { $0.distinctColors == [Palette.color(.chalk)] }, "\(id)")
            #expect(Set(def.frames).count == def.frames.count, "\(id): every frame differs")
        }
    }

    @Test func wallsLitFromTopLeft() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        for variant in ["plain", "socket", "baseboard"] {
            let ne = lookup[SpriteKey("wall.segment", variant: variant, facing: .ne)]!.frames[0]
            let nw = lookup[SpriteKey("wall.segment", variant: variant, facing: .nw)]!.frames[0]
            // The middle of the face, between the cap and the baseboard.
            let neFace = ne.meanLuma(in: PixelRect(x: 8, y: 40, width: 16, height: 40))!
            let nwFace = nw.meanLuma(in: PixelRect(x: 8, y: 40, width: 16, height: 40))!
            #expect(neFace > nwFace, "\(variant): the ne wall faces the light")
            #expect(ne[16, 50] == Ramp.wall.left && nw[16, 50] == Ramp.wall.right, "\(variant): left / right tones")
        }
        // Wall pieces stand on the floor edge: column x of a ne piece ends at row x / 2 + 95.
        let plain = lookup[SpriteKey("wall.segment", variant: "plain", facing: .ne)]!.frames[0]
        for x in 0..<32 {
            let bottom = (0..<plain.height).last { plain[x, $0].a != 0 }
            #expect(bottom == x / 2 + 95, "ne column \(x)")
        }
        let plainNW = lookup[SpriteKey("wall.segment", variant: "plain", facing: .nw)]!.frames[0]
        for x in 0..<32 {
            let bottom = (0..<plainNW.height).last { plainNW[x, $0].a != 0 }
            #expect(bottom == (31 - x) / 2 + 95, "nw column \(x)")
        }
    }

    @Test func wallVariantsDiffer() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        for wall in [Facing.ne, .nw] {
            let images = ["plain", "socket", "baseboard"].map { lookup[SpriteKey("wall.segment", variant: $0, facing: wall)]!.frames[0] }
            #expect(Set(images).count == 3, "\(wall)")
            // Same silhouette: segments tile seamlessly whatever their style.
            #expect(Set(images.map { $0.alphaMask() }).count == 1, "\(wall)")
        }
    }

    @Test func wallObjectsAreSheared2to1() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        var pieces: [(String, PixelImage)] = [("elevator@nw", lookup[SpriteKey("elevator", facing: .nw)]!.frames[0])]
        for wall in [Facing.ne, .nw] {
            pieces.append(("board.cork@\(wall)", lookup[SpriteKey("board.cork", facing: wall)]!.frames[0]))
            pieces.append(("wall.window~day@\(wall)", lookup[SpriteKey("wall.window", variant: "day", facing: wall)]!.frames[0]))
        }
        for (name, image) in pieces {
            let tops: [Int] = (0..<image.width).map { Self.topRow(image, $0) }
            #expect(!tops.contains(-1), "\(name): every column is drawn")
            for x in stride(from: 0, to: image.width, by: 2) {
                let step = tops[x + 1] - tops[x]
                #expect(step == 0, "\(name): columns \(x) and \(x + 1) share a step")
                if x >= 2 {
                    let rise = tops[x] - tops[x - 2]
                    #expect(rise == 1 || rise == -1, "\(name): 1 px per column pair at \(x)")
                }
            }
        }
        // The mini post-its of the cork wall follow the same 2:1 shear (wall objects, 7.2).
        let ne = DecorSpriteChecks.byKey(DeskItemSprites.all())[SpriteKey("postit.mini", variant: "hue3", facing: .ne)]!.frames[0]
        let tops: [Int] = (0..<ne.width).map { Self.topRow(ne, $0) }
        #expect(tops == [0, 0, 1, 1, 2, 2, 3, 3])
    }

    /// First opaque row of column x, -1 when the column is empty.
    static func topRow(_ image: PixelImage, _ x: Int) -> Int {
        for y in 0..<image.height where image[x, y].a != 0 { return y }
        return -1
    }

    @Test func windowsHaveThreeSkies() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        let day = Palette.color(.skyDay), night = Palette.color(.skyNight)
        for wall in [Facing.ne, .nw] {
            func colors(_ sky: String) -> Set<RGBA8> {
                Set(lookup[SpriteKey("wall.window", variant: sky, facing: wall)]!.frames[0].distinctColors)
            }
            #expect(colors("day").contains(day) && !colors("day").contains(night))
            #expect(colors("night").contains(night) && !colors("night").contains(day))
            #expect(!colors("dusk").contains(day) && !colors("dusk").contains(night))
            #expect(colors("dusk") != colors("day") && colors("dusk") != colors("night"))
            // Same frame and wall around the pane.
            let images = ["day", "dusk", "night"].map { lookup[SpriteKey("wall.window", variant: $0, facing: wall)]!.frames[0] }
            #expect(Set(images.map { $0.alphaMask() }).count == 1)
            #expect(images[0] != lookup[SpriteKey("wall.segment", variant: "plain", facing: wall)]!.frames[0])
        }
    }

    @Test func boardHoldsFortyEightSlots() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        let postits = DecorSpriteChecks.byKey(DeskItemSprites.all())
        let cork = Palette.color(.cork)
        for wall in [WallSide.ne, .nw] {
            let facing: Facing = wall == .ne ? .ne : .nw
            let board = lookup[SpriteKey("board.cork", facing: facing)]!.frames[0]
            let slots = WallSprites.boardSlots(wall: wall)
            #expect(slots.count == 48 && Set(slots).count == 48, "\(wall)")
            let postit = postits[SpriteKey("postit.mini", variant: "paper", facing: facing)]!
            let frame = postit.frames[0]
            var covered = Set<PixelPoint>()
            for slot in slots {
                // postit.mini's anchor goes on the slot; its whole footprint lies on cork, inside the frame, alone.
                let origin = PixelPoint(slot.x - postit.anchor.x, slot.y - postit.anchor.y)
                for y in 0..<frame.height {
                    for x in 0..<frame.width where frame[x, y].a != 0 {
                        let p = PixelPoint(origin.x + x, origin.y + y)
                        guard p.x >= 0, p.y >= 0, p.x < board.width, p.y < board.height else {
                            Issue.record("\(wall) slot \(slot) leaves the sprite")
                            continue
                        }
                        #expect(board[p.x, p.y] == cork, "\(wall) slot \(slot) on cork at \(p)")
                        #expect(covered.insert(p).inserted, "\(wall) slot \(slot) overlaps another one")
                    }
                }
            }
            // Row-major: 4 rows of 12, left to right then top to bottom.
            for row in 0..<4 {
                let line = Array(slots[(12 * row)..<(12 * row + 12)])
                #expect(zip(line, line.dropFirst()).allSatisfy { $0.x < $1.x }, "\(wall) row \(row)")
            }
            for column in 0..<12 {
                let ys = (0..<4).map { slots[12 * $0 + column].y }
                #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 }, "\(wall) column \(column)")
            }
        }
    }

    @Test func elevatorDoorsOpenAndTheLEDBlinks() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        let elevator = lookup[SpriteKey("elevator", facing: .nw)]!
        #expect(Set(elevator.frames).count == 6, "six door positions")
        let shade = Palette.color(.shade)
        let interior = elevator.frames.map { $0.pixels.filter { $0 == shade }.count }
        #expect(zip(interior, interior.dropFirst()).allSatisfy { $0 < $1 }, "the doors open: \(interior)")
        let led = lookup[SpriteKey("elevator.led")]!
        #expect(led.frames[0] != led.frames[1])
        #expect(led.frames[0].distinctColors.contains(Palette.color(.lampWarm)), "frame 0 is lit")
        #expect(!led.frames[1].distinctColors.contains(Palette.color(.lampWarm)))
        // The LED sits on the dark housing above the doors.
        let point = WallSprites.elevatorLEDPoint
        let origin = PixelPoint(point.x - led.anchor.x, point.y - led.anchor.y)
        #expect(origin.x >= 0 && origin.y >= 0 && origin.x + led.width <= elevator.width && origin.y + led.height <= elevator.height)
        for y in 0..<led.height {
            for x in 0..<led.width where led.frames[0][x, y].a != 0 {
                #expect(elevator.frames[0][origin.x + x, origin.y + y] == Palette.color(.ink), "housing under (\(x), \(y))")
            }
        }
    }

    @Test func pillarAndElevatorAreLitVolumes() {
        let lookup = DecorSpriteChecks.byKey(Self.walls)
        for key in [SpriteKey("pillar"), SpriteKey("elevator", facing: .nw)] {
            let lumas = DecorSpriteChecks.probeLumas(lookup[key]!)
            #expect(lumas != nil, "\(key.name) has a light probe")
            if let lumas { #expect(lumas.left > lumas.right, "\(key.name)") }
        }
    }

    @Test func everySpriteIsLintClean() {
        let issues = DecorSpriteChecks.lintIssues(Self.floors + Self.walls)
        #expect(issues.isEmpty, "\(issues.prefix(20))")
    }

    @Test func noAlertYellow() {
        #expect(DecorSpriteChecks.yellowSprites(Self.floors + Self.walls).isEmpty)
    }

    @Test func deterministic() {
        #expect(FloorSprites.all().map { $0.frames.map(\.fingerprint) } == Self.floors.map { $0.frames.map(\.fingerprint) })
        #expect(WallSprites.boardSlots(wall: .ne) == WallSprites.boardSlots(wall: .ne))
    }

    @Test func preview() {
        guard DecorSpriteChecks.previewsEnabled else { return }
        DecorSpriteChecks.write("decor-floors", DecorSpriteChecks.sheet(Self.floors.filter {
            $0.key.variant == nil || $0.key.variant!.hasPrefix("n") || $0.key.variant!.hasPrefix("hue4")
                || $0.key.variant!.hasPrefix("hue0") || $0.key.variant!.hasPrefix("hue2")
        }))
        DecorSpriteChecks.write("decor-walls", DecorSpriteChecks.sheet(Self.walls, maxWidth: 1400), scale: 2)
        DecorSpriteChecks.write("decor-room", Self.room(), scale: 2)
    }

    /// A small room: the two back walls with a window, the board and the elevator, hall parquet, corridor and a
    /// 6×7 carpet island of hue 4 (preview only, drawn back to front).
    static func room() -> PixelImage {
        let floors = DecorSpriteChecks.byKey(Self.floors), walls = DecorSpriteChecks.byKey(Self.walls)
        let (w, d) = (10, 12)
        var image = PixelImage(width: (w + d) * 32, height: (w + d) * 16 + 120, fill: Palette.color(.mist))
        func top(_ i: Int, _ j: Int) -> PixelPoint { PixelPoint((i - j + d) * 32, (i + j) * 16 + 112) }
        func centre(_ i: Int, _ j: Int) -> PixelPoint { let t = top(i, j); return PixelPoint(t.x, t.y + 16) }
        let island = GridRect(origin: GridPoint(2, 4), size: GridSize(w: 6, d: 7))
        for s in 0..<(w + d) {
            for j in 0..<d {
                let i = s - j
                guard i >= 0, i < w else { continue }
                let key: SpriteKey
                if island.contains(GridPoint(i, j)) {
                    let li = i - island.origin.i, lj = j - island.origin.j
                    let west = li == 0, east = li == island.size.w - 1, north = lj == 0, south = lj == island.size.d - 1
                    let id: SpriteID
                    switch (west, east, north, south) {
                    case (true, _, true, _): id = "floor.carpet.corner.n"
                    case (_, true, true, _): id = "floor.carpet.corner.e"
                    case (_, true, _, true): id = "floor.carpet.corner.s"
                    case (true, _, _, true): id = "floor.carpet.corner.w"
                    case (_, _, true, _): id = "floor.carpet.edge.n"
                    case (_, true, _, _): id = "floor.carpet.edge.e"
                    case (_, _, _, true): id = "floor.carpet.edge.s"
                    case (true, _, _, _): id = "floor.carpet.edge.w"
                    default: id = "floor.carpet"
                    }
                    key = id == "floor.carpet" ? SpriteKey(id, variant: lj == 3 ? "hue4.stripes" : "hue4.plain")
                        : SpriteKey(id, variant: "hue4")
                } else if j < 3 {
                    key = SpriteKey("floor.hall", variant: "n\((i * 7 + j * 13) % 3)")
                } else {
                    key = SpriteKey("floor.corridor", variant: "n\((i * 7 + j * 13) % 2)")
                }
                DecorSpriteChecks.place(floors[key], at: centre(i, j), into: &image)
            }
        }
        DecorSpriteChecks.place(walls[SpriteKey("wall.corner")], at: top(0, 0), into: &image)
        for j in 0..<d where !(4..<6).contains(j) {
            let variant = j % 3 == 2 ? "window" : "segment"
            let key = variant == "window" ? SpriteKey("wall.window", variant: "day", facing: .nw)
                : SpriteKey("wall.segment", variant: ["plain", "socket", "baseboard"][j % 3], facing: .nw)
            DecorSpriteChecks.place(walls[key], at: PixelPoint(top(0, j).x - 16, top(0, j).y + 8), into: &image)
        }
        DecorSpriteChecks.place(walls[SpriteKey("elevator", facing: .nw)], at: top(0, 5), into: &image)
        for i in 0..<w where !(1..<7).contains(i) {
            let key = i % 3 == 2 ? SpriteKey("wall.window", variant: "dusk", facing: .ne)
                : SpriteKey("wall.segment", variant: ["plain", "socket", "baseboard"][i % 3], facing: .ne)
            DecorSpriteChecks.place(walls[key], at: PixelPoint(top(i, 0).x + 16, top(i, 0).y + 8), into: &image)
        }
        DecorSpriteChecks.place(walls[SpriteKey("board.cork", facing: .ne)], at: top(4, 0), into: &image)
        let postits = DecorSpriteChecks.byKey(DeskItemSprites.all())
        let boardOrigin = PixelPoint(top(4, 0).x - 96, top(4, 0).y - 144)
        for (n, slot) in WallSprites.boardSlots(wall: .ne).enumerated() where n % 5 != 3 {
            let hue = n % 11 == 10 ? "paper" : "hue\(n % 11)"
            DecorSpriteChecks.place(postits[SpriteKey("postit.mini", variant: hue, facing: .ne)],
                                    at: PixelPoint(boardOrigin.x + slot.x, boardOrigin.y + slot.y), into: &image)
        }
        DecorSpriteChecks.place(walls[SpriteKey("pillar")], at: centre(9, 9), into: &image)
        return image
    }
}
