import Foundation
import Testing
@testable import PixelCore

/// Dropping a post-it on the scene: the table of 3.9, one test per row.
@Suite struct DropResolverTests {
    static let t0 = SceneFixtures.t0
    static let home = "/Users/lea"
    static let api = ProjectID(SceneFixtures.uuid(0xA1))
    static let infra = ProjectID(SceneFixtures.uuid(0xA2))
    static let archived = ProjectID(SceneFixtures.uuid(0xA3))
    static let nova = AgentID(SceneFixtures.uuid(0xB1))
    static let bip = AgentID(SceneFixtures.uuid(0xB2))
    static let kiwi = AgentID(SceneFixtures.uuid(0xB3))
    static let rio = AgentID(SceneFixtures.uuid(0xB4))
    static let sol = AgentID(SceneFixtures.uuid(0xB5))
    static let ghost = AgentID(SceneFixtures.uuid(0xB6))
    static let old = AgentID(SceneFixtures.uuid(0xB7))

    /// API (~/dev/api): Nova idle, Bip working, Kiwi offline, Rio waiting. INFRA (~/dev/infra): Sol idle, Ghost
    /// orphaned (its terminal runs outside the app). An archived project with its agent.
    static func workspace() -> Workspace {
        var w = Workspace()
        w.addProject(path: "/Users/lea/dev/api", name: "API", hueIndex: 4, id: api, now: t0 - 86_400)
        w.addProject(path: "/Users/lea/dev/infra", name: "INFRA", hueIndex: 2, id: infra, now: t0 - 86_000)
        w.addProject(path: "/Users/lea/dev/old", name: "OLD", hueIndex: 1, id: archived, now: t0 - 80_000)
        _ = w.addAgent(to: api, name: "Nova", id: nova, now: t0 - 3_600)
        _ = w.addAgent(to: api, name: "Bip", id: bip, now: t0 - 3_500)
        _ = w.addAgent(to: api, name: "Kiwi", id: kiwi, now: t0 - 3_400)
        _ = w.addAgent(to: api, name: "Rio", id: rio, now: t0 - 3_300)
        _ = w.addAgent(to: infra, name: "Sol", id: sol, now: t0 - 3_200)
        _ = w.addAgent(to: infra, name: "Ghost", id: ghost, now: t0 - 3_100)
        _ = w.addAgent(to: archived, name: "Old", id: old, now: t0 - 3_000)
        w.archiveProject(archived)
        return w
    }

    static func runtimes() -> [AgentID: AgentRuntime] {
        var waiting = SceneFixtures.runtime(.working(.bash))
        waiting.pendingWaits[.tool(toolUseID: "toolu_rio")] =
            PendingWait(reason: .permission(tool: "Bash", summary: "rm -rf dist"), subagentID: nil, since: t0 - 5)
        return [
            nova: SceneFixtures.runtime(.idle),
            bip: SceneFixtures.runtime(.working(.edit)),
            kiwi: SceneFixtures.runtime(.offline(.exited), pid: nil),
            rio: waiting,
            sol: SceneFixtures.runtime(.done),
            ghost: SceneFixtures.runtime(.offline(.orphanElsewhere), pid: nil),
            old: SceneFixtures.runtime(.idle),
        ]
    }

    static func card(_ n: Int, _ column: Column = .todo, project: ProjectID? = api, assignee: AgentID? = nil,
                     queueRank: String? = nil) -> TaskCard {
        TaskCard(id: TaskCardID(SceneFixtures.uuid(0xC00 + n)), title: "carte \(n)", projectID: project, column: column,
                 rank: "m\(n)", assignee: assignee, queueRank: queueRank, createdAt: t0 - Double(1_000 - n))
    }

    /// The dropped card (1, API, "À faire", unassigned); Nova has one card in her queue, Bip an instruction and two
    /// cards.
    static func board(dropped: TaskCard = card(1)) -> TaskBoardState {
        TaskBoardState(
            cards: [
                dropped,
                card(2, assignee: nova, queueRank: "a"),
                card(3, assignee: bip, queueRank: "a"),
                card(4, assignee: bip, queueRank: "b"),
                card(5, .inProgress, assignee: bip),
            ],
            instructions: [QueuedInstruction(agentID: bip, text: "continue", queueRank: "a", createdAt: t0 - 10)])
    }

    static func context(board: TaskBoardState = board()) -> DropContext {
        DropContext(workspace: workspace(), runtimes: runtimes(), board: board, home: home)
    }

    static func decide(_ card: TaskCard = card(1), over target: SceneHitTarget?) -> DropDecision {
        DropResolver.decide(card: card, over: target, context: context(board: board(dropped: card)))
    }

    /// C5: only a card of "À faire" can be given; the others are refused with the forbidden cursor.
    @Test func cardOutsideTodoIsRefused() {
        for column in [Column.inProgress, .review, .done] {
            let card = Self.card(1, column, assignee: column == .done ? nil : Self.bip)
            for target in [SceneHitTarget.agent(Self.nova), .freeDesk(Self.api, deskIndex: 6), .islandFloor(Self.api, part: 0)] {
                let decision = Self.decide(card, over: target)
                #expect(!decision.accepted && decision.action == .none, "\(column) \(target)")
                #expect(decision.feedback == "Remets-la d'abord à faire.", "\(column) \(target)")
                #expect(decision.highlight == nil)
            }
        }
    }

    /// An agent of the app, same project, free: given, last in its queue.
    @Test func sameProjectFreeAgentTakesItInItsQueue() {
        let decision = Self.decide(over: .agent(Self.nova))
        #expect(decision == DropDecision(accepted: true, feedback: "Donner à Nova · file #2", highlight: .agent(Self.nova),
                                         action: .assign(TaskCardID(SceneFixtures.uuid(0xC01)), Self.nova)))
        // Done counts as free too; an empty queue gives #1.
        var context = Self.context()
        context.runtimes[Self.nova] = SceneFixtures.runtime(.done)
        context.board.cards.removeAll { $0.assignee == Self.nova }
        #expect(DropResolver.decide(card: Self.card(1), over: .agent(Self.nova), context: context).feedback
                == "Donner à Nova · file #1")
    }

    /// Waiting for the user: given, delivered once the user has answered.
    @Test func waitingAgentGetsItAfterTheAnswer() {
        let decision = Self.decide(over: .agent(Self.rio))
        #expect(decision.accepted && decision.highlight == .agent(Self.rio))
        #expect(decision.feedback == "Donner à Rio · sera livré après ton accord")
        #expect(decision.action == .assign(TaskCardID(SceneFixtures.uuid(0xC01)), Self.rio))
    }

    /// Busy: given, queued behind what it already has (instructions count, they go first).
    @Test func busyAgentQueuesIt() {
        let decision = Self.decide(over: .agent(Self.bip))
        #expect(decision.accepted && decision.highlight == .agent(Self.bip))
        #expect(decision.feedback == "Donner à Bip · en file #4")
        #expect(decision.action == .assign(TaskCardID(SceneFixtures.uuid(0xC01)), Self.bip))
    }

    /// Another project: given after the app's confirmation (C3); the folder is shown, abbreviated.
    @Test func otherProjectShowsItsFolder() {
        let decision = Self.decide(over: .agent(Self.sol))
        #expect(decision.accepted && decision.highlight == .agent(Self.sol))
        #expect(decision.feedback == "Donner à Sol · autre projet : ~/dev/infra")
        #expect(decision.action == .assign(TaskCardID(SceneFixtures.uuid(0xC01)), Self.sol))
        // A card without project goes to any agent without confirmation: no "autre projet".
        let paper = Self.decide(Self.card(1, project: nil), over: .agent(Self.sol))
        #expect(paper.feedback == "Donner à Sol · file #1")
        // A folder outside the home folder is shown whole.
        var context = Self.context()
        context.home = "/Users/max"
        #expect(DropResolver.decide(card: Self.card(1), over: .agent(Self.sol), context: context).feedback
                == "Donner à Sol · autre projet : /Users/lea/dev/infra")
    }

    /// Offline: given, then the app offers to relaunch the session.
    @Test func offlineAgentGetsItAfterARelaunch() {
        let decision = Self.decide(over: .agent(Self.kiwi))
        #expect(decision.accepted && decision.highlight == .agent(Self.kiwi))
        #expect(decision.feedback == "Donner à Kiwi · hors ligne : sera livré après relance")
        #expect(decision.action == .assignOffline(TaskCardID(SceneFixtures.uuid(0xC01)), Self.kiwi))
        // Without any runtime yet (never launched): offline as well.
        var context = Self.context()
        context.runtimes[Self.kiwi] = nil
        #expect(DropResolver.decide(card: Self.card(1), over: .agent(Self.kiwi), context: context).action
                == .assignOffline(TaskCardID(SceneFixtures.uuid(0xC01)), Self.kiwi))
    }

    /// An orphan (its terminal outlived a crash of the app, outside it): forbidden.
    @Test func orphanIsForbidden() {
        let decision = Self.decide(over: .agent(Self.ghost))
        #expect(!decision.accepted && decision.action == .none && decision.highlight == nil)
        #expect(decision.feedback == "Ghost · terminal hors de l'app")
    }

    /// A free desk: a new agent is launched there with the post-it as its first prompt.
    @Test func freeDeskLaunchesANewAgent() {
        let decision = Self.decide(over: .freeDesk(Self.api, deskIndex: 4))
        #expect(decision == DropDecision(accepted: true, feedback: "Nouvel agent avec ce post-it",
                                         highlight: .freeDesk(Self.api, deskIndex: 4),
                                         action: .launchNewAgent(TaskCardID(SceneFixtures.uuid(0xC01)), Self.api,
                                                                 deskIndex: 4)))
        // A desk taken since (stale target): nothing.
        #expect(Self.decide(over: .freeDesk(Self.api, deskIndex: 0)).action == .none)
    }

    /// The floor or the sign of an island: the first free agent of the project (DispatchPolicy, chosen by the app).
    @Test func islandGivesItToItsFirstFreeAgent() {
        for target in [SceneHitTarget.islandFloor(Self.api, part: 0), .islandSign(Self.api, part: 0)] {
            let decision = Self.decide(over: target)
            #expect(decision == DropDecision(accepted: true, feedback: "Premier agent libre de API",
                                             highlight: .islandFloor(Self.api, part: 0),
                                             action: .firstFreeAgent(TaskCardID(SceneFixtures.uuid(0xC01)), Self.api)),
                    "\(target)")
        }
        // An annex highlights its own rug.
        #expect(Self.decide(over: .islandSign(Self.infra, part: 1)).highlight == .islandFloor(Self.infra, part: 1))
    }

    /// Anywhere else: no operation, no message.
    @Test func elsewhereDoesNothing() {
        let targets: [SceneHitTarget?] = [nil, .floor(GridPoint(3, 3)), .corkWall, .elevator, .hallProp(.coffeeMachine),
                                          .agent(AgentID(SceneFixtures.uuid(0xBF))), .agent(Self.old),
                                          .freeDesk(Self.archived, deskIndex: 2), .islandFloor(Self.archived, part: 0)]
        for target in targets {
            let decision = Self.decide(over: target)
            #expect(decision == DropDecision(accepted: false, feedback: "", highlight: nil, action: .none),
                    "\(String(describing: target))")
        }
        // A card already in that very queue: nothing to do.
        let queued = Self.card(2, assignee: Self.nova, queueRank: "a")
        let again = DropResolver.decide(card: queued, over: .agent(Self.nova), context: Self.context())
        #expect(!again.accepted && again.action == .none && again.highlight == .agent(Self.nova))
        #expect(again.feedback == "Déjà dans la file de Nova · file #1")
    }
}
