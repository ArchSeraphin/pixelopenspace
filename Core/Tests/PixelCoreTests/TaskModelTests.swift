import Foundation
import Testing
@testable import PixelCore

/// Deterministic ids, dates and boards shared by the task model, codec and validator tests.
enum TaskBoardSamples {
    static let t0 = at(0)

    /// `t0 + offset` seconds, built from whole milliseconds exactly as a decoded file gives it back.
    static func at(_ offset: Double) -> Date {
        let millis = 1_790_000_000_123 + Int64((offset * 1000).rounded())
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// "00000000-0000-0000-0000-00000000000N".
    static func uuid(_ n: Int) -> UUID {
        let digits = String(n)
        return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
    }

    static func card(_ n: Int) -> TaskCardID { TaskCardID(uuid(n)) }
    static func agent(_ n: Int) -> AgentID { AgentID(uuid(100 + n)) }
    static func project(_ n: Int) -> ProjectID { ProjectID(uuid(200 + n)) }
    static func template(_ n: Int) -> PromptTemplateID { PromptTemplateID(uuid(300 + n)) }
    static func instruction(_ n: Int) -> InstructionID { InstructionID(uuid(400 + n)) }

    static var templateIDs: [PromptTemplateID] { [template(1), template(2), template(3)] }

    /// A consistent board touching every field: agent 1 (project 1) works on card 2 and has card 1 and an
    /// instruction in its queue; card 3 waits for review, card 4 is done, card 5 is unassigned.
    static func board() -> TaskBoardState {
        var board = TaskBoardState.initial(templateIDs: templateIDs)
        let delivered = DeliveryInfo(sessionID: "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d", promptID: "p-2",
                                     sentAt: at(60), confirmedAt: at(61.5))
        board.cards = [
            TaskCard(id: card(1), title: "Pagination /users", details: "20 par page, paramètres page et per_page.",
                     projectID: project(1), rank: "i", priority: .high, tags: ["api", "backend"],
                     assignee: agent(1), queueRank: "k", templateID: template(2),
                     history: [CardEvent(at: at(1), kind: .created, to: .todo),
                               CardEvent(at: at(2), kind: .assigned, agentID: agent(1))],
                     createdAt: at(1), updatedAt: at(2)),
            TaskCard(id: card(2), title: "Refonte du header", projectID: project(1), column: .inProgress, rank: "i",
                     assignee: agent(1), delivery: delivered, flags: [.backgroundRunning, .interrupted],
                     createdAt: at(3), updatedAt: at(61.5)),
            TaskCard(id: card(3), title: "Doc de l'API", projectID: project(1), column: .review, rank: "i",
                     priority: .low, tags: ["doc"], assignee: agent(1),
                     delivery: DeliveryInfo(promptID: "p-3", sentAt: at(10), confirmedAt: at(11), turnEndedAt: at(50)),
                     createdAt: at(4), updatedAt: at(50)),
            TaskCard(id: card(4), title: "Lint CI", projectID: project(2), column: .done, rank: "i",
                     assignee: agent(2), delivery: DeliveryInfo(promptID: "p-4", sentAt: at(5), confirmedAt: at(6), turnEndedAt: at(7)),
                     history: [CardEvent(at: at(8), kind: .validated, from: .review, to: .done, note: "Validé")],
                     validatedOnce: true, createdAt: at(5), updatedAt: at(8)),
            TaskCard(id: card(5), title: "Rotation des logs", projectID: nil, rank: "r", createdAt: at(9)),
        ]
        board.instructions = [
            QueuedInstruction(id: instruction(1), agentID: agent(1), text: "Continue la tâche : Refonte du header",
                              cardID: card(2), queueRank: "a", createdAt: at(62)),
        ]
        return board
    }
}

@Suite struct TaskModelTests {
    typealias S = TaskBoardSamples

    @Test func columnTitles() {
        #expect(Column.allCases == [.todo, .inProgress, .review, .done])
        #expect(Column.allCases.map(\.title) == ["À faire", "En cours", "À valider", "Fait"])
    }

    @Test func priorityTitlesAndOrder() {
        #expect(Priority.allCases.map(\.title) == ["basse", "normale", "haute"])
        #expect(Priority.low < .normal && Priority.normal < .high)
        #expect(Priority.allCases.max() == .high)
    }

    @Test func cardsInColumnSortByRankThenCreationThenID() {
        var board = TaskBoardState()
        board.cards = [
            TaskCard(id: S.card(1), title: "c", projectID: nil, rank: "m", createdAt: S.at(1)),
            TaskCard(id: S.card(2), title: "a", projectID: nil, rank: "c", createdAt: S.at(5)),
            TaskCard(id: S.card(3), title: "review", projectID: nil, column: .review, rank: "a", createdAt: S.at(0)),
            TaskCard(id: S.card(5), title: "e", projectID: nil, rank: "x", createdAt: S.at(2)),
            TaskCard(id: S.card(4), title: "d", projectID: nil, rank: "x", createdAt: S.at(2)),
            TaskCard(id: S.card(6), title: "b", projectID: nil, rank: "m", createdAt: S.at(0)),
        ]
        #expect(board.cards(in: .todo).map(\.title) == ["a", "b", "c", "d", "e"])
        #expect(board.cards(in: .review).map(\.title) == ["review"])
        #expect(board.cards(in: .done).isEmpty)
    }

    @Test func initialBoardHasTheThreeStarterTemplates() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        #expect(board.schemaVersion == TaskBoardState.currentSchemaVersion)
        #expect(board.cards.isEmpty && board.instructions.isEmpty)
        #expect(board.templates.map(\.name) == ["Corriger un bug", "Ajouter une fonctionnalité", "Écrire la documentation"])
        #expect(board.templates.map(\.id) == S.templateIDs)
        #expect(board.templates.allSatisfy { $0.body.contains("{titre}") && $0.body.contains("{description}") })
        #expect(StarterTemplates.make(ids: S.templateIDs) == board.templates)
    }

    @Test func lookups() {
        let board = S.board()
        #expect(board.card(S.card(3))?.title == "Doc de l'API")
        #expect(board.card(S.card(99)) == nil)
        #expect(board.template(S.template(2))?.name == "Ajouter une fonctionnalité")
        #expect(board.template(S.template(99)) == nil)
    }

    @Test func cardDefaults() {
        let card = TaskCard(title: "Nouveau", projectID: nil, rank: "i", createdAt: S.t0)
        #expect(card.details == "" && card.tags.isEmpty && card.flags.isEmpty && card.history.isEmpty)
        #expect(card.column == .todo && card.priority == .normal)
        #expect(card.assignee == nil && card.queueRank == nil && card.templateID == nil && card.delivery == nil)
        #expect(!card.validatedOnce)
        #expect(card.updatedAt == S.t0)
        let later = TaskCard(title: "Plus tard", projectID: nil, rank: "i", createdAt: S.t0, updatedAt: S.at(5))
        #expect(later.updatedAt == S.at(5))
    }

    @Test func deliveryIsPendingUntilConfirmed() {
        var delivery = DeliveryInfo(sessionID: "s", sentAt: S.t0)
        #expect(delivery.isPending)
        delivery.confirmedAt = S.at(1)
        #expect(!delivery.isPending)
    }
}
