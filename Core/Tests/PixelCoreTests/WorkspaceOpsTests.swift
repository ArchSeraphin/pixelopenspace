import Foundation
import Testing
@testable import PixelCore

@Suite struct WorkspaceOpsTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func agentID(_ n: UInt8) -> AgentID {
        AgentID(UUID(uuid: (n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)))
    }

    // MARK: - Projects

    @Test func addProjectAssignsSlotOrderHueAndName() {
        var w = Workspace()
        let a = w.addProject(path: "/Users/seraphin/Projets/api/", now: Self.t0)
        let b = w.addProject(path: "/Users/seraphin/Projets/pixel demo", name: "  Démo  ", now: Self.t0)
        let pa = w.project(a)!
        let pb = w.project(b)!
        #expect(pa.path == "/Users/seraphin/Projets/api")
        #expect(pa.name == "api")
        #expect([pa.slot, pa.order, pa.hueIndex] == [0, 0, 0] as [Int])
        #expect(pb.name == "Démo")
        #expect([pb.slot, pb.order, pb.hueIndex] == [1, 1, 1] as [Int])
        #expect(pa.createdAt == Self.t0 && !pa.archived)
    }

    @Test func samePathReturnsTheExistingProject() {
        var w = Workspace()
        let a = w.addProject(path: "/Users/seraphin/Projets/api", now: Self.t0)
        let existing = w.addProject(path: "/Users/seraphin//Projets/./api/", name: "Autre", now: Self.t0)
        #expect(existing == a)
        #expect(w.projects.count == 1)
        w.archiveProject(a)
        let again = w.addProject(path: "/Users/seraphin/Projets/api", now: Self.t0)
        #expect(again != a)
        #expect(w.projects.count == 2)
        #expect(w.project(again)!.slot == 0)
    }

    @Test func addingAProjectNeverChangesExistingSlots() {
        var w = Workspace()
        var ids: [ProjectID] = []
        for i in 0..<6 { ids.append(w.addProject(path: "/p/\(i)", now: Self.t0)) }
        w.archiveProject(ids[1])
        w.archiveProject(ids[3])
        w.moveProject(ids[5], toOrder: 0)
        let before = Dictionary(uniqueKeysWithValues: w.projects.map { ($0.id, $0.slot) })
        let x = w.addProject(path: "/p/x", now: Self.t0)
        let y = w.addProject(path: "/p/y", now: Self.t0)
        let z = w.addProject(path: "/p/z", now: Self.t0)
        for (id, slot) in before { #expect(w.project(id)!.slot == slot) }
        // Freed slots are reused lowest first, then the grid grows.
        #expect([w.project(x)!.slot, w.project(y)!.slot, w.project(z)!.slot] == [1, 3, 6] as [Int])
        let live = w.projects.filter { !$0.archived }
        #expect(Set(live.map(\.slot)).count == live.count)
    }

    @Test func hueIsLeastUsedLowestFirst() {
        var w = Workspace()
        for i in 0..<10 { w.addProject(path: "/p/\(i)", now: Self.t0) }
        #expect(w.projects.map(\.hueIndex) == Array(0..<10))
        let eleventh = w.addProject(path: "/p/10", now: Self.t0)
        #expect(w.project(eleventh)!.hueIndex == 0)
        // Hue 3 is now unused: it is the least used.
        w.setProjectHue(w.projects[3].id, to: 0)
        let next = w.addProject(path: "/p/11", now: Self.t0)
        #expect(w.project(next)!.hueIndex == 3)
        // Archived projects do not count.
        w.archiveProject(w.projects[5].id)
        let afterArchive = w.addProject(path: "/p/13", now: Self.t0)
        #expect(w.project(afterArchive)!.hueIndex == 5)
        let explicit = w.addProject(path: "/p/12", hueIndex: 42, now: Self.t0)
        #expect(w.project(explicit)!.hueIndex == 9)
    }

    @Test func moveProjectRenumbersOrdersButNeverSlots() {
        var w = Workspace()
        let ids = (0..<4).map { w.addProject(path: "/p/\($0)", now: Self.t0) }
        let slots = w.projects.map(\.slot)
        let moved = w.moveProject(ids[3], toOrder: 0)
        #expect(moved)
        #expect(w.projectsInOrder.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
        #expect(w.projectsInOrder.map(\.order) == [0, 1, 2, 3])
        #expect(w.projects.map(\.slot) == slots)
        let moved2 = w.moveProject(ids[3], toOrder: 99)
        #expect(moved2)
        #expect(w.projectsInOrder.map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
        let moved3 = w.moveProject(ids[3], toOrder: 3)
        #expect(!moved3)
        let moved4 = w.moveProject(ProjectID(), toOrder: 0)
        #expect(!moved4)
    }

    @Test func archivedProjectsLeaveTheSidebar() {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", now: Self.t0)
        let b = w.addProject(path: "/p/b", now: Self.t0)
        let archived = w.archiveProject(a)
        #expect(archived)
        let archived2 = w.archiveProject(a)
        #expect(!archived2)
        #expect(w.projectsInOrder.map(\.id) == [b])
        let added = w.addAgent(to: a, now: Self.t0)
        #expect(added == nil)
        let c = w.addProject(path: "/p/c", now: Self.t0)
        #expect(w.project(c)!.order == 2)
        #expect(w.project(c)!.slot == 0)
    }

    /// Agents of an archived project stay in the workspace (the validator of `tasks.json` knows them at load),
    /// but they are neither assignees nor delivered to: the reducer's context and the dispatcher see live agents only.
    @Test func liveAgentsLeaveOutArchivedProjects() throws {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", now: Self.t0)
        let b = w.addProject(path: "/p/b", now: Self.t0)
        let addedA = w.addAgent(to: a, now: Self.t0)
        let a0 = try #require(addedA)
        let addedB = w.addAgent(to: b, now: Self.t0)
        let b0 = try #require(addedB)
        #expect(w.liveAgentProjects == [a0: a, b0: b])
        w.archiveProject(b)
        #expect(w.liveAgentProjects == [a0: a])
        #expect(w.isLiveAgent(a0))
        #expect(!w.isLiveAgent(b0))
        #expect(!w.isLiveAgent(Self.agentID(9)))
        #expect(w.liveProject(a)?.id == a)
        #expect(w.liveProject(b) == nil)
        #expect(w.liveProject(ProjectID()) == nil)
        #expect(Set(w.agents.map(\.id)) == [a0, b0])
    }

    /// The reducer refuses to give a card to an agent missing from its context (an archived project's).
    @Test func archivedProjectAgentIsNotAnAssignee() throws {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", now: Self.t0)
        let addedA = w.addAgent(to: a, now: Self.t0)
        let a0 = try #require(addedA)
        w.archiveProject(a)
        let card = TaskCardID()
        let context = TaskContext(now: Self.t0, agentProjects: w.liveAgentProjects, liveAgents: [])
        let (board, _) = TaskLifecycle.reduce(TaskBoardState(), .create(id: card, title: "Pagination", details: "",
                                                                         projectID: a, priority: .normal, tags: [],
                                                                         templateID: nil), context: context)
        let (after, effects) = TaskLifecycle.reduce(board, .assign(card, to: a0), context: context)
        #expect(after == board)
        #expect(effects.count == 1)
        #expect(effects.allSatisfy { if case .rejected(.unknownAgent, _) = $0 { return true } else { return false } })
    }

    @Test func renameAndHue() {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", now: Self.t0)
        let renamed = w.renameProject(a, to: "  API  ")
        #expect(renamed)
        #expect(w.project(a)!.name == "API")
        let renamed2 = w.renameProject(a, to: "   ")
        #expect(!renamed2)
        let renamed3 = w.renameProject(a, to: "API")
        #expect(!renamed3)
        let renamed4 = w.renameProject(ProjectID(), to: "X")
        #expect(!renamed4)
        let hueChanged = w.setProjectHue(a, to: 12)
        #expect(hueChanged)
        #expect(w.project(a)!.hueIndex == 9)
        let hueChanged2 = w.setProjectHue(a, to: -3)
        #expect(hueChanged2)
        #expect(w.project(a)!.hueIndex == 0)
        let hueChanged3 = w.setProjectHue(a, to: 0)
        #expect(!hueChanged3)
    }

    @Test func projectDefaultTemplate() {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", now: Self.t0)
        let b = w.addProject(path: "/p/b", now: Self.t0)
        let template = PromptTemplateID()
        let set = w.setProjectTemplate(a, to: template)
        #expect(set)
        #expect(w.project(a)!.defaults.templateID == template)
        #expect(w.project(b)!.defaults.templateID == nil)
        let setAgain = w.setProjectTemplate(a, to: template)
        #expect(!setAgain)
        let unknown = w.setProjectTemplate(ProjectID(), to: template)
        #expect(!unknown)
        let cleared = w.setProjectTemplate(a, to: nil)
        #expect(cleared)
        #expect(w.project(a)!.defaults.templateID == nil)
        // The other defaults are untouched.
        #expect(w.project(a)!.defaults.permissionMode == .default)
    }

    @Test func forgettingATemplateClearsEveryProjectUsingIt() {
        var w = Workspace()
        let a = w.addProject(path: "/p/a", now: Self.t0)
        let b = w.addProject(path: "/p/b", now: Self.t0)
        let c = w.addProject(path: "/p/c", now: Self.t0)
        let template = PromptTemplateID()
        let other = PromptTemplateID()
        w.setProjectTemplate(a, to: template)
        w.setProjectTemplate(b, to: template)
        w.setProjectTemplate(c, to: other)
        w.archiveProject(b)
        let forgotten = w.forgetTemplate(template)
        #expect(forgotten)
        #expect(w.project(a)!.defaults.templateID == nil)
        #expect(w.project(b)!.defaults.templateID == nil)
        #expect(w.project(c)!.defaults.templateID == other)
        let forgottenAgain = w.forgetTemplate(template)
        #expect(!forgottenAgain)
    }

    // MARK: - Agents

    @Test func addAgentTakesTheLowestFreeDesk() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", defaults: AgentDefaults(permissionMode: .plan), now: Self.t0)
        let other = w.addProject(path: "/p/b", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        let a0 = try #require(added)
        let added2 = w.addAgent(to: p, now: Self.t0)
        let a1 = try #require(added2)
        let added3 = w.addAgent(to: p, now: Self.t0)
        let a2 = try #require(added3)
        let added4 = w.addAgent(to: other, now: Self.t0)
        let b0 = try #require(added4)
        #expect(w.agents(in: p).map(\.deskIndex) == [0, 1, 2])
        #expect(w.agent(b0)!.deskIndex == 0)
        let removed = w.removeAgent(a1)
        #expect(removed)
        let removed2 = w.removeAgent(a1)
        #expect(!removed2)
        let added5 = w.addAgent(to: p, now: Self.t0)
        let a3 = try #require(added5)
        #expect(w.agent(a3)!.deskIndex == 1)
        #expect(w.agent(a0)!.deskIndex == 0 && w.agent(a2)!.deskIndex == 2)
        #expect(w.agents(in: p).map(\.id) == [a0, a3, a2])
        #expect(w.agent(a0)!.permissionMode == .plan)
    }

    @Test func addAgentOptions() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, name: " Bob ", permissionMode: .acceptEdits, model: " opus ",
                                         worktree: " bob ", now: Self.t0)
        let id = try #require(added)
        let a = try #require(w.agent(id))
        #expect(a.name == "Bob")
        #expect(a.permissionMode == .acceptEdits)
        #expect(a.model == "opus")
        #expect(a.worktree == "bob")
        #expect(a.projectID == p)
        #expect(a.sessions.isEmpty && a.lastProcess == nil && !a.queuePaused)
        let added2 = w.addAgent(to: p, model: "  ", worktree: "", now: Self.t0)
        let blank = try #require(added2)
        #expect(w.agent(blank)!.model == nil && w.agent(blank)!.worktree == nil)
        let added3 = w.addAgent(to: ProjectID(), now: Self.t0)
        #expect(added3 == nil)
    }

    @Test func generatedNamesAreUniqueAndReproducible() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let q = w.addProject(path: "/p/b", now: Self.t0)
        for i in 0..<30 {
            let added = w.addAgent(to: i.isMultiple(of: 2) ? p : q, id: Self.agentID(UInt8(i)), now: Self.t0)
            _ = try #require(added)
        }
        #expect(Set(w.agents.map(\.name)).count == 30)

        var replay = Workspace()
        let rp = replay.addProject(path: "/p/a", now: Self.t0)
        let rq = replay.addProject(path: "/p/b", now: Self.t0)
        for i in 0..<30 { replay.addAgent(to: i.isMultiple(of: 2) ? rp : rq, id: Self.agentID(UInt8(i)), now: Self.t0) }
        #expect(replay.agents.map(\.name) == w.agents.map(\.name))
    }

    /// A click on a free desk of the scene (3.9) creates the agent at that desk.
    @Test func addAgentAtAGivenDesk() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, id: Self.agentID(1), deskIndex: 3, now: Self.t0)
        let a = try #require(added)
        #expect(w.agent(a)!.deskIndex == 3)
        // Taken: refused, nothing added.
        let taken = w.addAgent(to: p, id: Self.agentID(2), deskIndex: 3, now: Self.t0)
        #expect(taken == nil)
        let negative = w.addAgent(to: p, id: Self.agentID(3), deskIndex: -1, now: Self.t0)
        #expect(negative == nil)
        #expect(w.agents.count == 1)
        // Without a desk: the lowest free one, as before.
        let lowest = w.addAgent(to: p, id: Self.agentID(4), now: Self.t0)
        #expect(lowest.flatMap { w.agent($0)?.deskIndex } == 0)
        // Desk 3 of another project is free.
        let q = w.addProject(path: "/p/b", now: Self.t0)
        let other = w.addAgent(to: q, id: Self.agentID(5), deskIndex: 3, now: Self.t0)
        #expect(other.flatMap { w.agent($0)?.deskIndex } == 3)
        // A desk of an annex: its slot is reserved at once.
        let annex = w.addAgent(to: q, id: Self.agentID(6), deskIndex: 9, now: Self.t0)
        #expect(annex.flatMap { w.agent($0)?.deskIndex } == 9)
        #expect(w.project(q)!.annexSlots == [2])
    }

    @Test func newAgentGetsAGeneratedLook() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        for n in 1...5 {
            let added = w.addAgent(to: p, id: Self.agentID(UInt8(n)), now: Self.t0)
            let id = try #require(added)
            #expect(w.agent(id)!.look == AgentLook.generated(for: id))
        }
        #expect(Set(w.agents.map(\.look)).count > 1)
        // A look chosen by the caller is kept.
        let chosen = AgentLook(skin: 3, hairStyle: 5, hairColor: 7, outfitPaletteIndex: 12, accessory: 2)
        let added = w.addAgent(to: p, id: Self.agentID(9), look: chosen, now: Self.t0)
        #expect(added.flatMap { w.agent($0)?.look } == chosen)
    }

    @Test func annexSlotIsAllocatedOnceAndKept() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let q = w.addProject(path: "/p/b", now: Self.t0)
        var ids: [AgentID] = []
        func add(_ n: Int) throws {
            let added = w.addAgent(to: p, id: Self.agentID(UInt8(n)), now: Self.t0)
            ids.append(try #require(added))
        }
        for n in 0..<7 { try add(n) }
        #expect(w.project(p)!.annexSlots.isEmpty)
        #expect(w.usedSlots == [0, 1])
        // The eighth agent fills the island: the annex (its free desk 8) gets the lowest free slot.
        try add(7)
        #expect(w.project(p)!.annexSlots == [2])
        #expect(w.usedSlots == [0, 1, 2])
        // Agents in the annex, then a full annex: the next part gets its slot too.
        for n in 8..<16 { try add(n) }
        #expect(w.agents(in: p).map(\.deskIndex) == Array(0..<16))
        #expect(w.project(p)!.annexSlots == [2, 3])
        // Removing agents frees nothing (append-only, 3.8); adding them back allocates nothing new.
        for id in ids[4..<12] { w.removeAgent(id) }
        #expect(w.project(p)!.annexSlots == [2, 3])
        for n in 20..<28 { w.addAgent(to: p, id: Self.agentID(UInt8(n)), now: Self.t0) }
        #expect(w.project(p)!.annexSlots == [2, 3])
        #expect(w.project(q)!.annexSlots.isEmpty && w.project(q)!.slot == 1)
        // The layout puts every part in its slot.
        let layout = WorldLayout.compute(WorldInput(workspace: w))
        #expect(layout.islands.filter { $0.projectID == p }.map(\.slot) == [0, 2, 3])
    }

    @Test func addProjectSkipsAnnexSlots() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        for n in 0..<8 { w.addAgent(to: p, id: Self.agentID(UInt8(n)), now: Self.t0) }
        #expect(w.project(p)!.annexSlots == [1])
        let q = w.addProject(path: "/p/b", now: Self.t0)
        #expect(w.project(q)!.slot == 2)
        // The annex did not move.
        let layout = WorldLayout.compute(WorldInput(workspace: w))
        #expect(layout.islands.map { "\($0.projectID == p ? "p" : "q").\($0.part)@\($0.slot)" } == ["p.0@0", "p.1@1", "q.0@2"])
    }

    @Test func archiveFreesAnnexSlots() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        for n in 0..<8 { w.addAgent(to: p, id: Self.agentID(UInt8(n)), now: Self.t0) }
        let q = w.addProject(path: "/p/b", now: Self.t0)
        #expect(w.usedSlots == [0, 1, 2])
        w.archiveProject(p)
        #expect(w.usedSlots == [2])
        #expect(w.project(p)!.annexSlots.isEmpty)
        // The main slot and the annex slot go to the next projects, lowest first.
        let r = w.addProject(path: "/p/c", now: Self.t0)
        let s = w.addProject(path: "/p/d", now: Self.t0)
        #expect([w.project(r)!.slot, w.project(s)!.slot] == [0, 1] as [Int])
        #expect(w.project(q)!.slot == 2)
    }

    @Test func renameAgent() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, name: "Nova", now: Self.t0)
        let a = try #require(added)
        let renamed = w.renameAgent(a, to: "Lune")
        #expect(renamed)
        #expect(w.agent(a)!.name == "Lune")
        let renamed2 = w.renameAgent(a, to: " ")
        #expect(!renamed2)
    }

    // MARK: - Effects

    @Test func recordSessionAppendsNewAndUpdatesKnownSessions() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        let a = try #require(added)
        let s1 = SessionRef(sessionID: "s1", cwd: "/p/a", startedAt: Self.t0, source: .startup, model: "sonnet")
        let s2 = SessionRef(sessionID: "s2", cwd: "/p/a", startedAt: Self.t0.addingTimeInterval(60), source: .clear)
        let changed = w.apply(.recordSession(s1), agent: a)
        #expect(changed)
        let changed2 = w.apply(.recordSession(s2), agent: a)
        #expect(changed2)
        let changed3 = w.apply(.recordSession(s2), agent: a)
        #expect(!changed3)
        #expect(w.agent(a)!.sessions.map(\.sessionID) == ["s1", "s2"])

        let changed4 = w.apply(.endSession(sessionID: "s1", reason: "processExit", at: Self.t0.addingTimeInterval(5)), agent: a)
        #expect(changed4)
        // Resumed later: updated, live again, and becomes the resume target (last).
        let resumed = SessionRef(sessionID: "s1", cwd: "/p/a/.claude/worktrees/nova", startedAt: Self.t0.addingTimeInterval(120),
                                 source: .resume, transcriptPath: "/t/s1.jsonl", model: nil)
        let changed5 = w.apply(.recordSession(resumed), agent: a)
        #expect(changed5)
        let sessions = w.agent(a)!.sessions
        #expect(sessions.map(\.sessionID) == ["s2", "s1"])
        let last = try #require(sessions.last)
        #expect(last.transcriptPath == "/t/s1.jsonl")
        #expect(last.model == "sonnet")
        #expect(last.cwd == "/p/a/.claude/worktrees/nova")
        #expect(last.startedAt == Self.t0 && last.source == .startup)
        #expect(last.endedAt == nil && last.endReason == nil)
    }

    @Test func endSessionAndCwd() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        let a = try #require(added)
        w.apply(.recordSession(SessionRef(sessionID: "s1", cwd: "/p/a", startedAt: Self.t0, source: .startup)), agent: a)
        let end = Self.t0.addingTimeInterval(30)
        let changed = w.apply(.endSession(sessionID: "s1", reason: "clear", at: end), agent: a)
        #expect(changed)
        #expect(w.agent(a)!.sessions[0].endedAt == end)
        #expect(w.agent(a)!.sessions[0].endReason == "clear")
        let changed2 = w.apply(.endSession(sessionID: "nope", reason: nil, at: end), agent: a)
        #expect(!changed2)
        let changed4 = w.apply(.updateSessionCwd(sessionID: "s1", cwd: ""), agent: a)
        #expect(!changed4)
        let changed5 = w.apply(.updateSessionCwd(sessionID: "nope", cwd: "/p/a"), agent: a)
        #expect(!changed5)
    }

    /// `CwdChanged` also fires for a `cd` of the agent's Bash tool: only a return to the project folder (leaving a
    /// worktree) moves the resume folder.
    @Test func cwdChangesOnlyBringTheResumeFolderBackToTheProject() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        let a = try #require(added)
        let worktree = "/p/a/.claude/worktrees/nova"
        w.apply(.recordSession(SessionRef(sessionID: "s1", cwd: worktree, startedAt: Self.t0, source: .startup)), agent: a)
        for cwd in ["/p/a/sub", "/tmp", "/p/a/.claude/worktrees/autre", "/p"] {
            let changed = w.apply(.updateSessionCwd(sessionID: "s1", cwd: cwd), agent: a)
            #expect(!changed)
        }
        #expect(w.agent(a)!.sessions[0].cwd == worktree)
        let changed = w.apply(.updateSessionCwd(sessionID: "s1", cwd: "/p/a/sub/../"), agent: a)
        #expect(changed)
        #expect(w.agent(a)!.sessions[0].cwd == "/p/a")
        let again = w.apply(.updateSessionCwd(sessionID: "s1", cwd: "/p/a"), agent: a)
        #expect(!again)
    }

    @Test func processAndQueueEffects() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        let a = try #require(added)
        let stamp = ProcessStamp(pid: 4242, startedAt: Self.t0)
        let changed = w.apply(.recordProcess(stamp), agent: a)
        #expect(changed)
        #expect(w.agent(a)!.lastProcess == stamp)
        let changed2 = w.apply(.recordProcess(stamp), agent: a)
        #expect(!changed2)
        let changed3 = w.apply(.setQueuePaused(true), agent: a)
        #expect(changed3)
        #expect(w.agent(a)!.queuePaused)
        let changed4 = w.apply(.setQueuePaused(true), agent: a)
        #expect(!changed4)
        let changed5 = w.apply(.setQueuePaused(false), agent: AgentID())
        #expect(!changed5)
    }

    @Test func effectsOutsideTheWorkspaceAreIgnored() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p/a", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        let a = try #require(added)
        let before = w
        let others: [AgentEffect] = [
            .notify(.turnDone), .playSound(.done), .card(.turnFailed), .pumpQueue(afterSeconds: 1),
            .raiseGlobalIssue(.quota(resetAt: nil)), .clearGlobalIssue(.quota), .announce("x"),
            .resampleScreen(afterSeconds: 1), .reconcile, .showMessage("x"),
        ]
        for effect in others {
            let changed = w.apply(effect, agent: a)
            #expect(!changed)
        }
        #expect(w == before)
    }
}

@Suite struct PathNormalizerTests {
    @Test func standardizeIsLexical() {
        #expect(PathNormalizer.standardize("/Users/seraphin//Projets/./api/") == "/Users/seraphin/Projets/api")
        #expect(PathNormalizer.standardize("/a/b/../c") == "/a/c")
        #expect(PathNormalizer.standardize("/../..") == "/")
        #expect(PathNormalizer.standardize("/") == "/")
        #expect(PathNormalizer.standardize("//") == "/")
        #expect(PathNormalizer.standardize("a/../../b/") == "../b")
        #expect(PathNormalizer.standardize("/Users/seraphin/Application Support/") == "/Users/seraphin/Application Support")
    }

    @Test func tilde() {
        #expect(PathNormalizer.expandTilde("~", home: "/Users/s") == "/Users/s")
        #expect(PathNormalizer.expandTilde("~/dev", home: "/Users/s") == "/Users/s/dev")
        #expect(PathNormalizer.expandTilde("~other/dev", home: "/Users/s") == "~other/dev")
        #expect(PathNormalizer.normalize("~/dev/../dev/api/", home: "/nonexistent-home") == "/nonexistent-home/dev/api")
    }

    @Test func relativePathsUseTheCurrentDirectory() {
        #expect(PathNormalizer.normalize("api", home: "/h", currentDirectory: "/nonexistent/dev") == "/nonexistent/dev/api")
        #expect(PathNormalizer.normalize("../x", home: "/h", currentDirectory: "/nonexistent/dev/") == "/nonexistent/x")
    }

    @Test func symlinksAreResolvedEvenForMissingTails() throws {
        let fm = FileManager.default
        let root = PathNormalizer.normalize(NSTemporaryDirectory(), home: "/")
            + "/pos-path-tests-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let real = root + "/real folder"
        try fm.createDirectory(atPath: real + "/sub", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: real)

        #expect(PathNormalizer.normalize(root + "/link/sub/", home: "/") == real + "/sub")
        #expect(PathNormalizer.normalize(root + "/link/missing/deeper", home: "/") == real + "/missing/deeper")
        #expect(PathNormalizer.normalize(root + "/link", home: "/") == real)
        #expect(PathNormalizer.normalize("/", home: "/h") == "/")
    }
}
