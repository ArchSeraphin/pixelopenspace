import Foundation
import Testing
@testable import PixelCore

/// SW and NW are the flattened mirror of SE and NE, reshaded so the light stays top-left (7.5).
@Suite struct CharacterReshadeTests {
    static let looks: [ResolvedLook] = ([AgentLook()] + CharacterSprites.sampleLooks).map {
        ResolvedLook($0, projectHue: 1)
    }

    /// The material of a slot, with its base and shade; an eye belongs to the face (skin) for segmentation.
    static func material(_ slot: Slot) -> (base: Slot, shade: Slot)? {
        switch slot {
        case .skin, .skinShade, .eye: return (.skin, .skinShade)
        case .hair, .hairShade: return (.hair, .hairShade)
        case .top, .topShade: return (.top, .topShade)
        case .bottom, .bottomShade: return (.bottom, .bottomShade)
        case .accessory, .accessoryShade: return (.accessory, .accessoryShade)
        default: return nil
        }
    }

    static func canvas(from rows: [[Slot]]) -> SlotCanvas {
        var canvas = SlotCanvas(width: rows[0].count, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, slot) in row.enumerated() { canvas[x, y] = slot }
        }
        return canvas
    }

    // MARK: Canvas operations

    @Test func flattenRemovesShades() {
        let all: [Slot] = [.clear, .role(.ink), .role(.paper), .skin, .skinShade, .skinOutline, .hair, .hairShade,
                           .hairOutline, .top, .topShade, .topOutline, .bottom, .bottomShade, .eye, .accessory,
                           .accessoryShade]
        let flat = Self.canvas(from: [all]).flattened()
        let expected: [Slot] = [.clear, .role(.ink), .role(.paper), .skin, .skin, .skinOutline, .hair, .hair,
                                .hairOutline, .top, .top, .topOutline, .bottom, .bottom, .eye, .accessory, .accessory]
        #expect((0..<all.count).map { flat[$0, 0] } == expected)
        for animation in CharacterAnimation.allCases {
            for facing in animation.drawnFacings {
                for frame in 0..<animation.framesPerFacing {
                    guard let canvas = CharacterSprites.canvas(animation, facing, frame: frame, look: Self.looks[0])
                    else { continue }
                    let flattened = canvas.flattened()
                    let shades: Set<Slot> = [.skinShade, .hairShade, .topShade, .bottomShade, .accessoryShade]
                    #expect(flattened.cells.allSatisfy { !shades.contains($0) }, "\(animation)@\(facing)#\(frame)")
                }
            }
        }
    }

    @Test func drawClipsAndSkipsClearCells() {
        var canvas = SlotCanvas(width: 4, height: 3)
        canvas.draw(PixelMap("""
            tt
            .t
            """), x: 0, y: 0)
        canvas.draw(PixelMap("""
            s.
            ss
            """), x: 1, y: 0)
        canvas.draw(PixelMap("pppp"), x: 2, y: 2)
        #expect(canvas[0, 0] == .top && canvas[1, 0] == .skin && canvas[2, 0] == .clear)
        #expect(canvas[1, 1] == .skin && canvas[2, 1] == .skin && canvas[0, 1] == .clear)
        #expect(canvas[2, 2] == .bottom && canvas[3, 2] == .bottom && canvas[1, 2] == .clear)
        #expect(canvas.mirrored()[3, 0] == .top && canvas.mirrored()[0, 2] == .bottom)
        #expect(canvas.mirrored().mirrored() == canvas)
    }

    @Test func reshadeOnASmallCanvas() {
        let canvas = Self.canvas(from: [
            [.hair, .hair, .hair, .hair, .clear, .top, .top, .clear],
            [.skin, .skin, .skin, .eye, .skin, .skin, .clear, .clear],
            [.skinOutline, .skinOutline, .clear, .clear, .clear, .clear, .clear, .clear],
            [.skin, .skin, .clear, .bottom, .bottom, .bottom, .topOutline, .top],
        ])
        let shaded = canvas.reshaded()
        // Run of 4 hair: right pixel shaded; run of 2 top: unchanged.
        #expect([shaded[0, 0], shaded[3, 0], shaded[5, 0], shaded[6, 0]] == [.hair, .hairShade, .top, .top])
        // Under the fringe (hair above) every skin pixel is shaded; the eye is part of the face run, never recoloured.
        #expect([shaded[0, 1], shaded[1, 1], shaded[2, 1], shaded[3, 1], shaded[4, 1], shaded[5, 1]]
                == [.skinShade, .skinShade, .skinShade, .eye, .skin, .skinShade])
        // Under the chin outline: shaded.
        #expect(shaded[0, 3] == .skinShade && shaded[1, 3] == .skinShade)
        // Run of 3 bottom: right pixel shaded; a lone top pixel stays.
        #expect([shaded[3, 3], shaded[5, 3], shaded[6, 3], shaded[7, 3]] == [.bottom, .bottomShade, .topOutline, .top])
        #expect(shaded.reshaded() == shaded, "reshading twice changes nothing")
    }

    // MARK: Mirrors

    @Test func reshadeBandsOnRightEdges() {
        for look in Self.looks.prefix(8) {
            for animation in CharacterAnimation.allCases {
                for facing in animation.facings where !animation.drawnFacings.contains(facing) {
                    for frame in 0..<animation.framesPerFacing {
                        guard let canvas = CharacterSprites.canvas(animation, facing, frame: frame, look: look) else {
                            Issue.record("no \(animation)@\(facing)#\(frame)")
                            continue
                        }
                        for y in 0..<canvas.height {
                            var x = 0
                            while x < canvas.width {
                                guard let m = Self.material(canvas[x, y]) else { x += 1; continue }
                                let start = x
                                while x < canvas.width, let n = Self.material(canvas[x, y]), n.base == m.base { x += 1 }
                                if x - start >= 3 {
                                    #expect(canvas[x - 1, y] == m.shade,
                                            "\(animation)@\(facing)#\(frame) \(look.variantName): run \(start)..<\(x) on row \(y) ends with \(canvas[x - 1, y])")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func mirrorsAreReshadedFlatMirrors() {
        let look = Self.looks[0]
        for animation in CharacterAnimation.allCases {
            for facing in animation.facings where !animation.drawnFacings.contains(facing) {
                for frame in 0..<animation.framesPerFacing {
                    guard let mirror = CharacterSprites.canvas(animation, facing, frame: frame, look: look),
                          let source = CharacterSprites.canvas(animation, facing.mirrored, frame: frame, look: look)
                    else {
                        Issue.record("no \(animation)@\(facing)#\(frame)")
                        continue
                    }
                    #expect(mirror == source.flattened().mirrored().reshaded(), "\(animation)@\(facing)#\(frame)")
                }
            }
        }
    }

    @Test func swIsNotPlainMirror() {
        let sheet = CharacterSprites.sheet(look: AgentLook(), projectHue: 4)
        for animation in CharacterAnimation.allCases {
            for (drawn, derived) in [(Facing.se, Facing.sw), (.ne, .nw)] where animation.facings.contains(derived) {
                guard let source = sheet.def(animation, drawn), let mirror = sheet.def(animation, derived) else {
                    Issue.record("missing \(animation)")
                    continue
                }
                for frame in 0..<animation.framesPerFacing {
                    let plain = source.frames[frame].mirrored()
                    #expect(mirror.frames[frame] != plain, "\(animation)@\(derived)#\(frame) is a plain mirror")
                    #expect(mirror.frames[frame].alphaMask() == plain.alphaMask(),
                            "\(animation)@\(derived)#\(frame) keeps the mirrored silhouette")
                }
            }
        }
    }

    /// Mean luma of the left half of the head is above the right half, in the four directions (sitIdle#0).
    @Test func lightStaysTopLeft() throws {
        for look in Self.looks {
            for facing in Facing.allCases {
                let image = try #require(CharacterSprites.canvas(.sitIdle, facing, frame: 0, look: look)).render(look)
                let bounds = try #require(image.opaqueBounds)
                let top = bounds.y, rows = CharacterSprites.headHeight
                var minX = image.width, maxX = -1
                for y in top..<(top + rows) {
                    for x in 0..<image.width where image[x, y].isOpaque {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                    }
                }
                let width = maxX - minX + 1, half = width / 2
                let left = try #require(image.meanLuma(in: PixelRect(x: minX, y: top, width: half, height: rows)))
                let right = try #require(image.meanLuma(in: PixelRect(x: maxX + 1 - half, y: top, width: half, height: rows)))
                #expect(left > right, "sitIdle@\(facing) \(look.variantName): left \(Int(left)) ≤ right \(Int(right))")
            }
        }
    }
}
