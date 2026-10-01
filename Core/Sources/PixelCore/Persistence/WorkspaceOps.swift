import Foundation

/// Commands on projects and agents, and the reducer effects that write to the workspace (proposal 4.2).
/// Pure: dates and identifiers come from the caller. Invariants kept: a live project's slot and annex slots never
/// change and are unique among the slots of live projects (`usedSlots`); a desk index is unique inside its project;
/// agents belong to known projects.
extension Workspace {
    /// Size of `Palette.projectHues`.
    public static let projectHueCount = 10

    // MARK: - Lookups

    public func project(_ id: ProjectID) -> Project? {
        projects.first { $0.id == id }
    }

    public func agent(_ id: AgentID) -> Agent? {
        agents.first { $0.id == id }
    }

    /// Agents of a project, by desk.
    public func agents(in projectID: ProjectID) -> [Agent] {
        agents.filter { $0.projectID == projectID }.sorted { ($0.deskIndex, $0.createdAt) < ($1.deskIndex, $1.createdAt) }
    }

    /// A known project that is not archived.
    public func liveProject(_ id: ProjectID) -> Project? {
        project(id).flatMap { $0.archived ? nil : $0 }
    }

    /// Project of each agent of a live project: the agents a post-it can be given to and whose queue is delivered
    /// (the reducer's `TaskContext.agentProjects`). Agents of archived projects stay in `agents`, and the validator
    /// of `tasks.json` knows them at load, but they are left out here.
    public var liveAgentProjects: [AgentID: ProjectID] {
        let live = Set(projects.filter { !$0.archived }.map(\.id))
        return Dictionary(agents.filter { live.contains($0.projectID) }.map { ($0.id, $0.projectID) }) { first, _ in first }
    }

    /// The agent exists and its project is live.
    public func isLiveAgent(_ id: AgentID) -> Bool {
        agent(id).map { liveProject($0.projectID) != nil } ?? false
    }

    /// Main slots and annex slots of the live projects: what a new project or a new annex never takes.
    public var usedSlots: Set<Int> {
        var slots: Set<Int> = []
        for project in projects where !project.archived {
            slots.insert(project.slot)
            slots.formUnion(project.annexSlots)
        }
        return slots
    }

    /// Live (non-archived) projects in sidebar order (⌘1…⌘9).
    public var projectsInOrder: [Project] {
        projects.filter { !$0.archived }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    // MARK: - Projects

    /// Adds a project for a folder, or returns the live project already open on it (same standardized path).
    /// Slot: the lowest one no live project holds, as its island or an annex (existing islands never move).
    /// Order: after the last live project.
    /// Hue: the given one (clamped to 0...9), otherwise the least used among live projects, lowest on ties.
    /// Name: the folder's name when `nil` or blank. `path` should come from `PathNormalizer.normalize`.
    @discardableResult
    public mutating func addProject(path: String, name: String? = nil, hueIndex: Int? = nil,
                                    defaults: AgentDefaults = AgentDefaults(), id: ProjectID = ProjectID(),
                                    now: Date) -> ProjectID {
        let standardized = PathNormalizer.standardize(path)
        let live = projects.filter { !$0.archived }
        if let existing = live.first(where: { PathNormalizer.standardize($0.path) == standardized }) {
            return existing.id
        }
        let slot = lowestFreeSlot()
        let order = (live.map(\.order).max() ?? -1) + 1
        let hue = hueIndex.map(Workspace.clampedHue) ?? leastUsedHue(among: live)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folderName = standardized.split(separator: "/").last.map(String.init) ?? standardized
        projects.append(Project(id: id, name: trimmedName.isEmpty ? folderName : trimmedName, path: standardized,
                                hueIndex: hue, order: order, slot: slot, defaults: defaults, createdAt: now))
        return id
    }

    @discardableResult
    public mutating func renameProject(_ id: ProjectID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = projects.firstIndex(where: { $0.id == id }), projects[i].name != trimmed else {
            return false
        }
        projects[i].name = trimmed
        return true
    }

    /// The hue is clamped to 0...9.
    @discardableResult
    public mutating func setProjectHue(_ id: ProjectID, to hueIndex: Int) -> Bool {
        let hue = Workspace.clampedHue(hueIndex)
        guard let i = projects.firstIndex(where: { $0.id == id }), projects[i].hueIndex != hue else { return false }
        projects[i].hueIndex = hue
        return true
    }

    /// "Défaut du projet" (template manager, mockup 6(l)): the prompt template a card of the project uses when it
    /// has none (`PromptComposer.resolveTemplate`); `nil` = none. The template is not checked against the board.
    @discardableResult
    public mutating func setProjectTemplate(_ id: ProjectID, to templateID: PromptTemplateID?) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == id }), projects[i].defaults.templateID != templateID else {
            return false
        }
        projects[i].defaults.templateID = templateID
        return true
    }

    /// A template was deleted: no project (archived ones included) keeps it as its default.
    @discardableResult
    public mutating func forgetTemplate(_ templateID: PromptTemplateID) -> Bool {
        var changed = false
        for i in projects.indices where projects[i].defaults.templateID == templateID {
            projects[i].defaults.templateID = nil
            changed = true
        }
        return changed
    }

    /// Moves a live project to position `order` (clamped) in the sidebar and renumbers live projects 0…n-1.
    /// Slots are never touched: the island stays where it is.
    @discardableResult
    public mutating func moveProject(_ id: ProjectID, toOrder order: Int) -> Bool {
        var ordered = projectsInOrder.map(\.id)
        guard let from = ordered.firstIndex(of: id) else { return false }
        ordered.remove(at: from)
        ordered.insert(id, at: min(max(order, 0), ordered.count))
        var changed = false
        for (newOrder, projectID) in ordered.enumerated() {
            guard let i = projects.firstIndex(where: { $0.id == projectID }), projects[i].order != newOrder else { continue }
            projects[i].order = newOrder
            changed = true
        }
        return changed
    }

    /// Archives a project: its slot and its annex slots (emptied) become free for the next projects and annexes.
    /// Its agents are kept.
    @discardableResult
    public mutating func archiveProject(_ id: ProjectID) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == id }), !projects[i].archived else { return false }
        projects[i].archived = true
        projects[i].annexSlots = []
        return true
    }

    // MARK: - Agents

    /// Adds an agent to a live project; `nil` when the project is unknown or archived.
    /// Desk: `deskIndex` nil, the lowest free desk (as before); given, that desk if it is free (≥ 0), else `nil` and
    /// nothing is added (a click on a free desk of the scene, 3.9).
    /// Look: `look` nil, `AgentLook.generated(for: id)`.
    /// Name: generated (unique in the workspace, reproducible from `id`) when `nil` or blank.
    /// Permission mode: the project's default when `nil`. `model == nil` inherits the project's at launch.
    /// Annexes (3.8): allocates an annex slot when the agent's part has none yet, and when its part becomes full (the
    /// next part's free desk): the lowest slot used by no live project and no annex (`usedSlots`). Removing an agent
    /// frees nothing.
    @discardableResult
    public mutating func addAgent(to projectID: ProjectID, name: String? = nil, permissionMode: PermissionMode? = nil,
                                  model: String? = nil, worktree: String? = nil, id: AgentID = AgentID(),
                                  deskIndex: Int? = nil, look: AgentLook? = nil, now: Date) -> AgentID? {
        guard let project = project(projectID), !project.archived else { return nil }
        let usedDesks = Set(agents.filter { $0.projectID == projectID }.map(\.deskIndex))
        let desk: Int
        if let deskIndex {
            guard deskIndex >= 0, !usedDesks.contains(deskIndex) else { return nil }
            desk = deskIndex
        } else {
            var lowest = 0
            while usedDesks.contains(lowest) { lowest += 1 }
            desk = lowest
        }
        let givenName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agentName = givenName.isEmpty
            ? NameGenerator.name(seed: NameGenerator.seed(for: id), avoiding: Set(agents.map(\.name)))
            : givenName
        agents.append(Agent(id: id, projectID: projectID, name: agentName, deskIndex: desk,
                            look: look ?? AgentLook.generated(for: id), model: Workspace.nonBlank(model),
                            permissionMode: permissionMode ?? project.defaults.permissionMode,
                            worktree: Workspace.nonBlank(worktree), createdAt: now))

        let perIsland = max(1, LayoutConfig.standard.desksPerIsland)
        let part = desk / perIsland
        let inPart = usedDesks.filter { $0 >= 0 && $0 / perIsland == part }.count + 1
        reserveAnnexSlots(of: projectID, throughPart: inPart >= perIsland ? part + 1 : part)
        return id
    }

    @discardableResult
    public mutating func removeAgent(_ id: AgentID) -> Bool {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return false }
        agents.remove(at: i)
        return true
    }

    @discardableResult
    public mutating func renameAgent(_ id: AgentID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = agents.firstIndex(where: { $0.id == id }), agents[i].name != trimmed else {
            return false
        }
        agents[i].name = trimmed
        return true
    }

    // MARK: - Reducer effects

    /// Applies an `AgentStateMachine` effect that writes to the workspace (proposal 4.2: `recordSession`,
    /// `endSession`, `updateSessionCwd`, `recordProcess`, `setQueuePaused`). Returns `true` when the workspace
    /// changed (the caller schedules a save); `false` for other effects, an unknown agent or session, or no change.
    ///
    /// `recordSession` appends a new session id. For a known id (resumed, compacted), the reference is updated
    /// (non-empty `cwd`, non-nil `transcriptPath` / `model`), marked live again (`endedAt` cleared) and moved last,
    /// since the resume target is `sessions.last`.
    ///
    /// `updateSessionCwd` (`CwdChanged`) only moves the resume folder back to the project folder, as when the agent
    /// leaves a worktree. `CwdChanged` also fires for a plain `cd` of the agent's Bash tool, which does not move the
    /// session: resuming there would load another folder's settings and permissions. And `--resume` finds a session
    /// from any folder and returns it to its Claude Code worktree by itself (sessions.md, worktrees.md), whereas a
    /// recorded worktree that is later removed would make the app start a new conversation instead.
    @discardableResult
    public mutating func apply(_ effect: AgentEffect, agent id: AgentID) -> Bool {
        guard let a = agents.firstIndex(where: { $0.id == id }) else { return false }
        var agent = agents[a]
        switch effect {
        case .recordSession(let ref):
            if let s = agent.sessions.lastIndex(where: { $0.sessionID == ref.sessionID }) {
                var existing = agent.sessions.remove(at: s)
                if !ref.cwd.isEmpty { existing.cwd = ref.cwd }
                if let path = ref.transcriptPath { existing.transcriptPath = path }
                if let model = ref.model { existing.model = model }
                existing.endedAt = nil
                existing.endReason = nil
                agent.sessions.append(existing)
            } else {
                agent.sessions.append(ref)
            }
        case .endSession(let sessionID, let reason, let at):
            guard let s = agent.sessions.lastIndex(where: { $0.sessionID == sessionID }) else { return false }
            agent.sessions[s].endedAt = at
            agent.sessions[s].endReason = reason
        case .updateSessionCwd(let sessionID, let cwd):
            guard !cwd.isEmpty, let s = agent.sessions.lastIndex(where: { $0.sessionID == sessionID }),
                  let projectPath = project(agent.projectID)?.path,
                  PathNormalizer.standardize(cwd) == PathNormalizer.standardize(projectPath) else { return false }
            agent.sessions[s].cwd = projectPath
        case .recordProcess(let stamp):
            agent.lastProcess = stamp
        case .setQueuePaused(let paused):
            agent.queuePaused = paused
        default:
            return false
        }
        guard agent != agents[a] else { return false }
        agents[a] = agent
        return true
    }

    // MARK: - Slots

    /// The lowest slot ≥ 0 that is not in `usedSlots`.
    func lowestFreeSlot() -> Int {
        let used = usedSlots
        var slot = 0
        while used.contains(slot) { slot += 1 }
        return slot
    }

    /// Gives parts 1 … `part` of a live project a slot each when they have none yet: `lowestFreeSlot()`, part by part.
    mutating func reserveAnnexSlots(of projectID: ProjectID, throughPart part: Int) {
        guard let i = projects.firstIndex(where: { $0.id == projectID }), !projects[i].archived else { return }
        while projects[i].annexSlots.count < part {
            projects[i].annexSlots.append(lowestFreeSlot())
        }
    }

    /// Persists the slot of every annex the layout shows without one (a file of version 1, or a repaired one): the
    /// slot it is shown in, so that nothing moves afterwards; a part before it that is not shown and has no slot gets
    /// the lowest slot that is neither used nor shown. The layout is the same before and after. Returns the shown
    /// parts it persisted, projects by slot, then part.
    @discardableResult
    mutating func persistShownAnnexSlots(config: LayoutConfig = .standard)
        -> [(projectID: ProjectID, part: Int, slot: Int)] {
        let layout = WorldLayout.compute(WorldInput(workspace: self, config: config))
        var shown: [ProjectID: [Int: Int]] = [:]
        for island in layout.islands where island.part > 0 {
            guard let project = liveProject(island.projectID), island.part > project.annexSlots.count else { continue }
            shown[island.projectID, default: [:]][island.part] = island.slot
        }
        guard !shown.isEmpty else { return [] }
        let pending = Set(shown.values.flatMap(\.values))
        let order = projects.indices.filter { !projects[$0].archived && shown[projects[$0].id] != nil }
            .sorted { (projects[$0].slot, projects[$0].id) < (projects[$1].slot, projects[$1].id) }
        var persisted: [(projectID: ProjectID, part: Int, slot: Int)] = []
        for i in order {
            let parts = shown[projects[i].id] ?? [:]
            let top = parts.keys.max() ?? 0
            while projects[i].annexSlots.count < top {
                let part = projects[i].annexSlots.count + 1
                if let slot = parts[part] {
                    projects[i].annexSlots.append(slot)
                    persisted.append((projects[i].id, part, slot))
                } else {
                    let used = usedSlots
                    var slot = 0
                    while used.contains(slot) || pending.contains(slot) { slot += 1 }
                    projects[i].annexSlots.append(slot)
                }
            }
        }
        return persisted
    }

    // MARK: - Helpers

    static func clampedHue(_ hue: Int) -> Int {
        min(max(hue, 0), projectHueCount - 1)
    }

    private func leastUsedHue(among live: [Project]) -> Int {
        var counts = [Int](repeating: 0, count: Workspace.projectHueCount)
        for p in live { counts[Workspace.clampedHue(p.hueIndex)] += 1 }
        let fewest = counts.min() ?? 0
        return counts.firstIndex(of: fewest) ?? 0
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
