import Foundation
import Testing
@testable import PixelCore

@Suite struct OverlaySpriteTests {
    static let overlays = OverlaySprites.all()
    static let effects = EffectSprites.all()
    static let yellow = Palette.color(.alertYellow)
    static let orange = Palette.color(.alertOrange)

    static func def(_ key: SpriteKey) -> SpriteDef? { (overlays + effects).first { $0.key == key } }

    struct Row {
        var key: SpriteKey, width: Int, height: Int, anchor: PixelPoint, frames: Int, fps: Double, loops: Bool
        var category: SpriteCategory
    }

    /// The table of task 5 (7.4.5, 7.4.8).
    static let table: [Row] = {
        var rows: [Row] = [
            Row(key: SpriteKey("ov.bang"), width: 12, height: 24, anchor: PixelPoint(6, 24), frames: 4, fps: 8, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.bang", variant: "xl"), width: 24, height: 48, anchor: PixelPoint(12, 48), frames: 4, fps: 8, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.bang.halo"), width: 32, height: 32, anchor: PixelPoint(16, 16), frames: 2, fps: 4, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.dots"), width: 20, height: 14, anchor: PixelPoint(10, 14), frames: 3, fps: 3, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.zzz"), width: 16, height: 16, anchor: PixelPoint(4, 16), frames: 3, fps: 2, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.storm"), width: 28, height: 18, anchor: PixelPoint(14, 18), frames: 4, fps: 6, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.check"), width: 12, height: 12, anchor: PixelPoint(6, 12), frames: 3, fps: 12, loops: false, category: .overlays),
            Row(key: SpriteKey("ov.stale"), width: 10, height: 14, anchor: PixelPoint(5, 14), frames: 2, fps: 2, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.background"), width: 12, height: 16, anchor: PixelPoint(6, 16), frames: 4, fps: 2, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.quota"), width: 14, height: 14, anchor: PixelPoint(7, 14), frames: 2, fps: 1, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.draft"), width: 10, height: 10, anchor: PixelPoint(5, 10), frames: 1, fps: 0, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.edgeArrow"), width: 16, height: 16, anchor: PixelPoint(8, 8), frames: 2, fps: 4, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.degraded"), width: 12, height: 12, anchor: PixelPoint(6, 12), frames: 1, fps: 0, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.unsafe"), width: 12, height: 12, anchor: PixelPoint(6, 12), frames: 1, fps: 0, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.external"), width: 12, height: 12, anchor: PixelPoint(6, 12), frames: 1, fps: 0, loops: true, category: .overlays),
            Row(key: SpriteKey("ov.selection"), width: 36, height: 18, anchor: PixelPoint(18, 9), frames: 2, fps: 3, loops: true, category: .overlays),
            Row(key: SpriteKey("fx.dust"), width: 24, height: 16, anchor: PixelPoint(12, 16), frames: 6, fps: 12, loops: false, category: .effects),
            Row(key: SpriteKey("fx.ding"), width: 12, height: 12, anchor: PixelPoint(6, 12), frames: 3, fps: 8, loops: false, category: .effects),
            Row(key: SpriteKey("fx.pinDrop"), width: 12, height: 8, anchor: PixelPoint(6, 8), frames: 3, fps: 12, loops: false, category: .effects),
        ]
        for icon in ToolIcon.allCases {
            rows.append(Row(key: SpriteKey(icon.spriteID), width: 16, height: 16, anchor: PixelPoint(8, 16), frames: 1, fps: 0,
                            loops: true, category: .overlays))
        }
        return rows
    }()

    // MARK: Table

    @Test func sizesAnchorsAndFrames() throws {
        for row in Self.table {
            let def = try #require(Self.def(row.key), "\(row.key.name) missing")
            #expect(def.width == row.width && def.height == row.height, "\(row.key.name): \(def.width)×\(def.height)")
            #expect(def.anchor == row.anchor, "\(row.key.name)")
            #expect(def.frames.count == row.frames, "\(row.key.name)")
            #expect(def.holds == AnimationClock.holds(fps: row.fps, frames: row.frames), "\(row.key.name)")
            if row.frames > 1 { #expect(def.loops == row.loops, "\(row.key.name)") }
            #expect(def.category == row.category, "\(row.key.name)")
            #expect(def.derivation == nil)
        }
        #expect(Self.overlays.count + Self.effects.count == Self.table.count, "no sprite outside the table")
        for group in [Self.overlays, Self.effects] {
            let keys = group.map(\.key)
            #expect(keys == keys.sorted() && Set(keys).count == keys.count)
        }
    }

    @Test func vocabularyHasSprites() {
        for icon in ToolIcon.allCases { #expect(Self.def(SpriteKey(icon.spriteID)) != nil, "\(icon)") }
        for badge in SceneBadge.allCases { #expect(Self.def(SpriteKey(badge.spriteID)) != nil, "\(badge)") }
        for kind in OverlayKind.allCases where kind != .tool {
            #expect(Self.def(SpriteKey(SpriteID("ov.\(kind.rawValue)"))) != nil, "\(kind)")
        }
    }

    @Test func animatedFramesDiffer() {
        for def in Self.overlays + Self.effects where def.frames.count > 1 {
            #expect(Set(def.frames).count > 1, "\(def.key.name): an animation that never changes")
            #expect(def.frames.allSatisfy { $0.opaqueBounds != nil } || def.key.id.rawValue.hasPrefix("fx."),
                    "\(def.key.name): an empty overlay frame")
        }
    }

    // MARK: Waiting

    @Test func bangIsYellowWithOrangeOutline() throws {
        let bang = try #require(Self.def(SpriteKey("ov.bang")))
        for (index, frame) in bang.frames.enumerated() {
            #expect(frame.distinctColors.contains(Self.yellow), "#\(index)")
            #expect(Set(frame.distinctColors).isSubset(of: [Self.yellow, Self.orange, Palette.color(.chalk)]), "#\(index)")
            let mask = frame.alphaMask()
            for y in 0..<frame.height {
                for x in 0..<frame.width where mask[x, y] {
                    let onRing = !mask[x - 1, y] || !mask[x + 1, y] || !mask[x, y - 1] || !mask[x, y + 1]
                    if onRing { #expect(frame[x, y] == Self.orange, "#\(index) (\(x), \(y))") }
                    else { #expect(frame[x, y] != Self.orange, "#\(index) (\(x), \(y)): orange inside") }
                }
            }
        }
        // Frame 0 is the key pose: the "!" stands on the anchor line.
        let bounds = try #require(bang.frames[0].opaqueBounds)
        #expect(bounds.y + bounds.height == bang.height)
        // The bounce only moves the glyph: same shape in every frame.
        let shapes = Set(bang.frames.compactMap { frame in frame.opaqueBounds.map { frame.cropped($0) } })
        #expect(shapes.count == 1)
    }

    @Test func bangXLIsTwiceTheSize() throws {
        let bang = try #require(Self.def(SpriteKey("ov.bang")))
        let xl = try #require(Self.def(SpriteKey("ov.bang", variant: "xl")))
        #expect(xl.width == 2 * bang.width && xl.height == 2 * bang.height)
        #expect(xl.anchor == PixelPoint(2 * bang.anchor.x, 2 * bang.anchor.y))
        #expect(xl.frames == bang.frames.map { $0.scaled(by: 2) })
        #expect(xl.holds == bang.holds)
    }

    @Test func alertYellowOnlyWhereAllowed() throws {
        for def in Self.overlays + Self.effects {
            let yellow = def.frames.contains { $0.distinctColors.contains(Self.yellow) }
            if yellow { #expect(Palette.allowsAlertYellow(def.key), "\(def.key.name)") }
        }
        for key in [SpriteKey("ov.bang"), SpriteKey("ov.bang", variant: "xl"), SpriteKey("ov.bang.halo"), SpriteKey("ov.edgeArrow")] {
            let def = try #require(Self.def(key))
            #expect(def.frames[0].distinctColors.contains(Self.yellow), "\(key.name) is drawn in the waiting yellow")
        }
    }

    @Test func edgeArrowIsSymmetric() throws {
        let arrow = try #require(Self.def(SpriteKey("ov.edgeArrow")))
        for frame in arrow.frames { #expect(frame == frame.mirrored(), "rotated by 45° steps at step 3: left-right symmetric") }
    }

    /// First render: the old pin read as a yellow drop marked "!". The sprite is an arrow pointing up (the scene
    /// turns it toward the agent off screen): a pointed head, barbs, a straight shaft, the waiting colours.
    @Test func edgeArrowIsAnArrowWithABang() throws {
        let arrow = try #require(Self.def(SpriteKey("ov.edgeArrow")))
        let frame = arrow.frames[0]
        let bounds = try #require(frame.opaqueBounds)
        // Row by row from the tip, the inked span: one run, centred, widening to the barbs, then a straight shaft.
        var widths: [Int] = []
        for y in bounds.y..<(bounds.y + bounds.height) {
            let inked = (0..<frame.width).filter { frame[$0, y].a != 0 }
            let (first, last) = (inked.first ?? 0, inked.last ?? -1)
            #expect(inked.count == last - first + 1, "row \(y): one run")
            #expect(first + last == frame.width - 1, "row \(y): centred")
            widths.append(inked.count)
        }
        #expect(widths[0] == 2, "a pointed tip")
        let widest = try #require(widths.max())
        let barbs = try #require(widths.lastIndex(of: widest))
        #expect(zip(widths[..<barbs], widths[1...barbs]).allSatisfy { $0 <= $1 }, "the head widens down to the barbs: \(widths)")
        let shaft = widths[(barbs + 1)...]
        #expect(shaft.count >= 4 && Set(shaft).count == 1, "a straight shaft under the head: \(widths)")
        #expect(widest - (shaft.first ?? widest) >= 6, "barbs of 3 px or more on each side: \(widths)")
        // Waiting colours: alertOrange outline, alertYellow body, an ink "!" inside on the axis.
        let ink = Palette.color(.ink)
        #expect(Set(frame.distinctColors) == [Self.yellow, Self.orange, ink])
        let mask = frame.alphaMask()
        var inkRows = Set<Int>()
        for y in 0..<frame.height {
            for x in 0..<frame.width where mask[x, y] {
                let onRing = !mask[x - 1, y] || !mask[x + 1, y] || !mask[x, y - 1] || !mask[x, y + 1]
                if onRing { #expect(frame[x, y] == Self.orange, "(\(x), \(y)): the outline is alertOrange") }
                if frame[x, y] == ink {
                    #expect(!onRing && (frame.width / 2 - 1...frame.width / 2).contains(x), "(\(x), \(y)): ink off the axis")
                    inkRows.insert(y)
                }
            }
        }
        var runs: [[Int]] = []
        for y in inkRows.sorted() {
            if let last = runs.last?.last, last + 1 == y { runs[runs.count - 1].append(y) } else { runs.append([y]) }
        }
        #expect(runs.count == 2 && runs[0].count >= 3 && runs[1].count < runs[0].count, "an ink \"!\": bar, gap, dot")
        // Frame 1 nudges the same arrow 1 px toward its tip.
        var nudged = PixelImage(width: frame.width, height: frame.height)
        nudged.blit(frame, x: 0, y: -1)
        #expect(arrow.frames[1] == nudged)
        #expect(bounds.y >= 1, "room for the nudge")
    }

    // MARK: Accessibility (7.9)

    @Test func stateShapesAreDistinct() throws {
        let ids: [SpriteID] = ["ov.bang", "ov.dots", "ov.zzz", "ov.storm", "ov.check", "ov.stale", "ov.background", "ov.quota"]
        let masks = try ids.map { id in try #require(Self.def(SpriteKey(id)), "\(id)").frames[0].alphaMask() }
        for i in masks.indices {
            for j in masks.indices where j > i {
                #expect(masks[i] != masks[j], "\(ids[i]) and \(ids[j]) have the same shape")
            }
        }
    }

    @Test func toolIconsAreDistinct() throws {
        let frames = try ToolIcon.allCases.map { icon in try #require(Self.def(SpriteKey(icon.spriteID))).frames[0] }
        #expect(Set(frames).count == ToolIcon.allCases.count)
        // Same bubble for every tool: only the 12×12 icon inside changes.
        let bubbles = Set(frames.map { $0.alphaMask() })
        #expect(bubbles.count == 1)
        let first = frames[0]
        for frame in frames.dropFirst() {
            for y in 0..<first.height {
                for x in 0..<first.width where first[x, y] != frame[x, y] {
                    #expect((2...13).contains(x) && (1...12).contains(y), "icon pixel (\(x), \(y)) outside its 12×12 box")
                }
            }
        }
    }

    @Test func badgesAreDistinct() throws {
        let frames = try SceneBadge.allCases.map { badge in try #require(Self.def(SpriteKey(badge.spriteID))).frames[0] }
        let masks = frames.map { $0.alphaMask() }
        #expect(Set(masks).count == masks.count, "each badge has its own shape")
    }

    @Test func selectionRingLiesOnTheTileDiamond() throws {
        let ring = try #require(Self.def(SpriteKey("ov.selection")))
        let diamond = Draw.isoDiamondMask(width: 36)
        for frame in ring.frames {
            let mask = frame.alphaMask()
            #expect(mask.subtracting(diamond).count == 0)
            #expect(mask.count > 0)
        }
        #expect(ring.frames[0].alphaMask() == ring.frames[1].alphaMask(), "the dashes march, the ring stays")
    }

    @Test func everySpriteIsLintClean() {
        for def in Self.overlays + Self.effects {
            let issues = SpriteLint.issues(def)
            #expect(issues.isEmpty, "\(issues)")
        }
    }

    @Test func deterministic() {
        #expect(OverlaySprites.all().map(\.frames) == Self.overlays.map(\.frames))
        #expect(EffectSprites.all().map(\.frames) == Self.effects.map(\.frames))
    }

    // MARK: Preview

    @Test func preview() {
        guard PreviewWriter.directory(in: ProcessInfo.processInfo.environment) != nil else { return }
        for (name, group) in [("overlays", Self.overlays), ("effects", Self.effects)] {
            for (suffix, background) in [("day", Palette.color(.floorLight)), ("dark", Palette.color(.shade))] {
                let rows = group.map { def in PixelImage.stacked(def.frames, axis: .horizontal, spacing: 2) }
                let sheet = PixelImage.stacked(rows, axis: .vertical, spacing: 2, background: background)
                PreviewWriter.write("\(name)-\(suffix)", width: sheet.width, height: sheet.height, rgba: sheet.rgbaBytes,
                                    scale: 4)
            }
        }
        // Zoomed key frames, side by side: tool icons, state overlays, badges.
        let groups: [(String, [SpriteKey])] = [
            ("overlay-tools", ToolIcon.allCases.map { SpriteKey($0.spriteID) }),
            ("overlay-states", ["ov.bang", "ov.dots", "ov.zzz", "ov.storm", "ov.check", "ov.stale", "ov.background", "ov.quota"]
                .map { SpriteKey(SpriteID($0)) }),
            ("overlay-badges", ["ov.draft", "ov.degraded", "ov.unsafe", "ov.external", "ov.edgeArrow", "fx.ding", "fx.pinDrop"]
                .map { SpriteKey(SpriteID($0)) }),
        ]
        for (name, keys) in groups {
            let frames = keys.compactMap { Self.def($0)?.frames[0] }
            let row = PixelImage.stacked(frames, axis: .horizontal, spacing: 3, background: Palette.color(.floorLight))
            PreviewWriter.write(name, width: row.width, height: row.height, rgba: row.rgbaBytes, scale: 8)
        }
    }
}
