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

    public init(layout: WorldLayoutResult, projects: [ProjectID: ProjectVisual], agents: [AgentID: SceneAgent],
                boardCardHues: [Int] = []) {
        self.layout = layout
        self.projects = projects
        self.agents = agents
        self.boardCardHues = boardCardHues
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
