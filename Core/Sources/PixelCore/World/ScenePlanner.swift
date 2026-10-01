import Foundation

/// The plan of a scene (stage 3, décision 1): what `SceneCompositor` draws and SpriteKit shows, as nodes with a
/// stable identifier and a baked background. Pure and deterministic; it does not depend on the animation clock (the
/// frames are chosen when drawing), so a scene that does not change gives the same plan and an empty diff.
public enum ScenePlanner {
    public static func plan(_ scene: SceneInput, options: ScenePlanOptions) -> WorldScenePlan {
        var builder = ScenePlanBuilder(scene: scene, options: options)
        return builder.build()
    }
}

/// Builds the plan of one scene, in the order of the first renders: floor; shadows; walls (whole world only); hall
/// props; then each island (sign, plant, the marks on its rug, its posts). The orders of the nodes are keys
/// (`SceneNode.order`), so the order in which they are built does not matter, except in the wall pass: a wall piece
/// that covers a node drawn before it becomes a node too (décision 2).
struct ScenePlanBuilder {
    let scene: SceneInput
    let options: ScenePlanOptions
    /// The rect of the canvas: the crop, or the whole world.
    let rect: GridRect
    let canvas: (width: Int, height: Int)
    private var floor: [SceneBackground.Piece] = []
    private var shadows: [SceneBackground.Piece] = []
    private var walls: [SceneBackground.Piece] = []
    private var nodes: [SceneNode] = []
    /// The lights of the back walls, before the world clips them (`clipWallLights`).
    private var wallLights: [SceneNode] = []
    private var seats: [AgentID: ScenePoint] = [:]
    /// Hall props already placed on a tile: their place on it.
    private var propsOnTile: [GridPoint: Int] = [:]

    init(scene: SceneInput, options: ScenePlanOptions) {
        self.scene = scene
        self.options = options
        rect = options.crop ?? scene.layout.bounds
        canvas = SceneCompositor.canvasSize(for: rect)
    }

    mutating func build() -> WorldScenePlan {
        addFloor()
        if options.crop == nil { addWalls() }
        addHallProps()
        for island in scene.layout.islands { addIsland(island) }
        nodes += clipWallLights()
        nodes.sort { ($0.layer, $0.order) < ($1.layer, $1.order) }
        let veil: UInt8? = options.night
            ? (options.reduceTransparency ? Palette.nightVeilAlphaReduced : Palette.nightVeilAlpha) : nil
        let islands = scene.layout.islands.filter { options.crop == nil || rect.intersects($0.rug) }.map {
            WorldScenePlan.IslandFrame(projectID: $0.projectID, part: $0.part, rug: $0.rug, sign: $0.sign)
        }
        return WorldScenePlan(
            rect: rect, canvasWidth: canvas.width, canvasHeight: canvas.height,
            background: SceneBackground(width: canvas.width, height: canvas.height, floor: floor, shadows: shadows,
                                        walls: walls),
            nodes: nodes, veilAlpha: veil, agentSeats: seats, islands: islands)
    }

    // MARK: Helpers

    var overview: Bool { options.overview }

    /// Overlays and floor marks hold their frame 0 under Reduce Motion (7.9).
    var markFrame: Int? { options.reduceMotion ? 0 : nil }

    /// Objects anchored on tiles outside the crop are left out.
    func inScope(_ tile: GridPoint) -> Bool { options.crop?.contains(tile) ?? true }

    /// Top vertex of a tile on the canvas (texels, y down).
    func top(_ tile: GridPoint) -> PixelPoint { SceneCompositor.imagePoint(of: tile, in: rect) }

    func center(_ tile: GridPoint) -> PixelPoint {
        let t = top(tile)
        return PixelPoint(t.x, t.y + IsoMath.tileHeight / 2)
    }

    func scenePoint(_ p: PixelPoint) -> ScenePoint { WorldScenePlan.scenePoint(p, in: rect) }

    static func plus(_ a: PixelPoint, _ b: PixelPoint) -> PixelPoint { PixelPoint(a.x + b.x, a.y + b.y) }

    static func hue(_ index: Int) -> Int { min(max(index, 0), Palette.projectHues.count - 1) }

    func hue(of project: ProjectID) -> Int { Self.hue(scene.projects[project]?.hueIndex ?? 0) }

    /// A catalog sprite as a node, its anchor on canvas point `point`. Returns its rect on the canvas; nil (and no
    /// node) for a key missing from the catalog.
    @discardableResult
    mutating func add(_ id: String, _ layer: SceneLayer, _ key: SpriteKey, at point: PixelPoint, order: Int,
                      frame: Int? = nil, tickOffset: Int = 0, tile: GridPoint?, target: SceneHitTarget?) -> PixelRect? {
        guard let node = Self.node(id, layer, key, at: point, in: rect, order: order, frame: frame,
                                   tickOffset: tickOffset, tile: tile, target: target)
        else { return nil }
        nodes.append(node)
        return PixelRect(x: point.x - node.anchor.x, y: point.y - node.anchor.y, width: node.width, height: node.height)
    }

    static func node(_ id: String, _ layer: SceneLayer, _ key: SpriteKey, at point: PixelPoint, in rect: GridRect,
                     order: Int, frame: Int? = nil, tickOffset: Int = 0, tile: GridPoint?,
                     target: SceneHitTarget?) -> SceneNode? {
        guard let def = SpriteCatalog.sprite(key) else { return nil }
        return SceneNode(id: SceneNodeID(id), layer: layer,
                         sprite: .sprite(key, frame: frame.map { min(max($0, 0), def.frames.count - 1) }),
                         position: WorldScenePlan.scenePoint(point, in: rect), anchor: def.anchor, width: def.width,
                         height: def.height, order: order, tickOffset: tickOffset, tile: tile, target: target)
    }

    /// A composed image as a node, its top-left at `origin`; `anchor` (px from that corner) is what stays put when
    /// the image changes size (a name plate's bottom centre, a sign's foot).
    mutating func add(_ id: String, _ layer: SceneLayer, image: PixelImage, name: String, origin: PixelPoint,
                      anchor: PixelPoint, order: Int, tile: GridPoint?, target: SceneHitTarget?) {
        nodes.append(SceneNode(id: SceneNodeID(id), layer: layer, sprite: .image(image, name: name),
                               position: scenePoint(Self.plus(origin, anchor)), anchor: anchor, width: image.width,
                               height: image.height, order: order, tile: tile, target: target))
    }

    /// A baked piece (frame 0 of a catalog sprite), its anchor on `point`; nil for a key missing from the catalog.
    func piece(_ key: SpriteKey, at point: PixelPoint, tile: GridPoint?) -> SceneBackground.Piece? {
        guard let def = SpriteCatalog.sprite(key) else { return nil }
        return SceneBackground.Piece(key: key, frame: 0, origin: PixelPoint(point.x - def.anchor.x, point.y - def.anchor.y),
                                     tile: tile)
    }

    /// A cast shadow under an object of `tile` (opaque ink, offset (+2, +1)), baked.
    mutating func shadow(_ id: SpriteID, under tile: GridPoint) {
        if let piece = piece(SpriteKey(id), at: Self.plus(center(tile), SceneCompositor.shadowOffset), tile: tile) {
            shadows.append(piece)
        }
    }

    // MARK: Orders (keys, see `SceneNode.order`)

    static func clamp(_ value: Int, _ count: Int) -> Int { min(max(value, 0), count - 1) }

    /// Kinds of floor marks on one tile, back to front.
    enum Mark: Int { case islandHover, hover, drop, selection }

    /// World layer, below every object: (i + j, i, kind).
    static func markOrder(_ tile: GridPoint, _ mark: Mark) -> Int {
        (clamp(tile.i + tile.j, 512) * 256 + clamp(tile.i, 256)) * 4 + mark.rawValue
    }

    /// World layer, objects: (i + j, depth layer, i, place on the tile).
    static func objectOrder(_ tile: GridPoint, _ layer: DepthLayer, _ place: Int) -> Int {
        let level: Int
        switch layer {
        case .carpet, .furniture: level = 0
        case .character: level = 1
        case .screen, .overlay: level = 2
        }
        let marks = 512 * 256 * 4
        return marks + ((clamp(tile.i + tile.j, 512) * 3 + level) * 256 + clamp(tile.i, 256)) * 8 + clamp(place, 8)
    }

    /// Overlay layer: (i + j, i, place above the seat).
    static func overlayOrder(_ tile: GridPoint, _ place: Int) -> Int {
        (clamp(tile.i + tile.j, 512) * 256 + clamp(tile.i, 256)) * 16 + clamp(place, 16)
    }

    /// Wall and wallLight layers: the `ne` wall, then the `nw` wall, by start, then the corner; then the place on
    /// that piece.
    static func wallOrder(_ side: WallSide?, start: Int, _ place: Int) -> Int {
        let wall: Int
        switch side {
        case .ne: wall = 0
        case .nw: wall = 1
        case nil: wall = 2
        }
        return (wall * 1024 + clamp(start, 1024)) * 64 + clamp(place, 64)
    }

    /// Light layer: by island slot, desk, then the lamp's pool before the screen's glow.
    static func deskLightOrder(slot: Int, local: Int, glow: Bool) -> Int {
        (clamp(slot, 16384) * 16 + clamp(local, 16)) * 2 + (glow ? 1 : 0)
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
            if let piece = piece(key, at: center(tile), tile: tile) { floor.append(piece) }
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

    /// One step of the wall pass: a node (cork wall, its cards, elevator, LED) or a piece to bake.
    private struct WallEntry {
        var node: SceneNode?
        var piece: SceneBackground.Piece?
        /// The identifier and order the piece takes if it must be a node.
        var id: String
        var order: Int
    }

    /// The back walls, piece by piece from the corner, then the corner over both. A piece of `span` tiles stands on
    /// the back edge of its tiles: its anchor is the middle of that edge. The cork wall with its cards and the
    /// elevator with its LED are nodes; the segments, windows and corner are baked, unless one of them covers a node
    /// drawn before it (it then becomes a node, in the same order, so that the picture does not change).
    mutating func addWalls() {
        let layout = scene.layout
        let corner = layout.bounds.origin
        let sky = options.night ? "night" : "day"
        var entries: [WallEntry] = []
        for piece in layout.walls {
            guard let side = piece.wall else { continue }
            let facing: Facing = side == .ne ? .ne : .nw
            let tile = side == .ne ? GridPoint(corner.i + piece.start, corner.j) : GridPoint(corner.i, corner.j + piece.start)
            let t = top(tile)
            let half = (x: IsoMath.tileWidth / 4 * piece.span, y: IsoMath.tileHeight / 4 * piece.span)
            let anchor = side == .ne ? PixelPoint(t.x + half.x, t.y + half.y) : PixelPoint(t.x - half.x, t.y + half.y)
            let pieceID = "wall:\(side.rawValue)/\(piece.start)"
            let order = Self.wallOrder(side, start: piece.start, 0)
            switch piece.piece {
            case .segment(let style):
                let key = SpriteKey("wall.segment", variant: style.rawValue, facing: facing)
                entries.append(WallEntry(piece: self.piece(key, at: anchor, tile: tile), id: pieceID, order: order))
            case .window:
                let key = SpriteKey("wall.window", variant: sky, facing: facing)
                guard let window = self.piece(key, at: anchor, tile: tile) else { continue }
                entries.append(WallEntry(piece: window, id: pieceID, order: order))
                if options.night { addStars(window: window.origin, side: side, start: piece.start, tile: tile) }
            case .board:
                let key = SpriteKey("board.cork", facing: facing)
                guard let board = Self.node("wall:board", .wall, key, at: anchor, in: rect, order: order, tile: tile,
                                            target: .corkWall)
                else { continue }
                entries.append(WallEntry(node: board, id: pieceID, order: order))
                let origin = PixelPoint(anchor.x - board.anchor.x, anchor.y - board.anchor.y)
                entries += boardCards(board: origin, side: side, start: piece.start, tile: tile)
            case .elevator:
                // Doors closed (frame 0) at rest; the LED blinks with the clock.
                let key = SpriteKey("elevator", facing: facing)
                guard let elevator = Self.node("wall:elevator", .wall, key, at: anchor, in: rect, order: order, frame: 0,
                                               tile: tile, target: .elevator)
                else { continue }
                entries.append(WallEntry(node: elevator, id: pieceID, order: order))
                let origin = PixelPoint(anchor.x - elevator.anchor.x, anchor.y - elevator.anchor.y)
                let led = Self.plus(origin, WallSprites.elevatorLEDPoint)
                let ledOrder = Self.wallOrder(side, start: piece.start, 1)
                if let node = Self.node("wall:elevator/led", .wall, SpriteKey("elevator.led"), at: led, in: rect,
                                        order: ledOrder, tile: tile, target: .elevator) {
                    entries.append(WallEntry(node: node, id: pieceID, order: ledOrder))
                }
                if options.night, let light = Self.node("wall:elevator/led/light", .wallLight, SpriteKey("elevator.led"),
                                                        at: led, in: rect, order: order, tile: tile, target: nil) {
                    wallLights.append(light)
                }
            case .corner:
                continue
            }
        }
        if layout.walls.contains(where: { $0.piece == .corner }) {
            entries.append(WallEntry(piece: piece(SpriteKey("wall.corner"), at: top(corner), tile: corner),
                                     id: "wall:corner", order: Self.wallOrder(nil, start: 0, 0)))
        }
        bakeWalls(entries)
    }

    /// The wall pass in its order: nodes stay nodes; a piece is baked unless it covers a node drawn before it.
    private mutating func bakeWalls(_ entries: [WallEntry]) {
        var drawn: [(origin: PixelPoint, images: [PixelImage])] = []
        for entry in entries {
            if let node = entry.node {
                nodes.append(node)
                drawn.append((canvasOrigin(of: node), Self.frames(of: node.sprite)))
                continue
            }
            guard let piece = entry.piece, let def = SpriteCatalog.sprite(piece.key) else { continue }
            let image = def.frames[piece.frame]
            let covers = drawn.contains { other in
                other.images.contains { Self.overlap(image, at: piece.origin, $0, at: other.origin) }
            }
            guard covers else {
                walls.append(piece)
                continue
            }
            let node = SceneNode(id: SceneNodeID(entry.id), layer: .wall, sprite: .sprite(piece.key, frame: piece.frame),
                                 position: scenePoint(Self.plus(piece.origin, def.anchor)), anchor: def.anchor,
                                 width: def.width, height: def.height, order: entry.order, tile: piece.tile)
            nodes.append(node)
            drawn.append((piece.origin, [image]))
        }
    }

    /// The mini post-its of the cork wall (hue 0…9, anything else paper), card k in the k-th slot of
    /// `boardSpread`, so that a few cards already cover the board in loose rows; the "+n" counter beyond 48.
    private mutating func boardCards(board: PixelPoint, side: WallSide, start: Int, tile: GridPoint) -> [WallEntry] {
        let facing: Facing = side == .ne ? .ne : .nw
        let slots = WallSprites.boardSlots(wall: side)
        var entries: [WallEntry] = []
        for (k, (index, hue)) in zip(SceneCompositor.boardSpread(slots), scene.boardCardHues).enumerated() {
            let variant = (0..<Palette.projectHues.count).contains(hue) ? "hue\(hue)" : "paper"
            let order = Self.wallOrder(side, start: start, 1 + k)
            let point = Self.plus(board, Self.plus(slots[index], SceneCompositor.boardJitter(index)))
            if let card = Self.node("wall:board/card/\(k)", .wall, SpriteKey("postit.mini", variant: variant, facing: facing),
                                    at: point, in: rect, order: order, tile: tile, target: .corkWall) {
                entries.append(WallEntry(node: card, id: "wall:board/card/\(k)", order: order))
            }
        }
        let extra = scene.boardCardHues.count - slots.count
        if extra > 0, let last = slots.last {
            let plate = HUDSprites.nameplate("+\(extra)", off: false)
            let base = Self.plus(board, PixelPoint(last.x + 8, last.y + 10))
            let anchor = PixelPoint(plate.width / 2, plate.height)
            add("wall:board/more", .overlay, image: plate, name: "nameplate:+\(extra)",
                origin: PixelPoint(base.x - anchor.x, base.y - anchor.y), anchor: anchor,
                order: Self.overlayOrder(tile, 0), tile: tile, target: .corkWall)
        }
        return entries
    }

    /// A big and two small stars in a night window, at spots chosen from the window's position along the wall.
    mutating func addStars(window origin: PixelPoint, side: WallSide, start: Int, tile: GridPoint) {
        guard let spots = SceneCompositor.starSpots[side] else { return }
        let id = "wall:\(side.rawValue)/\(start)/star/"
        if !spots.big.isEmpty {
            let spot = spots.big[(start * 37 + 11) % spots.big.count]
            if let star = Self.node(id + "0", .wallLight, SpriteKey("fx.star", variant: "big"), at: Self.plus(origin, spot),
                                    in: rect, order: Self.wallOrder(side, start: start, 0), tile: tile, target: nil) {
                wallLights.append(star)
            }
        }
        guard !spots.small.isEmpty else { return }
        for k in 0..<2 {
            let spot = spots.small[(start * 53 + k * 101 + 7) % spots.small.count]
            if let star = Self.node(id + "\(k + 1)", .wallLight, SpriteKey("fx.star", variant: "small"),
                                    at: Self.plus(origin, spot), in: rect, order: Self.wallOrder(side, start: start, k + 1),
                                    tile: tile, target: nil) {
                wallLights.append(star)
            }
        }
    }

    /// The lights of the back walls come already clipped by the world in front of them, so that nobody has a mask to
    /// compute: a light that no object of the world covers, whatever their frames, stays its (animated) sprite; one
    /// that is covered becomes its frame 0 without the pixels the world covers at tick 0 (the key poses), a still
    /// image; one covered entirely is left out.
    private func clipWallLights() -> [SceneNode] {
        let world = nodes.filter { $0.layer == .world }.map { (node: $0, origin: canvasOrigin(of: $0)) }
        var out: [SceneNode] = []
        for light in wallLights {
            guard case .sprite(let key, _) = light.sprite, let def = SpriteCatalog.sprite(key) else { continue }
            let origin = canvasOrigin(of: light)
            let front = world.filter {
                Self.intersects($0.origin, $0.node.width, $0.node.height, origin, light.width, light.height)
            }
            // A light that is not a light sprite (the LED) shines on its frame 0 only.
            let shining = def.category == .lights ? def.frames : [def.frames[0]]
            let covered = front.contains { item in
                Self.frames(of: item.node.sprite).contains { frame in
                    shining.contains { Self.overlap($0, at: origin, frame, at: item.origin) }
                }
            }
            guard covered else {
                out.append(light)
                continue
            }
            let shown = def.frameIndex(atTick: light.tickOffset)
            var image = def.frames[shown]
            for item in front {
                let frame = Self.stillFrame(of: item.node)
                for y in 0..<image.height {
                    for x in 0..<image.width where image[x, y].a != 0 {
                        let (fx, fy) = (origin.x + x - item.origin.x, origin.y + y - item.origin.y)
                        if fx >= 0, fy >= 0, fx < frame.width, fy < frame.height, frame[fx, fy].a != 0 { image[x, y] = .clear }
                    }
                }
            }
            guard image.pixels.contains(where: { $0.a != 0 }) else { continue }
            var clipped = light
            clipped.sprite = .image(image, name: key.frameName(shown))
            out.append(clipped)
        }
        return out
    }

    /// Top-left of a node's image on the canvas.
    func canvasOrigin(of node: SceneNode) -> PixelPoint {
        let anchor = WorldScenePlan.canvasPoint(node.position, in: rect)
        return PixelPoint(anchor.x - node.anchor.x, anchor.y - node.anchor.y)
    }

    /// Whether two boxes (top-left, width, height) share a pixel.
    static func intersects(_ a: PixelPoint, _ aw: Int, _ ah: Int, _ b: PixelPoint, _ bw: Int, _ bh: Int) -> Bool {
        a.x < b.x + bw && b.x < a.x + aw && a.y < b.y + bh && b.y < a.y + ah
    }

    /// Whether `a` at `ao` and `b` at `bo` (canvas) have an opaque pixel in common.
    static func overlap(_ a: PixelImage, at ao: PixelPoint, _ b: PixelImage, at bo: PixelPoint) -> Bool {
        let x0 = max(ao.x, bo.x), y0 = max(ao.y, bo.y)
        let x1 = min(ao.x + a.width, bo.x + b.width), y1 = min(ao.y + a.height, bo.y + b.height)
        guard x0 < x1, y0 < y1 else { return false }
        for y in y0..<y1 {
            for x in x0..<x1 where a[x - ao.x, y - ao.y].a != 0 && b[x - bo.x, y - bo.y].a != 0 { return true }
        }
        return false
    }

    /// Every frame a node may show (a given frame, all the frames of an animated sprite or character, the image).
    static func frames(of sprite: SceneSprite) -> [PixelImage] {
        switch sprite {
        case .sprite(let key, let frame):
            guard let def = SpriteCatalog.sprite(key) else { return [] }
            return frame.map { [def.frames[$0]] } ?? def.frames
        case .character(let look, let hue, let animation, let facing):
            let resolved = ResolvedLook(look, projectHue: hue)
            return (0..<animation.framesPerFacing).compactMap {
                CharacterSprites.canvas(animation, facing, frame: $0, look: resolved)?.render(resolved)
            }
        case .image(let image, _):
            return [image]
        }
    }

    /// What a node shows at tick 0.
    static func stillFrame(of node: SceneNode) -> PixelImage {
        SceneCompositor.image(of: node, tick: 0)?.image ?? PixelImage(width: 0, height: 0)
    }

    // MARK: Hall

    /// Coffee machine and plant of the hall; unlockable decor is not drawn before stage 6.
    mutating func addHallProps() {
        for prop in scene.layout.props where inScope(prop.tile) {
            let id = "hall:\(prop.kind.rawValue)/\(prop.tile.i),\(prop.tile.j)"
            // Props come after the objects of a post on their tile (places 4 to 7).
            let place = 4 + (propsOnTile[prop.tile] ?? 0)
            let order = Self.objectOrder(prop.tile, .furniture, place)
            switch prop.kind {
            case .coffeeMachine:
                add(id, .world, SpriteKey("decor.coffeeMachine"), at: center(prop.tile), order: order, tile: prop.tile,
                    target: .hallProp(prop.kind))
            case .plantSmall:
                shadow("shadow.small", under: prop.tile)
                add(id, .world, SpriteKey("decor.plantSmall"), at: center(prop.tile), order: order, tile: prop.tile,
                    target: .hallProp(prop.kind))
            default:
                continue
            }
            propsOnTile[prop.tile, default: 0] += 1
        }
    }

    // MARK: Islands

    mutating func addIsland(_ island: IslandPlacement) {
        let project = island.projectID, part = island.part
        let prefix = "island:\(project)/\(part)/"
        let visual = scene.projects[project]
        let hue = hue(of: project)
        if inScope(island.sign) {
            let name = visual?.name ?? ""
            let label = part == 0 ? name : "\(name) · \(part + 1)"
            let anchor = SpriteCatalog.sprite(SpriteKey("sign.island", variant: "hue\(hue)"))?.anchor ?? PixelPoint(32, 38)
            // ×2 in the overview, so that the name keeps the size it has at ×1 (décision 2 of the first render).
            let scale = overview ? SceneCompositor.overviewSignScale : 1
            let foot = Self.plus(center(island.sign), SceneCompositor.signFoot)
            let footAnchor = PixelPoint(anchor.x * scale, anchor.y * scale)
            add(prefix + "sign", .world, image: HUDSprites.sign(name: label, hue: hue).scaled(by: scale),
                name: "sign:\(label)", origin: PixelPoint(foot.x - footAnchor.x, foot.y - footAnchor.y),
                anchor: footAnchor, order: Self.objectOrder(island.sign, .furniture, 0), tile: island.sign,
                target: .islandSign(project, part: part))
        }
        if inScope(island.plant) {
            shadow("shadow.small", under: island.plant)
            add(prefix + "plant", .world, SpriteKey("decor.plantSmall"), at: center(island.plant),
                order: Self.objectOrder(island.plant, .furniture, 0), tile: island.plant,
                target: .islandFloor(project, part: part))
        }
        // Dropping a post-it on the island (its floor or its sign): every tile of its rug.
        if scene.dropTarget == .islandFloor(project, part: part) || scene.dropTarget == .islandSign(project, part: part) {
            for tile in island.rug.tiles where inScope(tile) {
                add(prefix + "hover/\(tile.i),\(tile.j)", .world, SpriteKey("floor.hover"), at: center(tile),
                    order: Self.markOrder(tile, .islandHover), frame: markFrame, tile: tile, target: nil)
            }
        }
        for desk in island.desks { addPost(desk, island: island, hue: hue) }
    }

    mutating func addPost(_ desk: DeskPlacement, island: IslandPlacement, hue: Int) {
        let project = island.projectID
        let agentID = desk.agentID.flatMap { scene.agents[$0] == nil ? nil : $0 }
        let agent = agentID.flatMap { scene.agents[$0] }
        let hidden = agentID.map(scene.hiddenAgents.contains) ?? false
        let post = "post:\(project)/\(desk.index)/"
        let target: SceneHitTarget = agentID.map(SceneHitTarget.agent) ?? .freeDesk(project, deskIndex: desk.index)
        // Only a free desk takes the marks of a free desk; an agent's drop target is its seat.
        let free = agentID == nil
        let freeHovered = free && scene.hovered == .freeDesk(project, deskIndex: desk.index)
        let freeDropped = free && scene.dropTarget == .freeDesk(project, deskIndex: desk.index)
        let agentDropped = agentID.map { scene.dropTarget == .agent($0) } ?? false

        if inScope(desk.seatTile) {
            let seat = desk.seatTile
            if let agentID { seats[agentID] = IsoMath.tileCenter(seat) }
            addSeat(desk, post: post, agent: hidden ? nil : agent, jacket: agent?.presentation.jacketOnChair == true,
                    agentID: agentID, hue: hue, target: target)
            if freeHovered { mark(post + "hover/seat", "floor.hover", seat, .hover) }
            if freeDropped || agentDropped { mark(post + "drop/seat", "floor.dropTarget", seat, .drop) }
            if let agentID, !hidden, scene.selectedAgent == agentID {
                mark("agent:\(agentID)/selection", "ov.selection", seat, .selection)
            }
        }
        if inScope(desk.deskTile) {
            addDesk(desk, post: post, agent: agent, slot: island.slot, target: target)
            if freeHovered { mark(post + "hover/desk", "floor.hover", desk.deskTile, .hover) }
            if freeDropped { mark(post + "drop/desk", "floor.dropTarget", desk.deskTile, .drop) }
        }
        guard let agentID, let agent, !hidden else { return }
        if inScope(desk.sideTile), agent.presentation.subagents > 0 {
            let c = center(desk.sideTile)
            let minis = SceneCompositor.miniOffsets(rowFacesViewer: desk.facing.isTowardViewer)
                .prefix(agent.presentation.subagents)
                .enumerated().sorted { $0.element.y < $1.element.y }   // the farther one first
            for (place, (k, offset)) in minis.enumerated() {
                add("agent:\(agentID)/mini/\(k)", .world, SpriteKey("agent.mini", variant: "hue\(hue)"),
                    at: Self.plus(c, offset), order: Self.objectOrder(desk.sideTile, .character, place), tickOffset: 6 * k,
                    tile: desk.sideTile, target: .agent(agentID))
            }
        }
        if inScope(desk.seatTile) { addOverlays(desk, island: island, agentID: agentID, agent: agent) }
    }

    /// A floor mark centred on a tile: under every object (`markOrder`), not clickable.
    mutating func mark(_ id: String, _ sprite: SpriteID, _ tile: GridPoint, _ kind: Mark) {
        add(id, .world, SpriteKey(sprite), at: center(tile), order: Self.markOrder(tile, kind), frame: markFrame,
            tile: tile, target: nil)
    }

    /// The avatar faces the post's gaze, or turns toward the viewer when it raises its hand.
    static func avatarFacing(_ p: AgentPresentation, gaze: Facing) -> Facing {
        p.facesViewer && !gaze.isTowardViewer ? gaze.opposite : gaze
    }

    /// A facing the animation has: the wanted one, else its opposite, else the animation's first.
    static func characterFacing(_ animation: CharacterAnimation, wanted: Facing) -> Facing {
        let facings = animation.facings
        return facings.contains(wanted) ? wanted : (facings.contains(wanted.opposite) ? wanted.opposite : facings[0])
    }

    /// Chair and avatar (`agent` nil: nobody sits, a hidden agent included). An avatar facing the viewer sits in
    /// front of the backrest (chair first); one turning its back to the viewer is drawn first, the backrest covering
    /// the bottom of its back.
    mutating func addSeat(_ desk: DeskPlacement, post: String, agent: SceneAgent?, jacket: Bool, agentID: AgentID?,
                          hue: Int, target: SceneHitTarget) {
        let seat = desk.seatTile, point = center(seat), gaze = desk.facing
        let chair = SpriteKey("chair", variant: "hue\(hue)" + (jacket ? ".jacket" : ""), facing: gaze)
        shadow("shadow.small", under: seat)
        guard let agentID, let agent, let animation = agent.presentation.animation else {
            add(post + "chair", .world, chair, at: point, order: Self.objectOrder(seat, .furniture, 0), tile: seat,
                target: target)
            return
        }
        shadow("shadow.char", under: seat)
        let facing = Self.characterFacing(animation, wanted: Self.avatarFacing(agent.presentation, gaze: gaze))
        let anchor = CharacterSprites.anchor
        nodes.append(SceneNode(id: SceneNodeID("agent:\(agentID)/avatar"), layer: .world,
                               sprite: .character(look: agent.look, hue: hue, animation: animation, facing: facing),
                               position: scenePoint(point), anchor: anchor, width: CharacterSprites.frameWidth,
                               height: CharacterSprites.frameHeight, order: Self.objectOrder(seat, .character, 0),
                               tile: seat, target: .agent(agentID)))
        let chairOrder = facing.isTowardViewer
            ? Self.objectOrder(seat, .furniture, 0) : Self.objectOrder(seat, .character, 1)
        add(post + "chair", .world, chair, at: point, order: chairOrder, tile: seat, target: target)
    }

    // MARK: Desk

    /// One object on the desk top: its footprint (to order the objects back to front) and its sprites.
    struct DeskItem {
        var box: SceneryKit.Box
        var sprites: [(role: String, key: SpriteKey, point: PixelPoint)]
    }

    /// The desk, then its objects back to front: monitor (screen or LED, post-it), keyboard, lamp, a mug or papers on
    /// some posts, the queue. At night, the lamp's pool and the screen's glow (light layer, already clipped).
    mutating func addDesk(_ desk: DeskPlacement, post: String, agent: SceneAgent?, slot: Int, target: SceneHitTarget) {
        let tile = desk.deskTile, point = center(tile), gaze = desk.facing
        let p = agent?.presentation
        shadow("shadow.tile", under: tile)
        add(post + "desk", .world, SpriteKey("desk", variant: "light", facing: gaze), at: point,
            order: Self.objectOrder(tile, .furniture, 0), tile: tile, target: target)

        let screen = p?.screen ?? .off
        let lampLit = options.night && (p?.deskLit ?? false)
        func box(_ a: Range<Int>, _ b: Range<Int>, height: Int) -> SceneryKit.Box {
            DeskLayout.box(a: a, b: b, z: IsoMath.deskTopHeight, height: height, facing: gaze)
        }
        var items: [DeskItem] = []

        // Monitor: the screen faces the agent; row A (gaze away from the viewer) shows it, shifted toward the aisle.
        let monitor = Self.plus(point, FurnitureSprites.monitorOffset(facing: gaze))
        let shift = gaze == .ne ? FurnitureSprites.rowAAisleShift.y : 0
        var monitorSprites: [(role: String, key: SpriteKey, point: PixelPoint)] = []
        let glow: PixelPoint
        if let screenOffset = MonitorSprites.screenOffset(facing: gaze), !gaze.isTowardViewer {
            let screenPoint = Self.plus(monitor, screenOffset)
            monitorSprites.append(("monitor", SpriteKey("monitor.front", facing: gaze), monitor))
            monitorSprites.append(("screen", MonitorSprites.screenKey(screen, facing: gaze), screenPoint))
            glow = Self.plus(screenPoint, SceneCompositor.glowOnScreen)
            if let card = agent?.extras.cardOnScreenHue {
                monitorSprites.append(("postit", Self.postitKey(card), Self.plus(screenPoint, SceneCompositor.postitOnScreen)))
            }
        } else {
            monitorSprites.append(("monitor", MonitorSprites.ledKey(screen, facing: gaze), monitor))
            glow = Self.plus(monitor, SceneCompositor.glowOnBack)
            if let card = agent?.extras.cardOnScreenHue {
                monitorSprites.append(("postit", Self.postitKey(card), Self.plus(monitor, SceneCompositor.postitOnBack)))
            }
        }
        items.append(DeskItem(box: box((-4 + shift)..<(4 + shift), -3..<(-1), height: 20), sprites: monitorSprites))

        items.append(DeskItem(box: box(DeskItemSprites.keyboardCells.a, DeskItemSprites.keyboardCells.b, height: 2),
                              sprites: [("keyboard", SpriteKey("keyboard", facing: gaze),
                                         Self.plus(point, FurnitureSprites.keyboardOffset(facing: gaze)))]))
        let lamp = Self.plus(point, FurnitureSprites.lampOffset(facing: gaze))
        items.append(DeskItem(box: box(DeskItemSprites.lampCells.a, DeskItemSprites.lampCells.b, height: 17),
                              sprites: [("lamp", SpriteKey("lamp.desk", variant: lampLit ? "on" : "off", facing: gaze), lamp)]))
        if agent != nil {
            switch desk.index % 3 {
            case 0:
                items.append(DeskItem(box: box(DeskItemSprites.mugCells.a, DeskItemSprites.mugCells.b, height: 6),
                                      sprites: [("mug", SpriteKey("mug", facing: gaze),
                                                 Self.plus(point, FurnitureSprites.mugOffset(facing: gaze)))]))
            case 1:
                items.append(DeskItem(box: box(DeskItemSprites.papersCells.a, DeskItemSprites.papersCells.b, height: 2),
                                      sprites: [("papers", SpriteKey("papers", facing: gaze),
                                                 Self.plus(point, FurnitureSprites.papersOffset(facing: gaze)))]))
            default:
                break
            }
        }
        if let queued = agent?.extras.queued, queued > 0 {
            let cells = DeskItemSprites.queuePlacement(facing: gaze)
            items.append(DeskItem(box: box(cells.a, cells.b, height: 3),
                                  sprites: [("queue", SpriteKey("desk.queue", variant: "\(min(queued, 3))"),
                                             Self.plus(point, FurnitureSprites.queueOffset(facing: gaze)))]))
        }
        // items[0] is the monitor (with its screen or LED and its post-it): what the screen's glow leaves dark. Its
        // frames all have the same shape, so its frame 0 clips the glow at every tick.
        var monitorParts: [(image: PixelImage, origin: PixelPoint)] = []
        var place = 0
        for index in SceneryKit.paintersOrder(items.map(\.box)) {
            for sprite in items[index].sprites {
                guard let rect = add(post + sprite.role, .world, sprite.key, at: sprite.point,
                                     order: Self.objectOrder(tile, .screen, place), tile: tile, target: target)
                else { continue }
                place += 1
                if index == 0, let def = SpriteCatalog.sprite(sprite.key) {
                    monitorParts.append((def.frames[0], PixelPoint(rect.x, rect.y)))
                }
            }
        }

        guard options.night else { return }
        let local = 2 * desk.post + (desk.row == .b ? 1 : 0)
        if lampLit, let def = SpriteCatalog.sprite(SpriteKey("light.cone")) {
            // The pool lies on the desk top under the lamp's base, clipped to the top.
            let pool = Self.plus(point, FurnitureSprites.lightConeOffset(facing: gaze))
            let origin = PixelPoint(pool.x - def.anchor.x, pool.y - def.anchor.y)
            let deskTop = PixelPoint(point.x, point.y - IsoMath.deskTopHeight)
            let image = Self.clipped(def.frames[0], at: origin, toDiamondAt: deskTop,
                                     halfWidth: SceneCompositor.deskTopHalfWidth)
            add(post + "cone", .light, image: image, name: SpriteKey("light.cone").frameName(0), origin: origin,
                anchor: def.anchor, order: Self.deskLightOrder(slot: slot, local: local, glow: false), tile: tile,
                target: nil)
        }
        if screen != .off, let def = SpriteCatalog.sprite(SpriteKey("light.screenGlow")) {
            // The glow lights the desk around the monitor, never the monitor itself: from behind (row B) the lit
            // back read as glass, from the front the screen's own colours shifted.
            let origin = PixelPoint(glow.x - def.anchor.x, glow.y - def.anchor.y)
            let image = Self.clipped(def.frames[0], at: origin, outside: monitorParts)
            add(post + "glow", .light, image: image, name: SpriteKey("light.screenGlow").frameName(0), origin: origin,
                anchor: def.anchor, order: Self.deskLightOrder(slot: slot, local: local, glow: true), tile: tile,
                target: nil)
        }
    }

    /// `image` placed at `origin`, without its pixels where one of `parts` is opaque.
    static func clipped(_ image: PixelImage, at origin: PixelPoint,
                        outside parts: [(image: PixelImage, origin: PixelPoint)]) -> PixelImage {
        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].a != 0 {
                let (cx, cy) = (origin.x + x, origin.y + y)
                let covered = parts.contains { part in
                    let (px, py) = (cx - part.origin.x, cy - part.origin.y)
                    return px >= 0 && py >= 0 && px < part.image.width && py < part.image.height && part.image[px, py].a != 0
                }
                if covered { out[x, y] = .clear }
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
    /// hovering (row A under the post, row B beside the head), or when the agent is hovered. The overview keeps only
    /// the urgent signs (décision 2 of the first render): the XL "!" of a wait with its halo, the storm of an error,
    /// and their agents' name plates, drawn ×2 over the sign (`addOverviewNameplate`); no bubble, badge, state icon
    /// or queue badge. Reduce Motion (7.9): the XL "!" at every zoom, no halo, every overlay on its frame 0.
    mutating func addOverlays(_ desk: DeskPlacement, island: IslandPlacement, agentID: AgentID, agent: SceneAgent) {
        let p = agent.presentation
        let id = "agent:\(agentID)/"
        let target = SceneHitTarget.agent(agentID)
        let seat = desk.seatTile
        let c = center(seat)
        let signs = !overview || p.showsUrgentSign
        let shift = SceneCompositor.headShift(p, facing: Self.avatarFacing(p, gaze: desk.facing))
        let head = PixelPoint(c.x + shift.x, c.y - SceneCompositor.overlayLift(p, row: desk.row) + shift.y)
        // The top of the signs over the head (the overlay and its halo), on the canvas.
        var signTop: Int?
        if signs {
            var right = head.x
            if let overlay = p.overlay {
                if overlay == .bang && p.halo && !options.reduceMotion {
                    let lift = overview ? SceneCompositor.haloLift.xl : SceneCompositor.haloLift.normal
                    if let rect = add(id + "halo", .overlay, SpriteKey("ov.bang.halo"), at: PixelPoint(head.x, head.y - lift),
                                      order: Self.overlayOrder(seat, 0), frame: markFrame, tile: seat, target: target) {
                        signTop = rect.y
                    }
                }
                let key = Self.primaryKey(overlay, tool: p.toolIcon, overview: overview || options.reduceMotion)
                if let rect = add(id + "overlay", .overlay, key, at: head, order: Self.overlayOrder(seat, 1),
                                  frame: markFrame, tile: seat, target: target) {
                    right = rect.x + rect.width
                    signTop = min(signTop ?? rect.y, rect.y)
                }
                if overlay == .bang, let icon = p.toolIcon, !overview {
                    right = putBeside(id + "bubble", SpriteKey(icon.spriteID), right: right, baseline: head.y,
                                      order: Self.overlayOrder(seat, 2), tile: seat, target: target)
                }
            } else if p.launchingSign, let rect = add(id + "launching", .overlay, HUDSprites.stateKey(.launching), at: head,
                                                      order: Self.overlayOrder(seat, 1), frame: markFrame, tile: seat,
                                                      target: target) {
                right = rect.x + rect.width
            }
            if !overview {
                for badge in p.badges {
                    let place = 3 + (SceneBadge.allCases.firstIndex(of: badge) ?? 0)
                    right = putBeside(id + "badge/\(badge.rawValue)", SpriteKey(badge.spriteID), right: right,
                                      baseline: head.y, order: Self.overlayOrder(seat, place), tile: seat, target: target)
                }
                if agent.extras.queued > 0, inScope(desk.deskTile) {
                    let queue = Self.plus(center(desk.deskTile), FurnitureSprites.queueOffset(facing: desk.facing))
                    add(id + "queueBadge", .overlay, HUDSprites.queueBadgeKey(count: agent.extras.queued),
                        at: Self.plus(queue, SceneCompositor.queueBadgeOffset), order: Self.overlayOrder(seat, 8),
                        frame: markFrame, tile: seat, target: target)
                }
            }
        }
        guard (signs && p.nameplateAlways) || scene.hovered == .agent(agentID) else { return }
        let plate = HUDSprites.nameplate(p.nameplateOff ? "\(agent.name) · OFF" : agent.name, off: p.nameplateOff)
        if overview {
            addOverviewNameplate(plate, id: id + "nameplate", name: agent.name, head: head, signTop: signTop,
                                 island: island, seat: seat, target: target)
            return
        }
        let origin: PixelPoint, anchor: PixelPoint
        if desk.row == .b {
            origin = SceneCompositor.rowBNameplateOrigin(p, plate: (plate.width, plate.height), seat: c)
            // Beside the head its right edge stays put; centred over an empty chair, its centre.
            anchor = PixelPoint(p.animation == nil ? plate.width / 2 : plate.width, plate.height)
        } else {
            origin = PixelPoint(c.x - plate.width / 2, c.y + SceneCompositor.nameplateDrop - plate.height)
            anchor = PixelPoint(plate.width / 2, plate.height)
        }
        add(id + "nameplate", .overlay, image: plate, name: "nameplate:\(agent.name)", origin: origin, anchor: anchor,
            order: Self.overlayOrder(seat, 9), tile: seat, target: target)
    }

    /// Px between an overview name plate and the sign under it, or the island sign beside it.
    static let overviewNameplateGap = 2

    /// The overview's name plate (décision of the milestone, "Texte en vue d'ensemble"): ×2 like the signs
    /// (`SceneCompositor.overviewSignScale`), so that its text keeps the size it has at ×1; centred over the head,
    /// `overviewNameplateGap` px over the top of the "!" and its halo or of the storm (`signTop`), right over the head
    /// without a sign (a hovered agent). Pushed right, past the island's sign and `overviewNameplateGap` px clear of
    /// it, where it would touch it (desk A0, beside the sign, under a storm). The sign's place comes from the island's
    /// geometry, drawn or not, so that a crop does not move the plate.
    mutating func addOverviewNameplate(_ plate: PixelImage, id: String, name: String, head: PixelPoint, signTop: Int?,
                                       island: IslandPlacement, seat: GridPoint, target: SceneHitTarget) {
        let scale = SceneCompositor.overviewSignScale, gap = Self.overviewNameplateGap
        let big = plate.scaled(by: scale)
        let bottom = (signTop ?? head.y) - gap
        var origin = PixelPoint(head.x - big.width / 2, bottom - big.height)
        if let sign = overviewSignRect(island) {
            let clear = origin.x + big.width + gap <= sign.x || sign.x + sign.width + gap <= origin.x
                || origin.y + big.height + gap <= sign.y || sign.y + sign.height + gap <= origin.y
            if !clear { origin.x = max(origin.x, sign.x + sign.width + gap) }
        }
        add(id, .overlay, image: big, name: "nameplate:\(name)", origin: origin,
            anchor: PixelPoint(big.width / 2, big.height), order: Self.overlayOrder(seat, 9), tile: seat, target: target)
    }

    /// Where the overview draws an island's sign (×2) on the canvas, whether it is in the crop or not; nil for a hue
    /// missing from the catalog.
    func overviewSignRect(_ island: IslandPlacement) -> PixelRect? {
        guard let def = SpriteCatalog.sprite(SpriteKey("sign.island", variant: "hue\(hue(of: island.projectID))")) else {
            return nil
        }
        let scale = SceneCompositor.overviewSignScale
        let foot = Self.plus(center(island.sign), SceneCompositor.signFoot)
        return PixelRect(x: foot.x - def.anchor.x * scale, y: foot.y - def.anchor.y * scale, width: def.width * scale,
                         height: def.height * scale)
    }

    /// Places a sprite whose left edge is `badgeGap` right of `right`, its anchor on the baseline; returns its right
    /// edge.
    mutating func putBeside(_ id: String, _ key: SpriteKey, right: Int, baseline: Int, order: Int, tile: GridPoint,
                            target: SceneHitTarget) -> Int {
        guard let def = SpriteCatalog.sprite(key) else { return right }
        let x = right + SceneCompositor.badgeGap
        add(id, .overlay, key, at: PixelPoint(x + def.anchor.x, baseline), order: order, frame: markFrame, tile: tile,
            target: target)
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
