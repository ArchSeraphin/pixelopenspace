import PixelCore
import SwiftUI

/// Counters per state (mockup 6(b)): symbol + number + words, most urgent first; states with no agent are hidden.
/// Clicking a counter filters the board on that state (clicking it again removes the filter).
struct StatusBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let summary = model.liveStatusSummary
        HStack(spacing: 6) {
            if summary.visibleKinds.isEmpty {
                Text("Aucun agent")
                    .foregroundStyle(.secondary)
            }
            ForEach(summary.visibleKinds, id: \.self) { kind in
                StatusCounterButton(kind: kind, text: summary.text(for: kind) ?? "",
                                    isActive: workbench.stateFilter == kind) {
                    workbench.toggleFilter(kind)
                }
            }
            Spacer(minLength: 8)
            HookHealthIndicator()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Barre d'état des agents")
    }
}

private struct StatusCounterButton: View {
    let kind: AgentStateKind
    let text: String
    let isActive: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(text)
                    .monospacedDigit()
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
        .help(isActive ? "Afficher tous les agents" : "N'afficher que ces agents")
        .accessibilityLabel(text)
        .accessibilityHint(isActive ? "Retire le filtre" : "Filtre les agents sur cet état")
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
