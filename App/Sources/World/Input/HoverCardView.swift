import AppKit
import PixelCore
import SwiftUI

/// The card of the hovered agent or free desk (6(a), 3.9), shown after the pointer rests on it: "Nova · API · ATTEND
/// TA RÉPONSE", "Bash : rm -rf dist · depuis 42 s", "clic : fenêtre · double : terminal"; "Poste libre · clic :
/// nouvel agent ici". The state is written in words and drawn with its symbol, never a colour alone (7.9).
///
/// A subview of the `WorldView` that lets every event through (no hit-test): the scene keeps the hover, the scroll
/// and the pinch. Its text follows the model (state, duration) while it shows. Decorative for VoiceOver, whose path
/// is the scene's accessibility elements and the list view. The HUD's controls (minimap, edge arrows) are SwiftUI
/// overlays drawn over the scene's view and its subviews: the card keeps out of their frames.
@MainActor
final class HoverCardView: NSHostingView<HoverCardContent> {
    /// Space kept between the card and the view's edges.
    static let margin: CGFloat = 8
    /// Distance from the pointer to the card.
    static let offset: CGFloat = 14
    /// Space kept between the card and a control of the HUD.
    static let obstacleGap: CGFloat = 4

    private var leading: NSLayoutConstraint?
    private var top: NSLayoutConstraint?

    init() {
        super.init(rootView: HoverCardContent())
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        // Exactly its content's size; the position gives way to the view's edges.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        setAccessibilityElement(false)
    }

    required init(rootView: HoverCardContent) {
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

    /// Adds the card, hidden, over the scene's view.
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

    /// Shows the card of `target` beside `point` (the pointer, in the view's points, origin at the bottom-left
    /// corner), out of `obstacles` (the HUD's frames, origin at the top-left corner): see `origin`.
    func show(_ target: SceneHitTarget, model: AppModel, near point: CGPoint, avoiding obstacles: [CGRect] = []) {
        guard let superview else { return }
        rootView = HoverCardContent(target: target, model: model)
        let bounds = superview.bounds
        let origin = Self.origin(size: fittingSize, near: CGPoint(x: point.x, y: bounds.height - point.y),
                                 in: bounds.size, avoiding: obstacles)
        leading?.constant = origin.x
        top?.constant = origin.y
        isHidden = false
        superview.layoutSubtreeIfNeeded()
    }

    /// The card's top-left corner for a card of `size` beside `pointer`, everything in points from the view's top-left
    /// corner. Below and to the right of the pointer, else to its left, else above, as long as the card stays inside
    /// the view's margins and clear of every obstacle. When no side is (the pointer near an edge, a target under the
    /// minimap as the snapshot harness shows it), the card goes inside the margins, against the obstacle it would
    /// cover if need be, at the clear place nearest to the pointer; with no clear place, below and to the right,
    /// inside the margins.
    static func origin(size: CGSize, near pointer: CGPoint, in view: CGSize, avoiding obstacles: [CGRect]) -> CGPoint {
        let area = CGRect(origin: .zero, size: view).insetBy(dx: margin, dy: margin)
        let blocked = obstacles.filter { !$0.isEmpty }.map { $0.insetBy(dx: -obstacleGap, dy: -obstacleGap) }
        func isClear(_ origin: CGPoint) -> Bool {
            let card = CGRect(origin: origin, size: size)
            // Sharing an edge is not covering.
            return !blocked.contains { let common = $0.intersection(card); return common.width > 0 && common.height > 0 }
        }
        /// Inside the margins (the top-left corner wins when the card is larger than the view).
        func clamped(_ origin: CGPoint) -> CGPoint {
            CGPoint(x: max(area.minX, min(origin.x, area.maxX - size.width)),
                    y: max(area.minY, min(origin.y, area.maxY - size.height)))
        }
        let right = pointer.x + offset, left = pointer.x - offset - size.width
        let below = pointer.y + offset, above = pointer.y - offset - size.height
        let sides = [CGPoint(x: right, y: below), CGPoint(x: left, y: below), CGPoint(x: right, y: above),
                     CGPoint(x: left, y: above)]
        if let origin = sides.first(where: { area.contains(CGRect(origin: $0, size: size)) && isClear($0) }) {
            return origin
        }
        let edges = sides.map(clamped)
        var places = edges
        for obstacle in blocked {
            for edge in edges {
                places += [CGPoint(x: edge.x, y: obstacle.minY - size.height), CGPoint(x: edge.x, y: obstacle.maxY),
                           CGPoint(x: obstacle.minX - size.width, y: edge.y), CGPoint(x: obstacle.maxX, y: edge.y)]
                    .map(clamped)
            }
        }
        func distance(_ origin: CGPoint) -> CGFloat {
            hypot(origin.x + size.width / 2 - pointer.x, origin.y + size.height / 2 - pointer.y)
        }
        // `min(by:)` keeps the first of equal places: the order of `sides` breaks ties.
        return places.filter(isClear).min { distance($0) < distance($1) } ?? edges[0]
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        rootView = HoverCardContent()
    }
}

/// The card's text, read from the model while it shows (the duration counts up with `model.now`).
struct HoverCardContent: View {
    var target: SceneHitTarget?
    var model: AppModel?

    var body: some View {
        if let target, let model, let lines = Self.lines(for: target, model: model) {
            VStack(alignment: .leading, spacing: 2) {
                lines
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1))
            .fixedSize()
            .accessibilityHidden(true)
        }
    }

    private static func lines(for target: SceneHitTarget, model: AppModel) -> AnyView? {
        switch target {
        case .agent(let agentID):
            guard model.agent(agentID) != nil else { return nil }
            return AnyView(agentLines(agentID, model: model))
        case .freeDesk:
            return AnyView(Text("Poste libre · clic : nouvel agent ici"))
        default:
            return nil
        }
    }

    @ViewBuilder
    private static func agentLines(_ agentID: AgentID, model: AppModel) -> some View {
        let names = model.names(of: agentID)
        let display = model.display(for: agentID)
        HStack(spacing: 4) {
            Text(names.agent)
                .fontWeight(.semibold)
            Text("· \(names.project) · \(display?.title.uppercased() ?? "SANS NOUVELLES")")
            if let display {
                Image(systemName: display.symbolName)
                    .foregroundStyle(StateStyle.tint(for: display.kind))
            }
        }
        if let display {
            Text(detail(display, now: model.now))
        }
        Text("clic : fenêtre · double : terminal")
            .foregroundStyle(.secondary)
    }

    /// "Bash : rm -rf dist · depuis 42 s · +1 attente".
    static func detail(_ display: AgentStatusDisplay, now: Date) -> String {
        var parts: [String] = []
        if let detail = display.detail, !detail.isEmpty { parts.append(detail) }
        parts.append("depuis \(DurationText.short(now.timeIntervalSince(display.since)))")
        parts.append(contentsOf: display.badges)
        return parts.joined(separator: " · ")
    }
}
