import Foundation

// Camera rules of the scene (3.9, 7.3): zoom levels, the pixel grid, what stays in view. SpriteKit only applies them.
//
// Two frames share these types: the scene, in texels with y up (décision 16: the top vertex of tile (0, 0) at the
// origin), and the view, in points with the origin at the bottom-left corner (AppKit). The camera's centre is the
// scene point shown at the middle of the view.

/// A point or a vector: scene texels, or view points.
public struct SceneVector: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Axis-aligned box, y up (scene texels) or view points (origin bottom-left, AppKit).
public struct SceneBox: Hashable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: SceneVector { SceneVector((minX + maxX) / 2, (minY + maxY) / 2) }

    /// Edges included.
    public func contains(_ p: SceneVector) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    /// Every point of `b` is inside (edges included).
    public func contains(_ b: SceneBox) -> Bool {
        b.minX >= minX && b.maxX <= maxX && b.minY >= minY && b.maxY <= maxY
    }
}

/// The size of the scene's view.
public struct ViewMetrics: Hashable, Sendable {
    /// Points.
    public var width: Double, height: Double
    /// Physical pixels per point: 1, or 2 on a Retina screen.
    public var backingScale: Int

    public init(width: Double, height: Double, backingScale: Int) {
        self.width = width
        self.height = height
        self.backingScale = backingScale
    }
}

/// Where the camera looks, and how close.
public struct CameraPose: Hashable, Sendable {
    public var zoom: SceneZoom
    /// Scene texels: what sits at the middle of the view.
    public var center: SceneVector

    public init(zoom: SceneZoom, center: SceneVector) {
        self.zoom = zoom
        self.center = center
    }
}

/// The camera rules, pure: the app keeps a pose, feeds it its gestures through these functions, and shows
/// `snapped(clamped(pose))` at every frame.
public enum CameraMath {
    /// Points kept around the world (décision 15).
    public static let margin = 48.0
    /// Arrow keys: view points per press; with ⇧, `keyboardFastFactor` times as many.
    public static let keyboardStep = 64.0, keyboardFastFactor = 4.0

    /// 0.5, 1, 2, 3.
    public static func pointsPerTexel(_ zoom: SceneZoom) -> Double {
        switch zoom {
        case .overview: return 0.5
        case .x1: return 1
        case .x2: return 2
        case .x3: return 3
        }
    }

    /// SKCameraNode scale: 1 / pointsPerTexel.
    public static func cameraScale(_ zoom: SceneZoom) -> Double {
        1 / pointsPerTexel(zoom)
    }

    /// The overview only with backingScale ≥ 2 (1 physical pixel per texel), then x1, x2, x3.
    public static func availableZooms(backingScale: Int) -> [SceneZoom] {
        backingScale >= 2 ? SceneZoom.allCases : SceneZoom.allCases.filter { $0 != .overview }
    }

    /// The world canvas in scene coordinates (décision 16): x ∈ [−32·(D − i0 + j0), 32·(W + i0 − j0)],
    /// y ∈ [−16·(i0 + j0 + W + D), 96 − 16·(i0 + j0)]; the size of `SceneCompositor.canvasSize(for:)`.
    public static func worldBox(for rect: GridRect) -> SceneBox {
        let size = SceneCompositor.canvasSize(for: rect)
        let halfTileWidth = IsoMath.tileWidth / 2, halfTileHeight = IsoMath.tileHeight / 2
        let minX = Double(-halfTileWidth * (rect.size.d - rect.origin.i + rect.origin.j))
        let maxY = Double(IsoMath.wallHeight - halfTileHeight * (rect.origin.i + rect.origin.j))
        return SceneBox(minX: minX, minY: maxY - Double(size.height), maxX: minX + Double(size.width), maxY: maxY)
    }

    /// Texels per physical pixel: 1 / (pointsPerTexel · backingScale).
    public static func pixelStep(_ zoom: SceneZoom, backingScale: Int) -> Double {
        1 / physicalPixelsPerTexel(zoom, backingScale: backingScale)
    }

    /// Rule 2 of 7.3: the centre floored to the physical-pixel grid (multiple of pixelStep), plus half a step on an
    /// axis whose size in physical pixels is odd, so that every integer texel edge lands on a pixel edge.
    /// Idempotent. The view's size in physical pixels is its size in points × backingScale, rounded.
    public static func snapped(_ pose: CameraPose, view: ViewMetrics) -> CameraPose {
        let k = physicalPixelsPerTexel(pose.zoom, backingScale: view.backingScale)
        let scale = Double(max(view.backingScale, 1))
        func snap(_ c: Double, points: Double) -> Double {
            guard c.isFinite else { return c }
            // The epsilon keeps a value already on the grid there despite rounding errors (idempotence).
            let pixels = (c * k + 1e-6).rounded(.down)
            let odd = Int((points * scale).rounded()) & 1 == 1
            return (odd ? pixels + 0.5 : pixels) / k
        }
        return CameraPose(zoom: pose.zoom, center: SceneVector(snap(pose.center.x, points: view.width),
                                                               snap(pose.center.y, points: view.height)))
    }

    /// Keeps the world in view with `margin`: on an axis where the world is larger than the view, the view never
    /// goes more than `margin` points past the world's edge; a world smaller than the view on an axis is centred on
    /// that axis. Not snapped.
    public static func clamped(_ pose: CameraPose, world: SceneBox, view: ViewMetrics) -> CameraPose {
        let p = pointsPerTexel(pose.zoom)
        let marginTexels = margin / p
        func clamp(_ c: Double, low: Double, high: Double, viewPoints: Double) -> Double {
            let viewTexels = viewPoints / p
            guard high - low > viewTexels else { return (low + high) / 2 }
            let lowest = low - marginTexels + viewTexels / 2, highest = high + marginTexels - viewTexels / 2
            return min(max(c, lowest), highest)
        }
        return CameraPose(zoom: pose.zoom,
                          center: SceneVector(clamp(pose.center.x, low: world.minX, high: world.maxX, viewPoints: view.width),
                                              clamp(pose.center.y, low: world.minY, high: world.maxY,
                                                    viewPoints: view.height)))
    }

    /// The scene texels the view shows.
    public static func visibleBox(_ pose: CameraPose, view: ViewMetrics) -> SceneBox {
        let p = pointsPerTexel(pose.zoom)
        let halfWidth = view.width / (2 * p), halfHeight = view.height / (2 * p)
        return SceneBox(minX: pose.center.x - halfWidth, minY: pose.center.y - halfHeight,
                        maxX: pose.center.x + halfWidth, maxY: pose.center.y + halfHeight)
    }

    /// Where a scene point is in the view (points, origin bottom-left).
    public static func viewPoint(of scene: SceneVector, pose: CameraPose, view: ViewMetrics) -> SceneVector {
        let p = pointsPerTexel(pose.zoom)
        return SceneVector((scene.x - pose.center.x) * p + view.width / 2, (scene.y - pose.center.y) * p + view.height / 2)
    }

    /// The scene point under a view point; inverse of `viewPoint(of:pose:view:)`.
    public static func scenePoint(atView point: SceneVector, pose: CameraPose, view: ViewMetrics) -> SceneVector {
        let p = pointsPerTexel(pose.zoom)
        return SceneVector((point.x - view.width / 2) / p + pose.center.x, (point.y - view.height / 2) / p + pose.center.y)
    }

    /// "Tout voir" (3.9): the largest available zoom whose view (minus margins) holds the whole world, centred; else
    /// x1 centred on the world with `needsMinimap`. The pose is clamped and snapped.
    public static func fitAll(world: SceneBox, view: ViewMetrics) -> (pose: CameraPose, needsMinimap: Bool) {
        let roomWidth = view.width - 2 * margin, roomHeight = view.height - 2 * margin
        for zoom in availableZooms(backingScale: view.backingScale).reversed() {
            let p = pointsPerTexel(zoom)
            if world.width * p <= roomWidth && world.height * p <= roomHeight {
                return (rest(CameraPose(zoom: zoom, center: world.center), world: world, view: view), false)
            }
        }
        return (rest(CameraPose(zoom: .x1, center: world.center), world: world, view: view), true)
    }

    /// Changes the zoom keeping the scene point under `viewPoint` (nil: the view's centre) where it is, then clamps
    /// and snaps.
    public static func zoomed(_ pose: CameraPose, to zoom: SceneZoom, keeping viewPoint: SceneVector?,
                              world: SceneBox, view: ViewMetrics) -> CameraPose {
        var center = pose.center
        if let viewPoint {
            let anchor = scenePoint(atView: viewPoint, pose: pose, view: view)
            let p = pointsPerTexel(zoom)
            center = SceneVector(anchor.x - (viewPoint.x - view.width / 2) / p, anchor.y - (viewPoint.y - view.height / 2) / p)
        }
        return rest(CameraPose(zoom: zoom, center: center), world: world, view: view)
    }

    /// Next or previous available zoom (delta ±1, or more), clamped to the available list. A zoom that is not
    /// available (the overview without Retina) counts as lying just below the next available one.
    public static func step(_ zoom: SceneZoom, by delta: Int, backingScale: Int) -> SceneZoom {
        let available = availableZooms(backingScale: backingScale)
        let below = available.filter { $0.rawValue < zoom.rawValue }.count
        var index: Int
        if available.contains(zoom) {
            index = below + delta
        } else {
            index = delta > 0 ? below + delta - 1 : below + delta
        }
        index = min(max(index, 0), available.count - 1)
        return available[index]
    }

    /// Moves the camera by `delta` view points (the view's content moves the other way), then clamps. Not snapped:
    /// small trackpad deltas add up; the scene snaps the pose it shows at every frame.
    public static func panned(_ pose: CameraPose, byViewPoints delta: SceneVector, world: SceneBox,
                              view: ViewMetrics) -> CameraPose {
        let p = pointsPerTexel(pose.zoom)
        let moved = CameraPose(zoom: pose.zoom, center: SceneVector(pose.center.x + delta.x / p, pose.center.y + delta.y / p))
        return clamped(moved, world: world, view: view)
    }

    /// Launch: `defaultZoom` (AppSettings: 0 = overview, falls back to x1 without Retina; out-of-range values are
    /// brought into 0…3), centred on `focus` or on the world; clamped and snapped.
    public static func initialPose(defaultZoom: Int, world: SceneBox, focus: SceneVector?, view: ViewMetrics) -> CameraPose {
        var zoom = SceneZoom(rawValue: min(max(defaultZoom, 0), 3)) ?? .x1
        if !availableZooms(backingScale: view.backingScale).contains(zoom) { zoom = .x1 }
        return rest(CameraPose(zoom: zoom, center: focus ?? world.center), world: world, view: view)
    }

    // MARK: Helpers

    /// pointsPerTexel · backingScale (a backing scale below 1 counts as 1).
    private static func physicalPixelsPerTexel(_ zoom: SceneZoom, backingScale: Int) -> Double {
        pointsPerTexel(zoom) * Double(max(backingScale, 1))
    }

    /// A pose at rest: clamped, then snapped.
    private static func rest(_ pose: CameraPose, world: SceneBox, view: ViewMetrics) -> CameraPose {
        snapped(clamped(pose, world: world, view: view), view: view)
    }
}

/// Pinch to zoom without a fractional zoom at rest (3.9): magnifications add up until they cross a threshold, which
/// is one zoom step.
public struct PinchAccumulator: Hashable, Sendable {
    public static let threshold = 0.35

    /// The magnification gathered since the last step.
    public private(set) var sum = 0.0

    public init() {}

    /// Adds a magnification delta (NSEvent.magnification); returns +1 or −1 when the sum crosses ±threshold (the
    /// sum then restarts from zero), else 0. Never a fractional zoom.
    public mutating func add(_ magnification: Double) -> Int {
        guard magnification.isFinite else { return 0 }
        sum += magnification
        if sum >= Self.threshold {
            sum = 0
            return 1
        }
        if sum <= -Self.threshold {
            sum = 0
            return -1
        }
        return 0
    }

    public mutating func reset() {
        sum = 0
    }
}
