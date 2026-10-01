import Foundation

// The public plan of a scene (stage 3, décision 1): every node SpriteKit shows, with a stable identifier, and the
// baked background. `ScenePlanner` builds it from a `SceneInput`; `SceneCompositor.render(_:tick:zoom:)` draws it in
// software (the reference); the app reconciles its nodes by identifier with `diff(from:)`.

/// What a click on a point of the scene means (3.9).
public enum SceneHitTarget: Hashable, Sendable {
    case agent(AgentID)
    case freeDesk(ProjectID, deskIndex: Int)
    case islandSign(ProjectID, part: Int)
    /// The rug and the island plant.
    case islandFloor(ProjectID, part: Int)
    case corkWall
    case elevator
    case hallProp(DecorKind)
    /// Hall or corridor, nothing on it.
    case floor(GridPoint)
}

/// Drawing passes, back to front. background: baked (décision 2), no node; wall: cork wall, its cards, elevator and
/// LED; world: floor marks, then furniture, characters, signs; light and wallLight: additive, at night only;
/// overlay: never veiled.
///
/// At night the veil goes over the background, wall and world layers, then the lights of both light layers are drawn
/// into one layer (wallLight first, each light over the ones before) and added once at `Palette.lightPoolAlpha`. A
/// light node drawn from a catalog sprite that is not itself a light (category other than `.lights`: the elevator's
/// LED) shines on its frame 0 only, the lit one, and adds nothing on its other frames.
public enum SceneLayer: Int, CaseIterable, Comparable, Sendable {
    case background, wall, world, wallLight, light, overlay

    public static func < (lhs: SceneLayer, rhs: SceneLayer) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Every `SceneNode.order` of the layer is in 0..<orderLimit: background 2^10 (no node: room for the tiles of
    /// the baked image), wall 2^18, world 2^22, wallLight 2^18, light 2^19, overlay 2^21.
    public var orderLimit: Int {
        switch self {
        case .background: return 1 << 10
        case .wall, .wallLight: return 1 << 18
        case .world: return 1 << 22
        case .light: return 1 << 19
        case .overlay: return 1 << 21
        }
    }

    /// The limits of the layers before this one, added up: `zBase + order` sorts every node of a plan back to
    /// front, and stays under 2^23 (`SceneNode.zOrder`).
    public var zBase: Int {
        SceneLayer.allCases.prefix { $0 < self }.reduce(0) { $0 + $1.orderLimit }
    }
}

/// "wall:board", "post:<projectID>/3/desk", "agent:<agentID>/avatar": stable while the object exists.
public struct SceneNodeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static func < (lhs: SceneNodeID, rhs: SceneNodeID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SceneSprite: Hashable, Sendable {
    /// A catalog sprite: `frame` nil = animated with the sprite's holds (frame 0 in a still render).
    case sprite(SpriteKey, frame: Int?)
    /// The look's sheet (CharacterSprites), animated. `facing` is a direction the animation has.
    case character(look: AgentLook, hue: Int, animation: CharacterAnimation, facing: Facing)
    /// A composed image (sign, name plate, clipped light): textures are cached by `PixelImage.fingerprint`.
    /// `name` says what it is ("sign:API", "nameplate:Nova", "light.cone#0" for a clipped frame of a sprite).
    case image(PixelImage, name: String)
}

/// One sprite of the scene.
///
/// Identifiers: `wall:board`, `wall:board/card/<k>` (k-th card of `SceneInput.boardCardHues`), `wall:board/more`
/// (the "+n" counter), `wall:elevator` (frame 0 fixed), `wall:elevator/led`, `wall:elevator/led/light` and
/// `wall:<ne|nw>/<start>/star/<k>` (night); `hall:<kind>/<i>,<j>`; `island:<projectID>/<part>/sign`, `…/plant`,
/// `…/hover/<i>,<j>`; `post:<projectID>/<deskIndex>/<role>` for `chair`, `desk`, `monitor`, `screen`, `keyboard`,
/// `lamp`, `mug`, `papers`, `postit`, `queue`, `cone`, `glow`, `hover/desk`, `hover/seat`, `drop/desk`,
/// `drop/seat`; `agent:<agentID>/<role>` for `avatar`, `mini/<k>`, `selection`, `halo`, `overlay`, `bubble`,
/// `badge/<kind>`, `queueBadge`, `nameplate`, `launching`. A wall piece that must be drawn over one of those
/// nodes would be a node too, `wall:<ne|nw>/<start>` or `wall:corner` (none in the layouts of v0).
///
/// Targets (3.9): every node of an occupied post and of its agent → `.agent`; of a free post → `.freeDesk`; the
/// sign → `.islandSign`; the island plant → `.islandFloor`; the cork wall, its cards and its counter →
/// `.corkWall`; the elevator and its LED → `.elevator`; hall props → `.hallProp`; lights and floor marks → nil.
public struct SceneNode: Hashable, Sendable {
    public var id: SceneNodeID
    public var layer: SceneLayer
    public var sprite: SceneSprite
    /// The anchor, in scene texels, y up (décision 16).
    public var position: ScenePoint
    /// Px from the top-left of the image.
    public var anchor: PixelPoint
    public var width: Int
    public var height: Int
    /// Painter's order inside its layer, in 0..<`layer.orderLimit`: unique in the layer, back to front. A key, not a
    /// rank: it derives from the object's own tile and its place there (world and overlay), its place along the
    /// wall, or its post (lights), never from the other objects of the scene, so it stays the same while the node
    /// exists and a node that comes or goes changes no other node. The world layer draws the floor marks first,
    /// then the objects by (i + j of their tile, `DepthLayer`), as `IsoMath.depth`, then left to right (by i), then
    /// in their order on the tile; the overlay layer by (i + j, i) of the seat, then halo, sign, bubble, badges,
    /// queue badge and name plate. Tiles beyond i = 255 or i + j = 511 (worlds wider than 21 slots) share the
    /// last values.
    public var order: Int
    /// Animation clock offset, in ticks (subagent minis).
    public var tickOffset: Int
    /// The tile the object stands on.
    public var tile: GridPoint?
    /// nil: not clickable (lights, marks).
    public var target: SceneHitTarget?

    public init(id: SceneNodeID, layer: SceneLayer, sprite: SceneSprite, position: ScenePoint, anchor: PixelPoint,
                width: Int, height: Int, order: Int, tickOffset: Int = 0, tile: GridPoint? = nil,
                target: SceneHitTarget? = nil) {
        self.id = id
        self.layer = layer
        self.sprite = sprite
        self.position = position
        self.anchor = anchor
        self.width = width
        self.height = height
        self.order = order
        self.tickOffset = tickOffset
        self.tile = tile
        self.target = target
    }

    /// The node's place among all the nodes of a plan, back to front: `layer.zBase + order`, under 2^23, so it is
    /// exact as a Float (SpriteKit's `zPosition`).
    public var zOrder: Int { layer.zBase + order }
}

/// The baked part (décision 2): floor tiles, shadows (applied once at 30 %, only over the floor), wall pieces, in
/// drawing order. Hashable to know when to bake again. Every piece is a still sprite: its frame 0.
public struct SceneBackground: Hashable, Sendable {
    /// One catalog frame, its top-left at `origin` on the canvas (texels, y down).
    public struct Piece: Hashable, Sendable {
        public var key: SpriteKey
        public var frame: Int
        public var origin: PixelPoint
        public var tile: GridPoint?

        public init(key: SpriteKey, frame: Int = 0, origin: PixelPoint, tile: GridPoint?) {
            self.key = key
            self.frame = frame
            self.origin = origin
            self.tile = tile
        }
    }

    /// The canvas: `WorldScenePlan.canvasWidth` × `canvasHeight`.
    public var width: Int
    public var height: Int
    public var floor: [Piece]
    public var shadows: [Piece]
    public var walls: [Piece]

    public init(width: Int, height: Int, floor: [Piece] = [], shadows: [Piece] = [], walls: [Piece] = []) {
        self.width = width
        self.height = height
        self.floor = floor
        self.shadows = shadows
        self.walls = walls
    }
}

public struct WorldScenePlan: Equatable, Sendable {
    /// The canvas rect: the crop, or `layout.bounds`.
    public var rect: GridRect
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var background: SceneBackground
    /// Sorted by (layer, order).
    public var nodes: [SceneNode]
    /// Night only.
    public var veilAlpha: UInt8?
    /// Seat tile centre of every agent seated in the plan, hidden ones included (camera flights, edge arrows,
    /// accessibility frames).
    public var agentSeats: [AgentID: ScenePoint]
    /// Rug of every island part in the canvas rect, and its sign tile; in layout order.
    public var islands: [IslandFrame]

    public struct IslandFrame: Hashable, Sendable {
        public var projectID: ProjectID
        public var part: Int
        public var rug: GridRect
        public var sign: GridPoint

        public init(projectID: ProjectID, part: Int, rug: GridRect, sign: GridPoint) {
            self.projectID = projectID
            self.part = part
            self.rug = rug
            self.sign = sign
        }
    }

    public init(rect: GridRect, canvasWidth: Int, canvasHeight: Int, background: SceneBackground, nodes: [SceneNode],
                veilAlpha: UInt8?, agentSeats: [AgentID: ScenePoint], islands: [IslandFrame]) {
        self.rect = rect
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.background = background
        self.nodes = nodes
        self.veilAlpha = veilAlpha
        self.agentSeats = agentSeats
        self.islands = islands
    }

    /// Décision 16: for a rect of origin (i0, j0) and depth D, x = sceneX + 32·(D − i0 + j0),
    /// y = 96 − 16·(i0 + j0) − sceneY (texels, y down).
    public static func canvasPoint(_ p: ScenePoint, in rect: GridRect) -> PixelPoint {
        let (i0, j0) = (rect.origin.i, rect.origin.j)
        return PixelPoint(p.x + IsoMath.tileWidth / 2 * (rect.size.d - i0 + j0),
                          IsoMath.wallHeight - IsoMath.tileHeight / 2 * (i0 + j0) - p.y)
    }

    /// The inverse of `canvasPoint(_:in:)`.
    public static func scenePoint(_ p: PixelPoint, in rect: GridRect) -> ScenePoint {
        let (i0, j0) = (rect.origin.i, rect.origin.j)
        return ScenePoint(x: p.x - IsoMath.tileWidth / 2 * (rect.size.d - i0 + j0),
                          y: IsoMath.wallHeight - IsoMath.tileHeight / 2 * (i0 + j0) - p.y)
    }

    public func canvasPoint(_ p: ScenePoint) -> PixelPoint { Self.canvasPoint(p, in: rect) }

    public func scenePoint(_ p: PixelPoint) -> ScenePoint { Self.scenePoint(p, in: rect) }

    /// Top-left of a node's image on the canvas.
    public func canvasOrigin(of node: SceneNode) -> PixelPoint {
        let anchor = canvasPoint(node.position)
        return PixelPoint(anchor.x - node.anchor.x, anchor.y - node.anchor.y)
    }

    public func node(_ id: SceneNodeID) -> SceneNode? { nodes.first { $0.id == id } }

    /// What changed since `old` (every node added when nil). Nodes compare by identifier: a node is updated when
    /// any of its fields differs. `added` and `updated` keep the plan's order, `removed` is sorted. The veil is
    /// not a node: compare `veilAlpha`.
    public func diff(from old: WorldScenePlan?) -> ScenePlanDiff {
        guard let old else { return ScenePlanDiff(added: nodes, updated: [], removed: [], backgroundChanged: true) }
        let previous = Dictionary(old.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [SceneNode] = [], updated: [SceneNode] = []
        var kept = Set<SceneNodeID>()
        for node in nodes {
            kept.insert(node.id)
            if let before = previous[node.id] {
                if before != node { updated.append(node) }
            } else {
                added.append(node)
            }
        }
        let removed = Set(old.nodes.map(\.id)).subtracting(kept).sorted()
        return ScenePlanDiff(added: added, updated: updated, removed: removed,
                             backgroundChanged: background != old.background || rect != old.rect)
    }
}

public struct ScenePlanDiff: Equatable, Sendable {
    public var added: [SceneNode]
    public var updated: [SceneNode]
    public var removed: [SceneNodeID]
    /// The background must be baked again.
    public var backgroundChanged: Bool

    public init(added: [SceneNode] = [], updated: [SceneNode] = [], removed: [SceneNodeID] = [],
                backgroundChanged: Bool = false) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.backgroundChanged = backgroundChanged
    }

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty && !backgroundChanged }
}

public struct ScenePlanOptions: Hashable, Sendable {
    /// The overview's plan: signs ×2, XL "!", only the urgent signs (décision 2 of the first render).
    public var overview: Bool
    public var night: Bool
    /// Night veil at 0.35 instead of 0.55.
    public var reduceTransparency: Bool
    /// nil: the whole world with its walls; otherwise only the objects anchored inside, without walls.
    public var crop: GridRect?
    /// 7.9: the XL "!" at every zoom, every overlay on its frame 0 (no bounce), no halo; the floor marks hold
    /// their frame 0 too.
    public var reduceMotion: Bool

    public init(overview: Bool = false, night: Bool = false, reduceTransparency: Bool = false, crop: GridRect? = nil,
                reduceMotion: Bool = false) {
        self.overview = overview
        self.night = night
        self.reduceTransparency = reduceTransparency
        self.crop = crop
        self.reduceMotion = reduceMotion
    }

    /// The plan a software render of these options draws (zoom and tick are the render's).
    public init(_ render: RenderOptions) {
        self.init(overview: render.zoom == .overview, night: render.night,
                  reduceTransparency: render.reduceTransparency, crop: render.crop)
    }
}
