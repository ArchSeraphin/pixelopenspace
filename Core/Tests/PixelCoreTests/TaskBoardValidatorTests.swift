import Foundation
import Testing
@testable import PixelCore

@Suite struct TaskBoardValidatorTests {
    typealias S = TaskBoardSamples

    static let agents: Set<AgentID> = [S.agent(1), S.agent(2)]
    static let projects: Set<ProjectID> = [S.project(1), S.project(2)]

    static func validate(_ board: TaskBoardState) -> (board: TaskBoardState, issues: [String]) {
        TaskBoardValidator.validate(board, agents: agents, projects: projects)
    }

    static func board(_ cards: [TaskCard], instructions: [QueuedInstruction] = []) -> TaskBoardState {
        TaskBoardState(cards: cards, instructions: instructions, templates: StarterTemplates.make(ids: S.templateIDs))
    }

    @Test func validBoardIsUntouched() {
        let board = S.board()
        let (fixed, issues) = Self.validate(board)
        #expect(fixed == board)
        #expect(issues.isEmpty)
    }

    @Test func unknownAssigneeIsUnassigned() throws {
        let lost = S.agent(9)
        let card = TaskCard(id: S.card(1), title: "Orpheline", projectID: S.project(1), rank: "i", assignee: lost,
                            queueRank: "k", delivery: DeliveryInfo(sessionID: "s", sentAt: S.at(3)),
                            flags: [.deliveryFailed], history: [CardEvent(at: S.at(1), kind: .created, to: .todo)],
                            createdAt: S.at(1), updatedAt: S.at(3))
        let (fixed, issues) = Self.validate(Self.board([card]))
        let repaired = try #require(fixed.card(S.card(1)))
        #expect(repaired.column == .todo)
        #expect(repaired.assignee == nil && repaired.queueRank == nil)
        #expect(repaired.flags.isEmpty)
        #expect(repaired.delivery == nil)
        #expect(repaired.rank == "i")
        #expect(repaired.history.count == 2)
        let event = try #require(repaired.history.last)
        #expect(event.kind == .unassigned && event.agentID == lost && event.from == .todo && event.to == .todo)
        #expect(event.at == S.at(3))
        #expect(repaired.updatedAt == S.at(3))
        #expect(issues.count == 1)
        #expect(issues[0].contains("Orpheline"))
    }

    @Test func unknownAssigneeInProgressOrReviewGoesBackToTodo() throws {
        let lost = S.agent(9)
        let waiting = TaskCard(id: S.card(1), title: "En attente", projectID: nil, rank: "i", createdAt: S.at(1))
        let running = TaskCard(id: S.card(2), title: "En cours", projectID: nil, column: .inProgress, rank: "i",
                               assignee: lost, delivery: DeliveryInfo(promptID: "p-2", sentAt: S.at(2), confirmedAt: S.at(2.5)),
                               flags: [.sessionLost, .backgroundRunning], createdAt: S.at(2), updatedAt: S.at(4))
        let reviewing = TaskCard(id: S.card(3), title: "À relire", projectID: nil, column: .review, rank: "i",
                                 assignee: lost,
                                 delivery: DeliveryInfo(promptID: "p-3", sentAt: S.at(3), confirmedAt: S.at(3.5), turnEndedAt: S.at(5)),
                                 createdAt: S.at(3), updatedAt: S.at(5))
        let (fixed, issues) = Self.validate(Self.board([waiting, running, reviewing]))
        #expect(fixed.cards.count == 3)
        #expect(fixed.cards(in: .todo).map(\.id) == [S.card(1), S.card(2), S.card(3)])
        #expect(fixed.cards(in: .inProgress).isEmpty && fixed.cards(in: .review).isEmpty)
        for (id, from) in [(S.card(2), Column.inProgress), (S.card(3), Column.review)] {
            let card = try #require(fixed.card(id))
            #expect(card.assignee == nil && card.queueRank == nil)
            #expect(card.flags.isEmpty)
            #expect(!card.flags.contains(.sessionLost))
            #expect(card.delivery == nil)
            let event = try #require(card.history.last)
            #expect(event.kind == .unassigned && event.from == from && event.to == .todo && event.agentID == lost)
        }
        // The delivery is kept in the history.
        #expect(fixed.card(S.card(2))?.history.last?.note?.contains("p-2") == true)
        #expect(fixed.card(S.card(3))?.history.last?.note?.contains("p-3") == true)
        #expect(issues.count == 2)
    }

    @Test func unknownAssigneeOnDoneCardIsCleared() throws {
        let done = TaskCard(id: S.card(1), title: "Fini", projectID: nil, column: .done, rank: "i", assignee: S.agent(9),
                            delivery: DeliveryInfo(promptID: "p", sentAt: S.at(1), confirmedAt: S.at(2), turnEndedAt: S.at(3)),
                            validatedOnce: true, createdAt: S.at(1), updatedAt: S.at(4))
        let (fixed, issues) = Self.validate(Self.board([done]))
        let card = try #require(fixed.card(S.card(1)))
        #expect(card.column == .done)
        #expect(card.assignee == nil)
        #expect(card.validatedOnce && card.delivery == done.delivery)
        #expect(issues.count == 1)
    }

    @Test func unknownProjectIsCleared() throws {
        let card = TaskCard(id: S.card(1), title: "Ailleurs", projectID: S.project(9), rank: "i", createdAt: S.t0)
        let known = TaskCard(id: S.card(2), title: "Ici", projectID: S.project(2), rank: "r", createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([card, known]))
        #expect(fixed.card(S.card(1))?.projectID == nil)
        #expect(fixed.card(S.card(2))?.projectID == S.project(2))
        #expect(issues.count == 1)
    }

    @Test func queueRankOutsideTheQueueIsRemoved() throws {
        let unassigned = TaskCard(id: S.card(1), title: "Libre", projectID: nil, rank: "i", queueRank: "k", createdAt: S.t0)
        let running = TaskCard(id: S.card(2), title: "En cours", projectID: nil, column: .inProgress, rank: "i",
                               assignee: S.agent(1), queueRank: "k", createdAt: S.t0)
        let queued = TaskCard(id: S.card(3), title: "En file", projectID: nil, rank: "r", assignee: S.agent(1),
                              queueRank: "k", createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([unassigned, running, queued]))
        #expect(fixed.card(S.card(1))?.queueRank == nil)
        #expect(fixed.card(S.card(2))?.queueRank == nil)
        #expect(fixed.card(S.card(3))?.queueRank == "k")
        #expect(issues.count == 2)
    }

    @Test func missingQueueRankIsAppendedToTheAgentQueue() throws {
        let first = TaskCard(id: S.card(1), title: "Premier", projectID: nil, rank: "c", assignee: S.agent(1),
                             queueRank: "k", createdAt: S.t0)
        let second = TaskCard(id: S.card(2), title: "Deuxième", projectID: nil, rank: "m", assignee: S.agent(1),
                              createdAt: S.t0)
        let third = TaskCard(id: S.card(3), title: "Troisième", projectID: nil, rank: "t", assignee: S.agent(1),
                             createdAt: S.t0)
        // Agent 2's queue: its instruction's rank counts too.
        let other = TaskCard(id: S.card(4), title: "Autre", projectID: nil, rank: "x", assignee: S.agent(2),
                             createdAt: S.t0)
        let instruction = QueuedInstruction(id: S.instruction(1), agentID: S.agent(2), text: "Précision",
                                            queueRank: "p", createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([third, first, second, other], instructions: [instruction]))
        let r1 = try #require(fixed.card(S.card(1))?.queueRank)
        let r2 = try #require(fixed.card(S.card(2))?.queueRank)
        let r3 = try #require(fixed.card(S.card(3))?.queueRank)
        let r4 = try #require(fixed.card(S.card(4))?.queueRank)
        #expect(r1 == "k")
        #expect(r1 < r2 && r2 < r3)
        #expect(r2 == RankKey.after("k"))
        #expect(r4 == RankKey.after("p"))
        #expect(issues.count == 3)
    }

    @Test func twoInProgressCardsForOneAgentKeepTheOldest() throws {
        let newer = TaskCard(id: S.card(1), title: "Plus récente", projectID: nil, column: .inProgress, rank: "c",
                             assignee: S.agent(1), createdAt: S.at(1), updatedAt: S.at(10))
        let oldest = TaskCard(id: S.card(2), title: "Plus ancienne", projectID: nil, column: .inProgress, rank: "i",
                              assignee: S.agent(1), createdAt: S.at(2), updatedAt: S.at(5))
        let newest = TaskCard(id: S.card(3), title: "Dernière", projectID: nil, column: .inProgress, rank: "r",
                              assignee: S.agent(1), flags: [.backgroundRunning], createdAt: S.at(3), updatedAt: S.at(20))
        let otherAgent = TaskCard(id: S.card(4), title: "Autre agent", projectID: nil, column: .inProgress, rank: "x",
                                  assignee: S.agent(2), createdAt: S.at(4), updatedAt: S.at(30))
        let (fixed, issues) = Self.validate(Self.board([newer, oldest, newest, otherAgent]))
        #expect(fixed.cards.count == 4)
        #expect(fixed.cards.allSatisfy { $0.column == .inProgress })
        #expect(fixed.card(S.card(2))?.flags == [])
        #expect(fixed.card(S.card(1))?.flags == [.interrupted])
        #expect(fixed.card(S.card(3))?.flags == [.backgroundRunning, .interrupted])
        #expect(fixed.card(S.card(4))?.flags == [])
        #expect(fixed.cards.allSatisfy { $0.assignee != nil })
        #expect(issues.count == 2)
    }

    @Test func interruptedInProgressCardsDoNotCompete() {
        // A card already stopped (interrupted, failed turn, lost session) leaves room for the current one.
        let stopped = TaskCard(id: S.card(1), title: "Interrompue", projectID: nil, column: .inProgress, rank: "c",
                               assignee: S.agent(1), flags: [.interrupted], createdAt: S.at(1), updatedAt: S.at(1))
        let failed = TaskCard(id: S.card(2), title: "Échouée", projectID: nil, column: .inProgress, rank: "i",
                              assignee: S.agent(1), flags: [.turnFailed], createdAt: S.at(2), updatedAt: S.at(2))
        let current = TaskCard(id: S.card(3), title: "Actuelle", projectID: nil, column: .inProgress, rank: "r",
                               assignee: S.agent(1), createdAt: S.at(3), updatedAt: S.at(3))
        let board = Self.board([stopped, failed, current])
        let (fixed, issues) = Self.validate(board)
        #expect(fixed == board)
        #expect(issues.isEmpty)
    }

    @Test func unknownTemplateIsCleared() {
        let card = TaskCard(id: S.card(1), title: "Modèle perdu", projectID: nil, rank: "i", templateID: S.template(9),
                            createdAt: S.t0)
        let known = TaskCard(id: S.card(2), title: "Modèle connu", projectID: nil, rank: "r", templateID: S.template(1),
                             createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([card, known]))
        #expect(fixed.card(S.card(1))?.templateID == nil)
        #expect(fixed.card(S.card(2))?.templateID == S.template(1))
        #expect(issues.count == 1)
    }

    @Test func instructionOfUnknownAgentIsRemoved() {
        let lost = QueuedInstruction(id: S.instruction(1), agentID: S.agent(9), text: "Perdue", queueRank: "i", createdAt: S.t0)
        let kept = QueuedInstruction(id: S.instruction(2), agentID: S.agent(1), text: "Gardée", queueRank: "i", createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([], instructions: [lost, kept]))
        #expect(fixed.instructions.map(\.id) == [S.instruction(2)])
        #expect(issues.count == 1)
    }

    @Test func duplicateRanksAreRenumberedInOrder() {
        let a = TaskCard(id: S.card(1), title: "A", projectID: nil, rank: "m", createdAt: S.at(1))
        let b = TaskCard(id: S.card(2), title: "B", projectID: nil, rank: "m", createdAt: S.at(2))
        let c = TaskCard(id: S.card(3), title: "C", projectID: nil, rank: "c", createdAt: S.at(3))
        let d = TaskCard(id: S.card(4), title: "D", projectID: nil, rank: "x", createdAt: S.at(4))
        let review1 = TaskCard(id: S.card(5), title: "R1", projectID: nil, column: .review, rank: "m", createdAt: S.at(5))
        let review2 = TaskCard(id: S.card(6), title: "R2", projectID: nil, column: .review, rank: "n", createdAt: S.at(6))
        let (fixed, issues) = Self.validate(Self.board([a, b, c, d, review1, review2]))
        let todo = fixed.cards(in: .todo)
        #expect(todo.map(\.title) == ["C", "A", "B", "D"])
        #expect(todo.map(\.rank) == RankKey.spread(4))
        #expect(fixed.cards(in: .review).map(\.rank) == ["m", "n"])
        #expect(issues.count == 1)
    }

    @Test func invalidRanksAreRenumbered() {
        let a = TaskCard(id: S.card(1), title: "A", projectID: nil, rank: "", createdAt: S.at(1))
        let b = TaskCard(id: S.card(2), title: "B", projectID: nil, rank: "k0", createdAt: S.at(2))
        let c = TaskCard(id: S.card(3), title: "C", projectID: nil, rank: "r", createdAt: S.at(3))
        let (fixed, issues) = Self.validate(Self.board([a, b, c]))
        let todo = fixed.cards(in: .todo)
        #expect(todo.map(\.title) == ["A", "B", "C"])
        #expect(todo.map(\.rank) == RankKey.spread(3))
        #expect(issues.count == 1)
    }

    @Test func tagsAreNormalized() {
        #expect(TaskBoardValidator.normalizedTags([" bug ", "#auth", "", "  ", "Bug", "#", "mon tag", "##x", "AUTH", "# ui"])
            == ["bug", "auth", "montag", "x", "ui"])
        let card = TaskCard(id: S.card(1), title: "Tags", projectID: nil, rank: "i", tags: ["#API", " api", "doc"],
                            createdAt: S.t0)
        let clean = TaskCard(id: S.card(2), title: "Propres", projectID: nil, rank: "r", tags: ["api"], createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([card, clean]))
        #expect(fixed.card(S.card(1))?.tags == ["API", "doc"])
        #expect(fixed.card(S.card(2))?.tags == ["api"])
        #expect(issues.count == 1)
    }

    @Test func blankTitleBecomesSansTitre() {
        let blank = TaskCard(id: S.card(1), title: "  \n\t ", projectID: nil, rank: "i", createdAt: S.t0)
        let padded = TaskCard(id: S.card(2), title: "  Gardé tel quel ", projectID: nil, rank: "r", createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([blank, padded]))
        #expect(fixed.card(S.card(1))?.title == "Sans titre")
        #expect(fixed.card(S.card(2))?.title == "  Gardé tel quel ")
        #expect(issues.count == 1)
    }

    @Test func duplicateIDsKeepTheFirst() {
        let card = TaskCard(id: S.card(1), title: "Premier", projectID: nil, rank: "i", createdAt: S.t0)
        var copy = card
        copy.title = "Copie"
        copy.rank = "r"
        let instruction = QueuedInstruction(id: S.instruction(1), agentID: S.agent(1), text: "Une", queueRank: "i", createdAt: S.t0)
        var instructionCopy = instruction
        instructionCopy.text = "Copie"
        var board = Self.board([card, copy], instructions: [instruction, instructionCopy])
        var templateCopy = board.templates[0]
        templateCopy.name = "Copie"
        board.templates.append(templateCopy)
        let (fixed, issues) = Self.validate(board)
        #expect(fixed.cards.map(\.title) == ["Premier"])
        #expect(fixed.instructions.map(\.text) == ["Une"])
        #expect(fixed.templates.map(\.name) == ["Corriger un bug", "Ajouter une fonctionnalité", "Écrire la documentation"])
        #expect(issues.count == 3)
    }

    @Test func duplicateOrInvalidQueueRanksAreRenumbered() throws {
        let first = TaskCard(id: S.card(1), title: "Un", projectID: nil, rank: "c", assignee: S.agent(1),
                             queueRank: "k", createdAt: S.at(1))
        let second = TaskCard(id: S.card(2), title: "Deux", projectID: nil, rank: "m", assignee: S.agent(1),
                              queueRank: "k", createdAt: S.at(2))
        let empty = TaskCard(id: S.card(3), title: "Vide", projectID: nil, rank: "t", assignee: S.agent(1),
                             queueRank: "", createdAt: S.at(3))
        let trailingZero = TaskCard(id: S.card(4), title: "Zéro final", projectID: nil, rank: "x", assignee: S.agent(2),
                                    queueRank: "k0", createdAt: S.at(4))
        let (fixed, issues) = Self.validate(Self.board([first, second, empty, trailingZero]))
        // Renumbered in their current order ("" < "k", then createdAt).
        let spread = RankKey.spread(3)
        #expect(fixed.card(S.card(3))?.queueRank == spread[0])
        #expect(fixed.card(S.card(1))?.queueRank == spread[1])
        #expect(fixed.card(S.card(2))?.queueRank == spread[2])
        #expect(fixed.card(S.card(4))?.queueRank == RankKey.spread(1)[0])
        // Column ranks are untouched.
        #expect(fixed.cards(in: .todo).map(\.rank) == ["c", "m", "t", "x"])
        #expect(issues.count == 2)
    }

    @Test func queueKeysAscendThroughInstructionsThenCards() throws {
        let olderInstruction = QueuedInstruction(id: S.instruction(1), agentID: S.agent(1), text: "Première",
                                                 queueRank: "m", createdAt: S.at(1))
        let newerInstruction = QueuedInstruction(id: S.instruction(2), agentID: S.agent(1), text: "Seconde",
                                                 queueRank: "m", createdAt: S.at(2))
        // Below the instructions' keys, though the queue shows it after them.
        let card = TaskCard(id: S.card(1), title: "Carte", projectID: nil, rank: "i", assignee: S.agent(1),
                            queueRank: "c", createdAt: S.at(3))
        // Agent 2's queue is already in order: untouched.
        let otherInstruction = QueuedInstruction(id: S.instruction(3), agentID: S.agent(2), text: "Autre",
                                                 queueRank: "a", createdAt: S.at(4))
        let otherCard = TaskCard(id: S.card(2), title: "Autre carte", projectID: nil, rank: "r", assignee: S.agent(2),
                                 queueRank: "k", createdAt: S.at(5))
        let (fixed, issues) = Self.validate(Self.board([card, otherCard],
                                                       instructions: [newerInstruction, olderInstruction, otherInstruction]))
        let spread = RankKey.spread(3)
        #expect(fixed.instructions.first { $0.id == S.instruction(1) }?.queueRank == spread[0])
        #expect(fixed.instructions.first { $0.id == S.instruction(2) }?.queueRank == spread[1])
        #expect(fixed.card(S.card(1))?.queueRank == spread[2])
        #expect(fixed.instructions.first { $0.id == S.instruction(3) }?.queueRank == "a")
        #expect(fixed.card(S.card(2))?.queueRank == "k")
        #expect(issues.count == 1)
    }

    @Test func missingQueueRankGoesAfterRepairedRanks() throws {
        // "é" is not a key: appended after it, the card would sort before it ("zi" < "é").
        let ranked = TaskCard(id: S.card(1), title: "Rangée", projectID: nil, rank: "c", assignee: S.agent(1),
                              queueRank: "c", createdAt: S.at(1))
        let invalid = TaskCard(id: S.card(2), title: "Invalide", projectID: nil, rank: "m", assignee: S.agent(1),
                               queueRank: "é", createdAt: S.at(2))
        let missing = TaskCard(id: S.card(3), title: "Sans rang", projectID: nil, rank: "t", assignee: S.agent(1),
                               createdAt: S.at(3))
        let (fixed, issues) = Self.validate(Self.board([ranked, invalid, missing]))
        let order = fixed.cards.filter { $0.assignee == S.agent(1) }
            .sorted { ($0.queueRank ?? "") < ($1.queueRank ?? "") }
            .map(\.id)
        #expect(order == [S.card(1), S.card(2), S.card(3)])
        #expect(fixed.cards.allSatisfy { $0.queueRank.map(RankKey.isValid) ?? false })
        #expect(issues.count == 2)
    }

    @Test func cardSentBackToTodoGoesLastEvenAfterInvalidRanks() throws {
        // "~" is not a key: a rank computed after it ("zi") would sort before it once the column is renumbered.
        let invalid = TaskCard(id: S.card(1), title: "Tilde", projectID: nil, rank: "~", createdAt: S.at(1))
        let valid = TaskCard(id: S.card(2), title: "Valide", projectID: nil, rank: "c", createdAt: S.at(2))
        let orphan = TaskCard(id: S.card(3), title: "Orpheline", projectID: nil, column: .inProgress, rank: "i",
                              assignee: S.agent(9), createdAt: S.at(3))
        let (fixed, issues) = Self.validate(Self.board([invalid, valid, orphan]))
        let todo = fixed.cards(in: .todo)
        #expect(todo.map(\.id) == [S.card(2), S.card(1), S.card(3)])
        #expect(todo.allSatisfy { RankKey.isValid($0.rank) })
        #expect(issues.count == 2)
    }

    @Test func inProgressCardWithoutAgentGoesBackToTodo() throws {
        let waiting = TaskCard(id: S.card(1), title: "En attente", projectID: nil, rank: "i", createdAt: S.at(1))
        let adrift = TaskCard(id: S.card(2), title: "Sans agent", projectID: nil, column: .inProgress, rank: "i",
                              queueRank: "k", delivery: DeliveryInfo(promptID: "p-7", sentAt: S.at(2), confirmedAt: S.at(3)),
                              flags: [.interrupted], createdAt: S.at(2), updatedAt: S.at(4))
        // Waiting for review without an agent: still validable, left alone.
        let reviewing = TaskCard(id: S.card(3), title: "À relire", projectID: nil, column: .review, rank: "i",
                                 delivery: DeliveryInfo(promptID: "p-8", sentAt: S.at(5), confirmedAt: S.at(6)),
                                 createdAt: S.at(5))
        let (fixed, issues) = Self.validate(Self.board([waiting, adrift, reviewing]))
        #expect(fixed.cards(in: .todo).map(\.id) == [S.card(1), S.card(2)])
        let card = try #require(fixed.card(S.card(2)))
        #expect(card.assignee == nil && card.queueRank == nil)
        #expect(card.flags.isEmpty && card.delivery == nil)
        #expect(card.updatedAt == S.at(4))
        let event = try #require(card.history.last)
        #expect(event.kind == .putBack && event.from == .inProgress && event.to == .todo && event.at == S.at(4))
        #expect(event.note?.contains("p-7") == true)
        #expect(fixed.card(S.card(3)) == reviewing)
        #expect(issues.count == 1)
    }

    @Test func pendingDeliveryIsClearedOutsideTheQueue() throws {
        let pending = DeliveryInfo(sessionID: "s", sentAt: S.at(1))
        let confirmed = DeliveryInfo(promptID: "p", sentAt: S.at(1), confirmedAt: S.at(2), turnEndedAt: S.at(3))
        let doneNeverConfirmed = TaskCard(id: S.card(1), title: "Fait sans envoi", projectID: nil, column: .done, rank: "i",
                                          delivery: pending, createdAt: S.at(1))
        let doneDelivered = TaskCard(id: S.card(2), title: "Fait livré", projectID: nil, column: .done, rank: "r",
                                     delivery: confirmed, validatedOnce: true, createdAt: S.at(2))
        let unassigned = TaskCard(id: S.card(3), title: "Libre", projectID: nil, rank: "i", delivery: pending,
                                  createdAt: S.at(3))
        let queued = TaskCard(id: S.card(4), title: "En tête", projectID: nil, rank: "r", assignee: S.agent(1),
                              queueRank: "k", delivery: pending, createdAt: S.at(4))
        let (fixed, issues) = Self.validate(Self.board([doneNeverConfirmed, doneDelivered, unassigned, queued]))
        #expect(fixed.card(S.card(1))?.delivery == nil)
        #expect(fixed.card(S.card(2))?.delivery == confirmed)
        #expect(fixed.card(S.card(3))?.delivery == nil)
        #expect(fixed.card(S.card(4))?.delivery == pending)
        #expect(fixed.cards.allSatisfy { $0.column != .done || $0.delivery?.isPending != true })
        #expect(issues.count == 2)
    }

    @Test func instructionOfUnknownCardIsRemoved() {
        let card = TaskCard(id: S.card(1), title: "Là", projectID: nil, column: .inProgress, rank: "i", assignee: S.agent(1),
                            flags: [.interrupted], createdAt: S.t0)
        let lost = QueuedInstruction(id: S.instruction(1), agentID: S.agent(1), text: "Continue la tâche : Disparue",
                                     cardID: S.card(9), queueRank: "c", createdAt: S.t0)
        let linked = QueuedInstruction(id: S.instruction(2), agentID: S.agent(1), text: "Continue la tâche : Là",
                                       cardID: S.card(1), queueRank: "i", createdAt: S.t0)
        let adHoc = QueuedInstruction(id: S.instruction(3), agentID: S.agent(1), text: "Lance les tests",
                                      queueRank: "r", createdAt: S.t0)
        let (fixed, issues) = Self.validate(Self.board([card], instructions: [lost, linked, adHoc]))
        #expect(fixed.instructions.map(\.id) == [S.instruction(2), S.instruction(3)])
        #expect(issues.count == 1)
    }

    @Test func invisibleTagsAreDroppedAndCaseIsFolded() {
        #expect(TaskBoardValidator.normalizedTags(["\u{200B}", "a\u{200B}b", "\u{202E}x", "\u{FEFF}#", "\u{00AD}",
                                                   "ß", "SS", "ς", "Σ", "\u{1F469}\u{200D}\u{1F4BB}"])
            == ["ab", "x", "ß", "ς", "\u{1F469}\u{200D}\u{1F4BB}"])
        #expect(TaskBoardValidator.tagKey("Straße") == TaskBoardValidator.tagKey("STRASSE"))
    }

    @Test func repairIsIdempotentAndNeverLosesACard() {
        let cards = [
            TaskCard(id: S.card(1), title: " ", projectID: S.project(9), rank: "m", tags: ["#a", "A"],
                     assignee: S.agent(9), queueRank: "k", templateID: S.template(9), createdAt: S.at(1)),
            TaskCard(id: S.card(2), title: "B", projectID: S.project(1), column: .inProgress, rank: "m",
                     assignee: S.agent(9), flags: [.sessionLost], createdAt: S.at(2)),
            TaskCard(id: S.card(3), title: "C", projectID: nil, rank: "m", assignee: S.agent(1), createdAt: S.at(3)),
            TaskCard(id: S.card(4), title: "D", projectID: nil, column: .inProgress, rank: "i", assignee: S.agent(1),
                     queueRank: "z", createdAt: S.at(4)),
            TaskCard(id: S.card(5), title: "E", projectID: nil, column: .inProgress, rank: "i", assignee: S.agent(1),
                     createdAt: S.at(5)),
            TaskCard(id: S.card(6), title: "F", projectID: nil, rank: "~", assignee: S.agent(1), queueRank: "k0",
                     createdAt: S.at(6)),
            TaskCard(id: S.card(7), title: "G", projectID: nil, column: .inProgress, rank: "é", queueRank: "k",
                     createdAt: S.at(7)),
            TaskCard(id: S.card(8), title: "H", projectID: nil, column: .done, rank: "i",
                     delivery: DeliveryInfo(sentAt: S.at(8)), createdAt: S.at(8)),
        ]
        let instructions = [
            QueuedInstruction(id: S.instruction(1), agentID: S.agent(1), text: "I", queueRank: "k", createdAt: S.at(1)),
            QueuedInstruction(id: S.instruction(2), agentID: S.agent(1), text: "J", cardID: S.card(9), queueRank: "k",
                              createdAt: S.at(2)),
            QueuedInstruction(id: S.instruction(3), agentID: S.agent(1), text: "K", cardID: S.card(4), queueRank: "k",
                              createdAt: S.at(3)),
        ]
        let (fixed, issues) = Self.validate(Self.board(cards, instructions: instructions))
        #expect(!issues.isEmpty)
        #expect(Set(fixed.cards.map(\.id)) == Set(cards.map(\.id)))
        for card in fixed.cards {
            #expect((card.queueRank != nil) == (card.column == .todo && card.assignee != nil))
            #expect(card.assignee.map(Self.agents.contains) ?? true)
            #expect(card.projectID.map(Self.projects.contains) ?? true)
            #expect(card.column != .inProgress || card.assignee != nil)
            #expect(card.column != .done || card.delivery?.isPending != true)
            #expect(RankKey.isValid(card.rank))
        }
        for column in Column.allCases {
            let ranks = fixed.cards(in: column).map(\.rank)
            #expect(zip(ranks, ranks.dropFirst()).allSatisfy { $0 < $1 })
        }
        let cardIDs = Set(fixed.cards.map(\.id))
        #expect(fixed.instructions.allSatisfy { $0.cardID.map(cardIDs.contains) ?? true })
        let queue = fixed.instructions.filter { $0.agentID == S.agent(1) }.map(\.queueRank).sorted()
            + fixed.cards.filter { $0.column == .todo && $0.assignee == S.agent(1) }.compactMap(\.queueRank).sorted()
        #expect(queue.allSatisfy(RankKey.isValid))
        #expect(zip(queue, queue.dropFirst()).allSatisfy { $0 < $1 })
        let (again, noIssues) = Self.validate(fixed)
        #expect(again == fixed)
        #expect(noIssues.isEmpty)
    }
}
