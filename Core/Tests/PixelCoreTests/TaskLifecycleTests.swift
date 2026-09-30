import Foundation
import Testing
@testable import PixelCore

/// A small world for the lifecycle tests: project API (1) with Nova (agent 1) and Pixou (agent 2), both online;
/// project Site (2) with Oslo (agent 3), offline.
enum TaskWorld {
    static let api = TaskBoardSamples.project(1)
    static let site = TaskBoardSamples.project(2)
    static let nova = TaskBoardSamples.agent(1)
    static let pixou = TaskBoardSamples.agent(2)
    static let oslo = TaskBoardSamples.agent(3)
    static let agentProjects: [AgentID: ProjectID] = [nova: api, pixou: api, oslo: site]
    static let liveAgents: Set<AgentID> = [nova, pixou]

    static func context(at offset: Double, sessionIDs: [AgentID: String] = [:]) -> TaskContext {
        TaskContext(now: TaskBoardSamples.at(offset), agentProjects: agentProjects, liveAgents: liveAgents,
                    sessionIDs: sessionIDs)
    }

    /// An agent's queue, computed apart from the reducer: its instructions, then its queued cards, each by key.
    static func queue(of agent: AgentID, in board: TaskBoardState) -> [QueueItem] {
        let instructions = board.instructions.filter { $0.agentID == agent }.sorted { $0.queueRank < $1.queueRank }
        let cards = board.cards.filter { $0.column == .todo && $0.assignee == agent }
            .sorted { ($0.queueRank ?? "") < ($1.queueRank ?? "") }
        return instructions.map { .instruction($0.id) } + cards.map { .card($0.id) }
    }

    /// The keys of an agent's queue, in queue order: they must be strictly ascending.
    static func queueKeys(of agent: AgentID, in board: TaskBoardState) -> [String] {
        queue(of: agent, in: board).compactMap { item in
            switch item {
            case .instruction(let id): board.instructions.first { $0.id == id }?.queueRank
            case .card(let id): board.card(id)?.queueRank
            }
        }
    }

    static func isStrictlyAscending(_ keys: [String]) -> Bool {
        zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }
    }
}

/// A board under test and its clock: each input is applied one second after the previous one (t = 101, 102…).
struct LifecycleRun {
    typealias S = TaskBoardSamples
    typealias W = TaskWorld

    var board: TaskBoardState
    var clock: Double = 100
    var sessionIDs: [AgentID: String] = [:]

    init(board: TaskBoardState = TaskBoardState(templates: StarterTemplates.make(ids: TaskBoardSamples.templateIDs))) {
        self.board = board
    }

    /// Date of the last applied input.
    var now: Date { S.at(clock) }

    @discardableResult
    mutating func apply(_ input: TaskInput) -> [TaskEffect] {
        clock += 1
        let (next, effects) = TaskLifecycle.reduce(board, input, context: W.context(at: clock, sessionIDs: sessionIDs))
        board = next
        return effects
    }

    /// Applies an input that must be refused: the board stays exactly the same (not even `updatedAt` moves).
    mutating func refused(_ input: TaskInput, sourceLocation: SourceLocation = #_sourceLocation) -> [TaskEffect] {
        let before = board
        let effects = apply(input)
        #expect(board == before, sourceLocation: sourceLocation)
        #expect(effects.count == 1, sourceLocation: sourceLocation)
        return effects
    }

    func card(_ n: Int) -> TaskCard? { board.card(S.card(n)) }

    mutating func create(_ n: Int, _ title: String, project: ProjectID? = TaskWorld.api) {
        apply(.create(id: S.card(n), title: title, details: "", projectID: project, priority: .normal, tags: [],
                      templateID: nil))
    }

    /// Creates card n in the agent's project, gives it to the agent and delivers it: "En cours" with `promptID`.
    mutating func start(_ n: Int, _ title: String, agent: AgentID = TaskWorld.nova, promptID: String?) {
        create(n, title, project: W.agentProjects[agent])
        apply(.assign(S.card(n), to: agent))
        apply(.deliveryStarted(.card(S.card(n)), agent: agent, sessionID: "session-1"))
        apply(.agentSignal(agent, .deliveryConfirmed(promptID: promptID)))
    }

    /// Like `start`, then the turn ends: "À valider".
    mutating func review(_ n: Int, _ title: String, agent: AgentID = TaskWorld.nova, promptID: String) {
        start(n, title, agent: agent, promptID: promptID)
        apply(.agentSignal(agent, .turnCommitted(promptID: promptID)))
    }
}

@Suite struct TaskLifecycleTests {
    typealias S = TaskBoardSamples
    typealias W = TaskWorld
    typealias M = TaskLifecycle.Message

    // MARK: - C1 create

    @Test func c01_createAppendsAnUnassignedCardAtTheEndOfTodo() throws {
        var run = LifecycleRun()
        let effects = run.apply(.create(id: S.card(1), title: "  Pagination /users \n", details: "20 par page",
                                        projectID: W.api, priority: .high, tags: ["#api", "API", " back end "],
                                        templateID: S.template(2)))
        #expect(effects.isEmpty)
        run.apply(.create(id: S.card(2), title: "Header", details: "", projectID: nil, priority: .normal, tags: [],
                          templateID: S.template(9)))
        let first = try #require(run.card(1))
        #expect(first.title == "Pagination /users")
        #expect(first.details == "20 par page")
        #expect(first.column == .todo && first.assignee == nil && first.queueRank == nil)
        #expect(first.projectID == W.api && first.priority == .high && first.templateID == S.template(2))
        #expect(first.tags == ["api", "backend"])
        #expect(first.flags.isEmpty && first.delivery == nil && !first.validatedOnce)
        #expect(first.history == [CardEvent(at: S.at(101), kind: .created, to: .todo)])
        #expect(first.createdAt == S.at(101) && first.updatedAt == S.at(101))
        let second = try #require(run.card(2))
        // An unknown template is not kept (as the validator does at load).
        #expect(second.templateID == nil)
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(1), S.card(2)])
        #expect(first.rank < second.rank)
    }

    @Test func c01_createRefusesABlankTitleOrATakenID() {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        let blank = run.refused(.create(id: S.card(2), title: " \n\t ", details: "", projectID: nil, priority: .normal,
                                        tags: [], templateID: nil))
        #expect(blank == [.rejected(.notAllowed("emptyTitle"), message: "Un post-it a besoin d'un titre.")])
        let taken = run.refused(.create(id: S.card(1), title: "Autre", details: "", projectID: nil, priority: .normal,
                                        tags: [], templateID: nil))
        #expect(taken == [.rejected(.notAllowed("duplicateCard"), message: M.duplicateCard)])
    }

    // MARK: - C2, C3 assign

    @Test func c02_assignQueuesTheCardAtTheEndOfTheAgentQueue() throws {
        var run = LifecycleRun()
        run.apply(.giveInstruction(agent: W.nova, text: "Lis le README", instructionID: S.instruction(1), atHead: false))
        run.create(1, "Pagination")
        run.create(2, "Header")
        let effects = run.apply(.assign(S.card(1), to: W.nova))
        #expect(effects == [.pump(W.nova)])
        run.apply(.assign(S.card(2), to: W.nova))
        let first = try #require(run.card(1))
        #expect(first.column == .todo && first.assignee == W.nova && first.projectID == W.api)
        #expect(first.history.map(\.kind) == [.created, .assigned])
        #expect(first.history.last == CardEvent(at: S.at(104), kind: .assigned, agentID: W.nova))
        #expect(first.updatedAt == S.at(104))
        #expect(W.queue(of: W.nova, in: run.board)
            == [.instruction(S.instruction(1)), .card(S.card(1)), .card(S.card(2))])
        let keys = W.queueKeys(of: W.nova, in: run.board)
        #expect(keys.count == 3 && W.isStrictlyAscending(keys))
        // The same agent again: nothing to do.
        let before = run.board
        #expect(run.apply(.assign(S.card(1), to: W.nova)).isEmpty)
        #expect(run.board == before)
    }

    @Test func c03_assignAcrossProjectsTakesTheAgentProject() throws {
        var run = LifecycleRun()
        run.create(1, "Logo", project: W.site)
        run.create(2, "Sans projet", project: nil)
        let effects = run.apply(.assign(S.card(1), to: W.nova))
        #expect(effects == [.pump(W.nova)])
        run.apply(.assign(S.card(2), to: W.nova))
        for n in [1, 2] {
            let card = try #require(run.card(n))
            #expect(card.projectID == W.api)
            #expect(card.assignee == W.nova && card.queueRank != nil)
            #expect(card.history.map(\.kind) == [.created, .assigned, .projectChanged])
        }
        let unknown = run.refused(.assign(S.card(1), to: S.agent(9)))
        #expect(unknown == [.rejected(.unknownAgent, message: M.unknownAgent)])
    }

    // MARK: - C4 unassign, reassign, reorder

    @Test func c04_unassignTakesTheCardOutOfTheQueue() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        let effects = run.apply(.unassign(S.card(1)))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .todo && card.assignee == nil && card.queueRank == nil)
        #expect(card.history.last == CardEvent(at: run.now, kind: .unassigned, agentID: W.nova))
        #expect(W.queue(of: W.nova, in: run.board).isEmpty)
        // Not queued any more: nothing to do.
        let before = run.board
        #expect(run.apply(.unassign(S.card(1))).isEmpty)
        #expect(run.board == before)
    }

    @Test func c04_reassignMovesTheCardToTheOtherQueue() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.create(2, "Chez Pixou")
        run.apply(.assign(S.card(2), to: W.pixou))
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        let effects = run.apply(.assign(S.card(1), to: W.pixou))
        #expect(effects == [.pump(W.pixou)])
        let card = try #require(run.card(1))
        #expect(card.assignee == W.pixou)
        #expect(card.history.last == CardEvent(at: run.now, kind: .reassigned, agentID: W.pixou))
        // The delivery to Nova was never confirmed: it is dropped with the queue it belonged to.
        #expect(card.delivery == nil)
        #expect(W.queue(of: W.nova, in: run.board).isEmpty)
        #expect(W.queue(of: W.pixou, in: run.board) == [.card(S.card(2)), .card(S.card(1))])
    }

    @Test func c04_reorderQueueMovesTheCardBetweenItsNeighbours() {
        var run = LifecycleRun()
        for n in 1...3 {
            run.create(n, "Carte \(n)")
            run.apply(.assign(S.card(n), to: W.nova))
        }
        let effects = run.apply(.reorderQueue(S.card(3), after: nil))
        #expect(effects == [.pump(W.nova)])
        #expect(W.queue(of: W.nova, in: run.board) == [.card(S.card(3)), .card(S.card(1)), .card(S.card(2))])
        #expect(run.card(3)?.history.last == CardEvent(at: run.now, kind: .reordered, agentID: W.nova))
        run.apply(.reorderQueue(S.card(1), after: S.card(2)))
        #expect(W.queue(of: W.nova, in: run.board) == [.card(S.card(3)), .card(S.card(2)), .card(S.card(1))])
        // Already in place: nothing changes.
        let before = run.board
        #expect(run.apply(.reorderQueue(S.card(3), after: nil)).isEmpty)
        #expect(run.apply(.reorderQueue(S.card(1), after: S.card(2))).isEmpty)
        #expect(run.board == before)
        // At the head of the cards means after the instructions.
        run.apply(.giveInstruction(agent: W.nova, text: "Consigne", instructionID: S.instruction(1), atHead: true))
        run.apply(.reorderQueue(S.card(1), after: nil))
        #expect(W.queue(of: W.nova, in: run.board)
            == [.instruction(S.instruction(1)), .card(S.card(1)), .card(S.card(3)), .card(S.card(2))])
        #expect(W.isStrictlyAscending(W.queueKeys(of: W.nova, in: run.board)))
        // Another agent's card is not a neighbour.
        run.create(4, "Chez Pixou")
        run.apply(.assign(S.card(4), to: W.pixou))
        let other = run.refused(.reorderQueue(S.card(1), after: S.card(4)))
        #expect(other == [.rejected(.notAllowed("otherQueue"), message: M.notSameQueue)])
        run.create(5, "Libre")
        let unqueued = run.refused(.reorderQueue(S.card(5), after: nil))
        #expect(unqueued == [.rejected(.notAllowed("notQueued"), message: M.notQueued)])
    }

    @Test func c04_queueChangesNeedACardInTodo() {
        var run = LifecycleRun()
        run.start(1, "En cours", promptID: "p-1")
        #expect(run.refused(.unassign(S.card(1))) == [.rejected(.notInTodo, message: M.notInQueue)])
        #expect(run.refused(.reorderQueue(S.card(1), after: nil)) == [.rejected(.notInTodo, message: M.notInQueue)])
    }

    // MARK: - C5 refused drags

    @Test func c05_dragToInProgressOrReassignOutsideTodoIsRefused() {
        var run = LifecycleRun()
        run.create(1, "À faire")
        run.start(2, "En cours", agent: W.nova, promptID: "p-2")
        run.review(3, "À valider", agent: W.pixou, promptID: "p-3")
        run.review(4, "Fait", agent: W.oslo, promptID: "p-4")
        run.apply(.validate(S.card(4)))
        let dropOnAgent = TaskEffect.rejected(.dragToInProgress, message: "Glisse-la sur un agent pour la lancer.")
        let putBackFirst = TaskEffect.rejected(.dragToInProgress, message: "Remets-la d'abord à faire.")
        #expect(run.refused(.move(S.card(1), to: .inProgress, after: nil)) == [dropOnAgent])
        #expect(run.refused(.move(S.card(3), to: .inProgress, after: S.card(2))) == [putBackFirst])
        #expect(run.refused(.move(S.card(4), to: .inProgress, after: nil)) == [putBackFirst])
        for n in [2, 3, 4] {
            #expect(run.refused(.assign(S.card(n), to: W.pixou)) == [putBackFirst])
        }
    }

    // MARK: - C6 delivery started

    @Test func c06_deliveryStartedRecordsTheDeliveryOfTheHeadOfTheQueue() throws {
        var run = LifecycleRun()
        run.create(1, "Premier")
        run.apply(.assign(S.card(1), to: W.nova))
        run.create(2, "Second")
        run.apply(.assign(S.card(2), to: W.nova))
        let notHead = TaskEffect.rejected(.notAllowed("notHeadOfQueue"), message: M.notHeadOfQueue)
        #expect(run.refused(.deliveryStarted(.card(S.card(2)), agent: W.nova, sessionID: "s-1")) == [notHead])
        #expect(run.refused(.deliveryStarted(.card(S.card(1)), agent: W.pixou, sessionID: "s-1")) == [notHead])
        let effects = run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.delivery == DeliveryInfo(sessionID: "s-1", sentAt: run.now))
        #expect(card.column == .todo && card.assignee == W.nova && card.queueRank != nil)
        #expect(card.history.last == CardEvent(at: run.now, kind: .deliveryStarted, agentID: W.nova))
    }

    @Test func c06_anInstructionAtTheHeadIsDeliveredFirst() throws {
        var run = LifecycleRun()
        run.create(1, "Premier")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.giveInstruction(agent: W.nova, text: "Lance les tests", instructionID: S.instruction(1), atHead: false))
        _ = run.refused(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        let effects = run.apply(.deliveryStarted(.instruction(S.instruction(1)), agent: W.nova, sessionID: "s-1"))
        #expect(effects.isEmpty)
        #expect(run.board.instructions.first?.delivery == DeliveryInfo(sessionID: "s-1", sentAt: run.now))
        #expect(run.card(1)?.delivery == nil)
        let unknown = run.refused(.deliveryStarted(.instruction(S.instruction(9)), agent: W.nova, sessionID: nil))
        #expect(unknown == [.rejected(.notAllowed("unknownInstruction"), message: M.unknownInstruction)])
    }

    @Test func c06_aNewDeliveryReplacesAnUnconfirmedOne() throws {
        // The dispatcher starts a delivery only when none is in flight: an older pending one is stale.
        var run = LifecycleRun()
        run.create(1, "Premier")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        run.apply(.giveInstruction(agent: W.nova, text: "Urgent", instructionID: S.instruction(1), atHead: true))
        run.apply(.deliveryStarted(.instruction(S.instruction(1)), agent: W.nova, sessionID: "s-1"))
        let card = try #require(run.card(1))
        #expect(card.delivery == nil && card.column == .todo && card.flags.isEmpty)
        #expect(card.history.last?.kind == .deliveryFailed)
        // The confirmation goes to the instruction; the card stays queued.
        run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-1")))
        #expect(run.board.instructions.isEmpty)
        #expect(run.card(1)?.column == .todo)
        #expect(W.queue(of: W.nova, in: run.board) == [.card(S.card(1))])
    }

    // MARK: - C7 delivery confirmed

    @Test func c07_deliveryConfirmedMovesTheCardToInProgress() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "session-1"))
        let effects = run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-1")))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .inProgress && card.queueRank == nil && card.assignee == W.nova)
        #expect(card.delivery == DeliveryInfo(sessionID: "session-1", promptID: "p-1", sentAt: S.at(103),
                                              confirmedAt: S.at(104)))
        #expect(card.flags.isEmpty)
        #expect(card.history.last == CardEvent(at: S.at(104), kind: .deliveryConfirmed, from: .todo, to: .inProgress,
                                               agentID: W.nova, note: "tour p-1"))
        #expect(W.queue(of: W.nova, in: run.board).isEmpty)
        #expect(run.board.cards(in: .inProgress).map(\.id) == [S.card(1)])
    }

    @Test func c07_confirmationWhileAnotherCardRunsInterruptsIt() throws {
        var run = LifecycleRun()
        run.start(1, "Premier", promptID: "p-1")
        run.start(2, "Second", promptID: "p-2")
        let first = try #require(run.card(1))
        let second = try #require(run.card(2))
        #expect(first.column == .inProgress && first.flags == [.interrupted])
        #expect(first.history.last?.kind == .interrupted && first.history.last?.agentID == W.nova)
        #expect(second.column == .inProgress && second.flags.isEmpty)
        #expect(run.board.cards(in: .inProgress).map(\.id) == [S.card(1), S.card(2)])
    }

    @Test func confirmationWithoutPendingDeliveryIsIgnored() {
        var run = LifecycleRun()
        run.create(1, "En file")
        run.apply(.assign(S.card(1), to: W.nova))
        run.create(2, "Chez Pixou")
        run.apply(.assign(S.card(2), to: W.pixou))
        run.apply(.deliveryStarted(.card(S.card(2)), agent: W.pixou, sessionID: "s"))
        // A turn typed by hand in Nova's terminal: no card was being delivered to Nova.
        var before = run.board
        #expect(run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-9"))).isEmpty)
        #expect(run.board == before)
        // A delivery is confirmed once.
        run.apply(.agentSignal(W.pixou, .deliveryConfirmed(promptID: "p-2")))
        before = run.board
        #expect(run.apply(.agentSignal(W.pixou, .deliveryConfirmed(promptID: "p-3"))).isEmpty)
        #expect(run.board == before)
    }

    // MARK: - C8 delivery failed

    @Test func c08_deliveryFailedKeepsTheCardAtTheHeadWithAFlag() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        run.create(2, "Suivante")
        run.apply(.assign(S.card(2), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        let effects = run.apply(.agentSignal(W.nova, .deliveryFailed(.noPromptSubmit)))
        #expect(effects == [.notify("Échec d'envoi de « Pagination » à l'agent. La file est en pause.")])
        let card = try #require(run.card(1))
        #expect(card.column == .todo && card.assignee == W.nova && card.queueRank != nil)
        #expect(card.delivery == nil && card.flags == [.deliveryFailed])
        #expect(card.history.last?.kind == .deliveryFailed && card.history.last?.note != nil)
        #expect(W.queue(of: W.nova, in: run.board).first == .card(S.card(1)))
        // Nothing pending any more: a second failure changes nothing.
        let before = run.board
        #expect(run.apply(.agentSignal(W.nova, .deliveryFailed(.processGone))).isEmpty)
        #expect(run.board == before)
    }

    @Test func c08_aFailedInstructionStaysAtTheHead() {
        var run = LifecycleRun()
        run.apply(.giveInstruction(agent: W.nova, text: "Lance les tests", instructionID: S.instruction(1), atHead: false))
        run.apply(.deliveryStarted(.instruction(S.instruction(1)), agent: W.nova, sessionID: "s-1"))
        let effects = run.apply(.agentSignal(W.nova, .deliveryFailed(.guardFailed("brouillon"))))
        #expect(effects == [.notify("Échec d'envoi de « Lance les tests » à l'agent. La file est en pause.")])
        #expect(run.board.instructions.map(\.id) == [S.instruction(1)])
        #expect(run.board.instructions.first?.delivery == nil)
    }

    // MARK: - C9 retry

    @Test func c09_retryClearsTheFailureAndPumpsTheQueue() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        run.apply(.agentSignal(W.nova, .deliveryFailed(.noPromptSubmit)))
        let effects = run.apply(.retry(S.card(1)))
        #expect(effects == [.pump(W.nova)])
        let card = try #require(run.card(1))
        #expect(card.flags.isEmpty && card.column == .todo && card.assignee == W.nova)
        #expect(card.history.last?.kind == .resent)
        let again = run.refused(.retry(S.card(1)))
        #expect(again == [.rejected(.notAllowed("noFailedDelivery"), message: M.nothingToRetry)])
    }

    @Test func c09_aNewDeliveryAlsoClearsTheFailure() {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        run.apply(.agentSignal(W.nova, .deliveryFailed(.noPromptSubmit)))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-2"))
        #expect(run.card(1)?.flags.isEmpty == true)
        #expect(run.card(1)?.delivery == DeliveryInfo(sessionID: "s-2", sentAt: run.now))
    }

    // MARK: - C10 turn committed

    @Test func c10_turnCommittedMovesTheMatchingCardToReview() throws {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        run.apply(.agentSignal(W.nova, .turnWaitingBackground))
        let effects = run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-1")))
        #expect(effects == [.pump(W.nova)])
        let card = try #require(run.card(1))
        #expect(card.column == .review && card.assignee == W.nova)
        #expect(card.delivery?.turnEndedAt == run.now && card.delivery?.promptID == "p-1")
        #expect(card.flags.isEmpty)
        #expect(card.history.last == CardEvent(at: run.now, kind: .turnEnded, from: .inProgress, to: .review,
                                               agentID: W.nova, note: "tour p-1"))
    }

    @Test func c10_withoutPromptIDTheOnlyOpenCardMoves() throws {
        // The card was confirmed without a prompt id: the first Stop after it, whatever its id.
        var run = LifecycleRun()
        run.start(1, "Sans identifiant", promptID: nil)
        run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-7")))
        #expect(run.card(1)?.column == .review)
        // A Stop without a prompt id: the only open card of the agent, whatever its id.
        run.start(2, "Avec identifiant", agent: W.pixou, promptID: "p-2")
        run.apply(.agentSignal(W.pixou, .turnCommitted(promptID: nil)))
        #expect(run.card(2)?.column == .review)
        // Two open cards: nothing can tell them apart.
        run.start(3, "Premier", promptID: nil)
        run.apply(.agentSignal(W.nova, .interrupted))
        run.start(4, "Second", promptID: nil)
        let before = run.board
        #expect(run.apply(.agentSignal(W.nova, .turnCommitted(promptID: nil))) == [.pump(W.nova)])
        #expect(run.board == before)
    }

    @Test func stopWithoutMatchingPromptIDMovesNothing() {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        // A turn launched by hand in the same terminal ends: the card stays "En cours".
        var before = run.board
        #expect(run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-2"))) == [.pump(W.nova)])
        #expect(run.board == before)
        // An agent with no card at all: its queue may still go on.
        before = run.board
        #expect(run.apply(.agentSignal(W.pixou, .turnCommitted(promptID: "p-3"))) == [.pump(W.pixou)])
        #expect(run.board == before)
    }

    // MARK: - C11 background tasks

    @Test func c11_turnWaitingBackgroundFlagsTheRunningCard() throws {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        let effects = run.apply(.agentSignal(W.nova, .turnWaitingBackground))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .inProgress && card.flags == [.backgroundRunning])
        #expect(card.history.last?.kind == .turnEnded && card.history.last?.to == nil)
        // Already flagged: nothing more.
        let before = run.board
        #expect(run.apply(.agentSignal(W.nova, .turnWaitingBackground)).isEmpty)
        #expect(run.board == before)
    }

    // MARK: - C12 turn reopened

    @Test func c12_turnReopenedBringsTheReviewCardBack() throws {
        var run = LifecycleRun()
        run.review(1, "Pagination", promptID: "p-1")
        let effects = run.apply(.agentSignal(W.nova, .turnReopened(promptID: "p-1")))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .inProgress && card.delivery?.turnEndedAt == nil && card.delivery?.promptID == "p-1")
        #expect(card.history.last == CardEvent(at: run.now, kind: .turnReopened, from: .review, to: .inProgress,
                                               agentID: W.nova, note: "tour p-1"))
    }

    @Test func c12_anotherTurnOrAValidatedCardStays() {
        var run = LifecycleRun()
        run.review(1, "Pagination", promptID: "p-1")
        var before = run.board
        run.apply(.agentSignal(W.nova, .turnReopened(promptID: "p-2")))
        run.apply(.agentSignal(W.nova, .turnReopened(promptID: nil)))
        run.apply(.agentSignal(W.pixou, .turnReopened(promptID: "p-1")))
        #expect(run.board == before)
        // Validated once, reopened and delivered again: its turn never comes back to life.
        run.apply(.validate(S.card(1)))
        run.apply(.reopen(S.card(1)))
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s"))
        run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-5")))
        run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-5")))
        before = run.board
        run.apply(.agentSignal(W.nova, .turnReopened(promptID: "p-5")))
        #expect(run.board == before)
        #expect(run.card(1)?.column == .review)
    }

    // MARK: - C13 turn failed, interrupted, session lost

    @Test(arguments: [(AgentCardSignal.turnFailed, CardFlag.turnFailed, CardEventKind.turnFailed),
                      (.interrupted, .interrupted, .interrupted),
                      (.sessionLost, .sessionLost, .sessionLost)])
    func c13_aStoppedTurnFlagsTheRunningCard(signal: AgentCardSignal, flag: CardFlag, kind: CardEventKind) throws {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        let effects = run.apply(.agentSignal(W.nova, signal))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .inProgress && card.flags == [flag])
        #expect(card.history.last == CardEvent(at: run.now, kind: kind, agentID: W.nova))
        let before = run.board
        run.apply(.agentSignal(W.nova, signal))
        #expect(run.board == before)
    }

    @Test func c13_sessionLostDuringADeliveryFailsIt() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s-1"))
        let effects = run.apply(.agentSignal(W.nova, .sessionLost))
        #expect(effects == [.notify("Échec d'envoi de « Pagination » à l'agent. La file est en pause.")])
        let card = try #require(run.card(1))
        #expect(card.column == .todo && card.delivery == nil && card.flags == [.deliveryFailed])
    }

    // MARK: - C14 continue

    @Test func c14_continueTaskQueuesAnInstructionAtTheHead() throws {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        run.create(2, "En file")
        run.apply(.assign(S.card(2), to: W.nova))
        run.apply(.agentSignal(W.nova, .interrupted))
        let effects = run.apply(.continueTask(S.card(1), instructionID: S.instruction(1)))
        #expect(effects == [.pump(W.nova)])
        let card = try #require(run.card(1))
        #expect(card.column == .inProgress && card.flags.isEmpty)
        #expect(card.history.last == CardEvent(at: run.now, kind: .continued, agentID: W.nova))
        let instruction = try #require(run.board.instructions.first)
        #expect(instruction == QueuedInstruction(id: S.instruction(1), agentID: W.nova,
                                                 text: "Continue la tâche : Pagination", cardID: S.card(1),
                                                 queueRank: instruction.queueRank, createdAt: run.now))
        #expect(W.queue(of: W.nova, in: run.board) == [.instruction(S.instruction(1)), .card(S.card(2))])
        #expect(W.isStrictlyAscending(W.queueKeys(of: W.nova, in: run.board)))
        // Delivered: the card keeps running with the new turn.
        run.apply(.deliveryStarted(.instruction(S.instruction(1)), agent: W.nova, sessionID: "session-1"))
        run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-2")))
        let resumed = try #require(run.card(1))
        #expect(resumed.column == .inProgress && resumed.flags.isEmpty)
        #expect(resumed.delivery?.promptID == "p-2" && resumed.delivery?.confirmedAt == run.now)
        #expect(run.board.instructions.isEmpty)
        run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-2")))
        #expect(run.card(1)?.column == .review)
    }

    @Test func c14_continueTaskNeedsAStoppedCardAndALiveAgent() {
        var run = LifecycleRun()
        run.start(1, "En cours", promptID: "p-1")
        let notStopped = run.refused(.continueTask(S.card(1), instructionID: S.instruction(1)))
        #expect(notStopped == [.rejected(.notAllowed("notStopped"), message: M.nothingToContinue)])
        run.start(2, "Logo", agent: W.oslo, promptID: "p-2")
        run.apply(.agentSignal(W.oslo, .sessionLost))
        let offline = run.refused(.continueTask(S.card(2), instructionID: S.instruction(1)))
        #expect(offline == [.rejected(.notAllowed("agentOffline"), message: "Relance d'abord la session de l'agent.")])
        // Nova runs card 3 now: card 1, interrupted, must wait.
        run.apply(.agentSignal(W.nova, .interrupted))
        run.start(3, "Suivante", promptID: "p-3")
        let busy = run.refused(.continueTask(S.card(1), instructionID: S.instruction(1)))
        #expect(busy == [.rejected(.notAllowed("otherCardRunning"), message: M.otherCardRunning)])
        run.create(4, "À faire")
        let todo = run.refused(.continueTask(S.card(4), instructionID: S.instruction(1)))
        #expect(todo == [.rejected(.notAllowed("notInProgress"), message: M.continueNeedsInProgress)])
    }

    // MARK: - C15 put back

    @Test func c15_putBackReturnsTheCardToTodoUnassigned() throws {
        var run = LifecycleRun()
        run.create(9, "Déjà là")
        run.review(1, "Pagination", promptID: "p-1")
        let effects = run.apply(.putBack(S.card(1)))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .todo && card.assignee == nil && card.queueRank == nil)
        #expect(card.flags.isEmpty && card.delivery == nil)
        #expect(card.history.last == CardEvent(at: run.now, kind: .putBack, from: .review, to: .todo, agentID: W.nova,
                                               note: "tour p-1"))
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(9), S.card(1)])
        // The agent's late Stop or reopening no longer affects it.
        let before = run.board
        run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-1")))
        run.apply(.agentSignal(W.nova, .turnReopened(promptID: "p-1")))
        #expect(run.board == before)
    }

    @Test func c15_dragToTodoPutsBackAtThePlaceAndDropsItsInstructions() throws {
        var run = LifecycleRun()
        run.create(9, "Déjà là")
        run.start(1, "Pagination", promptID: "p-1")
        run.apply(.agentSignal(W.nova, .interrupted))
        run.apply(.continueTask(S.card(1), instructionID: S.instruction(1)))
        run.apply(.agentSignal(W.nova, .interrupted))
        let effects = run.apply(.move(S.card(1), to: .todo, after: nil))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .todo && card.assignee == nil && card.flags.isEmpty && card.delivery == nil)
        #expect(card.history.last?.kind == .putBack && card.history.last?.from == .inProgress)
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(1), S.card(9)])
        // "Continue la tâche" was waiting in Nova's queue for this card: it no longer makes sense.
        #expect(run.board.instructions.isEmpty)
        #expect(run.refused(.putBack(S.card(9))) == [.rejected(.notAllowed("alreadyTodo"), message: M.alreadyTodo)])
    }

    // MARK: - C16 mark for review

    @Test func c16_markForReviewMovesARunningCardToReview() throws {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        run.apply(.agentSignal(W.nova, .interrupted))
        let effects = run.apply(.markForReview(S.card(1)))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .review && card.assignee == W.nova)
        #expect(card.history.last == CardEvent(at: run.now, kind: .markedForReview, from: .inProgress, to: .review,
                                               agentID: W.nova))
        run.start(2, "Header", agent: W.pixou, promptID: "p-2")
        run.apply(.move(S.card(2), to: .review, after: nil))
        #expect(run.board.cards(in: .review).map(\.id) == [S.card(2), S.card(1)])
        run.create(3, "À faire")
        let refusal = TaskEffect.rejected(.notAllowed("notInProgress"), message: M.reviewNeedsInProgress)
        #expect(run.refused(.markForReview(S.card(3))) == [refusal])
        #expect(run.refused(.move(S.card(3), to: .review, after: nil)) == [refusal])
    }

    // MARK: - C17 resend with a precision

    @Test func c17_resendQueuesThePrecisionAtTheHeadOfTheSameAgent() throws {
        var run = LifecycleRun()
        run.review(1, "Pagination", promptID: "p-1")
        run.create(2, "En file")
        run.apply(.assign(S.card(2), to: W.nova))
        let reviewed = try #require(run.card(1))
        let effects = run.apply(.resend(S.card(1), precision: "  Ajoute aussi un test \n",
                                        instructionID: S.instruction(1)))
        #expect(effects == [.pump(W.nova)])
        let card = try #require(run.card(1))
        #expect(card.column == .review && card.delivery == reviewed.delivery && card.assignee == W.nova)
        #expect(card.history.last?.kind == .resent)
        let instruction = try #require(run.board.instructions.first)
        #expect(instruction == QueuedInstruction(id: S.instruction(1), agentID: W.nova, text: "Ajoute aussi un test",
                                                 cardID: S.card(1), queueRank: instruction.queueRank,
                                                 createdAt: run.now))
        #expect(W.queue(of: W.nova, in: run.board) == [.instruction(S.instruction(1)), .card(S.card(2))])
        // Delivered and confirmed: back to "En cours" with the new turn.
        run.apply(.deliveryStarted(.instruction(S.instruction(1)), agent: W.nova, sessionID: "session-1"))
        let sentAt = run.now
        run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-2")))
        let resumed = try #require(run.card(1))
        #expect(resumed.column == .inProgress && resumed.flags.isEmpty)
        #expect(resumed.delivery == DeliveryInfo(sessionID: "session-1", promptID: "p-2", sentAt: sentAt,
                                                 confirmedAt: run.now))
        #expect(resumed.history.last == CardEvent(at: run.now, kind: .deliveryConfirmed, from: .review,
                                                  to: .inProgress, agentID: W.nova, note: "tour p-2"))
        #expect(run.board.instructions.isEmpty)
        #expect(run.card(2)?.column == .todo)
    }

    @Test func c17_resendWarnsWhenTheSessionChanged() {
        var run = LifecycleRun()
        run.review(1, "Pagination", promptID: "p-1")
        run.sessionIDs = [W.nova: "session-1"]
        #expect(run.apply(.resend(S.card(1), precision: "Et les tests", instructionID: S.instruction(1)))
            == [.pump(W.nova)])
        run.sessionIDs = [W.nova: "session-2"]
        #expect(run.apply(.resend(S.card(1), precision: "Et la doc", instructionID: S.instruction(2)))
            == [.warn(M.sessionChanged), .pump(W.nova)])
    }

    @Test func c17_resendNeedsAReviewCardAndALiveAgent() {
        var run = LifecycleRun()
        run.review(1, "Logo", agent: W.oslo, promptID: "p-1")
        let offline = run.refused(.resend(S.card(1), precision: "Plus grand", instructionID: S.instruction(1)))
        #expect(offline == [.rejected(.notAllowed("agentOffline"), message: "Relance d'abord la session de l'agent.")])
        run.review(2, "Pagination", promptID: "p-2")
        let blank = run.refused(.resend(S.card(2), precision: " \n", instructionID: S.instruction(1)))
        #expect(blank == [.rejected(.notAllowed("emptyPrecision"), message: M.emptyPrecision)])
        run.create(3, "À faire")
        let todo = run.refused(.resend(S.card(3), precision: "Plus vite", instructionID: S.instruction(1)))
        #expect(todo == [.rejected(.notAllowed("notInReview"), message: M.resendNeedsReview)])
    }

    // MARK: - C18 validate

    @Test func c18_validateMovesAReviewCardToDoneAndCountsItOnce() throws {
        var run = LifecycleRun()
        run.review(1, "Pagination", promptID: "p-1")
        let effects = run.apply(.validate(S.card(1)))
        #expect(effects == [.validated(S.card(1), firstTime: true)])
        let card = try #require(run.card(1))
        #expect(card.column == .done && card.validatedOnce && card.assignee == W.nova && card.flags.isEmpty)
        #expect(card.history.last == CardEvent(at: run.now, kind: .validated, from: .review, to: .done,
                                               agentID: W.nova))
        #expect(run.refused(.validate(S.card(1))) == [.rejected(.notAllowed("alreadyDone"), message: M.alreadyDone)])
        // Reopened, delivered again, validated again: counted only the first time.
        run.apply(.reopen(S.card(1)))
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s"))
        run.apply(.agentSignal(W.nova, .deliveryConfirmed(promptID: "p-2")))
        run.apply(.agentSignal(W.nova, .turnCommitted(promptID: "p-2")))
        #expect(run.apply(.move(S.card(1), to: .done, after: nil)) == [.validated(S.card(1), firstTime: false)])
        #expect(run.card(1)?.column == .done)
    }

    @Test func c18_validateFromTodoOrInProgressIsAllowed() throws {
        var run = LifecycleRun()
        // A queued card being sent, never delivered: it leaves the queue and counts for nothing.
        run.create(1, "Jamais livrée")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s"))
        #expect(run.apply(.validate(S.card(1))) == [.validated(S.card(1), firstTime: false)])
        let never = try #require(run.card(1))
        #expect(never.column == .done && never.assignee == nil && never.queueRank == nil)
        #expect(never.delivery == nil && !never.validatedOnce)
        #expect(never.history.last?.from == .todo)
        // A running card was delivered: it counts.
        run.start(2, "En cours", agent: W.pixou, promptID: "p-2")
        #expect(run.apply(.move(S.card(2), to: .done, after: S.card(1))) == [.validated(S.card(2), firstTime: true)])
        let running = try #require(run.card(2))
        #expect(running.column == .done && running.assignee == W.pixou && running.validatedOnce)
        #expect(run.board.cards(in: .done).map(\.id) == [S.card(1), S.card(2)])
    }

    // MARK: - C19 reopen

    @Test func c19_reopenReturnsADoneCardToTodoUnassigned() throws {
        var run = LifecycleRun()
        run.create(9, "Déjà là")
        run.review(1, "Pagination", promptID: "p-1")
        run.apply(.validate(S.card(1)))
        let effects = run.apply(.reopen(S.card(1)))
        #expect(effects.isEmpty)
        let card = try #require(run.card(1))
        #expect(card.column == .todo && card.assignee == nil && card.queueRank == nil && card.validatedOnce)
        #expect(card.history.last == CardEvent(at: run.now, kind: .reopened, from: .done, to: .todo))
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(9), S.card(1)])
        #expect(run.refused(.reopen(S.card(1))) == [.rejected(.notAllowed("notDone"), message: M.reopenNeedsDone)])
        // Dragging a done card to "À faire" reopens it too, where it is dropped.
        run.review(2, "Header", agent: W.pixou, promptID: "p-2")
        run.apply(.validate(S.card(2)))
        run.apply(.move(S.card(2), to: .todo, after: nil))
        #expect(run.card(2)?.history.last?.kind == .reopened)
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(2), S.card(9), S.card(1)])
        #expect(run.refused(.putBack(S.card(1))) == [.rejected(.notAllowed("alreadyTodo"), message: M.alreadyTodo)])
    }

    // MARK: - C20 delete

    @Test func c20_deleteRemovesTheCardAndItsInstructions() {
        var run = LifecycleRun()
        run.review(1, "Pagination", promptID: "p-1")
        run.apply(.resend(S.card(1), precision: "Précision", instructionID: S.instruction(1)))
        run.apply(.giveInstruction(agent: W.nova, text: "Autre", instructionID: S.instruction(2), atHead: false))
        run.create(2, "Reste")
        let effects = run.apply(.delete(S.card(1)))
        #expect(effects.isEmpty)
        #expect(run.card(1) == nil)
        #expect(run.board.instructions.map(\.id) == [S.instruction(2)])
        #expect(run.board.cards.map(\.id) == [S.card(2)])
        #expect(run.refused(.delete(S.card(1))) == [.rejected(.unknownCard, message: M.unknownCard)])
    }

    // MARK: - Instructions, agents, edits, templates, moves

    @Test func giveInstructionGoesBeforeTheCardsOrAtTheHead() throws {
        var run = LifecycleRun()
        run.create(1, "En file")
        run.apply(.assign(S.card(1), to: W.nova))
        let effects = run.apply(.giveInstruction(agent: W.nova, text: " Première ", instructionID: S.instruction(1),
                                                 atHead: false))
        #expect(effects == [.pump(W.nova)])
        run.apply(.giveInstruction(agent: W.nova, text: "Deuxième", instructionID: S.instruction(2), atHead: false))
        run.apply(.giveInstruction(agent: W.nova, text: "Urgente", instructionID: S.instruction(3), atHead: true))
        #expect(W.queue(of: W.nova, in: run.board) == [.instruction(S.instruction(3)), .instruction(S.instruction(1)),
                                                        .instruction(S.instruction(2)), .card(S.card(1))])
        #expect(W.isStrictlyAscending(W.queueKeys(of: W.nova, in: run.board)))
        let first = try #require(run.board.instructions.first { $0.id == S.instruction(1) })
        #expect(first.text == "Première" && first.cardID == nil && first.agentID == W.nova && first.delivery == nil)
        #expect(first.createdAt == S.at(103))
        #expect(run.refused(.giveInstruction(agent: S.agent(9), text: "x", instructionID: S.instruction(4), atHead: false))
            == [.rejected(.unknownAgent, message: M.unknownAgent)])
        #expect(run.refused(.giveInstruction(agent: W.nova, text: " ", instructionID: S.instruction(4), atHead: false))
            == [.rejected(.notAllowed("emptyInstruction"), message: M.emptyInstruction)])
        #expect(run.refused(.giveInstruction(agent: W.nova, text: "x", instructionID: S.instruction(1), atHead: false))
            == [.rejected(.notAllowed("duplicateInstruction"), message: M.duplicateInstruction)])
    }

    @Test func agentRemovedUnassignsTodoAndFlagsInProgress() throws {
        var run = LifecycleRun()
        run.review(4, "Fini", promptID: "p-4")
        run.apply(.validate(S.card(4)))
        run.review(3, "À relire", promptID: "p-3")
        run.start(2, "En cours", promptID: "p-2")
        run.apply(.agentSignal(W.nova, .interrupted))
        run.create(1, "En file")
        run.apply(.assign(S.card(1), to: W.nova))
        run.apply(.deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: "s"))
        run.apply(.agentSignal(W.nova, .deliveryFailed(.noPromptSubmit)))
        run.apply(.giveInstruction(agent: W.nova, text: "Consigne", instructionID: S.instruction(1), atHead: false))
        run.create(5, "Chez Pixou")
        run.apply(.assign(S.card(5), to: W.pixou))
        run.apply(.giveInstruction(agent: W.pixou, text: "Pour Pixou", instructionID: S.instruction(2), atHead: false))
        run.create(6, "Libre")
        let pixouCard = run.card(5)
        let effects = run.apply(.agentRemoved(W.nova))
        #expect(effects.isEmpty)
        // No card is lost; every card of Nova is back in "À faire", unassigned, at the end.
        #expect(run.board.cards.count == 6)
        for (n, from) in [(1, Column.todo), (2, .inProgress), (3, .review)] {
            let card = try #require(run.card(n))
            #expect(card.column == .todo && card.assignee == nil && card.queueRank == nil)
            #expect(card.flags.isEmpty && card.delivery == nil)
            let event = try #require(card.history.last)
            #expect(event.kind == .unassigned && event.from == from && event.to == .todo && event.agentID == W.nova)
        }
        #expect(run.card(2)?.history.last?.note?.contains("p-2") == true)
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(5), S.card(6), S.card(1), S.card(2), S.card(3)])
        // A done card keeps its column and its validation, not the agent.
        let done = try #require(run.card(4))
        #expect(done.column == .done && done.assignee == nil && done.validatedOnce)
        #expect(run.card(5) == pixouCard)
        #expect(run.board.instructions.map(\.id) == [S.instruction(2)])
    }

    @Test func editChangesTheTextFieldsAndRecordsEachChange() throws {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        #expect(run.apply(.edit(S.card(1), .title("  Pagination /users "))).isEmpty)
        run.apply(.edit(S.card(1), .details("20 par page")))
        run.apply(.edit(S.card(1), .priority(.high)))
        run.apply(.edit(S.card(1), .tags(["#API", "api", "back"])))
        run.apply(.edit(S.card(1), .template(S.template(1))))
        run.apply(.edit(S.card(1), .project(W.site)))
        let card = try #require(run.card(1))
        #expect(card.title == "Pagination /users" && card.details == "20 par page" && card.priority == .high)
        #expect(card.tags == ["API", "back"] && card.templateID == S.template(1) && card.projectID == W.site)
        #expect(card.history.map(\.kind) == [.created, .edited, .edited, .edited, .edited, .edited, .projectChanged])
        #expect(card.updatedAt == run.now)
        // The same values again: nothing recorded.
        let before = run.board
        for edit in [CardEdit.title("Pagination /users"), .details("20 par page"), .priority(.high),
                     .tags(["API", "#back"]), .template(S.template(1)), .project(W.site)] {
            #expect(run.apply(.edit(S.card(1), edit)).isEmpty)
        }
        #expect(run.board == before)
        run.apply(.edit(S.card(1), .template(nil)))
        #expect(run.card(1)?.templateID == nil)
    }

    @Test func editRefusesABlankTitleAnUnknownTemplateOrAProjectWhileAssigned() {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        run.apply(.assign(S.card(1), to: W.nova))
        #expect(run.refused(.edit(S.card(1), .title(" \n")))
            == [.rejected(.notAllowed("emptyTitle"), message: "Un post-it a besoin d'un titre.")])
        #expect(run.refused(.edit(S.card(1), .template(S.template(9))))
            == [.rejected(.notAllowed("unknownTemplate"), message: M.unknownTemplate)])
        #expect(run.refused(.edit(S.card(1), .project(W.site)))
            == [.rejected(.notAllowed("projectLocked"), message: M.projectLocked)])
        run.apply(.unassign(S.card(1)))
        run.apply(.edit(S.card(1), .project(W.site)))
        #expect(run.card(1)?.projectID == W.site)
    }

    @Test func templatesAreUpsertedAndDeletedCardsFallBackToNone() throws {
        var run = LifecycleRun()
        let custom = PromptTemplate(id: S.template(4), name: "Revue", body: "Relis {titre}")
        #expect(run.apply(.upsertTemplate(custom)).isEmpty)
        #expect(run.board.template(S.template(4)) == custom)
        var renamed = custom
        renamed.name = "Relecture"
        run.apply(.upsertTemplate(renamed))
        #expect(run.board.templates.count == 4 && run.board.template(S.template(4))?.name == "Relecture")
        #expect(run.refused(.upsertTemplate(PromptTemplate(id: S.template(5), name: " ", body: "")))
            == [.rejected(.notAllowed("emptyTemplateName"), message: M.emptyTemplateName)])
        run.apply(.create(id: S.card(1), title: "Avec modèle", details: "", projectID: nil, priority: .normal, tags: [],
                          templateID: S.template(4)))
        run.create(2, "Sans modèle")
        #expect(run.apply(.deleteTemplate(S.template(4))).isEmpty)
        #expect(run.board.template(S.template(4)) == nil && run.board.templates.count == 3)
        let card = try #require(run.card(1))
        #expect(card.templateID == nil && card.history.last?.kind == .edited && card.updatedAt == run.now)
        #expect(run.card(2)?.history.count == 1)
        #expect(run.refused(.deleteTemplate(S.template(4)))
            == [.rejected(.notAllowed("unknownTemplate"), message: M.unknownTemplate)])
    }

    @Test func moveInsideAColumnReordersIt() throws {
        var run = LifecycleRun()
        for n in 1...3 { run.create(n, "Carte \(n)") }
        #expect(run.apply(.move(S.card(3), to: .todo, after: S.card(1))).isEmpty)
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(1), S.card(3), S.card(2)])
        #expect(run.card(3)?.history.last == CardEvent(at: run.now, kind: .reordered, from: .todo, to: .todo))
        run.apply(.move(S.card(2), to: .todo, after: nil))
        #expect(run.board.cards(in: .todo).map(\.id) == [S.card(2), S.card(1), S.card(3)])
        // Already in place: nothing changes.
        let before = run.board
        #expect(run.apply(.move(S.card(1), to: .todo, after: S.card(2))).isEmpty)
        #expect(run.apply(.move(S.card(1), to: .todo, after: S.card(1))).isEmpty)
        #expect(run.board == before)
        run.start(4, "En cours", agent: W.pixou, promptID: "p-4")
        #expect(run.refused(.move(S.card(1), to: .todo, after: S.card(4)))
            == [.rejected(.notAllowed("notInColumn"), message: M.positionNotInColumn)])
        #expect(run.refused(.move(S.card(1), to: .todo, after: S.card(99)))
            == [.rejected(.unknownCard, message: M.unknownCard)])
        // "En cours" can be reordered too: nothing starts or stops.
        run.start(5, "Autre", agent: W.nova, promptID: "p-5")
        run.apply(.move(S.card(5), to: .inProgress, after: nil))
        #expect(run.board.cards(in: .inProgress).map(\.id) == [S.card(5), S.card(4)])
    }

    @Test func aRefusedInputChangesNothingAndEmitsOneRejection() {
        var run = LifecycleRun()
        run.start(1, "Pagination", promptID: "p-1")
        let inputs: [TaskInput] = [
            .edit(S.card(1), .title("")), .assign(S.card(1), to: W.pixou), .unassign(S.card(1)), .retry(S.card(1)),
            .continueTask(S.card(1), instructionID: S.instruction(1)),
            .resend(S.card(1), precision: "x", instructionID: S.instruction(1)), .reopen(S.card(1)),
            .deliveryStarted(.card(S.card(1)), agent: W.nova, sessionID: nil), .deleteTemplate(S.template(9)),
            .move(S.card(1), to: .todo, after: S.card(1)),
        ]
        for input in inputs {
            let effects = run.refused(input)
            guard case .rejected = effects.first else {
                Issue.record("\(input) was not refused: \(effects)")
                continue
            }
        }
    }

    @Test func anUnknownCardIsRefused() {
        var run = LifecycleRun()
        run.create(1, "Pagination")
        let lost = S.card(99)
        let inputs: [TaskInput] = [
            .edit(lost, .title("x")), .assign(lost, to: W.nova), .unassign(lost), .reorderQueue(lost, after: nil),
            .move(lost, to: .done, after: nil), .deliveryStarted(.card(lost), agent: W.nova, sessionID: nil),
            .retry(lost), .continueTask(lost, instructionID: S.instruction(1)), .putBack(lost), .markForReview(lost),
            .resend(lost, precision: "x", instructionID: S.instruction(1)), .validate(lost), .reopen(lost), .delete(lost),
        ]
        for input in inputs {
            #expect(run.refused(input) == [.rejected(.unknownCard, message: M.unknownCard)], "\(input)")
        }
    }

    // MARK: - Confirmations

    @Test func confirmationAssignAcrossProjects() {
        var run = LifecycleRun()
        run.create(1, "Logo", project: W.site)
        run.create(2, "API", project: W.api)
        run.create(3, "Sans projet", project: nil)
        let context = W.context(at: 200)
        func ask(_ input: TaskInput) -> ConfirmationKind? {
            TaskLifecycle.confirmation(for: input, state: run.board, context: context)
        }
        #expect(ask(.assign(S.card(1), to: W.nova)) == .assignAcrossProjects(agent: W.nova, from: W.site, to: W.api))
        #expect(ask(.assign(S.card(1), to: W.oslo)) == nil)
        #expect(ask(.assign(S.card(2), to: W.nova)) == nil)
        // No project yet: it takes the agent's without asking.
        #expect(ask(.assign(S.card(3), to: W.nova)) == nil)
        #expect(ask(.assign(S.card(1), to: S.agent(9))) == nil)
        #expect(ask(.assign(S.card(99), to: W.nova)) == nil)
    }

    @Test func confirmationMarkDoneWithoutReview() {
        var run = LifecycleRun()
        run.create(1, "À faire")
        run.start(2, "En cours", promptID: "p-2")
        run.review(3, "À valider", agent: W.pixou, promptID: "p-3")
        let context = W.context(at: 200)
        func ask(_ input: TaskInput) -> ConfirmationKind? {
            TaskLifecycle.confirmation(for: input, state: run.board, context: context)
        }
        #expect(ask(.validate(S.card(1))) == .markDoneWithoutReview(S.card(1)))
        #expect(ask(.move(S.card(1), to: .done, after: nil)) == .markDoneWithoutReview(S.card(1)))
        #expect(ask(.validate(S.card(2))) == .markDoneWithoutReview(S.card(2)))
        #expect(ask(.move(S.card(2), to: .done, after: S.card(3))) == .markDoneWithoutReview(S.card(2)))
        #expect(ask(.validate(S.card(3))) == nil)
        #expect(ask(.move(S.card(3), to: .done, after: nil)) == nil)
        #expect(ask(.move(S.card(2), to: .review, after: nil)) == nil)
    }

    @Test func confirmationDeleteInProgress() {
        var run = LifecycleRun()
        run.create(1, "À faire")
        run.start(2, "En cours", promptID: "p-2")
        let context = W.context(at: 200)
        #expect(TaskLifecycle.confirmation(for: .delete(S.card(2)), state: run.board, context: context)
            == .deleteInProgress(S.card(2)))
        #expect(TaskLifecycle.confirmation(for: .delete(S.card(1)), state: run.board, context: context) == nil)
        #expect(TaskLifecycle.confirmation(for: .putBack(S.card(2)), state: run.board, context: context) == nil)
    }
}
