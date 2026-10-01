import Foundation

/// A tile of the floor grid (3.8): i grows toward the bottom right of the screen, j toward the bottom left.
public struct GridPoint: Hashable, Comparable, Codable, Sendable {
    public var i: Int
    public var j: Int

    public init(_ i: Int, _ j: Int) {
        self.i = i
        self.j = j
    }

    /// Row-major: by j, then by i (the order of `GridRect.tiles`).
    public static func < (lhs: GridPoint, rhs: GridPoint) -> Bool { (lhs.j, lhs.i) < (rhs.j, rhs.i) }

    public static func + (lhs: GridPoint, rhs: GridPoint) -> GridPoint { GridPoint(lhs.i + rhs.i, lhs.j + rhs.j) }
    public static func - (lhs: GridPoint, rhs: GridPoint) -> GridPoint { GridPoint(lhs.i - rhs.i, lhs.j - rhs.j) }
}

/// A size in tiles: `w` along i, `d` along j.
public struct GridSize: Hashable, Codable, Sendable {
    public var w: Int
    public var d: Int

    public init(w: Int, d: Int) {
        self.w = w
        self.d = d
    }
}

/// Tiles origin.i ..< origin.i + w by origin.j ..< origin.j + d. Empty when w or d is not positive.
public struct GridRect: Hashable, Codable, Sendable {
    public var origin: GridPoint
    public var size: GridSize

    public init(origin: GridPoint, size: GridSize) {
        self.origin = origin
        self.size = size
    }

    public var isEmpty: Bool { size.w <= 0 || size.d <= 0 }

    /// One past the last tile along each axis.
    public var end: GridPoint { GridPoint(origin.i + size.w, origin.j + size.d) }

    public func contains(_ p: GridPoint) -> Bool {
        p.i >= origin.i && p.j >= origin.j && p.i < end.i && p.j < end.j
    }

    /// Every tile of `r` is inside; an empty `r` is contained when its origin range lies inside.
    public func contains(_ r: GridRect) -> Bool {
        r.origin.i >= origin.i && r.origin.j >= origin.j && r.end.i <= end.i && r.end.j <= end.j
    }

    /// At least one shared tile: rects that only touch do not intersect.
    public func intersects(_ r: GridRect) -> Bool {
        guard !isEmpty, !r.isEmpty else { return false }
        return origin.i < r.end.i && r.origin.i < end.i && origin.j < r.end.j && r.origin.j < end.j
    }

    /// The smallest rect holding both; an empty rect adds nothing.
    public func union(_ r: GridRect) -> GridRect {
        if r.isEmpty { return self }
        if isEmpty { return r }
        let lo = GridPoint(min(origin.i, r.origin.i), min(origin.j, r.origin.j))
        let hi = GridPoint(max(end.i, r.end.i), max(end.j, r.end.j))
        return GridRect(origin: lo, size: GridSize(w: hi.i - lo.i, d: hi.j - lo.j))
    }

    /// j-major then i.
    public var tiles: [GridPoint] {
        guard !isEmpty else { return [] }
        var out: [GridPoint] = []
        out.reserveCapacity(size.w * size.d)
        for j in origin.j..<end.j {
            for i in origin.i..<end.i { out.append(GridPoint(i, j)) }
        }
        return out
    }
}

/// se = +i (down-right on screen), sw = +j (down-left), nw = −i, ne = −j. se and sw face the viewer.
public enum Facing: String, CaseIterable, Codable, Sendable {
    case ne, nw, se, sw

    /// se and sw: the viewer sees the face, or the screen side of a monitor.
    public var isTowardViewer: Bool { self == .se || self == .sw }

    /// Horizontal flip on screen: se ↔ sw, ne ↔ nw.
    public var mirrored: Facing {
        switch self {
        case .se: return .sw
        case .sw: return .se
        case .ne: return .nw
        case .nw: return .ne
        }
    }

    /// Half turn: se ↔ nw, sw ↔ ne.
    public var opposite: Facing {
        switch self {
        case .se: return .nw
        case .nw: return .se
        case .sw: return .ne
        case .ne: return .sw
        }
    }

    /// One tile in that direction: ne (0, −1), nw (−1, 0), se (1, 0), sw (0, 1).
    public var step: GridPoint {
        switch self {
        case .ne: return GridPoint(0, -1)
        case .nw: return GridPoint(-1, 0)
        case .se: return GridPoint(1, 0)
        case .sw: return GridPoint(0, 1)
        }
    }
}
