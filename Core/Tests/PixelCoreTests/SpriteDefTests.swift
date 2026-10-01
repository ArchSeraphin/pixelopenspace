import Foundation
import Testing
@testable import PixelCore

@Suite struct SpriteDefTests {
    static let paper = Palette.color(.paper)

    // MARK: Keys

    @Test func spriteKeyName() {
        #expect(SpriteKey("chair", variant: "hue3.jacket", facing: .ne).name == "chair~hue3.jacket@ne")
        #expect(SpriteKey("screen.working").name == "screen.working")
        #expect(SpriteKey("wall.window", variant: "night", facing: .nw).name == "wall.window~night@nw")
        #expect(SpriteKey("desk", facing: .se).name == "desk@se")
        #expect(SpriteKey("screen.working").frameName(2) == "screen.working#2")
        #expect(SpriteKey("agent.type", variant: "s0h2c1op4a0", facing: .se).frameName(0) == "agent.type~s0h2c1op4a0@se#0")
        #expect(SpriteKey("desk", facing: .se).description == "desk@se")
    }

    @Test func spriteKeyOrderIsIdThenVariantThenFacing() {
        let keys = [
            SpriteKey("desk.postit", variant: "hue0"),
            SpriteKey("desk", variant: "light", facing: .sw),
            SpriteKey("desk", variant: "dark", facing: .se),
            SpriteKey("desk", variant: "light", facing: .ne),
            SpriteKey("desk"),
            SpriteKey("chair", variant: "slate", facing: .nw),
        ]
        #expect(keys.sorted() == [
            SpriteKey("chair", variant: "slate", facing: .nw),
            SpriteKey("desk"),
            SpriteKey("desk", variant: "dark", facing: .se),
            SpriteKey("desk", variant: "light", facing: .ne),
            SpriteKey("desk", variant: "light", facing: .sw),
            SpriteKey("desk.postit", variant: "hue0"),
        ])
    }

    @Test func spriteIDIsAString() throws {
        let id: SpriteID = "ov.bang"
        #expect(id.rawValue == "ov.bang" && id.description == "ov.bang")
        #expect(SpriteID("a") < SpriteID("b"))
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"ov.bang\"")
        #expect(try JSONDecoder().decode(SpriteID.self, from: data) == id)
        let key = SpriteKey("chair", variant: "hue1", facing: .sw)
        #expect(try JSONDecoder().decode(SpriteKey.self, from: JSONEncoder().encode(key)) == key)
    }

    // MARK: Animation clock

    @Test func holdsForEachAllowedCadence() {
        let table: [(Double, Int)] = [(12, 2), (8, 3), (6, 4), (4, 6), (3, 8), (2, 12), (1.5, 16), (1, 24)]
        #expect(AnimationClock.ticksPerSecond == 24)
        #expect(AnimationClock.allowedHolds == [2, 3, 4, 6, 8, 12, 16, 24])
        #expect(AnimationClock.allowedFPS == table.map(\.0))
        for (fps, hold) in table {
            #expect(AnimationClock.hold(forFPS: fps) == hold, "\(fps) fps")
            #expect(AnimationClock.holds(fps: fps, frames: 3) == [hold, hold, hold])
        }
        #expect(AnimationClock.holds(fps: 8, frames: 1) == [])
        #expect(AnimationClock.holds(fps: 0, frames: 1) == [], "a still sprite has no cadence")
    }

    @Test func forbiddenCadenceIsRefused() {
        for fps in [5.0, 10, 24, 0.5, 7, 0, -2, 2.5] {
            #expect(AnimationClock.hold(forFPS: fps) == nil, "\(fps) fps")
        }
    }

    @Test func holdsTrapOnAForbiddenCadence() async {
        await #expect(processExitsWith: .failure) {
            _ = AnimationClock.holds(fps: 5, frames: 2)
        }
    }

    @Test func frameIndexLoops() {
        let def = Self.sprite(frames: 3, holds: [2, 3, 4], loops: true)
        let expected = [0, 0, 1, 1, 1, 2, 2, 2, 2, 0, 0, 1]
        #expect((0..<12).map(def.frameIndex(atTick:)) == expected)
        #expect(def.frameIndex(atTick: 9 * 100 + 5) == 2)
        #expect(def.frameIndex(atTick: -1) == 2, "negative ticks wrap too")
    }

    @Test func frameIndexStopsOnTheLastFrame() {
        let def = Self.sprite(frames: 3, holds: [2, 2, 2], loops: false)
        #expect((0..<8).map(def.frameIndex(atTick:)) == [0, 0, 1, 1, 2, 2, 2, 2])
        #expect(def.frameIndex(atTick: 10_000) == 2)
        #expect(def.frameIndex(atTick: -5) == 0)
        #expect(Self.sprite(frames: 1, holds: []).frameIndex(atTick: 77) == 0)
    }

    @Test func sizeComesFromTheFrames() {
        let def = Self.sprite(frames: 2, holds: [3, 3], width: 5, height: 7)
        #expect(def.width == 5 && def.height == 7)
    }

    // MARK: Lint

    /// A clean sprite: paper frames, optional stone/slate faces for a light probe.
    static func sprite(frames: Int = 1, holds: [Int] = [], loops: Bool = true, width: Int = 4, height: Int = 4,
                       key: SpriteKey = SpriteKey("test.sprite")) -> SpriteDef {
        SpriteDef(key: key, category: .decor, anchor: PixelPoint(width / 2, height),
                  frames: Array(repeating: PixelImage(width: width, height: height, fill: paper), count: frames),
                  holds: holds, loops: loops)
    }

    static func probed(inverted: Bool) -> SpriteDef {
        var frame = PixelImage(width: 4, height: 2, fill: Palette.color(.stone))
        frame.fill(PixelRect(x: 2, y: 0, width: 2, height: 2), Palette.color(.slate))
        var def = sprite()
        def.frames = [frame]
        def.anchor = PixelPoint(2, 2)
        let left = PixelRect(x: 0, y: 0, width: 2, height: 2), right = PixelRect(x: 2, y: 0, width: 2, height: 2)
        def.lightProbe = inverted ? LightProbe(left: right, right: left) : LightProbe(left: left, right: right)
        return def
    }

    @Test func cleanSpriteHasNoIssue() {
        #expect(SpriteLint.issues(Self.sprite()) == [])
        #expect(SpriteLint.issues(Self.sprite(frames: 4, holds: [3, 3, 3, 3], loops: false)) == [])
        #expect(SpriteLint.issues(Self.probed(inverted: false)) == [])
        // Anchors on the far edges are inside [0, w] × [0, h].
        var edge = Self.sprite()
        edge.anchor = PixelPoint(4, 0)
        #expect(SpriteLint.issues(edge) == [])
        // Transparent pixels are fine; so is the full palette of a hue.
        var mixed = Self.sprite()
        mixed.frames[0][0, 0] = .clear
        mixed.frames[0][1, 0] = Palette.hue(7).dark
        #expect(SpriteLint.issues(mixed) == [])
    }

    @Test func lintCatchesEveryRule() {
        var faulty: [(String, SpriteDef)] = []

        var translucent = Self.sprite()
        translucent.frames[0][1, 1] = RGBA8(r: 0xE8, g: 0xE4, b: 0xD8, a: 128)
        faulty.append(("alpha", translucent))

        var offPalette = Self.sprite()
        offPalette.frames[0][2, 2] = RGBA8(r: 1, g: 2, b: 3)
        faulty.append(("palette", offPalette))

        var keyColour = Self.sprite()
        keyColour.frames[0][0, 3] = Palette.keyBase
        faulty.append(("key colour", keyColour))

        var yellow = Self.sprite(key: SpriteKey("desk", variant: "light", facing: .se))
        yellow.frames[0][0, 0] = Palette.color(.alertYellow)
        faulty.append(("alertYellow", yellow))

        var thirteen = Self.sprite(width: 13, height: 1)
        let roles = PaletteRole.allCases.filter { $0 != .ink && $0 != .alertYellow }.prefix(13)
        for (x, role) in roles.enumerated() { thirteen.frames[0][x, 0] = Palette.color(role) }
        faulty.append(("colours", thirteen))

        faulty.append(("holds", Self.sprite(frames: 2, holds: [3])))
        faulty.append(("holds", Self.sprite(frames: 2, holds: [5, 5])))
        faulty.append(("holds", Self.sprite(frames: 1, holds: [4])))

        var sizes = Self.sprite(frames: 2, holds: [4, 4])
        sizes.frames[1] = PixelImage(width: 4, height: 5, fill: Self.paper)
        faulty.append(("size", sizes))

        var anchor = Self.sprite()
        anchor.anchor = PixelPoint(5, 2)
        faulty.append(("anchor", anchor))
        var anchorUp = Self.sprite()
        anchorUp.anchor = PixelPoint(1, -1)
        faulty.append(("anchor", anchorUp))

        faulty.append(("light probe", Self.probed(inverted: true)))

        var blindProbe = Self.probed(inverted: false)
        blindProbe.lightProbe = LightProbe(left: PixelRect(x: 0, y: 0, width: 2, height: 2), right: PixelRect(x: 9, y: 9, width: 2, height: 2))
        faulty.append(("light probe", blindProbe))

        var empty = Self.sprite()
        empty.frames = []
        faulty.append(("frame", empty))

        for (rule, def) in faulty {
            let issues = SpriteLint.issues(def)
            #expect(!issues.isEmpty, "\(rule) not caught")
            #expect(issues.contains { $0.contains(rule) }, "\(rule): \(issues)")
            #expect(issues.allSatisfy { $0.hasPrefix(def.key.name) }, "issues name their sprite")
        }
    }

    @Test func alertYellowIsAllowedOnlyWhereListed() {
        for key in [SpriteKey("ov.bang"), SpriteKey("ov.bang", variant: "xl"), SpriteKey("screen.waiting", facing: .ne),
                    SpriteKey("monitor.back", variant: "led.waiting", facing: .sw)] {
            var def = Self.sprite(key: key)
            def.frames[0][0, 0] = Palette.color(.alertYellow)
            #expect(SpriteLint.issues(def) == [], "\(key.name)")
        }
        var led = Self.sprite(key: SpriteKey("monitor.back", variant: "led.error", facing: .se))
        led.frames[0][0, 0] = Palette.color(.alertYellow)
        #expect(!SpriteLint.issues(led).isEmpty)
    }

    @Test func inkAndOutlineColoursAreOutsideTheCap() {
        // 12 colours + ink + two material outlines: clean.
        var def = Self.sprite(width: 15, height: 1)
        let roles = PaletteRole.allCases.filter { ![.ink, .alertYellow, .shade, .hairDark].contains($0) }.prefix(12)
        for (x, role) in roles.enumerated() { def.frames[0][x, 0] = Palette.color(role) }
        def.frames[0][12, 0] = Palette.color(.ink)
        def.frames[0][13, 0] = Palette.color(.shade)
        def.frames[0][14, 0] = Palette.color(.hairDark)
        #expect(!SpriteLint.issues(def).isEmpty, "without declared outlines: 14 colours")
        def.outlineColors = [Palette.color(.shade), Palette.color(.hairDark)]
        #expect(SpriteLint.issues(def) == [])
    }

    @Test func lintChecksEveryFrame() {
        var def = Self.sprite(frames: 3, holds: [4, 4, 4])
        def.frames[2][3, 3] = Palette.keyDark
        let issues = SpriteLint.issues(def)
        #expect(issues.count == 1)
        #expect(issues.first?.hasPrefix("test.sprite#2") == true)
    }

    // MARK: Scene vocabulary

    @Test func characterAnimationTable() {
        let table: [(CharacterAnimation, Int, Double, Bool)] = [
            (.stand, 2, 2, true), (.walk, 4, 8, true), (.sitDown, 2, 8, false), (.sitIdle, 2, 2, true),
            (.type, 4, 12, true), (.think, 2, 2, true), (.stretch, 6, 6, false), (.coffee, 4, 4, false),
            (.sleep, 2, 1.5, true), (.raiseHand, 4, 6, true), (.celebrate, 6, 8, false), (.grab, 4, 8, false),
            (.cough, 4, 6, true), (.wave, 2, 4, false),
        ]
        #expect(CharacterAnimation.allCases == table.map(\.0))
        for (animation, frames, fps, loops) in table {
            #expect(animation.framesPerFacing == frames, "\(animation)")
            #expect(animation.fps == fps, "\(animation)")
            #expect(animation.loops == loops, "\(animation)")
            #expect(animation.spriteID == SpriteID("agent.\(animation.rawValue)"))
            #expect(AnimationClock.hold(forFPS: animation.fps) != nil, "\(animation): allowed cadence")
            #expect(animation.holds == AnimationClock.holds(fps: fps, frames: frames))
        }
        #expect(CharacterAnimation.raiseHand.drawnFacings == [.se])
        #expect(CharacterAnimation.raiseHand.facings == [.se, .sw])
        #expect(CharacterAnimation.type.drawnFacings == [.se, .ne])
        #expect(CharacterAnimation.type.facings == [.se, .ne, .sw, .nw])
    }

    @Test func characterFrameTotals() {
        let drawn = CharacterAnimation.allCases.reduce(0) { $0 + $1.framesPerFacing * $1.drawnFacings.count }
        let all = CharacterAnimation.allCases.reduce(0) { $0 + $1.framesPerFacing * $1.facings.count }
        #expect(drawn == 92)
        #expect(all == 184)
        let se = CharacterAnimation.allCases.filter { $0.facings.contains(.se) }.reduce(0) { $0 + $1.framesPerFacing }
        let ne = CharacterAnimation.allCases.filter { $0.facings.contains(.ne) }.reduce(0) { $0 + $1.framesPerFacing }
        #expect(se == 48 && ne == 44)
    }

    @Test func screenStateTable() {
        let table: [(ScreenState, Int, Double)] = [
            (.off, 1, 0), (.boot, 4, 8), (.idle, 2, 1), (.thinking, 3, 4), (.working, 4, 8),
            (.waiting, 2, 4), (.done, 1, 0), (.error, 3, 8), (.quota, 2, 1), (.background, 3, 2),
        ]
        #expect(ScreenState.allCases == table.map(\.0))
        for (state, frames, fps) in table {
            #expect(state.frames == frames, "\(state)")
            #expect(state.fps == fps, "\(state)")
            #expect(state.spriteID == SpriteID("screen.\(state.rawValue)"))
            #expect(state.holds == AnimationClock.holds(fps: fps, frames: frames))
        }
    }

    @Test func toolIconForEveryToolKind() {
        let table: [(ToolKind, ToolIcon)] = [
            (.read, .read), (.edit, .edit), (.bash, .bash), (.search, .search), (.web, .web),
            (.subagent, .subagent), (.question, .question), (.mcp("github"), .mcp), (.other("Skill"), .other),
        ]
        for (kind, icon) in table { #expect(ToolIcon(kind) == icon, "\(kind)") }
        #expect(Set(table.map(\.1)) == Set(ToolIcon.allCases))
        #expect(ToolIcon.bash.spriteID == "ov.tool.bash")
        #expect(ToolIcon.allCases.map(\.spriteID.rawValue) == ToolIcon.allCases.map { "ov.tool.\($0.rawValue)" })
    }

    @Test func overlayAndBadgeVocabulary() {
        #expect(OverlayKind.allCases == [.bang, .dots, .tool, .zzz, .storm, .check, .background, .quota])
        #expect(SceneBadge.allCases.map(\.spriteID) == ["ov.stale", "ov.draft", "ov.degraded", "ov.unsafe", "ov.external"])
    }

    @Test func categories() {
        #expect(SpriteCategory.allCases.map(\.rawValue) == [
            "floors", "walls", "furniture", "deskItems", "decor", "lights", "monitors", "screens", "overlays",
            "effects", "hud", "characters",
        ])
    }
}
