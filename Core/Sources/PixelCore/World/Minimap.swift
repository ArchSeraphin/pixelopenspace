import Foundation

/// The minimap (6(a), 3.9): the world scaled down into at most `Minimap.maxWidth` × `Minimap.maxHeight` points, at
/// 2 pt per texel of UI (every size and position a multiple of 2, 7.3).
public struct MinimapLayout: Hashable, Sendable {
    /// Points, multiples of 2.
    public var width: Double, height: Double
    /// Scene texels: what the minimap shows.
    public var world: SceneBox

    public init(width: Double, height: Double, world: SceneBox) {
        self.width = width
        self.height = height
        self.world = world
    }

    /// Minimap points, origin top-left (SwiftUI), y down, rounded to multiples of 2.
    public func point(of scene: SceneVector) -> SceneVector {
        SceneVector(Self.roundEven(rawX(scene.x)), Self.roundEven(rawY(scene.y)))
    }

    /// The scene point under a minimap point (not rounded); inverse of `point(of:)` on the 2 pt grid.
    public func scenePoint(at minimap: SceneVector) -> SceneVector {
        let x = width > 0 ? world.minX + minimap.x * world.width / width : world.center.x
        let y = height > 0 ? world.maxY - minimap.y * world.height / height : world.center.y
        return SceneVector(x, y)
    }

    /// The visible box in minimap points (y down: minY is the top edge), clipped to the minimap, each edge rounded
    /// to a multiple of 2. A view entirely off the world gives an empty box on the minimap's border.
    public func viewport(pose: CameraPose, view: ViewMetrics) -> SceneBox {
        let visible = CameraMath.visibleBox(pose, view: view)
        func clip(_ value: Double, _ limit: Double) -> Double { min(max(value, 0), limit) }
        return SceneBox(minX: clip(Self.roundEven(rawX(visible.minX)), width),
                        minY: clip(Self.roundEven(rawY(visible.maxY)), height),
                        maxX: clip(Self.roundEven(rawX(visible.maxX)), width),
                        maxY: clip(Self.roundEven(rawY(visible.minY)), height))
    }

    private func rawX(_ x: Double) -> Double {
        world.width > 0 ? (x - world.minX) * width / world.width : width / 2
    }

    private func rawY(_ y: Double) -> Double {
        world.height > 0 ? (world.maxY - y) * height / world.height : height / 2
    }

    /// Rounded to the nearest multiple of 2.
    private static func roundEven(_ value: Double) -> Double {
        (value / 2).rounded() * 2
    }
}

public enum Minimap {
    public static let maxWidth = 220.0, maxHeight = 140.0

    /// The largest minimap of the world's aspect inside maxWidth × maxHeight, both sides floored to a multiple of 2
    /// (at least 2). An empty world gets the whole room.
    public static func layout(world: SceneBox, maxWidth: Double = Minimap.maxWidth,
                              maxHeight: Double = Minimap.maxHeight) -> MinimapLayout {
        let roomWidth = floorEven(maxWidth), roomHeight = floorEven(maxHeight)
        guard world.width > 0, world.height > 0 else {
            return MinimapLayout(width: roomWidth, height: roomHeight, world: world)
        }
        let scale = min(roomWidth / world.width, roomHeight / world.height)
        return MinimapLayout(width: floorEven(world.width * scale), height: floorEven(world.height * scale), world: world)
    }

    /// Floored to a multiple of 2, at least 2 (the epsilon keeps an exact product such as 1920 · 220 / 1920 whole).
    private static func floorEven(_ value: Double) -> Double {
        max(2, ((value + 1e-9) / 2).rounded(.down) * 2)
    }
}
