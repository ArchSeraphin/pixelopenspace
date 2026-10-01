import Foundation
import PixelCore

/// Relaunching after a restart or a crash of the app (proposal 2.5, mock-up 6(p)): the banner "n sessions peuvent
/// être relancées", the "Relancer les sessions" sheet, and applying its choices. `RelaunchPlanner` decides which
/// sessions can be resumed and how; this file reads the disk and the processes for it, then launches.
///
/// Nothing starts by itself: only "Tout relancer" or the sheet launch, and the interrupted turn never restarts
/// unless the user picks "Continuer la tâche", applied once the session has started.
extension AppModel {
    // MARK: - Candidates

    /// The lines of the sheet, now: every agent left offline by the previous run (relaunched or orphan), with its
    /// status read from the disk (project folder, session folder, transcript) and from the processes still running.
    func relaunchCandidates() -> [RelaunchCandidate] {
        guard hasAgentsToRelaunch else { return [] }
        // Only the agents still offline since the previous run are looked up on disk.
        var offline = workspace
        offline.agents = workspace.agents.filter { runtimes[$0.id].map { Self.isLeftOffline($0.phase) } ?? false }
        let existing = RelaunchPlanner.pathsToCheck(workspace: offline)
            .filter { FileManager.default.fileExists(atPath: $0) }
        return RelaunchPlanner.candidates(workspace: workspace, runtimes: runtimes, board: board,
                                          files: FileFacts(existingPaths: existing),
                                          liveProcesses: verifiedLiveProcesses())
    }

    /// The banner, unless it was answered or put off, or another copy of the app owns the sessions. Nil when no
    /// line can be relaunched (live orphans and missing project folders have their own messages).
    var relaunchOffer: RelaunchOffer? {
        guard !isRelaunchOfferDismissed, hookServerState != .anotherInstance, hasAgentsToRelaunch else { return nil }
        let relaunchable = relaunchCandidates().filter(\.status.isRelaunchable)
        return relaunchable.isEmpty ? nil : RelaunchOffer(relaunchable: relaunchable)
    }

    /// Some agent is offline since the previous run (`RelaunchPlanner` looks at no other phase).
    private var hasAgentsToRelaunch: Bool {
        runtimes.values.contains { Self.isLeftOffline($0.phase) }
    }

    /// The phases `RelaunchPlanner` offers to relaunch.
    private static func isLeftOffline(_ phase: AgentPhase) -> Bool {
        phase == .offline(.appRelaunched) || phase == .offline(.orphanElsewhere)
    }

    /// For each orphan whose previous `claude` still runs, its own `lastProcess` stamp, verified again now by pid AND
    /// start time (`isAlive`, the check that made it `.offline(.orphanElsewhere)`). Keyed by that agent: a pid number
    /// reused by the system, or found in another agent's stamp, never makes an agent an orphan. The other agents'
    /// stamps were found dead at launch, and a dead pid with its start time never comes back.
    private func verifiedLiveProcesses() -> [AgentID: ProcessStamp] {
        var verified: [AgentID: ProcessStamp] = [:]
        for agent in workspace.agents where runtimes[agent.id]?.phase == .offline(.orphanElsewhere) {
            guard let stamp = agent.lastProcess, Self.isAlive(stamp) else { continue }
            verified[agent.id] = stamp
        }
        return verified
    }

    // MARK: - Intents

    /// "Tout relancer": the lines checked by default (resume, fork), their post-its "En cours" put back to do.
    func relaunchAll() {
        let selections = relaunchCandidates()
            .filter { $0.selectedByDefault && $0.status.isRelaunchable }
            .map { RelaunchSelection(agentID: $0.agentID, cardChoice: .putBack) }
        relaunch(selections)
    }

    /// "Plus tard": the banner stays hidden until the next launch; every agent can still be relaunched on its own.
    func dismissRelaunchOffer() {
        isRelaunchOfferDismissed = true
    }

    /// "Relancer n sessions": each checked line is launched as its status says, read again now (an orphan may still
    /// hold the session, a folder may be gone). "Remettre à faire" is applied at once; "Continuer la
    /// tâche" waits for the session to start (`settlePendingContinuation`). The banner goes away.
    func relaunch(_ selections: [RelaunchSelection]) {
        guard !selections.isEmpty else { return }
        if claude.phase == .notFound {
            showToast("Claude Code est introuvable : indique son chemin, puis relance les sessions.", style: .error)
            post(.claudeSetup)
            return
        }
        isRelaunchOfferDismissed = true
        let fresh = Dictionary(relaunchCandidates().map { ($0.agentID, $0) }) { first, _ in first }
        for selection in selections {
            let agentID = selection.agentID
            // Relaunched meanwhile, or removed: nothing to do.
            guard let candidate = fresh[agentID] else { continue }
            guard let spec = launchSpec(for: candidate) else {
                showToast("\(names(of: agentID).agent) n'a pas été relancé : \(Self.reason(candidate.status)).",
                          style: .warning, agentID: agentID)
                continue
            }
            let cardID = candidate.cardInProgress
            if let cardID, selection.cardChoice == .putBack { applyTask(.putBack(cardID)) }
            let continued = selection.cardChoice == .continueTask ? cardID : nil
            launch(agentID, mode: spec.mode, workingDirectory: spec.folder) { [weak self] started in
                guard started, let continued, let self else { return }
                self.pendingContinuations[agentID] = continued
                self.settlePendingContinuation(agentID)
            }
        }
    }

    // MARK: - "Continuer la tâche" (C14)

    /// Called after every reduction of an agent with a pending "Continuer la tâche": applied once the session has
    /// started (`SessionStart` gave its id, or no hook ever came and the agent is in degraded mode, where the queue
    /// waits for the hooks anyway), never before: C14 needs the agent live, and the instruction belongs to the
    /// resumed conversation. Put at the head of the queue before the dispatcher looks at it. Dropped, the card left
    /// flagged, when the process ends first; dropped silently when the user settled the card meanwhile.
    func settlePendingContinuation(_ agentID: AgentID) {
        guard let cardID = pendingContinuations[agentID], let runtime = runtimes[agentID] else { return }
        guard runtime.pid != nil else {
            pendingContinuations[agentID] = nil
            if let card = board.card(cardID), card.column == .inProgress, card.assignee == agentID {
                showToast("\(names(of: agentID).agent) : la session n'a pas démarré. « \(card.title) » reste en "
                              + "cours, marqué session perdue.", style: .warning, agentID: agentID)
            }
            return
        }
        guard runtime.currentSessionID != nil || runtime.hookHealth == .degraded else { return }
        pendingContinuations[agentID] = nil
        guard let card = board.card(cardID), card.column == .inProgress, card.assignee == agentID,
              !card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags) else { return }
        applyTask(.continueTask(cardID, instructionID: InstructionID()))
    }

    // MARK: - Helpers

    /// How a line is launched: `--resume` in the session's folder, `--resume --fork-session` in the project folder,
    /// or a new session. Nil for a line that cannot be relaunched.
    private func launchSpec(for candidate: RelaunchCandidate) -> (mode: LaunchMode, folder: String?)? {
        switch candidate.status {
        case .resumable(let ref):
            return (.resume(sessionID: ref.sessionID), nil)
        case .forkInProjectFolder(let ref):
            guard let agent = workspace.agent(candidate.agentID),
                  let project = workspace.project(agent.projectID) else { return nil }
            return (.fork(fromSessionID: ref.sessionID), project.path)
        case .newSession:
            return (.new(initialPrompt: nil), nil)
        case .orphanAlive, .projectFolderMissing:
            return nil
        }
    }

    /// Why a line cannot be relaunched (French, for a toast).
    static func reason(_ status: RelaunchStatus) -> String {
        switch status {
        case .orphanAlive(let pid): "sa session tourne encore hors de l'app (pid \(pid))"
        case .projectFolderMissing(let path): "\(RelaunchPlanner.projectFolderMissingReason) (\(path))"
        case .resumable, .forkInProjectFolder, .newSession: "statut inattendu"
        }
    }
}
