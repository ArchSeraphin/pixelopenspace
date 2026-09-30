import Foundation
import PixelCore

/// The cork board (proposal 3.5, 4.3b): every change goes through `TaskLifecycle.reduce` (`applyTask`), whose
/// effects are executed here. The board panel, the card editor and the agents' cards read the queries below.
/// `.pump` asks the `TaskDispatcher` to look at the agent's queue (step 2b-2).
extension AppModel {
    // MARK: - Reducer

    /// Reduces one input with a fresh `TaskContext`, stores the new board, then executes the effects in order.
    @discardableResult
    func applyTask(_ input: TaskInput) -> [TaskEffect] {
        applyTasks([input])
    }

    /// The confirmation to ask for before `applyTask(input)` (C3, C18 from "À faire" or "En cours", C20 from
    /// "En cours"), if any.
    func taskConfirmation(for input: TaskInput) -> ConfirmationKind? {
        TaskLifecycle.confirmation(for: input, state: board, context: taskContext())
    }

    /// Reduces the inputs in order against one context, stores the board once, then executes all the effects.
    /// "Réessayer" (C9) and "Continuer la tâche" (C14) also resume the agent's queue, paused by the failure or the
    /// interruption (`resumeQueue`).
    @discardableResult
    private func applyTasks(_ inputs: [TaskInput]) -> [TaskEffect] {
        let context = taskContext()
        var next = board
        var effects: [TaskEffect] = []
        var resumed: [AgentID] = []
        for input in inputs {
            let (reduced, emitted) = TaskLifecycle.reduce(next, input, context: context)
            next = reduced
            effects += emitted
            let refused = emitted.contains { if case .rejected = $0 { return true } else { return false } }
            if !refused, let agent = Self.agentResumed(by: input, in: reduced) { resumed.append(agent) }
        }
        commitBoard(next)
        for agent in resumed {
            resumeQueue(agent)
        }
        for effect in effects {
            perform(effect)
        }
        return effects
    }

    /// C9 and C14 resume the queue of the card's agent (4.3b: "reprise de la file").
    private static func agentResumed(by input: TaskInput, in board: TaskBoardState) -> AgentID? {
        switch input {
        case .retry(let id), .continueTask(let id, _): board.card(id)?.assignee
        default: nil
        }
    }

    /// What the reducer reads about the world, now: each agent's project, the running agents and their current
    /// session, the projects' names.
    func taskContext() -> TaskContext {
        let live = runtimes.filter { $0.value.pid != nil }
        let agentProjects = Dictionary(workspace.agents.map { ($0.id, $0.projectID) }) { first, _ in first }
        let projectNames = Dictionary(workspace.projects.map { ($0.id, $0.name) }) { first, _ in first }
        return TaskContext(now: Date(), agentProjects: agentProjects, liveAgents: Set(live.keys),
                           sessionIDs: live.compactMapValues(\.currentSessionID), projectNames: projectNames)
    }

    private func perform(_ effect: TaskEffect) {
        switch effect {
        case .pump(let agentID):
            dispatcher.pump(agentID)
        case .notify(let text):
            showToast(text, style: .warning)
        case .rejected(_, let message):
            showToast(message)
        case .warn(let text):
            showToast(text, style: .warning)
        case .validated:
            // XP arrives with step 6.
            break
        }
    }

    // MARK: - Intents

    /// ⌘N: a card at the end of "À faire". `nil` when the title is blank or the card was refused.
    @discardableResult
    func createCard(title: String, projectID: ProjectID?) -> TaskCardID? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = TaskCardID()
        applyTask(.create(id: id, title: title, details: "", projectID: knownProject(projectID), priority: .normal,
                          tags: [], templateID: nil))
        return board.card(id) == nil ? nil : id
    }

    /// "Coller une liste": one card per item of the pasted list (`PasteImporter`), in order, saved at once.
    /// Returns the ids of the cards created.
    @discardableResult
    func createCards(fromPasted text: String, projectID: ProjectID?) -> [TaskCardID] {
        let pasted = PasteImporter.cards(from: text)
        guard !pasted.isEmpty else { return [] }
        let project = knownProject(projectID)
        let ids = pasted.map { _ in TaskCardID() }
        applyTasks(zip(ids, pasted).map { id, card in
            .create(id: id, title: card.title, details: card.details, projectID: project, priority: .normal,
                    tags: [], templateID: nil)
        })
        return ids.filter { board.card($0) != nil }
    }

    /// A project of the workspace, else no project (a card never points to an unknown project, as at load).
    private func knownProject(_ id: ProjectID?) -> ProjectID? {
        id.flatMap { workspace.project($0) == nil ? nil : $0 }
    }

    // MARK: - Queries

    /// The card's prompt exactly as the dispatcher will type it (step 2b-2): its template (the card's, else its
    /// project's default), filled by `PromptComposer`, cleaned by `PromptSanitizer` (mockup 6(l)).
    func promptPreview(for cardID: TaskCardID) -> SanitizedPrompt? {
        board.card(cardID).map(promptPreview(for:))
    }

    /// Same as `promptPreview(for:)` for a card value: the editor passes the stored card with the fields being
    /// edited, so that the preview follows the typing before anything is saved.
    func promptPreview(for card: TaskCard) -> SanitizedPrompt {
        let project = card.projectID.flatMap { workspace.project($0) }
        let template = PromptComposer.resolveTemplate(card: card, projectDefault: project?.defaults.templateID,
                                                      in: board)
        let subject = PromptSubject(card: card, projectName: project?.name, projectPath: project?.path)
        return PromptSanitizer.sanitize(PromptComposer.compose(subject, template: template))
    }

    /// The agent's queue: its instructions, then its queued cards.
    func queue(of agent: AgentID) -> [QueueItem] {
        BoardQuery.queue(of: agent, in: board)
    }

    /// "file #2": 1-based position of a queued card in its agent's queue.
    func queuePosition(of card: TaskCardID) -> Int? {
        BoardQuery.queuePosition(of: card, in: board)
    }

    /// The card the agent is working on ("En cours"), if any.
    func currentCard(of agent: AgentID) -> TaskCard? {
        BoardQuery.currentCard(of: agent, in: board)
    }

    /// Why the head of the agent's queue is not being delivered (`DispatchPolicy`, on the last screen reading and the
    /// model's clock); nil when the queue is empty or a delivery can start.
    func deliveryWaitCause(of agentID: AgentID) -> WaitCause? {
        guard let agent = workspace.agent(agentID), let runtime = runtimes[agentID] else { return nil }
        let queue = queue(of: agentID)
        guard !queue.isEmpty else { return nil }
        let decision = DispatchPolicy.nextDelivery(agent: agent, runtime: runtime, queue: queue, now: now,
                                                   lastTurnEndedAt: dispatcher.lastTurnEndedAt[agentID],
                                                   settings: DispatchSettings(settings: settings),
                                                   draftOverride: dispatcher.draftOverride(for: agentID,
                                                                                           screen: runtime.screen))
        if case .wait(let cause) = decision { return cause }
        return nil
    }

    /// The project a card is given to by "Premier agent libre" or "Lancer un nouvel agent": its own, else the one
    /// selected (a card without project).
    func dispatchProject(for card: TaskCard) -> ProjectID? {
        (card.projectID ?? selectedProjectID).flatMap { workspace.project($0)?.id }
    }

    /// "Premier agent libre" (3.6): the agent of the card's project it would go to; nil when no agent of that
    /// project runs (the app then offers "Lancer un nouvel agent avec ce post-it").
    func firstFreeAgent(for card: TaskCard) -> AgentID? {
        guard let projectID = dispatchProject(for: card) else { return nil }
        let agents = workspace.agents(in: projectID)
        let lengths = Dictionary(agents.map { ($0.id, queue(of: $0.id).count) }) { first, _ in first }
        return DispatchPolicy.firstFreeAgent(in: projectID, agents: agents, runtimes: runtimes, queueLengths: lengths)
    }

    /// The four columns under `boardFilter` (every column present, possibly empty).
    var filteredBoard: [Column: [TaskCard]] {
        BoardQuery.filtered(board, boardFilter)
    }
}
