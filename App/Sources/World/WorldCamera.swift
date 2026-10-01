import Foundation
import Observation
import PixelCore
import QuartzCore

/// Where the camera can go (3.9): an agent's seat, an island, the hall (elevator and cork wall), a scene point, or
/// the whole world ("Tout voir").
enum CameraTarget: Hashable {
    case agent(AgentID)
    case island(ProjectID, part: Int)
    case hall
    case point(SceneVector)
    case all
}

/// The camera of the scene: the core's rules (`CameraMath`, `CameraFlight`) applied to the gestures, the commands and
/// the flights. It keeps an unsnapped request (small pans add up) and publishes the pose the scene shows: clamped
/// to the world with its margin, then snapped to the physical-pixel grid (7.3, rule 2), only when it changes.
@MainActor
@Observable
final class WorldCamera {
    /// Snapped: what the scene shows.
    private(set) var pose = CameraPose(zoom: .x1, center: SceneVector(0, 0))
    private(set) var view = ViewMetrics(width: 0, height: 0, backingScale: 2)
    /// The world canvas in scene texels (`CameraMath.worldBox(for: plan.rect)`).
    private(set) var world = SceneBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
    /// `pose.zoom == .overview`, published only when it changes: the plan of the overview differs (signs ×2, XL "!").
    private(set) var showsOverview = false

    /// The request: zoom and centre before clamping and snapping.
    @ObservationIgnored private var raw = CameraPose(zoom: .x1, center: SceneVector(0, 0))
    @ObservationIgnored private var flight: CameraFlight?
    @ObservationIgnored private var hasView = false
    @ObservationIgnored private var hasWorld = false
    /// The initial pose was set (both the view and the world are known).
    @ObservationIgnored private(set) var isPlaced = false

    /// Scene point of a target (the stage reads the plan); nil when it is not in the scene.
    @ObservationIgnored var resolveTarget: ((CameraTarget) -> SceneVector?)?
    /// Reduce Motion (the app's setting or the system's): flights are instant.
    @ObservationIgnored var reduceMotion: () -> Bool = { false }
    /// `AppSettings.defaultZoom`, read when the camera is first placed.
    @ObservationIgnored var defaultZoom: () -> Int = { 2 }
    /// Called after every change of the request: the scene poses its camera node, the view runs at 60 fps while
    /// flying.
    @ObservationIgnored var onChange: (() -> Void)?

    var availableZooms: [SceneZoom] { CameraMath.availableZooms(backingScale: view.backingScale) }
    var visibleBox: SceneBox { CameraMath.visibleBox(pose, view: view) }
    /// The world is not entirely visible.
    var needsMinimap: Bool { isPlaced && !visibleBox.contains(world) }
    var isFlying: Bool { flight != nil }

    func viewPoint(of scene: SceneVector) -> SceneVector {
        CameraMath.viewPoint(of: scene, pose: pose, view: view)
    }

    func scenePoint(atView point: SceneVector) -> SceneVector {
        CameraMath.scenePoint(atView: point, pose: pose, view: view)
    }

    // MARK: View and world

    /// The view's size in points and its backing scale (layout, screen change).
    func updateView(_ metrics: ViewMetrics) {
        guard metrics.width > 0, metrics.height > 0, metrics != view || !hasView else { return }
        view = metrics
        hasView = true
        if !availableZooms.contains(raw.zoom) { raw.zoom = .x1 }
        placeOrPublish()
    }

    /// The world of the current plan.
    func updateWorld(_ box: SceneBox) {
        guard box != world || !hasWorld else { return }
        world = box
        hasWorld = true
        placeOrPublish()
    }

    private func placeOrPublish() {
        guard hasView, hasWorld else { return }
        if !isPlaced {
            isPlaced = true
            raw = CameraMath.initialPose(defaultZoom: defaultZoom(), world: world, focus: nil, view: view)
        }
        publish()
    }

    // MARK: Zoom

    /// One of the zooms at rest (an unavailable one falls back to ×1), keeping the scene point under `viewPoint`
    /// (nil: the view's centre) where it is. Instant: no fractional zoom is ever shown (7.3).
    func setZoom(_ zoom: SceneZoom, about viewPoint: SceneVector?, animated: Bool) {
        guard isPlaced else { return }
        let target = availableZooms.contains(zoom) ? zoom : .x1
        flight = nil
        raw = CameraMath.zoomed(pose, to: target, keeping: viewPoint, world: world, view: view)
        publish()
    }

    func zoomIn(about viewPoint: SceneVector?) {
        setZoom(CameraMath.step(pose.zoom, by: 1, backingScale: view.backingScale), about: viewPoint, animated: true)
    }

    func zoomOut(about viewPoint: SceneVector?) {
        setZoom(CameraMath.step(pose.zoom, by: -1, backingScale: view.backingScale), about: viewPoint, animated: true)
    }

    /// "Tout voir" (⌘0, 3.9): the largest zoom that holds the world, centred. The zoom changes at once, the centre
    /// flies when `animated` (and Reduce Motion is off).
    func fitAll(animated: Bool) {
        guard isPlaced else { return }
        let fit = CameraMath.fitAll(world: world, view: view)
        if animated && !reduceMotion() {
            raw.zoom = fit.pose.zoom
            publish()
            startFlight(to: fit.pose.center)
        } else {
            flight = nil
            raw = fit.pose
            publish()
        }
    }

    // MARK: Moves

    /// Immediate (gestures, keyboard, automatic scrolling); the shown pose is snapped at once and at every frame.
    func pan(byViewPoints delta: SceneVector) {
        guard isPlaced else { return }
        flight = nil
        raw = CameraMath.panned(raw, byViewPoints: delta, world: world, view: view)
        publish()
    }

    /// `CameraFlight` from where the camera is to the target; instant with Reduce Motion.
    func fly(to target: CameraTarget) {
        guard isPlaced else { return }
        if target == .all { return fitAll(animated: true) }
        guard let point = resolveTarget?(target) else { return }
        startFlight(to: point)
    }

    /// Instant.
    func center(on target: CameraTarget) {
        guard isPlaced else { return }
        if target == .all { return fitAll(animated: false) }
        guard let point = resolveTarget?(target) else { return }
        flight = nil
        raw = CameraMath.clamped(CameraPose(zoom: pose.zoom, center: point), world: world, view: view)
        publish()
    }

    private func startFlight(to point: SceneVector) {
        let destination = CameraMath.clamped(CameraPose(zoom: raw.zoom, center: point), world: world, view: view).center
        if reduceMotion() {
            flight = nil
            raw.center = destination
        } else {
            flight = CameraFlight(from: pose.center, to: destination, start: CACurrentMediaTime())
        }
        publish()
    }

    /// The pose to show at `time` (the scene calls it every frame): the flight advanced, clamped, snapped.
    @discardableResult
    func advance(to time: TimeInterval) -> CameraPose {
        if let flight {
            raw.center = flight.position(at: time)
            if flight.isFinished(at: time) { self.flight = nil }
            publish(notify: self.flight == nil)
        }
        return pose
    }

    private func publish(notify: Bool = true) {
        guard isPlaced else { return }
        raw = CameraMath.clamped(raw, world: world, view: view)
        let shown = CameraMath.snapped(raw, view: view)
        if shown != pose { pose = shown }
        let overview = shown.zoom == .overview
        if overview != showsOverview { showsOverview = overview }
        if notify { onChange?() }
    }
}
