import CoreGraphics
import PixelCore
import SwiftUI

/// One agent's dot on the minimap: the glyph of its state (`minimap.dot.<state>`), never its colour alone (7.9).
/// The drop task reads `agentID` (a post-it held over a dot goes to that agent) and `center`.
struct MinimapDot: Hashable, Sendable, Identifiable {
    var agentID: AgentID
    var kind: AgentStateKind
    /// The seat's point (where the dot's anchor goes), in points from the minimap's top-left corner (its frame
    /// included), multiples of 2.
    var center: CGPoint

    var id: AgentID { agentID }
}

/// The minimap (6(a), 3.9), bottom right of the scene, while the world is not entirely visible: the frame
/// `minimap.frame` in 9-slice, the islands as blocks of their project's light tone, one dot per agent, and the
/// visible part of the world (`minimap.viewport`). A click flies the camera there, a drag moves it at once. Everything
/// at 2 pt per texel, never smoothed.
struct MinimapView: View {
    /// Texels of the frame around the map (`HUDSprites.minimapFrameInsets`).
    static let frameInset = 4
    /// Points the pointer moves before a press becomes a drag.
    static let dragThreshold: CGFloat = 3

    let stage: WorldStage

    @Environment(AppModel.self) private var model
    @State private var isDragging = false

    init(stage: WorldStage) {
        self.stage = stage
    }

    var body: some View {
        let camera = stage.camera
        if camera.needsMinimap, let map = MinimapRenderer.shared.content(world: camera.world, hud: WorldHUD.shared,
                                                                          model: model) {
            ZStack(alignment: .topLeading) {
                SpriteImage(image: map.base)
                ForEach(map.dots) { dot in
                    let key = HUDSprites.minimapDotKey(dot.kind)
                    let anchor = Self.anchorPoints(of: key)
                    SpriteImage(key)
                        .offset(x: dot.center.x - anchor.x, y: dot.center.y - anchor.y)
                        .accessibilityHidden(true)
                }
                MinimapViewport(camera: camera, layout: map.layout)
            }
            .frame(width: map.size.width, height: map.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drag(map.layout))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mini-carte")
            .accessibilityHint("Montre la partie visible de l'open space ; un clic y déplace la vue")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Tout voir") { camera.fitAll(animated: true) }
            .help("Mini-carte : clic pour y aller, glisser pour déplacer la vue")
        }
    }

    /// A sprite's anchor in points from its top-left corner (`minimap.dot.*`: 5 × 5 texels, anchor (2, 2)).
    static func anchorPoints(of key: SpriteKey) -> CGPoint {
        guard let anchor = SpriteCatalog.sprite(key)?.anchor else { return .zero }
        return CGPoint(x: CGFloat(anchor.x) * SpriteImage.pointsPerTexel, y: CGFloat(anchor.y) * SpriteImage.pointsPerTexel)
    }

    /// Press then release without moving: a flight to that point; past `dragThreshold`: the view's centre follows
    /// the pointer.
    private func drag(_ layout: MinimapLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height)
                guard isDragging || moved >= Self.dragThreshold else { return }
                isDragging = true
                stage.camera.center(on: .point(Self.scenePoint(at: value.location, layout: layout)))
                stage.view?.noteInteraction()
            }
            .onEnded { value in
                defer { isDragging = false }
                guard !isDragging else { return }
                stage.camera.fly(to: .point(Self.scenePoint(at: value.location, layout: layout)))
                stage.view?.noteInteraction()
            }
    }

    /// The scene point under a point of the minimap (its frame included), clamped to the map.
    static func scenePoint(at location: CGPoint, layout: MinimapLayout) -> SceneVector {
        let inset = Double(frameInset) * Double(SpriteImage.pointsPerTexel)
        let x = min(max(Double(location.x) - inset, 0), layout.width)
        let y = min(max(Double(location.y) - inset, 0), layout.height)
        return layout.scenePoint(at: SceneVector(x, y))
    }
}

/// The visible part of the world on the minimap: `minimap.viewport` in 9-slice, redrawn as the camera moves.
private struct MinimapViewport: View {
    let camera: WorldCamera
    let layout: MinimapLayout

    var body: some View {
        let box = layout.viewport(pose: camera.pose, view: camera.view)
        if let image = MinimapRenderer.shared.viewport(width: box.width, height: box.height) {
            let ppt = Double(SpriteImage.pointsPerTexel)
            let inset = Double(MinimapView.frameInset) * ppt
            // A box narrower than the 9-slice's corners keeps their size, inside the map.
            let width = Double(image.width) * ppt, height = Double(image.height) * ppt
            let x = min(box.minX, max(layout.width - width, 0)), y = min(box.minY, max(layout.height - height, 0))
            SpriteImage(image: image)
                .offset(x: inset + x, y: inset + y)
                .allowsHitTesting(false)
        }
    }
}

/// The minimap's pictures: the frame and the islands, composed when the world, the islands or their hues change
/// (texels, 2 pt each); the viewport's 9-slice, by size. The dots are placed by the view.
@MainActor
final class MinimapRenderer {
    static let shared = MinimapRenderer()

    /// What the view draws.
    struct Content {
        var layout: MinimapLayout
        /// The frame and the islands, one pixel per texel.
        var base: CGImage
        var dots: [MinimapDot]
        /// Points, frame included.
        var size: CGSize
    }

    private struct BaseKey: Equatable {
        var layout: MinimapLayout
        var islands: [WorldScenePlan.IslandFrame]
        var hues: [ProjectID: Int]
    }

    private var base: (key: BaseKey, image: CGImage)?
    private var viewports: [Int: CGImage] = [:]

    private init() {}

    /// Nil before the first plan, or when the world is empty.
    func content(world: SceneBox, hud: WorldHUD, model: AppModel) -> Content? {
        guard world.width > 0, world.height > 0 else { return nil }
        let layout = Minimap.layout(world: world)
        var hues: [ProjectID: Int] = [:]
        for island in hud.islands { hues[island.projectID] = model.project(island.projectID)?.hueIndex ?? 0 }
        let key = BaseKey(layout: layout, islands: hud.islands, hues: hues)
        let image: CGImage
        if let base, base.key == key {
            image = base.image
        } else {
            guard let composed = Self.composeBase(layout: layout, islands: hud.islands, hues: hues).cgImage() else {
                return nil
            }
            base = (key, composed)
            image = composed
        }
        let ppt = Double(SpriteImage.pointsPerTexel)
        let inset = Double(MinimapView.frameInset) * ppt
        var dots: [MinimapDot] = []
        for agent in model.agentsInOrder {
            guard let seat = hud.seats[agent.id] else { continue }
            let kind = model.runtime(for: agent.id)?.kind ?? .offline
            let point = layout.point(of: SceneVector(Double(seat.x), Double(seat.y)))
            dots.append(MinimapDot(agentID: agent.id, kind: kind, center: CGPoint(x: inset + point.x, y: inset + point.y)))
        }
        // The most urgent on top.
        dots.sort { $0.kind.urgency < $1.kind.urgency }
        let size = CGSize(width: Double(image.width) * ppt, height: Double(image.height) * ppt)
        return Content(layout: layout, base: image, dots: dots, size: size)
    }

    /// The viewport's 9-slice for a box of `width` × `height` minimap points (at least its corners).
    func viewport(width: Double, height: Double) -> CGImage? {
        guard let def = SpriteCatalog.sprite(SpriteKey("minimap.viewport")), let source = def.frames.first else {
            return nil
        }
        let insets = HUDSprites.minimapViewportInsets
        let w = max(Int((width / Double(SpriteImage.pointsPerTexel)).rounded()), insets.left + insets.right)
        let h = max(Int((height / Double(SpriteImage.pointsPerTexel)).rounded()), insets.top + insets.bottom)
        let key = w << 16 | h
        if let cached = viewports[key] { return cached }
        guard let image = source.nineSlice(insets: insets, width: w, height: h).cgImage() else { return nil }
        if viewports.count >= 16 { viewports.removeAll(keepingCapacity: true) }
        viewports[key] = image
        return image
    }

    /// `minimap.frame` around the map, and every texel of the map whose centre falls on an island's rug in the
    /// light tone of its project, its border in the dark tone (a block that reads on the frame's ground).
    static func composeBase(layout: MinimapLayout, islands: [WorldScenePlan.IslandFrame],
                            hues: [ProjectID: Int]) -> PixelImage {
        let ppt = Double(SpriteImage.pointsPerTexel)
        let mapWidth = Int(layout.width / ppt), mapHeight = Int(layout.height / ppt)
        let inset = MinimapView.frameInset
        let insets = HUDSprites.minimapFrameInsets
        var image: PixelImage
        if let frame = SpriteCatalog.sprite(SpriteKey("minimap.frame"))?.frames.first {
            image = frame.nineSlice(insets: insets, width: mapWidth + 2 * inset, height: mapHeight + 2 * inset)
        } else {
            image = PixelImage(width: mapWidth + 2 * inset, height: mapHeight + 2 * inset, fill: Palette.color(.ink))
        }
        // Which island covers each texel of the map (index into `islands`), then fill and border.
        var owner = [Int](repeating: -1, count: mapWidth * mapHeight)
        for y in 0..<mapHeight {
            for x in 0..<mapWidth {
                let scene = layout.scenePoint(at: SceneVector((Double(x) + 0.5) * ppt, (Double(y) + 0.5) * ppt))
                let grid = IsoMath.toGrid(x: scene.x, y: scene.y)
                let tile = GridPoint(Int(grid.i.rounded(.down)), Int(grid.j.rounded(.down)))
                if let index = islands.firstIndex(where: { $0.rug.contains(tile) }) { owner[y * mapWidth + x] = index }
            }
        }
        func ownerAt(_ x: Int, _ y: Int) -> Int {
            guard x >= 0, y >= 0, x < mapWidth, y < mapHeight else { return -1 }
            return owner[y * mapWidth + x]
        }
        for y in 0..<mapHeight {
            for x in 0..<mapWidth {
                let index = owner[y * mapWidth + x]
                guard index >= 0 else { continue }
                let tones = Palette.hue(hues[islands[index].projectID] ?? 0)
                let border = ownerAt(x - 1, y) != index || ownerAt(x + 1, y) != index || ownerAt(x, y - 1) != index
                    || ownerAt(x, y + 1) != index
                image[inset + x, inset + y] = border ? tones.dark : tones.light
            }
        }
        return image
    }
}
