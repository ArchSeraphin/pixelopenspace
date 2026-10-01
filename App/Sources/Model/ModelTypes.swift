import Foundation
import PixelCore

/// A short message shown for a few seconds (French), newest last.
struct Toast: Identifiable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case info, warning, error
    }

    let id: UUID
    let text: String
    let style: Style
    /// The agent it is about, if any (the UI can offer "Afficher").
    let agentID: AgentID?
    let createdAt: Date
}

/// "Bring this agent into view" (notification click, ⌘'…). A new `id` each time, so the same agent can be asked
/// for twice in a row.
struct FocusRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let agentID: AgentID
}

/// Something only the UI can do (a sheet, a window, the Settings scene). Posted by `CommandCenter` and by the
/// model; the UI performs it, then calls `AppModel.consumeUIRequest(_:)`.
enum UIRequest: Equatable, Sendable {
    /// "Nouveau projet" sheet (folder picker, mockup 6(m)).
    case newProject
    /// "Nouvel agent" sheet (mockup 6(n)), for this project or the selected one.
    case newAgent(ProjectID?)
    /// Settings scene (SwiftUI `openSettings`).
    case showSettings
    case toggleTerminalPanel
    /// Show this agent's terminal (panel or window).
    case openTerminal(AgentID)
    /// Welcome sheet: Claude Code not found (mockup 6(r)).
    case claudeSetup
    /// ⌘N: the board panel shows, with the title field at the top of "À faire" (mockup 6(c)).
    case newCard
    /// ⇧⌘V: "Coller une liste" sheet, prefilled with the clipboard.
    case pasteCards
    /// "Gérer les modèles" sheet (mockup 6(l)).
    case manageTemplates
    /// ⌘B: show or hide the board panel.
    case toggleBoard
    /// ⌘L: the list view, or back to the open space.
    case toggleListView
    /// ⌘+, ⌘−: the next or previous zoom of the open space, about the view's centre.
    case zoomIn
    case zoomOut
    /// ⌘0, "Tout voir" (3.9).
    case fitAll
}

struct PendingUIRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: UIRequest
}

/// An agent that quitting would interrupt (mockup 6(p)).
struct QuitEntry: Identifiable, Equatable, Sendable {
    let agentID: AgentID
    let agentName: String
    let projectName: String
    let display: AgentStatusDisplay

    var id: AgentID { agentID }
}

struct QuitAssessment: Equatable, Sendable {
    /// Agents that are thinking, working, waiting for the user or for background tasks, or paused by the quota.
    var busy: [QuitEntry]
    /// Every running session (quitting closes them all).
    var runningSessions: Int

    var canQuitImmediately: Bool { busy.isEmpty }
}

/// Shown by the UI as the quit sheet; answered with `AppModel.respondToQuit(_:)`.
struct QuitRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    var assessment: QuitAssessment
}

enum QuitChoice: Equatable, Sendable {
    case cancel
    /// Close every session now (SIGTERM, then SIGKILL after 2 s) and quit.
    case quitAnyway
    /// Quit by itself once no agent is busy any more; waits stay for the user to answer.
    case waitForTurns
}

/// What becomes of a relaunched agent's post-it "En cours" (mockup 6(p)).
enum RelaunchCardChoice: Equatable, Hashable, Sendable {
    /// "Continuer la tâche" (C14): once the session has started, never before, a "Continue la tâche" instruction
    /// goes to the head of the agent's queue.
    case continueTask
    /// "Remettre à faire" (C15), at once. The default, and what "Tout relancer" does.
    case putBack
}

/// A line of the "Relancer les sessions" sheet the user checked.
struct RelaunchSelection: Equatable, Sendable {
    let agentID: AgentID
    /// Applies to the agent's post-it "En cours", if it has one.
    let cardChoice: RelaunchCardChoice
}

/// What `AppModel.relaunchCandidates` reads outside the model, cached (`AppModel.relaunchProbe`) because the banner
/// and the sheet render often (the sheet every second, for "il y a 2 h"): the paths of `RelaunchPlanner.pathsToCheck`
/// that exist, and the orphans whose previous `claude` was verified alive.
struct RelaunchProbe: Equatable, Sendable {
    var existingPaths: Set<String>
    var liveProcesses: [AgentID: ProcessStamp]
}

/// The banner "n sessions peuvent être relancées" (proposal 2.5): the candidates that can be relaunched (resume,
/// fork, new session), in sidebar order. Live orphans and projects whose folder is gone are not counted.
struct RelaunchOffer: Equatable, Sendable {
    let relaunchable: [RelaunchCandidate]

    /// What "Tout relancer" relaunches: the lines checked by default (resume and fork).
    var byDefault: [RelaunchCandidate] { relaunchable.filter(\.selectedByDefault) }
}

/// State of the hook pipeline, for the sidebar ("HOOKS ● actifs 6/6") and the degraded-mode banner (mockup 6(o)).
struct HookStatus: Equatable, Sendable {
    var server: HookServerState
    /// Agents with a running process.
    var runningAgents: Int
    /// Running agents whose hooks arrive.
    var healthyAgents: Int
    /// Running agents without any hook since their launch (degraded mode, 4.4).
    var degradedAgents: [AgentID]
    /// French banner text when something is wrong, `nil` otherwise.
    var problem: String?
}
