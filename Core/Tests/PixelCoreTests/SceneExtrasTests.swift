import Foundation
import Testing
@testable import PixelCore

/// `SceneInput.make(…board…)`: the post-its of the scene read from the board (queues, the card on each screen, the
/// cork wall), and the interaction fields passed through.
@Suite struct SceneExtrasTests {
    static let t0 = SceneFixtures.t0
    static let api = ProjectID(SceneFixtures.uuid(0xA1))
    static let site = ProjectID(SceneFixtures.uuid(0xA2))
    static let nova = AgentID(SceneFixtures.uuid(0xB1))
    static let bip = AgentID(SceneFixtures.uuid(0xB2))
    static let ivo = AgentID(SceneFixtures.uuid(0xB3))
    static let gone = ProjectID(SceneFixtures.uuid(0xAF))

    /// API (hue 4) with Nova and Bip, SITE (hue 0) with Ivo.
    static func workspace() -> Workspace {
        var workspace = Workspace()
        workspace.addProject(path: "/projets/api", name: "API", hueIndex: 4, id: api, now: t0 - 86_400)
        workspace.addProject(path: "/projets/site", name: "SITE", hueIndex: 0, id: site, now: t0 - 86_000)
        _ = workspace.addAgent(to: api, name: "Nova", id: nova, now: t0 - 3_600)
        _ = workspace.addAgent(to: api, name: "Bip", id: bip, now: t0 - 3_500)
        _ = workspace.addAgent(to: site, name: "Ivo", id: ivo, now: t0 - 3_400)
        return workspace
    }

    static func card(_ n: Int, _ column: Column, rank: String, project: ProjectID?, assignee: AgentID? = nil,
                     queueRank: String? = nil) -> TaskCard {
        TaskCard(id: TaskCardID(SceneFixtures.uuid(0xC00 + n)), title: "carte \(n)", projectID: project, column: column,
                 rank: rank, assignee: assignee, queueRank: queueRank, createdAt: t0 - Double(1_000 - n))
    }

    /// Nova: two queued cards (API, SITE), one instruction, nothing on screen. Bip: a card assigned without a queue
    /// rank (not queued), working on a SITE card. Ivo: working on a card without project. The cork wall: the open
    /// columns, ranks out of insertion order, a card of a project that no longer exists, one done card (left out).
    static func board() -> TaskBoardState {
        TaskBoardState(
            cards: [
                card(1, .todo, rank: "m", project: api, assignee: nova, queueRank: "a"),
                card(2, .todo, rank: "c", project: site, assignee: nova, queueRank: "b"),
                card(3, .todo, rank: "t", project: api, assignee: bip),
                card(4, .todo, rank: "a", project: nil),
                card(5, .inProgress, rank: "k", project: nil, assignee: ivo),
                card(6, .inProgress, rank: "b", project: site, assignee: bip),
                card(7, .review, rank: "x", project: gone),
                card(8, .review, rank: "d", project: api),
                card(9, .done, rank: "a", project: site),
            ],
            instructions: [QueuedInstruction(agentID: nova, text: "continue", queueRank: "a", createdAt: t0 - 10)])
    }

    static func scene(board: TaskBoardState = board()) -> SceneInput {
        SceneInput.make(workspace: workspace(), runtimes: [:], board: board, now: t0)
    }

    @Test func queuesCountCardsNotInstructions() {
        let scene = Self.scene()
        #expect(BoardQuery.queue(of: Self.nova, in: Self.board()).count == 3, "the instruction is in Nova's queue")
        #expect(scene.agents[Self.nova]?.extras.queued == 2)
        // Assigned without a queue rank: not queued.
        #expect(scene.agents[Self.bip]?.extras.queued == 0)
        #expect(scene.agents[Self.ivo]?.extras.queued == 0)
    }

    @Test func cardOnScreenTakesItsProjectHue() {
        let scene = Self.scene()
        #expect(scene.agents[Self.nova]?.extras.cardOnScreenHue == nil)
        #expect(scene.agents[Self.bip]?.extras.cardOnScreenHue == 0, "SITE")
        #expect(scene.agents[Self.ivo]?.extras.cardOnScreenHue == SceneInput.paperHue, "no project: paper")
        // Drawn on the screen of the post: a paper post-it on Ivo's monitor.
        let plan = ScenePlanner.plan(scene, options: ScenePlanOptions())
        let ivoDesk = scene.layout.islands.flatMap(\.desks).first { $0.agentID == Self.ivo }!
        let postit = plan.node(SceneNodeID("post:\(Self.site)/\(ivoDesk.index)/postit"))
        #expect(postit?.sprite == .sprite(SpriteKey("desk.postit", variant: "paper"), frame: nil))
    }

    @Test func corkWallShowsOpenColumnsInOrder() {
        // À faire by rank (4 "a", 2 "c", 1 "m", 3 "t"), En cours (6 "b", 5 "k"), À valider (8 "d", 7 "x");
        // card 7's project is gone: paper; the done card is left out.
        #expect(Self.scene().boardCardHues == [10, 0, 4, 4, 0, 10, 4, 10])
        #expect(SceneInput.corkWallColumns == [.todo, .inProgress, .review])
    }

    @Test func emptyBoardMatchesPlainMake() {
        let workspace = Self.workspace()
        let (_, runtimes) = SceneFixtures.twoDeskWorkspace()
        let plain = SceneInput.make(workspace: workspace, runtimes: runtimes, now: Self.t0)
        let fromBoard = SceneInput.make(workspace: workspace, runtimes: runtimes, board: TaskBoardState(), now: Self.t0)
        #expect(fromBoard == plain)
        #expect(fromBoard.boardCardHues.isEmpty && fromBoard.agents.values.allSatisfy { $0.extras == AgentExtras() })
        let calm = SceneInput.make(workspace: workspace, runtimes: runtimes, board: TaskBoardState(), now: Self.t0,
                                   reduceMotion: true)
        #expect(calm == SceneInput.make(workspace: workspace, runtimes: runtimes, now: Self.t0, reduceMotion: true))
    }

    @Test func interactionFieldsPassThrough() {
        let scene = SceneInput.make(workspace: Self.workspace(), runtimes: [:], board: Self.board(), now: Self.t0,
                                    selectedAgent: Self.bip, hovered: .freeDesk(Self.api, deskIndex: 2),
                                    dropTarget: .islandFloor(Self.site, part: 0), hiddenAgents: [Self.ivo])
        #expect(scene.selectedAgent == Self.bip)
        #expect(scene.hovered == .freeDesk(Self.api, deskIndex: 2))
        #expect(scene.dropTarget == .islandFloor(Self.site, part: 0))
        #expect(scene.hiddenAgents == [Self.ivo])
        // The plain initializer leaves them empty.
        let plain = SceneInput(layout: scene.layout, projects: scene.projects, agents: scene.agents)
        #expect(plain.selectedAgent == nil && plain.hovered == nil && plain.dropTarget == nil && plain.hiddenAgents.isEmpty)
    }
}
