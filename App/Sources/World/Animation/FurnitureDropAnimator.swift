import Foundation
import PixelCore
import SpriteKit

/// The furniture of a new island, or of the desks its rug gained, falls into place (7.4.4, 7.4.8): desk, chair,
/// monitor, lamp and everything on the desk fall together from 48 texels in 0.35 s (`SnappedMove.fall`, whole texels
/// at every frame), one post 0.08 s after the other, with a puff of dust (`fx.dust`) under the desk and the chair on
/// landing. A new island's sign comes down with its first post, its plant with the last. An agent already at a
/// falling post rides its chair down (an arriving one walks from the elevator meanwhile: hidden). Its floor marks
/// (selection, hover, drop target) and lights stay on the floor. The nodes are the plan's: only their position
/// moves, and the plan's place is where they land.
@MainActor
final class FurnitureDropAnimator {
    static let height: CGFloat = 48
    static let duration: TimeInterval = 0.35
    static let stagger: TimeInterval = 0.08
    static let dropKey = "drop"

    /// One post (or a sign, a plant): its nodes fall together, then dust rises from `dust`.
    struct Piece: Hashable, Sendable {
        var nodes: [SceneNodeID]
        var dust: [GridPoint]
        /// Its place in the fall: starts `index · stagger` after the first.
        var index: Int
    }

    private weak var stage: WorldStage?
    /// The nodes moved by a fall, for `cancelAll`.
    private var moved: Set<SceneNodeID> = []
    private var dustNodes: [SKSpriteNode] = []

    init(stage: WorldStage) {
        self.stage = stage
    }

    static var dustDuration: TimeInterval {
        let ticks = SpriteCatalog.sprite(SpriteKey("fx.dust"))?.holds.reduce(0, +) ?? 12
        return Double(ticks) / Double(AnimationClock.ticksPerSecond)
    }

    /// The pieces of an island part, from its plan: every desk (`desks` nil: a new island, with its sign and its
    /// plant) or only these desk indices (the rug grew), by index.
    static func pieces(project: ProjectID, part: Int, desks: [Int]?, plan: WorldScenePlan,
                       layout: WorldLayoutResult, firstIndex: Int = 0) -> [Piece] {
        guard let island = layout.islands.first(where: { $0.projectID == project && $0.part == part }) else { return [] }
        let wanted = desks.map(Set.init)
        let posts = island.desks.filter { wanted?.contains($0.index) ?? true }.sorted { $0.index < $1.index }
        var pieces: [Piece] = []
        for (k, desk) in posts.enumerated() {
            let post = "post:\(project)/\(desk.index)/"
            let agent = desk.agentID.map { "agent:\($0)/" }
            let ids = plan.nodes.filter { node in
                guard node.layer == .world || node.layer == .overlay else { return false }
                let raw = node.id.rawValue
                if raw.hasPrefix(post) {
                    let role = raw.dropFirst(post.count)
                    return !role.hasPrefix("hover/") && !role.hasPrefix("drop/")
                }
                if let agent, raw.hasPrefix(agent) { return raw.dropFirst(agent.count) != "selection" }
                return false
            }.map(\.id)
            pieces.append(Piece(nodes: ids, dust: [desk.deskTile, desk.seatTile], index: firstIndex + k))
        }
        if desks == nil {
            let prefix = "island:\(project)/\(part)/"
            let last = firstIndex + max(posts.count - 1, 0)
            for (role, tile, index) in [("sign", island.sign, firstIndex), ("plant", island.plant, last)] {
                let id = SceneNodeID(prefix + role)
                guard plan.node(id) != nil else { continue }
                pieces.append(Piece(nodes: [id], dust: [tile], index: index))
            }
        }
        return pieces
    }

    /// Seconds from the first post's start to the last landing.
    static func fallDuration(_ pieces: [Piece]) -> TimeInterval {
        let last = pieces.map(\.index).max() ?? 0
        return Double(last) * stagger + duration
    }

    /// Seconds from the first post's start to the last dust.
    static func totalDuration(_ pieces: [Piece]) -> TimeInterval {
        fallDuration(pieces) + dustDuration
    }

    // MARK: Live

    /// Drops `pieces` now (their nodes are in the scene, at their place in the plan).
    func drop(_ pieces: [Piece]) {
        guard let stage, let scene = stage.scene, let plan = stage.plan else { return }
        let registry = stage.registry
        for piece in pieces {
            let delay = Double(piece.index) * Self.stagger
            for id in piece.nodes {
                guard let sprite = scene.node(for: id), let rest = plan.node(id)?.position else { continue }
                let place = CGPoint(x: rest.x, y: rest.y)
                sprite.removeAction(forKey: Self.dropKey)
                moved.insert(id)
                // Out of sight until its turn, then held up there for the first frame of its fall.
                sprite.alpha = 0
                sprite.position = CGPoint(x: place.x, y: place.y + Self.height)
                let appear = SKAction.run { [weak sprite] in
                    MainActor.assumeIsolated {
                        sprite?.alpha = 1
                        sprite?.position = CGPoint(x: place.x, y: place.y + Self.height)
                    }
                }
                let land = SKAction.run { [weak self] in
                    MainActor.assumeIsolated { _ = self?.moved.remove(id) }
                }
                sprite.run(.sequence([.wait(forDuration: delay), appear,
                                      SnappedMove.fall(from: Self.height, duration: Self.duration, onto: place), land]),
                           withKey: Self.dropKey)
            }
            for tile in piece.dust {
                guard let dust = makeDust(on: tile, registry: registry) else { continue }
                dust.alpha = 0
                scene.addEffect(dust)
                var steps: [SKAction] = [.wait(forDuration: delay + Self.duration), .run { [weak dust] in
                    MainActor.assumeIsolated { dust?.alpha = 1 }
                }]
                if let frames = registry.action(SpriteKey("fx.dust"), tickOffset: 0) { steps.append(frames) }
                steps.append(.wait(forDuration: 1.0 / Double(AnimationClock.ticksPerSecond) * 2))
                steps.append(.run { [weak self, weak dust] in
                    MainActor.assumeIsolated {
                        guard let dust else { return }
                        dust.removeFromParent()
                        self?.dustNodes.removeAll { $0 === dust }
                    }
                })
                dust.run(.sequence(steps))
            }
        }
        noteEnergy(for: Self.totalDuration(pieces))
    }

    // MARK: Snapshots

    /// The fall frozen at `progress` (0…1) from the first post's start to the last post's landing (its dust just
    /// rising at 1).
    func pose(_ pieces: [Piece], progress: Double) {
        guard let stage, let scene = stage.scene, let plan = stage.plan else { return }
        let registry = stage.registry
        let t = min(max(progress, 0), 1) * Self.fallDuration(pieces)
        let dustDef = SpriteCatalog.sprite(SpriteKey("fx.dust"))
        for piece in pieces {
            let local = t - Double(piece.index) * Self.stagger
            for id in piece.nodes {
                guard let sprite = scene.node(for: id), let rest = plan.node(id)?.position else { continue }
                sprite.removeAction(forKey: Self.dropKey)
                moved.insert(id)
                let lift = SnappedMove.fallHeight(Self.height, progress: local / Self.duration)
                sprite.alpha = local < 0 ? 0 : 1
                sprite.position = CGPoint(x: CGFloat(rest.x), y: CGFloat(rest.y) + lift)
            }
            let dustTime = local - Self.duration
            guard dustTime >= 0, dustTime < Self.dustDuration, let dustDef else { continue }
            let frame = dustDef.frameIndex(atTick: Int((dustTime * Double(AnimationClock.ticksPerSecond)).rounded(.down)))
            for tile in piece.dust {
                guard let dust = makeDust(on: tile, registry: registry, frame: frame) else { continue }
                scene.addEffect(dust)
            }
        }
    }

    /// Everything back at its place in the plan, no dust left (a new scene, a snapshot step).
    func cancelAll() {
        if let scene = stage?.scene {
            for id in moved {
                guard let sprite = scene.node(for: id) as? PlanSpriteNode else { continue }
                sprite.removeAction(forKey: Self.dropKey)
                sprite.alpha = 1
                if let rest = sprite.planNode?.position {
                    sprite.position = CGPoint(x: CGFloat(rest.x), y: CGFloat(rest.y))
                }
            }
        }
        moved = []
        for dust in dustNodes { dust.removeFromParent() }
        dustNodes = []
    }

    // MARK: Helpers

    /// A puff of dust centred on `tile`, in front of what stands there.
    private func makeDust(on tile: GridPoint, registry: SpriteRegistry, frame: Int = 0) -> SKSpriteNode? {
        let key = SpriteKey("fx.dust")
        guard let def = SpriteCatalog.sprite(key), let texture = registry.texture(key, frame: frame) else { return nil }
        let dust = SKSpriteNode(texture: texture, color: .clear, size: CGSize(width: def.width, height: def.height))
        dust.name = "dust:\(tile.i),\(tile.j)"
        dust.anchorPoint = CGPoint(x: Double(def.anchor.x) / Double(def.width),
                                   y: 1 - Double(def.anchor.y) / Double(def.height))
        dust.blendMode = .alpha
        dust.position = GridSpot(centreOf: tile).scenePoint
        dust.zPosition = SceneDepth.world(tile: tile, level: .overlay, place: 7)
        dustNodes.append(dust)
        return dust
    }

    /// 60 frames per second while things fall.
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
