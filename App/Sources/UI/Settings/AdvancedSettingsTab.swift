import PixelCore
import SwiftUI

/// "Avancé" tab: diagnostics. For now the hook → screen latency (MVP acceptance criterion 2: p95 under 150 ms),
/// measured by `AppModel.receive(_:)` over the last 500 accepted hook events and updated live.
struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.hookLatency.summary
        Form {
            Section {
                LabeledContent("Latence hook → écran") {
                    if let summary {
                        Text(summary.text)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    } else {
                        Text("aucune mesure pour l'instant")
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary, !summary.meetsTarget {
                    Label("Au-dessus de l'objectif (p95 sous "
                        + "\(LatencySummary.millisecondsText(LatencySummary.targetP95Ns))) : les états des agents "
                        + "s'affichent en retard.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StateStyle.tint(for: .waitingInput))
                }
            } header: {
                Text("Diagnostic")
            } footer: {
                Text("Temps entre l'instant où pixel-hook reçoit un événement de Claude Code et celui où l'app "
                    + "applique le nouvel état, sur les \(LatencyWindow.defaultCapacity) derniers événements "
                    + "acceptés depuis le lancement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
