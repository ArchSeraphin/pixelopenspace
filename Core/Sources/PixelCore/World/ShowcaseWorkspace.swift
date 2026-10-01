import Foundation

/// The simulated open space of the snapshot and demo modes: mockup 6(q)'s 6 projects and 20 agents, with every
/// state of an agent, and a board whose post-its feed the queues. Fixed ids and dates (Showcase.now).
public struct ShowcaseWorkspace: Equatable, Sendable {
    public var workspace: Workspace
    public var runtimes: [AgentID: AgentRuntime]
    public var board: TaskBoardState
    /// Matches the board: queue sizes, the card stuck on each monitor (current card's project hue, 10 = paper).
    public var extras: [AgentID: AgentExtras]
    /// Cards of "À faire", "En cours", "À valider", by column then rank: their project hue, 10 = paper.
    public var boardCardHues: [Int]
    public var now: Date

    public init(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState,
                extras: [AgentID: AgentExtras], boardCardHues: [Int], now: Date) {
        self.workspace = workspace
        self.runtimes = runtimes
        self.board = board
        self.extras = extras
        self.boardCardHues = boardCardHues
        self.now = now
    }

    /// Agents with a running process (never Kiwi, offline): the ones a demo trial may put in a wait. In sidebar
    /// order (projects in order, then desks).
    public var liveAgents: [AgentID] {
        workspace.projectsInOrder
            .flatMap { workspace.agents(in: $0.id) }
            .map(\.id)
            .filter { runtimes[$0]?.pid != nil }
    }

    public func sceneInput(reduceMotion: Bool = false) -> SceneInput {
        SceneInput.make(workspace: workspace, runtimes: runtimes, extras: extras, boardCardHues: boardCardHues,
                        now: now, reduceMotion: reduceMotion)
    }

    public func agentID(named name: String) -> AgentID? {
        workspace.agents.first { $0.name == name }?.id
    }

    public func projectID(named name: String) -> ProjectID? {
        workspace.projects.first { $0.name == name }?.id
    }

    public func cardID(titled title: String) -> TaskCardID? {
        board.cards.first { $0.title == title }?.id
    }

    /// Runtimes where exactly `picks` wait (reason k cycles a fixed list: permission Bash, question, permission Edit,
    /// MCP message; since 5 + 17·k seconds); Nova, Sol and Ivo, who wait in `runtimes`, work instead.
    /// Precondition: every pick is in `liveAgents`.
    public func runtimes(waiting picks: [AgentID]) -> [AgentID: AgentRuntime] {
        let live = Set(liveAgents)
        var result = runtimes
        // Whoever waits in the distribution goes on with the tool it was waiting for (a question: reading).
        for (id, runtime) in runtimes {
            guard let wait = runtime.oldestWait else { continue }
            let tool: ToolKind
            if case .permission(let name, _) = wait.reason { tool = ToolKind.from(toolName: name) } else { tool = .read }
            result[id] = Showcase.runtime(.working(tool))
        }
        for (k, id) in picks.enumerated() {
            precondition(live.contains(id), "a demo trial only puts a live agent in a wait")
            let reason = Showcase.trialReasons[k % Showcase.trialReasons.count]
            result[id] = Showcase.runtime(.waiting(reason, secondsAgo: TimeInterval(5 + 17 * k)))
        }
        return result
    }
}

/// What a live agent of the demo does between two trials ("Animer").
public enum DemoActivity: Hashable, Sendable {
    case working(ToolKind), thinking, idle(minutes: Int), done
}

extension Showcase {
    /// The app's simulated open space: mockup 6(q)'s projects in slots 0 to 5, 20 agents (table of the step 3 plan,
    /// task 1), the board below, the extras and the cork wall derived from that board.
    public static func appWorkspace() -> ShowcaseWorkspace {
        var workspace = Workspace()
        var runtimes: [AgentID: AgentRuntime] = [:]
        var next = 0
        for (index, project) in appProjects.enumerated() {
            let projectID = workspace.addProject(path: "/projets/\(project.name.lowercased())", name: project.name,
                                                 hueIndex: project.hue, id: ProjectID(uuid(appProjectIDs + index)),
                                                 now: now - 172_800 + Double(index) * 60)
            for case let member? in project.members {
                let id = AgentID(uuid(appAgentIDs + next))
                next += 1
                _ = workspace.addAgent(to: projectID, name: member.name, permissionMode: member.permissionMode, id: id,
                                       now: now - 86_400 + Double(next) * 60)
                if let look = looks[member.name], let i = workspace.agents.firstIndex(where: { $0.id == id }) {
                    workspace.agents[i].look = look
                }
                runtimes[id] = runtime(member.activity)
            }
        }
        let board = appBoard(workspace)
        return ShowcaseWorkspace(workspace: workspace, runtimes: runtimes, board: board,
                                 extras: extras(of: board, workspace: workspace),
                                 boardCardHues: corkWallHues(of: board, workspace: workspace), now: now)
    }

    /// An empty workspace (first launch, 6(r)), same clock: no project, no agent, the starter templates.
    public static func emptyWorkspace() -> ShowcaseWorkspace {
        let templates = (0..<StarterTemplates.definitions.count).map { PromptTemplateID(uuid(appTemplateIDs + $0)) }
        return ShowcaseWorkspace(workspace: Workspace(), runtimes: [:],
                                 board: TaskBoardState.initial(templateIDs: templates), extras: [:], boardCardHues: [],
                                 now: now)
    }

    /// The runtime of a live agent doing `activity` at `now` (demo animation): a running process, healthy hooks,
    /// the phase starting at `now` (idle: `minutes` ago, asleep after 10).
    public static func demoRuntime(_ activity: DemoActivity, now: Date) -> AgentRuntime {
        let phase: AgentPhase
        var since = now
        switch activity {
        case .working(let tool): phase = .working(tool)
        case .thinking: phase = .thinking
        case .idle(let minutes):
            phase = .idle
            since = now - TimeInterval(max(minutes, 0) * 60)
        case .done: phase = .done
        }
        var runtime = AgentRuntime(phase: phase, phaseSince: since)
        runtime.pid = 40_000
        runtime.hookHealth = .healthy
        runtime.currentSessionID = "session-demo"
        return runtime
    }

    // MARK: Distribution

    /// First ids of each kind ("00000000-0000-0000-0000-0000000000NN"), apart from the milestone's scenes.
    static let appProjectIDs = 0x0A1
    static let appAgentIDs = 0x101
    static let appCardIDs = 0x201
    static let appTemplateIDs = 0x301

    /// The plan's table, project by project, desk by desk (projects created in this order: slots 0 to 5).
    static let appProjects: [DemoProject] = [
        DemoProject(name: "API", hue: 4, members: [
            Member(name: "Nova", activity: .waiting(.permission(tool: "Bash", summary: "rm -rf dist"), secondsAgo: 42)),
            Member(name: "Bip", activity: .working(.bash, subagents: 2)),
            Member(name: "Lune", activity: .thinking()),
            Member(name: "Kiwi", activity: .offline(.closedByUser)),
            Member(name: "Oslo", activity: .done),
        ]),
        DemoProject(name: "INFRA", hue: 3, members: [
            Member(name: "Zéphyr", activity: .error(.api("overloaded"))),
            Member(name: "Ada", activity: .working(.edit)),
            Member(name: "Rio", activity: .quota(resumeInMinutes: 40)),
            Member(name: "Sol", activity: .waiting(.question([question]), secondsAgo: 130)),
        ]),
        DemoProject(name: "SITE", hue: 0, members: [
            Member(name: "Pixou", activity: .working(.edit)),
            Member(name: "Tao", activity: .idle(minutes: 12)),
            Member(name: "Mika", activity: .background),
        ]),
        DemoProject(name: "DATA", hue: 5, members: [
            Member(name: "Plume", activity: .thinking(stale: true, degraded: true)),
            Member(name: "Galet", activity: .idle(minutes: 2, draft: "ajoute un test"), permissionMode: .bypassPermissions),
            Member(name: "Brume", activity: .launching),
        ]),
        DemoProject(name: "MOBILE", hue: 7, members: [
            Member(name: "Comète", activity: .working(.subagent, subagents: 1)),
            Member(name: "Nuage", activity: .idle(minutes: 6)),
            Member(name: "Pépin", activity: .working(.mcp("notes"))),
        ]),
        DemoProject(name: "DOCS", hue: 2, members: [
            Member(name: "Ivo", activity: .waiting(.permission(tool: "Edit", summary: "README.md"), secondsAgo: 5)),
            Member(name: "Cajou", activity: .done),
        ]),
    ]

    /// The waits of a demo trial, in turn: permission Bash, question, permission Edit, MCP message.
    static let trialReasons: [WaitReason] = [
        .permission(tool: "Bash", summary: "git push --force"),
        .question([AskedQuestion(header: "Cache", question: "Faut-il vider le cache avant la mise en ligne ?",
                                 options: ["Oui", "Non"], multiSelect: false)]),
        .permission(tool: "Edit", summary: "Package.swift"),
        .elicitation(server: "notes", message: "Choisis le carnet où ranger le compte rendu"),
    ]

    // MARK: Board

    /// One post-it of the simulated board, in column order.
    struct DemoCard {
        var title: String
        var project: String?
        var column: Column
        var assignee: String? = nil
        var priority: Priority = .normal
        var tags: [String] = []
        var details: String = ""
    }

    /// The plan's board: "À faire", "En cours", "À valider", "Fait", each in rank order. Queued cards are the
    /// assigned ones of "À faire", in this order.
    static let appCards: [DemoCard] = [
        DemoCard(title: "Doc des erreurs 401", project: "API", column: .todo, assignee: "Nova", tags: ["doc"],
                 details: "Lister les cas où l'API répond 401 et le message renvoyé."),
        DemoCard(title: "Pagination /users", project: "API", column: .todo, priority: .high, tags: ["api"]),
        DemoCard(title: "Tri des colonnes", project: "API", column: .todo, priority: .low),
        DemoCard(title: "Rotation des logs", project: "INFRA", column: .todo, tags: ["ops"]),
        DemoCard(title: "Menu mobile", project: "SITE", column: .todo, assignee: "Pixou", tags: ["ui"]),
        DemoCard(title: "Logo du pied de page", project: "SITE", column: .todo, assignee: "Pixou", tags: ["ui"]),
        DemoCard(title: "Index des tables", project: "DATA", column: .todo, tags: ["perf"]),
        DemoCard(title: "Vérifier les liens", project: nil, column: .todo),
        DemoCard(title: "Refonte du header", project: "SITE", column: .inProgress, assignee: "Pixou", tags: ["ui"]),
        DemoCard(title: "Cache des builds", project: "API", column: .inProgress, assignee: "Bip", tags: ["ci"]),
        DemoCard(title: "Migration Terraform", project: "INFRA", column: .inProgress, assignee: "Ada", tags: ["ops"]),
        DemoCard(title: "Notifications push", project: "MOBILE", column: .inProgress, assignee: "Comète"),
        DemoCard(title: "Synchro des notes", project: "MOBILE", column: .inProgress, assignee: "Pépin"),
        DemoCard(title: "Recherche plein texte", project: "DATA", column: .inProgress, assignee: "Plume",
                 tags: ["perf"]),
        DemoCard(title: "README d'installation", project: "API", column: .review, assignee: "Oslo", tags: ["doc"]),
        DemoCard(title: "Guide de contribution", project: "DOCS", column: .review, assignee: "Cajou", tags: ["doc"]),
        DemoCard(title: "Lint CI", project: "API", column: .done, tags: ["ci"]),
        DemoCard(title: "Nettoyage des logs", project: "INFRA", column: .done, tags: ["ops"]),
        DemoCard(title: "Page 404", project: "SITE", column: .done, tags: ["ui"]),
    ]

    /// The board as the lifecycle would leave it: ranks spread in each column, queue ranks spread in each agent's
    /// queue, a confirmed delivery on every card in progress or to review, a history that tells the same story.
    static func appBoard(_ workspace: Workspace) -> TaskBoardState {
        let agentIDs = Dictionary(workspace.agents.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let projectIDs = Dictionary(workspace.projects.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var ranks: [Column: [String]] = [:]
        for column in Column.allCases {
            ranks[column] = RankKey.spread(appCards.filter { $0.column == column }.count)
        }
        var queueRanks: [String: [String]] = [:]
        for name in Set(appCards.compactMap { $0.column == .todo ? $0.assignee : nil }) {
            queueRanks[name] = RankKey.spread(appCards.filter { $0.column == .todo && $0.assignee == name }.count)
        }
        var cards: [TaskCard] = []
        for (index, spec) in appCards.enumerated() {
            let created = now - 259_200 + Double(index) * 1_800
            let agent = spec.assignee.flatMap { agentIDs[$0] }
            var history = [CardEvent(at: created, kind: .created, to: .todo)]
            var updated = created
            var queueRank: String?
            var delivery: DeliveryInfo?
            if let agent {
                updated = created + 600
                history.append(CardEvent(at: updated, kind: .assigned, agentID: agent))
            }
            if spec.column == .todo, let name = spec.assignee {
                queueRank = queueRanks[name]?.removeFirst()
            }
            if spec.column == .inProgress || spec.column == .review, let agent {
                let sent = created + 3_600
                delivery = DeliveryInfo(sessionID: "session-demo", promptID: "prompt-\(index + 1)", sentAt: sent,
                                        confirmedAt: sent + 2)
                history.append(CardEvent(at: sent, kind: .deliveryStarted, agentID: agent))
                history.append(CardEvent(at: sent + 2, kind: .deliveryConfirmed, from: .todo, to: .inProgress,
                                         agentID: agent))
                updated = sent + 2
                if spec.column == .review {
                    let ended = sent + 1_800
                    delivery?.turnEndedAt = ended
                    history.append(CardEvent(at: ended, kind: .turnEnded, from: .inProgress, to: .review, agentID: agent))
                    updated = ended
                }
            }
            if spec.column == .done {
                updated = created + 7_200
                history.append(CardEvent(at: updated, kind: .validated, from: .review, to: .done))
            }
            cards.append(TaskCard(id: TaskCardID(uuid(appCardIDs + index)), title: spec.title, details: spec.details,
                                  projectID: spec.project.flatMap { projectIDs[$0] }, column: spec.column,
                                  rank: ranks[spec.column]!.removeFirst(), priority: spec.priority, tags: spec.tags,
                                  assignee: agent, queueRank: queueRank, delivery: delivery, history: history,
                                  validatedOnce: spec.column == .done, createdAt: created, updatedAt: updated))
        }
        var board = emptyWorkspace().board
        board.cards = cards
        return board
    }

    /// Each agent's queue size and the card stuck on its monitor (its current card's project hue, 10 = paper).
    static func extras(of board: TaskBoardState, workspace: Workspace) -> [AgentID: AgentExtras] {
        var extras: [AgentID: AgentExtras] = [:]
        for agent in workspace.agents {
            let monitor = BoardQuery.currentCard(of: agent.id, in: board).map { hue(of: $0, workspace: workspace) }
            extras[agent.id] = AgentExtras(queued: BoardQuery.queue(of: agent.id, in: board).count,
                                           cardOnScreenHue: monitor)
        }
        return extras
    }

    /// The mini post-its of the cork wall: "À faire", "En cours" and "À valider", by column then rank.
    static func corkWallHues(of board: TaskBoardState, workspace: Workspace) -> [Int] {
        [Column.todo, .inProgress, .review].flatMap { board.cards(in: $0) }.map { hue(of: $0, workspace: workspace) }
    }

    /// The card's project hue, 10 (paper) without a project.
    static func hue(of card: TaskCard, workspace: Workspace) -> Int {
        card.projectID.flatMap { workspace.project($0)?.hueIndex } ?? 10
    }
}
