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
