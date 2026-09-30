import PixelCore

/// What the user may do with one agent now (buttons matrix of mockup 6(d), for the states of step 2a). Cards,
/// the terminal header and context menus all read it, so a button is never offered where the model would refuse.
@MainActor
struct AgentActions {
    let agentID: AgentID
    let runtime: AgentRuntime?
    /// A terminal exists (running, or kept after its process ended).
    let hasTerminal: Bool

    init(model: AppModel, agentID: AgentID) {
        self.agentID = agentID
        runtime = model.runtime(for: agentID)
        hasTerminal = model.hasTerminal(agentID) || model.sessions.isRunning(agentID)
    }

    var isRunning: Bool { runtime?.pid != nil }

    var isOffline: Bool {
        if case .offline = runtime?.phase { return true }
        return false
    }

    /// The agent's previous `claude` still runs outside the app (crash of a previous run, proposal 2.5).
    var isOrphan: Bool { runtime?.phase == .offline(.orphanElsewhere) }

    var isInError: Bool {
        if case .error = runtime?.phase { return true }
        return false
    }

    /// Terminal: every state but offline (6(d)).
    var canOpenTerminal: Bool { hasTerminal && !isOffline }

    /// Interrompre: thinking or working, no wait open, no interrupt already sent (5.8, one ESC only).
    var canInterrupt: Bool {
        guard let runtime, runtime.pid != nil, runtime.pendingWaits.isEmpty, runtime.interruptRequestedAt == nil else {
            return false
        }
        switch runtime.phase {
        case .thinking, .working: return true
        default: return false
        }
    }

    /// Why "Interrompre" is greyed out (tooltip).
    var interruptUnavailableReason: String {
        guard let runtime, runtime.pid != nil else { return "Aucune session en cours" }
        if !runtime.pendingWaits.isEmpty { return "L'agent attend ta réponse : réponds ou refuse dans le terminal" }
        if runtime.interruptRequestedAt != nil { return "Interruption déjà demandée" }
        if case .quotaPaused = runtime.phase { return "Interrompre annulerait la reprise automatique" }
        return "Seulement quand l'agent réfléchit ou travaille"
    }

    /// Relancer: offline (unless its previous process still runs), or in error once the process has ended.
    var canRelaunch: Bool {
        guard runtime != nil, !isRunning, !isOrphan else { return false }
        return isOffline || isInError
    }

    /// Fermer la session: any running process.
    var canClose: Bool { isRunning }

    /// Closing would interrupt a turn, a wait or a background task: ask first (6(d), "confirmation").
    var closeNeedsConfirmation: Bool {
        guard let runtime else { return false }
        return AppModel.isBusy(runtime)
    }

    /// Retirer: only an agent whose process is gone.
    var canRemove: Bool { runtime != nil && !isRunning }
}
