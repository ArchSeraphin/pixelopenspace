import Foundation

/// A point of the scene in texels, y up (3.8): the top vertex of tile (0, 0) is the origin.
public struct ScenePoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Draw order inside a tile (7.3): carpet 0, furniture 2, character 4, screen 5, overlay 8.
public enum DepthLayer: Int, CaseIterable, Sendable {
    case carpet = 0, furniture = 2, character = 4, screen = 5, overlay = 8
}

/// The 2:1 isometric projection of 3.8 and the templates of 7.3.
public enum IsoMath {
    /// A tile is a 64×32 diamond; one level is 16 px.
    public static let tileWidth = 64, tileHeight = 32, levelHeight = 16
    /// Heights in px: chair seat, desk top, top of a screen, a character, a wall (6 levels).
    public static let seatHeight = 16, deskTopHeight = 24, screenTopHeight = 44, characterHeight = 56, wallHeight = 96

    /// Top vertex of the tile: ((i − j)·32, −(i + j)·16).
    public static func toScene(_ p: GridPoint) -> ScenePoint {
        ScenePoint(x: (p.i - p.j) * tileWidth / 2, y: -(p.i + p.j) * tileHeight / 2)
    }

    /// Centre of the tile: toScene + (0, −16).
    public static func tileCenter(_ p: GridPoint) -> ScenePoint {
        let top = toScene(p)
        return ScenePoint(x: top.x, y: top.y - tileHeight / 2)
    }

    /// Inverse of toScene, in fractional tiles.
    public static func toGrid(x: Double, y: Double) -> (i: Double, j: Double) {
        let iMinusJ = x / Double(tileWidth / 2), iPlusJ = -y / Double(tileHeight / 2)
        return ((iPlusJ + iMinusJ) / 2, (iPlusJ - iMinusJ) / 2)
    }

    /// (i + j)·10 + layer: farther tiles first, then the layers of a tile in order.
    public static func depth(_ p: GridPoint, layer: DepthLayer) -> Int {
        (p.i + p.j) * 10 + layer.rawValue
    }

    /// Same rule for a position between tiles (a walking character).
    public static func depth(i: Double, j: Double, layer: DepthLayer) -> Double {
        (i + j) * 10 + Double(layer.rawValue)
    }
}
