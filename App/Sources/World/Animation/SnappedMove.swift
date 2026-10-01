import CoreGraphics
import Foundation
import PixelCore
import SpriteKit

/// Rule 1 of 7.3 for what the scene moves by itself (an agent walking between the elevator and its seat, falling
/// furniture, a post-it flying to a desk): never `SKAction.move`, whose fractional positions spread a sprite over two
/// texels, but a custom action that recomputes the position at every frame and rounds it to whole texels. One scene
/// unit is one texel and the camera puts every whole texel on a physical pixel (rule 2): a rounded position is
/// pixel exact at every zoom.
@MainActor
enum SnappedMove {
    /// SpriteKit runs a custom action of no duration once; a path of no length still ends on its point.
    private static let shortest: TimeInterval = 1.0 / 240

    /// Moves a node along scene points (texels, y up) at `speed` texels per second, its position recomputed and
    /// rounded to whole texels every frame (`SnappedPath`); it ends exactly on the last point.
    static func along(_ points: [CGPoint], speed: CGFloat) -> SKAction {
        along(points, speed: speed, step: nil)
    }

    /// The same; `step` follows each new position (a walker turns at the corners and changes its depth).
    static func along(_ points: [CGPoint], speed: CGFloat,
                      step: (@MainActor (SKNode, SnappedPath.Sample) -> Void)?) -> SKAction {
        let path = SnappedPath(points)
        let duration = path.duration(speed: speed)
        return .customAction(withDuration: max(duration, shortest)) { node, elapsed in
            MainActor.assumeIsolated {
                let distance = duration > 0 ? path.length * min(1, Double(elapsed) / duration) : path.length
                let sample = path.sample(at: distance)
                node.position = sample.point
                step?(node, sample)
            }
        }
    }

    /// Falls from `height` texels above the place the node has when the action starts (its place in the plan),
    /// accelerating (ease-in), the height left rounded to whole texels every frame (`fallHeight`); it ends on that
    /// place. One base per node: the action may run on several nodes at once.
    static func fall(from height: CGFloat, duration: TimeInterval) -> SKAction {
        let bases = FallBases()
        return .customAction(withDuration: max(duration, shortest)) { node, elapsed in
            MainActor.assumeIsolated {
                let base = bases.base(of: node)
                let progress = duration > 0 ? Double(elapsed) / duration : 1
                node.position = CGPoint(x: base.x, y: base.y + fallHeight(height, progress: progress))
                if progress >= 1 { bases.forget(node) }
            }
        }
    }

    /// The same onto a known place (`rest`, whole texels): the node may already be held above it when the action
    /// starts (a post-it of a falling island waiting for its turn).
    static func fall(from height: CGFloat, duration: TimeInterval, onto rest: CGPoint) -> SKAction {
        .customAction(withDuration: max(duration, shortest)) { node, elapsed in
            MainActor.assumeIsolated {
                let progress = duration > 0 ? Double(elapsed) / duration : 1
                node.position = CGPoint(x: rest.x, y: rest.y + fallHeight(height, progress: progress))
            }
        }
    }

    /// The height left at `progress` (0…1) of a fall from `height`: `height · (1 − progress²)` (ease-in: slow at
    /// first, fastest on landing), rounded to whole texels.
    nonisolated static func fallHeight(_ height: CGFloat, progress: Double) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return (height * CGFloat(1 - t * t)).rounded()
    }

    /// The place each node had when its fall started.
    @MainActor
    private final class FallBases {
        private var bases: [ObjectIdentifier: CGPoint] = [:]

        func base(of node: SKNode) -> CGPoint {
            let key = ObjectIdentifier(node)
            if let base = bases[key] { return base }
            let base = CGPoint(x: node.position.x.rounded(), y: node.position.y.rounded())
            bases[key] = base
            return base
        }

        func forget(_ node: SKNode) {
            bases[ObjectIdentifier(node)] = nil
        }
    }
}

/// A path through scene points (texels, y up), sampled in whole texels. Along a segment of the isometric grid
/// (2:1, |dx| = 2·|dy|) the sample stays on the line: it moves one texel up or down for every two sideways, as the
/// floor's edges are drawn. Along any other segment both coordinates are rounded.
struct SnappedPath: Sendable {
    struct Sample: Hashable, Sendable {
        /// Whole texels.
        var point: CGPoint
        /// The segment the sample is on (0 for the first), `points.count − 2` at the end; 0 for a single point.
        var segment: Int
        /// Fraction of that segment (0…1).
        var fraction: Double
    }

    /// Whole texels.
    let points: [CGPoint]
    /// Distance from the first point to each point.
    let starts: [Double]
    let length: Double

    init(_ points: [CGPoint]) {
        let rounded = points.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
        self.points = rounded
        var starts: [Double] = []
        var total = 0.0
        for (index, point) in rounded.enumerated() {
            if index > 0 {
                let previous = rounded[index - 1]
                total += Double(hypot(point.x - previous.x, point.y - previous.y))
            }
            starts.append(total)
        }
        self.starts = starts
        length = total
    }

    /// Seconds to walk the whole path at `speed` texels per second.
    func duration(speed: Double) -> TimeInterval {
        speed > 0 ? length / speed : 0
    }

    /// The point `distance` texels along the path (clamped to its ends), in whole texels.
    func sample(at distance: Double) -> Sample {
        guard let first = points.first else { return Sample(point: .zero, segment: 0, fraction: 0) }
        guard points.count > 1 else { return Sample(point: first, segment: 0, fraction: 0) }
        let d = min(max(distance, 0), length)
        var segment = 0
        while segment < points.count - 2 && d >= starts[segment + 1] {
            segment += 1
        }
        let a = points[segment], b = points[segment + 1]
        let span = starts[segment + 1] - starts[segment]
        let fraction = span > 0 ? min(max((d - starts[segment]) / span, 0), 1) : 1
        return Sample(point: Self.snapped(from: a, to: b, fraction: fraction), segment: segment, fraction: fraction)
    }

    /// A point of segment a → b in whole texels (a and b are whole).
    static func snapped(from a: CGPoint, to b: CGPoint, fraction: Double) -> CGPoint {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        if dy != 0 && abs(dx) == 2 * abs(dy) {
            // On the 2:1 line: whole steps of (±2, ±1).
            let k = (abs(dy) * fraction).rounded()
            return CGPoint(x: a.x + CGFloat(2 * k * (dx > 0 ? 1 : -1)), y: a.y + CGFloat(k * (dy > 0 ? 1 : -1)))
        }
        return CGPoint(x: (Double(a.x) + dx * fraction).rounded(), y: (Double(a.y) + dy * fraction).rounded())
    }
}

/// The depth (`zPosition`) of what the scene moves by itself among the nodes of the plan (`SceneNode.zOrder`).
///
/// The world layer orders its objects by (i + j of their tile, `DepthLayer` level, i, place on the tile), after
/// the floor marks, the same key as `IsoMath.depth`: this mirrors how `ScenePlanner` packs `SceneNode.order` for
/// that layer (2^19 orders of floor marks first, then 8 places per (i + j, level, i), levels furniture 0,
/// character 1, screen and overlay 2; tiles beyond i = 255 or i + j = 511 share the last values). A walking
/// character takes the depth of the tile under its feet, at the character level, after the minis of that tile.
enum SceneDepth {
    /// Floor marks come first in the world layer (`markOrder`: 512 × 256 × 4 orders).
    static let marks = 512 * 256 * 4

    /// The zPosition the plan gives an object of `tile`, at `level`, `place` on its tile (0…7).
    static func world(tile: GridPoint, level: DepthLayer, place: Int) -> CGFloat {
        let rank: Int
        switch level {
        case .carpet, .furniture: rank = 0
        case .character: rank = 1
        case .screen, .overlay: rank = 2
        }
        let order = marks + ((clamp(tile.i + tile.j, 512) * 3 + rank) * 256 + clamp(tile.i, 256)) * 8 + clamp(place, 8)
        return CGFloat(SceneLayer.world.zBase + order)
    }

    /// A walker at a fractional grid position: the tile under its feet (a character stands on the centre of its
    /// tile, (a + 0.5, b + 0.5)), character level, last place (over the minis of a side tile).
    static func walker(i: Double, j: Double) -> CGFloat {
        world(tile: GridPoint(Int(i.rounded(.down)), Int(j.rounded(.down))), level: .character, place: 7)
    }

    /// Over the background and the back walls, under every node of the world layer: the shadow of a walker, which
    /// the furniture around it covers like the baked shadows.
    static var floorShadow: CGFloat { CGFloat(SceneLayer.world.zBase) - 0.5 }

    private static func clamp(_ value: Int, _ count: Int) -> Int { min(max(value, 0), count - 1) }
}

/// A point of the floor in fractional tiles: (a + 0.5, b + 0.5) is the centre of tile (a, b).
struct GridSpot: Hashable, Sendable {
    var i: Double
    var j: Double

    init(_ i: Double, _ j: Double) {
        self.i = i
        self.j = j
    }

    /// The centre of a tile.
    init(centreOf tile: GridPoint) {
        self.init(Double(tile.i) + 0.5, Double(tile.j) + 0.5)
    }

    /// The projection of 3.8 (`IsoMath.toScene`, extended to fractional tiles), in scene texels.
    var scenePoint: CGPoint {
        CGPoint(x: (i - j) * Double(IsoMath.tileWidth / 2), y: -(i + j) * Double(IsoMath.tileHeight / 2))
    }
}
