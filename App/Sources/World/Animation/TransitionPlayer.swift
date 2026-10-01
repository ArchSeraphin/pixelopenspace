import Foundation
import PixelCore
import QuartzCore
import SpriteKit

/// The frames of one character animation in one direction, played once (décision 17: `setTexture` and waits of
/// `hold / 24` s), maybe backwards: `sitDown` backwards is `standUp` (7.4.4, "sans frame de plus").
@MainActor
struct CharacterClip {
    let ref: CharacterRef
    let reversed: Bool
    let textures: [SKTexture]
    /// Ticks per frame, in the order played.
    let holds: [Int]

    /// nil while the character's frames are not composed (`SpriteRegistry.prepare`).
    init?(_ ref: CharacterRef, reversed: Bool = false, registry: SpriteRegistry) {
        let count = ref.animation.framesPerFacing
        let textures = (0..<count).compactMap { registry.characterTexture(ref, frame: $0) }
        guard textures.count == count, count > 0 else { return nil }
        var holds = ref.animation.holds
        if holds.count != count { holds = Array(repeating: AnimationClock.ticksPerSecond / 2, count: count) }
        self.ref = ref
        self.reversed = reversed
        self.textures = reversed ? textures.reversed() : textures
        self.holds = reversed ? holds.reversed() : holds
    }

    var ticks: Int { holds.reduce(0, +) }
    var duration: TimeInterval { Double(ticks) / Double(AnimationClock.ticksPerSecond) }

    /// The frame shown `time` seconds after the start: the last one once played (a looping animation loops).
    func texture(at time: TimeInterval) -> SKTexture {
        var tick = Int((max(time, 0) * Double(AnimationClock.ticksPerSecond)).rounded(.down))
        if ref.animation.loops && !reversed && ticks > 0 { tick %= ticks }
        for (index, hold) in holds.enumerated() {
            if tick < hold { return textures[index] }
            tick -= hold
        }
        return textures[textures.count - 1]
    }

    /// Every frame once, the last one held for its hold too.
    func action() -> SKAction {
        let tick = Double(AnimationClock.ticksPerSecond)
        return .sequence(textures.indices.flatMap { index in
            [SKAction.setTexture(textures[index]), .wait(forDuration: Double(holds[index]) / tick)]
        })
    }

    /// Animations drawn standing: the others are seated (7.4.4).
    nonisolated static func isStanding(_ animation: CharacterAnimation) -> Bool {
        animation == .stand || animation == .walk
    }

    /// A direction `animation` has: `wanted`, else its opposite, else its first (as the planner chooses).
    nonisolated static func facing(_ animation: CharacterAnimation, wanted: Facing) -> Facing {
        let facings = animation.facings
        if facings.contains(wanted) { return wanted }
        return facings.contains(wanted.opposite) ? wanted.opposite : facings[0]
    }
}

/// One-shot animations of an agent's avatar (7.4.4): `celebrate` on a confirmed end of turn, `grab` for a post-it
/// received (task 12), `stretch` and `coffee` at rest, `sitDown` when a standing agent sits down. The avatar stays the
/// plan's node (`agent:<id>/avatar`): the one-shot replaces its animation, then the node gets the plan's look and
/// animation back (`PlanSpriteNode.refreshLook`). When the plan gives the avatar another look meanwhile (another
/// state), the plan wins at once (`WorldScene.apply`). Nothing plays with Reduce Motion, nor in the frozen scene of the
/// snapshot harness.
///
/// At rest (idle, not asleep), every agent stretches or drinks a coffee, in turn, every 45 to 90 s at random.
@MainActor
final class TransitionPlayer {
    /// The key of the one-shot on the avatar (the plan's animation runs under `WorldSceneNodes.animationKey`).
    static let actionKey = "transition"
    /// The pause between two gestures of an agent at rest, in seconds.
    static let idleDelay: ClosedRange<Double> = 45...90

    private weak var stage: WorldStage?
    /// The look each playing avatar had when its one-shot started.
    private var playing: [AgentID: SceneSprite] = [:]

    private struct IdleGesture {
        var due: TimeInterval
        var next: CharacterAnimation
    }

    private var idle: [AgentID: IdleGesture] = [:]
    private var idleTimer: Timer?
    private var idleTimerDue: TimeInterval?

    init(stage: WorldStage) {
        self.stage = stage
    }

    /// Plays `animation` once on the agent's avatar, then gives the node back to the plan's animation. Nothing when
    /// the agent has no avatar in the scene (offline, walking from the elevator) or animations are off.
    func play(_ animation: CharacterAnimation, agent: AgentID) {
        guard let stage, let scene = stage.scene, canAnimate(scene),
              let sprite = Self.avatar(agent, in: scene), let shown = sprite.planNode?.sprite,
              case .character(let look, let hue, _, let facing) = shown else { return }
        let ref = CharacterRef(look: look, hue: hue, animation: animation,
                               facing: CharacterClip.facing(animation, wanted: facing))
        let registry = stage.registry
        if registry.hasCharacter(ref) {
            start(ref, agent: agent, expecting: shown)
            return
        }
        Task { @MainActor [weak self, registry] in
            await registry.prepare(characters: [ref])
            // Composed by another preparation meanwhile, or not at all: whatever is missing now.
            registry.prepareNow(characters: [ref])
            self?.start(ref, agent: agent, expecting: shown)
        }
    }

    func isPlaying(_ agent: AgentID) -> Bool {
        guard playing[agent] != nil, let scene = stage?.scene, let sprite = Self.avatar(agent, in: scene),
              sprite.action(forKey: Self.actionKey) != nil else { return false }
        return true
    }

    /// Every avatar back to the plan's animation (a new scene, the coordinator stopped, a snapshot step).
    func cancelAll() {
        if let stage, let scene = stage.scene {
            for agent in playing.keys {
                guard let sprite = Self.avatar(agent, in: scene), sprite.action(forKey: Self.actionKey) != nil else {
                    continue
                }
                sprite.removeAction(forKey: Self.actionKey)
                sprite.refreshLook(registry: stage.registry, frozen: scene.isFrozen)
            }
        }
        playing = [:]
        idle = [:]
        stopIdleTimer()
    }

    private func start(_ ref: CharacterRef, agent: AgentID, expecting shown: SceneSprite) {
        guard let stage, let scene = stage.scene, canAnimate(scene),
              let sprite = Self.avatar(agent, in: scene), sprite.planNode?.sprite == shown,
              let clip = CharacterClip(ref, registry: stage.registry) else { return }
        sprite.removeAction(forKey: WorldSceneNodes.animationKey)
        sprite.removeAction(forKey: Self.actionKey)
        playing[agent] = shown
        let done = SKAction.run { [weak self, weak sprite] in
            MainActor.assumeIsolated {
                guard let self, let sprite else { return }
                self.finish(agent, sprite: sprite)
            }
        }
        sprite.run(.sequence([clip.action(), done]), withKey: Self.actionKey)
    }

    private func finish(_ agent: AgentID, sprite: PlanSpriteNode) {
        playing[agent] = nil
        guard let stage else { return }
        sprite.refreshLook(registry: stage.registry, frozen: stage.scene?.isFrozen ?? false)
    }

    private func canAnimate(_ scene: WorldScene) -> Bool {
        !scene.isFrozen && !SnapshotHooks.shared.isEnabled && !(stage?.coordinator?.reduceMotion ?? false)
    }

    static func avatar(_ agent: AgentID, in scene: WorldScene) -> PlanSpriteNode? {
        scene.node(for: SceneNodeID("agent:\(agent)/avatar")) as? PlanSpriteNode
    }

    // MARK: Gestures at rest

    /// Keeps a gesture due for every agent at rest in `input` (idle, not asleep, seated, shown), and only for them.
    func updateIdleGestures(_ input: SceneInput) {
        guard let scene = stage?.scene, canAnimate(scene) else {
            idle = [:]
            stopIdleTimer()
            return
        }
        let now = CACurrentMediaTime()
        var kept: [AgentID: IdleGesture] = [:]
        for (id, agent) in input.agents where Self.isAtRest(agent) && !input.hiddenAgents.contains(id) {
            kept[id] = idle[id] ?? IdleGesture(due: now + Double.random(in: Self.idleDelay),
                                               next: Bool.random() ? .stretch : .coffee)
        }
        idle = kept
        scheduleIdleTimer()
    }

    static func isAtRest(_ agent: SceneAgent) -> Bool {
        let p = agent.presentation
        return p.kind == .idle && !p.asleep && p.animation == .sitIdle
    }

    /// One timer, at the earliest gesture due (kept while that time does not change: the scene plans every second).
    private func scheduleIdleTimer() {
        let due = idle.values.map(\.due).min()
        if idleTimer != nil && due == idleTimerDue { return }
        idleTimer?.invalidate()
        idleTimer = nil
        idleTimerDue = due
        guard let due else { return }
        let delay = max(0.05, due - CACurrentMediaTime())
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTimerFired() }
        }
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        idleTimerDue = nil
    }

    private func idleTimerFired() {
        idleTimer = nil
        idleTimerDue = nil
        let now = CACurrentMediaTime()
        let shown = stage?.view.map { !$0.isPaused && $0.window != nil } ?? false
        for (id, gesture) in idle where gesture.due <= now {
            // Hidden window: no gesture, the next one comes later.
            if shown && !isPlaying(id) { play(gesture.next, agent: id) }
            idle[id] = IdleGesture(due: now + Double.random(in: Self.idleDelay),
                                   next: gesture.next == .stretch ? .coffee : .stretch)
        }
        scheduleIdleTimer()
    }
}
