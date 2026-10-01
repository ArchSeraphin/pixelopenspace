import Foundation

/// Every sprite of the visual milestone (v0, décision 1), generated once by the sprite sets of `Assets/Sprites` and
/// `Assets/Characters`. The compositor, the contact sheets and the golden fingerprints read it; the app's
/// `SpriteRegistry` will pack it into atlases at stage 3.
public enum SpriteCatalog {
    /// The v0 ids, sorted: what 7.4 marks for stage 3, plus `light.cone`, `light.screenGlow` and `fx.star` (stage 4,
    /// needed by the night renders) and `elevator.led`. Left out: the SwiftUI skin of 7.4.6, the board post-its and
    /// pins, `trash`, `printer`, `ov.smoke`, `ov.speech`, the stage 4 and 6 effects, unlockable decor, portraits,
    /// the external outline, levels, badges and edit mode.
    public static let v0IDs: [SpriteID] = {
        var ids: [SpriteID] = [
            // 7.4.1 floors and marks
            "floor.hall", "floor.corridor", "floor.carpet",
            "floor.carpet.edge.n", "floor.carpet.edge.e", "floor.carpet.edge.s", "floor.carpet.edge.w",
            "floor.carpet.corner.n", "floor.carpet.corner.e", "floor.carpet.corner.s", "floor.carpet.corner.w",
            "floor.hover", "floor.dropTarget", "shadow.tile", "shadow.char", "shadow.small",
            // 7.4.2 walls and structure
            "wall.segment", "wall.window", "wall.corner", "pillar", "elevator", "elevator.led", "board.cork", "sign.island",
            // 7.4.3 post furniture
            "desk", "chair", "monitor.front", "monitor.back", "keyboard", "mug", "papers", "desk.postit", "desk.queue",
            "lamp.desk", "light.cone",
            // 7.4.4 characters
            "agent.mini",
            // 7.4.5 overlays
            "ov.bang", "ov.bang.halo", "ov.dots", "ov.zzz", "ov.storm", "ov.check", "ov.background", "ov.quota",
            "ov.edgeArrow", "ov.selection",
            // 7.4.7 post-its of the cork wall
            "postit.mini",
            // 7.4.8 effects
            "fx.dust", "fx.ding", "fx.pinDrop",
            // 7.4.9 base decor
            "decor.plantSmall", "decor.coffeeMachine",
            // 7.4.10 HUD and night lights
            "desk.nameplate", "desk.queueBadge", "minimap.frame", "minimap.viewport", "fx.star", "light.screenGlow",
        ]
        ids += ScreenState.allCases.map(\.spriteID)
        ids += CharacterAnimation.allCases.map(\.spriteID)
        ids += ToolIcon.allCases.map(\.spriteID)
        ids += SceneBadge.allCases.map(\.spriteID)
        for kind in AgentStateKind.allCases {
            ids.append(SpriteID("hud.state.\(kind.rawValue)"))
            ids.append(SpriteID("minimap.dot.\(kind.rawValue)"))
        }
        return ids.sorted()
    }()

    /// Every v0 sprite (all groups + `CharacterSprites.catalogDefs()`), sorted by key, built once.
    public static let all: [SpriteDef] = {
        let groups: [[SpriteDef]] = [
            FloorSprites.all(), WallSprites.all(), FurnitureSprites.all(), DeskItemSprites.all(), DecorSprites.all(),
            LightSprites.all(), MonitorSprites.all(), OverlaySprites.all(), EffectSprites.all(), HUDSprites.all(),
            CharacterSprites.catalogDefs(),
        ]
        return groups.flatMap { $0 }.sorted { $0.key < $1.key }
    }()

    /// Position of each key in `all`.
    private static let index: [SpriteKey: Int] = {
        var out: [SpriteKey: Int] = [:]
        for (position, def) in all.enumerated() where out[def.key] == nil { out[def.key] = position }
        return out
    }()

    public static func sprite(_ key: SpriteKey) -> SpriteDef? {
        index[key].map { all[$0] }
    }

    /// The sprites of one category, sorted by key.
    public static func sprites(in category: SpriteCategory) -> [SpriteDef] {
        all.filter { $0.category == category }
    }
}
