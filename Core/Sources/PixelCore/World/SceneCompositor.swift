import Foundation

/// Software rendering of the whole scene (3.10): the picture SpriteKit draws, as a `PixelImage`, without a GPU, so
/// that the visual milestone renders under Linux and the app's captures have a reference. Pure and deterministic.
/// `ScenePlanner` decides what is drawn and where (`WorldScenePlan`); the compositor draws that plan at one tick of
/// the animation clock.
///
/// Order of a render, in texels (scaled by the zoom at the very end):
/// 1. the baked background (`SceneBackground`): the floor (hall parquet, corridors, the islands' rugs with their
///    borders), the shadows (drawn opaque in one layer, offset (+2, +1), applied once at 30 %, 7.3 rule 4, only over
///    the floor), and the pieces of the two back walls (whole world only);
/// 2. the wall layer: the cork wall and its mini post-its (spread in loose rows), the elevator and its LED;
/// 3. the world layer, back to front (`SceneNode.order`): floor marks (hover, drop target, selection), then hall
///    props, island signs (×2 in the overview) and plants, and every post (chair, avatar, desk, monitor, screen,
///    desk items, subagent minis);
/// 4. at night: the veil (multiply) over all of the above, then the lights of both light layers in one layer, added
///    once (the stars and the LED's light already clipped by the world in front of them, the lamp pools on the desk
///    tops, the screen glows around their monitors);
/// 5. the overlay layer, never veiled: state overlays, the "démarre" sign of a starting agent, tool bubbles, badges,
///    queue badges, name plates, the "+n" of the cork wall. The overview keeps only the urgent signs: the XL "!" of a
///    wait, the storm of an error and those agents' name plates (décision 2 of the first render).
public enum SceneCompositor {
    /// `render(ScenePlanner.plan(scene, options: ScenePlanOptions(options)), tick: options.tick, zoom: options.zoom)`.
    public static func render(_ scene: SceneInput, options: RenderOptions) -> PixelImage {
        render(ScenePlanner.plan(scene, options: ScenePlanOptions(options)), tick: options.tick, zoom: options.zoom)
    }

    /// The plan at `tick` (24 per second; animated sprites show their frame at `tick + tickOffset`), scaled for
    /// `zoom`: what SpriteKit shows, the reference of the app's captures.
    public static func render(_ plan: WorldScenePlan, tick: Int, zoom: SceneZoom) -> PixelImage {
        rasterize(frame(plan, tick: tick)).scaled(by: zoom.pixelsPerTexel)
    }

    /// The background alone at 1 pixel per texel (canvasWidth × canvasHeight): floor, shadows and wall pieces.
    /// Outside the world the pixels stay transparent.
    public static func background(_ plan: WorldScenePlan) -> PixelImage {
        rasterize(backgroundFrame(plan.background))
    }

    /// (W + D)·32 × ((W + D)·16 + 96) texels for a W × D rect (3.8): 24×24 → 1536×864, 36×24 → 1920×1056.
    public static func canvasSize(for rect: GridRect) -> (width: Int, height: Int) {
        let span = rect.size.w + rect.size.d
        return (span * IsoMath.tileWidth / 2, span * IsoMath.tileHeight / 2 + IsoMath.wallHeight)
    }

    /// Top vertex of a tile in that canvas (texels, y down): x = ((i − i0) − (j − j0) + D)·32,
    /// y = (i − i0 + j − j0)·16 + 96.
    public static func imagePoint(of tile: GridPoint, in rect: GridRect) -> PixelPoint {
        let di = tile.i - rect.origin.i, dj = tile.j - rect.origin.j
        return PixelPoint((di - dj + rect.size.d) * IsoMath.tileWidth / 2,
                          (di + dj) * IsoMath.tileHeight / 2 + IsoMath.wallHeight)
    }

    // MARK: Placements tuned on the milestone renders

    /// Px above the seat tile's centre where the primary overlay's anchor (its bottom) goes. Row B faces the viewer
    /// and has the aisle behind its head: 9 px over a seated head (top 45 px over the seat), 3 px over a raised hand
    /// (51). Row A turns its back to the viewer and, on screen, the desk of the post before it fills the space over
    /// its head: the overlay sits on the head (1 to 3 px over it), so that it reads as this agent's and not as that
    /// desk's; raised hand as in row B, standing (starting) 2 px over the head (48).
    static func overlayLift(_ p: AgentPresentation, row: IslandRow) -> Int {
        if p.animation == .raiseHand || row == .b { return 54 }
        return p.animation == .stand ? 50 : 48
    }
    /// Where the head of a sleeping agent lies, from where it is when seated (`CharacterPoses.slumped`): toward the
    /// desk and lower, 8 px aside and 13 px down from the front (SE), 7 px aside and 5 px down from the back (NE),
    /// mirrored toward SW and NW. The overlay ("zZ") follows it, so that it does not float over the empty place of a
    /// seated head. Zero for every other animation.
    static func headShift(_ p: AgentPresentation, facing: Facing) -> PixelPoint {
        guard p.animation == .sleep else { return PixelPoint(0, 0) }
        let lying = facing.isTowardViewer ? CharacterPoses.leanHeadFront : CharacterPoses.leanHeadBack
        let dx = lying.x - CharacterPoses.seatHead.x, dy = lying.y - CharacterPoses.seatHead.y
        return PixelPoint(facing == .se || facing == .ne ? dx : -dx, dy)
    }
    /// Centre of the "!" glyph above the overlay anchor, where the halo is centred (normal, XL).
    static let haloLift = (normal: 12, xl: 24)
    /// Gap between the primary overlay, the question bubble and the badges.
    static let badgeGap = 1
    /// Row A: where the name plate's bottom centre goes, from the seat tile's centre: under the post, on the floor
    /// in front of the chair.
    static let nameplateDrop = 18
    /// Row B: the name plate beside the head, on the side of the post before (the next post's overlays rise on the
    /// other side), its bottom 35 px over the seat tile's centre (the head spans about x −6…5, y −45…−36; a raised
    /// hand goes up at x −11). Offline, nobody sits there: the "OFF" plate takes the place of the head, centred over
    /// the chair (wider, it would cover the agent of the post before). Returns the plate's top-left corner.
    static func rowBNameplateOrigin(_ p: AgentPresentation, plate: (width: Int, height: Int),
                                    seat c: PixelPoint) -> PixelPoint {
        let bottom = c.y - 35 - plate.height
        guard p.animation != nil else { return PixelPoint(c.x - plate.width / 2, bottom) }
        return PixelPoint(c.x - (p.animation == .raiseHand ? 13 : 9) - plate.width, bottom)
    }
    /// The island sign stands on the outer corner of its tile, the rug's front-left corner (in the back corner, the
    /// overlays of desk B0 covered it), its foot this far from the tile's centre.
    static let signFoot = PixelPoint(-IsoMath.tileWidth / 2, 0)
    /// The sign drawn ×2 in the overview (0.5 pt per texel): its text keeps the 5 pt capitals of ×1.
    static let overviewSignScale = 2
    /// Queue badge anchor, from the anchor of `desk.queue`.
    static let queueBadgeOffset = PixelPoint(6, -5)
    /// Where the post-it stuck on the monitor goes: from the screen's anchor (row A), from the monitor's (row B).
    static let postitOnScreen = PixelPoint(4, -7)
    static let postitOnBack = PixelPoint(-6, -12)
    /// Subagent minis on the clearance tile, from its centre, the first one alone when there is one: in its left
    /// half, which the next post's desk (and, in row A, the next seated agent) does not hide.
    static func miniOffsets(rowFacesViewer: Bool) -> [PixelPoint] {
        rowFacesViewer ? [PixelPoint(-12, -6), PixelPoint(-2, -11)] : [PixelPoint(-20, 0), PixelPoint(-10, -8)]
    }
    /// A lamp's light pool (`light.cone`) has its anchor on the desk-top point under the lamp's base
    /// (`FurnitureSprites.lightConeOffset`) and is clipped to the desk top: the iso diamond of this half-width,
    /// `IsoMath.deskTopHeight` over the desk tile's centre (the top of `desk` spans x −30…29 around it). It never
    /// spills on the carpet.
    static let deskTopHalfWidth = 30
    /// Centre of a screen's glow: in front of the screen (row A, from the screen's anchor), on the agent's side of
    /// the monitor (row B, from the monitor's anchor).
    static let glowOnScreen = PixelPoint(-4, 0)
    static let glowOnBack = PixelPoint(6, -10)
    /// Shadow offset (7.2).
    static let shadowOffset = PixelPoint(2, 1)

    // MARK: Frame and raster

    /// What a plan draws at `tick`, image by image, in drawing order (tests and debugging read it).
    static func frame(_ plan: WorldScenePlan, tick: Int) -> SceneFrame {
        var frame = backgroundFrame(plan.background)
        frame.veilAlpha = plan.veilAlpha
        var characters: [CharacterFrameKey: PixelImage] = [:]
        for node in plan.nodes {
            guard let shown = image(of: node, tick: tick, cache: &characters) else { continue }
            let origin = plan.canvasOrigin(of: node)
            let placement = ScenePlacement(name: shown.name, key: shown.key, image: shown.image, origin: origin,
                                           tile: node.tile, order: node.order, sequence: frame.count, id: node.id,
                                           behindWorld: node.layer == .wallLight)
            switch node.layer {
            case .background: continue
            case .wall: frame.walls.append(placement)
            case .world: frame.world.append(placement)
            case .wallLight, .light:
                // A light that is not a light sprite (the LED) shines on its frame 0 only.
                if case .sprite(let key, _) = node.sprite, SpriteCatalog.sprite(key)?.category != .lights,
                   shown.frame != 0 { continue }
                frame.lights.append(placement)
            case .overlay: frame.overlays.append(placement)
            }
        }
        return frame
    }

    /// The frame of a scene: `frame(ScenePlanner.plan(scene, options: ScenePlanOptions(options)), tick:)`.
    static func frame(_ scene: SceneInput, options: RenderOptions) -> SceneFrame {
        frame(ScenePlanner.plan(scene, options: ScenePlanOptions(options)), tick: options.tick)
    }

    /// The baked pieces, frame 0 of their sprites.
    static func backgroundFrame(_ background: SceneBackground) -> SceneFrame {
        var frame = SceneFrame(width: background.width, height: background.height)
        var sequence = 0
        func placements(_ pieces: [SceneBackground.Piece]) -> [ScenePlacement] {
            pieces.enumerated().compactMap { index, piece in
                guard let def = SpriteCatalog.sprite(piece.key), def.frames.indices.contains(piece.frame) else { return nil }
                sequence += 1
                return ScenePlacement(name: piece.key.frameName(piece.frame), key: piece.key, image: def.frames[piece.frame],
                                      origin: piece.origin, tile: piece.tile, order: index, sequence: sequence - 1)
            }
        }
        frame.floor = placements(background.floor)
        frame.shadows = placements(background.shadows)
        frame.walls = placements(background.walls)
        return frame
    }

    struct CharacterFrameKey: Hashable {
        var look: AgentLook
        var hue: Int
        var animation: CharacterAnimation
        var facing: Facing
        var frame: Int
    }

    /// What a node shows at `tick`: the image, its name ("desk~light@ne#0", "sign:API"), its catalog key (the
    /// character sheet's key for an avatar, nil for a composed image) and its frame. Character frames are composed
    /// as the sheets compose them (`CharacterSprites.canvas`); nil for a sprite missing from the catalog.
    static func image(of node: SceneNode, tick: Int) -> (image: PixelImage, name: String, key: SpriteKey?, frame: Int)? {
        var cache: [CharacterFrameKey: PixelImage] = [:]
        return image(of: node, tick: tick, cache: &cache)
    }

    static func image(of node: SceneNode, tick: Int, cache: inout [CharacterFrameKey: PixelImage])
        -> (image: PixelImage, name: String, key: SpriteKey?, frame: Int)? {
        switch node.sprite {
        case .sprite(let key, let frame):
            guard let def = SpriteCatalog.sprite(key), !def.frames.isEmpty else { return nil }
            let index = frame.map { min(max($0, 0), def.frames.count - 1) } ?? def.frameIndex(atTick: tick + node.tickOffset)
            return (def.frames[index], key.frameName(index), key, index)
        case .character(let look, let hue, let animation, let facing):
            let timing = SpriteDef(key: SpriteKey(animation.spriteID), category: .characters, anchor: CharacterSprites.anchor,
                                   frames: Array(repeating: PixelImage(width: 0, height: 0), count: animation.framesPerFacing),
                                   holds: animation.holds, loops: animation.loops)
            let index = timing.frameIndex(atTick: tick + node.tickOffset)
            let resolved = ResolvedLook(look, projectHue: hue)
            let key = SpriteKey(animation.spriteID, variant: resolved.variantName, facing: facing)
            let cacheKey = CharacterFrameKey(look: look, hue: hue, animation: animation, facing: facing, frame: index)
            if let image = cache[cacheKey] { return (image, key.frameName(index), key, index) }
            guard let canvas = CharacterSprites.canvas(animation, facing, frame: index, look: resolved) else { return nil }
            let image = canvas.render(resolved)
            cache[cacheKey] = image
            return (image, key.frameName(index), key, index)
        case .image(let image, let name):
            return (image, name, nil, 0)
        }
    }

    /// The frame at 1 pixel per texel.
    static func rasterize(_ frame: SceneFrame) -> PixelImage {
        var canvas = PixelImage(width: frame.width, height: frame.height)
        for p in frame.floor { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        if !frame.shadows.isEmpty {
            canvas.composite(shadowLayer(frame, over: canvas), alpha: Palette.shadowAlpha)
        }
        for p in frame.walls { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        for p in frame.world { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        if let veil = frame.veilAlpha {
            canvas.multiply(by: Palette.nightVeil, alpha: veil)
            if !frame.lights.isEmpty {
                // One layer, each light over the ones before, added once.
                var lights = PixelImage(width: frame.width, height: frame.height)
                for p in frame.lights { lights.blit(p.image, x: p.origin.x, y: p.origin.y) }
                canvas.add(lights, alpha: Palette.lightPoolAlpha)
            }
        }
        for p in frame.overlays { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        return canvas
    }

    /// Every shadow, opaque ink in one layer (overlaps do not darken twice), kept only over what is drawn:
    /// outside the world the pixels stay transparent.
    private static func shadowLayer(_ frame: SceneFrame, over floor: PixelImage) -> PixelImage {
        var layer = PixelImage(width: frame.width, height: frame.height)
        for p in frame.shadows { layer.blit(p.image, x: p.origin.x, y: p.origin.y) }
        let shade = layer.pixels, ground = floor.pixels
        for index in shade.indices where shade[index].a != 0 && ground[index].a == 0 {
            layer[index % frame.width, index / frame.width] = .clear
        }
        return layer
    }

    // MARK: Cork wall

    /// The order in which the cork wall fills its slots (`slots` row-major, `WallSprites.boardRows` rows): the cards
    /// go round the rows (0, 2, 1, 3), and along a row they spread in van der Corput order (columns 0, 8, 4, 2, 10…
    /// of 12), each row shifted by its own offset. Every prefix covers the whole board in a few loose rows (12 cards:
    /// three per row, in a brick pattern, never one line), and a new card never moves the cards already pinned.
    static func boardSpread(_ slots: [PixelPoint]) -> [Int] {
        let rows = WallSprites.boardRows
        guard rows > 0, !slots.isEmpty, slots.count % rows == 0 else { return Array(slots.indices) }
        let columns = slots.count / rows
        let rowOrder = vanDerCorput(rows), columnOrder = vanDerCorput(columns)
        return (0..<slots.count).map { k in
            let row = rowOrder[k % rows]
            return row * columns + (columnOrder[k / rows] + rowOrder[row]) % columns
        }
    }

    /// 0..<n in van der Corput order (bit-reversed indices, those ≥ n left out): 0, 2, 1, 3 for 4; 0, 8, 4, 2, 10,
    /// 6, 1, 9, 5, 3, 11, 7 for 12. Each prefix is spread over the whole range.
    static func vanDerCorput(_ n: Int) -> [Int] {
        var bits = 0
        while 1 << bits < n { bits += 1 }
        return (0..<(1 << bits)).map { i in
            (0..<bits).reduce(0) { reversed, bit in reversed | ((i >> bit) & 1) << (bits - 1 - bit) }
        }.filter { $0 < n }
    }

    /// A pinned card is never quite straight in its slot: 0 or 1 px off, from the slot index.
    static func boardJitter(_ index: Int) -> PixelPoint {
        let steps = [0, 1, 0, -1, 0]
        return PixelPoint(steps[(index * 7) % 5], steps[(index * 3 + 2) % 5])
    }

    // MARK: Stars of the night windows

    /// Pane pixels of the night window of each wall where a star may go: any sky pixel for a small star, a sky pixel
    /// with a 3×3 sky neighbourhood for a big one; row-major.
    static let starSpots: [WallSide: (small: [PixelPoint], big: [PixelPoint])] = {
        var out: [WallSide: (small: [PixelPoint], big: [PixelPoint])] = [:]
        for side in WallSide.allCases {
            let facing: Facing = side == .ne ? .ne : .nw
            guard let window = SpriteCatalog.sprite(SpriteKey("wall.window", variant: "night", facing: facing))?.frames.first
            else { continue }
            let sky = Palette.color(.skyNight)
            func isSky(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && y >= 0 && x < window.width && y < window.height && window[x, y] == sky
            }
            var small: [PixelPoint] = [], big: [PixelPoint] = []
            for y in 0..<window.height {
                for x in 0..<window.width where isSky(x, y) {
                    small.append(PixelPoint(x, y))
                    if (-1...1).allSatisfy({ dy in (-1...1).allSatisfy { dx in isSky(x + dx, y + dy) } }) {
                        big.append(PixelPoint(x, y))
                    }
                }
            }
            out[side] = (small, big)
        }
        return out
    }()
}

/// One image placed on the canvas of a scene (texels, top-left corner), with what it is: tests and debugging read
/// the frame of a plan, `SceneCompositor.rasterize` draws it.
struct ScenePlacement: Sendable {
    /// The sprite and frame ("desk~light@ne#0"), or "sign:API", "nameplate:Nova", "light.cone#0" for composed images.
    var name: String
    /// The catalog key (or the character sheet key); nil for composed images.
    var key: SpriteKey?
    var image: PixelImage
    var origin: PixelPoint
    /// The tile the object stands on (its anchor): what a crop keeps.
    var tile: GridPoint?
    /// The node's `SceneNode.order`, or the piece's index in its part of the background.
    var order: Int
    /// Drawing order, unique in a frame.
    var sequence: Int
    /// The node shown; nil for a baked piece.
    var id: SceneNodeID?
    /// A light of the back walls (a star in a window, the elevator's LED), already clipped by the world in front of
    /// it (a sign, a plant).
    var behindWorld = false

    /// The opaque pixel of the image at canvas (x, y); nil when transparent or outside the image.
    func pixel(atCanvasX x: Int, _ y: Int) -> RGBA8? {
        let lx = x - origin.x, ly = y - origin.y
        guard lx >= 0, ly >= 0, lx < image.width, ly < image.height else { return nil }
        let p = image[lx, ly]
        return p.a == 0 ? nil : p
    }
}

/// Everything a plan draws at one tick, in drawing order: the baked pieces, then the nodes of each layer.
struct SceneFrame: Sendable {
    var width: Int
    var height: Int
    var floor: [ScenePlacement] = []
    var shadows: [ScenePlacement] = []
    /// The baked wall pieces, then the nodes of the wall layer.
    var walls: [ScenePlacement] = []
    /// Sorted back to front.
    var world: [ScenePlacement] = []
    /// Night veil alpha; nil by day.
    var veilAlpha: UInt8?
    /// Additive, at night only: the wallLight layer, then the light layer.
    var lights: [ScenePlacement] = []
    /// Sorted back to front, never veiled.
    var overlays: [ScenePlacement] = []

    /// Placements so far.
    var count: Int { floor.count + shadows.count + walls.count + world.count + lights.count + overlays.count }
}
