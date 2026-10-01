import PixelCore
import SwiftUI

/// The edge arrows (3.9, 6(k)): for each agent waiting out of view (`EdgeArrows.layout`), a small button on the
/// border of the scene, pointing toward it: `ov.edgeArrow` (up) or `ov.edgeArrow~diagonal` (up-right) turned by
/// quarter turns, never by 45°, and the agent's name plate on the inner side. A click flies the camera to the agent.
/// Only the arrows and their plates take the events: the rest of the layer lets the scene have them.
struct EdgeArrowsView: View {
    /// Points between an arrow and its name plate.
    static let plateGap: CGFloat = 4

    let stage: WorldStage

    @Environment(AppModel.self) private var model

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
        ZStack(alignment: .topLeading) {
            ForEach(arrows, id: \.id) { arrow in
                EdgeArrowButton(arrow: arrow, name: model.agent(arrow.id)?.name ?? "Agent", viewHeight: height,
                                tick: tick) {
                    WorldFlights.fly(to: arrow.id, model: model, stage: stage)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The animation clock (24 ticks per second, 7.3).
    private static func tick(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate * Double(AnimationClock.ticksPerSecond)).rounded(.down))
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
    let action: @MainActor () -> Void

    var body: some View {
        let sprite = EdgeArrowsView.sprite(for: arrow.direction)
        let frame = SpriteCatalog.sprite(sprite.key)?.frameIndex(atTick: tick) ?? 0
        let size = SpriteImage.size(of: sprite.key, quarterTurns: sprite.quarterTurns)
        let center = CGPoint(x: CGFloat(arrow.position.x), y: viewHeight - CGFloat(arrow.position.y))
        let plate = SpriteImageCache.nameplate(name)
        let plateSize = plate.map {
            CGSize(width: CGFloat($0.width) * SpriteImage.pointsPerTexel, height: CGFloat($0.height) * SpriteImage.pointsPerTexel)
        } ?? .zero
        let plateCenter = Self.plateCenter(arrow: center, arrowSize: size, plate: plateSize, direction: arrow.direction)
        Group {
            if let plate {
                Button(action: action) {
                    SpriteImage(image: plate)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                .offset(x: plateCenter.x - plateSize.width / 2, y: plateCenter.y - plateSize.height / 2)
            }
            Button(action: action) {
                SpriteImage(sprite.key, frame: frame, quarterTurns: sprite.quarterTurns)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name) attend, hors champ")
            .accessibilityHint("Fait voler la caméra jusqu'à \(name)")
            .offset(x: center.x - size.width / 2, y: center.y - size.height / 2)
        }
        .help("\(name) attend ta réponse, hors champ : clic pour y aller")
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
