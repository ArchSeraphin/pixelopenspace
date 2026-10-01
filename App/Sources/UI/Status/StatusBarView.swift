import PixelCore
import SwiftUI

/// Counters per state (mockups 6(a), 6(b)): symbol + number + words, most urgent first; states with no agent are
/// hidden. In the open space, clicking a counter flies the camera to the next agent in that state (décision 13); in
/// the list view, it filters the board on that state (clicking it again removes the filter). On the right, in the
/// open space, the zoom (décision 12).
struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let summary = model.liveStatusSummary
        let inScene = workbench.mainView == .scene
        HStack(spacing: 6) {
            if summary.visibleKinds.isEmpty {
                Text("Aucun agent")
                    .foregroundStyle(.secondary)
            } else {
                // The words when they fit on one line, else the numbers (6(q)); the waiting counter keeps its words.
                ViewThatFits(in: .horizontal) {
                    counters(summary, inScene: inScene, compact: false)
                    counters(summary, inScene: inScene, compact: true)
                }
            }
            Spacer(minLength: 8)
            if inScene, let camera = WorldHUD.shared.stage?.camera {
                ZoomControl(camera: camera)
                    .fixedSize()
                Divider()
                    .frame(height: 14)
            }
            HookHealthIndicator()
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Barre d'état des agents")
    }

    /// One button per state with agents; `compact`: the number alone (the words stay in the tooltip and for
    /// VoiceOver), except for the waiting agents.
    private func counters(_ summary: StatusSummary, inScene: Bool, compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(summary.visibleKinds, id: \.self) { kind in
                let text = summary.text(for: kind) ?? ""
                StatusCounterButton(kind: kind, text: text,
                                    shown: compact && kind != .waitingInput ? "\(summary.count(of: kind))" : text,
                                    flies: inScene, isActive: !inScene && workbench.stateFilter == kind) {
                    counterClicked(kind)
                }
            }
        }
    }

    /// Open space: the next agent in that state (`WorldFlights`); list view: the board's filter.
    private func counterClicked(_ kind: AgentStateKind) {
        if workbench.mainView == .scene, let stage = workbench.worldStage {
            WorldFlights.flyToNext(kind, model: model, stage: stage)
        } else {
            workbench.toggleFilter(kind)
        }
    }
}

private struct StatusCounterButton: View {
    let kind: AgentStateKind
    /// "2 réfléchissent": the tooltip and VoiceOver.
    let text: String
    /// On the button: `text`, or the number alone when the bar is short of room.
    let shown: String
    /// Open space: a click flies the camera (no filter there).
    let flies: Bool
    let isActive: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(shown)
                    .monospacedDigit()
                    .lineLimit(1)
            } icon: {
                Image(systemName: StateStyle.symbolName(for: kind))
                    .foregroundStyle(StateStyle.tint(for: kind))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isActive ? StateStyle.tint(for: kind).opacity(0.22) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(isActive ? StateStyle.tint(for: kind) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(text)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var helpText: String {
        if flies { return "\(text) : aller voir le prochain agent dans cet état" }
        return "\(text) : " + (isActive ? "afficher tous les agents" : "n'afficher que ces agents")
    }

    private var hint: String {
        if flies { return "Fait voler la caméra vers le prochain agent dans cet état" }
        return isActive ? "Retire le filtre" : "Filtre les agents sur cet état"
    }
}

/// "HOOKS ● actifs 6/6" (mockup 6(b)): whether the hook pipeline works, in words.
private struct HookHealthIndicator: View {
    private struct Presentation {
        var symbol: String
        var text: String
        var color: Color
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.hookStatus
        let presentation = describe(status)
        Label {
            Text(presentation.text)
        } icon: {
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(status.problem ?? "Les états des agents arrivent en temps réel par les hooks de Claude Code.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.text)
    }

    private func describe(_ status: HookStatus) -> Presentation {
        switch status.server {
        case .running:
            if !status.degradedAgents.isEmpty {
                return Presentation(symbol: "exclamationmark.triangle.fill",
                                    text: "Hooks : mode dégradé (\(status.degradedAgents.count))",
                                    color: StateStyle.tint(for: .waitingInput))
            }
            let count = status.runningAgents > 0 ? " \(status.healthyAgents)/\(status.runningAgents)" : ""
            return Presentation(symbol: "circle.fill", text: "Hooks actifs\(count)", color: StateStyle.tint(for: .done))
        case .helperMissing:
            return Presentation(symbol: "exclamationmark.triangle.fill", text: "Hooks : pixel-hook absent",
                                color: StateStyle.tint(for: .error))
        case .anotherInstance:
            return Presentation(symbol: "xmark.octagon.fill", text: "Hooks : autre copie ouverte",
                                color: StateStyle.tint(for: .error))
        case .failed:
            return Presentation(symbol: "xmark.octagon.fill", text: "Hooks indisponibles",
                                color: StateStyle.tint(for: .error))
        case .stopped:
            return Presentation(symbol: "circle", text: "Hooks arrêtés", color: Color.secondary)
        }
    }
}
