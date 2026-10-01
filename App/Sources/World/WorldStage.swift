import AppKit
import Foundation
import PixelCore

/// One per main window: what every feature of the scene reaches. The stage outlives the scene and its view: ⌘L
/// tears the SpriteKit view down and builds it again, the camera, the textures and the coordinator stay.
@MainActor
final class WorldStage {
    let camera: WorldCamera
    let interaction: WorldInteractionState
    let registry: SpriteRegistry
    /// The plan the scene shows, and the input it was planned from (snapshots compare the scene with the software
    /// render of this input).
    private(set) var plan: WorldScenePlan?
    private(set) var input: SceneInput?
    weak var view: WorldView?
    weak var scene: WorldScene?
    /// Created with the stage, started by `WorldAreaView`.
    private(set) var coordinator: WorldSceneCoordinator?
    /// Snapshots only: the last capture, cropped to whole texels, and the whole view it was cut from
    /// (`showStill`).
    var lastCapture: (cropped: CGImage, full: CGImage)?

    init(model: AppModel, workbench: WorkbenchState) {
        camera = WorldCamera()
        interaction = WorldInteractionState()
        registry = SpriteRegistry()
        coordinator = WorldSceneCoordinator(model: model, workbench: workbench, stage: self)
        camera.resolveTarget = { [weak self] target in self?.scenePoint(for: target) }
        camera.defaultZoom = { [weak model] in model?.settings.defaultZoom ?? 2 }
        camera.reduceMotion = { [weak self] in self?.coordinator?.reduceMotion ?? false }
        camera.onChange = { [weak self] in
            self?.scene?.syncCamera()
            self?.view?.updateEnergy()
        }
        if SnapshotHooks.shared.isEnabled {
            WorldSnapshotHooks.register(stage: self, model: model, workbench: workbench)
        }
    }

    /// A new SpriteKit view shows the scene: the coordinator applies the whole plan to it.
    func attach(view: WorldView, scene: WorldScene) {
        self.view = view
        self.scene = scene
        scene.stage = self
        view.stage = self
        coordinator?.sceneAttached()
    }

    /// The view left the window hierarchy (list view, window closed).
    func detach(view: WorldView) {
        guard self.view === view else { return }
        self.view = nil
        scene = nil
    }

    /// Set by the coordinator only.
    func setPlan(_ plan: WorldScenePlan, input: SceneInput) {
        self.plan = plan
        self.input = input
        camera.updateWorld(CameraMath.worldBox(for: plan.rect))
    }

    /// The scene is up to date and the camera posed (snapshots: after each step).
    func settle() {
        coordinator?.replanNow()
        scene?.syncCamera()
    }

    // MARK: Targets

    /// Height (texels) the camera aims above a seat: the middle of a seated agent rather than the floor.
    static let agentAim = 24.0
    /// Height above an island's rug: the furniture's middle.
    static let islandAim = 16.0
    /// Height above the hall's floor: the middle of the back walls (cork wall, elevator).
    static let hallAim = 48.0

    /// Scene point of a camera target, from the plan; nil when it is not in the scene.
    func scenePoint(for target: CameraTarget) -> SceneVector? {
        switch target {
        case .point(let point):
            return point
        case .all:
            return camera.world.center
        case .agent(let id):
            guard let seat = plan?.agentSeats[id] else { return nil }
            return SceneVector(Double(seat.x), Double(seat.y) + Self.agentAim)
        case .island(let projectID, let part):
            guard let island = plan?.islands.first(where: { $0.projectID == projectID && $0.part == part })
                ?? plan?.islands.first(where: { $0.projectID == projectID }) else { return nil }
            let centre = Self.center(of: island.rug)
            return SceneVector(centre.x, centre.y + Self.islandAim)
        case .hall:
            guard let layout = input?.layout else { return nil }
            let centre = Self.center(of: layout.boardWall.union(layout.elevator))
            return SceneVector(centre.x, centre.y + Self.hallAim)
        }
    }

    /// The middle of a rect of tiles, in scene texels (the projection of 3.8 is linear: the top vertex of the
    /// fractional tile at its centre).
    static func center(of rect: GridRect) -> SceneVector {
        let i = Double(rect.origin.i) + Double(rect.size.w) / 2, j = Double(rect.origin.j) + Double(rect.size.d) / 2
        return SceneVector((i - j) * Double(IsoMath.tileWidth / 2), -(i + j) * Double(IsoMath.tileHeight / 2))
    }

    /// The agent or live project of that name in the workspace (snapshot steps).
    func agentID(named name: String, in model: AppModel) -> AgentID? {
        model.workspace.agents.first { $0.name == name }?.id
    }

    func projectID(named name: String, in model: AppModel) -> ProjectID? {
        model.workspace.projects.first { $0.name == name && !$0.archived }?.id
    }

    /// The agent's seat is inside the view (notifications: "the user can see it").
    func isVisible(_ agentID: AgentID) -> Bool {
        guard view?.window != nil, let seat = plan?.agentSeats[agentID] else { return false }
        return camera.visibleBox.contains(SceneVector(Double(seat.x), Double(seat.y)))
    }
}
