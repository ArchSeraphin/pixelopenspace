import AppKit
import PixelCore
import SwiftUI

/// What a drop of the dragged post-it does there (3.9, 6(k)): "Donner à Nova · file #2", "Nouvel agent avec ce
/// post-it", "Premier agent libre de API"; or why it cannot ("Remets-la d'abord à faire.", "Nova · terminal hors de
/// l'app"). A symbol says which, never a colour alone (7.9).
struct DropFeedbackBubble: View {
    let text: String
    let accepted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: accepted ? "note.text" : "nosign")
                .foregroundStyle(accepted ? Color.accentColor : StateStyle.tint(for: .error))
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(accepted ? Color.accentColor : StateStyle.tint(for: .error), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accepted ? text : "Refusé : \(text)")
    }

    /// Measured sizes, by text: a drag shows a handful of decisions.
    @MainActor private static var sizes: [String: CGSize] = [:]

    /// The bubble's size in points, for the controls that place it themselves (an edge arrow, the minimap).
    @MainActor
    static func size(text: String, accepted: Bool) -> CGSize {
        let key = (accepted ? "1" : "0") + text
        if let size = sizes[key] { return size }
        let size = NSHostingView(rootView: DropFeedbackBubble(text: text, accepted: accepted)).fittingSize
        if sizes.count >= 64 { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = size
        return size
    }
}

/// Where the bubble of a dragged post-it goes over the scene: beside what it speaks of, inside the view's margins,
/// clear of the HUD's controls (the minimap, the edge arrows and their plates). SwiftUI draws them over the scene's
/// view and over one another: a bubble placed blindly goes under the minimap or covers an arrow. Shared by the
/// scene's bubble (`DropFeedbackView`), the edge arrows and the minimap, as `HoverCardView` does for the hover card.
@MainActor
enum DropBubbleLayout {
    /// Points between the bubble and the view's edges.
    static let margin = HoverCardView.margin
    /// Points between the bubble and the control or the highlight it speaks of.
    static let gap: CGFloat = 6

    /// The frames of the HUD's controls over the scene, in its points from the top-left corner: the minimap while it
    /// shows, and each edge arrow with its plate (the room of its highlight).
    static func hudFrames(stage: WorldStage, model: AppModel) -> [CGRect] {
        var frames: [CGRect] = []
        if let minimap = MinimapView.frame(stage: stage, model: model) { frames.append(minimap) }
        let height = CGFloat(stage.camera.view.height)
        for arrow in WorldHUD.shared.edgeArrows(model: model) {
            frames.append(EdgeArrowsView.dropArea(of: arrow, model: model, viewHeight: height))
        }
        return frames
    }

    /// The top-left corner of a bubble of `size`: the first of `candidates` (in order of preference) that keeps it
    /// inside the view's margins and clear of every obstacle; when none does, the clear place nearest to `pointer`
    /// against an obstacle (`HoverCardView.origin`). Points from the view's top-left corner, whole.
    static func origin(size: CGSize, candidates: [CGPoint], near pointer: CGPoint, in view: CGSize,
                       avoiding obstacles: [CGRect]) -> CGPoint {
        let area = CGRect(origin: .zero, size: view).insetBy(dx: margin, dy: margin)
        let blocked = obstacles.filter { !$0.isEmpty }
            .map { $0.insetBy(dx: -HoverCardView.obstacleGap, dy: -HoverCardView.obstacleGap) }
        let found = candidates.first { origin in
            let bubble = CGRect(origin: origin, size: size)
            // Sharing an edge is not covering.
            return area.contains(bubble) && !blocked.contains {
                let common = $0.intersection(bubble)
                return common.width > 0 && common.height > 0
            }
        }
        let origin = found ?? HoverCardView.origin(size: size, near: pointer, in: view, avoiding: obstacles)
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    /// A candidate moved inside the view's margins (a control sits at the edge of the view).
    static func clamped(_ origin: CGPoint, size: CGSize, in view: CGSize) -> CGPoint {
        let area = CGRect(origin: .zero, size: view).insetBy(dx: margin, dy: margin)
        return CGPoint(x: max(area.minX, min(origin.x, area.maxX - size.width)),
                       y: max(area.minY, min(origin.y, area.maxY - size.height)))
    }
}

/// The bubble over the scene, beside the pointer, while a post-it is dragged there (`WorldDropController`).
///
/// A subview of the `WorldView` that lets every event through (no hit-test, no drag type): the scene keeps the drag,
/// the hover, the scroll and the pinch (décision 9). VoiceOver hears the decision through the drag's own feedback.
@MainActor
final class DropFeedbackView: NSHostingView<DropFeedbackContent> {
    /// Space kept between the bubble and the view's edges.
    static let margin = DropBubbleLayout.margin
    /// Distance from the pointer to the bubble: below the drag's image of the post-it, to its right.
    static let offset = CGSize(width: 18, height: 26)

    private var leading: NSLayoutConstraint?
    private var top: NSLayoutConstraint?

    init() {
        super.init(rootView: DropFeedbackContent())
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        setAccessibilityElement(false)
    }

    required init(rootView: DropFeedbackContent) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    var isShowing: Bool { !isHidden }

    /// Adds the bubble, hidden, over the scene's view.
    func install(in view: NSView) {
        view.addSubview(self)
        let leading = leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let top = topAnchor.constraint(equalTo: view.topAnchor)
        leading.priority = .init(900)
        top.priority = .init(900)
        let edges = [
            leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Self.margin),
            trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Self.margin),
            topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: Self.margin),
            bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -Self.margin),
        ]
        for edge in edges { edge.priority = .init(990) }
        NSLayoutConstraint.activate([leading, top] + edges)
        self.leading = leading
        self.top = top
    }

    /// Shows `text` beside `point` (the pointer, in the view's points, origin at the bottom-left corner): below and
    /// to the right, else below and to the left, above and to the right, above and to the left, inside the view and
    /// clear of `obstacles` (the HUD's frames, origin at the top-left corner: `DropBubbleLayout.hudFrames`).
    func show(_ text: String, accepted: Bool, near point: CGPoint, avoiding obstacles: [CGRect] = []) {
        guard let superview else { return }
        let content = DropFeedbackContent(text: text, accepted: accepted)
        if rootView != content { rootView = content }
        let size = fittingSize
        let bounds = superview.bounds
        let pointer = CGPoint(x: point.x, y: bounds.height - point.y)
        let right = pointer.x + Self.offset.width, left = pointer.x - Self.offset.width - size.width
        let below = pointer.y + Self.offset.height, above = pointer.y - Self.offset.height - size.height
        let candidates = [CGPoint(x: right, y: below), CGPoint(x: left, y: below), CGPoint(x: right, y: above),
                          CGPoint(x: left, y: above)]
        let origin = DropBubbleLayout.origin(size: size, candidates: candidates, near: pointer, in: bounds.size,
                                             avoiding: obstacles)
        leading?.constant = origin.x
        top?.constant = origin.y
        if isHidden { isHidden = false }
        superview.layoutSubtreeIfNeeded()
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        rootView = DropFeedbackContent()
    }
}

/// The bubble's content (empty while hidden).
struct DropFeedbackContent: View, Equatable {
    var text: String?
    var accepted = true

    var body: some View {
        if let text {
            DropFeedbackBubble(text: text, accepted: accepted)
                .accessibilityHidden(true)
        }
    }
}
