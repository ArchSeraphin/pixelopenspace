import PixelCore
import SwiftUI

/// "Relancer les sessions" (mockup 6(p), second part), opened by "Choisir…" on the relaunch banner: one line per
/// agent left offline by the previous run, read live (`AppModel.relaunchCandidates`).
///
/// A line is checked by default when its conversation can be resumed (in its folder, or forked in the project
/// folder when that folder is gone); a new session (transcript purged, no session) is offered unchecked; a session
/// still held by a live process, or a project whose folder is gone, cannot be checked. For a post-it "En cours":
/// "Continuer la tâche" or "Remettre à faire" (default). "Plus tard" hides the banner until the next launch.
struct RelaunchSheet: View {
    /// Beyond this many lines, the list scrolls.
    static let linesWithoutScrolling = 5
    static let scrollingHeight: CGFloat = 420

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    /// Lines the user checked or unchecked; the others keep `selectedByDefault`.
    @State private var checks: [AgentID: Bool] = [:]
    /// The fate of each post-it "En cours"; "Remettre à faire" when not chosen.
    @State private var cardChoices: [AgentID: RelaunchCardChoice] = [:]
    /// Orphans the user chose to leave running ("Laisser tourner").
    @State private var leftRunning: Set<AgentID> = []

    var body: some View {
        let candidates = model.relaunchCandidates()
        let selected = candidates.filter(isChecked)
        VStack(alignment: .leading, spacing: 14) {
            Text("Relancer les sessions")
                .font(.title2.weight(.semibold))
            Text("Coche les sessions à reprendre. Un tour interrompu ne repart jamais tout seul : pour chaque post-it "
                + "en cours, choisis de le continuer (la consigne part une fois la session démarrée) ou de le remettre "
                + "à faire.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                Text("Aucune session à relancer : elles ont toutes été relancées ou fermées.")
                    .foregroundStyle(.secondary)
            } else if candidates.count > Self.linesWithoutScrolling {
                ScrollView {
                    lines(candidates)
                }
                .frame(height: Self.scrollingHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            } else {
                lines(candidates)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                Button("Plus tard") { later() }
                    .keyboardShortcut(.cancelAction)
                    .help("Ne rien relancer maintenant ; chaque agent reste relançable depuis sa carte")
                Spacer()
                Button(relaunchTitle(selected.count)) { relaunch(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func lines(_ candidates: [RelaunchCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.agentID) { index, candidate in
                if index > 0 { Divider() }
                RelaunchLine(candidate: candidate, now: model.now, isChecked: checkBinding(candidate),
                             cardChoice: choiceBinding(candidate),
                             isLeftRunning: leftRunning.contains(candidate.agentID),
                             terminate: { model.terminateOrphan(candidate.agentID) },
                             leaveRunning: { leftRunning.insert(candidate.agentID) })
            }
        }
    }

    // MARK: - Choices

    private func isChecked(_ candidate: RelaunchCandidate) -> Bool {
        candidate.status.isRelaunchable && (checks[candidate.agentID] ?? candidate.selectedByDefault)
    }

    private func checkBinding(_ candidate: RelaunchCandidate) -> Binding<Bool> {
        Binding(get: { isChecked(candidate) }, set: { checks[candidate.agentID] = $0 })
    }

    private func choiceBinding(_ candidate: RelaunchCandidate) -> Binding<RelaunchCardChoice> {
        Binding(get: { cardChoices[candidate.agentID] ?? .putBack }, set: { cardChoices[candidate.agentID] = $0 })
    }

    private func relaunchTitle(_ count: Int) -> String {
        switch count {
        case 0: return "Relancer"
        case 1: return "Relancer 1 session"
        default: return "Relancer \(count) sessions"
        }
    }

    private func relaunch(_ selected: [RelaunchCandidate]) {
        let selections = selected.map {
            RelaunchSelection(agentID: $0.agentID, cardChoice: cardChoices[$0.agentID] ?? .putBack)
        }
        workbench.dismissSheet()
        model.relaunch(selections)
    }

    private func later() {
        model.dismissRelaunchOffer()
        workbench.dismissSheet()
    }
}

/// One line: checkbox, "Nova · API", the post-it in progress or the session ("session 7d2f…") or why it cannot be
/// resumed, "il y a 2 h", the folder it will run in; then the post-it's choice, or the orphan's buttons.
private struct RelaunchLine: View {
    let candidate: RelaunchCandidate
    let now: Date
    @Binding var isChecked: Bool
    @Binding var cardChoice: RelaunchCardChoice
    let isLeftRunning: Bool
    let terminate: () -> Void
    let leaveRunning: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let names = model.names(of: candidate.agentID)
        let card = candidate.cardInProgress.flatMap { model.board.card($0) }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if candidate.status.isRelaunchable {
                Toggle("Relancer \(names.agent)", isOn: $isChecked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                Image(systemName: "minus.square")
                    .foregroundStyle(.secondary)
                    .help("Ne peut pas être relancée pour l'instant")
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(names.project.isEmpty ? names.agent : "\(names.agent) · \(names.project)")
                        .fontWeight(.semibold)
                        .frame(minWidth: 120, alignment: .leading)
                    Text(headline(card))
                        .foregroundStyle(isWarning ? AnyShapeStyle(StateStyle.tint(for: .waitingInput))
                                                   : AnyShapeStyle(HierarchicalShapeStyle.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(headline(card))
                    Spacer(minLength: 8)
                    if let ago = candidate.lastActivity.map({ Self.ago(now.timeIntervalSince($0)) }) {
                        Text(ago)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    if let folder {
                        Text(ProjectSectionView.abbreviated(folder))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160, alignment: .trailing)
                            .help(folder)
                    }
                }
                if let detail = detail(card) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if card != nil, candidate.status.isRelaunchable {
                    Picker("post-it en cours :", selection: $cardChoice) {
                        Text("Continuer la tâche").tag(RelaunchCardChoice.continueTask)
                        Text("Remettre à faire").tag(RelaunchCardChoice.putBack)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .disabled(!isChecked)
                    .help(choiceHelp)
                }
                if case .orphanAlive = candidate.status {
                    if isLeftRunning {
                        Text("Laissée hors de l'app : sa session ne peut pas être reprise tant que ce processus vit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Button("Terminer ce processus", action: terminate)
                                .help("SIGTERM au processus : la session pourra être reprise une fois qu'il sera arrêté")
                            Button("Laisser tourner", action: leaveRunning)
                                .help("Ses hooks restent refusés ; le relancer reste impossible tant qu'il vit")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var isWarning: Bool {
        switch candidate.status {
        case .orphanAlive, .projectFolderMissing: true
        case .resumable, .forkInProjectFolder, .newSession: false
        }
    }

    /// The post-it in progress or the session for a resumable line, otherwise why the line differs.
    private func headline(_ card: TaskCard?) -> String {
        switch candidate.status {
        case .resumable(let ref), .forkInProjectFolder(let ref):
            return card.map { "« \($0.title) »" } ?? Self.sessionLabel(ref.sessionID)
        case .newSession(let reason):
            return reason
        case .orphanAlive(let pid):
            return "⚠ tourne encore hors de l'app (pid \(pid))"
        case .projectFolderMissing:
            return "⚠ " + RelaunchPlanner.projectFolderMissingReason
        }
    }

    /// A second line: the fork, the missing folder, or the post-it when the headline is about something else.
    private func detail(_ card: TaskCard?) -> String? {
        let cardLine = card.map { "post-it en cours : « \($0.title) »" }
        switch candidate.status {
        case .resumable:
            return nil
        case .forkInProjectFolder(let ref):
            return "Son dossier (\(ProjectSectionView.abbreviated(ref.cwd))) n'existe plus : la conversation sera "
                + "dupliquée dans le dossier du projet."
        case .newSession, .orphanAlive:
            return cardLine
        case .projectFolderMissing(let path):
            let missing = "\(ProjectSectionView.abbreviated(path)) : remets le dossier en place pour relancer l'agent."
            return cardLine.map { missing + " " + $0 } ?? missing
        }
    }

    /// Where the session will run: its own folder for a resume, the project folder otherwise.
    private var folder: String? {
        guard let agent = model.agent(candidate.agentID), let project = model.project(agent.projectID) else {
            return nil
        }
        switch candidate.status {
        case .resumable(let ref):
            let cwd = ref.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            return cwd.hasPrefix("/") ? cwd : project.path
        case .forkInProjectFolder, .newSession:
            return project.path
        case .orphanAlive, .projectFolderMissing:
            return nil
        }
    }

    private var choiceHelp: String {
        if case .newSession = candidate.status {
            return "Nouvelle session : elle ne connaît pas la conversation précédente. « Continuer la tâche » lui "
                + "envoie « Continue la tâche : » suivi du titre du post-it, une fois la session démarrée."
        }
        return "« Continuer la tâche » envoie « Continue la tâche : » suivi du titre, une fois la session reprise. "
            + "« Remettre à faire » renvoie le post-it dans « À faire », sans agent."
    }

    /// "session 7d2f…".
    static func sessionLabel(_ sessionID: String) -> String {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "session " + String(id.prefix(4)) + (id.count > 4 ? "…" : "")
    }

    /// "à l'instant", "il y a 12 min", "il y a 2 h", "il y a 3 j".
    static func ago(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "à l'instant" }
        if seconds < 3_600 { return "il y a \(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "il y a \(Int(seconds / 3_600)) h" }
        return "il y a \(Int(seconds / 86_400)) j"
    }
}
