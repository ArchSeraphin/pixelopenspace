import PixelCore
import SwiftUI

/// Waiting tray (proposal 3.9, "qui attend quoi en moins de 3 s"): one row per waiting agent, oldest wait first,
/// `agent · projet · raison · depuis`. Shown as long as at least one agent waits. Clicking a row selects the
/// agent, flies the camera to it in the open space (the list shows its card instead), and opens its window
/// (`AgentWindowController`), which acknowledges the wait; the answer is given from there, by its "Ouvrir le
/// terminal ⌘T".
struct WaitingTrayView: View {
    static let visibleRows = 4

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        // Always present, even empty: the agent windows' controller is prepared when the tray appears.
        VStack(spacing: 0) {
            tray
        }
        .onAppear {
            AgentWindowController.shared.prepare(model: model, workbench: workbench)
        }
    }

    @ViewBuilder
    private var tray: some View {
        let entries = model.liveStatusSummary.waiting
        let title = entries.count > 1 ? "EN ATTENTE · \(entries.count) agents" : "EN ATTENTE"
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(title)
                        .font(.caption.weight(.bold))
                } icon: {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(StateStyle.tint(for: .waitingInput))
                }
                .accessibilityAddTraits(.isHeader)
                if entries.count > Self.visibleRows {
                    ScrollView {
                        rows(entries)
                    }
                    .frame(height: CGFloat(Self.visibleRows) * 24)
                } else {
                    rows(entries)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StateStyle.tint(for: .waitingInput).opacity(0.10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents en attente")
        }
    }

    private func rows(_ entries: [WaitingEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                WaitingTrayRow(entry: entry) {
                    openWindow(of: entry.agentID)
                }
            }
        }
    }

    /// Open space: selects the agent and flies the camera to it, then opens its window; list view: selects it,
    /// scrolls to its card and opens its window.
    private func openWindow(of agentID: AgentID) {
        if workbench.mainView == .scene, let stage = workbench.worldStage {
            WorldFlights.fly(to: agentID, model: model, stage: stage)
        } else {
            workbench.reveal(agentID)
        }
        AgentWindowController.shared.show(agentID, model: model, workbench: workbench)
    }
}

private struct WaitingTrayRow: View {
    let entry: WaitingEntry
    let action: @MainActor () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let names = model.names(of: entry.agentID)
        let since = DurationText.short(model.now.timeIntervalSince(entry.since))
        let reason = AgentPresenter.describe(entry.reason)
        let extra = entry.count > 1 ? " (+\(entry.count - 1))" : ""
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: AgentPresenter.symbolName(for: entry.reason))
                    .foregroundStyle(StateStyle.tint(for: .waitingInput))
                    .accessibilityHidden(true)
                Text(names.agent)
                    .fontWeight(.semibold)
                Text("· \(names.project) · \(reason)\(extra)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(since)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ouvrir la fenêtre de \(names.agent) : ce qu'il attend, et son terminal pour répondre")
        .accessibilityLabel(model.accessibilityLabel(for: entry.agentID) ?? "\(names.agent), \(reason)")
        .accessibilityHint("Ouvre la fenêtre de l'agent")
    }
}
