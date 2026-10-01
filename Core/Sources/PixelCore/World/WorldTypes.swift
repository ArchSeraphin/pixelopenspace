import Foundation

// Inputs and placements of the world layout (3.8). Pure values: `WorldLayout.compute` turns projects, agents and
// decor into tiles; the compositor and the scene only draw the result.

/// The decor objects of 4.1. Only `plantSmall` and `coffeeMachine` are drawn in v0.
public enum DecorKind: String, CaseIterable, Codable, Sendable {
    case plantSmall, coffeeMachine, cactus, espressoMachine, floorLamp, plantBig, posterMountain, posterWave,
         posterRobot, aquarium, rug, bookshelf, sofa, arcade, waterCooler
}

/// What a decor object belongs to: the hall, or the island of a project (it goes when the project is archived).
public enum DecorAnchor: Hashable, Codable, Sendable {
    case hall
    case island(ProjectID)
}

/// A decor object placed by the user (edit mode, step 6). `tile` is a world tile.
public struct DecorItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: DecorKind
    public var tile: GridPoint
    public var facing: Facing
    public var anchor: DecorAnchor

    public init(id: UUID, kind: DecorKind, tile: GridPoint, facing: Facing, anchor: DecorAnchor) {
        self.id = id
        self.kind = kind
        self.tile = tile
        self.facing = facing
        self.anchor = anchor
    }
}

/// The fixed grid of the open space (3.8).
public struct LayoutConfig: Hashable, Sendable {
    /// One slot: an 8-desk island of 10×7 tiles plus its corridors.
    public var slotPitch: GridSize
    /// Fixed band along the back wall (j < hallDepth): hall, cork wall, elevator.
    public var hallDepth: Int
    /// Island origin inside its slot.
    public var islandInset: GridPoint
    /// Desks of one island part: deskIndex / desksPerIsland is the part, deskIndex % desksPerIsland the local index.
    public var desksPerIsland: Int

    public init(slotPitch: GridSize = GridSize(w: 12, d: 9), hallDepth: Int = 6, islandInset: GridPoint = GridPoint(1, 1),
                desksPerIsland: Int = 8) {
        self.slotPitch = slotPitch
        self.hallDepth = hallDepth
        self.islandInset = islandInset
        self.desksPerIsland = desksPerIsland
    }

    public static let standard = LayoutConfig()
}

public struct WorldInput: Sendable {
    public var projects: [Project]
    public var agents: [Agent]
    public var decor: [DecorItem]
    public var config: LayoutConfig

    public init(projects: [Project], agents: [Agent], decor: [DecorItem] = [], config: LayoutConfig = .standard) {
        self.projects = projects
        self.agents = agents
        self.decor = decor
        self.config = config
    }

    public init(workspace: Workspace, decor: [DecorItem] = [], config: LayoutConfig = .standard) {
        self.init(projects: workspace.projects, agents: workspace.agents, decor: decor, config: config)
    }
}

/// The two rows of an island, back to back. A: front row, gaze `ne` (the viewer sees the lit screen and the
/// agent's back). B: back row, gaze `sw` (the viewer sees the face).
public enum IslandRow: String, Codable, Sendable {
    case a, b
}

/// One desk: the desk tile, the seat tile behind it (along j), and the free tile beside it (along +i), which takes
/// the subagent minis and the lamp's pool of light.
public struct DeskPlacement: Hashable, Sendable {
    /// `Agent.deskIndex`: 8 per island part, the part first.
    public var index: Int
    public var row: IslandRow
    /// Position in the row, along +i.
    public var post: Int
    public var deskTile: GridPoint
    public var seatTile: GridPoint
    public var sideTile: GridPoint
    /// Gaze of the seated agent: `.ne` in row A, `.sw` in row B. Desk objects are drawn in this direction.
    public var facing: Facing
    /// `nil`: a free desk.
    public var agentID: AgentID?

    public init(index: Int, row: IslandRow, post: Int, deskTile: GridPoint, seatTile: GridPoint, sideTile: GridPoint,
                facing: Facing, agentID: AgentID?) {
        self.index = index
        self.row = row
        self.post = post
        self.deskTile = deskTile
        self.seatTile = seatTile
        self.sideTile = sideTile
        self.facing = facing
        self.agentID = agentID
    }
}

/// One island, or one annex of a project ("API · 2").
public struct IslandPlacement: Hashable, Sendable {
    public var projectID: ProjectID
    /// 0: the main island, in `Project.slot`; 1 and more: annexes.
    public var part: Int
    public var slot: Int
    /// Never moves: it derives from the slot alone.
    public var origin: GridPoint
    /// (capacity + 2) × 7: the tiles the island reserves in its slot.
    public var size: GridSize
    /// 4 or 8 desks (the 4-step rule of 3.8): how far the island may grow before it reserves more of its slot.
    public var capacity: Int
    /// The carpet: the occupied desks and a free one, by whole posts (`WorldLayout.rugDesks`), plus a one-tile
    /// margin, from local (0, 1), 6 tiles deep. Grows toward +i as agents arrive, from a corner that never moves;
    /// always inside `rect`.
    public var rug: GridRect
    /// Local (0, 6): the island sign, on the front-left corner of the rug (it never moves).
    public var sign: GridPoint
    /// Local (rug W − 1, 1): the island plant, on the back-right corner of the rug.
    public var plant: GridPoint
    /// The desks on the rug, by index: every occupied desk and at least one free desk while the island is not full.
    public var desks: [DeskPlacement]

    public init(projectID: ProjectID, part: Int, slot: Int, origin: GridPoint, size: GridSize, capacity: Int,
                rug: GridRect, sign: GridPoint, plant: GridPoint, desks: [DeskPlacement]) {
        self.projectID = projectID
        self.part = part
        self.slot = slot
        self.origin = origin
        self.size = size
        self.capacity = capacity
        self.rug = rug
        self.sign = sign
        self.plant = plant
        self.desks = desks
    }

    public var rect: GridRect { GridRect(origin: origin, size: size) }
}

public enum WallSegmentStyle: String, CaseIterable, Codable, Sendable {
    case plain, socket, baseboard
}

public enum WallPiece: Hashable, Sendable {
    case corner
    case segment(WallSegmentStyle)
    case window
    /// The cork wall (6 tiles of the `ne` wall).
    case board
    /// The elevator (2 tiles of the `nw` wall).
    case elevator
}

/// A piece of the two back walls. The `ne` wall runs along j = 0 (tiles (start, 0)…), the `nw` wall along
/// i = 0 (tiles (0, start)…). The front edges have no wall.
public struct WallPlacement: Hashable, Sendable {
    /// `nil` for the corner.
    public var wall: WallSide?
    /// Tile index along the wall: i for `.ne`, j for `.nw`.
    public var start: Int
    /// Tiles covered: board 6, elevator 2, others 1.
    public var span: Int
    public var piece: WallPiece

    public init(wall: WallSide?, start: Int, span: Int, piece: WallPiece) {
        self.wall = wall
        self.start = start
        self.span = span
        self.piece = piece
    }
}

/// A placed decor object: a fixed hall prop or a decor item of the input.
public struct PropPlacement: Hashable, Sendable {
    public var kind: DecorKind
    public var tile: GridPoint
    public var facing: Facing
    public var anchor: DecorAnchor

    public init(kind: DecorKind, tile: GridPoint, facing: Facing, anchor: DecorAnchor) {
        self.kind = kind
        self.tile = tile
        self.facing = facing
        self.anchor = anchor
    }
}

public struct WorldLayoutResult: Equatable, Sendable {
    /// By (slot, part).
    public var islands: [IslandPlacement]
    /// Hall props and input decor, by tile (j, then i), kind, facing and anchor. Island plants are in
    /// `IslandPlacement.plant`.
    public var props: [PropPlacement]
    /// The corner, then the `ne` wall by start, then the `nw` wall by start.
    public var walls: [WallPlacement]
    /// Every slot rect inside the bounds, row-major (floor painted as corridor under the islands).
    public var corridors: [GridRect]
    public var bounds: GridRect
    public var hall: GridRect
    /// Floor tiles in front of the cork wall: i 1 to 6 along the `ne` wall.
    public var boardWall: GridRect
    /// Floor tiles in front of the elevator: j 2 and 3 along the `nw` wall.
    public var elevator: GridRect

    public init(islands: [IslandPlacement], props: [PropPlacement], walls: [WallPlacement], corridors: [GridRect],
                bounds: GridRect, hall: GridRect, boardWall: GridRect, elevator: GridRect) {
        self.islands = islands
        self.props = props
        self.walls = walls
        self.corridors = corridors
        self.bounds = bounds
        self.hall = hall
        self.boardWall = boardWall
        self.elevator = elevator
    }
}
