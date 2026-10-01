import Foundation

/// Pure, deterministic placement of islands, desks, walls and hall on the grid (3.8). Append-only: a live project
/// keeps `Project.slot` and an agent keeps `Agent.deskIndex`, and every tile below derives from those two numbers
/// alone, so adding, removing or archiving a project or an agent never moves an existing island or desk, even when
/// an island grows from 4 to 8 desks (it grows toward +i, inside its slot). The rug follows the agents more closely
/// (one post at a time, `rugDesks`) but also grows toward +i from a fixed corner, inside the island's reserved rect.
public enum WorldLayout {
    /// Depth of an island along j, sign and border included.
    static let islandDepth = 7
    /// Cork wall: tiles i 1 to 6 of the `ne` wall.
    static let boardStart = 1
    static let boardSpan = 6
    /// Elevator: tiles j 2 and 3 of the `nw` wall.
    static let elevatorStart = 2
    static let elevatorSpan = 2
    /// Fixed hall props, inside the smallest world (12 tiles wide).
    static let hallProps = [
        PropPlacement(kind: .coffeeMachine, tile: GridPoint(8, 1), facing: .sw, anchor: .hall),
        PropPlacement(kind: .plantSmall, tile: GridPoint(10, 1), facing: .sw, anchor: .hall),
    ]

    /// Live (non-archived) projects get an island in `Project.slot` (a negative slot, which the validator never
    /// leaves, gets none); their agents sit at `deskIndex`. Part p of a project holds the desks p·8 ..< (p + 1)·8;
    /// part p ≥ 1 (an annex) exists when it has an agent or when part p − 1 is full, and takes the lowest slot used
    /// by no live project and no annex placed before it (projects by slot, then part). Annex slots are not
    /// persisted: a new project can move an annex (décision 7). Two agents on one desk (never in a valid
    /// workspace): the lowest id sits. Input decor keeps its world tile; an item outside the bounds, or anchored to
    /// an island that is not live, is left out. The result does not depend on the order of the input arrays.
    public static func compute(_ input: WorldInput) -> WorldLayoutResult {
        let config = input.config
        let perIsland = max(1, config.desksPerIsland)
        let live = input.projects.filter { !$0.archived && $0.slot >= 0 }
            .sorted { ($0.slot, $0.id) < ($1.slot, $1.id) }
        let liveIDs = Set(live.map(\.id))

        // deskIndex → agent, per live project.
        var seats: [ProjectID: [Int: AgentID]] = [:]
        for agent in input.agents where agent.deskIndex >= 0 && liveIDs.contains(agent.projectID) {
            if let seated = seats[agent.projectID]?[agent.deskIndex], seated < agent.id { continue }
            seats[agent.projectID, default: [:]][agent.deskIndex] = agent.id
        }

        var usedSlots = Set(live.map(\.slot))
        var nextFree = 0
        var islands: [IslandPlacement] = []
        for project in live {
            // local index → agent, per part.
            var parts: [Int: [Int: AgentID]] = [:]
            for (index, agentID) in seats[project.id] ?? [:] {
                parts[index / perIsland, default: [:]][index % perIsland] = agentID
            }
            let highestPart = parts.keys.max() ?? 0
            var previousFull = false
            for part in 0...(highestPart + 1) {
                let locals = parts[part] ?? [:]
                defer { previousFull = locals.count >= perIsland }
                guard part == 0 || !locals.isEmpty || previousFull else { continue }
                let slot: Int
                if part == 0 {
                    slot = project.slot
                } else {
                    while usedSlots.contains(nextFree) { nextFree += 1 }
                    slot = nextFree
                    usedSlots.insert(slot)
                }
                islands.append(island(project: project.id, part: part, slot: slot, locals: locals, config: config))
            }
        }
        islands.sort { ($0.slot, $0.part) < ($1.slot, $1.part) }

        // Bounding box of the used slots, from the hall corner; at least one slot.
        var columns = 1
        var rows = 1
        for island in islands {
            let (column, row) = slotCoordinates(island.slot)
            columns = max(columns, column + 1)
            rows = max(rows, row + 1)
        }
        let pitch = config.slotPitch
        let bounds = GridRect(origin: GridPoint(0, 0),
                              size: GridSize(w: pitch.w * columns, d: config.hallDepth + pitch.d * rows))
        var corridors: [GridRect] = []
        for row in 0..<rows {
            for column in 0..<columns { corridors.append(slotRect(column: column, row: row, config: config)) }
        }

        let hall = GridRect(origin: GridPoint(0, 0), size: GridSize(w: bounds.size.w, d: config.hallDepth))
        var props = hallProps
        for item in input.decor where bounds.contains(item.tile) {
            if case .island(let projectID) = item.anchor, !liveIDs.contains(projectID) { continue }
            props.append(PropPlacement(kind: item.kind, tile: item.tile, facing: item.facing, anchor: item.anchor))
        }
        props.sort(by: propOrder)

        var walls = [WallPlacement(wall: nil, start: 0, span: 1, piece: .corner)]
        walls += wallPieces(.ne, length: bounds.size.w)
        walls += wallPieces(.nw, length: bounds.size.d)

        return WorldLayoutResult(
            islands: islands, props: props, walls: walls, corridors: corridors, bounds: bounds, hall: hall,
            boardWall: GridRect(origin: GridPoint(boardStart, 0), size: GridSize(w: boardSpan, d: 1)),
            elevator: GridRect(origin: GridPoint(0, elevatorStart), size: GridSize(w: 1, d: elevatorSpan)))
    }

    /// Square shells: (0,0) (1,0) (0,1) (1,1) (2,0) (2,1) (0,2) (1,2) (2,2) (3,0)…: shell s lists (s, 0)…(s, s − 1),
    /// then (0, s)…(s, s). Independent of the number of projects. Precondition: slot ≥ 0.
    public static func slotCoordinates(_ slot: Int) -> (column: Int, row: Int) {
        precondition(slot >= 0, "negative slot")
        // Integer square root (the correctly rounded Double root, then corrected).
        var shell = Int(Double(slot).squareRoot())
        while shell * shell > slot { shell -= 1 }
        while (shell + 1) * (shell + 1) <= slot { shell += 1 }
        let k = slot - shell * shell
        return k < shell ? (column: shell, row: k) : (column: k - shell, row: shell)
    }

    /// 4·⌈(max(agents, highestLocalIndex + 1) + 1) / 4⌉, at most `maximum` (desksPerIsland): 4 for 0 to 3 agents,
    /// 8 for 4 to 7. There is always a free desk while the island is not full.
    public static func capacity(agents: Int, highestLocalIndex: Int?,
                                maximum: Int = LayoutConfig.standard.desksPerIsland) -> Int {
        let needed = max(agents, (highestLocalIndex ?? -1) + 1) + 1
        return min(4 * ((needed + 3) / 4), maximum)
    }

    /// (2·⌈capacity / 2⌉ + 2) × 7: sign and border included, 6×7 for 4 desks, 10×7 for 8.
    public static func islandSize(capacity: Int) -> GridSize {
        GridSize(w: 2 * ((capacity + 1) / 2) + 2, d: islandDepth)
    }

    /// The desks on the rug (décision 3 of the first render): every occupied desk and at least one free desk, by
    /// whole posts (a post is the desk of row A and the desk of row B at the same i): 2·⌈max(agents + 1,
    /// highestLocalIndex + 1) / 2⌉, at most the capacity. With desks 0, 1, … filled in order: 2 desks for 0 or 1
    /// agent, 4 for 2 or 3, 6 for 4 or 5, 8 for 6 and 7. The rug grows by one post every second agent instead of
    /// jumping from 4 to 8 desks, and never shrinks while agents arrive.
    public static func rugDesks(agents: Int, highestLocalIndex: Int?,
                                maximum: Int = LayoutConfig.standard.desksPerIsland) -> Int {
        let needed = max(agents + 1, (highestLocalIndex ?? -1) + 1)
        let capacity = capacity(agents: agents, highestLocalIndex: highestLocalIndex, maximum: maximum)
        return min(2 * ((needed + 1) / 2), capacity)
    }

    /// Even local index → row A, odd → row B; post = index / 2. Independent of the capacity.
    public static func deskLocal(_ localIndex: Int) -> (row: IslandRow, post: Int) {
        (row: localIndex % 2 == 0 ? .a : .b, post: localIndex / 2)
    }

    // MARK: - Pieces

    /// The tiles of a slot: (pitch.w·column, hallDepth + pitch.d·row), pitch.w × pitch.d.
    static func slotRect(column: Int, row: Int, config: LayoutConfig) -> GridRect {
        GridRect(origin: GridPoint(config.slotPitch.w * column, config.hallDepth + config.slotPitch.d * row),
                 size: config.slotPitch)
    }

    /// Local geometry (origin of the island, W = 2·⌈capacity / 2⌉ + 2, D = 7): back row j = 0 (bare, a corridor
    /// between the islands), row B aisle j = 1, row B seats j = 2 and desks j = 3, row A desks j = 4 and seats
    /// j = 5, front border j = 6. Post n has its desk at i = 1 + 2n and its free side tile at i = 2 + 2n, on the
    /// desk's row. The rug is the desks on it plus a one-tile margin: from (0, 1), 2·⌈rugDesks / 2⌉ + 2 wide and 6
    /// deep. The sign stands on its front-left corner (0, 6), away from every overlay (in the back corner the
    /// overlays of desk B0 covered it), the plant on its back-right corner (rug W − 1, 1).
    static func island(project: ProjectID, part: Int, slot: Int, locals: [Int: AgentID],
                       config: LayoutConfig) -> IslandPlacement {
        let perIsland = max(1, config.desksPerIsland)
        let highest = locals.keys.max()
        let capacity = WorldLayout.capacity(agents: locals.count, highestLocalIndex: highest, maximum: perIsland)
        let shown = rugDesks(agents: locals.count, highestLocalIndex: highest, maximum: perIsland)
        let size = islandSize(capacity: capacity)
        let (column, row) = slotCoordinates(slot)
        let origin = slotRect(column: column, row: row, config: config).origin + config.islandInset
        let rug = GridRect(origin: origin + GridPoint(0, 1),
                           size: GridSize(w: islandSize(capacity: shown).w, d: islandDepth - 1))
        let desks = (0..<shown).map { local -> DeskPlacement in
            let (deskRow, post) = deskLocal(local)
            let i = 1 + 2 * post
            let deskJ = deskRow == .a ? 4 : 3
            let seatJ = deskRow == .a ? 5 : 2
            return DeskPlacement(index: part * perIsland + local, row: deskRow, post: post,
                                 deskTile: origin + GridPoint(i, deskJ), seatTile: origin + GridPoint(i, seatJ),
                                 sideTile: origin + GridPoint(i + 1, deskJ), facing: deskRow == .a ? .ne : .sw,
                                 agentID: locals[local])
        }
        return IslandPlacement(projectID: project, part: part, slot: slot, origin: origin, size: size,
                               capacity: capacity, rug: rug, sign: origin + GridPoint(0, islandDepth - 1),
                               plant: rug.origin + GridPoint(rug.size.w - 1, 0), desks: desks)
    }

    /// One back wall, tile by tile from the corner: the cork wall (`ne`) and the elevator (`nw`) on their tiles,
    /// a window wherever start % 3 == 2, segments elsewhere.
    static func wallPieces(_ side: WallSide, length: Int) -> [WallPlacement] {
        var pieces: [WallPlacement] = []
        var start = 0
        while start < length {
            if side == .ne, start == boardStart, start + boardSpan <= length {
                pieces.append(WallPlacement(wall: side, start: start, span: boardSpan, piece: .board))
                start += boardSpan
                continue
            }
            if side == .nw, start == elevatorStart, start + elevatorSpan <= length {
                pieces.append(WallPlacement(wall: side, start: start, span: elevatorSpan, piece: .elevator))
                start += elevatorSpan
                continue
            }
            let piece: WallPiece = start % 3 == 2 ? .window : .segment(segmentStyle(start: start))
            pieces.append(WallPlacement(wall: side, start: start, span: 1, piece: piece))
            start += 1
        }
        return pieces
    }

    /// A six-tile rhythm along each wall, from the corner: plain, plain, (window), baseboard, socket, (window).
    /// Depends only on the tile, so a wall that grows keeps its pieces.
    static func segmentStyle(start: Int) -> WallSegmentStyle {
        switch start % 6 {
        case 3: return .baseboard
        case 4: return .socket
        default: return .plain
        }
    }

    /// By tile (j, then i), kind, facing, then anchor (hall first, then islands by project id).
    static func propOrder(_ a: PropPlacement, _ b: PropPlacement) -> Bool {
        if a.tile != b.tile { return a.tile < b.tile }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        if a.facing != b.facing { return a.facing.rawValue < b.facing.rawValue }
        return anchorKey(a.anchor) < anchorKey(b.anchor)
    }

    static func anchorKey(_ anchor: DecorAnchor) -> String {
        switch anchor {
        case .hall: return ""
        case .island(let id): return "island " + id.description
        }
    }
}
