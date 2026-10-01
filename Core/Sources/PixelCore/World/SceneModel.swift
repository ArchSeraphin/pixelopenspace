import Foundation

// What the software compositor draws (3.10): the layout, the look of each project and agent, and how to render.

/// The zoom levels of the scene at rest (7.3). The overview draws 1 pixel per texel, shown at 0.5 pt per texel on a
/// Retina screen; ×1, ×2 and ×3 draw k pixels per texel, the nearest-neighbour upscale of ×1.
public enum SceneZoom: Int, CaseIterable, Sendable {
    case overview = 0, x1 = 1, x2 = 2, x3 = 3

    /// overview 1 (shown at 0.5 pt per texel), else rawValue.
    public var pixelsPerTexel: Int { self == .overview ? 1 : rawValue }
}

public struct RenderOptions: Hashable, Sendable {
    public var zoom: SceneZoom
    public var night: Bool
    /// Animation clock (24 ticks per second); 0 shows frame 0 everywhere (the key poses).
    public var tick: Int
    /// nil: the whole world with its walls; otherwise only the tiles inside, without walls.
    public var crop: GridRect?
    /// Night veil at 0.35 instead of 0.55 (Reduce Transparency, Increase Contrast).
    public var reduceTransparency: Bool

    public init(zoom: SceneZoom = .x1, night: Bool = false, tick: Int = 0, crop: GridRect? = nil,
                reduceTransparency: Bool = false) {
        self.zoom = zoom
        self.night = night
        self.tick = tick
        self.crop = crop
        self.reduceTransparency = reduceTransparency
    }
}

/// What the scene shows of a project: the sign's name and the hue of its carpet, chairs and minis.
public struct ProjectVisual: Hashable, Sendable {
    public var name: String
    public var hueIndex: Int

    public init(name: String, hueIndex: Int) {
        self.name = name
        self.hueIndex = hueIndex
    }
}

/// Post-its around an agent (step 2b): the queue on the desk and the card stuck on the monitor.
public struct AgentExtras: Hashable, Sendable {
    /// Post-its in the queue: `desk.queue` (1 to 3 sheets) and its badge.
    public var queued: Int
    /// Post-it stuck on the monitor: hue 0…9, 10 = paper.
    public var cardOnScreenHue: Int?

    public init(queued: Int = 0, cardOnScreenHue: Int? = nil) {
        self.queued = queued
        self.cardOnScreenHue = cardOnScreenHue
    }
}

public struct SceneAgent: Equatable, Sendable {
    public var name: String
    public var look: AgentLook
    public var presentation: AgentPresentation
    public var extras: AgentExtras

    public init(name: String, look: AgentLook, presentation: AgentPresentation, extras: AgentExtras = .init()) {
        self.name = name
        self.look = look
        self.presentation = presentation
        self.extras = extras
    }
}

public struct SceneInput: Equatable, Sendable {
    public var layout: WorldLayoutResult
    public var projects: [ProjectID: ProjectVisual]
    public var agents: [AgentID: SceneAgent]
    /// Mini post-its of the cork wall, in order (hue 0…9, 10 = paper): 48 shown, then a "+n" counter.
    public var boardCardHues: [Int]
    /// `ov.selection` under its seat.
    public var selectedAgent: AgentID?
    /// An agent: its name plate; a free desk: `floor.hover` on its desk and seat.
    public var hovered: SceneHitTarget?
    /// An agent: `floor.dropTarget` on its seat; a free desk: on its desk and seat; an island (its floor or its
    /// sign): `floor.hover` on every tile of its rug.
    public var dropTarget: SceneHitTarget?
    /// Left out of the scene, leaving only the chair: the avatar, its shadow, its minis, its overlays and plate
    /// (an agent walking from the elevator to its desk).
    public var hiddenAgents: Set<AgentID>

    /// The interaction fields default to nothing: the scene draws exactly what it drew without them.
    public init(layout: WorldLayoutResult, projects: [ProjectID: ProjectVisual], agents: [AgentID: SceneAgent],
                boardCardHues: [Int] = [], selectedAgent: AgentID? = nil, hovered: SceneHitTarget? = nil,
                dropTarget: SceneHitTarget? = nil, hiddenAgents: Set<AgentID> = []) {
        self.layout = layout
        self.projects = projects
        self.agents = agents
        self.boardCardHues = boardCardHues
        self.selectedAgent = selectedAgent
        self.hovered = hovered
        self.dropTarget = dropTarget
        self.hiddenAgents = hiddenAgents
    }

    /// Layout by `WorldLayout.compute`, presentations by `AgentPresenter.scene` (no runtime → offline(.notStarted)),
    /// permission mode from each `Agent`. Agents of archived projects are left out, like their islands.
    public static func make(workspace: Workspace, runtimes: [AgentID: AgentRuntime], extras: [AgentID: AgentExtras] = [:],
                            boardCardHues: [Int] = [], now: Date, reduceMotion: Bool = false) -> SceneInput {
        let layout = WorldLayout.compute(WorldInput(workspace: workspace))
        var projects: [ProjectID: ProjectVisual] = [:]
        for project in workspace.projects where !project.archived {
            projects[project.id] = ProjectVisual(name: project.name, hueIndex: project.hueIndex)
        }
        var agents: [AgentID: SceneAgent] = [:]
        for agent in workspace.agents {
            guard let project = workspace.liveProject(agent.projectID) else { continue }
            let runtime = runtimes[agent.id] ?? AgentRuntime(phase: .offline(.notStarted), phaseSince: now)
            let options = ScenePresentationOptions(reduceMotion: reduceMotion, permissionMode: agent.permissionMode)
            let presentation = AgentPresenter.scene(runtime, now: now, agentName: agent.name, projectName: project.name,
                                                    options: options)
            agents[agent.id] = SceneAgent(name: agent.name, look: agent.look, presentation: presentation,
                                          extras: extras[agent.id] ?? AgentExtras())
        }
        return SceneInput(layout: layout, projects: projects, agents: agents, boardCardHues: boardCardHues)
    }
}

extension SceneInput {
    /// The paper post-it (`postit.mini~paper`, `desk.postit~paper`): a card without project.
    public static let paperHue = 10

    /// The columns whose cards the cork wall shows: "À faire", "En cours", "À valider".
    public static let corkWallColumns: [Column] = [.todo, .inProgress, .review]

    /// Layout, presentations and post-its from the board: queued = cards in the agent's queue (instructions do not
    /// count), cardOnScreenHue = hue of the project of its current card (10 without project), boardCardHues = cards
    /// of "À faire", "En cours", "À valider" by column then rank. A card whose project is not in the workspace is
    /// paper too. The interaction fields are passed through.
    public static func make(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState, now: Date,
                            reduceMotion: Bool = false, selectedAgent: AgentID? = nil, hovered: SceneHitTarget? = nil,
                            dropTarget: SceneHitTarget? = nil, hiddenAgents: Set<AgentID> = []) -> SceneInput {
        var hues: [ProjectID: Int] = [:]
        for project in workspace.projects { hues[project.id] = project.hueIndex }
        func hue(_ card: TaskCard) -> Int { card.projectID.flatMap { hues[$0] } ?? paperHue }

        var extras: [AgentID: AgentExtras] = [:]
        for agent in workspace.agents {
            let queued = BoardQuery.queue(of: agent.id, in: board).filter {
                if case .card = $0 { return true }
                return false
            }.count
            let onScreen = BoardQuery.currentCard(of: agent.id, in: board).map(hue)
            if queued > 0 || onScreen != nil { extras[agent.id] = AgentExtras(queued: queued, cardOnScreenHue: onScreen) }
        }
        let boardCardHues = corkWallColumns.flatMap { board.cards(in: $0).map(hue) }
        var scene = make(workspace: workspace, runtimes: runtimes, extras: extras, boardCardHues: boardCardHues,
                         now: now, reduceMotion: reduceMotion)
        scene.selectedAgent = selectedAgent
        scene.hovered = hovered
        scene.dropTarget = dropTarget
        scene.hiddenAgents = hiddenAgents
        return scene
    }
}
