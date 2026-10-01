import Foundation
import Testing
@testable import PixelCore

@Suite struct WorldLayoutTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_845_200)

    static func projectID(_ n: Int) -> ProjectID {
        ProjectID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!)
    }

    static func agentID(project p: Int, desk d: Int) -> AgentID {
        AgentID(UUID(uuidString: String(format: "00000000-0000-0000-%04X-%012X", p, d))!)
    }

    static func project(_ n: Int, slot: Int, archived: Bool = false) -> Project {
        Project(id: projectID(n), name: "P\(n)", path: "/p/\(n)", hueIndex: n % 10, order: n, slot: slot,
                createdAt: t0, archived: archived)
    }

    static func agents(project p: Int, desks: [Int]) -> [Agent] {
        desks.map { Agent(id: agentID(project: p, desk: $0), projectID: projectID(p), name: "A\(p)-\($0)",
                          deskIndex: $0, createdAt: t0) }
    }

    /// `count` projects in slots 0..<count, each with `agents` agents at desks 0..<agents.
    static func world(projects count: Int, agents: Int = 0) -> WorldInput {
        let projects = (0..<count).map { project($0, slot: $0) }
        let all = (0..<count).flatMap { Self.agents(project: $0, desks: Array(0..<agents)) }
        return WorldInput(projects: projects, agents: all)
    }

    static func layout(_ projects: [Project], _ agents: [Agent] = [], decor: [DecorItem] = []) -> WorldLayoutResult {
        WorldLayout.compute(WorldInput(projects: projects, agents: agents, decor: decor))
    }

    static func rect(_ i: Int, _ j: Int, _ w: Int, _ d: Int) -> GridRect {
        GridRect(origin: GridPoint(i, j), size: GridSize(w: w, d: d))
    }

    // MARK: - Slots, capacity, size

    @Test func slotOrder() {
        let first = (0..<10).map { WorldLayout.slotCoordinates($0) }
        let expected = [(0, 0), (1, 0), (0, 1), (1, 1), (2, 0), (2, 1), (0, 2), (1, 2), (2, 2), (3, 0)]
        #expect(first.map { $0.column } == expected.map { $0.0 })
        #expect(first.map { $0.row } == expected.map { $0.1 })
        // Square shells: every cell of an n×n square is used once by the first n² slots.
        for n in 1...9 {
            let cells = (0..<(n * n)).map { WorldLayout.slotCoordinates($0) }
            #expect(Set(cells.map { $0.column * 100 + $0.row }).count == n * n)
            #expect(cells.allSatisfy { $0.column < n && $0.row < n })
        }
    }

    @Test func capacityAndIslandSize() {
        for agents in 0...3 { #expect(WorldLayout.capacity(agents: agents, highestLocalIndex: agents == 0 ? nil : agents - 1) == 4) }
        for agents in 4...7 { #expect(WorldLayout.capacity(agents: agents, highestLocalIndex: agents - 1) == 8) }
        // A gap in the desks: local index 6 with 3 agents needs the 8-desk island.
        #expect(WorldLayout.capacity(agents: 3, highestLocalIndex: 6) == 8)
        #expect(WorldLayout.capacity(agents: 1, highestLocalIndex: 3) == 8)
        #expect(WorldLayout.capacity(agents: 2, highestLocalIndex: 2) == 4)
        // Never more than 8 desks: the eighth agent fills the island and opens an annex.
        #expect(WorldLayout.capacity(agents: 8, highestLocalIndex: 7) == 8)
        #expect(WorldLayout.islandSize(capacity: 4) == GridSize(w: 6, d: 7))
        #expect(WorldLayout.islandSize(capacity: 8) == GridSize(w: 10, d: 7))

        for (agents, capacity, width) in [(0, 4, 6), (3, 4, 6), (4, 8, 10), (7, 8, 10)] {
            let island = WorldLayout.compute(Self.world(projects: 1, agents: agents)).islands[0]
            #expect(island.capacity == capacity, "\(agents) agents")
            #expect(island.size == GridSize(w: width, d: 7), "\(agents) agents")
            #expect(island.rect == GridRect(origin: island.origin, size: island.size))
        }
        let gap = Self.layout([Self.project(0, slot: 0)], Self.agents(project: 0, desks: [0, 1, 6])).islands[0]
        #expect(gap.capacity == 8)
    }

    @Test func rugFitsTheAgents() {
        // Desks filled in order: one post (2 desks) more every second agent, the next free desk always on the rug.
        let shown = (0...8).map { WorldLayout.rugDesks(agents: $0, highestLocalIndex: $0 == 0 ? nil : $0 - 1) }
        #expect(shown == [2, 2, 4, 4, 6, 6, 8, 8, 8])
        // Gaps: the highest desk sets the rug; a free gap counts as the free desk.
        #expect(WorldLayout.rugDesks(agents: 1, highestLocalIndex: 1) == 2)
        #expect(WorldLayout.rugDesks(agents: 3, highestLocalIndex: 6) == 8)
        #expect(WorldLayout.rugDesks(agents: 2, highestLocalIndex: 4) == 6)
        // Never past the capacity of the configuration.
        #expect(WorldLayout.rugDesks(agents: 4, highestLocalIndex: 3, maximum: 4) == 4)

        for (agents, desks, width) in [(0, 2, 4), (1, 2, 4), (2, 4, 6), (3, 4, 6), (4, 6, 8), (5, 6, 8), (6, 8, 10), (7, 8, 10)] {
            let island = WorldLayout.compute(Self.world(projects: 1, agents: agents)).islands[0]
            #expect(island.desks.map(\.index) == Array(0..<desks), "\(agents) agents")
            // The desks plus a one-tile margin: from the aisle (local j = 1) to the front border (j = 6).
            #expect(island.rug == GridRect(origin: island.origin + GridPoint(0, 1), size: GridSize(w: width, d: 6)),
                    "\(agents) agents")
            #expect(island.rect.contains(island.rug))
            #expect(island.plant == island.origin + GridPoint(width - 1, 1))
            #expect(island.sign == island.origin + GridPoint(0, 6))
        }
    }

    @Test func footprintTable() {
        #expect(WorldLayout.compute(Self.world(projects: 0)).bounds == Self.rect(0, 0, 12, 15))
        for (projects, w, d) in [(1, 12, 15), (3, 24, 24), (5, 36, 24), (6, 36, 24), (8, 36, 33)] {
            for agents in [0, 7] {
                let result = WorldLayout.compute(Self.world(projects: projects, agents: agents))
                #expect(result.bounds == Self.rect(0, 0, w, d), "\(projects) projects, \(agents) agents")
            }
        }
        // The bounding box of the used slots, from the hall corner, even with free slots inside.
        let sparse = Self.layout([Self.project(0, slot: 4)])
        #expect(sparse.bounds == Self.rect(0, 0, 36, 15))
        // Every slot of the bounding box is painted as corridor, row-major.
        let corridors = WorldLayout.compute(Self.world(projects: 3)).corridors
        #expect(corridors == [Self.rect(0, 6, 12, 9), Self.rect(12, 6, 12, 9), Self.rect(0, 15, 12, 9),
                              Self.rect(12, 15, 12, 9)])
    }

    // MARK: - Islands and desks

    @Test func deskGeometry() {
        for (local, row, post) in [(0, IslandRow.a, 0), (1, .b, 0), (2, .a, 1), (6, .a, 3), (7, .b, 3)] {
            let place = WorldLayout.deskLocal(local)
            #expect(place.row == row && place.post == post, "local \(local)")
        }

        let agents = Self.agents(project: 0, desks: [0, 1, 2])
        let island = Self.layout([Self.project(0, slot: 0)], agents).islands[0]
        #expect(island.projectID == Self.projectID(0))
        #expect(island.part == 0 && island.slot == 0)
        // Slot 0 starts at (0, 6), below the hall; the island is inset by (1, 1).
        #expect(island.origin == GridPoint(1, 7))
        #expect(island.sign == GridPoint(1, 13))
        #expect(island.plant == GridPoint(6, 8))
        #expect(island.rug == Self.rect(1, 8, 6, 6))
        let expected = [
            DeskPlacement(index: 0, row: .a, post: 0, deskTile: GridPoint(2, 11), seatTile: GridPoint(2, 12),
                          sideTile: GridPoint(3, 11), facing: .ne, agentID: agents[0].id),
            DeskPlacement(index: 1, row: .b, post: 0, deskTile: GridPoint(2, 10), seatTile: GridPoint(2, 9),
                          sideTile: GridPoint(3, 10), facing: .sw, agentID: agents[1].id),
            DeskPlacement(index: 2, row: .a, post: 1, deskTile: GridPoint(4, 11), seatTile: GridPoint(4, 12),
                          sideTile: GridPoint(5, 11), facing: .ne, agentID: agents[2].id),
            // The free desk is listed too.
            DeskPlacement(index: 3, row: .b, post: 1, deskTile: GridPoint(4, 10), seatTile: GridPoint(4, 9),
                          sideTile: GridPoint(5, 10), facing: .sw, agentID: nil),
        ]
        #expect(island.desks == expected)

        // Slot 4 is column 2, row 0.
        let other = Self.layout([Self.project(0, slot: 4)]).islands[0]
        #expect(other.origin == GridPoint(25, 7))
        #expect(other.desks[0].deskTile == GridPoint(26, 11))
    }

    @Test func islandGrowsInPlace() {
        let projects = [Self.project(0, slot: 1), Self.project(1, slot: 0)]
        let three = Self.layout(projects, Self.agents(project: 0, desks: [0, 1, 2]))
        let four = Self.layout(projects, Self.agents(project: 0, desks: [0, 1, 2, 3]))
        let small = three.islands.first { $0.projectID == Self.projectID(0) }!
        let big = four.islands.first { $0.projectID == Self.projectID(0) }!
        #expect(small.origin == big.origin)
        #expect(small.size.w == 6 && big.size.w == 10)
        #expect(small.capacity == 4 && big.capacity == 8)
        // The rug grows by one post (the fifth desk is free), from the same corner; the sign stays.
        #expect(small.rug == GridRect(origin: small.origin + GridPoint(0, 1), size: GridSize(w: 6, d: 6)))
        #expect(big.rug == GridRect(origin: small.origin + GridPoint(0, 1), size: GridSize(w: 8, d: 6)))
        #expect(small.sign == big.sign)
        #expect(small.plant == small.origin + GridPoint(5, 1) && big.plant == small.origin + GridPoint(7, 1))
        #expect(small.desks.count == 4 && big.desks.count == 6)
        for d in 0..<4 {
            var before = small.desks[d]
            let after = big.desks[d]
            before.agentID = after.agentID
            #expect(before == after, "desk \(d)")
        }
        // The neighbour did not move either.
        #expect(three.islands.first { $0.projectID == Self.projectID(1) }
                == four.islands.first { $0.projectID == Self.projectID(1) })
    }

    @Test func annexAfterSevenAgents() {
        let seven = Self.layout([Self.project(0, slot: 0)], Self.agents(project: 0, desks: Array(0..<7)))
        #expect(seven.islands.count == 1)

        // Eight agents fill the 8-desk island: an empty annex opens in the first slot no live project uses.
        let projects = [Self.project(0, slot: 0), Self.project(1, slot: 1)]
        let full = Self.layout(projects, Self.agents(project: 0, desks: Array(0..<8)))
        #expect(full.islands.map(\.slot) == [0, 1, 2])
        #expect(full.islands.map(\.part) == [0, 0, 1])
        let annex = full.islands[2]
        #expect(annex.projectID == Self.projectID(0))
        #expect(annex.capacity == 4 && annex.size == GridSize(w: 6, d: 7))
        #expect(annex.origin == GridPoint(1, 16))
        // An empty annex shows one post on a small rug.
        #expect(annex.desks.map(\.index) == [8, 9])
        #expect(annex.rug == GridRect(origin: GridPoint(1, 17), size: GridSize(w: 4, d: 6)))
        #expect(annex.desks.allSatisfy { $0.agentID == nil })
        #expect(annex.desks[0].deskTile == GridPoint(2, 20))
        #expect(full.bounds == Self.rect(0, 0, 24, 24))

        // An agent at desk 9 sits in the annex, row B, post 0.
        let ninth = Self.layout([Self.project(0, slot: 0)], Self.agents(project: 0, desks: [0, 9]))
        #expect(ninth.islands.map(\.slot) == [0, 1])
        let desk = ninth.islands[1].desks.first { $0.agentID == Self.agentID(project: 0, desk: 9) }!
        #expect(desk.index == 9 && desk.row == .b && desk.post == 0 && desk.facing == .sw)

        // Annexes skip the slots of live projects and take the lowest free ones, projects by slot, then part.
        let crowded = Self.layout([Self.project(0, slot: 0), Self.project(1, slot: 1), Self.project(2, slot: 3)],
                                  Self.agents(project: 0, desks: Array(0..<8)) + Self.agents(project: 2, desks: [0, 8, 16]))
        let annexes = crowded.islands.filter { $0.part > 0 }.map { "\($0.projectID == Self.projectID(0) ? 0 : 2).\($0.part)@\($0.slot)" }
        #expect(annexes.sorted() == ["0.1@2", "2.1@4", "2.2@5"])
        #expect(crowded.islands.map(\.slot) == [0, 1, 2, 3, 4, 5])
    }

    /// `Project.annexSlots` (workspace v2): part p sits in `annexSlots[p − 1]`, kept for life; a part without a
    /// persisted slot (an older or repaired file) takes the lowest slot no live project and no annex holds.
    @Test func annexUsesItsPersistedSlot() {
        var api = Self.project(0, slot: 0)
        api.annexSlots = [3, 5]
        let site = Self.project(1, slot: 1)
        let agents = Self.agents(project: 0, desks: Array(0..<9))
        let result = Self.layout([api, site], agents)
        #expect(result.islands.map { "\($0.part)@\($0.slot)" } == ["0@0", "0@1", "1@3"])
        // Part 2 has no agent and part 1 is not full: its slot stays reserved but shows nothing.
        #expect(result.bounds == Self.rect(0, 0, 24, 24))

        // Full annex: part 2 opens in its own slot.
        let full = Self.layout([api, site], Self.agents(project: 0, desks: Array(0..<16)))
        #expect(full.islands.map { "\($0.part)@\($0.slot)" } == ["0@0", "0@1", "1@3", "2@5"])
        let annex = full.islands.first { $0.part == 1 }!
        #expect(annex.origin == GridPoint(13, 16))
        #expect(annex.desks.map(\.index) == Array(8..<16))

        // No persisted slot for part 2: the lowest slot that no live project and no annex holds (2), not 3 or 5.
        api.annexSlots = [3]
        var other = Self.project(2, slot: 4)
        other.annexSlots = [5]
        let fallback = Self.layout([api, site, other], Self.agents(project: 0, desks: Array(0..<16))
                                   + Self.agents(project: 2, desks: [8]))
        #expect(fallback.islands.map { "\($0.slot):\($0.projectID == Self.projectID(0) ? 0 : $0.projectID == Self.projectID(1) ? 1 : 2).\($0.part)" }
                == ["0:0.0", "1:1.0", "2:0.2", "3:0.1", "4:2.0", "5:2.1"])

        // A persisted slot that a live project holds (never in a validated workspace) is ignored, as is a negative
        // one or one an annex placed before it already took: those parts fall back.
        api.annexSlots = [1, -2]
        other.annexSlots = [3]
        var third = Self.project(3, slot: 6)
        third.annexSlots = [3]
        let broken = Self.layout([api, site, other, third],
                                 Self.agents(project: 0, desks: [0, 8, 16]) + Self.agents(project: 2, desks: [8])
                                 + Self.agents(project: 3, desks: [8]))
        let slots = broken.islands.map(\.slot)
        #expect(Set(slots).count == slots.count)
        #expect(broken.islands.filter { $0.projectID == Self.projectID(2) }.map(\.slot) == [3, 4])
        #expect(broken.islands.filter { $0.projectID == Self.projectID(0) }.map(\.slot) == [0, 2, 5])
        #expect(broken.islands.filter { $0.projectID == Self.projectID(3) }.map(\.slot) == [6, 7])
        // An archived project's annex slots are free.
        var archived = Self.project(4, slot: 8, archived: true)
        archived.annexSlots = [2]
        let withArchived = Self.layout([api, site, other, third, archived],
                                       Self.agents(project: 0, desks: [0, 8, 16]) + Self.agents(project: 2, desks: [8])
                                       + Self.agents(project: 3, desks: [8]))
        #expect(withArchived == broken)
    }

    @Test func archivedProjectHasNoIsland() {
        let projects = [Self.project(0, slot: 0, archived: true), Self.project(1, slot: 1)]
        let agents = Self.agents(project: 0, desks: [0, 1]) + Self.agents(project: 1, desks: [0])
        let decor = [DecorItem(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, kind: .cactus,
                               tile: GridPoint(15, 8), facing: .sw, anchor: .island(Self.projectID(0)))]
        let result = Self.layout(projects, agents, decor: decor)
        #expect(result.islands.map(\.projectID) == [Self.projectID(1)])
        let seated = result.islands.flatMap(\.desks).compactMap(\.agentID)
        #expect(seated == [Self.agentID(project: 1, desk: 0)])
        // Decor of an archived island goes with it; the archived slot no longer counts in the bounds.
        #expect(!result.props.contains { $0.kind == .cactus })
        #expect(result.bounds == Self.rect(0, 0, 24, 15))
        // An agent of an unknown project has no desk either.
        let stray = Agent(id: Self.agentID(project: 9, desk: 0), projectID: Self.projectID(9), name: "X", deskIndex: 0,
                          createdAt: Self.t0)
        #expect(Self.layout([Self.project(1, slot: 0)], [stray]).islands[0].desks.allSatisfy { $0.agentID == nil })
    }

    // MARK: - Hall and walls

    @Test func hallIsFixed() {
        let hallProps = [
            PropPlacement(kind: .coffeeMachine, tile: GridPoint(8, 1), facing: .sw, anchor: .hall),
            PropPlacement(kind: .plantSmall, tile: GridPoint(10, 1), facing: .sw, anchor: .hall),
        ]
        for projects in [0, 1, 3, 6, 8] {
            let result = WorldLayout.compute(Self.world(projects: projects, agents: 5))
            #expect(result.hall == Self.rect(0, 0, result.bounds.size.w, 6))
            #expect(result.boardWall == Self.rect(1, 0, 6, 1))
            #expect(result.elevator == Self.rect(0, 2, 1, 2))
            #expect(result.props == hallProps)
            #expect(result.islands.allSatisfy { !$0.rect.intersects(result.hall) })
        }
    }

    @Test func wallsFollowBounds() {
        for projects in [1, 8] {
            let result = WorldLayout.compute(Self.world(projects: projects))
            let w = result.bounds.size.w
            let d = result.bounds.size.d
            #expect(result.walls.first == WallPlacement(wall: nil, start: 0, span: 1, piece: .corner))
            #expect(result.walls.filter { $0.piece == .corner }.count == 1)
            for side in WallSide.allCases {
                let pieces = result.walls.filter { $0.wall == side }
                let length = side == .ne ? w : d
                // Contiguous, sorted, no gap and no overlap, exactly the back edge: no wall on the front edges.
                var next = 0
                for piece in pieces {
                    #expect(piece.start == next, "\(side) at \(piece.start)")
                    next = piece.start + piece.span
                }
                #expect(next == length, "\(side)")
                for piece in pieces {
                    switch piece.piece {
                    case .board:
                        #expect(side == .ne && piece.start == 1 && piece.span == 6)
                    case .elevator:
                        #expect(side == .nw && piece.start == 2 && piece.span == 2)
                    case .window:
                        #expect(piece.span == 1 && piece.start % 3 == 2)
                    case .segment:
                        #expect(piece.span == 1 && piece.start % 3 != 2)
                    case .corner:
                        Issue.record("corner on a wall")
                    }
                }
                #expect(pieces.filter { $0.piece == .board }.count == (side == .ne ? 1 : 0))
                #expect(pieces.filter { $0.piece == .elevator }.count == (side == .nw ? 1 : 0))
            }
            // Corner, then the ne wall by start, then the nw wall by start.
            let order = result.walls.map { $0.wall.map { $0 == .ne ? 1 : 2 } ?? 0 }
            #expect(order == order.sorted())
        }
        let one = WorldLayout.compute(Self.world(projects: 1))
        #expect(one.walls.filter { $0.wall == .ne && $0.piece == .window }.map(\.start) == [8, 11])
        #expect(one.walls.filter { $0.wall == .nw && $0.piece == .window }.map(\.start) == [5, 8, 11, 14])
        // A new row of slots lengthens the side wall by 9 tiles; the pieces already there stay the same.
        let three = WorldLayout.compute(Self.world(projects: 3))
        let nwOne = one.walls.filter { $0.wall == .nw }
        let nwThree = three.walls.filter { $0.wall == .nw }
        #expect(nwThree.count > nwOne.count)
        #expect(Array(nwThree.prefix(nwOne.count)) == nwOne)
        let styles = Set(three.walls.compactMap { if case .segment(let s) = $0.piece { return s } else { return nil } })
        #expect(styles == Set(WallSegmentStyle.allCases))
    }

    // MARK: - Decor and order

    @Test func inputDecorIsKeptSortedAndInsideBounds() {
        let decor = [
            DecorItem(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, kind: .rug,
                      tile: GridPoint(4, 3), facing: .se, anchor: .hall),
            DecorItem(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!, kind: .cactus,
                      tile: GridPoint(11, 13), facing: .sw, anchor: .island(Self.projectID(0))),
            // Outside the floor: dropped.
            DecorItem(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!, kind: .sofa,
                      tile: GridPoint(30, 2), facing: .sw, anchor: .hall),
        ]
        let result = Self.layout([Self.project(0, slot: 0)], decor: decor)
        #expect(result.props == [
            PropPlacement(kind: .coffeeMachine, tile: GridPoint(8, 1), facing: .sw, anchor: .hall),
            PropPlacement(kind: .plantSmall, tile: GridPoint(10, 1), facing: .sw, anchor: .hall),
            PropPlacement(kind: .rug, tile: GridPoint(4, 3), facing: .se, anchor: .hall),
            PropPlacement(kind: .cactus, tile: GridPoint(11, 13), facing: .sw, anchor: .island(Self.projectID(0))),
        ])
    }

    @Test func inputOrderDoesNotMatter() {
        let projects = [Self.project(0, slot: 2), Self.project(1, slot: 0), Self.project(2, slot: 5, archived: true),
                        Self.project(3, slot: 1), Self.project(4, slot: 3)]
        let agents = Self.agents(project: 0, desks: Array(0..<8)) + Self.agents(project: 1, desks: [0, 2, 5])
            + Self.agents(project: 2, desks: [0]) + Self.agents(project: 3, desks: [1, 9]) + Self.agents(project: 4, desks: [])
        let decor = (0..<4).map {
            DecorItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000E%d", $0))!,
                      kind: DecorKind.allCases[$0 + 2], tile: GridPoint(2 + $0, 4), facing: .sw, anchor: .hall)
        }
        let reference = Self.layout(projects, agents, decor: decor)
        var rng = SplitMix64(seed: 7)
        for _ in 0..<20 {
            let shuffled = Self.layout(projects.shuffled(using: &rng), agents.shuffled(using: &rng),
                                       decor: decor.shuffled(using: &rng))
            #expect(shuffled == reference)
        }
        // Sorted outputs.
        let keys = reference.islands.map { [$0.slot, $0.part] }
        #expect(keys == keys.sorted { $0.lexicographicallyPrecedes($1) })
        for island in reference.islands { #expect(island.desks.map(\.index) == island.desks.map(\.index).sorted()) }
    }

    @Test func worldInputFromWorkspace() {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", id: Self.projectID(1), now: Self.t0)
        w.addAgent(to: a, name: "Nova", id: Self.agentID(project: 1, desk: 0), now: Self.t0)
        let input = WorldInput(workspace: w)
        #expect(input.projects == w.projects && input.agents == w.agents && input.decor.isEmpty)
        #expect(input.config == .standard)
        #expect(LayoutConfig.standard == LayoutConfig(slotPitch: GridSize(w: 12, d: 9), hallDepth: 6,
                                                      islandInset: GridPoint(1, 1), desksPerIsland: 8))
        #expect(WorldLayout.compute(input).islands[0].desks[0].agentID == Self.agentID(project: 1, desk: 0))
    }
}
