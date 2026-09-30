import Foundation

/// What the reducer needs to know about the world (all read by the caller, at call time).
public struct TaskContext: Sendable {
    public var now: Date
    /// Project of each app agent (unknown agents are absent).
    public var agentProjects: [AgentID: ProjectID]
    /// Agents whose `claude` process is running.
    public var liveAgents: Set<AgentID>
    /// Current Claude Code session of the live agents (`AgentRuntime.currentSessionID`), when known: C17 warns when
    /// it differs from the session the card was delivered to. An agent missing here never triggers the warning.
    public var sessionIDs: [AgentID: String]
    /// Names of the projects, for the history: C3 notes the project a card came from. A project missing here is
    /// written as its id.
    public var projectNames: [ProjectID: String]

    public init(now: Date, agentProjects: [AgentID: ProjectID], liveAgents: Set<AgentID>,
                sessionIDs: [AgentID: String] = [:], projectNames: [ProjectID: String] = [:]) {
        self.now = now
        self.agentProjects = agentProjects
        self.liveAgents = liveAgents
        self.sessionIDs = sessionIDs
        self.projectNames = projectNames
    }
}

/// Everything that changes the board: the user's actions, the dispatcher's deliveries and the agents' signals.
public enum TaskInput: Equatable, Sendable {
    /// C1, appended at the end of "À faire".
    case create(id: TaskCardID, title: String, details: String, projectID: ProjectID?, priority: Priority,
                tags: [String], templateID: PromptTemplateID?)
    case edit(TaskCardID, CardEdit)
    /// C2 / C3 (project changes to the agent's); to another agent, C4 (reassign).
    case assign(TaskCardID, to: AgentID)
    /// C4.
    case unassign(TaskCardID)
    /// C4, inside the assignee's queue (nil = head of its cards, still after its instructions).
    case reorderQueue(TaskCardID, after: TaskCardID?)
    /// Drag between or inside columns: C5, C15, C16, C18, and C19 from "Fait"; same column = reorder.
    /// `after`: the card of the target column it is dropped after, nil = at the top.
    case move(TaskCardID, to: Column, after: TaskCardID?)
    /// C6.
    case deliveryStarted(QueueItem, agent: AgentID, sessionID: String?)
    /// C7, C8, C10 to C13.
    case agentSignal(AgentID, AgentCardSignal)
    /// C9.
    case retry(TaskCardID)
    /// C14.
    case continueTask(TaskCardID, instructionID: InstructionID)
    /// C15.
    case putBack(TaskCardID)
    /// C16.
    case markForReview(TaskCardID)
    /// C17.
    case resend(TaskCardID, precision: String, instructionID: InstructionID)
    /// C18.
    case validate(TaskCardID)
    /// C19.
    case reopen(TaskCardID)
    /// C20.
    case delete(TaskCardID)
    case giveInstruction(agent: AgentID, text: String, instructionID: InstructionID, atHead: Bool)
    case agentRemoved(AgentID)
    case upsertTemplate(PromptTemplate)
    /// Cards using it fall back to nil.
    case deleteTemplate(PromptTemplateID)
}

/// What the editor changes on a card (column, assignment and delivery only change through the other inputs).
public enum CardEdit: Equatable, Sendable {
    case title(String), details(String), priority(Priority), tags([String]), template(PromptTemplateID?),
         project(ProjectID?)
}

/// Why an input was refused. `notAllowed` carries a short English reason (logs, tests); the user reads the
/// message of `TaskEffect.rejected`.
public enum TaskRejection: Equatable, Sendable {
    case unknownCard, unknownAgent, notInTodo, dragToInProgress, notAllowed(String)
}

public enum TaskEffect: Equatable, Sendable {
    /// The dispatcher (step 2b-2) may deliver the head of this queue.
    case pump(AgentID)
    /// French text, e.g. "Échec d'envoi de « Titre » à l'agent. La file est en pause." A title (or instruction)
    /// longer than 40 characters is cut, ending with "…": the text is one line of a notification.
    case notify(String)
    /// XP later (step 6): `firstTime` at most once per card, and only for a card delivered at least once.
    case validated(TaskCardID, firstTime: Bool)
    /// UI toast; the state is unchanged.
    case rejected(TaskRejection, message: String)
    /// C17 session changed, and similar.
    case warn(String)
}

/// Asked by the UI before applying an input (C3, C18 from todo or inProgress, C20 from inProgress).
public enum ConfirmationKind: Equatable, Sendable {
    case assignAcrossProjects(agent: AgentID, from: ProjectID?, to: ProjectID)
    case markDoneWithoutReview(TaskCardID)
    case deleteInProgress(TaskCardID)
}

/// Pure reducer of the cork board: transition table C1 to C20 of proposal 4.3b, plus instructions, agent removal
/// and templates. Never reads a clock (`TaskContext.now`), never makes an id (the caller passes them).
///
/// An accepted transition appends a `CardEvent` to the history of every card it changes and sets its `updatedAt`.
/// An input with nothing to change (same value, already in place, no matching card for a signal) changes nothing
/// and emits nothing. A refused input changes nothing at all, not even `updatedAt`, and emits exactly one
/// `.rejected`.
///
/// Invariants kept (property tests): at most one running "En cours" card per agent (one without a stopping flag,
/// `TaskBoardValidator.stoppingFlags`), a card arriving in "En cours" marks the other one interrupted;
/// `queueRank != nil` exactly on queued cards (`todo`, assigned); a pending delivery only on a queued card, and at
/// most one queue item per agent being delivered; each agent's queue keys strictly ascending (instructions, then
/// cards); unique ranks in each column; assignees are agents of `agentProjects`; a card only disappears by
/// `delete`; a card is validated for the first time at most once.
public enum TaskLifecycle {
    /// Applies one input. Returns the new board and the side effects for the app layer, in order.
    public static func reduce(_ state: TaskBoardState, _ input: TaskInput, context: TaskContext)
        -> (TaskBoardState, [TaskEffect]) {
        var step = Step(board: state, context: context)
        switch input {
        case .create(let id, let title, let details, let projectID, let priority, let tags, let templateID):
            step.create(id: id, title: title, details: details, projectID: projectID, priority: priority, tags: tags,
                        templateID: templateID)
        case .edit(let id, let change):
            step.edit(id, change)
        case .assign(let id, let agent):
            step.assign(id, to: agent)
        case .unassign(let id):
            step.unassign(id)
        case .reorderQueue(let id, let after):
            step.reorderQueue(id, after: after)
        case .move(let id, let column, let after):
            step.move(id, to: column, after: after)
        case .deliveryStarted(let item, let agent, let sessionID):
            step.deliveryStarted(item, agent: agent, sessionID: sessionID)
        case .agentSignal(let agent, let signal):
            step.agentSignal(agent, signal)
        case .retry(let id):
            step.retry(id)
        case .continueTask(let id, let instructionID):
            step.continueTask(id, instructionID: instructionID)
        case .putBack(let id):
            step.putBack(id)
        case .markForReview(let id):
            step.markForReview(id)
        case .resend(let id, let precision, let instructionID):
            step.resend(id, precision: precision, instructionID: instructionID)
        case .validate(let id):
            step.validate(id)
        case .reopen(let id):
            step.reopen(id)
        case .delete(let id):
            step.delete(id)
        case .giveInstruction(let agent, let text, let instructionID, let atHead):
            step.giveInstruction(agent: agent, text: text, instructionID: instructionID, atHead: atHead)
        case .agentRemoved(let agent):
            step.agentRemoved(agent)
        case .upsertTemplate(let template):
            step.upsertTemplate(template)
        case .deleteTemplate(let id):
            step.deleteTemplate(id)
        }
        if let refusal = step.refusal {
            return (state, [.rejected(refusal.rejection, message: refusal.message)])
        }
        return (step.board, step.effects)
    }

    /// The confirmation the UI asks for before applying `input`, if any (C3, C18 from "À faire" or "En cours",
    /// C20 from "En cours"). Nil as well for an input the reducer would refuse.
    public static func confirmation(for input: TaskInput, state: TaskBoardState, context: TaskContext)
        -> ConfirmationKind? {
        switch input {
        case .assign(let id, let agent):
            guard let card = state.card(id), card.column == .todo, card.assignee != agent,
                  let target = context.agentProjects[agent], let current = card.projectID, current != target
            else { return nil }
            return .assignAcrossProjects(agent: agent, from: current, to: target)
        case .validate(let id), .move(let id, to: .done, after: _):
            guard let column = state.card(id)?.column, column == .todo || column == .inProgress else { return nil }
            return .markDoneWithoutReview(id)
        case .delete(let id):
            guard state.card(id)?.column == .inProgress else { return nil }
            return .deleteInProgress(id)
        default:
            return nil
        }
    }
}

extension TaskLifecycle {
    /// Texts for the user (French).
    enum Message {
        static let unknownCard = "Ce post-it n'existe plus."
        static let unknownAgent = "Cet agent n'existe plus."
        static let unknownInstruction = "Cette consigne n'existe plus."
        static let unknownTemplate = "Ce modèle n'existe plus."
        static let duplicateCard = "Ce post-it existe déjà."
        static let duplicateInstruction = "Cette consigne existe déjà."
        static let emptyTitle = "Un post-it a besoin d'un titre."
        static let emptyTemplateName = "Un modèle a besoin d'un nom."
        static let emptyInstruction = "La consigne est vide."
        static let emptyPrecision = "La précision est vide."
        /// C5, a card of "À faire" dropped on "En cours".
        static let dropOnAgent = "Glisse-la sur un agent pour la lancer."
        /// C5, a card of another column assigned or dropped on "En cours".
        static let putBackFirst = "Remets-la d'abord à faire."
        static let relaunchFirst = "Relance d'abord la session de l'agent."
        /// The project of an assigned card is its agent's (C3): a queued card leaves the queue first, a card of
        /// "En cours" or "À valider" goes back to "À faire" (C15), a done card is reopened (C19).
        static let projectLocked = "Retire d'abord ce post-it de la file de son agent pour changer de projet."
        static let projectLockedPutBackFirst = "Remets d'abord ce post-it à faire pour changer de projet."
        static let projectLockedReopenFirst = "Rouvre d'abord ce post-it pour changer de projet."
        static let notInQueue = "Seul un post-it à faire peut entrer dans une file ou en sortir."
        static let notQueued = "Ce post-it n'est dans la file d'aucun agent."
        static let notSameQueue = "Ce post-it n'est pas dans la même file."
        static let positionNotInColumn = "Cette place n'est pas dans la colonne visée."
        static let notHeadOfQueue = "Seul l'élément en tête de file peut être envoyé."
        static let nothingToRetry = "Aucun envoi à réessayer pour ce post-it."
        static let continueNeedsInProgress = "Seul un post-it en cours peut être continué."
        static let nothingToContinue = "Ce post-it n'a été ni interrompu ni arrêté."
        static let otherCardRunning = "L'agent travaille déjà sur un autre post-it."
        static let reviewNeedsInProgress = "Seul un post-it en cours peut passer à valider."
        static let resendNeedsReview = "Seul un post-it à valider peut être renvoyé."
        static let noAgentToResend = "Ce post-it n'a plus d'agent à qui le renvoyer."
        static let alreadyTodo = "Ce post-it est déjà à faire."
        static let alreadyDone = "Ce post-it est déjà fait."
        static let reopenNeedsDone = "Seul un post-it fait peut être rouvert."
        static let reopenInstead = "Ce post-it est fait : rouvre-le plutôt."
        static let sessionChanged = "La session de l'agent a changé depuis l'envoi : la précision part dans une autre conversation."

        /// C8, the title cut at 40 characters (`quoted`).
        static func deliveryFailed(_ title: String) -> String {
            "Échec d'envoi de \(quoted(title)) à l'agent. La file est en pause."
        }

        /// C14.
        static func continueTask(_ title: String) -> String {
            "Continue la tâche : \(title)"
        }

        /// C15, C16, C18: instructions tied to the card, not sent yet, left the agent's queue.
        static func instructionsDropped(_ count: Int) -> String {
            count == 1
                ? "La consigne en attente pour ce post-it a été retirée de la file de l'agent."
                : "Les \(count) consignes en attente pour ce post-it ont été retirées de la file de l'agent."
        }

        /// « text », cut at 40 characters.
        static func quoted(_ text: String) -> String {
            let limit = 40
            let short = text.count > limit ? String(text.prefix(limit)) + "…" : text
            return "« \(short) »"
        }
    }

    /// Notes of the history (French).
    enum Note {
        static let agentRemoved = "agent retiré"
        static let staleDelivery = "envoi jamais confirmé, remplacé par un autre"
        static let backgroundTasks = "tâche de fond en cours"
        static let otherCardStarted = "un autre post-it a démarré pour cet agent"
        static let retry = "nouvel essai d'envoi"
        static let sessionLost = "session perdue"
        static let templateDeleted = "modèle supprimé"

        static func turn(_ promptID: String?, after prefix: String? = nil) -> String? {
            let parts = [prefix, promptID.map { "tour \($0)" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        /// C3: the project the card came from, by name when the caller gave it, else by id.
        static func previousProject(_ project: ProjectID?, names: [ProjectID: String]) -> String {
            "projet précédent : " + (project.map { names[$0] ?? $0.description } ?? "aucun")
        }

        static func precision(_ text: String) -> String {
            let limit = 40
            return "précision : " + (text.count > limit ? String(text.prefix(limit)) + "…" : text)
        }

        static func abort(_ reason: DeliveryAbortReason) -> String {
            switch reason {
            case .guardFailed(let detail): "garde non remplie : \(detail)"
            case .noPromptSubmit: "aucune confirmation de Claude Code"
            case .processGone: "session terminée"
            }
        }
    }
}

/// One reduction in progress: the board being changed, the effects emitted so far, and the refusal if any.
private struct Step {
    typealias M = TaskLifecycle.Message
    typealias N = TaskLifecycle.Note

    var board: TaskBoardState
    var effects: [TaskEffect] = []
    var refusal: (rejection: TaskRejection, message: String)?
    let context: TaskContext
    /// Copy it to a local before an optional-chained write to `board` (`board.cards[i].delivery?.x = now` reads
    /// `self` inside the write access).
    let now: Date

    init(board: TaskBoardState, context: TaskContext) {
        self.board = board
        self.context = context
        self.now = context.now
    }

    // MARK: - Helpers

    mutating func emit(_ effect: TaskEffect) {
        effects.append(effect)
    }

    /// Refuses the input: `reduce` returns the board it was given and this rejection only.
    mutating func reject(_ rejection: TaskRejection, _ message: String) {
        if refusal == nil { refusal = (rejection, message) }
    }

    mutating func refuse(_ reason: String, _ message: String) {
        reject(.notAllowed(reason), message)
    }

    func index(of id: TaskCardID) -> Int? {
        board.cards.firstIndex { $0.id == id }
    }

    func instructionExists(_ id: InstructionID) -> Bool {
        board.instructions.contains { $0.id == id }
    }

    /// Appends an event to card `i` and dates the change.
    mutating func record(_ i: Int, _ kind: CardEventKind, from: Column? = nil, to: Column? = nil,
                         agent: AgentID? = nil, note: String? = nil) {
        board.cards[i].history.append(CardEvent(at: now, kind: kind, from: from, to: to, agentID: agent, note: note))
        board.cards[i].updatedAt = now
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Columns

    /// Indices of a column's cards in display order, `excluded` left out.
    func column(_ column: Column, excluding excluded: TaskCardID? = nil) -> [Int] {
        board.cards.indices
            .filter { board.cards[$0].column == column && board.cards[$0].id != excluded }
            .sorted { TaskCard.displayOrder(board.cards[$0], board.cards[$1]) }
    }

    /// A rank after every other card of the column.
    func rankAtEnd(of column: Column, excluding excluded: TaskCardID) -> String {
        RankKey.after(self.column(column, excluding: excluded).map { board.cards[$0].rank }.max())
    }

    /// The rank that puts card `id` right after `other` in `column` (nil: at the top). Refuses the input and
    /// returns nil when `other` is not another card of that column.
    mutating func rank(in column: Column, after other: TaskCardID?, moving id: TaskCardID) -> String? {
        let others = self.column(column, excluding: id)
        guard let other else { return RankKey.before(others.map { board.cards[$0].rank }.min()) }
        guard let position = others.firstIndex(where: { board.cards[$0].id == other }) else {
            if index(of: other) == nil {
                reject(.unknownCard, M.unknownCard)
            } else {
                refuse("notInColumn", M.positionNotInColumn)
            }
            return nil
        }
        let upper = position + 1 < others.count ? board.cards[others[position + 1]].rank : nil
        return RankKey.between(board.cards[others[position]].rank, upper)
    }

    // MARK: Queues

    /// Queue order of instructions: key, then creation, then id (total and deterministic).
    static func queueOrder(_ a: QueuedInstruction, _ b: QueuedInstruction) -> Bool {
        if a.queueRank != b.queueRank { return a.queueRank < b.queueRank }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    /// Queue order of cards: key, then column order.
    static func queueOrder(_ a: TaskCard, _ b: TaskCard) -> Bool {
        if a.queueRank != b.queueRank { return (a.queueRank ?? "") < (b.queueRank ?? "") }
        return TaskCard.displayOrder(a, b)
    }

    /// Indices of the agent's instructions, in queue order.
    func instructions(of agent: AgentID) -> [Int] {
        board.instructions.indices
            .filter { board.instructions[$0].agentID == agent }
            .sorted { Self.queueOrder(board.instructions[$0], board.instructions[$1]) }
    }

    /// Indices of the agent's queued cards ("À faire", assigned to it), in queue order, `excluded` left out.
    func queuedCards(of agent: AgentID, excluding excluded: TaskCardID? = nil) -> [Int] {
        board.cards.indices
            .filter { i in
                let card = board.cards[i]
                return card.column == .todo && card.assignee == agent && card.id != excluded
            }
            .sorted { Self.queueOrder(board.cards[$0], board.cards[$1]) }
    }

    /// The agent's queue: its instructions, then its queued cards.
    func queue(of agent: AgentID) -> [QueueItem] {
        instructions(of: agent).map { .instruction(board.instructions[$0].id) }
            + queuedCards(of: agent).map { .card(board.cards[$0].id) }
    }

    func headOfQueue(_ agent: AgentID) -> QueueItem? {
        queue(of: agent).first
    }

    /// The keys of the agent's instructions and of its queued cards, each in queue order.
    func queueKeys(of agent: AgentID, excluding excluded: TaskCardID? = nil)
        -> (instructions: [String], cards: [String]) {
        (instructions(of: agent).map { board.instructions[$0].queueRank },
         queuedCards(of: agent, excluding: excluded).compactMap { board.cards[$0].queueRank })
    }

    /// A key after the whole queue: a card joins it.
    func keyAtEndOfQueue(_ agent: AgentID) -> String {
        let keys = queueKeys(of: agent)
        return RankKey.after((keys.instructions + keys.cards).max())
    }

    /// A key before the whole queue: an instruction at the head.
    func keyAtHeadOfQueue(_ agent: AgentID) -> String {
        let keys = queueKeys(of: agent)
        return RankKey.before((keys.instructions + keys.cards).min())
    }

    /// A key after the instructions and before the cards (`excluded` left out).
    func keyAfterInstructions(_ agent: AgentID, excluding excluded: TaskCardID? = nil) -> String {
        let keys = queueKeys(of: agent, excluding: excluded)
        return RankKey.between(keys.instructions.max(), keys.cards.min())
    }

    /// The agent's instruction being delivered, if any.
    func pendingInstruction(of agent: AgentID) -> Int? {
        instructions(of: agent).first { board.instructions[$0].delivery?.isPending == true }
    }

    /// The agent's queued card being delivered, if any.
    func pendingCard(of agent: AgentID) -> Int? {
        queuedCards(of: agent).first { board.cards[$0].delivery?.isPending == true }
    }

    // MARK: Shared transitions

    /// "En cours" for this agent, without a stopping flag: the agent works on it.
    func isRunning(_ card: TaskCard, for agent: AgentID) -> Bool {
        card.column == .inProgress && card.assignee == agent
            && card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags)
    }

    /// Before card `id` runs for `agent`: any other running card of the agent is marked interrupted (none is moved),
    /// so that at most one card per agent runs.
    mutating func makeRoom(for id: TaskCardID, agent: AgentID) {
        for i in board.cards.indices where board.cards[i].id != id && isRunning(board.cards[i], for: agent) {
            board.cards[i].flags.insert(.interrupted)
            record(i, .interrupted, agent: agent, note: N.otherCardStarted)
        }
    }

    /// A card of "À faire" leaves its agent's queue: a delivery never confirmed and its failure go with it.
    mutating func leaveQueue(_ i: Int) {
        board.cards[i].assignee = nil
        board.cards[i].queueRank = nil
        if board.cards[i].delivery?.isPending == true { board.cards[i].delivery = nil }
        board.cards[i].flags.remove(.deliveryFailed)
    }

    /// Instructions tied to a card and not being delivered ("Continue la tâche", a precision): the user settled
    /// the card (C15, C16, C18), they would send the agent back to it; they leave the queue and, with `warn`, the
    /// user is told. One being typed stays: its confirmation no longer moves a card of "À faire" or "Fait" (C7
    /// guard), and brings a card of "À valider" back to "En cours" as the agent does work on it.
    mutating func dropWaitingInstructions(of card: TaskCardID, warn: Bool) {
        let before = board.instructions.count
        board.instructions.removeAll { $0.cardID == card && $0.delivery == nil }
        let dropped = before - board.instructions.count
        if warn && dropped > 0 { emit(.warn(M.instructionsDropped(dropped))) }
    }

    /// C15: back to "À faire", unassigned, flags cleared, the delivery kept only in the history. The agent is not
    /// interrupted; its Stop no longer affects the card. `warn`: tell the user about the instructions dropped
    /// (not when the agent itself goes, with all its instructions).
    mutating func sendBackToTodo(_ i: Int, rank: String, kind: CardEventKind, note prefix: String? = nil,
                                 warn: Bool = true) {
        let card = board.cards[i]
        board.cards[i].column = .todo
        board.cards[i].rank = rank
        board.cards[i].assignee = nil
        board.cards[i].queueRank = nil
        board.cards[i].flags = []
        board.cards[i].delivery = nil
        record(i, kind, from: card.column, to: .todo, agent: card.assignee,
               note: N.turn(card.delivery?.promptID, after: prefix))
        dropWaitingInstructions(of: card.id, warn: warn)
    }

    /// C16. A "Continue la tâche" still waiting would bring the card back to "En cours": it leaves the queue, and
    /// the flag of its failed delivery with it.
    mutating func sendToReview(_ i: Int, rank: String) {
        let card = board.cards[i]
        board.cards[i].column = .review
        board.cards[i].rank = rank
        board.cards[i].flags.remove(.deliveryFailed)
        record(i, .markedForReview, from: .inProgress, to: .review, agent: card.assignee)
        dropWaitingInstructions(of: card.id, warn: true)
    }

    /// C18, from any other column. XP counts once per card, and only for a card delivered at least once
    /// (proposal 3.11): a confirmed delivery, now or in the history (C15 and agent removal clear it).
    mutating func sendToDone(_ i: Int, rank: String) {
        let card = board.cards[i]
        if card.column == .todo { leaveQueue(i) }
        // Only a confirmed delivery counts (4.3b: a done card never has a pending one).
        if board.cards[i].delivery?.isPending == true { board.cards[i].delivery = nil }
        let delivered = board.cards[i].delivery != nil || card.history.contains { $0.kind == .deliveryConfirmed }
        board.cards[i].column = .done
        board.cards[i].rank = rank
        board.cards[i].flags = []
        if delivered { board.cards[i].validatedOnce = true }
        record(i, .validated, from: card.column, to: .done, agent: card.assignee)
        emit(.validated(card.id, firstTime: !card.validatedOnce && delivered))
        dropWaitingInstructions(of: card.id, warn: true)
    }

    /// C19: back to "À faire", unassigned; `validatedOnce` and the last delivery kept.
    mutating func reopen(_ i: Int, rank: String) {
        board.cards[i].column = .todo
        board.cards[i].rank = rank
        board.cards[i].assignee = nil
        board.cards[i].queueRank = nil
        board.cards[i].flags = []
        record(i, .reopened, from: .done, to: .todo)
    }

    /// A new instruction in the agent's queue at `key` (C14, C17, `giveInstruction`).
    mutating func queueInstruction(_ id: InstructionID, agent: AgentID, text: String, card: TaskCardID?, key: String) {
        board.instructions.append(QueuedInstruction(id: id, agentID: agent, text: text, cardID: card, queueRank: key,
                                                    createdAt: now))
    }

    // MARK: - C1 create

    mutating func create(id: TaskCardID, title: String, details: String, projectID: ProjectID?, priority: Priority,
                         tags: [String], templateID: PromptTemplateID?) {
        let title = Self.trimmed(title)
        guard !title.isEmpty else { return refuse("emptyTitle", M.emptyTitle) }
        guard index(of: id) == nil else { return refuse("duplicateCard", M.duplicateCard) }
        // An unknown template is not kept, as at load (`TaskBoardValidator`).
        let template = templateID.flatMap { board.template($0)?.id }
        board.cards.append(TaskCard(id: id, title: title, details: details, projectID: projectID,
                                    rank: rankAtEnd(of: .todo, excluding: id), priority: priority,
                                    tags: TaskBoardValidator.normalizedTags(tags), templateID: template,
                                    history: [CardEvent(at: now, kind: .created, to: .todo)], createdAt: now))
    }

    // MARK: - Edit

    mutating func edit(_ id: TaskCardID, _ change: CardEdit) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        let card = board.cards[i]
        switch change {
        case .title(let title):
            let title = Self.trimmed(title)
            guard !title.isEmpty else { return refuse("emptyTitle", M.emptyTitle) }
            guard title != card.title else { return }
            board.cards[i].title = title
            record(i, .edited, note: "titre")
        case .details(let details):
            guard details != card.details else { return }
            board.cards[i].details = details
            record(i, .edited, note: "description")
        case .priority(let priority):
            guard priority != card.priority else { return }
            board.cards[i].priority = priority
            record(i, .edited, note: "priorité")
        case .tags(let tags):
            let tags = TaskBoardValidator.normalizedTags(tags)
            guard tags != card.tags else { return }
            board.cards[i].tags = tags
            record(i, .edited, note: "tags")
        case .template(let template):
            if let template, board.template(template) == nil { return refuse("unknownTemplate", M.unknownTemplate) }
            guard template != card.templateID else { return }
            board.cards[i].templateID = template
            record(i, .edited, note: "modèle")
        case .project(let project):
            guard project != card.projectID else { return }
            // The project of an assigned card is its agent's (C3).
            guard card.assignee == nil else {
                switch card.column {
                case .todo: return refuse("projectLocked", M.projectLocked)
                case .inProgress, .review: return refuse("projectLocked", M.projectLockedPutBackFirst)
                case .done: return refuse("projectLocked", M.projectLockedReopenFirst)
                }
            }
            board.cards[i].projectID = project
            record(i, .projectChanged, note: N.previousProject(card.projectID, names: context.projectNames))
        }
    }

    // MARK: - C2 to C5 assignment and queue order

    mutating func assign(_ id: TaskCardID, to agent: AgentID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        let card = board.cards[i]
        guard card.column == .todo else { return reject(.dragToInProgress, M.putBackFirst) }
        guard let project = context.agentProjects[agent] else { return reject(.unknownAgent, M.unknownAgent) }
        guard card.assignee != agent else { return }
        let key = keyAtEndOfQueue(agent)
        leaveQueue(i)
        board.cards[i].assignee = agent
        board.cards[i].queueRank = key
        record(i, card.assignee == nil ? .assigned : .reassigned, agent: agent)
        if card.projectID != project {
            board.cards[i].projectID = project
            record(i, .projectChanged, agent: agent,
                   note: N.previousProject(card.projectID, names: context.projectNames))
        }
        emit(.pump(agent))
    }

    mutating func unassign(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        guard board.cards[i].column == .todo else { return reject(.notInTodo, M.notInQueue) }
        guard let agent = board.cards[i].assignee else { return }
        leaveQueue(i)
        record(i, .unassigned, agent: agent)
    }

    mutating func reorderQueue(_ id: TaskCardID, after other: TaskCardID?) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        guard board.cards[i].column == .todo else { return reject(.notInTodo, M.notInQueue) }
        guard let agent = board.cards[i].assignee else { return refuse("notQueued", M.notQueued) }
        guard other != id else { return }
        let others = queuedCards(of: agent, excluding: id)
        let key: String
        if let other {
            guard let position = others.firstIndex(where: { board.cards[$0].id == other }) else {
                if index(of: other) == nil { return reject(.unknownCard, M.unknownCard) }
                return refuse("otherQueue", M.notSameQueue)
            }
            let upper = position + 1 < others.count ? board.cards[others[position + 1]].queueRank : nil
            key = RankKey.between(board.cards[others[position]].queueRank, upper)
        } else {
            key = keyAfterInstructions(agent, excluding: id)
        }
        // Already right after `other`: nothing to do.
        let current = queuedCards(of: agent)
        if let position = current.firstIndex(of: i) {
            let previous = position > 0 ? board.cards[current[position - 1]].id : nil
            if previous == other { return }
        }
        board.cards[i].queueRank = key
        record(i, .reordered, agent: agent)
        emit(.pump(agent))
    }

    /// A drop: reorder inside a column, or C5, C15, C16, C18, C19 between columns.
    mutating func move(_ id: TaskCardID, to target: Column, after other: TaskCardID?) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        let card = board.cards[i]
        if target == card.column { return reorderColumn(i, after: other) }
        switch target {
        case .inProgress:
            // C5: only a delivery confirmed by the agent starts a card.
            reject(.dragToInProgress, card.column == .todo ? M.dropOnAgent : M.putBackFirst)
        case .todo:
            guard let rank = rank(in: .todo, after: other, moving: id) else { return }
            if card.column == .done {
                reopen(i, rank: rank)
            } else {
                sendBackToTodo(i, rank: rank, kind: .putBack)
            }
        case .review:
            guard card.column == .inProgress else { return refuse("notInProgress", M.reviewNeedsInProgress) }
            guard let rank = rank(in: .review, after: other, moving: id) else { return }
            sendToReview(i, rank: rank)
        case .done:
            guard let rank = rank(in: .done, after: other, moving: id) else { return }
            sendToDone(i, rank: rank)
        }
    }

    /// Display order inside a column; nothing else changes (a card of "En cours" keeps running).
    mutating func reorderColumn(_ i: Int, after other: TaskCardID?) {
        let card = board.cards[i]
        guard other != card.id else { return }
        guard let rank = rank(in: card.column, after: other, moving: card.id) else { return }
        let current = column(card.column)
        if let position = current.firstIndex(of: i) {
            let previous = position > 0 ? board.cards[current[position - 1]].id : nil
            if previous == other { return }
        }
        board.cards[i].rank = rank
        record(i, .reordered, from: card.column, to: card.column)
    }

    // MARK: - C6 delivery started

    mutating func deliveryStarted(_ item: QueueItem, agent: AgentID, sessionID: String?) {
        switch item {
        case .card(let id):
            guard index(of: id) != nil else { return reject(.unknownCard, M.unknownCard) }
        case .instruction(let id):
            guard instructionExists(id) else { return refuse("unknownInstruction", M.unknownInstruction) }
        }
        guard headOfQueue(agent) == item else { return refuse("notHeadOfQueue", M.notHeadOfQueue) }
        dropStaleDeliveries(of: agent, except: item)
        let delivery = DeliveryInfo(sessionID: sessionID, sentAt: now)
        switch item {
        case .card(let id):
            guard let i = index(of: id) else { return }
            board.cards[i].delivery = delivery
            board.cards[i].flags.remove(.deliveryFailed)
            record(i, .deliveryStarted, agent: agent)
        case .instruction(let id):
            guard let j = board.instructions.firstIndex(where: { $0.id == id }) else { return }
            board.instructions[j].delivery = delivery
        }
    }

    /// The dispatcher starts a delivery only when none is in flight for the agent (the agent's reducer holds one
    /// `pendingDelivery` at most): another item still marked as being delivered is stale. At most one item per
    /// agent is ever being delivered, so C7 and C8 know which one they are about.
    mutating func dropStaleDeliveries(of agent: AgentID, except item: QueueItem) {
        for j in instructions(of: agent) where board.instructions[j].delivery?.isPending == true
            && item != .instruction(board.instructions[j].id) {
            board.instructions[j].delivery = nil
        }
        for i in queuedCards(of: agent) where board.cards[i].delivery?.isPending == true
            && item != .card(board.cards[i].id) {
            board.cards[i].delivery = nil
            record(i, .deliveryFailed, agent: agent, note: N.staleDelivery)
        }
    }

    // MARK: - Agent signals (C7, C8, C10 to C13)

    mutating func agentSignal(_ agent: AgentID, _ signal: AgentCardSignal) {
        switch signal {
        case .deliveryConfirmed(let promptID):
            deliveryConfirmed(agent, promptID: promptID)
        case .deliveryFailed(let reason):
            deliveryFailed(agent, note: N.abort(reason))
        case .turnCommitted(let promptID):
            turnCommitted(agent, promptID: promptID)
            // The queue may go on even when no card ended (a turn typed by hand).
            emit(.pump(agent))
        case .turnWaitingBackground:
            flagRunningCards(of: agent, .backgroundRunning, kind: .turnEnded, note: N.backgroundTasks)
        case .turnReopened(let promptID):
            turnReopened(agent, promptID: promptID)
        case .turnFailed:
            flagRunningCards(of: agent, .turnFailed, kind: .turnFailed)
        case .interrupted:
            flagRunningCards(of: agent, .interrupted, kind: .interrupted)
        case .sessionLost:
            // C13, and C8 for a delivery in flight.
            deliveryFailed(agent, note: N.sessionLost)
            for i in column(.inProgress) where board.cards[i].assignee == agent
                && !board.cards[i].flags.contains(.sessionLost) {
                board.cards[i].flags.insert(.sessionLost)
                record(i, .sessionLost, agent: agent)
            }
        }
    }

    /// C7. An instruction being delivered comes first; its card (C14, C17), if still with this agent, runs the
    /// new turn. Otherwise the queued card being delivered starts. Nothing being delivered: nothing moves.
    mutating func deliveryConfirmed(_ agent: AgentID, promptID: String?) {
        if let j = pendingInstruction(of: agent) {
            let instruction = board.instructions.remove(at: j)
            guard let cardID = instruction.cardID, let i = index(of: cardID) else { return }
            let card = board.cards[i]
            guard card.assignee == agent, card.column == .review || card.column == .inProgress else { return }
            makeRoom(for: cardID, agent: agent)
            if card.column != .inProgress {
                board.cards[i].column = .inProgress
                board.cards[i].rank = rankAtEnd(of: .inProgress, excluding: cardID)
            }
            board.cards[i].delivery = DeliveryInfo(sessionID: instruction.delivery?.sessionID, promptID: promptID,
                                                   sentAt: instruction.delivery?.sentAt ?? now, confirmedAt: now)
            board.cards[i].flags = []
            record(i, .deliveryConfirmed, from: card.column, to: .inProgress, agent: agent, note: N.turn(promptID))
            return
        }
        guard let i = pendingCard(of: agent) else { return }
        let card = board.cards[i]
        makeRoom(for: card.id, agent: agent)
        board.cards[i].column = .inProgress
        board.cards[i].rank = rankAtEnd(of: .inProgress, excluding: card.id)
        board.cards[i].queueRank = nil
        let confirmedAt = now
        board.cards[i].delivery?.promptID = promptID
        board.cards[i].delivery?.confirmedAt = confirmedAt
        board.cards[i].flags = []
        record(i, .deliveryConfirmed, from: .todo, to: .inProgress, agent: agent, note: N.turn(promptID))
    }

    /// C8 (and C13 `sessionLost` during a delivery): the item stays where it is in the queue, its delivery cleared;
    /// a card is flagged. The agent's queue is already paused (T31). An instruction's card still with the agent
    /// (C14, C17, same guard as C7) is flagged too: "Réessayer" (C9) resumes the queue, the instruction still at
    /// its head, and a card of "En cours" no longer looks like it runs while the agent is idle.
    mutating func deliveryFailed(_ agent: AgentID, note: String) {
        if let j = pendingInstruction(of: agent) {
            let instruction = board.instructions[j]
            board.instructions[j].delivery = nil
            if let cardID = instruction.cardID, let i = index(of: cardID), board.cards[i].assignee == agent,
               board.cards[i].column == .inProgress || board.cards[i].column == .review {
                board.cards[i].flags.insert(.deliveryFailed)
                record(i, .deliveryFailed, agent: agent, note: note)
            }
            emit(.notify(M.deliveryFailed(instruction.text)))
            return
        }
        guard let i = pendingCard(of: agent) else { return }
        board.cards[i].delivery = nil
        board.cards[i].flags.insert(.deliveryFailed)
        record(i, .deliveryFailed, agent: agent, note: note)
        emit(.notify(M.deliveryFailed(board.cards[i].title)))
    }

    /// C10. The agent's card of "En cours" whose delivery has this prompt id. Otherwise, when the Stop has no
    /// prompt id or the card was confirmed without one, the only card of the agent whose turn is open: among the
    /// cards the agent works on, since a stopped one (`TaskBoardValidator.stoppingFlags`) is no longer its current
    /// turn. Such a card takes the Stop's prompt id, so that C12 finds it. A Stop that matches no card (a turn
    /// typed by hand) moves nothing.
    mutating func turnCommitted(_ agent: AgentID, promptID: String?) {
        let cards = column(.inProgress).filter { board.cards[$0].assignee == agent }
        var target: Int?
        if let promptID {
            target = cards.first { board.cards[$0].delivery?.promptID == promptID }
        }
        if target == nil {
            let open = cards.filter { i in
                isRunning(board.cards[i], for: agent) && board.cards[i].delivery.map { $0.turnEndedAt == nil } == true
            }
            if open.count == 1, promptID == nil || board.cards[open[0]].delivery?.promptID == nil {
                target = open[0]
            }
        }
        guard let i = target else { return }
        let card = board.cards[i]
        board.cards[i].column = .review
        board.cards[i].rank = rankAtEnd(of: .review, excluding: card.id)
        let endedAt = now
        board.cards[i].delivery?.turnEndedAt = endedAt
        if card.delivery?.promptID == nil { board.cards[i].delivery?.promptID = promptID }
        board.cards[i].flags.remove(.backgroundRunning)
        record(i, .turnEnded, from: .inProgress, to: .review, agent: agent,
               note: N.turn(card.delivery?.promptID ?? promptID))
    }

    /// C12: the turn of a card waiting for review goes on (same prompt id), unless the card was ever validated.
    mutating func turnReopened(_ agent: AgentID, promptID: String?) {
        guard let promptID else { return }
        let match = column(.review).first { i in
            let card = board.cards[i]
            return card.assignee == agent && card.delivery?.promptID == promptID && !card.validatedOnce
        }
        guard let i = match else { return }
        let id = board.cards[i].id
        makeRoom(for: id, agent: agent)
        board.cards[i].column = .inProgress
        board.cards[i].rank = rankAtEnd(of: .inProgress, excluding: id)
        board.cards[i].delivery?.turnEndedAt = nil
        board.cards[i].flags = []
        record(i, .turnReopened, from: .review, to: .inProgress, agent: agent, note: N.turn(promptID))
    }

    /// C11, C13: a flag on the card the agent works on (one at most); the column does not change.
    mutating func flagRunningCards(of agent: AgentID, _ flag: CardFlag, kind: CardEventKind, note: String? = nil) {
        for i in column(.inProgress) where isRunning(board.cards[i], for: agent) && !board.cards[i].flags.contains(flag) {
            board.cards[i].flags.insert(flag)
            record(i, kind, agent: agent, note: note)
        }
    }

    // MARK: - C9 retry, C14 continue

    mutating func retry(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        guard board.cards[i].flags.contains(.deliveryFailed) else { return refuse("noFailedDelivery", M.nothingToRetry) }
        let agent = board.cards[i].assignee
        board.cards[i].flags.remove(.deliveryFailed)
        record(i, .resent, agent: agent, note: N.retry)
        if let agent { emit(.pump(agent)) }
    }

    mutating func continueTask(_ id: TaskCardID, instructionID: InstructionID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        let card = board.cards[i]
        guard card.column == .inProgress else { return refuse("notInProgress", M.continueNeedsInProgress) }
        guard !card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags) else {
            return refuse("notStopped", M.nothingToContinue)
        }
        guard let agent = card.assignee, context.liveAgents.contains(agent) else {
            return refuse("agentOffline", M.relaunchFirst)
        }
        // Another card runs: this one would run too (at most one per agent).
        guard !board.cards.contains(where: { $0.id != id && isRunning($0, for: agent) }) else {
            return refuse("otherCardRunning", M.otherCardRunning)
        }
        guard !instructionExists(instructionID) else { return refuse("duplicateInstruction", M.duplicateInstruction) }
        queueInstruction(instructionID, agent: agent, text: M.continueTask(card.title), card: id,
                         key: keyAtHeadOfQueue(agent))
        board.cards[i].flags = []
        record(i, .continued, agent: agent)
        emit(.pump(agent))
    }

    // MARK: - C15 to C20

    mutating func putBack(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        switch board.cards[i].column {
        case .inProgress, .review:
            sendBackToTodo(i, rank: rankAtEnd(of: .todo, excluding: id), kind: .putBack)
        case .todo:
            refuse("alreadyTodo", M.alreadyTodo)
        case .done:
            refuse("done", M.reopenInstead)
        }
    }

    mutating func markForReview(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        guard board.cards[i].column == .inProgress else { return refuse("notInProgress", M.reviewNeedsInProgress) }
        sendToReview(i, rank: rankAtEnd(of: .review, excluding: id))
    }

    /// C17: the card stays "À valider" until the precision's delivery is confirmed (C7).
    mutating func resend(_ id: TaskCardID, precision: String, instructionID: InstructionID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        let card = board.cards[i]
        guard card.column == .review else { return refuse("notInReview", M.resendNeedsReview) }
        let text = Self.trimmed(precision)
        guard !text.isEmpty else { return refuse("emptyPrecision", M.emptyPrecision) }
        guard let agent = card.assignee else { return refuse("noAgent", M.noAgentToResend) }
        guard context.liveAgents.contains(agent) else { return refuse("agentOffline", M.relaunchFirst) }
        guard !instructionExists(instructionID) else { return refuse("duplicateInstruction", M.duplicateInstruction) }
        queueInstruction(instructionID, agent: agent, text: text, card: id, key: keyAtHeadOfQueue(agent))
        record(i, .resent, agent: agent, note: N.precision(text))
        if let delivered = card.delivery?.sessionID, let current = context.sessionIDs[agent], delivered != current {
            emit(.warn(M.sessionChanged))
        }
        emit(.pump(agent))
    }

    mutating func validate(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        guard board.cards[i].column != .done else { return refuse("alreadyDone", M.alreadyDone) }
        sendToDone(i, rank: rankAtEnd(of: .done, excluding: id))
    }

    mutating func reopen(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        guard board.cards[i].column == .done else { return refuse("notDone", M.reopenNeedsDone) }
        reopen(i, rank: rankAtEnd(of: .todo, excluding: id))
    }

    /// C20: the card and every instruction tied to it. A turn in progress is not interrupted (as C15).
    mutating func delete(_ id: TaskCardID) {
        guard let i = index(of: id) else { return reject(.unknownCard, M.unknownCard) }
        board.cards.remove(at: i)
        board.instructions.removeAll { $0.cardID == id }
    }

    // MARK: - Instructions, agents, templates

    mutating func giveInstruction(agent: AgentID, text: String, instructionID: InstructionID, atHead: Bool) {
        guard context.agentProjects[agent] != nil else { return reject(.unknownAgent, M.unknownAgent) }
        let text = Self.trimmed(text)
        guard !text.isEmpty else { return refuse("emptyInstruction", M.emptyInstruction) }
        guard !instructionExists(instructionID) else { return refuse("duplicateInstruction", M.duplicateInstruction) }
        let key = atHead ? keyAtHeadOfQueue(agent) : keyAfterInstructions(agent)
        queueInstruction(instructionID, agent: agent, text: text, card: nil, key: key)
        emit(.pump(agent))
    }

    /// The agent's cards are never lost: queued ones leave the queue, running or waiting ones go back to
    /// "À faire" as C15, all at the end of "À faire"; a done card only loses its agent. Its instructions go.
    mutating func agentRemoved(_ agent: AgentID) {
        for i in column(.todo) where board.cards[i].assignee == agent {
            let id = board.cards[i].id
            leaveQueue(i)
            board.cards[i].flags = []
            board.cards[i].rank = rankAtEnd(of: .todo, excluding: id)
            record(i, .unassigned, from: .todo, to: .todo, agent: agent, note: N.agentRemoved)
        }
        for source in [Column.inProgress, .review] {
            for i in column(source) where board.cards[i].assignee == agent {
                sendBackToTodo(i, rank: rankAtEnd(of: .todo, excluding: board.cards[i].id), kind: .unassigned,
                               note: N.agentRemoved, warn: false)
            }
        }
        for i in column(.done) where board.cards[i].assignee == agent {
            board.cards[i].assignee = nil
            record(i, .unassigned, agent: agent, note: N.agentRemoved)
        }
        board.instructions.removeAll { $0.agentID == agent }
    }

    mutating func upsertTemplate(_ template: PromptTemplate) {
        let name = Self.trimmed(template.name)
        guard !name.isEmpty else { return refuse("emptyTemplateName", M.emptyTemplateName) }
        let stored = PromptTemplate(id: template.id, name: name, body: template.body)
        if let j = board.templates.firstIndex(where: { $0.id == template.id }) {
            board.templates[j] = stored
        } else {
            board.templates.append(stored)
        }
    }

    mutating func deleteTemplate(_ id: PromptTemplateID) {
        guard let j = board.templates.firstIndex(where: { $0.id == id }) else {
            return refuse("unknownTemplate", M.unknownTemplate)
        }
        board.templates.remove(at: j)
        for i in board.cards.indices where board.cards[i].templateID == id {
            board.cards[i].templateID = nil
            record(i, .edited, note: N.templateDeleted)
        }
    }
}
