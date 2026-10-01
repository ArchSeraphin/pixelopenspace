import Foundation

/// The way an avatar walks between the elevator and its seat (arrival and departure, task 11): tile by tile on the
/// floor of the layout, around the furniture. Pure and deterministic.
public enum WalkPath {
    /// The four steps, in the order they are tried: +i, +j, −i, −j.
    static let steps = [GridPoint(1, 0), GridPoint(0, 1), GridPoint(-1, 0), GridPoint(0, -1)]

    /// Floor tile in front of the elevator doors (`layout.elevator.origin`).
    public static func door(_ layout: WorldLayoutResult) -> GridPoint {
        layout.elevator.origin
    }

    /// Desks, seats, signs, island plants, hall props: what nobody walks through. The free tile beside a desk (the
    /// minis, the lamp's light) and the floor are walkable; so is a `.rug` decor, laid on the floor.
    public static func blockedTiles(_ layout: WorldLayoutResult) -> Set<GridPoint> {
        var blocked: Set<GridPoint> = []
        for prop in layout.props where prop.kind != .rug { blocked.insert(prop.tile) }
        for island in layout.islands {
            blocked.insert(island.sign)
            blocked.insert(island.plant)
            for desk in island.desks {
                blocked.insert(desk.deskTile)
                blocked.insert(desk.seatTile)
            }
        }
        return blocked
    }

    /// Shortest 4-neighbour path from `from` to `to`, both included, inside the bounds, through unblocked tiles
    /// (`from` and `to` may be blocked: a seat); neighbours tried in the order +i, +j, −i, −j (breadth first, the
    /// first way found to a tile is kept); nil when unreachable or outside the bounds. `[from]` when they are equal.
    public static func route(from: GridPoint, to: GridPoint, layout: WorldLayoutResult) -> [GridPoint]? {
        let bounds = layout.bounds
        guard bounds.contains(from), bounds.contains(to) else { return nil }
        if from == to { return [from] }
        let blocked = blockedTiles(layout)
        var parent: [GridPoint: GridPoint] = [from: from]
        var frontier = [from]
        var head = 0
        while head < frontier.count {
            let tile = frontier[head]
            head += 1
            for step in steps {
                let next = tile + step
                guard bounds.contains(next), parent[next] == nil, next == to || !blocked.contains(next) else { continue }
                parent[next] = tile
                if next == to {
                    var path = [to]
                    var cursor = tile
                    while cursor != from {
                        path.append(cursor)
                        cursor = parent[cursor]!
                    }
                    path.append(from)
                    return path.reversed()
                }
                frontier.append(next)
            }
        }
        return nil
    }
}
