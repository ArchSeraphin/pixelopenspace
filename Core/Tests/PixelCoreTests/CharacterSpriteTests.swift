import Foundation
import Testing
@testable import PixelCore

/// Characters of 7.4.4: looks, the 14 animations drawn toward SE and NE, their reshaded mirrors, agent.mini.
@Suite struct CharacterSpriteTests {
    static let defaultLook = ResolvedLook(AgentLook(), projectHue: 4)
    static let defaultSheet = CharacterSprites.sheet(look: AgentLook(), projectHue: 4)
    /// One sheet per sample look, built once for the whole suite.
    static let sampleSheets: [CharacterSheet] = CharacterSprites.sampleLooks.map {
        CharacterSprites.sheet(look: $0, projectHue: 2)
    }

    static func frame(_ sheet: CharacterSheet, _ animation: CharacterAnimation, _ facing: Facing,
                      _ index: Int = 0) -> PixelImage {
        guard let def = sheet.def(animation, facing) else {
            preconditionFailure("no \(animation)@\(facing)")
        }
        return def.frames[index]
    }

    static func canvas(_ animation: CharacterAnimation, _ facing: Facing, frame: Int = 0,
                       look: ResolvedLook = defaultLook) -> SlotCanvas {
        guard let canvas = CharacterSprites.canvas(animation, facing, frame: frame, look: look) else {
            preconditionFailure("no canvas for \(animation)@\(facing)#\(frame)")
        }
        return canvas
    }

    /// 4-connected components of `slot`, as lists of (x, y).
    static func components(of slot: Slot, in canvas: SlotCanvas) -> [[PixelPoint]] {
        var seen = Set<PixelPoint>()
        var out: [[PixelPoint]] = []
        for y in 0..<canvas.height {
            for x in 0..<canvas.width where canvas[x, y] == slot && !seen.contains(PixelPoint(x, y)) {
                var stack = [PixelPoint(x, y)]
                var component: [PixelPoint] = []
                seen.insert(PixelPoint(x, y))
                while let p = stack.popLast() {
                    component.append(p)
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let q = PixelPoint(p.x + dx, p.y + dy)
                        guard q.x >= 0, q.y >= 0, q.x < canvas.width, q.y < canvas.height,
                              canvas[q.x, q.y] == slot, !seen.contains(q) else { continue }
                        seen.insert(q)
                        stack.append(q)
                    }
                }
                out.append(component.sorted { ($0.y, $0.x) < ($1.y, $1.x) })
            }
        }
        return out
    }

    // MARK: Sheet structure

    @Test func frameCounts() {
        let defs = Self.defaultSheet.defs
        func frames(_ facing: Facing) -> Int {
            defs.filter { $0.key.facing == facing }.reduce(0) { $0 + $1.frames.count }
        }
        #expect(frames(.se) == 48)
        #expect(frames(.ne) == 44)
        #expect(frames(.sw) == 48)
        #expect(frames(.nw) == 44)
        #expect(defs.reduce(0) { $0 + $1.frames.count } == 184)
        #expect(defs.count == 13 * 4 + 2)
        #expect(defs.map(\.key) == defs.map(\.key).sorted(), "defs are sorted by key")
        #expect(Set(defs.map(\.key)).count == defs.count, "keys are unique")
    }

    @Test func sizesAnchorsHolds() {
        let sheet = Self.defaultSheet
        #expect(CharacterSprites.frameWidth == 32 && CharacterSprites.frameHeight == 56)
        #expect(CharacterSprites.anchor == PixelPoint(16, 53))
        for animation in CharacterAnimation.allCases {
            for facing in animation.facings {
                guard let def = sheet.def(animation, facing) else {
                    Issue.record("missing \(animation)@\(facing)")
                    continue
                }
                let name = def.key.name
                #expect(def.key == SpriteKey(animation.spriteID, variant: sheet.look.variantName, facing: facing), "\(name)")
                #expect(def.category == .characters, "\(name)")
                #expect(def.width == 32 && def.height == 56, "\(name)")
                #expect(def.frames.allSatisfy { $0.width == 32 && $0.height == 56 }, "\(name)")
                #expect(def.anchor == PixelPoint(16, 53), "\(name)")
                #expect(def.frames.count == animation.framesPerFacing, "\(name)")
                #expect(def.holds == AnimationClock.holds(fps: animation.fps, frames: animation.framesPerFacing), "\(name)")
                #expect(def.loops == animation.loops, "\(name)")
                #expect(def.outlineColors == sheet.look.outlineColors, "\(name)")
                if animation.drawnFacings.contains(facing) {
                    #expect(def.derivation == nil && def.source == nil, "\(name) is drawn")
                } else {
                    #expect(def.derivation == .mirrorReshaded, "\(name)")
                    #expect(def.source == SpriteKey(animation.spriteID, variant: sheet.look.variantName,
                                                    facing: facing.mirrored), "\(name)")
                }
            }
        }
        #expect(Self.defaultSheet.def(.type, .se)?.key.name == "agent.type~s0h0c0op4a0@se")
    }

    @Test func sheetFramesAreRenderedCanvases() {
        let sheet = Self.defaultSheet
        for def in sheet.defs {
            guard let facing = def.key.facing,
                  let animation = CharacterAnimation.allCases.first(where: { $0.spriteID == def.key.id }) else {
                Issue.record("unexpected key \(def.key.name)")
                continue
            }
            for (index, frame) in def.frames.enumerated() {
                #expect(frame == Self.canvas(animation, facing, frame: index).render(sheet.look), "\(def.key.name)#\(index)")
            }
        }
    }

    @Test func raiseHandOnlyTowardViewer() {
        let sheet = Self.defaultSheet
        #expect(sheet.def(.raiseHand, .se) != nil)
        #expect(sheet.def(.raiseHand, .sw) != nil)
        #expect(sheet.def(.raiseHand, .ne) == nil)
        #expect(sheet.def(.raiseHand, .nw) == nil)
        #expect(CharacterSprites.canvas(.raiseHand, .ne, frame: 0, look: Self.defaultLook) == nil)
        #expect(CharacterSprites.canvas(.raiseHand, .nw, frame: 0, look: Self.defaultLook) == nil)
        #expect(CharacterSprites.canvas(.type, .se, frame: 4, look: Self.defaultLook) == nil, "type has 4 frames")
        for animation in CharacterAnimation.allCases where animation != .raiseHand {
            for facing in Facing.allCases { #expect(sheet.def(animation, facing) != nil, "\(animation)@\(facing)") }
        }
    }

    // MARK: Palette and lint

    @Test func paletteAndColorCapOnSampledLooks() {
        for sheet in Self.sampleSheets {
            for def in sheet.defs {
                var first = def
                first.frames = [def.frames[0]]
                first.holds = []
                let issues = SpriteLint.issues(first)
                #expect(issues.isEmpty, "\(issues)")
            }
        }
        // Three complete sheets, every frame.
        for index in [0, 7, 13] {
            for def in Self.sampleSheets[index].defs {
                let issues = SpriteLint.issues(def)
                #expect(issues.isEmpty, "\(issues)")
            }
        }
        for def in Self.defaultSheet.defs {
            let issues = SpriteLint.issues(def)
            #expect(issues.isEmpty, "\(issues)")
        }
    }

    @Test func neverAlertYellowNorKeyColours() {
        let forbidden: Set<RGBA8> = Palette.keyColors.union([Palette.color(.alertYellow)])
        for sheet in Self.sampleSheets + [Self.defaultSheet] {
            for def in sheet.defs {
                for frame in def.frames {
                    #expect(Set(frame.distinctColors).isDisjoint(with: forbidden), "\(def.key.name)")
                }
            }
        }
        for hue in 0..<10 {
            for frame in CharacterSprites.mini(projectHue: hue).frames {
                #expect(Set(frame.distinctColors).isDisjoint(with: forbidden))
            }
        }
    }

    // MARK: Proportions (7.10)

    @Test func threeAndHalfHeads() throws {
        let stand = Self.frame(Self.defaultSheet, .stand, .se)
        let bounds = try #require(stand.opaqueBounds)
        let ratio = Double(bounds.height) / Double(CharacterSprites.headHeight)
        #expect(ratio >= 3.2 && ratio <= 3.8, "\(bounds.height) px for a head of \(CharacterSprites.headHeight) px: \(ratio)")
    }

    @Test func eyesAreOneByTwo() {
        var looks = [Self.defaultLook]
        looks += CharacterSprites.sampleLooks.map { ResolvedLook($0, projectHue: 2) }
        for look in looks {
            for animation in [CharacterAnimation.sitIdle, .stand] {
                for facing in [Facing.se, .sw] {
                    let canvas = Self.canvas(animation, facing, look: look)
                    let eyes = Self.components(of: .eye, in: canvas)
                    #expect(eyes.count == 2, "\(animation)@\(facing) \(look.variantName): \(eyes.count) eyes")
                    for eye in eyes {
                        let xs = Set(eye.map(\.x)), ys = Set(eye.map(\.y))
                        #expect(eye.count == 2 && xs.count == 1 && ys.count == 2,
                                "\(animation)@\(facing) \(look.variantName): eye \(eye)")
                    }
                }
            }
        }
    }

    /// Below each eye, and between the eyes, only skin and its shade down to the chin outline: no mouth.
    @Test func noMouthAtRest() {
        for animation in [CharacterAnimation.stand, .sitIdle, .type, .think, .sleep] {
            for facing in [Facing.se, .sw] {
                for frame in 0..<animation.framesPerFacing {
                    let canvas = Self.canvas(animation, facing, frame: frame)
                    let eyes = Self.components(of: .eye, in: canvas).flatMap { $0 }
                    guard let minX = eyes.map(\.x).min(), let maxX = eyes.map(\.x).max(),
                          let bottom = eyes.map(\.y).max() else {
                        Issue.record("\(animation)@\(facing)#\(frame): no eye")
                        continue
                    }
                    for x in minX...maxX {
                        var y = bottom + 1
                        while y < canvas.height, canvas[x, y] == .skin || canvas[x, y] == .skinShade { y += 1 }
                        #expect(y > bottom + 1, "\(animation)@\(facing)#\(frame): no skin under the eyes at x \(x)")
                        #expect(y < canvas.height && canvas[x, y] == .skinOutline,
                                "\(animation)@\(facing)#\(frame): \(y < canvas.height ? "\(canvas[x, y])" : "edge") at (\(x), \(y)) under the eyes")
                    }
                }
            }
        }
    }

    /// Opaque in one canvas and not in the other.
    static func silhouetteDifference(_ a: SlotCanvas, _ b: SlotCanvas) -> Int {
        zip(a.cells, b.cells).filter { ($0 == .clear) != ($1 == .clear) }.count
    }

    /// Bounds of the hair and of the accessory worn on it (x range, top row); nil when the canvas has none.
    static func hairBounds(_ canvas: SlotCanvas) -> (minX: Int, maxX: Int, top: Int)? {
        let hair: Set<Slot> = [.hair, .hairShade, .hairOutline, .accessory, .accessoryShade]
        var minX = Int.max, maxX = Int.min, top = Int.max
        for y in 0..<canvas.height {
            for x in 0..<canvas.width where hair.contains(canvas[x, y]) {
                minX = min(minX, x)
                maxX = max(maxX, x)
                top = min(top, y)
            }
        }
        return minX <= maxX ? (minX, maxX, top) : nil
    }

    /// 7.9: asleep, the agent is slumped over its desk, the head on its folded arms. At ×1 and without the "zZ" the
    /// silhouette must not read as sitIdle with closed eyes: many texels differ, and the head leaves the axis of the
    /// hips toward the desk (+x when drawn, −x for the mirrors), lower than at rest when seen from the front.
    @Test func sleepIsSlumpedNotSitIdle() throws {
        let looks = [Self.defaultLook] + CharacterSprites.sampleLooks.map { ResolvedLook($0, projectHue: 2) }
        for look in looks {
            for facing in Facing.allCases {
                for frame in 0..<CharacterAnimation.sleep.framesPerFacing {
                    let idle = Self.canvas(.sitIdle, facing, frame: frame % CharacterAnimation.sitIdle.framesPerFacing,
                                           look: look)
                    let sleep = Self.canvas(.sleep, facing, frame: frame, look: look)
                    let label = "sleep@\(facing)#\(frame) \(look.variantName)"
                    let differing = Self.silhouetteDifference(idle, sleep)
                    #expect(differing >= 160, "\(label): only \(differing) texels differ from sitIdle")
                    let idleHair = try #require(Self.hairBounds(idle)), sleepHair = try #require(Self.hairBounds(sleep))
                    let shift = (sleepHair.minX + sleepHair.maxX) - (idleHair.minX + idleHair.maxX)
                    let towardDesk = facing == .se || facing == .ne ? shift : -shift
                    #expect(towardDesk >= 2 * 5, "\(label): the head moves \(towardDesk / 2) px toward the desk")
                    if facing.isTowardViewer {
                        #expect(sleepHair.top - idleHair.top >= 8,
                                "\(label): the head is only \(sleepHair.top - idleHair.top) px lower than at rest")
                    }
                    // Long hair falls forward with the head, not down the bent back.
                    let pose = CharacterPoses.slumped(facing.isTowardViewer ? .front : .back)
                    let chin = pose.head.y + CharacterParts.headSize - 1
                    let hairBelowChin = (chin..<sleep.height).contains { y in
                        (0..<sleep.width).contains { [.hair, .hairShade, .hairOutline].contains(sleep[$0, y]) }
                    }
                    #expect(!hairBelowChin, "\(label): hair below the chin (row \(chin))")
                }
            }
        }
    }

    @Test func feetOnAnchor() throws {
        for facing in Facing.allCases {
            for index in 0..<2 {
                let bounds = try #require(Self.frame(Self.defaultSheet, .stand, facing, index).opaqueBounds)
                #expect(bounds.y + bounds.height - 1 == 53, "stand@\(facing)#\(index)")
                #expect(bounds.x < 16 && bounds.x + bounds.width > 16, "stand@\(facing)#\(index): feet around x 16")
            }
        }
    }

    @Test func seatedPosesKeepTheirFeetOnTheFloor() throws {
        for animation in [CharacterAnimation.sitIdle, .type, .think] {
            for facing in animation.facings {
                let bounds = try #require(Self.frame(Self.defaultSheet, animation, facing).opaqueBounds)
                #expect(bounds.y + bounds.height <= 56, "\(animation)@\(facing)")
                #expect(bounds.y + bounds.height - 1 >= 50, "\(animation)@\(facing): feet near the floor")
            }
        }
    }

    // MARK: Looks

    @Test func looksAreDistinct() {
        func image(_ look: AgentLook) -> String {
            let resolved = ResolvedLook(look, projectHue: 4)
            return Self.canvas(.sitIdle, .se, look: resolved).render(resolved).fingerprint
        }
        let hairStyles = (0..<CharacterPalette.hairStyleCount).map { image(AgentLook(hairStyle: $0)) }
        #expect(Set(hairStyles).count == CharacterPalette.hairStyleCount, "6 distinct haircuts")
        let accessories = (0..<CharacterPalette.accessoryCount).map { image(AgentLook(accessory: $0)) }
        #expect(Set(accessories).count == CharacterPalette.accessoryCount, "none, glasses, headphones, beanie")
        #expect(image(AgentLook(accessory: nil)) == image(AgentLook(accessory: 0)), "nil and 0: no accessory")
        let hairColors = (0..<CharacterPalette.hairColorCount).map { image(AgentLook(hairColor: $0)) }
        #expect(Set(hairColors).count == CharacterPalette.hairColorCount)
        let skins = (0..<CharacterPalette.skinCount).map { image(AgentLook(skin: $0)) }
        #expect(Set(skins).count == CharacterPalette.skinCount)
        let outfits = (0..<CharacterPalette.outfitCount).map { image(AgentLook(outfitPaletteIndex: $0)) }
        #expect(Set(outfits).count == CharacterPalette.outfitCount)
        // Two haircuts also differ in silhouette, not only in colour.
        let short = Self.canvas(.stand, .se, look: ResolvedLook(AgentLook(hairStyle: 0), projectHue: 4))
        let bun = Self.canvas(.stand, .se, look: ResolvedLook(AgentLook(hairStyle: 4), projectHue: 4))
        #expect(short != bun)
    }

    /// Row A shows every agent from behind. With grey hair (Zéphyr, Lou) a uniform cap closed by its outline read as
    /// a helmet or a beanie: every haircut now has strands inside the hair (outline texels surrounded by hair), and
    /// the short cuts (short, bun, buzz cut) leave the ears and the nape bare.
    @Test func hairFromBehindIsNotACap() {
        let hair: Set<Slot> = [.hair, .hairShade, .hairOutline], skin: Set<Slot> = [.skin, .skinShade]
        for style in 0..<CharacterPalette.hairStyleCount {
            for facing in [Facing.ne, .nw] {
                let look = ResolvedLook(AgentLook(hairStyle: style, hairColor: 3), projectHue: 4)
                let canvas = Self.canvas(.sitIdle, facing, look: look)
                func isHair(_ x: Int, _ y: Int) -> Bool {
                    x >= 0 && y >= 0 && x < canvas.width && y < canvas.height && hair.contains(canvas[x, y])
                }
                var strands = 0
                for y in 0..<canvas.height {
                    for x in 0..<canvas.width where canvas[x, y] == .hairOutline
                        && isHair(x - 1, y) && isHair(x + 1, y) && isHair(x, y - 1) && isHair(x, y + 1) {
                        strands += 1
                    }
                }
                #expect(strands >= 3, "haircut \(style)@\(facing): \(strands) strands")
                guard [0, 4, 5].contains(style) else { continue }
                // Nape: a row of bare skin right under the hair, wider than the neck.
                let nape = (1..<canvas.height).contains { y in
                    (0..<canvas.width).filter { skin.contains(canvas[$0, y]) && isHair($0, y - 1) }.count >= 6
                }
                #expect(nape, "haircut \(style)@\(facing): no bare nape under the hair")
                // Ears: skin on both sides of the hair, on the same row.
                let ears = (0..<canvas.height).contains { y in
                    let xs = (0..<canvas.width).filter { isHair($0, y) }
                    guard let left = xs.min(), let right = xs.max() else { return false }
                    return (0..<left).contains { skin.contains(canvas[$0, y]) }
                        && ((right + 1)..<canvas.width).contains { skin.contains(canvas[$0, y]) }
                }
                #expect(ears, "haircut \(style)@\(facing): no ear beside the hair")
            }
        }
    }

    @Test func beanieHidesHairRisingAboveTheHead() {
        for style in [1, 4] {
            let bare = Self.canvas(.stand, .se, look: ResolvedLook(AgentLook(hairStyle: style), projectHue: 4))
            let capped = Self.canvas(.stand, .se, look: ResolvedLook(AgentLook(hairStyle: style, accessory: 3),
                                                                     projectHue: 4))
            let hair: Set<Slot> = [.hair, .hairShade, .hairOutline]
            let bareTop = (0..<5).contains { y in (0..<32).contains { hair.contains(bare[$0, y]) } }
            let cappedTop = (0..<5).contains { y in (0..<32).contains { hair.contains(capped[$0, y]) } }
            #expect(bareTop, "haircut \(style) rises above the head")
            #expect(!cappedTop, "haircut \(style) under a beanie")
        }
    }

    @Test func outfitFollowsTheProjectWhenUnset() {
        let ownHue = CharacterSprites.sheet(look: AgentLook(), projectHue: 6)
        let explicit = CharacterSprites.sheet(look: AgentLook(outfitPaletteIndex: 6), projectHue: 1)
        #expect(Self.frame(ownHue, .sitIdle, .se) == Self.frame(explicit, .sitIdle, .se))
        #expect(ownHue.look.variantName == "s0h0c0op6a0")
        #expect(Self.frame(ownHue, .sitIdle, .se).distinctColors.contains(Palette.hue(6).base))
    }

    @Test func deterministicSheets() {
        let a = CharacterSprites.sheet(look: AgentLook(skin: 2, hairStyle: 3, hairColor: 5, outfitPaletteIndex: 12,
                                                       accessory: 2), projectHue: 7)
        let b = CharacterSprites.sheet(look: AgentLook(skin: 2, hairStyle: 3, hairColor: 5, outfitPaletteIndex: 12,
                                                       accessory: 2), projectHue: 7)
        #expect(a.defs.map(\.key) == b.defs.map(\.key))
        #expect(a.defs.flatMap { $0.frames.map(\.fingerprint) } == b.defs.flatMap { $0.frames.map(\.fingerprint) })
    }

    @Test func sampleLooksCoverEveryOption() {
        let looks = CharacterSprites.sampleLooks
        let resolved = looks.map { ResolvedLook($0, projectHue: 0) }
        #expect(Set(resolved.map(\.skin)) == Set(0..<CharacterPalette.skinCount))
        #expect(Set(resolved.map(\.hairStyle)) == Set(0..<CharacterPalette.hairStyleCount))
        #expect(Set(resolved.map(\.hairColor)) == Set(0..<CharacterPalette.hairColorCount))
        #expect(Set(looks.compactMap(\.outfitPaletteIndex)) == Set(0..<CharacterPalette.outfitCount))
        #expect(Set(resolved.map(\.accessory)) == Set(0..<CharacterPalette.accessoryCount))
        #expect(Set(resolved.map(\.variantName)).count == looks.count, "every sample look is different")
    }

    @Test func variantNameAndClamping() {
        #expect(ResolvedLook(AgentLook(skin: 0, hairStyle: 2, hairColor: 1), projectHue: 4).variantName == "s0h2c1op4a0")
        #expect(ResolvedLook(AgentLook(outfitPaletteIndex: 13, accessory: 3), projectHue: 4).variantName == "s0h0c0o13a3")
        #expect(ResolvedLook(AgentLook(outfitPaletteIndex: 2), projectHue: 9).variantName == "s0h0c0op2a0")
        let clamped = ResolvedLook(AgentLook(skin: 9, hairStyle: -1, hairColor: 40, outfitPaletteIndex: 99, accessory: 7),
                                   projectHue: 12)
        #expect(clamped.variantName == "s3h0c7o15a3")
        #expect(ResolvedLook(AgentLook(), projectHue: -3).variantName == "s0h0c0op0a0")
        #expect(ResolvedLook(AgentLook(), projectHue: 30).variantName == "s0h0c0op9a0")
    }

    @Test func lookTables() {
        func c(_ role: PaletteRole) -> RGBA8 { Palette.color(role) }
        let skins: [(PaletteRole, PaletteRole, PaletteRole)] = [
            (.skin1, .skin2, .skin3), (.skin2, .skin3, .skin4), (.skin3, .skin4, .hairDark), (.skin4, .hairDark, .ink),
        ]
        for (index, tones) in skins.enumerated() {
            let look = ResolvedLook(AgentLook(skin: index), projectHue: 0)
            #expect(look.color(.skin) == c(tones.0) && look.color(.skinShade) == c(tones.1)
                    && look.color(.skinOutline) == c(tones.2), "skin \(index)")
        }
        let hairs: [(RGBA8, RGBA8, RGBA8)] = [
            (c(.hairDark), c(.ink), c(.ink)), (c(.woodMid), c(.woodDark), c(.hairDark)),
            (c(.woodLight), c(.woodMid), c(.woodDark)), (c(.stone), c(.slate), c(.shade)),
            (c(.paper), c(.mist), c(.stone)), (Palette.hue(0).base, Palette.hue(0).dark, c(.ink)),
            (Palette.hue(1).base, Palette.hue(1).dark, c(.woodDark)), (Palette.hue(6).base, Palette.hue(6).dark, c(.ink)),
        ]
        for (index, tones) in hairs.enumerated() {
            let look = ResolvedLook(AgentLook(hairColor: index), projectHue: 0)
            #expect(look.color(.hair) == tones.0 && look.color(.hairShade) == tones.1
                    && look.color(.hairOutline) == tones.2, "hair colour \(index)")
        }
        let neutrals: [(PaletteRole, PaletteRole, PaletteRole)] = [
            (.paper, .mist, .stone), (.stone, .slate, .shade), (.slate, .shade, .ink),
            (.woodMid, .woodDark, .hairDark), (.leaf, .leafDark, .ink), (.uiTitle, .shade, .ink),
        ]
        for hue in 0..<10 {
            let look = ResolvedLook(AgentLook(outfitPaletteIndex: hue), projectHue: 3)
            let tones = Palette.hue(hue)
            #expect(look.color(.top) == tones.base && look.color(.topShade) == tones.dark
                    && look.color(.topOutline) == tones.dark, "outfit \(hue)")
        }
        for (offset, tones) in neutrals.enumerated() {
            let look = ResolvedLook(AgentLook(outfitPaletteIndex: 10 + offset), projectHue: 3)
            #expect(look.color(.top) == c(tones.0) && look.color(.topShade) == c(tones.1)
                    && look.color(.topOutline) == c(tones.2), "outfit \(10 + offset)")
        }
        let projectOutfit = ResolvedLook(AgentLook(), projectHue: 5)
        #expect(projectOutfit.color(.top) == Palette.hue(5).base && projectOutfit.color(.topShade) == Palette.hue(5).dark)
        #expect(projectOutfit.color(.bottom) == c(.slate) && projectOutfit.color(.bottomShade) == c(.shade))
        #expect(projectOutfit.color(.eye) == c(.ink))
        #expect(projectOutfit.color(.clear) == nil)
        #expect(projectOutfit.color(.role(.paper)) == c(.paper))
        #expect(projectOutfit.outlineColors == [c(.skin3), c(.ink), Palette.hue(5).dark])
        for accessory in 1..<CharacterPalette.accessoryCount {
            let look = ResolvedLook(AgentLook(accessory: accessory), projectHue: 0)
            let base = look.color(.accessory), shade = look.color(.accessoryShade)
            #expect(base != nil && shade != nil, "accessory \(accessory)")
            if let base, let shade {
                #expect(Palette.spriteColors.contains(base) && Palette.spriteColors.contains(shade))
                #expect(base.luma > shade.luma, "accessory \(accessory): the shade is darker")
                #expect(base != c(.alertYellow) && shade != c(.alertYellow))
            }
        }
    }

    // MARK: agent.mini and catalog

    @Test func miniAgent() {
        var fingerprints = Set<String>()
        for hue in 0..<10 {
            let def = CharacterSprites.mini(projectHue: hue)
            #expect(def.key == SpriteKey("agent.mini", variant: "hue\(hue)"))
            #expect(def.category == .characters)
            #expect(def.width == 16 && def.height == 24)
            #expect(def.anchor == PixelPoint(8, 23))
            #expect(def.frames.count == 2 && def.holds == [6, 6] && def.loops)
            #expect(def.frames[0] != def.frames[1], "the two frames move")
            #expect(def.frames[0].distinctColors.contains(Palette.hue(hue).base), "wears the project hue")
            let issues = SpriteLint.issues(def)
            #expect(issues.isEmpty, "\(issues)")
            let bottom = def.frames[0].opaqueBounds.map { $0.y + $0.height - 1 }
            #expect(bottom == 23, "feet on the anchor")
            fingerprints.insert(def.frames[0].fingerprint)
        }
        #expect(fingerprints.count == 10)
    }

    @Test func catalogDefs() {
        let defs = CharacterSprites.catalogDefs()
        #expect(defs.count == 54 + 10)
        #expect(defs.map(\.key) == defs.map(\.key).sorted())
        #expect(Set(defs.map(\.key)).count == defs.count)
        let agentKeys = defs.filter { $0.key.id != "agent.mini" }.map(\.key)
        #expect(agentKeys == Self.defaultSheet.defs.map(\.key))
        #expect(defs.filter { $0.key.id == "agent.mini" }.map { $0.key.variant ?? "" } == (0..<10).map { "hue\($0)" })
        #expect(defs.allSatisfy { $0.category == .characters })
        for def in defs {
            let issues = SpriteLint.issues(def)
            #expect(issues.isEmpty, "\(issues)")
        }
    }

    // MARK: Preview

    /// `PIXEL_PREVIEW_DIR=<dir> swift test --filter preview`: one full sheet, the sample looks, agent.mini.
    @Test func preview() {
        guard PreviewWriter.directory(in: ProcessInfo.processInfo.environment) != nil else { return }
        let background = Palette.color(.floorLight)
        func sheetImage(_ sheet: CharacterSheet) -> PixelImage {
            var rows: [PixelImage] = []
            for animation in CharacterAnimation.allCases {
                var cells: [PixelImage] = []
                for facing in [Facing.se, .sw, .ne, .nw] {
                    guard let def = sheet.def(animation, facing) else { continue }
                    cells.append(PixelImage.stacked(def.frames, axis: .horizontal, spacing: 2))
                }
                rows.append(PixelImage.stacked(cells, axis: .horizontal, spacing: 8))
            }
            return PixelImage.stacked(rows, axis: .vertical, spacing: 4, background: background)
        }
        let full = sheetImage(Self.defaultSheet)
        PreviewWriter.write("characters-sheet", width: full.width, height: full.height, rgba: full.rgbaBytes, scale: 4)
        let other = sheetImage(Self.sampleSheets[9])
        PreviewWriter.write("characters-sheet-2", width: other.width, height: other.height, rgba: other.rgbaBytes, scale: 4)

        var looks: [PixelImage] = []
        for sheet in Self.sampleSheets {
            looks.append(PixelImage.stacked([Self.frame(sheet, .sitIdle, .se), Self.frame(sheet, .sitIdle, .sw),
                                             Self.frame(sheet, .sitIdle, .ne), Self.frame(sheet, .sitIdle, .nw),
                                             Self.frame(sheet, .stand, .se), Self.frame(sheet, .type, .ne)],
                                            axis: .vertical, spacing: 2))
        }
        let minis = (0..<10).map { PixelImage.stacked(CharacterSprites.mini(projectHue: $0).frames, axis: .vertical, spacing: 2) }
        let looksImage = PixelImage.stacked([PixelImage.stacked(looks, axis: .horizontal, spacing: 4),
                                             PixelImage.stacked(minis, axis: .horizontal, spacing: 4)],
                                            axis: .vertical, spacing: 8, background: background)
        PreviewWriter.write("characters-looks", width: looksImage.width, height: looksImage.height,
                            rgba: looksImage.rgbaBytes, scale: 4)
    }
}
