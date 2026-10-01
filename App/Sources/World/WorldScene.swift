import AppKit
import Foundation
import PixelCore
import QuartzCore
import SpriteKit

/// The open space in SpriteKit (3.9): one sprite per node of the core's plan, reconciled by identifier, over the
/// baked background in tiles of at most 1024 × 1024 texels. One scene unit is one texel, y up (décision 16); the
/// camera's scale is `CameraMath.cameraScale(zoom)` (`.resizeFill`: one unit per point at scale 1).
final class WorldScene: SKScene {
    /// Largest side of a background tile, in texels.
    static let backgroundTileSize = 1024

    let cameraNode = SKCameraNode()
    /// Child of the camera, over everything; hidden during captures.
    let hudLayer = SKNode()
    weak var stage: WorldStage?
    /// Snapshots: no action, every animated sprite on the frame of the software render at tick 0.
    var isFrozen = false {
        didSet {
            guard isFrozen != oldValue, let registry = stage?.registry else { return }
            for sprite in sprites.values { sprite.refreshLook(registry: registry, frozen: isFrozen) }
        }
    }

    private let content = SKNode()
    private var sprites: [SceneNodeID: PlanSpriteNode] = [:]
    private var backgroundTiles: [SKSpriteNode] = []
    /// The background now shown (what was baked, and for which canvas rect).
    private(set) var bakedBackground: SceneBackground?
    private(set) var bakedRect: GridRect?
    private var wasFlying = false

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let shade = Palette.color(.shade)
        backgroundColor = NSColor(srgbRed: Double(shade.r) / 255, green: Double(shade.g) / 255,
                                  blue: Double(shade.b) / 255, alpha: 1)
        addChild(content)
        addChild(cameraNode)
        camera = cameraNode
        // Over every layer of the plan (zOrder < 2^23).
        hudLayer.zPosition = CGFloat(1 << 24)
        cameraNode.addChild(hudLayer)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Plan

    /// Reconciliation by node id: removed sprites go, added ones come, updated ones change their texture, animation
    /// or position in place (never removed and added again). The background is the coordinator's
    /// (`showBackground`), baked off the main thread. A one-shot of `TransitionPlayer` stops when the plan gives its
    /// avatar another look (another state wins at once).
    func apply(_ plan: WorldScenePlan, diff: ScenePlanDiff) {
        guard let registry = stage?.registry else { return }
        for id in diff.removed {
            sprites.removeValue(forKey: id)?.removeFromParent()
        }
        for node in diff.added + diff.updated {
            if let sprite = sprites[node.id] {
                if sprite.planNode?.sprite != node.sprite, sprite.action(forKey: TransitionPlayer.actionKey) != nil {
                    sprite.removeAction(forKey: TransitionPlayer.actionKey)
                }
                sprite.show(node, registry: registry, frozen: isFrozen)
            } else {
                let sprite = WorldSceneNodes.make(node, registry: registry, frozen: isFrozen)
                sprites[node.id] = sprite
                content.addChild(sprite)
            }
        }
    }

    /// Sprites still waiting for a character's frames get them (after `SpriteRegistry.prepare`).
    func refreshMissingTextures() {
        guard let registry = stage?.registry else { return }
        for sprite in sprites.values where sprite.lacksTexture {
            sprite.refreshLook(registry: registry, frozen: isFrozen)
        }
    }

    func node(for id: SceneNodeID) -> SKSpriteNode? {
        sprites[id]
    }

    /// A node the scene shows besides the plan's (a walker, its shadow, the ding, dust), among the plan's sprites:
    /// its `zPosition` places it among them (`SceneDepth`). Its owner removes it.
    func addEffect(_ node: SKNode) {
        content.addChild(node)
    }

    /// One-shot animations of the avatars (task 11; a post-it received after a drop, task 12).
    var transitions: TransitionPlayer? {
        stage?.coordinator?.transitions
    }

    var spriteCount: Int { sprites.count }
    var backgroundTileCount: Int { backgroundTiles.count }

    // MARK: Background

    /// The baked background (`SceneCompositor.background(plan)`, canvas of `rect`), in tiles of at most
    /// `backgroundTileSize` texels, each placed by its top-left corner (décision 16).
    func showBackground(_ image: PixelImage, background: SceneBackground, rect: GridRect) {
        for tile in backgroundTiles { tile.removeFromParent() }
        backgroundTiles = []
        let side = Self.backgroundTileSize
        var index = 0
        for y in stride(from: 0, to: image.height, by: side) {
            for x in stride(from: 0, to: image.width, by: side) {
                let crop = PixelRect(x: x, y: y, width: min(side, image.width - x), height: min(side, image.height - y))
                let tile = SKSpriteNode(texture: SpriteRegistry.makeTexture(image.cropped(crop)), color: .clear,
                                        size: CGSize(width: crop.width, height: crop.height))
                tile.name = "background/\(index)"
                tile.anchorPoint = CGPoint(x: 0, y: 1)
                let corner = WorldScenePlan.scenePoint(PixelPoint(x, y), in: rect)
                tile.position = CGPoint(x: corner.x, y: corner.y)
                tile.zPosition = CGFloat(SceneLayer.background.zBase + index)
                tile.blendMode = .alpha
                content.addChild(tile)
                backgroundTiles.append(tile)
                index += 1
            }
        }
        bakedBackground = background
        bakedRect = rect
    }

    /// Forgets the background (a new canvas is baking): the coordinator bakes again.
    func needsBackground(_ plan: WorldScenePlan) -> Bool {
        bakedBackground != plan.background || bakedRect != plan.rect
    }

    // MARK: Camera

    /// Poses the camera node on the camera's snapped pose (every frame, and at once after a change).
    func syncCamera() {
        guard let camera = stage?.camera, camera.isPlaced else { return }
        let pose = camera.pose
        let position = CGPoint(x: pose.center.x, y: pose.center.y)
        if cameraNode.position != position { cameraNode.position = position }
        let scale = CGFloat(CameraMath.cameraScale(pose.zoom))
        if cameraNode.xScale != scale || cameraNode.yScale != scale { cameraNode.setScale(scale) }
    }

    /// Nothing else happens per frame: a flight in progress advances, then the camera is posed.
    override func didFinishUpdate() {
        guard let camera = stage?.camera else { return }
        if camera.isFlying {
            camera.advance(to: CACurrentMediaTime())
        }
        if camera.isFlying != wasFlying {
            wasFlying = camera.isFlying
            stage?.view?.updateEnergy()
        }
        syncCamera()
    }
}
