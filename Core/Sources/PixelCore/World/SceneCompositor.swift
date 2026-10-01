import Foundation

/// Software rendering of the whole scene (3.10): the same picture SpriteKit will draw at stage 3, as a
/// `PixelImage`, without a GPU, so that the visual milestone renders under Linux. Pure and deterministic.
///
/// Order of a render, in texels (scaled by the zoom at the very end):
/// 1. floor: hall parquet, corridors, the islands' rugs with their borders (`IslandPlacement.rug`);
/// 2. shadows: drawn opaque in one layer, offset (+2, +1), applied once at 30 % (7.3, rule 4), only over the floor;
/// 3. walls (whole world only): the two back walls, cork wall and its mini post-its (spread in loose rows),
///    elevator and its LED, corner;
/// 4. the world sorted back to front by `IsoMath.depth`, then by insertion order: hall props, island signs (×2 in
///    the overview) and plants, and every post (chair, avatar, desk, monitor, screen, desk items, subagent minis);
/// 5. at night: the veil (multiply) over all of the above, then the additive lights (lamp pools on the desk tops,
///    screen glows around their monitors, stars);
/// 6. overlays, never veiled: state overlays, the "démarre" sign of a starting agent, tool bubbles, badges, queue
///    badges, name plates, the "+n" of the cork wall. The overview keeps only the urgent signs: the XL "!" of a
///    wait, the storm of an error and those agents' name plates (décision 2 of the first render).
public enum SceneCompositor {
    public static func render(_ scene: SceneInput, options: RenderOptions) -> PixelImage {
        rasterize(plan(scene, options: options)).scaled(by: options.zoom.pixelsPerTexel)
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

    // MARK: Plan and raster

    static func plan(_ scene: SceneInput, options: RenderOptions) -> ScenePlan {
        var builder = ScenePlanBuilder(scene: scene, options: options)
        return builder.build()
    }

    /// The plan at 1 pixel per texel.
    static func rasterize(_ plan: ScenePlan) -> PixelImage {
        var canvas = PixelImage(width: plan.width, height: plan.height)
        for p in plan.floor { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        if !plan.shadows.isEmpty {
            canvas.composite(shadowLayer(plan, over: canvas), alpha: Palette.shadowAlpha)
        }
        for p in plan.walls { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        for p in plan.world { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        if let veil = plan.veilAlpha {
            canvas.multiply(by: Palette.nightVeil, alpha: veil)
            if !plan.lights.isEmpty {
                var lights = PixelImage(width: plan.width, height: plan.height)
                let front = plan.lights.contains(where: \.behindWorld) ? worldMask(plan) : []
                for p in plan.lights {
                    if p.behindWorld {
                        blit(p, into: &lights, outside: front)
                    } else {
                        lights.blit(p.image, x: p.origin.x, y: p.origin.y)
                    }
                }
                canvas.add(lights, alpha: Palette.lightPoolAlpha)
            }
        }
        for p in plan.overlays { canvas.blit(p.image, x: p.origin.x, y: p.origin.y) }
        return canvas
    }

    /// Where the world pass draws (row-major, one flag per canvas pixel): what hides the lights of the back walls.
    private static func worldMask(_ plan: ScenePlan) -> [Bool] {
        var mask = [Bool](repeating: false, count: plan.width * plan.height)
        for p in plan.world {
            for y in 0..<p.image.height {
                let cy = p.origin.y + y
                guard cy >= 0, cy < plan.height else { continue }
                for x in 0..<p.image.width where p.image[x, y].a != 0 {
                    let cx = p.origin.x + x
                    if cx >= 0, cx < plan.width { mask[cy * plan.width + cx] = true }
                }
            }
        }
        return mask
    }

    /// Blits `p` into the light layer except where `mask` is set.
    private static func blit(_ p: ScenePlacement, into layer: inout PixelImage, outside mask: [Bool]) {
        for y in 0..<p.image.height {
            let cy = p.origin.y + y
            guard cy >= 0, cy < layer.height else { continue }
            for x in 0..<p.image.width where p.image[x, y].a != 0 {
                let cx = p.origin.x + x
                if cx >= 0, cx < layer.width, !mask[cy * layer.width + cx] { layer[cx, cy] = p.image[x, y] }
            }
        }
    }

    /// Every shadow, opaque ink in one layer (overlaps do not darken twice), kept only over what is drawn:
    /// outside the world the pixels stay transparent.
    private static func shadowLayer(_ plan: ScenePlan, over floor: PixelImage) -> PixelImage {
        var layer = PixelImage(width: plan.width, height: plan.height)
        for p in plan.shadows { layer.blit(p.image, x: p.origin.x, y: p.origin.y) }
        let shade = layer.pixels, ground = floor.pixels
        for index in shade.indices where shade[index].a != 0 && ground[index].a == 0 {
            layer[index % plan.width, index / plan.width] = .clear
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
/// the plan, `SceneCompositor.rasterize` draws it.
struct ScenePlacement: Sendable {
    /// The sprite and frame ("desk~light@ne#0"), or "sign:API", "nameplate:Nova" for composed images.
    var name: String
    /// The catalog key (or the character sheet key); nil for composed images.
    var key: SpriteKey?
    var image: PixelImage
    var origin: PixelPoint
    /// The tile the object stands on (its anchor): what a crop keeps.
    var tile: GridPoint?
    /// `IsoMath.depth` of the tile and layer; the world and the overlays draw by (depth, sequence).
    var depth: Int
    /// Insertion order, unique in a plan.
    var sequence: Int
    /// A light of the back walls (a star in a window, the elevator's LED): hidden wherever the world stands in front
    /// of the wall (a sign, a plant), like the wall itself.
    var behindWorld = false

    /// The opaque pixel of the image at canvas (x, y); nil when transparent or outside the image.
    func pixel(atCanvasX x: Int, _ y: Int) -> RGBA8? {
        let lx = x - origin.x, ly = y - origin.y
        guard lx >= 0, ly >= 0, lx < image.width, ly < image.height else { return nil }
        let p = image[lx, ly]
        return p.a == 0 ? nil : p
    }
}

/// Everything a render draws, in drawing order.
struct ScenePlan: Sendable {
    var width: Int
    var height: Int
    var floor: [ScenePlacement] = []
    var shadows: [ScenePlacement] = []
    var walls: [ScenePlacement] = []
    /// Sorted back to front.
    var world: [ScenePlacement] = []
    /// Night veil alpha; nil by day.
    var veilAlpha: UInt8?
    /// Additive, at night only.
    var lights: [ScenePlacement] = []
    /// Sorted back to front, never veiled.
    var overlays: [ScenePlacement] = []
}

/// Builds the plan of one render. Character frames are composed on demand (`CharacterSprites.canvas`, the very
/// function the sheets use) and cached for the duration of the call.
struct ScenePlanBuilder {
    /// `wallLights`: lights of the back walls, in `plan.lights` but hidden by the world (`behindWorld`).
    enum Pass { case floor, shadows, walls, world, lights, wallLights, overlays }

    struct CharacterFrameKey: Hashable {
        var look: AgentLook
        var hue: Int
        var animation: CharacterAnimation
        var facing: Facing
        var frame: Int
    }

    let scene: SceneInput
    let options: RenderOptions
    /// The rect of the canvas: the crop, or the whole world.
    let rect: GridRect
    var plan: ScenePlan
    private var sequence = 0
    private var characterFrames: [CharacterFrameKey: PixelImage] = [:]

    init(scene: SceneInput, options: RenderOptions) {
        self.scene = scene
        self.options = options
        rect = options.crop ?? scene.layout.bounds
        let size = SceneCompositor.canvasSize(for: rect)
        plan = ScenePlan(width: size.width, height: size.height)
        if options.night {
            plan.veilAlpha = options.reduceTransparency ? Palette.nightVeilAlphaReduced : Palette.nightVeilAlpha
        }
    }

    mutating func build() -> ScenePlan {
        addFloor()
        if options.crop == nil { addWalls() }
        addHallProps()
        for island in scene.layout.islands { addIsland(island) }
        let byDepth: (ScenePlacement, ScenePlacement) -> Bool = { ($0.depth, $0.sequence) < ($1.depth, $1.sequence) }
        plan.world.sort(by: byDepth)
        plan.overlays.sort(by: byDepth)
        return plan
    }

    // MARK: Helpers

    var overview: Bool { options.zoom == .overview }

    /// Objects anchored on tiles outside the crop are left out.
    func inScope(_ tile: GridPoint) -> Bool { options.crop?.contains(tile) ?? true }

    func top(_ tile: GridPoint) -> PixelPoint { SceneCompositor.imagePoint(of: tile, in: rect) }

    func center(_ tile: GridPoint) -> PixelPoint {
        let t = top(tile)
        return PixelPoint(t.x, t.y + IsoMath.tileHeight / 2)
    }

    static func depth(_ tile: GridPoint, _ layer: DepthLayer) -> Int { IsoMath.depth(tile, layer: layer) }

    static func plus(_ a: PixelPoint, _ b: PixelPoint) -> PixelPoint { PixelPoint(a.x + b.x, a.y + b.y) }

    static func hue(_ index: Int) -> Int { min(max(index, 0), Palette.projectHues.count - 1) }

    func hue(of project: ProjectID) -> Int { Self.hue(scene.projects[project]?.hueIndex ?? 0) }

    /// Places frame `frame` (default: the frame at the render tick) of a catalog sprite, its anchor on `point`.
    /// Returns its top-left and size; nil (and nothing drawn) for a key missing from the catalog.
    @discardableResult
    mutating func put(_ key: SpriteKey, at point: PixelPoint, tile: GridPoint?, depth: Int, in pass: Pass,
                      frame: Int? = nil, tickOffset: Int = 0) -> PixelRect? {
        guard let def = SpriteCatalog.sprite(key) else { return nil }
        let index = frame.map { min(max($0, 0), def.frames.count - 1) } ?? def.frameIndex(atTick: options.tick + tickOffset)
        let origin = PixelPoint(point.x - def.anchor.x, point.y - def.anchor.y)
        put(name: key.frameName(index), key: key, image: def.frames[index], origin: origin, tile: tile, depth: depth, in: pass)
        return PixelRect(x: origin.x, y: origin.y, width: def.width, height: def.height)
    }

    mutating func put(name: String, key: SpriteKey?, image: PixelImage, origin: PixelPoint, tile: GridPoint?, depth: Int,
                      in pass: Pass) {
        let placement = ScenePlacement(name: name, key: key, image: image, origin: origin, tile: tile, depth: depth,
                                       sequence: sequence)
        sequence += 1
        switch pass {
        case .floor: plan.floor.append(placement)
        case .shadows: plan.shadows.append(placement)
        case .walls: plan.walls.append(placement)
        case .world: plan.world.append(placement)
        case .lights: plan.lights.append(placement)
        case .wallLights:
            var light = placement
            light.behindWorld = true
            plan.lights.append(light)
        case .overlays: plan.overlays.append(placement)
        }
    }

    /// A cast shadow under an object of `tile` (opaque ink, offset (+2, +1)).
    mutating func shadow(_ id: SpriteID, under tile: GridPoint) {
        put(SpriteKey(id), at: Self.plus(center(tile), SceneCompositor.shadowOffset), tile: tile, depth: 0, in: .shadows)
    }

    // MARK: Floor

    mutating func addFloor() {
        let layout = scene.layout
        var carpet: [GridPoint: SpriteKey] = [:]
        for island in layout.islands {
            let hue = hue(of: island.projectID)
            for tile in island.rug.tiles {
                carpet[tile] = Self.carpetKey(local: tile - island.rug.origin, size: island.rug.size, hue: hue)
            }
        }
        // j-major: each tile covers the 2-step overlap of the tiles behind it.
        for tile in rect.tiles where layout.bounds.contains(tile) {
            let key: SpriteKey
            if let island = carpet[tile] {
                key = island
            } else if layout.hall.contains(tile) {
                key = SpriteKey("floor.hall", variant: "n\(Self.noise(tile, 3))")
            } else {
                key = SpriteKey("floor.corridor", variant: "n\(Self.noise(tile, 2))")
            }
            put(key, at: center(tile), tile: tile, depth: Self.depth(tile, .carpet), in: .floor)
        }
    }

    /// (i·7 + j·13) mod n: the floor noise variant.
    static func noise(_ tile: GridPoint, _ n: Int) -> Int { ((tile.i * 7 + tile.j * 13) % n + n) % n }

    /// Carpet tile of an island at a local tile: corners, then edges (`.n` j = 0, `.e` i = W − 1, `.s` j = D − 1,
    /// `.w` i = 0), plain carpet inside.
    static func carpetKey(local: GridPoint, size: GridSize, hue: Int) -> SpriteKey {
        let lastI = size.w - 1, lastJ = size.d - 1
        let id: SpriteID
        switch (local.i, local.j) {
        case (0, 0): id = "floor.carpet.corner.n"
        case (lastI, 0): id = "floor.carpet.corner.e"
        case (lastI, lastJ): id = "floor.carpet.corner.s"
        case (0, lastJ): id = "floor.carpet.corner.w"
        case (_, 0): id = "floor.carpet.edge.n"
        case (lastI, _): id = "floor.carpet.edge.e"
        case (_, lastJ): id = "floor.carpet.edge.s"
        case (0, _): id = "floor.carpet.edge.w"
        default: return SpriteKey("floor.carpet", variant: "hue\(hue).plain")
        }
        return SpriteKey(id, variant: "hue\(hue)")
    }

    // MARK: Walls

    /// The back walls, piece by piece from the corner, then the corner over both. A piece of `span` tiles stands on
    /// the back edge of its tiles: its anchor is the middle of that edge.
    mutating func addWalls() {
        let layout = scene.layout
        let corner = layout.bounds.origin
        let sky = options.night ? "night" : "day"
        for piece in layout.walls {
            guard let side = piece.wall else { continue }
            let facing: Facing = side == .ne ? .ne : .nw
            let tile = side == .ne ? GridPoint(corner.i + piece.start, corner.j) : GridPoint(corner.i, corner.j + piece.start)
            let t = top(tile)
            let half = (x: IsoMath.tileWidth / 4 * piece.span, y: IsoMath.tileHeight / 4 * piece.span)
            let anchor = side == .ne ? PixelPoint(t.x + half.x, t.y + half.y) : PixelPoint(t.x - half.x, t.y + half.y)
            let depth = Self.depth(tile, .carpet)
            switch piece.piece {
            case .segment(let style):
                put(SpriteKey("wall.segment", variant: style.rawValue, facing: facing), at: anchor, tile: tile, depth: depth,
                    in: .walls)
            case .window:
                let frame = put(SpriteKey("wall.window", variant: sky, facing: facing), at: anchor, tile: tile, depth: depth,
                                in: .walls)
                if options.night, let frame { addStars(window: PixelPoint(frame.x, frame.y), side: side, start: piece.start, tile: tile) }
            case .board:
                guard let frame = put(SpriteKey("board.cork", facing: facing), at: anchor, tile: tile, depth: depth, in: .walls)
                else { continue }
                addBoardCards(board: PixelPoint(frame.x, frame.y), side: side, tile: tile)
            case .elevator:
                // Doors closed (frame 0) at rest; the LED blinks with the clock.
                guard let frame = put(SpriteKey("elevator", facing: facing), at: anchor, tile: tile, depth: depth, in: .walls,
                                      frame: 0)
                else { continue }
                let led = Self.plus(PixelPoint(frame.x, frame.y), WallSprites.elevatorLEDPoint)
                put(SpriteKey("elevator.led"), at: led, tile: tile, depth: depth, in: .walls)
                if options.night, let def = SpriteCatalog.sprite(SpriteKey("elevator.led")), def.frameIndex(atTick: options.tick) == 0 {
                    put(SpriteKey("elevator.led"), at: led, tile: tile, depth: depth, in: .wallLights)
                }
            case .corner:
                continue
            }
        }
        if layout.walls.contains(where: { $0.piece == .corner }) {
            put(SpriteKey("wall.corner"), at: top(corner), tile: corner, depth: Self.depth(corner, .carpet), in: .walls)
        }
    }

    /// The mini post-its of the cork wall (hue 0…9, anything else paper), card k in the k-th slot of
    /// `boardSpread`, so that a few cards already cover the board in loose rows; the "+n" counter beyond 48.
    mutating func addBoardCards(board: PixelPoint, side: WallSide, tile: GridPoint) {
        let facing: Facing = side == .ne ? .ne : .nw
        let slots = WallSprites.boardSlots(wall: side)
        for (index, hue) in zip(SceneCompositor.boardSpread(slots), scene.boardCardHues) {
            let variant = (0..<Palette.projectHues.count).contains(hue) ? "hue\(hue)" : "paper"
            put(SpriteKey("postit.mini", variant: variant, facing: facing),
                at: Self.plus(board, Self.plus(slots[index], SceneCompositor.boardJitter(index))), tile: tile,
                depth: Self.depth(tile, .carpet), in: .walls)
        }
        let extra = scene.boardCardHues.count - slots.count
        guard extra > 0, let last = slots.last else { return }
        let plate = HUDSprites.nameplate("+\(extra)", off: false)
        let base = Self.plus(board, PixelPoint(last.x + 8, last.y + 10))
        put(name: "nameplate:+\(extra)", key: nil, image: plate,
            origin: PixelPoint(base.x - plate.width / 2, base.y - plate.height), tile: tile,
            depth: Self.depth(tile, .overlay), in: .overlays)
    }

    /// A big and two small stars in a night window, at spots chosen from the window's position along the wall.
    mutating func addStars(window origin: PixelPoint, side: WallSide, start: Int, tile: GridPoint) {
        guard let spots = SceneCompositor.starSpots[side] else { return }
        let depth = Self.depth(tile, .carpet)
        if !spots.big.isEmpty {
            let spot = spots.big[(start * 37 + 11) % spots.big.count]
            put(SpriteKey("fx.star", variant: "big"), at: Self.plus(origin, spot), tile: tile, depth: depth, in: .wallLights)
        }
        guard !spots.small.isEmpty else { return }
        for k in 0..<2 {
            let spot = spots.small[(start * 53 + k * 101 + 7) % spots.small.count]
            put(SpriteKey("fx.star", variant: "small"), at: Self.plus(origin, spot), tile: tile, depth: depth,
                in: .wallLights)
        }
    }

    // MARK: Hall

    /// Coffee machine and plant of the hall; unlockable decor is not drawn before stage 6.
    mutating func addHallProps() {
        for prop in scene.layout.props where inScope(prop.tile) {
            switch prop.kind {
            case .coffeeMachine:
                put(SpriteKey("decor.coffeeMachine"), at: center(prop.tile), tile: prop.tile,
                    depth: Self.depth(prop.tile, .furniture), in: .world)
            case .plantSmall:
                addPlant(at: prop.tile)
            default:
                continue
            }
        }
    }

    mutating func addPlant(at tile: GridPoint) {
        shadow("shadow.small", under: tile)
        put(SpriteKey("decor.plantSmall"), at: center(tile), tile: tile, depth: Self.depth(tile, .furniture), in: .world)
    }

    // MARK: Islands

    mutating func addIsland(_ island: IslandPlacement) {
        let visual = scene.projects[island.projectID]
        let hue = hue(of: island.projectID)
        if inScope(island.sign) {
            let name = visual?.name ?? ""
            let label = island.part == 0 ? name : "\(name) · \(island.part + 1)"
            let anchor = SpriteCatalog.sprite(SpriteKey("sign.island", variant: "hue\(hue)"))?.anchor ?? PixelPoint(32, 38)
            // ×2 in the overview, so that the name keeps the size it has at ×1 (décision 2 of the first render).
            let scale = overview ? SceneCompositor.overviewSignScale : 1
            let foot = Self.plus(center(island.sign), SceneCompositor.signFoot)
            put(name: "sign:\(label)", key: nil, image: HUDSprites.sign(name: label, hue: hue).scaled(by: scale),
                origin: PixelPoint(foot.x - anchor.x * scale, foot.y - anchor.y * scale), tile: island.sign,
                depth: Self.depth(island.sign, .furniture), in: .world)
        }
        if inScope(island.plant) { addPlant(at: island.plant) }
        for desk in island.desks { addPost(desk, hue: hue) }
    }

    mutating func addPost(_ desk: DeskPlacement, hue: Int) {
        let agent = desk.agentID.flatMap { scene.agents[$0] }
        if inScope(desk.seatTile) { addSeat(desk, agent: agent, hue: hue) }
        if inScope(desk.deskTile) { addDesk(desk, agent: agent) }
        if inScope(desk.sideTile), let p = agent?.presentation, p.subagents > 0 {
            let c = center(desk.sideTile)
            let minis = SceneCompositor.miniOffsets(rowFacesViewer: desk.facing.isTowardViewer).prefix(p.subagents)
                .enumerated().sorted { $0.element.y < $1.element.y }   // the farther one first
            for (k, offset) in minis {
                put(SpriteKey("agent.mini", variant: "hue\(hue)"), at: Self.plus(c, offset), tile: desk.sideTile,
                    depth: Self.depth(desk.sideTile, .character), in: .world, tickOffset: 6 * k)
            }
        }
        if inScope(desk.seatTile), let agent { addOverlays(desk, agent: agent) }
    }

    /// The avatar faces the post's gaze, or turns toward the viewer when it raises its hand.
    static func avatarFacing(_ p: AgentPresentation, gaze: Facing) -> Facing {
        p.facesViewer && !gaze.isTowardViewer ? gaze.opposite : gaze
    }

    /// Chair and avatar. An avatar facing the viewer sits in front of the backrest (chair first); one turning its
    /// back to the viewer is drawn first, the backrest covering the bottom of its back.
    mutating func addSeat(_ desk: DeskPlacement, agent: SceneAgent?, hue: Int) {
        let seat = desk.seatTile, point = center(seat), gaze = desk.facing
        let p = agent?.presentation
        let chair = SpriteKey("chair", variant: "hue\(hue)" + (p?.jacketOnChair == true ? ".jacket" : ""), facing: gaze)
        shadow("shadow.small", under: seat)
        guard let agent, let p, let animation = p.animation,
              let avatar = characterFrame(look: agent.look, hue: hue, animation: animation,
                                          facing: Self.avatarFacing(p, gaze: gaze))
        else {
            put(chair, at: point, tile: seat, depth: Self.depth(seat, .furniture), in: .world)
            return
        }
        shadow("shadow.char", under: seat)
        let anchor = CharacterSprites.anchor
        let origin = PixelPoint(point.x - anchor.x, point.y - anchor.y)
        let depth = Self.depth(seat, .character)
        if avatar.key.facing?.isTowardViewer == true {
            put(chair, at: point, tile: seat, depth: Self.depth(seat, .furniture), in: .world)
            put(name: avatar.key.frameName(avatar.frame), key: avatar.key, image: avatar.image, origin: origin, tile: seat,
                depth: depth, in: .world)
        } else {
            put(name: avatar.key.frameName(avatar.frame), key: avatar.key, image: avatar.image, origin: origin, tile: seat,
                depth: depth, in: .world)
            put(chair, at: point, tile: seat, depth: depth, in: .world)
        }
    }

    /// The frame of `animation` at the render tick, as the sheet of that look draws it; nil when the animation has
    /// no frame toward any facing close to `facing`.
    mutating func characterFrame(look: AgentLook, hue: Int, animation: CharacterAnimation,
                                 facing wanted: Facing) -> (key: SpriteKey, frame: Int, image: PixelImage)? {
        let facings = animation.facings
        let facing = facings.contains(wanted) ? wanted : (facings.contains(wanted.opposite) ? wanted.opposite : facings[0])
        let timing = SpriteDef(key: SpriteKey(animation.spriteID), category: .characters, anchor: CharacterSprites.anchor,
                               frames: Array(repeating: PixelImage(width: 0, height: 0), count: animation.framesPerFacing),
                               holds: animation.holds, loops: animation.loops)
        let frame = timing.frameIndex(atTick: options.tick)
        let resolved = ResolvedLook(look, projectHue: hue)
        let key = SpriteKey(animation.spriteID, variant: resolved.variantName, facing: facing)
        let cacheKey = CharacterFrameKey(look: look, hue: hue, animation: animation, facing: facing, frame: frame)
        if let image = characterFrames[cacheKey] { return (key, frame, image) }
        guard let canvas = CharacterSprites.canvas(animation, facing, frame: frame, look: resolved) else { return nil }
        let image = canvas.render(resolved)
        characterFrames[cacheKey] = image
        return (key, frame, image)
    }

    // MARK: Desk

    /// One object on the desk top: its footprint (to order the objects back to front) and its sprites.
    struct DeskItem {
        var box: SceneryKit.Box
        var sprites: [(key: SpriteKey, point: PixelPoint)]
    }

    /// The desk, then its objects back to front: monitor (screen or LED, post-it), keyboard, lamp, a mug or papers on
    /// some posts, the queue. At night, the lamp's pool and the screen's glow.
    mutating func addDesk(_ desk: DeskPlacement, agent: SceneAgent?) {
        let tile = desk.deskTile, point = center(tile), gaze = desk.facing
        let p = agent?.presentation
        shadow("shadow.tile", under: tile)
        put(SpriteKey("desk", variant: "light", facing: gaze), at: point, tile: tile, depth: Self.depth(tile, .furniture),
            in: .world)

        let screen = p?.screen ?? .off
        let lampLit = options.night && (p?.deskLit ?? false)
        func box(_ a: Range<Int>, _ b: Range<Int>, height: Int) -> SceneryKit.Box {
            DeskLayout.box(a: a, b: b, z: IsoMath.deskTopHeight, height: height, facing: gaze)
        }
        var items: [DeskItem] = []

        // Monitor: the screen faces the agent; row A (gaze away from the viewer) shows it, shifted toward the aisle.
        let monitor = Self.plus(point, FurnitureSprites.monitorOffset(facing: gaze))
        let shift = gaze == .ne ? FurnitureSprites.rowAAisleShift.y : 0
        var monitorSprites: [(key: SpriteKey, point: PixelPoint)] = []
        let glow: PixelPoint
        if let screenOffset = MonitorSprites.screenOffset(facing: gaze), !gaze.isTowardViewer {
            let screenPoint = Self.plus(monitor, screenOffset)
            monitorSprites.append((SpriteKey("monitor.front", facing: gaze), monitor))
            monitorSprites.append((MonitorSprites.screenKey(screen, facing: gaze), screenPoint))
            glow = Self.plus(screenPoint, SceneCompositor.glowOnScreen)
            if let card = agent?.extras.cardOnScreenHue {
                monitorSprites.append((Self.postitKey(card), Self.plus(screenPoint, SceneCompositor.postitOnScreen)))
            }
        } else {
            monitorSprites.append((MonitorSprites.ledKey(screen, facing: gaze), monitor))
            glow = Self.plus(monitor, SceneCompositor.glowOnBack)
            if let card = agent?.extras.cardOnScreenHue {
                monitorSprites.append((Self.postitKey(card), Self.plus(monitor, SceneCompositor.postitOnBack)))
            }
        }
        items.append(DeskItem(box: box((-4 + shift)..<(4 + shift), -3..<(-1), height: 20), sprites: monitorSprites))

        items.append(DeskItem(box: box(DeskItemSprites.keyboardCells.a, DeskItemSprites.keyboardCells.b, height: 2),
                              sprites: [(SpriteKey("keyboard", facing: gaze),
                                         Self.plus(point, FurnitureSprites.keyboardOffset(facing: gaze)))]))
        let lamp = Self.plus(point, FurnitureSprites.lampOffset(facing: gaze))
        items.append(DeskItem(box: box(DeskItemSprites.lampCells.a, DeskItemSprites.lampCells.b, height: 17),
                              sprites: [(SpriteKey("lamp.desk", variant: lampLit ? "on" : "off", facing: gaze), lamp)]))
        if agent != nil {
            switch desk.index % 3 {
            case 0:
                items.append(DeskItem(box: box(DeskItemSprites.mugCells.a, DeskItemSprites.mugCells.b, height: 6),
                                      sprites: [(SpriteKey("mug", facing: gaze),
                                                 Self.plus(point, FurnitureSprites.mugOffset(facing: gaze)))]))
            case 1:
                items.append(DeskItem(box: box(DeskItemSprites.papersCells.a, DeskItemSprites.papersCells.b, height: 2),
                                      sprites: [(SpriteKey("papers", facing: gaze),
                                                 Self.plus(point, FurnitureSprites.papersOffset(facing: gaze)))]))
            default:
                break
            }
        }
        if let queued = agent?.extras.queued, queued > 0 {
            let cells = DeskItemSprites.queuePlacement(facing: gaze)
            items.append(DeskItem(box: box(cells.a, cells.b, height: 3),
                                  sprites: [(SpriteKey("desk.queue", variant: "\(min(queued, 3))"),
                                             Self.plus(point, FurnitureSprites.queueOffset(facing: gaze)))]))
        }
        let depth = Self.depth(tile, .screen)
        // items[0] is the monitor (with its screen or LED and its post-it): what the screen's glow leaves dark.
        var monitorParts: [ScenePlacement] = []
        for index in SceneryKit.paintersOrder(items.map(\.box)) {
            for sprite in items[index].sprites {
                guard put(sprite.key, at: sprite.point, tile: tile, depth: depth, in: .world) != nil else { continue }
                if index == 0, let placed = plan.world.last { monitorParts.append(placed) }
            }
        }

        guard options.night else { return }
        if lampLit, let def = SpriteCatalog.sprite(SpriteKey("light.cone")) {
            // The pool lies on the desk top under the lamp's base, clipped to the top.
            let pool = Self.plus(point, FurnitureSprites.lightConeOffset(facing: gaze))
            let origin = PixelPoint(pool.x - def.anchor.x, pool.y - def.anchor.y)
            let deskTop = PixelPoint(point.x, point.y - IsoMath.deskTopHeight)
            let image = Self.clipped(def.frames[0], at: origin, toDiamondAt: deskTop,
                                     halfWidth: SceneCompositor.deskTopHalfWidth)
            put(name: SpriteKey("light.cone").frameName(0), key: SpriteKey("light.cone"), image: image, origin: origin,
                tile: tile, depth: depth, in: .lights)
        }
        if screen != .off, let def = SpriteCatalog.sprite(SpriteKey("light.screenGlow")) {
            // The glow lights the desk around the monitor, never the monitor itself: from behind (row B) the lit
            // back read as glass, from the front the screen's own colours shifted.
            let origin = PixelPoint(glow.x - def.anchor.x, glow.y - def.anchor.y)
            let image = Self.clipped(def.frames[0], at: origin, outside: monitorParts)
            put(name: SpriteKey("light.screenGlow").frameName(0), key: SpriteKey("light.screenGlow"), image: image,
                origin: origin, tile: tile, depth: depth, in: .lights)
        }
    }

    /// `image` placed at `origin`, without its pixels where one of `placements` is opaque.
    static func clipped(_ image: PixelImage, at origin: PixelPoint, outside placements: [ScenePlacement]) -> PixelImage {
        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].a != 0 {
                let (cx, cy) = (origin.x + x, origin.y + y)
                if placements.contains(where: { $0.pixel(atCanvasX: cx, cy) != nil }) { out[x, y] = .clear }
            }
        }
        return out
    }

    /// `image` placed at `origin`, keeping only its pixels inside the iso diamond centred on `center` (2:1, the
    /// given half-width in px): |dx| + 2·|dy| ≤ halfWidth.
    static func clipped(_ image: PixelImage, at origin: PixelPoint, toDiamondAt center: PixelPoint,
                        halfWidth: Int) -> PixelImage {
        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].a != 0 {
                let dx = origin.x + x - center.x, dy = origin.y + y - center.y
                if abs(dx) + 2 * abs(dy) > halfWidth { out[x, y] = .clear }
            }
        }
        return out
    }

    /// `desk.postit~hueN`, or `~paper` for 10 and any other value.
    static func postitKey(_ hue: Int) -> SpriteKey {
        SpriteKey("desk.postit", variant: (0..<Palette.projectHues.count).contains(hue) ? "hue\(hue)" : "paper")
    }

    // MARK: Overlays

    /// Above the head: the halo, the primary overlay (or the "démarre" sign of a starting agent), the question
    /// bubble beside a "!", the badges in a row; the queue badge on the desk; the name plate when it shows without
    /// hovering (row A under the post, row B beside the head). The overview keeps only the urgent signs (décision 2
    /// of the first render): the XL "!" of a wait with its halo, the storm of an error, and their agents' name
    /// plates; no bubble, badge, state icon or queue badge.
    mutating func addOverlays(_ desk: DeskPlacement, agent: SceneAgent) {
        let p = agent.presentation
        if overview && !p.showsUrgentSign { return }
        let seat = desk.seatTile
        let depth = Self.depth(seat, .overlay)
        let c = center(seat)
        let shift = SceneCompositor.headShift(p, facing: Self.avatarFacing(p, gaze: desk.facing))
        let head = PixelPoint(c.x + shift.x, c.y - SceneCompositor.overlayLift(p, row: desk.row) + shift.y)
        var right = head.x
        if let overlay = p.overlay {
            if overlay == .bang && p.halo {
                let lift = overview ? SceneCompositor.haloLift.xl : SceneCompositor.haloLift.normal
                put(SpriteKey("ov.bang.halo"), at: PixelPoint(head.x, head.y - lift), tile: seat, depth: depth, in: .overlays)
            }
            if let frame = put(Self.primaryKey(overlay, tool: p.toolIcon, overview: overview), at: head, tile: seat,
                               depth: depth, in: .overlays) {
                right = frame.x + frame.width
            }
            if overlay == .bang, let icon = p.toolIcon, !overview {
                right = putBeside(SpriteKey(icon.spriteID), right: right, baseline: head.y, tile: seat, depth: depth)
            }
        } else if p.launchingSign, let frame = put(HUDSprites.stateKey(.launching), at: head, tile: seat, depth: depth,
                                                   in: .overlays) {
            right = frame.x + frame.width
        }
        if !overview {
            for badge in p.badges {
                right = putBeside(SpriteKey(badge.spriteID), right: right, baseline: head.y, tile: seat, depth: depth)
            }
            if agent.extras.queued > 0, inScope(desk.deskTile) {
                let queue = Self.plus(center(desk.deskTile), FurnitureSprites.queueOffset(facing: desk.facing))
                put(HUDSprites.queueBadgeKey(count: agent.extras.queued),
                    at: Self.plus(queue, SceneCompositor.queueBadgeOffset), tile: seat, depth: depth, in: .overlays)
            }
        }
        if p.nameplateAlways {
            let plate = HUDSprites.nameplate(p.nameplateOff ? "\(agent.name) · OFF" : agent.name, off: p.nameplateOff)
            let origin: PixelPoint
            if desk.row == .b {
                origin = SceneCompositor.rowBNameplateOrigin(p, plate: (plate.width, plate.height), seat: c)
            } else {
                origin = PixelPoint(c.x - plate.width / 2, c.y + SceneCompositor.nameplateDrop - plate.height)
            }
            put(name: "nameplate:\(agent.name)", key: nil, image: plate, origin: origin, tile: seat, depth: depth,
                in: .overlays)
        }
    }

    /// Places a sprite whose left edge is `badgeGap` right of `right`, its anchor on the baseline; returns its right edge.
    mutating func putBeside(_ key: SpriteKey, right: Int, baseline: Int, tile: GridPoint, depth: Int) -> Int {
        guard let def = SpriteCatalog.sprite(key) else { return right }
        let x = right + SceneCompositor.badgeGap
        put(key, at: PixelPoint(x + def.anchor.x, baseline), tile: tile, depth: depth, in: .overlays)
        return x + def.width
    }

    static func primaryKey(_ overlay: OverlayKind, tool: ToolIcon?, overview: Bool) -> SpriteKey {
        switch overlay {
        case .bang: return SpriteKey("ov.bang", variant: overview ? "xl" : nil)
        case .dots: return SpriteKey("ov.dots")
        case .tool: return SpriteKey((tool ?? .other).spriteID)
        case .zzz: return SpriteKey("ov.zzz")
        case .storm: return SpriteKey("ov.storm")
        case .check: return SpriteKey("ov.check")
        case .background: return SpriteKey("ov.background")
        case .quota: return SpriteKey("ov.quota")
        }
    }
}
