import PixelCore
import SwiftUI

/// The edge arrows (3.9, 6(k)): for each agent waiting out of view (`EdgeArrows.layout`), a small button on the
/// border of the scene, pointing toward it: `ov.edgeArrow` (up) or `ov.edgeArrow~diagonal` (up-right) turned by
/// quarter turns, never by 45°, and the agent's name plate on the inner side. A click flies the camera to the agent.
/// Only the arrows and their plates take the events: the rest of the layer lets the scene have them.
///
/// An arrow is also a drop target of a dragged post-it (3.9, 6(k) "lâcher dessus vole vers Sol"): held there, it is
/// highlighted with what a drop does, and after half a second the camera flies to the agent while the drag goes on;
/// let go there, the post-it goes to that agent (`DropHUDController`).
struct EdgeArrowsView: View {
    /// Points between an arrow and its name plate.
    static let plateGap: CGFloat = 4
    /// Points of the highlight around an arrow and its plate under a dragged post-it.
    static let dropPadding: CGFloat = 4

    let stage: WorldStage

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    init(stage: WorldStage) {
        self.stage = stage
    }

    var body: some View {
        let hud = WorldHUD.shared
        let arrows = hud.edgeArrows(model: model)
        let height = CGFloat(stage.camera.view.height)
        if !arrows.isEmpty {
            if hud.animates {
                // The arrows nudge toward their tip at the sprite's rate (4 fps, a frame every 6 ticks); the timeline
                // exists only while an arrow is shown.
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    layer(arrows, height: height, tick: Self.tick(at: context.date))
                }
            } else {
                layer(arrows, height: height, tick: 0)
            }
        }
    }

    private func layer(_ arrows: [EdgeArrow], height: CGFloat, tick: Int) -> some View {
        let viewSize = CGSize(width: CGFloat(stage.camera.view.width), height: height)
        // The HUD's frames, only while a post-it is held over an arrow (its bubble keeps out of them).
        let held = workbench.dropHUDHover.map { if case .edgeArrow = $0.spot { true } else { false } } ?? false
        let obstacles = held ? DropBubbleLayout.hudFrames(stage: stage, model: model) : []
        return ZStack(alignment: .topLeading) {
            ForEach(arrows, id: \.id) { arrow in
                let spot = DropHUDSpot.edgeArrow(arrow.id)
                EdgeArrowButton(arrow: arrow, name: model.agent(arrow.id)?.name ?? "Agent", viewHeight: height,
                                tick: tick, dropHover: workbench.dropHUDHover.flatMap { $0.spot == spot ? $0 : nil },
                                viewSize: viewSize, obstacles: obstacles) {
                    WorldFlights.fly(to: arrow.id, model: model, stage: stage)
                }
                .agentDropTarget(spot, model: model, workbench: workbench)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The animation clock (24 ticks per second, 7.3).
    private static func tick(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate * Double(AnimationClock.ticksPerSecond)).rounded(.down))
    }

    /// The frames of an arrow and of its name plate (empty without one), in the scene's points from its top-left
    /// corner (the arrows are placed from the bottom-left corner, AppKit's).
    static func frames(of arrow: EdgeArrow, plate plateSize: CGSize, viewHeight: CGFloat) -> (arrow: CGRect, plate: CGRect) {
        let sprite = sprite(for: arrow.direction)
        let size = SpriteImage.size(of: sprite.key, quarterTurns: sprite.quarterTurns)
        let center = CGPoint(x: CGFloat(arrow.position.x), y: viewHeight - CGFloat(arrow.position.y))
        let arrowFrame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
                                height: size.height)
        guard plateSize != .zero else { return (arrowFrame, .zero) }
        let plateCenter = EdgeArrowButton.plateCenter(arrow: center, arrowSize: size, plate: plateSize,
                                                      direction: arrow.direction)
        let plateFrame = CGRect(x: plateCenter.x - plateSize.width / 2, y: plateCenter.y - plateSize.height / 2,
                                width: plateSize.width, height: plateSize.height)
        return (arrowFrame, plateFrame)
    }

    /// The size in points of an agent's name plate.
    static func plateSize(_ name: String) -> CGSize {
        SpriteImageCache.nameplate(name).map {
            CGSize(width: CGFloat($0.width) * SpriteImage.pointsPerTexel, height: CGFloat($0.height) * SpriteImage.pointsPerTexel)
        } ?? .zero
    }

    /// An arrow and its plate, the highlight's padding included (the frame of the highlight under a dragged post-it),
    /// in the scene's points from its top-left corner.
    static func dropArea(of arrow: EdgeArrow, model: AppModel, viewHeight: CGFloat) -> CGRect {
        dropArea(frames(of: arrow, plate: plateSize(model.agent(arrow.id)?.name ?? "Agent"), viewHeight: viewHeight))
    }

    static func dropArea(_ frames: (arrow: CGRect, plate: CGRect)) -> CGRect {
        let both = frames.plate.isEmpty ? frames.arrow : frames.arrow.union(frames.plate)
        return both.insetBy(dx: -dropPadding, dy: -dropPadding)
    }

    /// The agent whose arrow (or plate) is under `point`, in the scene's points from its top-left corner, the
    /// highlight's padding included: where the scene's view finds a dragged post-it held over an arrow.
    static func agent(at point: CGPoint, arrows: [EdgeArrow], model: AppModel, viewHeight: CGFloat) -> AgentID? {
        arrows.first { dropArea(of: $0, model: model, viewHeight: viewHeight).contains(point) }?.id
    }

    /// The sprite and its quarter turns for one of the 8 directions (0 up, then clockwise by 45°).
    static func sprite(for direction: Int) -> (key: SpriteKey, quarterTurns: Int) {
        let d = ((direction % 8) + 8) % 8
        if d % 2 == 0 { return (SpriteKey("ov.edgeArrow"), d / 2) }
        return (SpriteKey("ov.edgeArrow", variant: "diagonal"), (d - 1) / 2)
    }
}

/// One arrow and its name plate ("SOL"), both buttons with the same action; VoiceOver hears one of them: "Sol
/// attend, hors champ".
private struct EdgeArrowButton: View {
    let arrow: EdgeArrow
    let name: String
    /// The scene's height in points: the arrows are placed from the bottom-left corner (AppKit), SwiftUI from the
    /// top-left.
    let viewHeight: CGFloat
    let tick: Int
    /// A dragged post-it is held over the arrow: highlighted, with the decision's words.
    let dropHover: DropHUDHover?
    /// The scene's size in points and the HUD's frames, for the bubble of a dragged post-it.
    let viewSize: CGSize
    let obstacles: [CGRect]
    let action: @MainActor () -> Void

    var body: some View {
        let sprite = EdgeArrowsView.sprite(for: arrow.direction)
        let frame = SpriteCatalog.sprite(sprite.key)?.frameIndex(atTick: tick) ?? 0
        let plate = SpriteImageCache.nameplate(name)
        let frames = EdgeArrowsView.frames(of: arrow, plate: EdgeArrowsView.plateSize(name), viewHeight: viewHeight)
        Group {
            if let dropHover {
                let area = EdgeArrowsView.dropArea(frames)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                    .allowsHitTesting(false)
                let size = DropFeedbackBubble.size(text: dropHover.feedback, accepted: dropHover.accepted)
                let origin = Self.bubbleOrigin(size: size, around: area, direction: arrow.direction, in: viewSize,
                                               avoiding: obstacles)
                DropFeedbackBubble(text: dropHover.feedback, accepted: dropHover.accepted)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(false)
            }
            if let plate {
                Button(action: action) {
                    SpriteImage(image: plate)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                .offset(x: frames.plate.minX, y: frames.plate.minY)
            }
            Button(action: action) {
                SpriteImage(sprite.key, frame: frame, quarterTurns: sprite.quarterTurns)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) attend, hors champ")
            .accessibilityHint("Fait voler la caméra jusqu'à \(name)")
            .offset(x: frames.arrow.minX, y: frames.arrow.minY)
        }
        .help("\(name) attend ta réponse, hors champ : clic pour y aller")
    }

    /// Where the bubble of a dragged post-it goes beside the highlight `area`, toward the inside of the view: under
    /// it, or over it for an arrow pointing down (directions 3 to 5), from its left edge, or ending at its right edge
    /// for an arrow pointing right (directions 1 to 3); else on the other side of it; else the clear place nearest to
    /// it. Inside the view's margins, clear of the minimap and of the other arrows (`DropBubbleLayout`).
    static func bubbleOrigin(size: CGSize, around area: CGRect, direction: Int, in view: CGSize,
                             avoiding obstacles: [CGRect]) -> CGPoint {
        let d = ((direction % 8) + 8) % 8
        let gap = DropBubbleLayout.gap
        let right = (1...3).contains(d), down = (3...5).contains(d)
        let x = right ? area.maxX - size.width : area.minX
        let over = area.minY - gap - size.height, under = area.maxY + gap
        let candidates = [CGPoint(x: x, y: down ? over : under), CGPoint(x: x, y: down ? under : over)]
            .map { DropBubbleLayout.clamped($0, size: size, in: view) }
        return DropBubbleLayout.origin(size: size, candidates: candidates, near: CGPoint(x: area.midX, y: area.midY),
                                       in: view, avoiding: obstacles)
    }

    /// The plate beside the arrow, toward the inside of the view: on the left or the right of an arrow that points
    /// sideways or diagonally, below or above one that points up or down. Whole points.
    static func plateCenter(arrow: CGPoint, arrowSize: CGSize, plate: CGSize, direction: Int) -> CGPoint {
        let d = ((direction % 8) + 8) % 8
        let gap = EdgeArrowsView.plateGap
        switch d {
        case 0:
            return CGPoint(x: arrow.x, y: arrow.y + arrowSize.height / 2 + gap + plate.height / 2)
        case 4:
            return CGPoint(x: arrow.x, y: arrow.y - arrowSize.height / 2 - gap - plate.height / 2)
        default:
            // Pointing right (1…3): the plate on the left; pointing left (5…7): on the right.
            let side: CGFloat = d < 4 ? -1 : 1
            return CGPoint(x: arrow.x + side * (arrowSize.width / 2 + gap + plate.width / 2), y: arrow.y)
        }
    }
}
