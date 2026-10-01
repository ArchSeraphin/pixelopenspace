import Foundation

/// The sprite sheet of one look: the 14 animations of 7.4.4 in every direction (184 frames).
public struct CharacterSheet: Sendable {
    public let look: ResolvedLook
    /// Sorted by key.
    public let defs: [SpriteDef]

    /// nil: raiseHand toward ne/nw (the avatar turns toward the viewer to raise its hand).
    public func def(_ animation: CharacterAnimation, _ facing: Facing) -> SpriteDef? {
        let key = SpriteKey(animation.spriteID, variant: look.variantName, facing: facing)
        return defs.first { $0.key == key }
    }
}

/// Characters of 7.4.4, composed on demand from parts (7.5): SE and NE are drawn, SW and NW are their flattened
/// mirrors, reshaded so the light stays top-left.
public enum CharacterSprites {
    public static let frameWidth = 32, frameHeight = 56
    /// Between the feet (7.3).
    public static let anchor = PixelPoint(16, 53)
    /// Hair top to chin outline: a standing figure is 49 px, about 3.5 heads (7.10).
    public static let headHeight = CharacterParts.headSize

    /// Key "agent.<animation>~<variantName>@<facing>"; SE and NE drawn, SW and NW = mirrorReshaded.
    public static func sheet(look: AgentLook, projectHue: Int) -> CharacterSheet {
        let resolved = ResolvedLook(look, projectHue: projectHue)
        var defs: [SpriteDef] = []
        func key(_ animation: CharacterAnimation, _ facing: Facing) -> SpriteKey {
            SpriteKey(animation.spriteID, variant: resolved.variantName, facing: facing)
        }
        for animation in CharacterAnimation.allCases {
            for facing in animation.drawnFacings {
                // Each drawn frame is composed once; its mirror is derived from the same canvas.
                let drawn = (0..<animation.framesPerFacing).compactMap {
                    canvas(animation, facing, frame: $0, look: resolved)
                }
                let mirrors = drawn.map { $0.flattened().mirrored().reshaded() }
                for (target, canvases) in [(facing, drawn), (facing.mirrored, mirrors)] {
                    let isMirror = target != facing
                    defs.append(SpriteDef(
                        key: key(animation, target), category: .characters, anchor: anchor,
                        frames: canvases.map { $0.render(resolved) }, holds: animation.holds, loops: animation.loops,
                        derivation: isMirror ? .mirrorReshaded : nil, source: isMirror ? key(animation, facing) : nil,
                        outlineColors: resolved.outlineColors))
                }
            }
        }
        return CharacterSheet(look: resolved, defs: defs.sorted { $0.key < $1.key })
    }

    /// One frame in slot space (before colours): SE and NE composed from parts, SW and NW =
    /// `drawn.flattened().mirrored().reshaded()`. nil for raiseHand toward ne/nw or a frame out of range.
    public static func canvas(_ animation: CharacterAnimation, _ facing: Facing, frame: Int,
                              look: ResolvedLook) -> SlotCanvas? {
        guard animation.facings.contains(facing), frame >= 0, frame < animation.framesPerFacing else { return nil }
        if !animation.drawnFacings.contains(facing) {
            return canvas(animation, facing.mirrored, frame: frame, look: look)?.flattened().mirrored().reshaded()
        }
        let view: CharacterParts.View = facing == .se ? .front : .back
        let poses = CharacterPoses.frames(animation, view)
        guard frame < poses.count else { return nil }
        return compose(poses[frame], view: view, look: look)
    }

    static func compose(_ pose: CharacterPoses.Pose, view: CharacterParts.View, look: ResolvedLook) -> SlotCanvas {
        var canvas = SlotCanvas(width: frameWidth, height: frameHeight)
        let legs = CharacterParts.legs(pose.legs, view)
        canvas.draw(legs.map, x: legs.dx, y: legs.dy)
        canvas.draw(CharacterParts.torso(view), x: pose.torso.x, y: pose.torso.y)
        let arms = CharacterParts.arms(pose.arms, view)
        let armsLast = CharacterParts.armsOverHead(pose.arms, view)
        func drawArms() {
            for piece in arms { canvas.draw(piece.map, x: pose.torso.x + piece.dx, y: pose.torso.y + piece.dy) }
        }
        if !armsLast { drawArms() }
        canvas.draw(CharacterParts.head(view, eyes: pose.eyes), x: pose.head.x, y: pose.head.y)
        let hairY = pose.head.y + CharacterParts.hairOffsetY
        canvas.draw(CharacterParts.hair(style: look.hairStyle, view), x: pose.head.x, y: hairY)
        if look.accessory == CharacterParts.beanieKind {
            // The beanie flattens whatever hair rises above the head (spikes, bun).
            for y in max(hairY, 0)..<min(max(pose.head.y, 0), frameHeight) {
                for x in max(pose.head.x, 0)..<min(pose.head.x + CharacterParts.headSize, frameWidth) {
                    canvas[x, y] = .clear
                }
            }
        }
        if let accessory = CharacterParts.accessory(look.accessory, view) {
            canvas.draw(accessory, x: pose.head.x, y: hairY)
        }
        if armsLast { drawArms() }
        return canvas
    }

    // MARK: agent.mini

    /// agent.mini~hueN: a small helper in a cap of the project hue, posed beside a desk while sub-agents run.
    public static func mini(projectHue: Int) -> SpriteDef {
        let hue = CharacterPalette.clamp(projectHue, Palette.projectHues.count)
        let frames = [miniFrame0, miniFrame1].map { $0.renderDecor(hue: hue) }
        return SpriteDef(key: SpriteKey("agent.mini", variant: "hue\(hue)"), category: .characters,
                         anchor: PixelPoint(8, 23), frames: frames, holds: AnimationClock.holds(fps: 4, frames: 2),
                         loops: true, outlineColors: [Palette.hue(hue).dark, Palette.color(.skin3)])
    }

    /// The mini's face uses fixed skin roles (it has no look of its own).
    private static let miniLegend: [Character: Slot] = [
        "s": .role(.skin1), "S": .role(.skin2), "q": .role(.skin3), "e": .role(.ink),
    ]

    /// 16×24: cap and body in the hue (light top-left, dark outline), feet on the anchor row.
    static let miniFrame0 = PixelMap("""
        ................
        ................
        ................
        ................
        ......DDDD......
        .....DLLPPD.....
        ....DLPPPPPD....
        ....DDDDDDDDDD..
        ....qssssSSq....
        ....qsesseSq....
        ....qsesseSq....
        .....qssSSq.....
        ......qqqq......
        .....DLPPPD.....
        ....DLLPPPPD....
        ...DLDLPPPDPD...
        ...DD.DPPPD.DD..
        ......DPPPD.....
        ......DDDDD.....
        ......oo.oo.....
        ......oo.oo.....
        ......oo.oo.....
        .....ooo.ooo....
        .....ooo.ooo....
        """, legend: miniLegend)

    /// Second frame: stands taller and waves.
    static let miniFrame1 = PixelMap("""
        ................
        ................
        ................
        ......DDDD......
        .....DLLPPD.....
        ....DLPPPPPD....
        ....DDDDDDDDDD..
        ....qssssSSq....
        ....qsesseSq....
        ....qsesseSq.DD.
        .....qssSSq..DD.
        ......qqqq..DD..
        .....DLPPPDDD...
        ....DLLPPPPD....
        ...DLDLPPPDD....
        ...DD.DPPPD.....
        ......DPPPD.....
        ......DDDDD.....
        ......oo.oo.....
        ......oo.oo.....
        ......oo.oo.....
        ......oo.oo.....
        .....ooo.ooo....
        .....ooo.ooo....
        """, legend: miniLegend)

    // MARK: Catalog

    /// Catalog entries: the sheet of AgentLook() with hue 4, and agent.mini for hues 0…9, sorted by key.
    public static func catalogDefs() -> [SpriteDef] {
        let sheet = sheet(look: AgentLook(), projectHue: 4).defs
        let minis = (0..<Palette.projectHues.count).map { mini(projectHue: $0) }
        return (sheet + minis).sorted { $0.key < $1.key }
    }

    /// Looks of contact sheet 6: each skin, each haircut, each hair colour, each outfit (all 16), each accessory.
    public static let sampleLooks: [AgentLook] = (0..<CharacterPalette.outfitCount).map { index in
        AgentLook(skin: index % CharacterPalette.skinCount,
                  hairStyle: (index * 5 + 1) % CharacterPalette.hairStyleCount,
                  hairColor: (index * 3) % CharacterPalette.hairColorCount,
                  outfitPaletteIndex: index,
                  accessory: (index / 2) % CharacterPalette.accessoryCount)
    }
}
