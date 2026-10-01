import Foundation

/// Scrolling while a post-it is dragged near an edge of the scene (3.9).
public enum AutoScroll {
    /// Points from an edge where the camera starts gliding, and where it speeds up; view points per second.
    public static let band = 48.0, fastBand = 16.0, speed = 200.0, fastSpeed = 600.0

    /// Camera velocity in view points per second while dragging at `pointer` (view points, origin bottom-left):
    /// toward each edge closer than `band` (speed), or `fastBand` (fastSpeed); zero elsewhere, and outside the view
    /// (the drag left the scene). Feed it to `CameraMath.panned` scaled by the frame's duration.
    public static func velocity(pointer: SceneVector, view: ViewMetrics) -> SceneVector {
        SceneVector(axis(pointer.x, size: view.width), axis(pointer.y, size: view.height))
    }

    /// Toward the nearer edge of [0, size], or 0.
    private static func axis(_ position: Double, size: Double) -> Double {
        guard position >= 0, position <= size else { return 0 }
        let toLow = position, toHigh = size - position
        let sign = toLow <= toHigh ? -1.0 : 1.0
        let distance = min(toLow, toHigh)
        if distance < fastBand { return sign * fastSpeed }
        if distance < band { return sign * speed }
        return 0
    }
}
