import Foundation

/// An agent that wants an edge arrow while it is out of view (3.9: an agent waiting for an answer).
public struct EdgeArrowTarget: Hashable, Sendable {
    public var id: AgentID
    /// Scene texels: the agent's seat.
    public var point: SceneVector
    /// Higher first: keeps its place when two arrows are too close.
    public var priority: Int

    public init(id: AgentID, point: SceneVector, priority: Int) {
        self.id = id
        self.point = point
        self.priority = priority
    }
}

/// An arrow on the border of the scene's view, pointing toward an agent out of view.
public struct EdgeArrow: Hashable, Sendable {
    public var id: AgentID
    /// View points, origin bottom-left, multiples of 2 (2 pt per texel UI).
    public var position: SceneVector
    /// 0 up, then clockwise by 45°: 1 up-right, 2 right … 7 up-left.
    public var direction: Int

    public init(id: AgentID, position: SceneVector, direction: Int) {
        self.id = id
        self.position = position
        self.direction = direction
    }
}

public enum EdgeArrows {
    /// Points between the view's edges and the arrows' centres; points between two arrows along the border.
    public static let inset = 20.0, spacing = 36.0

    /// One arrow per target outside the visible box: where the ray from the view's centre to the target crosses the
    /// rect inset by `inset`; direction = nearest 45°; arrows closer than `spacing` along the border are pushed
    /// apart (higher priority keeps its place, then lower id); sorted by priority (highest first), then id.
    /// A target listed twice keeps its first arrow in that order.
    public static func layout(_ targets: [EdgeArrowTarget], pose: CameraPose, view: ViewMetrics) -> [EdgeArrow] {
        let visible = CameraMath.visibleBox(pose, view: view)
        let ordered = targets.filter { !visible.contains($0.point) }.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id
        }
        let border = Border(width: view.width, height: view.height, inset: inset)
        var seen = Set<AgentID>()
        var placed: [Double] = []
        var arrows: [EdgeArrow] = []
        for target in ordered where seen.insert(target.id).inserted {
            let point = CameraMath.viewPoint(of: target.point, pose: pose, view: view)
            let dx = point.x - view.width / 2, dy = point.y - view.height / 2
            let s = border.free(near: border.parameter(alongRay: dx, dy), avoiding: placed, spacing: spacing)
            placed.append(s)
            let onBorder = border.point(at: s)
            arrows.append(EdgeArrow(id: target.id, position: SceneVector(evenPoints(onBorder.x), evenPoints(onBorder.y)),
                                    direction: direction(dx, dy)))
        }
        return arrows
    }

    /// The nearest of the 8 directions to the vector (dx, dy), y up: 0 up, clockwise.
    static func direction(_ dx: Double, _ dy: Double) -> Int {
        let angle = atan2(dx, dy)   // clockwise from up
        let octant = Int((angle / (Double.pi / 4)).rounded())
        return ((octant % 8) + 8) % 8
    }

    /// Rounded to the nearest multiple of 2.
    static func evenPoints(_ value: Double) -> Double {
        (value / 2).rounded() * 2
    }

    /// The inset rect, walked clockwise from its top-left corner: a point of the border is a distance along it.
    struct Border {
        let x0: Double, x1: Double, y0: Double, y1: Double

        init(width: Double, height: Double, inset: Double) {
            // A view too small for the inset collapses the rect on its centre.
            let ix = min(inset, width / 2), iy = min(inset, height / 2)
            x0 = ix
            x1 = width - ix
            y0 = iy
            y1 = height - iy
        }

        var w: Double { x1 - x0 }
        var h: Double { y1 - y0 }
        var perimeter: Double { 2 * (w + h) }

        /// Where the ray from the centre along (dx, dy) leaves the rect. Precondition: (dx, dy) is not zero.
        func parameter(alongRay dx: Double, _ dy: Double) -> Double {
            let tx = dx == 0 ? Double.infinity : (w / 2) / abs(dx)
            let ty = dy == 0 ? Double.infinity : (h / 2) / abs(dy)
            let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
            if tx <= ty {
                let y = min(max(cy + dy * tx, y0), y1)
                return dx > 0 ? w + (y1 - y) : wrap(2 * w + h + (y - y0))
            }
            let x = min(max(cx + dx * ty, x0), x1)
            return dy > 0 ? x - x0 : w + h + (x1 - x)
        }

        func point(at s: Double) -> SceneVector {
            let s = wrap(s)
            if s <= w { return SceneVector(x0 + s, y1) }
            if s <= w + h { return SceneVector(x1, y1 - (s - w)) }
            if s <= 2 * w + h { return SceneVector(x1 - (s - w - h), y0) }
            return SceneVector(x0, y0 + (s - 2 * w - h))
        }

        /// The place nearest to `s` at least `spacing` away from every placed arrow, along the border; `s` itself
        /// when the border is too short for another arrow. On a tie, the place met first clockwise from the top-left
        /// corner.
        func free(near s: Double, avoiding placed: [Double], spacing: Double) -> Double {
            guard perimeter > 0, !placed.isEmpty else { return s }
            var candidates = [s]
            for other in placed {
                candidates.append(wrap(other + spacing))
                candidates.append(wrap(other - spacing))
            }
            let valid = candidates.filter { c in placed.allSatisfy { distance(c, $0) >= spacing - 1e-9 } }
            let best = valid.min { a, b in
                let da = distance(a, s), db = distance(b, s)
                return da != db ? da < db : a < b
            }
            return best ?? s
        }

        /// Along the border, the shorter way round.
        func distance(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: perimeter)
            return min(d, perimeter - d)
        }

        func wrap(_ s: Double) -> Double {
            guard perimeter > 0 else { return 0 }
            let r = s.truncatingRemainder(dividingBy: perimeter)
            return r < 0 ? r + perimeter : r
        }
    }
}
