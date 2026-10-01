import Observation
import PixelCore
import SwiftUI

/// The open space in the main window (scene mode, the default; ⌘L shows the list instead): the SpriteKit view, and,
/// while there is no project, the card of the empty world (6(r)) over the hall. Over the scene, the HUD's small
/// controls: the minimap (bottom right, 6(a)) and the edge arrows (3.9); only they take the events, in their frames.
/// Starts and stops the coordinator with its appearance, and attaches the HUD (`WorldHUD`) to the stage.
struct WorldAreaView: View {
    /// Points between the minimap and the corner of the scene.
    static let minimapMargin: CGFloat = 16

    let stage: WorldStage

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        WorldViewRepresentable(stage: stage)
            .overlay {
                if model.projects.isEmpty {
                    EmptyWorldCard()
                        .padding(24)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                MinimapView(stage: stage)
                    .padding(Self.minimapMargin)
            }
            .overlay {
                EdgeArrowsView(stage: stage)
            }
            .onAppear {
                stage.coordinator?.start()
                WorldHUD.shared.attach(stage: stage, model: model, workbench: workbench)
            }
            .onDisappear { stage.coordinator?.stop() }
            .onChange(of: model.workspace) {
                WorldHUD.shared.refresh()
            }
            .onChange(of: stage.camera.world) {
                WorldHUD.shared.refresh()
            }
    }
}

/// What the HUD of the scene (minimap, edge arrows, VoiceOver elements, the status bar's zoom control) reads of the
/// stage: the seats and the islands of its plan, published. The stage does not publish its plan, and the
/// coordinator plans a run-loop turn or more after the model changes (characters are composed first): the HUD copies
/// the plan when the workspace or the world changes, then again every `retryDelay` until the plan shows the agents
/// and the projects of the workspace (at most `retryLimit` times). One main window, one HUD.
@MainActor
@Observable
final class WorldHUD {
    static let shared = WorldHUD()
    static let retryDelay: Duration = .milliseconds(50)
    static let retryLimit = 40

    /// `plan.agentSeats`, as last copied.
    private(set) var seats: [AgentID: ScenePoint] = [:]
    /// `plan.islands`, as last copied.
    private(set) var islands: [WorldScenePlan.IslandFrame] = []
    /// Changes when another stage is attached: `stage` is observed through it.
    private var stageGeneration = 0

    @ObservationIgnored private weak var stageRef: WorldStage?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// The scene's elements for VoiceOver (7.9).
    @ObservationIgnored let accessibility = WorldAccessibility()

    private init() {}

    /// The stage of the main window's open space (nil before the scene first appeared).
    var stage: WorldStage? {
        _ = stageGeneration
        return stageRef
    }

    func attach(stage: WorldStage, model: AppModel, workbench: WorkbenchState) {
        if stageRef !== stage {
            stageRef = stage
            stageGeneration += 1
        }
        self.model = model
        accessibility.configure(hud: self, model: model, workbench: workbench)
        refresh()
    }

    /// Copies the seats and islands of the stage's plan, gives the scene's view its VoiceOver elements, and looks
    /// again shortly while the plan is behind the workspace (or the view not made yet).
    func refresh() {
        refresh(attempt: 0)
    }

    private func refresh(attempt: Int) {
        retry?.cancel()
        retry = nil
        guard let stage = stageRef, let model else { return }
        let plan = stage.plan
        let newSeats = plan?.agentSeats ?? [:]
        let newIslands = plan?.islands ?? []
        if newSeats != seats { seats = newSeats }
        if newIslands != islands { islands = newIslands }
        accessibility.update(stage: stage)
        let settled = stage.view != nil && Self.plan(of: stage.input, matches: model.workspace)
        guard !settled, attempt < Self.retryLimit else { return }
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled else { return }
            self?.refresh(attempt: attempt + 1)
        }
    }

    /// The plan was made from a workspace with the same live projects and agents (what `SceneInput.make` keeps).
    static func plan(of input: SceneInput?, matches workspace: Workspace) -> Bool {
        guard let input else { return false }
        let projects = Set(workspace.projects.filter { !$0.archived }.map(\.id))
        let agents = Set(workspace.agents.filter { workspace.liveProject($0.projectID) != nil }.map(\.id))
        return Set(input.projects.keys) == projects && Set(input.agents.keys) == agents
    }

    // MARK: Edge arrows

    /// The arrows of the agents waiting out of view (3.9), in the view's points: one per waiting agent placed in the
    /// plan, the oldest wait first in priority (tray order).
    func edgeArrows(model: AppModel) -> [EdgeArrow] {
        guard let camera = stage?.camera, camera.isPlaced else { return [] }
        let waiting = model.liveStatusSummary.waiting
        let targets = waiting.enumerated().compactMap { index, entry -> EdgeArrowTarget? in
            guard let seat = seats[entry.agentID] else { return nil }
            return EdgeArrowTarget(id: entry.agentID, point: SceneVector(Double(seat.x), Double(seat.y)),
                                   priority: waiting.count - index)
        }
        guard !targets.isEmpty else { return [] }
        return EdgeArrows.layout(targets, pose: camera.pose, view: camera.view)
    }

    /// Animated HUD sprites (edge arrows): never in the snapshot harness (frame 0, as the scene), nor with Reduce
    /// Motion.
    var animates: Bool {
        !SnapshotHooks.shared.isEnabled && !(stage?.coordinator?.reduceMotion ?? false)
    }
}
