import Foundation

/// The demonstration scenes of the visual milestone (section 8): one 8-desk island of the project "API" in two
/// casts that, together, show every state of an agent, and the overview of mockup 6(q), 20 agents on 6 projects.
/// Built like the app will build them: a real `Workspace` (`addProject`, `addAgent`), runtimes, `SceneInput.make`.
/// Fixed identifiers and dates: the same scenes on every run and every platform.
public enum Showcase {
    /// 2026-10-01 09:00 UTC.
    public static let now = Date(timeIntervalSince1970: 1_790_845_200)

    /// The 2 casts of the island (décision 13), same project, same 8-desk island; each leaves one desk free.
    public static func islandCasts() -> [SceneInput] {
        [scene(projects: [islandProject(casts[0])], startID: 0x11), scene(projects: [islandProject(casts[1])], startID: 0x21)]
    }

    /// Slot 0: the island and its ring of corridor.
    public static func islandCrop() -> GridRect {
        WorldLayout.slotRect(column: 0, row: 0, config: .standard)
    }

    /// Both casts rendered at 1 texel per pixel, stacked with a PixelFont caption above each, then scaled.
    public static func islandSheet(zoom: SceneZoom, night: Bool) -> PixelImage {
        let crop = islandCrop()
        var parts: [PixelImage] = []
        for (cast, caption) in zip(islandCasts(), captions) {
            let scene = SceneCompositor.render(cast, options: RenderOptions(zoom: .x1, night: night, crop: crop))
            parts.append(captionBand(caption, width: scene.width))
            parts.append(scene)
        }
        return PixelImage.stacked(parts, axis: .vertical, spacing: 0).scaled(by: zoom.pixelsPerTexel)
    }

    /// Mockup 6(q): API, INFRA, SITE, DATA, MOBILE and DOCS in slots 0 to 5, 3 agents waiting, 12 post-its on the
    /// cork wall.
    public static func overview() -> SceneInput {
        scene(projects: overviewProjects, startID: 0x31, boardCardHues: [4, 4, 3, 0, 5, 7, 4, 2, 3, 10, 0, 5])
    }

    /// The whole world at the overview zoom (1 pixel per texel).
    public static func overviewImage(night: Bool) -> PixelImage {
        SceneCompositor.render(overview(), options: RenderOptions(zoom: .overview, night: night))
    }

    // MARK: Cast

    /// What an agent of a demonstration scene is doing.
    enum Activity {
        case waiting(WaitReason, secondsAgo: TimeInterval)
        case working(ToolKind, subagents: Int = 0)
        case thinking(stale: Bool = false, degraded: Bool = false)
        case done
        case error(AgentError)
        case idle(minutes: Int, draft: String? = nil)
        case offline(OfflineReason)
        case background
        case quota(resumeInMinutes: Int)
        case launching
    }

    struct Member {
        var name: String
        var activity: Activity
        var extras = AgentExtras()
        var permissionMode = PermissionMode.default
    }

    struct DemoProject {
        var name: String
        var hue: Int
        /// By desk index; nil leaves the desk free.
        var members: [Member?]
    }

    static let question = AskedQuestion(header: "Base", question: "Quelle base de données pour les tests ?",
                                        options: ["SQLite", "PostgreSQL"], multiSelect: false)

    /// The two casts of the island, desk by desk (row A: even desks, front; row B: odd desks, back).
    static let casts: [[Member?]] = [
        [
            Member(name: "Nova", activity: .waiting(.permission(tool: "Bash", summary: "rm -rf dist"), secondsAgo: 42),
                   extras: AgentExtras(queued: 1)),
            Member(name: "Bip", activity: .working(.bash, subagents: 2)),
            Member(name: "Lune", activity: .thinking()),
            Member(name: "Oslo", activity: .done),
            Member(name: "Zéphyr", activity: .error(.api("overloaded"))),
            Member(name: "Tao", activity: .idle(minutes: 12)),
            Member(name: "Kiwi", activity: .offline(.closedByUser)),
            nil,
        ],
        [
            Member(name: "Pixou", activity: .working(.edit), extras: AgentExtras(queued: 2, cardOnScreenHue: 1)),
            Member(name: "Sol", activity: .waiting(.question([question]), secondsAgo: 130)),
            Member(name: "Mika", activity: .background),
            Member(name: "Rio", activity: .quota(resumeInMinutes: 40)),
            Member(name: "Lou", activity: .launching),
            Member(name: "Plume", activity: .thinking(stale: true, degraded: true)),
            nil,
            Member(name: "Galet", activity: .idle(minutes: 2, draft: "ajoute un test"), permissionMode: .bypassPermissions),
        ],
    ]

    static let captions = [
        "DISTRIBUTION 1 : ATTENTE, TRAVAIL, RÉFLEXION, FINI, ERREUR, ENDORMI, HORS LIGNE, POSTE LIBRE",
        "DISTRIBUTION 2 : TRAVAIL, QUESTION, TÂCHE DE FOND, LIMITE D'USAGE, DÉMARRAGE, SANS NOUVELLES, POSTE LIBRE, BROUILLON",
    ]

    static func islandProject(_ members: [Member?]) -> DemoProject {
        DemoProject(name: "API", hue: 4, members: members)
    }

    static let overviewProjects: [DemoProject] = [
        DemoProject(name: "API", hue: 4, members: [
            Member(name: "Nova", activity: .waiting(.permission(tool: "Bash", summary: "rm -rf dist"), secondsAgo: 42),
                   extras: AgentExtras(queued: 1)),
            Member(name: "Bip", activity: .working(.bash, subagents: 2)),
            Member(name: "Lune", activity: .thinking()),
            Member(name: "Kiwi", activity: .working(.read)),
            Member(name: "Oslo", activity: .done),
        ]),
        DemoProject(name: "INFRA", hue: 3, members: [
            Member(name: "Zéphyr", activity: .error(.api("overloaded"))),
            Member(name: "Ada", activity: .working(.edit)),
            Member(name: "Rio", activity: .idle(minutes: 4)),
            Member(name: "Sol", activity: .waiting(.question([question]), secondsAgo: 130)),
        ]),
        DemoProject(name: "SITE", hue: 0, members: [
            Member(name: "Pixou", activity: .working(.edit)),
            Member(name: "Tao", activity: .idle(minutes: 12)),
            Member(name: "Mika", activity: .done),
        ]),
        DemoProject(name: "DATA", hue: 5, members: [
            Member(name: "Plume", activity: .working(.search)),
            Member(name: "Galet", activity: .working(.web)),
            Member(name: "Brume", activity: .thinking()),
        ]),
        DemoProject(name: "MOBILE", hue: 7, members: [
            Member(name: "Comète", activity: .working(.subagent, subagents: 1)),
            Member(name: "Nuage", activity: .idle(minutes: 6)),
            Member(name: "Pépin", activity: .working(.mcp("notes"))),
        ]),
        DemoProject(name: "DOCS", hue: 2, members: [
            Member(name: "Ivo", activity: .waiting(.permission(tool: "Edit", summary: "README.md"), secondsAgo: 5)),
            Member(name: "Cajou", activity: .working(.bash)),
        ]),
    ]

    /// Looks fixed by hand (décision 12): every skin, the six haircuts, glasses (1), headphones (2) and beanie (3);
    /// `outfitPaletteIndex` nil wears the project's hue. The same name has the same look in every scene.
    static let looks: [String: AgentLook] = [
        "Nova": AgentLook(skin: 0, hairStyle: 1, hairColor: 5, outfitPaletteIndex: nil, accessory: 1),
        "Bip": AgentLook(skin: 2, hairStyle: 3, hairColor: 0, outfitPaletteIndex: 12, accessory: 2),
        "Lune": AgentLook(skin: 1, hairStyle: 4, hairColor: 2, outfitPaletteIndex: 10, accessory: nil),
        "Oslo": AgentLook(skin: 3, hairStyle: 0, hairColor: 0, outfitPaletteIndex: 13, accessory: 3),
        "Zéphyr": AgentLook(skin: 0, hairStyle: 2, hairColor: 3, outfitPaletteIndex: 14, accessory: nil),
        "Tao": AgentLook(skin: 2, hairStyle: 5, hairColor: 1, outfitPaletteIndex: 11, accessory: nil),
        "Kiwi": AgentLook(skin: 1, hairStyle: 0, hairColor: 4, outfitPaletteIndex: nil, accessory: 2),
        "Pixou": AgentLook(skin: 3, hairStyle: 1, hairColor: 6, outfitPaletteIndex: 15, accessory: 1),
        "Sol": AgentLook(skin: 0, hairStyle: 3, hairColor: 2, outfitPaletteIndex: nil, accessory: 3),
        "Mika": AgentLook(skin: 2, hairStyle: 4, hairColor: 7, outfitPaletteIndex: 10, accessory: 2),
        "Rio": AgentLook(skin: 1, hairStyle: 2, hairColor: 0, outfitPaletteIndex: 12, accessory: nil),
        "Lou": AgentLook(skin: 3, hairStyle: 5, hairColor: 3, outfitPaletteIndex: nil, accessory: nil),
        "Plume": AgentLook(skin: 0, hairStyle: 0, hairColor: 1, outfitPaletteIndex: 14, accessory: 1),
        "Galet": AgentLook(skin: 2, hairStyle: 1, hairColor: 4, outfitPaletteIndex: 11, accessory: 2),
        "Ada": AgentLook(skin: 1, hairStyle: 3, hairColor: 7, outfitPaletteIndex: 13, accessory: nil),
        "Brume": AgentLook(skin: 3, hairStyle: 4, hairColor: 4, outfitPaletteIndex: nil, accessory: 1),
        "Comète": AgentLook(skin: 0, hairStyle: 5, hairColor: 6, outfitPaletteIndex: 10, accessory: 2),
        "Nuage": AgentLook(skin: 2, hairStyle: 2, hairColor: 2, outfitPaletteIndex: nil, accessory: 3),
        "Pépin": AgentLook(skin: 1, hairStyle: 1, hairColor: 0, outfitPaletteIndex: 15, accessory: nil),
        "Ivo": AgentLook(skin: 3, hairStyle: 3, hairColor: 1, outfitPaletteIndex: 12, accessory: 1),
        "Cajou": AgentLook(skin: 0, hairStyle: 4, hairColor: 3, outfitPaletteIndex: nil, accessory: nil),
    ]

    // MARK: Building

    /// "00000000-0000-0000-0000-0000000000NN".
    static func uuid(_ n: Int) -> UUID {
        let hex = String(n, radix: 16, uppercase: true)
        return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - hex.count) + hex)!
    }

    /// Projects created in order (slots 0, 1, …), agents added desk by desk; a free desk gets a placeholder agent,
    /// removed afterwards, so that the agents after it keep their desk.
    static func scene(projects: [DemoProject], startID: Int, boardCardHues: [Int] = []) -> SceneInput {
        var workspace = Workspace()
        var runtimes: [AgentID: AgentRuntime] = [:]
        var extras: [AgentID: AgentExtras] = [:]
        var placeholders: [AgentID] = []
        var next = startID
        for (index, project) in projects.enumerated() {
            let projectID = workspace.addProject(path: "/projets/\(project.name.lowercased())", name: project.name,
                                                 hueIndex: project.hue, id: ProjectID(uuid(1 + index)),
                                                 now: now - 172_800 + Double(index) * 60)
            for member in project.members {
                let id = AgentID(uuid(next))
                next += 1
                let created = now - 86_400 + Double(next) * 60
                guard let member else {
                    _ = workspace.addAgent(to: projectID, name: "-", id: id, now: created)
                    placeholders.append(id)
                    continue
                }
                _ = workspace.addAgent(to: projectID, name: member.name, permissionMode: member.permissionMode, id: id,
                                       now: created)
                if let look = looks[member.name], let i = workspace.agents.firstIndex(where: { $0.id == id }) {
                    workspace.agents[i].look = look
                }
                runtimes[id] = runtime(member.activity)
                extras[id] = member.extras
            }
        }
        for id in placeholders { workspace.removeAgent(id) }
        return SceneInput.make(workspace: workspace, runtimes: runtimes, extras: extras, boardCardHues: boardCardHues,
                               now: now)
    }

    /// The runtime of a live (or offline) agent in that activity, as the state machine would leave it.
    static func runtime(_ activity: Activity) -> AgentRuntime {
        func live(_ phase: AgentPhase, since seconds: TimeInterval = 90) -> AgentRuntime {
            var r = AgentRuntime(phase: phase, phaseSince: now - seconds)
            r.pid = 40_000
            r.hookHealth = .healthy
            r.currentSessionID = "session-demo"
            return r
        }
        switch activity {
        case .waiting(let reason, let ago):
            let tool: ToolKind
            if case .permission(let name, _) = reason { tool = ToolKind.from(toolName: name) } else { tool = .question }
            var r = live(.working(tool), since: ago + 20)
            r.pendingWaits[.tool(toolUseID: "toolu_demo")] = PendingWait(reason: reason, subagentID: nil, since: now - ago)
            return r
        case .working(let tool, let subagents):
            var r = live(.working(tool))
            r.activeSubagentIDs = Set((0..<subagents).map { "subagent-\($0 + 1)" })
            return r
        case .thinking(let stale, let degraded):
            var r = live(.thinking)
            r.stale = stale
            if degraded { r.hookHealth = .degraded }
            return r
        case .done:
            return live(.done, since: 30)
        case .error(let error):
            return live(.error(error), since: 60)
        case .idle(let minutes, let draft):
            var r = live(.idle, since: TimeInterval(minutes * 60))
            if let draft { r.screen = ScreenFacts(inputBox: .draft(prefix: draft), recognized: true) }
            return r
        case .offline(let reason):
            return AgentRuntime(phase: .offline(reason), phaseSince: now - 3_600)
        case .background:
            return live(.waitingBackground(tasks: 1, crons: 0), since: 300)
        case .quota(let minutes):
            return live(.quotaPaused(resetAt: now + TimeInterval(minutes * 60), autoResume: true), since: 600)
        case .launching:
            var r = live(.launching, since: 3)
            r.hookHealth = .unknown(since: now - 3)
            return r
        }
    }

    /// The caption on a paper band (ink text, 4 px of margin), at least `width` wide.
    static func captionBand(_ text: String, width: Int) -> PixelImage {
        let glyphs = PixelFont.render(text, color: Palette.color(.ink))
        let margin = 4
        var band = PixelImage(width: max(width, glyphs.width + 2 * margin), height: glyphs.height + 2 * margin,
                              fill: Palette.color(.paper))
        band.blit(glyphs, x: margin, y: margin)
        return band
    }
}
