import Foundation
import PixelCore
import SpriteKit

/// A sprite of the scene and the plan node it shows.
final class PlanSpriteNode: SKSpriteNode {
    private(set) var planNode: SceneNode?

    /// The texture, the animation, the anchor, the position and the depth of `node` (7.3: whole texels from the
    /// plan, never computed here). A node keeps its texture and its running animation while its sprite and clock
    /// offset stay the same.
    func show(_ node: SceneNode, registry: SpriteRegistry, frozen: Bool) {
        let old = planNode
        planNode = node
        if old?.sprite != node.sprite || old?.tickOffset != node.tickOffset || old == nil {
            WorldSceneNodes.setLook(of: self, to: node, registry: registry, frozen: frozen)
        }
        size = CGSize(width: node.width, height: node.height)
        anchorPoint = WorldSceneNodes.anchorPoint(node)
        position = CGPoint(x: node.position.x, y: node.position.y)
        zPosition = CGFloat(node.zOrder)
    }

    /// The look again (the textures it waited for are there, or the scene froze or thawed).
    func refreshLook(registry: SpriteRegistry, frozen: Bool) {
        guard let node = planNode else { return }
        WorldSceneNodes.setLook(of: self, to: node, registry: registry, frozen: frozen)
    }

    /// Waiting for a character's frames.
    var lacksTexture: Bool { texture == nil }
}

/// How a `SceneNode` of the core's plan becomes a SpriteKit sprite.
@MainActor
enum WorldSceneNodes {
    static let animationKey = "plan.animation"

    /// `(ax / w, 1 − ay / h)`: the plan's anchor (px from the top-left) in SpriteKit's unit square (y up).
    static func anchorPoint(_ node: SceneNode) -> CGPoint {
        guard node.width > 0, node.height > 0 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: Double(node.anchor.x) / Double(node.width),
                       y: 1 - Double(node.anchor.y) / Double(node.height))
    }

    /// The character of a node, if it shows one.
    static func characterRef(_ node: SceneNode) -> CharacterRef? {
        guard case .character(let look, let hue, let animation, let facing) = node.sprite else { return nil }
        return CharacterRef(look: look, hue: hue, animation: animation, facing: facing)
    }

    /// Texture and animation. Frozen (snapshots): the frame of the software render at tick 0 (`tickOffset` applied),
    /// no action. Otherwise that frame first, then the animation from the same offset.
    static func setLook(of sprite: PlanSpriteNode, to node: SceneNode, registry: SpriteRegistry, frozen: Bool) {
        sprite.removeAction(forKey: animationKey)
        var texture: SKTexture?
        var action: SKAction?
        switch node.sprite {
        case .sprite(let key, let frame):
            if let frame {
                texture = registry.texture(key, frame: frame)
            } else {
                texture = registry.texture(key, frame: registry.frameIndex(key, atTick: node.tickOffset))
                if !frozen { action = registry.action(key, tickOffset: node.tickOffset) }
            }
        case .character:
            guard let ref = characterRef(node) else { break }
            texture = registry.characterTexture(ref, frame: registry.characterFrameIndex(ref, atTick: node.tickOffset))
            if !frozen { action = registry.characterAction(ref, tickOffset: node.tickOffset) }
        case .image(let image, _):
            texture = registry.texture(for: image)
        }
        sprite.texture = texture
        // A sprite without its texture (a character still being composed) stays hidden, never a coloured square.
        sprite.isHidden = texture == nil
        sprite.color = .clear
        sprite.colorBlendFactor = 0
        if let action { sprite.run(action, withKey: animationKey) }
    }

    /// A new sprite for `node`.
    static func make(_ node: SceneNode, registry: SpriteRegistry, frozen: Bool) -> PlanSpriteNode {
        let sprite = PlanSpriteNode(texture: nil, color: .clear, size: CGSize(width: node.width, height: node.height))
        sprite.name = node.id.rawValue
        sprite.blendMode = .alpha
        sprite.show(node, registry: registry, frozen: frozen)
        return sprite
    }
}
