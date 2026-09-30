import PixelCore
import SwiftUI

/// Waiting tray (proposal 3.9, "qui attend quoi en moins de 3 s"): one row per waiting agent, oldest wait first,
/// `agent · projet · raison · depuis`. Shown as long as at least one agent waits. Clicking a row selects the
/// agent, opens its terminal with the keyboard focus and acknowledges the wait.
struct WaitingTrayView: View {
    static let visibleRows = 4

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
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
                    workbench.openWaitingAgent(entry.agentID)
                }
            }
        }
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
        .help("Ouvrir le terminal de \(names.agent) pour répondre")
        .accessibilityLabel(model.accessibilityLabel(for: entry.agentID) ?? "\(names.agent), \(reason)")
        .accessibilityHint("Ouvre son terminal")
    }
}
