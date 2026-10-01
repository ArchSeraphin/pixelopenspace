import Foundation
import Testing
@testable import PixelCore

/// The simulated open space of the snapshot and demo modes (step 3, task 1): mockup 6(q)'s 6 projects and 20 agents,
/// every state of an agent, a board that feeds the queues, and the demo trials.
@Suite struct ShowcaseWorkspaceTests {
    static let showcase = Showcase.appWorkspace()

    /// Names of each project's agents, desk by desk.
    static func roster(_ showcase: ShowcaseWorkspace) -> [String: [String]] {
        var roster: [String: [String]] = [:]
        for project in showcase.workspace.projectsInOrder {
            roster[project.name] = showcase.workspace.agents(in: project.id).map(\.name)
        }
        return roster
    }

    static func presentation(_ name: String, in scene: SceneInput) -> AgentPresentation {
        scene.agents.values.first { $0.name == name }!.presentation
    }

    @Test func twentyAgentsOnSixProjects() {
        let workspace = Self.showcase.workspace
        #expect(workspace.agents.count == 20)
        let projects = workspace.projectsInOrder
        #expect(projects.map(\.name) == ["API", "INFRA", "SITE", "DATA", "MOBILE", "DOCS"])
        #expect(projects.map(\.hueIndex) == [4, 3, 0, 5, 7, 2])
        #expect(projects.map(\.slot) == [0, 1, 2, 3, 4, 5])
        #expect(Self.roster(Self.showcase) == [
            "API": ["Nova", "Bip", "Lune", "Kiwi", "Oslo"],
            "INFRA": ["Zéphyr", "Ada", "Rio", "Sol"],
            "SITE": ["Pixou", "Tao", "Mika"],
            "DATA": ["Plume", "Galet", "Brume"],
            "MOBILE": ["Comète", "Nuage", "Pépin"],
            "DOCS": ["Ivo", "Cajou"],
        ])
        // Desks 0, 1, 2… in each project; every agent has a runtime and its hand-made look.
        for project in projects {
            #expect(workspace.agents(in: project.id).map(\.deskIndex) == Array(0..<workspace.agents(in: project.id).count))
        }
        for agent in workspace.agents {
            #expect(Self.showcase.runtimes[agent.id] != nil, "\(agent.name)")
            #expect(agent.look == Showcase.looks[agent.name], "\(agent.name)")
        }
        #expect(Self.showcase.runtimes.count == 20)
        #expect(Self.showcase.now == Showcase.now)
        let scene = Self.showcase.sceneInput()
        #expect(scene.agents.count == 20 && scene.projects.count == 6)
        #expect(scene.layout.islands.map(\.slot) == [0, 1, 2, 3, 4, 5])
    }

    @Test func everyStateIsPresent() {
        let scene = Self.showcase.sceneInput()
        let agents = Array(scene.agents.values)
        #expect(Set(agents.map(\.presentation.kind)) == Set(AgentStateKind.allCases))
        #expect(agents.contains { $0.presentation.asleep && $0.presentation.overlay == .zzz })
        #expect(agents.contains { $0.presentation.overlay == .bang && $0.presentation.toolIcon == .question })
        let badges = Set(agents.flatMap(\.presentation.badges))
        #expect(badges.isSuperset(of: [.stale, .degraded, .draft, .unsafe]))
        #expect(agents.contains { $0.presentation.subagents > 0 })

        // The plan's table, agent by agent.
        func p(_ name: String) -> AgentPresentation { Self.presentation(name, in: scene) }
        #expect(p("Nova").kind == .waitingInput && p("Nova").label.contains("rm -rf dist"))
        #expect(p("Bip").toolIcon == .bash && p("Bip").subagents == 2)
        #expect(p("Lune").kind == .thinking)
        #expect(p("Kiwi").kind == .offline && p("Kiwi").nameplateOff)
        #expect(p("Oslo").kind == .done && p("Cajou").kind == .done)
        #expect(p("Zéphyr").kind == .error && p("Zéphyr").label.contains("serveurs surchargés"))
        #expect(p("Ada").toolIcon == .edit)
        #expect(p("Rio").kind == .quotaPaused && p("Rio").label.contains("40 min"))
        #expect(p("Sol").kind == .waitingInput && p("Sol").toolIcon == .question)
        #expect(p("Pixou").toolIcon == .edit)
        #expect(p("Tao").asleep && !p("Nuage").asleep && p("Nuage").kind == .idle)
        #expect(p("Mika").kind == .waitingBackground)
        #expect(p("Plume").kind == .thinking && p("Plume").badges == [.stale, .degraded])
        #expect(p("Galet").kind == .idle && !p("Galet").asleep && p("Galet").badges == [.draft, .unsafe])
        #expect(p("Brume").kind == .launching && p("Brume").launchingSign)
        #expect(p("Comète").toolIcon == .subagent && p("Comète").subagents == 1)
        #expect(p("Pépin").toolIcon == .mcp)
        #expect(p("Ivo").kind == .waitingInput && p("Ivo").label.contains("README.md"))
        let waiting = agents.filter { $0.presentation.kind == .waitingInput }.map(\.name).sorted()
        #expect(waiting == ["Ivo", "Nova", "Sol"])
    }

    @Test func boardIsValid() {
        let showcase = Self.showcase
        let board = showcase.board
        let agents = Set(showcase.workspace.agents.map(\.id))
        let projects = Set(showcase.workspace.projects.map(\.id))
        let (repaired, issues) = TaskBoardValidator.validate(board, agents: agents, projects: projects)
        #expect(issues.isEmpty, "\(issues)")
        #expect(repaired == board)
        let (workspace, workspaceIssues) = WorkspaceValidator.validate(showcase.workspace)
        #expect(workspaceIssues.isEmpty, "\(workspaceIssues)")
        #expect(workspace == showcase.workspace)

        #expect(board.cards.count == 19)
        #expect(board.cards(in: .todo).map(\.title) == [
            "Doc des erreurs 401", "Pagination /users", "Tri des colonnes", "Rotation des logs", "Menu mobile",
            "Logo du pied de page", "Index des tables", "Vérifier les liens",
        ])
        #expect(board.cards(in: .inProgress).map(\.title) == [
            "Refonte du header", "Cache des builds", "Migration Terraform", "Notifications push",
            "Synchro des notes", "Recherche plein texte",
        ])
        #expect(board.cards(in: .review).map(\.title) == ["README d'installation", "Guide de contribution"])
        #expect(board.cards(in: .done).map(\.title) == ["Lint CI", "Nettoyage des logs", "Page 404"])
        #expect(Set(board.cards.map(\.id)).count == board.cards.count)
        #expect(!board.templates.isEmpty)

        // At most one card in progress per agent, each with a confirmed delivery.
        let inProgress = board.cards(in: .inProgress)
        #expect(Set(inProgress.compactMap(\.assignee)).count == inProgress.count)
        #expect(inProgress.allSatisfy { $0.delivery?.confirmedAt != nil })

        let id = { (name: String) in showcase.agentID(named: name)! }
        #expect(BoardQuery.queue(of: id("Nova"), in: board).count == 1)
        #expect(BoardQuery.queue(of: id("Pixou"), in: board).count == 2)
        #expect(BoardQuery.queuePosition(of: showcase.cardID(titled: "Logo du pied de page")!, in: board) == 2)
        let pagination = board.card(showcase.cardID(titled: "Pagination /users")!)!
        #expect(pagination.assignee == nil && pagination.priority == .high
                && pagination.projectID == showcase.projectID(named: "API"))
        #expect(board.card(showcase.cardID(titled: "Tri des colonnes")!)!.priority == .low)
        #expect(board.card(showcase.cardID(titled: "Vérifier les liens")!)!.projectID == nil)

        // The extras are what the board says: queue sizes, the current card on the monitor (project hue, 10 = paper).
        for agent in showcase.workspace.agents {
            let current = BoardQuery.currentCard(of: agent.id, in: board)
            let hue = current.map { card in
                card.projectID.flatMap { showcase.workspace.project($0)?.hueIndex } ?? 10
            }
            let expected = AgentExtras(queued: BoardQuery.queue(of: agent.id, in: board).count, cardOnScreenHue: hue)
            #expect((showcase.extras[agent.id] ?? AgentExtras()) == expected, "\(agent.name)")
        }
        #expect(Set(showcase.extras.keys).isSubset(of: agents))
        #expect(showcase.extras[id("Pixou")] == AgentExtras(queued: 2, cardOnScreenHue: 0))
        #expect(showcase.extras[id("Nova")] == AgentExtras(queued: 1, cardOnScreenHue: nil))
        #expect(showcase.extras[id("Comète")]?.cardOnScreenHue == 7)

        // The cork wall: "À faire", "En cours", "À valider", by column then rank.
        #expect(showcase.boardCardHues == [4, 4, 4, 3, 0, 0, 5, 10, 0, 4, 3, 7, 7, 5, 4, 2])
        #expect(showcase.sceneInput().boardCardHues == showcase.boardCardHues)
    }

    @Test func waitingOnlyThePicked() {
        let showcase = Self.showcase
        let live = showcase.liveAgents
        var random = SplitMix64(seed: 0x5EED_0003)
        for _ in 0..<40 {
            let first = live[Int(random.next() % UInt64(live.count))]
            var second = first
            while second == first { second = live[Int(random.next() % UInt64(live.count))] }
            let runtimes = showcase.runtimes(waiting: [first, second])
            #expect(Set(runtimes.keys) == Set(showcase.runtimes.keys))
            let waiting = Set(runtimes.filter { !$0.value.pendingWaits.isEmpty }.map(\.key))
            #expect(waiting == [first, second])
            // Since 5 s for the first pick, 22 s for the second.
            let since = { (id: AgentID) in showcase.now.timeIntervalSince(runtimes[id]!.oldestWait!.since) }
            #expect(since(first) == 5 && since(second) == 22)
            #expect(runtimes.values.allSatisfy { $0.pid != nil || $0.kind == .offline })
        }
        // Nova, Sol and Ivo work instead; the reasons cycle: permission Bash, question, permission Edit, MCP message.
        let picks = ["Tao", "Bip", "Galet", "Brume", "Ada"].map { showcase.agentID(named: $0)! }
        let runtimes = showcase.runtimes(waiting: picks)
        for name in ["Nova", "Sol", "Ivo"] {
            #expect(runtimes[showcase.agentID(named: name)!]?.kind == .working, "\(name)")
        }
        let reasons = picks.map { runtimes[$0]!.oldestWait!.reason }
        guard case .permission(let tool0, _) = reasons[0], tool0 == "Bash" else { Issue.record("\(reasons[0])"); return }
        guard case .question = reasons[1] else { Issue.record("\(reasons[1])"); return }
        guard case .permission(let tool2, _) = reasons[2], tool2 == "Edit" else { Issue.record("\(reasons[2])"); return }
        guard case .elicitation = reasons[3] else { Issue.record("\(reasons[3])"); return }
        guard case .permission(let tool4, _) = reasons[4], tool4 == "Bash" else { Issue.record("\(reasons[4])"); return }
        // The scene shows exactly those waits.
        var trial = showcase
        trial.runtimes = showcase.runtimes(waiting: Array(picks.prefix(2)))
        let waitingNames = trial.sceneInput().agents.values.filter { $0.presentation.kind == .waitingInput }
            .map(\.name).sorted()
        #expect(waitingNames == ["Bip", "Tao"])
    }

    @Test func offlineAgentIsNeverLive() {
        let showcase = Self.showcase
        let kiwi = showcase.agentID(named: "Kiwi")!
        #expect(!showcase.liveAgents.contains(kiwi))
        #expect(showcase.liveAgents.count == 19)
        #expect(Set(showcase.liveAgents).count == 19)
        for id in showcase.liveAgents { #expect(showcase.runtimes[id]?.pid != nil) }
        #expect(showcase.runtimes[kiwi]?.phase == .offline(.closedByUser))
        // Sidebar order: projects in order, desks in order.
        let names = showcase.liveAgents.compactMap { showcase.workspace.agent($0)?.name }
        #expect(names.prefix(5) == ["Nova", "Bip", "Lune", "Oslo", "Zéphyr"])
    }

    @Test func emptyWorkspaceHasNoProject() {
        let empty = Showcase.emptyWorkspace()
        #expect(empty.workspace.projects.isEmpty && empty.workspace.agents.isEmpty)
        #expect(empty.runtimes.isEmpty && empty.extras.isEmpty && empty.liveAgents.isEmpty)
        #expect(empty.board.cards.isEmpty && empty.board.instructions.isEmpty && !empty.board.templates.isEmpty)
        #expect(empty.boardCardHues.isEmpty)
        #expect(empty.now == Showcase.now)
        let scene = empty.sceneInput()
        #expect(scene.agents.isEmpty && scene.projects.isEmpty && scene.layout.islands.isEmpty)
        #expect(empty.agentID(named: "Nova") == nil && empty.projectID(named: "API") == nil)
        #expect(empty.runtimes(waiting: []).isEmpty)
    }

    @Test func deterministic() {
        #expect(Showcase.appWorkspace() == Showcase.appWorkspace())
        #expect(Showcase.emptyWorkspace() == Showcase.emptyWorkspace())
        #expect(Showcase.appWorkspace().sceneInput() == Showcase.appWorkspace().sceneInput())
        let picks = Array(Self.showcase.liveAgents.suffix(2))
        #expect(Self.showcase.runtimes(waiting: picks) == Showcase.appWorkspace().runtimes(waiting: picks))
    }

    @Test func lookupsFindByName() {
        let showcase = Self.showcase
        #expect(showcase.agentID(named: "Nova") == showcase.workspace.agents.first { $0.name == "Nova" }?.id)
        #expect(showcase.agentID(named: "Personne") == nil)
        #expect(showcase.projectID(named: "DOCS") == showcase.workspace.projectsInOrder.last?.id)
        #expect(showcase.cardID(titled: "Page 404").flatMap { showcase.board.card($0)?.column } == .done)
        #expect(showcase.cardID(titled: "Absent") == nil)
    }

    @Test func demoRuntimeShowsTheActivity() {
        let now = Showcase.now + 3_600
        let cases: [(DemoActivity, AgentStateKind)] = [
            (.working(.edit), .working), (.thinking, .thinking), (.idle(minutes: 3), .idle), (.done, .done),
        ]
        for (activity, kind) in cases {
            let runtime = Showcase.demoRuntime(activity, now: now)
            #expect(runtime.kind == kind, "\(activity)")
            #expect(runtime.pid != nil && runtime.pendingWaits.isEmpty && runtime.hookHealth == .healthy)
        }
        let asleep = AgentPresenter.scene(Showcase.demoRuntime(.idle(minutes: 15), now: now), now: now,
                                          agentName: "Tao", projectName: "SITE")
        #expect(asleep.asleep)
        let awake = AgentPresenter.scene(Showcase.demoRuntime(.idle(minutes: 2), now: now), now: now,
                                         agentName: "Tao", projectName: "SITE")
        #expect(!awake.asleep)
        #expect(Showcase.demoRuntime(.working(.bash), now: now).phase == .working(.bash))
    }
}
