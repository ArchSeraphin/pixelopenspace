import Foundation

/// Hit-testing of a scene plan to the texel (3.9): SpriteKit only tests bounding boxes, the app asks this instead.
/// Pure and deterministic; it keeps the character frames it composes, so the app keeps one tester per plan.
public struct SceneHitTester: Sendable {
    /// The nodes with a target, top first (overlay, then world, then wall, by descending order), with their image's
    /// top-left corner on the canvas.
    private let candidates: [(node: SceneNode, origin: PixelPoint)]
    /// Scene → canvas: x + offset.x, offset.y − y (décision 16).
    private let offset: PixelPoint
    /// The floor tiles the plan draws: the world.
    private let floor: Set<GridPoint>
    private let islands: [WorldScenePlan.IslandFrame]
    private var characters: [SceneCompositor.CharacterFrameKey: PixelImage] = [:]

    public init(plan: WorldScenePlan) {
        candidates = plan.nodes.reversed().compactMap { node in
            guard node.target != nil, node.width > 0, node.height > 0 else { return nil }
            return (node, plan.canvasOrigin(of: node))
        }
        offset = plan.canvasPoint(ScenePoint(x: 0, y: 0))
        floor = Set(plan.background.floor.compactMap(\.tile))
        islands = plan.islands
    }

    /// The target under a scene point (texels, y up): nodes with a target, from the top (overlay, then world, then
    /// wall, by descending order), whose opaque pixel covers the texel (frame shown at `tick`: catalog frames,
    /// character frames composed and cached, composed images); else the tile under the point: a rug →
    /// islandFloor, the hall or a corridor → floor(tile); outside the world → nil.
    public mutating func target(at point: SceneVector, tick: Int = 0) -> SceneHitTarget? {
        let cx = Int((point.x + Double(offset.x)).rounded(.down))
        let cy = Int((Double(offset.y) - point.y).rounded(.down))
        for (node, origin) in candidates {
            let (x, y) = (cx - origin.x, cy - origin.y)
            guard x >= 0, y >= 0, x < node.width, y < node.height,
                  let shown = SceneCompositor.image(of: node, tick: tick, cache: &characters),
                  x < shown.image.width, y < shown.image.height, shown.image[x, y].a != 0
            else { continue }
            return node.target
        }
        let grid = IsoMath.toGrid(x: point.x, y: point.y)
        let tile = GridPoint(Int(grid.i.rounded(.down)), Int(grid.j.rounded(.down)))
        guard floor.contains(tile) else { return nil }
        if let island = islands.first(where: { $0.rug.contains(tile) }) {
            return .islandFloor(island.projectID, part: island.part)
        }
        return .floor(tile)
    }
}
