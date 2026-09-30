import Foundation
import PixelCore

/// The cork board (proposal 3.5, 4.3b): every change goes through `TaskLifecycle.reduce` (`applyTask`), whose
/// effects are executed here. The board panel, the card editor and the agents' cards read the queries below.
/// Nothing is delivered to a terminal yet: `.pump` is only logged until the dispatcher (step 2b-2).
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
    @discardableResult
    private func applyTasks(_ inputs: [TaskInput]) -> [TaskEffect] {
        let context = taskContext()
        var next = board
        var effects: [TaskEffect] = []
        for input in inputs {
            let (reduced, emitted) = TaskLifecycle.reduce(next, input, context: context)
            next = reduced
            effects += emitted
        }
        commitBoard(next)
        for effect in effects {
            perform(effect)
        }
        return effects
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
            // The dispatcher arrives with step 2b-2: nothing is typed into a terminal yet.
            AppLog.sessions.debug("pump \(agentID.description, privacy: .public): no delivery before step 2b-2")
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
        guard let card = board.card(cardID) else { return nil }
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

    /// The four columns under `boardFilter` (every column present, possibly empty).
    var filteredBoard: [Column: [TaskCard]] {
        BoardQuery.filtered(board, boardFilter)
    }
}
