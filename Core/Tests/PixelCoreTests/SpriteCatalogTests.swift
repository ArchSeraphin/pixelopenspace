import Foundation
import Testing
@testable import PixelCore

@Suite struct SpriteCatalogTests {
    static let all = SpriteCatalog.all

    @Test func coversEveryV0ID() {
        let present = Set(Self.all.map(\.key.id))
        let missing = SpriteCatalog.v0IDs.filter { !present.contains($0) }
        #expect(missing.isEmpty, "v0 ids without a sprite: \(missing)")
    }

    @Test func noUnknownIDs() {
        let known = Set(SpriteCatalog.v0IDs)
        let unknown = Set(Self.all.map(\.key.id)).subtracting(known).sorted()
        #expect(unknown.isEmpty, "sprites outside the v0 list: \(unknown)")
    }

    @Test func v0IDsAreSortedUniqueAndLeaveOutLaterStages() {
        let ids = SpriteCatalog.v0IDs
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        // Décision 1: what 7.4 marks for stage 3, plus light.cone, light.screenGlow, fx.star and elevator.led.
        for id: SpriteID in ["light.cone", "light.screenGlow", "fx.star", "elevator.led", "agent.mini", "postit.mini",
                             "sign.island", "board.cork", "desk.queueBadge", "minimap.viewport", "ov.edgeArrow"] {
            #expect(ids.contains(id), "\(id)")
        }
        for id: SpriteID in ["trash", "printer", "postit.card", "postit.corner", "pin.red", "tape", "ov.smoke", "ov.speech",
                             "fx.confetti", "fx.sparkle", "fx.steam", "fx.levelUp", "fx.xp", "portrait.mini",
                             "agent.outline.dashed", "hud.level", "hud.xpBar", "floor.editGrid", "decor.cactus", "ui.window"] {
            #expect(!ids.contains(id), "\(id) is not a v0 sprite")
        }
        // The vocabulary of the scene has a sprite each.
        for state in ScreenState.allCases { #expect(ids.contains(state.spriteID)) }
        for icon in ToolIcon.allCases { #expect(ids.contains(icon.spriteID)) }
        for badge in SceneBadge.allCases { #expect(ids.contains(badge.spriteID)) }
        for animation in CharacterAnimation.allCases { #expect(ids.contains(animation.spriteID)) }
        for kind in AgentStateKind.allCases {
            #expect(ids.contains(SpriteID("hud.state.\(kind.rawValue)")))
            #expect(ids.contains(SpriteID("minimap.dot.\(kind.rawValue)")))
        }
    }

    @Test func uniqueKeys() {
        let keys = Self.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys == keys.sorted(), "the catalog is sorted by key")
    }

    @Test func everySpriteIsLintClean() {
        let issues = Self.all.flatMap(SpriteLint.issues)
        #expect(issues.isEmpty, "\(issues.count) issue(s): \(issues.prefix(10))")
    }

    @Test func mirrorsMatchTheirSource() {
        let mirrors = Self.all.filter { $0.derivation == .mirror }
        #expect(!mirrors.isEmpty)
        for def in mirrors {
            guard let sourceKey = def.source, let source = SpriteCatalog.sprite(sourceKey) else {
                Issue.record("\(def.key.name): mirror without its source in the catalog")
                continue
            }
            #expect(source.derivation == nil, "\(def.key.name): the source is drawn")
            #expect(def.frames == source.frames.map { $0.mirrored() }, "\(def.key.name): frames")
            #expect(def.anchor == PixelPoint(source.width - source.anchor.x, source.anchor.y), "\(def.key.name): anchor")
            #expect(def.holds == source.holds && def.loops == source.loops, "\(def.key.name): timing")
        }
        // Reshaded mirrors (characters) are never plain mirrors.
        for def in Self.all where def.derivation == .mirrorReshaded {
            #expect(def.category == .characters, "\(def.key.name)")
            #expect(def.source.flatMap(SpriteCatalog.sprite) != nil, "\(def.key.name): source in the catalog")
        }
    }

    @Test func lookupAndCategories() {
        for def in Self.all.prefix(40) + Self.all.suffix(40) {
            #expect(SpriteCatalog.sprite(def.key)?.frames == def.frames, "\(def.key.name)")
        }
        #expect(SpriteCatalog.sprite(SpriteKey("desk", variant: "light", facing: .ne)) != nil)
        #expect(SpriteCatalog.sprite(SpriteKey("ov.bang", variant: "xl")) != nil)
        #expect(SpriteCatalog.sprite(SpriteKey("agent.mini", variant: "hue9")) != nil)
        #expect(SpriteCatalog.sprite(SpriteKey("no.such.sprite")) == nil)
        var total = 0
        for category in SpriteCategory.allCases {
            let defs = SpriteCatalog.sprites(in: category)
            #expect(!defs.isEmpty, "\(category)")
            #expect(defs.allSatisfy { $0.category == category })
            #expect(defs.map(\.key) == defs.map(\.key).sorted())
            total += defs.count
        }
        #expect(total == Self.all.count)
    }

    @Test func groupsAreConcatenated() {
        let groups = [FloorSprites.all(), WallSprites.all(), FurnitureSprites.all(), DeskItemSprites.all(),
                      DecorSprites.all(), LightSprites.all(), MonitorSprites.all(), OverlaySprites.all(),
                      EffectSprites.all(), HUDSprites.all(), CharacterSprites.catalogDefs()]
        #expect(groups.reduce(0) { $0 + $1.count } == Self.all.count)
        // The character sheet of the default look (hue 4): 184 frames, and the minis of the 10 hues.
        let characterFrames = SpriteCatalog.sprites(in: .characters).filter { $0.key.id != "agent.mini" }
            .reduce(0) { $0 + $1.frames.count }
        #expect(characterFrames == 184)
        #expect(SpriteCatalog.sprites(in: .characters).filter { $0.key.id == "agent.mini" }.count == 10)
    }
}
