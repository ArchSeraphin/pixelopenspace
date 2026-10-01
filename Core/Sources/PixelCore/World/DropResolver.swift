import Foundation

/// What the drop rules read: the workspace, the agents' runtimes and the board, at the time of the drag.
public struct DropContext: Sendable {
    public var workspace: Workspace
    public var runtimes: [AgentID: AgentRuntime]
    public var board: TaskBoardState
    /// The user's home folder, to abbreviate paths with "~".
    public var home: String

    public init(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState, home: String) {
        self.workspace = workspace
        self.runtimes = runtimes
        self.board = board
        self.home = home
    }
}

/// What a drop does (the app performs it through `CommandCenter` and `TaskLifecycle`).
public enum DropAction: Hashable, Sendable {
    /// `TaskInput.assign`; across projects, the app first asks the confirmation of `TaskLifecycle.confirmation` (C3).
    case assign(TaskCardID, AgentID)
    /// Assign, then offer "Relancer la session".
    case assignOffline(TaskCardID, AgentID)
    /// Create an agent at that desk with the post-it as its positional prompt.
    case launchNewAgent(TaskCardID, ProjectID, deskIndex: Int)
    /// `DispatchPolicy.firstFreeAgent` of the project, chosen by the app when the card is dropped.
    case firstFreeAgent(TaskCardID, ProjectID)
    case none
}

public struct DropDecision: Hashable, Sendable {
    /// The copy operation. False with a feedback: the forbidden cursor and the reason; false without one: no
    /// operation (nothing to drop on there).
    public var accepted: Bool
    /// French, what will happen ("Donner à Nova · file #2"), or why not; empty when there is nothing to say.
    public var feedback: String
    /// What the scene marks under the post-it (`SceneInput.dropTarget`).
    public var highlight: SceneHitTarget?
    public var action: DropAction

    public init(accepted: Bool, feedback: String, highlight: SceneHitTarget?, action: DropAction) {
        self.accepted = accepted
        self.feedback = feedback
        self.highlight = highlight
        self.action = action
    }

    /// No operation, no message.
    public static let nothing = DropDecision(accepted: false, feedback: "", highlight: nil, action: .none)
}

/// The drop rules of the scene: the table of 3.9, for a post-it dragged over a target of the scene (a row of the
/// waiting tray or a dot of the minimap is the agent's target).
///
/// | Target | Decision |
/// |---|---|
/// | any target below, card outside "À faire" (C5) | refused: "Remets-la d'abord à faire." |
/// | agent of the app, its runtime `offline(.orphanElsewhere)` | refused: "Nova · terminal hors de l'app" |
/// | agent the card is already given to | nothing to do: "Déjà dans la file de Nova · file #n" |
/// | agent, free (`idle` or `done`) | `assign`: "Donner à Nova · file #n", n = its queue + 1 (instructions count) |
/// | agent waiting for the user | `assign`: "Donner à Nova · sera livré après ton accord" |
/// | agent busy (any other live state) | `assign`: "Donner à Nova · en file #n" |
/// | agent of another project (C3) | `assign`: "Donner à Sol · autre projet : ~/dev/infra" (the app confirms) |
/// | agent offline (or never launched) | `assignOffline`: "Donner à Kiwi · hors ligne : sera livré après relance" |
/// | free desk | `launchNewAgent`: "Nouvel agent avec ce post-it" |
/// | floor or sign of an island | `firstFreeAgent`: "Premier agent libre de API", the whole rug marked |
/// | anything else, an agent or project that is gone or archived, a desk taken since | nothing |
///
/// Another project and offline add up: "Donner à Sol · autre projet : ~/dev/infra · hors ligne : sera livré après
/// relance".
public enum DropResolver {
    public static func decide(card: TaskCard, over target: SceneHitTarget?, context: DropContext) -> DropDecision {
        guard let target else { return .nothing }
        switch target {
        case .agent(let agent):
            return decide(card: card, agent: agent, context: context)
        case .freeDesk(let projectID, let deskIndex):
            guard context.workspace.liveProject(projectID) != nil, deskIndex >= 0,
                  !context.workspace.agents.contains(where: { $0.projectID == projectID && $0.deskIndex == deskIndex })
            else { return .nothing }
            if let refusal = refusal(card) { return refusal }
            return DropDecision(accepted: true, feedback: "Nouvel agent avec ce post-it", highlight: target,
                                action: .launchNewAgent(card.id, projectID, deskIndex: deskIndex))
        case .islandFloor(let projectID, let part), .islandSign(let projectID, let part):
            guard let project = context.workspace.liveProject(projectID) else { return .nothing }
            if let refusal = refusal(card) { return refusal }
            return DropDecision(accepted: true, feedback: "Premier agent libre de \(project.name)",
                                highlight: .islandFloor(projectID, part: part),
                                action: .firstFreeAgent(card.id, projectID))
        case .corkWall, .elevator, .hallProp, .floor:
            return .nothing
        }
    }

    /// C5: only a card of "À faire" enters a queue.
    static func refusal(_ card: TaskCard) -> DropDecision? {
        guard card.column != .todo else { return nil }
        return DropDecision(accepted: false, feedback: TaskLifecycle.Message.putBackFirst, highlight: nil, action: .none)
    }

    static func decide(card: TaskCard, agent id: AgentID, context: DropContext) -> DropDecision {
        let workspace = context.workspace
        guard let agent = workspace.agent(id), let project = workspace.liveProject(agent.projectID) else { return .nothing }
        if let refusal = refusal(card) { return refusal }
        let runtime = context.runtimes[id] ?? AgentRuntime(phase: .offline(.notStarted), phaseSince: Date(timeIntervalSince1970: 0))
        if runtime.phase == .offline(.orphanElsewhere) {
            return DropDecision(accepted: false, feedback: "\(agent.name) · terminal hors de l'app", highlight: nil,
                                action: .none)
        }
        let queue = BoardQuery.queue(of: id, in: context.board)
        if card.assignee == id {
            // `TaskLifecycle` would change nothing.
            let position = queue.firstIndex(of: .card(card.id)).map { " · file #\($0 + 1)" } ?? ""
            return DropDecision(accepted: false, feedback: "Déjà dans la file de \(agent.name)\(position)",
                                highlight: .agent(id), action: .none)
        }

        var parts = ["Donner à \(agent.name)"]
        let acrossProjects = needsConfirmation(card, to: id, context: context)
        if acrossProjects { parts.append("autre projet : \(abbreviated(project.path, home: context.home))") }
        let offline: Bool
        if case .offline = runtime.phase { offline = true } else { offline = false }
        let position = queue.count + 1
        if offline {
            parts.append("hors ligne : sera livré après relance")
        } else if !acrossProjects {
            switch runtime.kind {
            case .waitingInput: parts.append("sera livré après ton accord")
            case .idle, .done: parts.append("file #\(position)")
            default: parts.append("en file #\(position)")
            }
        }
        return DropDecision(accepted: true, feedback: parts.joined(separator: " · "), highlight: .agent(id),
                            action: offline ? .assignOffline(card.id, id) : .assign(card.id, id))
    }

    /// The confirmation C3 that the app asks before the assignment (`TaskLifecycle.confirmation`), with the dragged
    /// card as it is now.
    static func needsConfirmation(_ card: TaskCard, to agent: AgentID, context: DropContext) -> Bool {
        var board = context.board
        if let index = board.cards.firstIndex(where: { $0.id == card.id }) {
            board.cards[index] = card
        } else {
            board.cards.append(card)
        }
        let taskContext = TaskContext(now: Date(timeIntervalSince1970: 0), agentProjects: context.workspace.liveAgentProjects,
                                      liveAgents: [])
        guard case .assignAcrossProjects? = TaskLifecycle.confirmation(for: .assign(card.id, to: agent), state: board,
                                                                       context: taskContext)
        else { return false }
        return true
    }

    /// "~/dev/api" for a folder in `home`, the path itself elsewhere.
    static func abbreviated(_ path: String, home: String) -> String {
        let base = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !base.isEmpty, base != "/", path == base || path.hasPrefix(base + "/") else { return path }
        return "~" + path.dropFirst(base.count)
    }
}
