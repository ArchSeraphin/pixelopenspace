import AppKit
import Foundation
import Observation
import PixelCore

/// Keeps the scene equal to the core's plan of the model (3.9): it observes the workspace, the runtimes, the board,
/// the selection, the clock, the settings, the interaction state and the overview zoom; the changes of one run-loop
/// turn give one plan (`ScenePlanner.plan`), whose diff from the last one is applied only when it is not empty. The
/// characters a plan needs are composed off the main actor before it is applied, the background baked off the main
/// thread when it changes. Never a night scene at this step (décision 4).
@MainActor
final class WorldSceneCoordinator {
    private let model: AppModel
    private weak var workbench: WorkbenchState?
    /// The stage owns the coordinator; weak, because a plan waiting for its characters may outlive the window.
    private weak var stage: WorldStage?

    private var isRunning = false
    private var isScheduled = false
    /// The live observation (a stopped then restarted coordinator never keeps two).
    private var observation = 0
    /// Each plan has its number; an older one whose characters arrive late is not applied.
    private var generation = 0
    /// What the attached scene shows.
    private weak var appliedScene: WorldScene?
    private var appliedPlan: WorldScenePlan?
    /// The background baking off the main thread, and its number (a newer bake drops an older result).
    private var bakeGeneration = 0
    private var pendingBake: (background: SceneBackground, rect: GridRect)?
    private weak var pendingBakeScene: WorldScene?

    init(model: AppModel, workbench: WorkbenchState, stage: WorldStage) {
        self.model = model
        self.workbench = workbench
        self.stage = stage
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    /// Reduce Motion: the app's setting or the system's (7.9). Off in the snapshot harness, whose reference is drawn
    /// without it.
    var reduceMotion: Bool {
        if SnapshotHooks.shared.isEnabled { return false }
        return model.settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe()
        schedule()
    }

    func stop() {
        isRunning = false
    }

    /// A new scene: the whole plan goes into it.
    func sceneAttached() {
        appliedScene = nil
        appliedPlan = nil
        if isRunning { schedule() }
    }

    /// Synchronous (snapshots): plans, composes the missing characters and bakes the background on the main actor.
    func replanNow() {
        guard let stage else { return }
        generation += 1
        let (plan, input) = makePlan(stage)
        stage.registry.prepareNow(characters: Self.characterRefs(in: plan))
        apply(plan, input: input, to: stage, bakeNow: true)
    }

    // MARK: Observation

    private func observe() {
        guard isRunning, let stage else { return }
        observation += 1
        let mine = observation
        let model = self.model
        let interaction = stage.interaction
        let camera = stage.camera
        withObservationTracking {
            _ = model.workspace
            _ = model.runtimes
            _ = model.board
            _ = model.selectedAgentID
            _ = model.now
            _ = model.settings
            _ = interaction.hovered
            _ = interaction.dropTarget
            _ = interaction.hiddenAgents
            _ = camera.showsOverview
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning, mine == self.observation else { return }
                self.schedule()
                self.observe()
            }
        }
    }

    /// One plan for all the changes of this run-loop turn.
    private func schedule() {
        guard isRunning, !isScheduled else { return }
        isScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isScheduled = false
            await self.replan()
        }
    }

    private func replan() async {
        guard isRunning, let stage else { return }
        generation += 1
        let mine = generation
        let (plan, input) = makePlan(stage)
        let refs = Self.characterRefs(in: plan)
        let registry = stage.registry
        if !refs.allSatisfy(registry.hasCharacter) {
            await registry.prepare(characters: refs)
            // Composed by an earlier plan's preparation meanwhile, or not at all: whatever is missing now.
            guard mine == generation, let stage = self.stage else { return }
            registry.prepareNow(characters: refs)
            apply(plan, input: input, to: stage, bakeNow: false)
        } else {
            apply(plan, input: input, to: stage, bakeNow: false)
        }
    }

    private func makePlan(_ stage: WorldStage) -> (WorldScenePlan, SceneInput) {
        let interaction = stage.interaction
        let reduceMotion = self.reduceMotion
        let input = SceneInput.make(workspace: model.workspace, runtimes: model.runtimes, board: model.board,
                                    now: model.now, reduceMotion: reduceMotion, selectedAgent: model.selectedAgentID,
                                    hovered: interaction.hovered, dropTarget: interaction.dropTarget,
                                    hiddenAgents: interaction.hiddenAgents)
        let options = ScenePlanOptions(overview: stage.camera.showsOverview, night: false, reduceMotion: reduceMotion)
        return (ScenePlanner.plan(input, options: options), input)
    }

    static func characterRefs(in plan: WorldScenePlan) -> Set<CharacterRef> {
        Set(plan.nodes.compactMap(WorldSceneNodes.characterRef))
    }

    // MARK: Applying

    private func apply(_ plan: WorldScenePlan, input: SceneInput, to stage: WorldStage, bakeNow: Bool) {
        stage.setPlan(plan, input: input)
        guard let scene = stage.scene else { return }
        let previous = appliedScene === scene ? appliedPlan : nil
        let diff = plan.diff(from: previous)
        if !diff.added.isEmpty || !diff.updated.isEmpty || !diff.removed.isEmpty {
            scene.apply(plan, diff: diff)
        }
        appliedScene = scene
        appliedPlan = plan
        if scene.needsBackground(plan) {
            bake(plan, into: scene, now: bakeNow)
        }
        scene.syncCamera()
    }

    /// `SceneCompositor.background(plan)`: off the main thread, or at once for a snapshot.
    private func bake(_ plan: WorldScenePlan, into scene: WorldScene, now: Bool) {
        if now {
            bakeGeneration += 1
            pendingBake = nil
            scene.showBackground(SceneCompositor.background(plan), background: plan.background, rect: plan.rect)
            return
        }
        if let pendingBake, pendingBakeScene === scene, pendingBake.background == plan.background,
           pendingBake.rect == plan.rect { return }
        bakeGeneration += 1
        let mine = bakeGeneration
        pendingBake = (plan.background, plan.rect)
        pendingBakeScene = scene
        Task { @MainActor [weak self, weak scene] in
            let image = await Task.detached(priority: .userInitiated) { SceneCompositor.background(plan) }.value
            guard let self, mine == self.bakeGeneration else { return }
            self.pendingBake = nil
            scene?.showBackground(image, background: plan.background, rect: plan.rect)
        }
    }
}
