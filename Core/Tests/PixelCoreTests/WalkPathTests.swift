import Foundation
import Testing
@testable import PixelCore

/// `WalkPath`: the way from the elevator to a seat, and back (arrival and departure, task 11).
@Suite struct WalkPathTests {
    static let overview = Showcase.overview().layout

    static let neighbours = [GridPoint(1, 0), GridPoint(0, 1), GridPoint(-1, 0), GridPoint(0, -1)]

    /// Reference: plain breadth-first distances from `from`, through unblocked tiles of the bounds (`to` may be
    /// blocked). Shares no code with `WalkPath.route`.
    static func referenceDistance(from: GridPoint, to: GridPoint, layout: WorldLayoutResult) -> Int? {
        let blocked = WalkPath.blockedTiles(layout)
        var distance: [GridPoint: Int] = [from: 0]
        var frontier = [from]
        while !frontier.isEmpty {
            var next: [GridPoint] = []
            for tile in frontier {
                if tile == to { return distance[tile] }
                for step in neighbours {
                    let n = tile + step
                    guard layout.bounds.contains(n), distance[n] == nil, n == to || !blocked.contains(n) else { continue }
                    distance[n] = distance[tile]! + 1
                    next.append(n)
                }
            }
            frontier = next
        }
        return nil
    }

    static func seats(_ layout: WorldLayoutResult) -> [GridPoint] {
        layout.islands.flatMap(\.desks).map(\.seatTile)
    }

    @Test func doorIsInFrontOfTheElevator() {
        #expect(WalkPath.door(Self.overview) == Self.overview.elevator.origin)
        #expect(WalkPath.door(Self.overview) == GridPoint(0, 2))
        #expect(!WalkPath.blockedTiles(Self.overview).contains(WalkPath.door(Self.overview)))
    }

    @Test func blockedTilesAreTheFurniture() {
        let layout = Self.overview
        let blocked = WalkPath.blockedTiles(layout)
        for island in layout.islands {
            #expect(blocked.contains(island.sign) && blocked.contains(island.plant))
            for desk in island.desks {
                #expect(blocked.contains(desk.deskTile) && blocked.contains(desk.seatTile))
                // The free tile beside the desk only holds the minis and the lamp's light.
                #expect(!blocked.contains(desk.sideTile))
            }
        }
        for prop in layout.props { #expect(blocked.contains(prop.tile)) }
        var expected = Set(layout.props.map(\.tile))
        for island in layout.islands {
            expected.formUnion([island.sign, island.plant])
            for desk in island.desks { expected.formUnion([desk.deskTile, desk.seatTile]) }
        }
        #expect(blocked == expected)
        // A rug decor lies on the floor: walkable, unlike every other prop.
        let decor = [
            DecorItem(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, kind: .rug, tile: GridPoint(4, 3),
                      facing: .se, anchor: .hall),
            DecorItem(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!, kind: .sofa, tile: GridPoint(5, 3),
                      facing: .sw, anchor: .hall),
        ]
        let furnished = WalkPath.blockedTiles(WorldLayout.compute(WorldInput(projects: [], agents: [], decor: decor)))
        #expect(!furnished.contains(GridPoint(4, 3)) && furnished.contains(GridPoint(5, 3)))
    }

    @Test func everySeatOfTheOverviewIsReachedFromTheDoor() {
        let layout = Self.overview
        let door = WalkPath.door(layout)
        let blocked = WalkPath.blockedTiles(layout)
        let seats = Self.seats(layout)
        #expect(seats.count >= 20)
        for seat in seats {
            guard let path = WalkPath.route(from: door, to: seat, layout: layout) else {
                Issue.record("seat \(seat) not reached")
                continue
            }
            #expect(path.first == door && path.last == seat)
            // Contiguous: one 4-neighbour step at a time, inside the bounds.
            for (a, b) in zip(path, path.dropFirst()) {
                #expect(Self.neighbours.contains(b - a), "\(a) → \(b)")
            }
            #expect(path.allSatisfy { layout.bounds.contains($0) })
            // Never through furniture: only the seat itself is blocked.
            #expect(path.dropLast().allSatisfy { !blocked.contains($0) }, "seat \(seat)")
            // Shortest, and never twice on a tile.
            #expect(path.count - 1 == Self.referenceDistance(from: door, to: seat, layout: layout), "seat \(seat)")
            #expect(Set(path).count == path.count)
        }
    }

    /// Generated workspaces (annexes included, up to 20 agents per project): every seat is reached from the door, by
    /// a shortest path.
    @Test func everySeatOfGeneratedWorldsIsReached() {
        for history in WorldLayoutPropertyTests.histories.enumerated().filter({ $0.offset % 10 == 0 }).map(\.element) {
            let layout = WorldLayout.compute(WorldInput(workspace: history.last!))
            let door = WalkPath.door(layout)
            for seat in Self.seats(layout) {
                let path = WalkPath.route(from: door, to: seat, layout: layout)
                #expect(path.map { $0.count - 1 } == Self.referenceDistance(from: door, to: seat, layout: layout))
                #expect(path != nil, "seat \(seat)")
            }
        }
    }

    /// The way back: from a seat to the door, through the same rules.
    @Test func everySeatLeadsBackToTheDoor() {
        let layout = Self.overview
        let door = WalkPath.door(layout)
        let blocked = WalkPath.blockedTiles(layout)
        for seat in Self.seats(layout) {
            let path = WalkPath.route(from: seat, to: door, layout: layout)
            #expect(path?.first == seat && path?.last == door)
            #expect(path.map { $0.dropFirst().allSatisfy { !blocked.contains($0) } } == true)
            #expect(path.map { $0.count - 1 } == Self.referenceDistance(from: seat, to: door, layout: layout))
        }
    }

    @Test func deterministicAndTriesNeighboursInOrder() {
        let layout = Self.overview
        let door = WalkPath.door(layout)
        for seat in Self.seats(layout) {
            #expect(WalkPath.route(from: door, to: seat, layout: layout) == WalkPath.route(from: door, to: seat, layout: layout))
        }
        // In the open hall, +i is tried first: the path goes along i, then along j.
        let path = WalkPath.route(from: GridPoint(1, 2), to: GridPoint(3, 4), layout: layout)
        #expect(path == [GridPoint(1, 2), GridPoint(2, 2), GridPoint(3, 2), GridPoint(3, 3), GridPoint(3, 4)])
        // Same tile: a path of one tile.
        #expect(WalkPath.route(from: door, to: door, layout: layout) == [door])
    }

    @Test func unreachableGivesNil() {
        let layout = Self.overview
        let door = WalkPath.door(layout)
        // Outside the floor.
        #expect(WalkPath.route(from: door, to: GridPoint(-1, 2), layout: layout) == nil)
        #expect(WalkPath.route(from: door, to: GridPoint(layout.bounds.end.i, 3), layout: layout) == nil)
        #expect(WalkPath.route(from: GridPoint(0, -1), to: door, layout: layout) == nil)
        // A hall tile walled in by four cacti.
        let ring = [GridPoint(3, 3), GridPoint(5, 3), GridPoint(4, 2), GridPoint(4, 4)].enumerated().map { k, tile in
            DecorItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000C%d", k))!, kind: .cactus,
                      tile: tile, facing: .sw, anchor: .hall)
        }
        let walled = WorldLayout.compute(WorldInput(projects: [], agents: [], decor: ring))
        #expect(WalkPath.route(from: WalkPath.door(walled), to: GridPoint(4, 3), layout: walled) == nil)
        #expect(Self.referenceDistance(from: WalkPath.door(walled), to: GridPoint(4, 3), layout: walled) == nil)
        // Its neighbour outside the ring is still reached.
        #expect(WalkPath.route(from: WalkPath.door(walled), to: GridPoint(6, 3), layout: walled) != nil)
    }
}
