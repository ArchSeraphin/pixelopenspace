import Foundation
import Testing
@testable import PixelCore

@Suite struct MonitorSpriteTests {
    static let all = MonitorSprites.all()
    static let yellow = Palette.color(.alertYellow)

    static func def(_ key: SpriteKey) -> SpriteDef? { all.first { $0.key == key } }

    // MARK: Catalogue shape

    @Test func keysAreSortedAndUnique() {
        let keys = Self.all.map(\.key)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        // 2 front monitors, 10 LED variants × 2 back monitors, 10 screens × 2 facings.
        #expect(keys.count == 2 + 20 + 20)
        #expect(Self.all.allSatisfy { $0.category == ($0.key.id.rawValue.hasPrefix("screen.") ? .screens : .monitors) })
    }

    @Test func screenStatesFramesAndFps() throws {
        for state in ScreenState.allCases {
            let ne = try #require(Self.def(MonitorSprites.screenKey(state, facing: .ne)), "\(state)")
            #expect(ne.key == SpriteKey(state.spriteID, facing: .ne))
            #expect(ne.frames.count == state.frames, "\(state)")
            #expect(ne.holds == state.holds, "\(state)")
            #expect(ne.loops)
            #expect(ne.width == MonitorSprites.screenWidth && ne.height == MonitorSprites.screenHeight)
            #expect(ne.anchor == MonitorSprites.screenAnchor)
            #expect(ne.derivation == nil && ne.source == nil)
            // The content is drawn on the plane of the face: each column pair sits 1 px lower than the previous one.
            let mask = ne.frames[0].alphaMask()
            for x in 0..<ne.width {
                let rows = (0..<ne.height).filter { mask[x, $0] }
                #expect(rows == Array((x / 2)..<(x / 2 + MonitorSprites.screenFlatHeight)), "\(state) column \(x)")
            }
            let nw = try #require(Self.def(MonitorSprites.screenKey(state, facing: .nw)), "\(state)")
            #expect(nw.derivation == .mirror && nw.source == ne.key)
            #expect(nw.frames == ne.frames.map { $0.mirrored() })
            #expect(nw.holds == ne.holds && nw.anchor == PixelPoint(ne.width - ne.anchor.x, ne.anchor.y))
            #expect(Self.def(SpriteKey(state.spriteID, facing: .se)) == nil)
            #expect(Self.def(SpriteKey(state.spriteID, facing: .sw)) == nil)
        }
    }

    @Test func animatedScreensChangeEveryFrame() throws {
        for state in ScreenState.allCases where state.frames > 1 {
            let frames = try #require(Self.def(MonitorSprites.screenKey(state, facing: .ne))).frames
            for index in frames.indices {
                #expect(frames[index] != frames[(index + 1) % frames.count], "\(state) #\(index)")
            }
        }
        let screens = ScreenState.allCases.compactMap { Self.def(MonitorSprites.screenKey($0, facing: .ne))?.frames[0] }
        #expect(Set(screens).count == ScreenState.allCases.count, "every state shows its own key frame")
    }

    @Test func onlyWaitingScreenIsYellow() throws {
        for def in Self.all where def.key.id.rawValue.hasPrefix("screen.") {
            let yellow = def.frames.contains { $0.distinctColors.contains(Self.yellow) }
            #expect(yellow == (def.key.id == ScreenState.waiting.spriteID), "\(def.key.name)")
        }
        let waiting = try #require(Self.def(MonitorSprites.screenKey(.waiting, facing: .ne)))
        #expect(waiting.frames[0].distinctColors.contains(Self.yellow), "frame 0 is the lit phase of the blink")
    }

    @Test func monitorFacings() {
        let front = Self.all.filter { $0.key.id == "monitor.front" }
        #expect(front.map(\.key) == [SpriteKey("monitor.front", facing: .ne), SpriteKey("monitor.front", facing: .nw)])
        let back = Self.all.filter { $0.key.id == "monitor.back" }
        #expect(Set(back.compactMap(\.key.facing)) == [.se, .sw])
        for def in front + back {
            #expect(def.width == 24 && def.height == 24, "\(def.key.name)")
            #expect(def.anchor == PixelPoint(12, 22), "\(def.key.name)")
            #expect(def.derivation == nil, "\(def.key.name): every monitor is generated, never mirrored")
            #expect(def.lightProbe != nil, "\(def.key.name): a lit volume carries its light probe")
        }
        for def in front { #expect(def.frames.count == 1 && def.holds.isEmpty) }
        for def in back { #expect(def.frames.count == 2 && def.holds == [12, 12] && def.loops) }
        #expect(MonitorSprites.screenOffset(facing: .se) == nil && MonitorSprites.screenOffset(facing: .sw) == nil)
    }

    @Test func ledVariantsAreDistinct() throws {
        for facing in [Facing.se, .sw] {
            let defs = try ScreenState.allCases.map { state in
                try #require(Self.def(MonitorSprites.ledKey(state, facing: facing)), "\(state)@\(facing)")
            }
            #expect(defs.map { $0.key.variant } == ScreenState.allCases.map { "led.\($0.rawValue)" })
            let firstFrames = defs.map { $0.frames[0] }
            #expect(Set(firstFrames).count == defs.count, "frames 0 pairwise different")
            let blinkPatterns = defs.map { $0.frames }
            #expect(Set(blinkPatterns).count == defs.count, "every state has its own colour and pattern")
            for (state, def) in zip(ScreenState.allCases, defs) {
                let yellow = def.frames.contains { $0.distinctColors.contains(Self.yellow) }
                #expect(yellow == (state == .waiting), "\(def.key.name)")
                // Only the LED changes with the state: the casing is the same everywhere.
                let changed = zip(def.frames[0].pixels, defs[0].frames[0].pixels).filter { $0 != $1 }.count
                #expect(changed <= MonitorSprites.ledPixelCount, "\(def.key.name)")
            }
            let waiting = defs[ScreenState.allCases.firstIndex(of: .waiting)!]
            #expect(waiting.frames[0] != waiting.frames[1], "the waiting LED blinks")
        }
    }

    @Test func screenFitsTheGlass() throws {
        for facing in [Facing.ne, .nw] {
            let monitor = try #require(Self.def(SpriteKey("monitor.front", facing: facing)))
            let screen = try #require(Self.def(MonitorSprites.screenKey(.off, facing: facing)))
            let offset = try #require(MonitorSprites.screenOffset(facing: facing))
            // Top-left of the screen inside the monitor frame when both anchors are placed as specified.
            let x0 = monitor.anchor.x + offset.x - screen.anchor.x
            let y0 = monitor.anchor.y + offset.y - screen.anchor.y
            var composed = monitor.frames[0]
            composed.blit(screen.frames[0], x: x0, y: y0)
            #expect(composed == monitor.frames[0], "the monitor alone shows the off screen")
            let mask = screen.frames[0].alphaMask()
            let casing: Set<RGBA8> = [Palette.color(.stone), Palette.color(.slate)]
            for y in 0..<mask.height {
                for x in 0..<mask.width where mask[x, y] {
                    #expect(monitor.frames[0][x0 + x, y0 + y].a == 255)
                    // Every 4-neighbour outside the glass is the bezel or the side of the panel.
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where !mask[x + dx, y + dy] {
                        let p = monitor.frames[0][x0 + x + dx, y0 + y + dy]
                        #expect(casing.contains(p), "\(facing): (\(x + dx), \(y + dy)) is \(p.hexString)")
                    }
                }
            }
        }
    }

    @Test func frontMonitorsAreNotMirrors() throws {
        let ne = try #require(Self.def(SpriteKey("monitor.front", facing: .ne))).frames[0]
        let nw = try #require(Self.def(SpriteKey("monitor.front", facing: .nw))).frames[0]
        #expect(nw.alphaMask() == ne.mirrored().alphaMask(), "same silhouette")
        #expect(nw != ne.mirrored(), "relit, not flipped")
    }

    @Test func everySpriteIsLintClean() {
        for def in Self.all {
            let issues = SpriteLint.issues(def)
            #expect(issues.isEmpty, "\(issues)")
        }
    }

    @Test func deterministic() {
        #expect(MonitorSprites.all().map { $0.frames } == Self.all.map { $0.frames })
    }

    // MARK: Preview

    @Test func preview() {
        guard PreviewWriter.directory(in: ProcessInfo.processInfo.environment) != nil else { return }
        let rows = Self.all.map { def in PixelImage.stacked(def.frames, axis: .horizontal, spacing: 2) }
        let sheet = PixelImage.stacked(rows, axis: .vertical, spacing: 2, background: Palette.color(.floorLight))
        PreviewWriter.write("monitors", width: sheet.width, height: sheet.height, rgba: sheet.rgbaBytes, scale: 4)
        // Each front monitor with every screen state on it, as the compositor will place them.
        var cells: [PixelImage] = []
        for facing in [Facing.ne, .nw] {
            guard let monitor = Self.def(SpriteKey("monitor.front", facing: facing)),
                  let offset = MonitorSprites.screenOffset(facing: facing) else { continue }
            for state in ScreenState.allCases {
                guard let screen = Self.def(MonitorSprites.screenKey(state, facing: facing)) else { continue }
                var cell = monitor.frames[0]
                cell.blit(screen.frames[0], x: monitor.anchor.x + offset.x - screen.anchor.x,
                          y: monitor.anchor.y + offset.y - screen.anchor.y)
                cells.append(cell)
            }
        }
        let composed = PixelImage.stacked(cells, axis: .horizontal, spacing: 4, background: Palette.color(.floorLight))
        PreviewWriter.write("monitors-with-screens", width: composed.width, height: composed.height,
                            rgba: composed.rgbaBytes, scale: 6)
    }
}
