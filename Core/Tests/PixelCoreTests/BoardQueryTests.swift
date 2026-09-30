import Foundation
import Testing
@testable import PixelCore

@Suite struct FuzzyMatcherTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatcher.matches("", "Pagination /users"))
        #expect(FuzzyMatcher.matches("", ""))
        #expect(FuzzyMatcher.matches("  \t\n ", "Pagination /users"))
        #expect(FuzzyMatcher.matches("  ", ""))
    }

    @Test func emptyCandidateMatchesOnlyAnEmptyQuery() {
        #expect(!FuzzyMatcher.matches("a", ""))
        #expect(!FuzzyMatcher.matches("a", "   "))
    }

    @Test func queryWordIsASubsequenceOfACandidateWord() {
        #expect(FuzzyMatcher.matches("pagi", "Pagination /users"))
        #expect(FuzzyMatcher.matches("pgn", "Pagination /users"))
        #expect(FuzzyMatcher.matches("users", "Pagination /users"))
        #expect(FuzzyMatcher.matches("/usr", "Pagination /users"))
        #expect(FuzzyMatcher.matches("pagination", "Pagination"))
        // Letters in the wrong order, or one too many.
        #expect(!FuzzyMatcher.matches("gap", "Pagination"))
        #expect(!FuzzyMatcher.matches("paginations", "Pagination"))
        #expect(!FuzzyMatcher.matches("login", "Pagination /users"))
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(FuzzyMatcher.matches("deploiement", "Déploiement du site"))
        #expect(FuzzyMatcher.matches("DÉPLOIEMENT", "deploiement"))
        #expect(FuzzyMatcher.matches("déploiement", "DEPLOIEMENT"))
        #expect(FuzzyMatcher.matches("ecrire", "Écrire la documentation"))
        #expect(FuzzyMatcher.matches("noel", "Noël"))
        #expect(FuzzyMatcher.matches("ca", "ÇA"))
        #expect(FuzzyMatcher.matches("PAGI", "pagination"))
    }

    @Test func frenchLigaturesMatchTheirLetters() {
        #expect(FuzzyMatcher.matches("oeuvre", "Chef-d'œuvre"))
        #expect(FuzzyMatcher.matches("coeur", "Cœur du sujet"))
        #expect(FuzzyMatcher.matches("cœur", "COEUR"))
        #expect(FuzzyMatcher.matches("aeg", "Æg"))
    }

    @Test func everyQueryWordMustMatch() {
        #expect(FuzzyMatcher.matches("corr login", "Corriger le login"))
        #expect(FuzzyMatcher.matches("login corr", "Corriger le login"))
        #expect(FuzzyMatcher.matches("le le", "Corriger le login"))
        #expect(!FuzzyMatcher.matches("corr pagi", "Corriger le login"))
    }

    @Test func aQueryWordDoesNotSpanTwoCandidateWords() {
        // Letters picked across words would match almost any short word in a long description.
        #expect(!FuzzyMatcher.matches("lelogin", "Corriger le login"))
        // "d" of "Dans", "o" of "son", "c" of "code": no single word has them in this order.
        #expect(!FuzzyMatcher.matches("doc", "Dans son code, le jeton expire trop tôt"))
        #expect(FuzzyMatcher.matches("doc", "Dans son code, voir la doc"))
    }

    @Test func anyWhitespaceSeparatesWords() {
        #expect(FuzzyMatcher.matches("corr\tlogin", "Corriger\nle\u{00A0}login"))
        #expect(!FuzzyMatcher.matches("lelogin", "le\u{00A0}login"))
    }

    @Test func invisibleCharactersAreIgnored() {
        #expect(FuzzyMatcher.matches("pagi\u{200B}nation", "Pagination"))
        #expect(FuzzyMatcher.matches("pagination", "Pagi\u{200B}na\u{202E}tion"))
        #expect(FuzzyMatcher.matches("\u{200B}", "Pagination"))
    }
}

@Suite struct BoardQueryTests {
    typealias S = TaskBoardSamples

    /// Projects 1 ("API") and 2 ("Site"), agents 1 (Nova) and 2 (Pixou).
    /// Agent 1 works on card 8, has cards 3 then 1 in its queue (in that order, whatever the columns say) after
    /// instructions 2 then 1; agent 2 works on card 4 and has instruction 3 in its queue.
    static func board() -> TaskBoardState {
        var board = TaskBoardState.initial(templateIDs: S.templateIDs)
        board.cards = [
            TaskCard(id: S.card(1), title: "Pagination /users", details: "20 par page.", projectID: S.project(1),
                     rank: "i", priority: .high, tags: ["api", "backend"], assignee: S.agent(1), queueRank: "m",
                     createdAt: S.at(1)),
            TaskCard(id: S.card(2), title: "Déploiement du site", details: "Mettre en ligne la version 2.",
                     projectID: S.project(2), rank: "c", tags: ["infra"], createdAt: S.at(2)),
            TaskCard(id: S.card(3), title: "Corriger le login", details: "Le jeton OAuth expire trop tôt.",
                     projectID: S.project(1), rank: "r", tags: ["bug", "auth"], assignee: S.agent(1), queueRank: "d",
                     createdAt: S.at(3)),
            TaskCard(id: S.card(4), title: "Refonte du header", projectID: S.project(2), column: .inProgress, rank: "i",
                     tags: ["ui"], assignee: S.agent(2),
                     delivery: DeliveryInfo(promptID: "p-4", sentAt: S.at(4), confirmedAt: S.at(4.5)),
                     createdAt: S.at(4)),
            TaskCard(id: S.card(5), title: "Doc de l'API", projectID: S.project(1), column: .review, rank: "i",
                     tags: ["doc", "API"], assignee: S.agent(1), createdAt: S.at(5)),
            TaskCard(id: S.card(6), title: "Lint CI", projectID: nil, column: .done, rank: "i", tags: ["ci"],
                     assignee: S.agent(1), validatedOnce: true, createdAt: S.at(6)),
            TaskCard(id: S.card(7), title: "Rotation des logs", projectID: nil, rank: "x", createdAt: S.at(7)),
            TaskCard(id: S.card(8), title: "Cache Redis", projectID: S.project(1), column: .inProgress, rank: "c",
                     assignee: S.agent(1),
                     delivery: DeliveryInfo(promptID: "p-8", sentAt: S.at(8), confirmedAt: S.at(8.5)),
                     createdAt: S.at(8)),
        ]
        board.instructions = [
            QueuedInstruction(id: S.instruction(1), agentID: S.agent(1), text: "Continue la tâche : Cache Redis",
                              cardID: S.card(8), queueRank: "k", createdAt: S.at(20)),
            QueuedInstruction(id: S.instruction(3), agentID: S.agent(2), text: "Ajoute le menu mobile",
                              queueRank: "a", createdAt: S.at(22)),
            QueuedInstruction(id: S.instruction(2), agentID: S.agent(1), text: "Précision : garder 20 par page",
                              queueRank: "b", createdAt: S.at(21)),
        ]
        return board
    }

    /// Card ids per column, in column order.
    static func ids(_ result: [Column: [TaskCard]]) -> [Column: [TaskCardID]] {
        result.mapValues { $0.map(\.id) }
    }

    static func filtered(_ filter: BoardFilter, _ board: TaskBoardState = board()) -> [Column: [TaskCardID]] {
        ids(BoardQuery.filtered(board, filter))
    }

    // MARK: - filtered

    @Test func everyColumnIsPresentEvenEmpty() {
        let empty = Self.filtered(BoardFilter(), TaskBoardState())
        #expect(empty == [.todo: [], .inProgress: [], .review: [], .done: []])

        let nothing = Self.filtered(BoardFilter(text: "introuvable"))
        #expect(nothing == [.todo: [], .inProgress: [], .review: [], .done: []])
    }

    @Test func emptyFilterKeepsEveryCardOrderedByRank() {
        let result = Self.filtered(BoardFilter())
        #expect(result[.todo] == [S.card(2), S.card(1), S.card(3), S.card(7)])
        #expect(result[.inProgress] == [S.card(8), S.card(4)])
        #expect(result[.review] == [S.card(5)])
        #expect(result[.done] == [S.card(6)])
        #expect(result.flat.count == Self.board().cards.count)
    }

    @Test func orderFollowsRankThenCreation() {
        var board = TaskBoardState()
        board.cards = [
            TaskCard(id: S.card(1), title: "b", projectID: nil, rank: "m", createdAt: S.at(2)),
            TaskCard(id: S.card(2), title: "c", projectID: nil, rank: "z", createdAt: S.at(0)),
            TaskCard(id: S.card(3), title: "a", projectID: nil, rank: "m", createdAt: S.at(1)),
        ]
        #expect(Self.filtered(BoardFilter(), board)[.todo] == [S.card(3), S.card(1), S.card(2)])
    }

    @Test func filterByProject() {
        let result = Self.filtered(BoardFilter(projectID: S.project(1)))
        #expect(result[.todo] == [S.card(1), S.card(3)])
        #expect(result[.inProgress] == [S.card(8)])
        #expect(result[.review] == [S.card(5)])
        #expect(result[.done] == [])

        // A card without a project only shows with every project.
        #expect(Self.filtered(BoardFilter(projectID: S.project(2)))[.todo] == [S.card(2)])
        #expect(Self.filtered(BoardFilter(projectID: S.project(9))).flat.isEmpty)
    }

    @Test func filterByColumns() {
        let result = Self.filtered(BoardFilter(columns: [.todo, .review]))
        #expect(result[.todo] == [S.card(2), S.card(1), S.card(3), S.card(7)])
        #expect(result[.inProgress] == [])
        #expect(result[.review] == [S.card(5)])
        #expect(result[.done] == [])
        #expect(Set(result.keys) == Set(Column.allCases))
    }

    @Test func filterByTagsRequiresAllOfThemIgnoringCase() {
        let api = Self.filtered(BoardFilter(tags: ["api"]))
        #expect(api[.todo] == [S.card(1)])
        #expect(api[.review] == [S.card(5)])
        #expect(api[.inProgress] == [] && api[.done] == [])

        #expect(Self.filtered(BoardFilter(tags: ["api", "backend"])).flat == [S.card(1)])
        #expect(Self.filtered(BoardFilter(tags: ["#API", "Backend"])).flat == [S.card(1)])
        #expect(Self.filtered(BoardFilter(tags: ["api", "bug"])).flat.isEmpty)
        #expect(Self.filtered(BoardFilter(tags: ["bu"])).flat.isEmpty)
    }

    @Test func blankTagsAreIgnored() {
        #expect(Self.filtered(BoardFilter(tags: ["", " ", "#"])) == Self.filtered(BoardFilter()))
        #expect(Self.filtered(BoardFilter(tags: ["", "#bug"])).flat == [S.card(3)])
    }

    @Test func filterByTextIsFuzzyAndIgnoresAccents() {
        #expect(Self.filtered(BoardFilter(text: "pagi")).flat == [S.card(1)])
        #expect(Self.filtered(BoardFilter(text: "Pagination")).flat == [S.card(1)])
        #expect(Self.filtered(BoardFilter(text: "deploiement")).flat == [S.card(2)])
        #expect(Self.filtered(BoardFilter(text: "DÉPLOIEMENT")).flat == [S.card(2)])
        #expect(Self.filtered(BoardFilter(text: "corr login")).flat == [S.card(3)])
        #expect(Self.filtered(BoardFilter(text: "corr pagi")).flat.isEmpty)
    }

    @Test func textSearchesDetailsAndTags() {
        // Details.
        #expect(Self.filtered(BoardFilter(text: "oauth")).flat == [S.card(3)])
        #expect(Self.filtered(BoardFilter(text: "version")).flat == [S.card(2)])
        // Tags, with or without "#".
        #expect(Self.filtered(BoardFilter(text: "backend")).flat == [S.card(1)])
        #expect(Self.filtered(BoardFilter(text: "#infra")).flat == [S.card(2)])
        // Title and tag together.
        #expect(Self.filtered(BoardFilter(text: "login #bug")).flat == [S.card(3)])
    }

    @Test func filterByAssignee() {
        let nova = Self.filtered(BoardFilter(assignee: S.agent(1)))
        #expect(nova[.todo] == [S.card(1), S.card(3)])
        #expect(nova[.inProgress] == [S.card(8)])
        #expect(nova[.review] == [S.card(5)])
        #expect(nova[.done] == [S.card(6)])
        let pixou = Self.filtered(BoardFilter(assignee: S.agent(2)))
        #expect(pixou.flat == [S.card(4)])
    }

    @Test func criteriaCombine() {
        #expect(Self.filtered(BoardFilter(projectID: S.project(1), tags: ["bug"], text: "jeton")).flat
                    == [S.card(3)])
        #expect(Self.filtered(BoardFilter(projectID: S.project(1), text: "deploiement")).flat.isEmpty)
        #expect(Self.filtered(BoardFilter(columns: [.todo], text: "users", assignee: S.agent(1))).flat
                    == [S.card(1)])
        #expect(Self.filtered(BoardFilter(columns: [.inProgress], assignee: S.agent(1))).flat
                    == [S.card(8)])
        #expect(Self.filtered(BoardFilter(projectID: S.project(2), tags: ["api"])).flat.isEmpty)
    }

    @Test func filterIsEmptyOnlyWhenItKeepsEverything() {
        #expect(BoardFilter().isEmpty)
        #expect(BoardFilter(tags: ["", "#"], text: " \t\n").isEmpty)
        #expect(!BoardFilter(projectID: S.project(1)).isEmpty)
        #expect(!BoardFilter(columns: [.done]).isEmpty)
        #expect(!BoardFilter(tags: ["bug"]).isEmpty)
        #expect(!BoardFilter(text: "login").isEmpty)
        #expect(!BoardFilter(assignee: S.agent(1)).isEmpty)
    }

    // MARK: - Queues

    @Test func queueListsInstructionsThenCardsEachByQueueRank() {
        let board = Self.board()
        #expect(BoardQuery.queue(of: S.agent(1), in: board) == [
            .instruction(S.instruction(2)), .instruction(S.instruction(1)), .card(S.card(3)), .card(S.card(1)),
        ])
        #expect(BoardQuery.queue(of: S.agent(2), in: board) == [.instruction(S.instruction(3))])
        #expect(BoardQuery.queue(of: S.agent(9), in: board).isEmpty)
    }

    @Test func queueHoldsOnlyQueuedTodoCards() {
        var board = Self.board()
        board.instructions = []
        // Not queued: in progress, waiting for review, done, or a todo card without a queue rank.
        board.cards.append(TaskCard(id: S.card(10), title: "Sans rang", projectID: nil, rank: "y",
                                    assignee: S.agent(2), createdAt: S.at(10)))
        #expect(BoardQuery.queue(of: S.agent(1), in: board) == [.card(S.card(3)), .card(S.card(1))])
        #expect(BoardQuery.queue(of: S.agent(2), in: board).isEmpty)
    }

    @Test func queueTiesAreBrokenDeterministically() {
        var board = TaskBoardState()
        board.cards = [
            TaskCard(id: S.card(2), title: "b", projectID: nil, rank: "m", assignee: S.agent(1), queueRank: "k",
                     createdAt: S.at(1)),
            TaskCard(id: S.card(1), title: "a", projectID: nil, rank: "c", assignee: S.agent(1), queueRank: "k",
                     createdAt: S.at(2)),
        ]
        board.instructions = [
            QueuedInstruction(id: S.instruction(2), agentID: S.agent(1), text: "y", queueRank: "a", createdAt: S.at(1)),
            QueuedInstruction(id: S.instruction(1), agentID: S.agent(1), text: "x", queueRank: "a", createdAt: S.at(1)),
            QueuedInstruction(id: S.instruction(3), agentID: S.agent(1), text: "z", queueRank: "a", createdAt: S.at(0)),
        ]
        let expected: [QueueItem] = [
            .instruction(S.instruction(3)), .instruction(S.instruction(1)), .instruction(S.instruction(2)),
            .card(S.card(1)), .card(S.card(2)),
        ]
        #expect(BoardQuery.queue(of: S.agent(1), in: board) == expected)
        board.cards.reverse()
        board.instructions.reverse()
        #expect(BoardQuery.queue(of: S.agent(1), in: board) == expected)
    }

    @Test func queuePositionCountsFromOneAfterInstructions() {
        let board = Self.board()
        #expect(BoardQuery.queuePosition(of: S.card(3), in: board) == 3)
        #expect(BoardQuery.queuePosition(of: S.card(1), in: board) == 4)

        var noInstructions = board
        noInstructions.instructions = []
        #expect(BoardQuery.queuePosition(of: S.card(3), in: noInstructions) == 1)
        #expect(BoardQuery.queuePosition(of: S.card(1), in: noInstructions) == 2)
    }

    @Test func queuePositionIsNilOutsideAQueue() {
        let board = Self.board()
        #expect(BoardQuery.queuePosition(of: S.card(2), in: board) == nil)   // unassigned
        #expect(BoardQuery.queuePosition(of: S.card(8), in: board) == nil)   // in progress
        #expect(BoardQuery.queuePosition(of: S.card(5), in: board) == nil)   // waiting for review
        #expect(BoardQuery.queuePosition(of: S.card(6), in: board) == nil)   // done
        #expect(BoardQuery.queuePosition(of: S.card(99), in: board) == nil)  // unknown
    }

    @Test func currentCardIsTheAgentsCardInProgress() {
        let board = Self.board()
        #expect(BoardQuery.currentCard(of: S.agent(1), in: board)?.id == S.card(8))
        #expect(BoardQuery.currentCard(of: S.agent(2), in: board)?.id == S.card(4))
        #expect(BoardQuery.currentCard(of: S.agent(9), in: board) == nil)

        var idle = board
        idle.cards.removeAll { $0.column == .inProgress }
        // Queued, waiting for review or done: not being worked on.
        #expect(BoardQuery.currentCard(of: S.agent(1), in: idle) == nil)
    }

    @Test func currentCardPrefersTheRunningCardOverStoppedOnes() {
        var board = Self.board()
        board.cards.append(TaskCard(id: S.card(9), title: "Interrompue", projectID: S.project(1), column: .inProgress,
                                    rank: "a", assignee: S.agent(1), flags: [.interrupted], createdAt: S.at(9),
                                    updatedAt: S.at(30)))
        #expect(BoardQuery.currentCard(of: S.agent(1), in: board)?.id == S.card(8))

        // Only stopped cards left: the latest one the agent touched.
        board.cards.append(TaskCard(id: S.card(10), title: "Session perdue", projectID: S.project(1),
                                    column: .inProgress, rank: "b", assignee: S.agent(1), flags: [.sessionLost],
                                    createdAt: S.at(10), updatedAt: S.at(40)))
        board.cards.removeAll { $0.id == S.card(8) }
        #expect(BoardQuery.currentCard(of: S.agent(1), in: board)?.id == S.card(10))

        // A card still running in the background is not stopped.
        board.cards.append(TaskCard(id: S.card(11), title: "Tâche de fond", projectID: S.project(1),
                                    column: .inProgress, rank: "c", assignee: S.agent(1), flags: [.backgroundRunning],
                                    createdAt: S.at(11), updatedAt: S.at(12)))
        #expect(BoardQuery.currentCard(of: S.agent(1), in: board)?.id == S.card(11))
    }

    // MARK: - Tags

    @Test func allTagsAreSortedAndUniqueIgnoringCase() {
        #expect(BoardQuery.allTags(Self.board()) == ["api", "auth", "backend", "bug", "ci", "doc", "infra", "ui"])

        var board = TaskBoardState()
        board.cards = [
            TaskCard(id: S.card(1), title: "a", projectID: nil, rank: "a", tags: ["Zeta", "élan", "API"], createdAt: S.at(1)),
            TaskCard(id: S.card(2), title: "b", projectID: nil, rank: "b", tags: ["api", "ZETA", "Backend"], createdAt: S.at(2)),
            TaskCard(id: S.card(3), title: "c", projectID: nil, column: .done, rank: "a", tags: ["#doc", "ecole", "école"],
                     createdAt: S.at(3)),
        ]
        // The first spelling met is kept; accents and case do not push a tag to the end.
        #expect(BoardQuery.allTags(board) == ["API", "Backend", "doc", "ecole", "école", "élan", "Zeta"])
        #expect(BoardQuery.allTags(TaskBoardState()).isEmpty)
    }
}

extension Dictionary where Key == Column, Value == [TaskCardID] {
    /// Every card id, column after column (deterministic, unlike `values`).
    var flat: [TaskCardID] { Column.allCases.flatMap { self[$0] ?? [] } }
}
