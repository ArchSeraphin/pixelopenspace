import PixelCore
import SwiftUI

/// "Quitter Pixel Open Space ?" (mockup 6(p), first part): the agents that quitting would interrupt, live.
/// Annuler · Quitter quand même · Attendre la fin des tours (default).
struct QuitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let assessment = model.prepareToQuit()
        VStack(alignment: .leading, spacing: 14) {
            Text("Quitter Pixel Open Space ?")
                .font(.title2.weight(.semibold))
            Text(summary(assessment))
            if !assessment.busy.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(assessment.busy) { entry in
                        QuitEntryRow(entry: entry)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Text("Un outil en cours (installation, migration…) serait interrompu. Les conversations pourront être "
                    + "reprises au prochain lancement.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Annuler", role: .cancel) { answer(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Quitter quand même", role: .destructive) { answer(.quitAnyway) }
                Button("Attendre la fin des tours") { answer(.waitForTurns) }
                    .keyboardShortcut(.defaultAction)
                    .help("Plus rien n'est envoyé ; l'app quitte d'elle-même quand tous les agents sont au repos")
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func summary(_ assessment: QuitAssessment) -> String {
        let sessions = assessment.runningSessions
        let closing = sessions > 1 ? "Quitter ferme les \(sessions) sessions." : "Quitter ferme la session en cours."
        switch assessment.busy.count {
        case 0: return closing + " Aucun agent n'est occupé."
        case 1: return closing + " 1 agent n'est pas au repos :"
        default: return closing + " \(assessment.busy.count) agents ne sont pas au repos :"
        }
    }

    private func answer(_ choice: QuitChoice) {
        model.respondToQuit(choice)
        workbench.dismissSheet()
    }
}

private struct QuitEntryRow: View {
    let entry: QuitEntry

    @Environment(AppModel.self) private var model

    var body: some View {
        let display = entry.display
        let since = DurationText.short(model.now.timeIntervalSince(display.since))
        HStack(spacing: 8) {
            Image(systemName: display.symbolName)
                .foregroundStyle(StateStyle.tint(for: display.kind))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text("\(entry.agentName) · \(entry.projectName)")
                .fontWeight(.semibold)
                .frame(minWidth: 140, alignment: .leading)
            Text(display.detail.map { "\(display.title) : \($0)" } ?? display.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("depuis \(since)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
