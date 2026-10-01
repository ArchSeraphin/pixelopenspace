import AppKit
import Foundation
import Observation
import PixelCore

/// Keeps the scene equal to the core's plan of the model (3.9): it observes the workspace, the runtimes, the board,
/// the selection, the clock, the settings, the interaction state and the overview zoom; the changes of one run-loop
/// turn give one plan (`ScenePlanner.plan`), whose diff from the last one is applied only when it is not empty. The
/// characters a plan needs are composed off the main actor before it is applied, the background baked off the main
/// thread when it changes. Never a night scene at this step (décision 4).
///
/// The scene lives (task 11, 7.4.4): each plan applied is compared with the previous one (`WorldEvents.between`).
/// An agent that appears walks from the elevator (`ArrivalAnimator`: left out of the plan before it is applied, so
/// that its avatar never shows at its seat first), one that leaves walks to it, a confirmed end of turn celebrates,
/// a standing agent sits down, an agent at rest stretches or drinks a coffee now and then (`TransitionPlayer`), the
/// furniture of a new island or of new desks falls (`FurnitureDropAnimator`). Nothing of this with Reduce Motion
/// (changes are instant), nor in the snapshot harness, whose hooks `arrival` and `islandDrop` pose a frozen
/// animation instead. A new scene, or the coordinator stopped, ends every animation.
@MainActor
final class WorldSceneCoordinator {
    static let snapshotOwner = "tâche 11"

    private let model: AppModel
    private weak var workbench: WorkbenchState?
    /// The stage owns the coordinator; weak, because a plan waiting for its characters may outlive the window.
    private weak var stage: WorldStage?

    /// One-shots of the avatars (celebrate, sitDown, gestures at rest; grab after a drop, task 12).
    let transitions: TransitionPlayer
    let arrivals: ArrivalAnimator
    let drops: FurnitureDropAnimator

    private var isRunning = false
    private var isScheduled = false
    /// The live observation (a stopped then restarted coordinator never keeps two).
    private var observation = 0
    /// Each plan has its number; an older one whose characters arrive late is not applied.
    private var generation = 0
    /// What the attached scene shows, and the input it was planned from (the world events of the next plan).
    private weak var appliedScene: WorldScene?
    private var appliedPlan: WorldScenePlan?
    private var appliedInput: SceneInput?
    /// The background baking off the main thread, and its number (a newer bake drops an older result).
    private var bakeGeneration = 0
    private var pendingBake: (background: SceneBackground, rect: GridRect)?
    private weak var pendingBakeScene: WorldScene?

    /// Snapshots: a frozen animation lasts while the camera and the model stay as they were when it was posed.
    private struct FrozenStamp: Equatable {
        var pose: CameraPose
        var workspace: Workspace
        var runtimes: [AgentID: AgentRuntime]
        var board: TaskBoardState
    }

    private var frozenStamp: FrozenStamp?

    init(model: AppModel, workbench: WorkbenchState, stage: WorldStage) {
        self.model = model
        self.workbench = workbench
        self.stage = stage
        transitions = TransitionPlayer(stage: stage)
        arrivals = ArrivalAnimator(stage: stage, transitions: transitions)
        drops = FurnitureDropAnimator(stage: stage)
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        registerSnapshotHooks()
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
        cancelAnimations()
    }

    /// A new scene: the whole plan goes into it; the animations of the old one end (nothing animates on the first
    /// plan of a scene).
    func sceneAttached() {
        cancelAnimations()
        appliedScene = nil
        appliedPlan = nil
        appliedInput = nil
        if isRunning { schedule() }
    }

    /// Synchronous (snapshots): plans, composes the missing characters and bakes the background on the main actor.
    func replanNow() {
        guard let stage else { return }
        expireFrozenAnimations(stage)
        generation += 1
        let planned = makePlan(stage)
        stage.registry.prepareNow(characters: Self.characterRefs(in: planned.plan))
        apply(planned, to: stage, bakeNow: true)
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
        expireFrozenAnimations(stage)
        generation += 1
        let mine = generation
        let planned = makePlan(stage)
        let refs = Self.characterRefs(in: planned.plan)
        let registry = stage.registry
        if !refs.allSatisfy(registry.hasCharacter) {
            await registry.prepare(characters: refs)
            // Composed by an earlier plan's preparation meanwhile, or not at all: whatever is missing now.
            guard mine == generation, let stage = self.stage else { return }
            registry.prepareNow(characters: refs)
            apply(planned, to: stage, bakeNow: false)
        } else {
            apply(planned, to: stage, bakeNow: false)
        }
    }

    private struct Planned {
        var plan: WorldScenePlan
        var input: SceneInput
        var options: ScenePlanOptions
    }

    private func makePlan(_ stage: WorldStage) -> Planned {
        let interaction = stage.interaction
        let reduceMotion = self.reduceMotion
        let input = SceneInput.make(workspace: model.workspace, runtimes: model.runtimes, board: model.board,
                                    now: model.now, reduceMotion: reduceMotion, selectedAgent: model.selectedAgentID,
                                    hovered: interaction.hovered, dropTarget: interaction.dropTarget,
                                    hiddenAgents: interaction.hiddenAgents)
        let options = ScenePlanOptions(overview: stage.camera.showsOverview, night: false, reduceMotion: reduceMotion)
        return Planned(plan: ScenePlanner.plan(input, options: options), input: input, options: options)
    }

    static func characterRefs(in plan: WorldScenePlan) -> Set<CharacterRef> {
        Set(plan.nodes.compactMap(WorldSceneNodes.characterRef))
    }

    // MARK: Applying

    private func apply(_ planned: Planned, to stage: WorldStage, bakeNow: Bool) {
        var plan = planned.plan
        var input = planned.input
        guard let scene = stage.scene else {
            stage.setPlan(plan, input: input)
            return
        }
        let sameScene = appliedScene === scene
        let previousPlan = sameScene ? appliedPlan : nil
        let previousInput = sameScene ? appliedInput : nil

        // The world events since the last plan applied to this scene (none on its first plan).
        let events = animates(scene) ? WorldEvents.between(previousInput, input) : []
        let walking = arrivals.walkingArrivals(events, input: input)
        if !walking.isEmpty {
            // Left out of this very plan: their avatar never shows at the seat before the walk.
            arrivals.hide(walking)
            input.hiddenAgents = stage.interaction.hiddenAgents
            plan = ScenePlanner.plan(input, options: planned.options)
        }
        let departures = arrivals.departures(events, previous: previousPlan, input: input, scene: scene)

        stage.setPlan(plan, input: input)
        let diff = plan.diff(from: previousPlan)
        if !diff.added.isEmpty || !diff.updated.isEmpty || !diff.removed.isEmpty {
            scene.apply(plan, diff: diff)
        }
        appliedScene = scene
        appliedPlan = plan
        appliedInput = input
        if scene.needsBackground(plan) {
            bake(plan, into: scene, now: bakeNow)
        }
        scene.syncCamera()

        if animates(scene) {
            play(events, walking: walking, departures: departures, previous: previousInput, input: input, plan: plan)
        }
        transitions.updateIdleGestures(input)
        arrivals.planShown()
    }

    /// Animations play in a scene that is not frozen, outside the snapshot harness, without Reduce Motion.
    private func animates(_ scene: WorldScene) -> Bool {
        !scene.isFrozen && !SnapshotHooks.shared.isEnabled && !reduceMotion
    }

    /// The events of a plan just applied (its nodes are in the scene).
    private func play(_ events: [WorldEvent], walking: [AgentID], departures: [ArrivalAnimator.Departure],
                      previous: SceneInput?, input: SceneInput, plan: WorldScenePlan) {
        var pieces: [FurnitureDropAnimator.Piece] = []
        for event in events {
            let next = (pieces.map(\.index).max() ?? -1) + 1
            switch event {
            case .islandAppeared(let project, let part):
                pieces += FurnitureDropAnimator.pieces(project: project, part: part, desks: nil, plan: plan,
                                                       layout: input.layout, firstIndex: next)
            case .desksAppeared(let project, let part, let desks):
                pieces += FurnitureDropAnimator.pieces(project: project, part: part, desks: desks, plan: plan,
                                                       layout: input.layout, firstIndex: next)
            case .turnCelebrated(let agent):
                if !input.hiddenAgents.contains(agent) { transitions.play(.celebrate, agent: agent) }
            case .agentArrived, .agentLeft:
                // Walks below; an arrival without a way from the elevator appears at once.
                break
            case .cardReceived:
                // The post-it's flight and `grab` follow a drop on the scene (task 12).
                break
            }
        }
        if !pieces.isEmpty { drops.drop(pieces) }
        if !walking.isEmpty { arrivals.startArrivals(walking, input: input) }
        if !departures.isEmpty { arrivals.startDepartures(departures, input: input) }

        // A standing agent (a session starting) sits down when the plan seats it.
        guard let previous else { return }
        for (id, agent) in input.agents {
            guard let now = agent.presentation.animation, !CharacterClip.isStanding(now),
                  previous.agents[id]?.presentation.animation == .stand,
                  !input.hiddenAgents.contains(id), !previous.hiddenAgents.contains(id) else { continue }
            transitions.play(.sitDown, agent: id)
        }
    }

    /// Ends every animation: walkers gone, every agent back in the plan, furniture in place, avatars on the plan's
    /// animation.
    private func cancelAnimations() {
        frozenStamp = nil
        transitions.cancelAll()
        arrivals.cancelAll()
        drops.cancelAll()
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
            // A walker hands its agent back once the baked shadow under its seat is there too.
            self.arrivals.planShown()
        }
    }

    // MARK: Snapshot hooks (task 11)

    /// `arrival(agent, progress)` and `islandDrop(project, progress)`: the scene posed at that fraction of the
    /// animation, frozen. The arrival's camera follows the walker (the elevator is far from most seats). The pose
    /// lasts until the camera or the model changes, or another pose replaces it.
    private func registerSnapshotHooks() {
        let hooks = SnapshotHooks.shared
        guard hooks.isEnabled else { return }
        hooks.register(.arrival, owner: Self.snapshotOwner) { [weak self] step in
            guard case .arrival(let name, let progress) = step, let self, let stage = self.stage,
                  self.sceneReady(stage), let agent = stage.agentID(named: name, in: self.model) else { return false }
            return self.poseArrival(agent, progress: progress, stage: stage)
        }
        hooks.register(.islandDrop, owner: Self.snapshotOwner) { [weak self] step in
            guard case .islandDrop(let name, let progress) = step, let self, let stage = self.stage,
                  self.sceneReady(stage), let project = stage.projectID(named: name, in: self.model) else {
                return false
            }
            return self.poseIslandDrop(project, progress: progress, stage: stage)
        }
    }

    /// The scene is on screen, planned, and its camera placed.
    private func sceneReady(_ stage: WorldStage) -> Bool {
        guard stage.view?.window != nil, stage.scene != nil else { return false }
        stage.settle()
        return stage.camera.isPlaced && stage.plan != nil
    }

    private func poseArrival(_ agent: AgentID, progress: Double, stage: WorldStage) -> Bool {
        cancelAnimations()
        stage.settle()
        guard let input = stage.input, arrivals.canWalk(agent, input: input) else { return false }
        var aim: CGPoint?
        if progress < 1 {
            arrivals.hide([agent])
            stage.settle()
            guard let hiddenInput = stage.input, let point = arrivals.pose(agent, progress: progress, input: hiddenInput)
            else { return false }
            aim = point
        } else if let seat = stage.plan?.agentSeats[agent] {
            // The walk is over: the plan shows the agent at its seat.
            aim = CGPoint(x: seat.x, y: seat.y)
        }
        if let aim {
            stage.camera.center(on: .point(SceneVector(Double(aim.x), Double(aim.y) + WorldStage.agentAim)))
            stage.settle()
        }
        frozenStamp = stamp(stage)
        return true
    }

    private func poseIslandDrop(_ project: ProjectID, progress: Double, stage: WorldStage) -> Bool {
        cancelAnimations()
        stage.settle()
        guard let plan = stage.plan, let input = stage.input else { return false }
        var pieces: [FurnitureDropAnimator.Piece] = []
        for island in input.layout.islands where island.projectID == project {
            let next = (pieces.map(\.index).max() ?? -1) + 1
            pieces += FurnitureDropAnimator.pieces(project: project, part: island.part, desks: nil, plan: plan,
                                                   layout: input.layout, firstIndex: next)
        }
        guard !pieces.isEmpty else { return false }
        drops.pose(pieces, progress: progress)
        frozenStamp = stamp(stage)
        return true
    }

    private func stamp(_ stage: WorldStage) -> FrozenStamp {
        FrozenStamp(pose: stage.camera.pose, workspace: model.workspace, runtimes: model.runtimes, board: model.board)
    }

    /// A frozen animation ends when the camera or the model moved since it was posed (the next step or scenario).
    private func expireFrozenAnimations(_ stage: WorldStage) {
        guard let frozenStamp, frozenStamp != stamp(stage) else { return }
        cancelAnimations()
    }
}
