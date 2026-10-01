import AppKit
import Foundation
import PixelCore
import SpriteKit

/// After a post-it is dropped on the scene (3.9, 6(k)): a `desk.postit` of its project's hue flies from where it was
/// let go to the agent's desk (`SnappedMove`: whole texels at every frame, 7.3), the agent takes it (`grab`,
/// `TransitionPlayer`), then the pin goes in (`fx.pinDrop`) on its screen. A new agent (it arrives by the elevator)
/// takes nothing: the pin goes in on its desk. Nothing of this with Reduce Motion, nor in the frozen scene of the
/// snapshot harness.
@MainActor
final class PostitFlight {
    /// Texels per second of the flight, and the bounds of its duration.
    static let speed: CGFloat = 480
    static let shortest: TimeInterval = 0.25
    static let longest: TimeInterval = 0.5
    /// Texels above the desk's tile centre where the post-it lands: the screen, over the desk top.
    static let landingHeight = IsoMath.deskTopHeight + 12

    private weak var stage: WorldStage?
    /// The post-its in flight and the pins going in.
    private var nodes: [SKNode] = []

    init(stage: WorldStage) {
        self.stage = stage
    }

    /// From `start` (scene texels) to the desk of `outcome`.
    func fly(from start: SceneVector, to outcome: DropIntents.Outcome) {
        guard let stage, let scene = stage.scene, let plan = stage.plan, canAnimate(scene),
              let desk = plan.node(SceneNodeID("post:\(outcome.projectID)/\(outcome.deskIndex)/desk")) else { return }
        let registry = stage.registry
        let key = Self.postitKey(outcome.hueIndex)
        guard let def = SpriteCatalog.sprite(key), let texture = registry.texture(key, frame: 0) else { return }
        let from = CGPoint(x: start.x.rounded(), y: start.y.rounded())
        let to = CGPoint(x: CGFloat(desk.position.x), y: CGFloat(desk.position.y + Self.landingHeight))
        let postit = SKSpriteNode(texture: texture, color: .clear, size: CGSize(width: def.width, height: def.height))
        postit.name = "drop:postit"
        postit.anchorPoint = Self.anchorPoint(def)
        postit.blendMode = .alpha
        postit.position = from
        // Over the whole world while it flies.
        postit.zPosition = CGFloat(SceneLayer.overlay.zBase + SceneLayer.overlay.orderLimit - 1)
        scene.addEffect(postit)
        nodes.append(postit)

        let distance = hypot(to.x - from.x, to.y - from.y)
        let duration = min(max(Double(distance / Self.speed), Self.shortest), Self.longest)
        let speed = duration > 0 ? distance / CGFloat(duration) : Self.speed
        let agentID = outcome.agentID, isNew = outcome.isNew
        let landed = SKAction.run { [weak self, weak postit] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let postit { self.remove(postit) }
                self.landed(at: to, agent: isNew ? nil : agentID)
            }
        }
        postit.run(.sequence([SnappedMove.along([from, to], speed: speed), landed]))
        noteEnergy(for: duration + Self.grabDuration + Self.pinDuration)
    }

    /// Every flight and pin gone (the view left its window).
    func cancelAll() {
        for node in nodes { node.removeFromParent() }
        nodes = []
    }

    // MARK: Steps

    /// The agent takes the post-it, then the pin goes in on its screen.
    private func landed(at point: CGPoint, agent: AgentID?) {
        guard let stage else { return }
        var delay: TimeInterval = 0
        if let agent, let transitions = stage.coordinator?.transitions {
            transitions.play(.grab, agent: agent)
            delay = Self.grabDuration
        }
        guard let scene = stage.scene else { return }
        let key = SpriteKey("fx.pinDrop")
        guard let def = SpriteCatalog.sprite(key), let texture = stage.registry.texture(key, frame: 0) else { return }
        let pin = SKSpriteNode(texture: texture, color: .clear, size: CGSize(width: def.width, height: def.height))
        pin.name = "drop:pin"
        pin.anchorPoint = Self.anchorPoint(def)
        pin.blendMode = .alpha
        pin.position = point
        pin.zPosition = CGFloat(SceneLayer.overlay.zBase + SceneLayer.overlay.orderLimit - 1)
        pin.alpha = 0
        scene.addEffect(pin)
        nodes.append(pin)
        var steps: [SKAction] = [.wait(forDuration: delay), .run { [weak pin] in
            MainActor.assumeIsolated { pin?.alpha = 1 }
        }]
        if let frames = stage.registry.action(key, tickOffset: 0) {
            steps.append(frames)
        }
        steps.append(.wait(forDuration: Self.pinDuration))
        steps.append(.run { [weak self, weak pin] in
            MainActor.assumeIsolated {
                guard let self, let pin else { return }
                self.remove(pin)
            }
        })
        pin.run(.sequence(steps))
    }

    private func remove(_ node: SKNode) {
        node.removeFromParent()
        nodes.removeAll { $0 === node }
    }

    // MARK: Helpers

    /// `grab` played once (seconds at 24 ticks per second).
    static var grabDuration: TimeInterval {
        Double(CharacterAnimation.grab.holds.reduce(0, +)) / Double(AnimationClock.ticksPerSecond)
    }

    /// `fx.pinDrop` played once, plus a beat on its last frame.
    static var pinDuration: TimeInterval {
        let ticks = SpriteCatalog.sprite(SpriteKey("fx.pinDrop"))?.holds.reduce(0, +) ?? 6
        return Double(ticks + 4) / Double(AnimationClock.ticksPerSecond)
    }

    /// `desk.postit~hueN`, or `~paper` for a card without a project's hue (as the plan draws it on a monitor).
    static func postitKey(_ hue: Int) -> SpriteKey {
        SpriteKey("desk.postit", variant: (0..<Palette.projectHues.count).contains(hue) ? "hue\(hue)" : "paper")
    }

    /// The sprite's anchor (pixels from its top-left corner) as SpriteKit's unit point (y up).
    private static func anchorPoint(_ def: SpriteDef) -> CGPoint {
        CGPoint(x: Double(def.anchor.x) / Double(def.width), y: 1 - Double(def.anchor.y) / Double(def.height))
    }

    private func canAnimate(_ scene: WorldScene) -> Bool {
        !scene.isFrozen && !SnapshotHooks.shared.isEnabled && !(stage?.coordinator?.reduceMotion ?? false)
    }

    /// 60 frames per second while the post-it flies and the pin goes in.
    private func noteEnergy(for duration: TimeInterval) {
        guard let view = stage?.view else { return }
        view.noteInteraction()
        let renewals = Int((duration / WorldView.interactionHold).rounded(.down))
        guard renewals > 0 else { return }
        for k in 1...renewals {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * WorldView.interactionHold * 0.9) {
                [weak view] in
                MainActor.assumeIsolated { view?.noteInteraction() }
            }
        }
    }
}
