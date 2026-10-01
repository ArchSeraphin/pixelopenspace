import Foundation

/// A camera flight toward an agent, an island or the hall (3.9): an ease-in-out of 0.4 s from one centre to another.
/// Times are seconds on any clock the caller keeps (the scene's update time); the pose shown at each frame is
/// `CameraMath.snapped` of `position(at:)`, never a sub-pixel position (7.3, rule 1).
public struct CameraFlight: Hashable, Sendable {
    public static let duration = 0.4

    /// Scene texels.
    public let from: SceneVector, to: SceneVector
    /// Seconds.
    public let start: Double, duration: Double

    /// duration 0 (Reduce Motion): finished at once. A negative or invalid duration counts as 0.
    public init(from: SceneVector, to: SceneVector, start: Double, duration: Double = CameraFlight.duration) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration > 0 && duration.isFinite ? duration : 0
    }

    /// Cubic ease-in-out, unsnapped (the scene snaps every frame): `from` until `start`, `to` from start + duration.
    public func position(at time: Double) -> SceneVector {
        let t = progress(at: time)
        if t <= 0 { return from }
        if t >= 1 { return to }
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return SceneVector(from.x + (to.x - from.x) * eased, from.y + (to.y - from.y) * eased)
    }

    public func isFinished(at time: Double) -> Bool {
        duration == 0 || time >= start + duration
    }

    /// 0 before the start, 1 when finished, linear in between.
    private func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((time - start) / duration, 0), 1)
    }
}
