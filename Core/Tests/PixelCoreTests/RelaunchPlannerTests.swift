import Foundation
import Testing
@testable import PixelCore

/// Fixtures of `RelaunchPlannerTests`: two projects, fixed ids and dates, sessions with a folder and a transcript.
fileprivate enum RelaunchFixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let home = "/Users/seraphin"
    static let api = Project(id: ProjectID(uuid(0xA0)), name: "API", path: "/Users/seraphin/dev/api", hueIndex: 0,
                             order: 0, slot: 0, createdAt: t0)
    static let site = Project(id: ProjectID(uuid(0xB0)), name: "SITE", path: "/Users/seraphin/dev/site", hueIndex: 1,
                              order: 1, slot: 1, createdAt: t0)
    static let nova = AgentID(uuid(0x01))
    static let bip = AgentID(uuid(0x02))
    static let tao = AgentID(uuid(0x03))
    static let rio = AgentID(uuid(0x04))

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// A session of `project` run in `cwd` (the project folder by default), with its transcript.
    static func session(_ id: String, project: Project = api, cwd: String? = nil, transcript: Bool = true,
                        startedAt: Date = at(0), endedAt: Date? = at(30)) -> SessionRef {
        let folder = cwd ?? project.path
        let encoded = folder.replacingOccurrences(of: "/", with: "-")
        return SessionRef(sessionID: id, cwd: folder, startedAt: startedAt, source: .startup, endedAt: endedAt,
                          endReason: endedAt == nil ? nil : "processExit",
                          transcriptPath: transcript ? "\(home)/.claude/projects/\(encoded)/\(id).jsonl" : nil)
    }

    static func agent(_ id: AgentID, _ name: String = "Nova", project: Project = api, desk: Int = 0,
                      sessions: [SessionRef], lastProcess: ProcessStamp? = nil) -> Agent {
        Agent(id: id, projectID: project.id, name: name, deskIndex: desk, sessions: sessions,
              lastProcess: lastProcess, createdAt: t0)
    }

    static func offline(_ reason: OfflineReason = .appRelaunched) -> AgentRuntime {
        AgentRuntime(phase: .offline(reason), phaseSince: at(120))
    }

    /// Every folder and transcript of the agents' sessions: the files as they were left.
    static func allPaths(_ agents: [Agent]) -> Set<String> {
        Set(agents.flatMap { $0.sessions.flatMap { [$0.cwd] + ($0.transcriptPath.map { [$0] } ?? []) } })
    }

    /// Candidates with every agent relaunched (unless `runtimes` says otherwise) and every file and project folder
    /// present (unless `existing` says otherwise).
    static func candidates(_ agents: [Agent], projects: [Project] = [api, site],
                           runtimes: [AgentID: AgentRuntime]? = nil, board: TaskBoardState = TaskBoardState(),
                           existing: Set<String>? = nil,
                           live: [AgentID: ProcessStamp] = [:]) -> [RelaunchCandidate] {
        let workspace = Workspace(projects: projects, agents: agents)
        let runtimes = runtimes ?? Dictionary(uniqueKeysWithValues: agents.map { ($0.id, offline()) })
        let files = FileFacts(existingPaths: existing ?? allPaths(agents).union(projects.map(\.path)))
        return RelaunchPlanner.candidates(workspace: workspace, runtimes: runtimes, board: board, files: files,
                                          liveProcesses: live)
    }

    static func card(_ n: Int, _ title: String, column: Column, assignee: AgentID?, queueRank: String? = nil,
                     flags: Set<CardFlag> = [], updatedAt: Date = at(20)) -> TaskCard {
        TaskCard(id: TaskCardID(uuid(0x100 + n)), title: title, projectID: api.id, column: column,
                 rank: String(UnicodeScalar(UInt8(0x60 + n))), assignee: assignee, queueRank: queueRank,
                 flags: flags, createdAt: at(1), updatedAt: updatedAt)
    }
}

@Suite struct RelaunchPlannerTests {
    fileprivate typealias F = RelaunchFixture

    // MARK: - One test per status

    @Test func resumableSessionResumesInItsFolder() {
        let last = F.session("7d2f9c1e-0000-4000-8000-000000000001", startedAt: F.at(10), endedAt: F.at(40))
        let nova = F.agent(F.nova, sessions: [F.session("old"), last])
        let found = F.candidates([nova])
        #expect(found == [RelaunchCandidate(agentID: F.nova, status: .resumable(last), selectedByDefault: true,
                                            cardInProgress: nil, lastActivity: F.at(40))])
        // A worktree still on disk is resumed there: `--resume` runs in `SessionRef.cwd`.
        let worktree = F.session("W1", cwd: "/Users/seraphin/dev/api/.claude/worktrees/nova")
        let inWorktree = F.agent(F.nova, sessions: [worktree])
        #expect(F.candidates([inWorktree]).map(\.status) == [.resumable(worktree)])
    }

    /// Review focus 1: a session still held by a live process is never resumed from here.
    @Test func orphanAliveIsNotResumable() {
        let stamp = ProcessStamp(pid: 4312, startedAt: F.at(5))
        let rio = F.agent(F.rio, "Rio", sessions: [F.session("R1")], lastProcess: stamp)
        let found = F.candidates([rio], runtimes: [F.rio: F.offline(.orphanElsewhere)], live: [F.rio: stamp])
        #expect(found == [RelaunchCandidate(agentID: F.rio, status: .orphanAlive(pid: 4312), selectedByDefault: false,
                                            cardInProgress: nil, lastActivity: F.at(30))])
        #expect(!RelaunchStatus.orphanAlive(pid: 4312).isRelaunchable)
        // Whatever the phase says: a live process wins (checked again by the app when it verifies the stamps).
        #expect(F.candidates([rio], live: [F.rio: stamp]).map(\.status) == [.orphanAlive(pid: 4312)])
        // Once the process is gone ("Terminer ce processus"), the session can be resumed.
        let gone = F.candidates([rio], runtimes: [F.rio: F.offline(.orphanElsewhere)], live: [:])
        #expect(gone.map(\.status) == [.resumable(F.session("R1"))])
        #expect(gone.map(\.selectedByDefault) == [true])
        // An orphan without a recorded process is not alive, whatever is verified for it.
        let unknown = F.agent(F.rio, "Rio", sessions: [F.session("R1")])
        #expect(F.candidates([unknown], runtimes: [F.rio: F.offline(.orphanElsewhere)], live: [F.rio: stamp])
                    .map(\.status) == [.resumable(F.session("R1"))])
    }

    /// A pid number is reused by the system: only the agent whose own stamp (pid and start time) was verified alive
    /// is an orphan. Another agent with the same pid in an older stamp is resumed as usual.
    @Test func orphanStampsAreMatchedPerAgent() {
        let rioStamp = ProcessStamp(pid: 4312, startedAt: F.at(5))
        let staleStamp = ProcessStamp(pid: 4312, startedAt: F.at(-600))
        let rio = F.agent(F.rio, "Rio", desk: 0, sessions: [F.session("R1")], lastProcess: rioStamp)
        let nova = F.agent(F.nova, "Nova", desk: 1, sessions: [F.session("N1")], lastProcess: staleStamp)
        let runtimes = [F.rio: F.offline(.orphanElsewhere), F.nova: F.offline()]
        let found = F.candidates([rio, nova], runtimes: runtimes, live: [F.rio: rioStamp])
        #expect(found.map(\.status) == [.orphanAlive(pid: 4312), .resumable(F.session("N1"))])
        #expect(found.map(\.selectedByDefault) == [false, true])
        // A stamp verified for another agent never marks this one, even with the same pid.
        #expect(F.candidates([nova], live: [F.rio: rioStamp]).map(\.status) == [.resumable(F.session("N1"))])
        // A verified stamp that is not the agent's current one (same pid, another start time) does not count.
        #expect(F.candidates([nova], live: [F.nova: rioStamp]).map(\.status) == [.resumable(F.session("N1"))])
        #expect(F.candidates([rio], live: [F.rio: staleStamp]).map(\.status) == [.resumable(F.session("R1"))])
    }

    /// Review focus 2: a transcript purged by Claude Code cannot be resumed nor forked.
    @Test func transcriptMissingProposesNewSession() {
        let last = F.session("T1", project: F.site)
        let tao = F.agent(F.tao, "Tao", project: F.site, sessions: [last])
        let found = F.candidates([tao], existing: [F.site.path])
        let purged = RelaunchStatus.newSession(reason: "transcript purgé : une nouvelle session sera créée")
        #expect(found == [RelaunchCandidate(agentID: F.tao, status: purged, selectedByDefault: false,
                                            cardInProgress: nil, lastActivity: F.at(30))])
        #expect(RelaunchPlanner.transcriptPurgedReason == "transcript purgé : une nouvelle session sera créée")
        // Before the folder: a fork needs the transcript too.
        let worktree = F.agent(F.tao, "Tao", project: F.site,
                               sessions: [F.session("T2", project: F.site, cwd: "/tmp/gone")])
        #expect(F.candidates([worktree], existing: [F.site.path]).map(\.status)
                == [.newSession(reason: RelaunchPlanner.transcriptPurgedReason)])
        #expect(RelaunchStatus.newSession(reason: RelaunchPlanner.transcriptPurgedReason).isRelaunchable)
    }

    /// Review focus 3: the session's folder is gone (worktree removed): fork it in the project folder.
    @Test func missingFolderForksInProjectFolder() {
        let last = F.session("W1", cwd: "/Users/seraphin/dev/api/.claude/worktrees/nova")
        let nova = F.agent(F.nova, sessions: [last])
        let found = F.candidates([nova], existing: [F.api.path, last.transcriptPath!])
        #expect(found == [RelaunchCandidate(agentID: F.nova, status: .forkInProjectFolder(last),
                                            selectedByDefault: true, cardInProgress: nil, lastActivity: F.at(30))])
        #expect(RelaunchStatus.forkInProjectFolder(last).isRelaunchable)
        // The session's folder spelled differently (trailing slash, "."): still the project folder, which exists.
        let spelled = F.session("P2", cwd: "/Users/seraphin/dev/./api/")
        #expect(F.candidates([F.agent(F.nova, sessions: [spelled])], existing: [F.api.path, spelled.transcriptPath!])
                    .map(\.status) == [.resumable(spelled)])
    }

    /// The project's own folder is gone (moved, deleted, unmounted disk): resume, fork and new session would all
    /// fail, since every launch needs it. The line says so, is never checked, and cannot be relaunched.
    @Test func missingProjectFolderIsNotRelaunchable() {
        let last = F.session("P1")
        let nova = F.agent(F.nova, sessions: [last])
        let found = F.candidates([nova], existing: [last.transcriptPath!])
        #expect(found == [RelaunchCandidate(agentID: F.nova, status: .projectFolderMissing(path: F.api.path),
                                            selectedByDefault: false, cardInProgress: nil, lastActivity: F.at(30))])
        #expect(!RelaunchStatus.projectFolderMissing(path: F.api.path).isRelaunchable)
        #expect(RelaunchPlanner.projectFolderMissingReason == "dossier du projet introuvable")
        // Even when the session ran in a worktree that is still there: the app launches nothing without the project
        // folder.
        let worktree = F.session("W1", cwd: "/Volumes/ext/api-wt")
        let inWorktree = F.agent(F.nova, sessions: [worktree])
        #expect(F.candidates([inWorktree], existing: [worktree.cwd, worktree.transcriptPath!]).map(\.status)
                == [.projectFolderMissing(path: F.api.path)])
        // Without any session (a new session would be started there).
        let bip = F.agent(F.bip, "Bip", sessions: [])
        #expect(F.candidates([bip], existing: []).map(\.status) == [.projectFolderMissing(path: F.api.path)])
        // An orphan still alive stays an orphan: "Terminer ce processus" is still offered.
        let stamp = ProcessStamp(pid: 77, startedAt: F.at(1))
        let rio = F.agent(F.rio, "Rio", sessions: [last], lastProcess: stamp)
        #expect(F.candidates([rio], existing: [], live: [F.rio: stamp]).map(\.status) == [.orphanAlive(pid: 77)])
        // Once the folder is back, the session is resumed.
        #expect(F.candidates([nova], existing: [F.api.path, last.transcriptPath!]).map(\.status)
                == [.resumable(last)])
    }

    @Test func unknownTranscriptOrFolderIsNotJudged() {
        // No transcript path recorded: resumed (the app falls back to a new session when the resume fails fast).
        let noTranscript = F.session("U1", transcript: false)
        #expect(F.candidates([F.agent(F.nova, sessions: [noTranscript])]).map(\.status) == [.resumable(noTranscript)])
        var blank = F.session("U2")
        blank.transcriptPath = "  "
        #expect(F.candidates([F.agent(F.nova, sessions: [blank])], existing: [F.api.path]).map(\.status)
                == [.resumable(blank)])
        // A folder that is not absolute: `LaunchPlanner` resumes in the project folder.
        let relative = F.session("U3", cwd: "dev/api")
        #expect(F.candidates([F.agent(F.nova, sessions: [relative])], existing: [F.api.path, relative.transcriptPath!])
                    .map(\.status) == [.resumable(relative)])
        // Paths are looked up trimmed, as `LaunchPlanner` uses them.
        var padded = F.session("U4", cwd: "/Users/seraphin/dev/api/wt")
        padded.cwd = " /Users/seraphin/dev/api/wt\n"
        padded.transcriptPath = " /Users/seraphin/.claude/projects/x/U4.jsonl "
        let existing: Set<String> = [F.api.path, "/Users/seraphin/dev/api/wt",
                                     "/Users/seraphin/.claude/projects/x/U4.jsonl"]
        #expect(F.candidates([F.agent(F.nova, sessions: [padded])], existing: existing).map(\.status)
                == [.resumable(padded)])
    }

    @Test func agentWithoutUsableSessionGetsANewSession() {
        let empty = F.agent(F.bip, "Bip", sessions: [])
        let none = RelaunchStatus.newSession(reason: "aucune session enregistrée : une nouvelle session sera créée")
        #expect(F.candidates([empty]) == [RelaunchCandidate(agentID: F.bip, status: none, selectedByDefault: false,
                                                            cardInProgress: nil, lastActivity: nil)])
        #expect(RelaunchPlanner.noSessionReason == "aucune session enregistrée : une nouvelle session sera créée")
        // An id `--resume` would refuse (blank, read as an option).
        for id in ["", "  ", "--dangerously-skip-permissions"] {
            let agent = F.agent(F.bip, "Bip", sessions: [F.session(id)])
            #expect(F.candidates([agent]).map(\.status)
                    == [.newSession(reason: "session illisible : une nouvelle session sera créée")])
        }
        #expect(RelaunchPlanner.unreadableSessionReason == "session illisible : une nouvelle session sera créée")
        #expect(RelaunchStatus.newSession(reason: RelaunchPlanner.noSessionReason).isRelaunchable)
    }

    // MARK: - Who, in which order, with what

    @Test func onlyRelaunchedAndOrphanAgentsAreCandidates() {
        let phases: [AgentPhase] = [.offline(.notStarted), .offline(.closedByUser), .offline(.exited), .idle,
                                    .launching, .error(.crashed(1)), .offline(.appRelaunched),
                                    .offline(.orphanElsewhere)]
        var agents: [Agent] = []
        var runtimes: [AgentID: AgentRuntime] = [:]
        for (i, phase) in phases.enumerated() {
            let agent = F.agent(AgentID(F.uuid(0x10 + i)), "A\(i)", desk: i, sessions: [F.session("S\(i)")])
            agents.append(agent)
            runtimes[agent.id] = AgentRuntime(phase: phase, phaseSince: F.t0)
        }
        // Without a runtime: not shown.
        agents.append(F.agent(AgentID(F.uuid(0x30)), "Sans", desk: 20, sessions: [F.session("S30")]))
        let found = F.candidates(agents, runtimes: runtimes).map(\.agentID)
        #expect(found == [AgentID(F.uuid(0x16)), AgentID(F.uuid(0x17))])
    }

    @Test func candidatesComeInSidebarOrder() {
        // Projects by `order` (site before api here), agents by desk; archived projects and unknown ones are left
        // out, as in the sidebar.
        var api = F.api
        api.order = 5
        var site = F.site
        site.order = 1
        var old = Project(id: ProjectID(F.uuid(0xC0)), name: "OLD", path: "/Users/seraphin/dev/old", hueIndex: 2,
                          order: 0, slot: 2, createdAt: F.t0)
        old.archived = true
        let agents = [
            F.agent(F.nova, "Nova", project: api, desk: 1, sessions: [F.session("N")]),
            F.agent(F.bip, "Bip", project: api, desk: 0, sessions: [F.session("B")]),
            F.agent(F.tao, "Tao", project: site, desk: 3, sessions: [F.session("T", project: site)]),
            F.agent(F.rio, "Rio", project: old, desk: 0, sessions: [F.session("R", project: old)]),
            Agent(id: AgentID(F.uuid(0x40)), projectID: ProjectID(F.uuid(0xD0)), name: "Perdu", deskIndex: 0,
                  sessions: [F.session("L")], createdAt: F.t0),
        ]
        let found = F.candidates(agents, projects: [api, site, old])
        #expect(found.map(\.agentID) == [F.tao, F.bip, F.nova])
    }

    @Test func cardInProgressIsTheAgentsCurrentCard() {
        let nova = F.agent(F.nova, sessions: [F.session("N")])
        let bip = F.agent(F.bip, "Bip", desk: 1, sessions: [F.session("B")])
        let board = TaskBoardState(cards: [
            F.card(1, "Corriger le login OAuth", column: .inProgress, assignee: F.nova),
            F.card(2, "Écrire la doc", column: .todo, assignee: F.nova, queueRank: "a"),
            F.card(3, "Relire la PR", column: .review, assignee: F.bip),
            F.card(4, "Carte d'un autre", column: .inProgress, assignee: nil),
        ])
        let found = F.candidates([nova, bip], board: board)
        #expect(found.map(\.cardInProgress) == [TaskCardID(F.uuid(0x101)), nil])
        // A stopped card (flag) is still the one the agent was on: the user decides what becomes of it.
        let stopped = TaskBoardState(cards: [
            F.card(5, "Migrer la base", column: .inProgress, assignee: F.nova, flags: [.sessionLost]),
        ])
        #expect(F.candidates([nova], board: stopped).map(\.cardInProgress) == [TaskCardID(F.uuid(0x105))])
    }

    @Test func lastActivityIsTheEndOrTheStartOfTheLastSession() {
        let ended = F.agent(F.nova, sessions: [F.session("A", startedAt: F.at(0), endedAt: F.at(90)),
                                               F.session("B", startedAt: F.at(100), endedAt: F.at(130))])
        let crashed = F.agent(F.bip, "Bip", desk: 1, sessions: [F.session("C", startedAt: F.at(50), endedAt: nil)])
        #expect(F.candidates([ended, crashed]).map(\.lastActivity) == [F.at(130), F.at(50)])
    }

    @Test func defaultSelectionFollowsTheStatus() {
        let stamp = ProcessStamp(pid: 77, startedAt: F.t0)
        let resumable = F.agent(F.nova, desk: 0, sessions: [F.session("R")])
        let fork = F.agent(F.bip, "Bip", desk: 1, sessions: [F.session("F", cwd: "/Users/seraphin/dev/api/wt")])
        let purged = F.agent(F.tao, "Tao", desk: 2, sessions: [F.session("P")])
        let orphan = F.agent(F.rio, "Rio", desk: 3, sessions: [F.session("O")], lastProcess: stamp)
        let agents = [resumable, fork, purged, orphan]
        var existing = F.allPaths(agents)
        existing.remove("/Users/seraphin/dev/api/wt")
        existing.remove(purged.sessions[0].transcriptPath!)
        let found = F.candidates(agents, existing: existing, live: [F.rio: stamp])
        #expect(found.map(\.selectedByDefault) == [true, true, false, false])
        #expect(found.map(\.status) == [.resumable(resumable.sessions[0]), .forkInProjectFolder(fork.sessions[0]),
                                        .newSession(reason: RelaunchPlanner.transcriptPurgedReason),
                                        .orphanAlive(pid: 77)])
    }

    @Test func pathsToCheckAreTheProjectFoldersAndTheLastSessionsFoldersAndTranscripts() {
        var noTranscript = F.session("B", cwd: " /Users/seraphin/dev/api/wt ", transcript: false)
        noTranscript.transcriptPath = "   "
        let agents = [
            F.agent(F.nova, sessions: [F.session("old", cwd: "/Users/seraphin/dev/api/old"), F.session("A")]),
            F.agent(F.bip, "Bip", desk: 1, sessions: [noTranscript]),
            F.agent(F.tao, "Tao", desk: 2, sessions: []),
        ]
        let paths = RelaunchPlanner.pathsToCheck(workspace: Workspace(projects: [F.api, F.site], agents: agents))
        #expect(paths == [F.api.path, agents[0].sessions[1].transcriptPath!, "/Users/seraphin/dev/api/wt"])
        // The project folder of an agent without any session is checked too; a project without agents is not.
        let rio = F.agent(F.rio, "Rio", project: F.site, sessions: [])
        let withSite = RelaunchPlanner.pathsToCheck(workspace: Workspace(projects: [F.api, F.site], agents: [rio]))
        #expect(withSite == [F.site.path])
    }

    @Test func reasonsAreFrenchWithoutEmDash() {
        for reason in [RelaunchPlanner.noSessionReason, RelaunchPlanner.unreadableSessionReason,
                       RelaunchPlanner.transcriptPurgedReason] {
            #expect(reason.hasSuffix("une nouvelle session sera créée"))
            #expect(!reason.contains("\u{2014}"))
        }
        #expect(!RelaunchPlanner.projectFolderMissingReason.contains("\u{2014}"))
    }

    // MARK: - With the board (review focus 4, core side)

    /// On load, each relaunched agent with a card "En cours" gets `sessionLost`: the card stays where it is, flagged,
    /// and nothing is queued or sent until the user chooses (C13; "Continuer la tâche" is C14, later, with the agent
    /// live).
    @Test func relaunchedAgentsCardsAreFlaggedSessionLostAndNeverSent() {
        let nova = F.agent(F.nova, sessions: [F.session("N")])
        let bip = F.agent(F.bip, "Bip", desk: 1, sessions: [F.session("B")])
        let tao = F.agent(F.tao, "Tao", desk: 2, sessions: [F.session("T")])
        var board = TaskBoardState(cards: [
            F.card(1, "Corriger le login OAuth", column: .inProgress, assignee: F.nova),
            F.card(2, "Écrire la doc", column: .todo, assignee: F.nova, queueRank: "a"),
            F.card(3, "Relire la PR", column: .review, assignee: F.bip),
        ])
        let context = TaskContext(now: F.at(120), agentProjects: [F.nova: F.api.id, F.bip: F.api.id, F.tao: F.api.id],
                                  liveAgents: [])
        let found = F.candidates([nova, bip, tao], board: board)
        var effects: [TaskEffect] = []
        for candidate in found where candidate.cardInProgress != nil {
            let signal = TaskInput.agentSignal(candidate.agentID, .sessionLost)
            let (next, fx) = TaskLifecycle.reduce(board, signal, context: context)
            board = next
            effects += fx
        }
        #expect(effects.isEmpty)
        #expect(board.instructions.isEmpty)
        let running = board.card(TaskCardID(F.uuid(0x101)))!
        #expect(running.column == .inProgress)
        #expect(running.flags == [.sessionLost])
        #expect(running.history.last?.kind == .sessionLost)
        #expect(board.card(TaskCardID(F.uuid(0x102)))?.column == .todo)
        #expect(board.card(TaskCardID(F.uuid(0x102)))?.flags == [])
        #expect(board.card(TaskCardID(F.uuid(0x103)))?.flags == [])
        // The sheet still shows the card of the agent, now flagged.
        #expect(F.candidates([nova, bip, tao], board: board).map(\.cardInProgress)
                == [TaskCardID(F.uuid(0x101)), nil, nil])
        // Loading twice (a second launch) flags nothing more.
        let (again, fx) = TaskLifecycle.reduce(board, .agentSignal(F.nova, .sessionLost), context: context)
        #expect(fx.isEmpty)
        #expect(again == board)
    }

    /// At launch, the agents whose turn of the previous run is lost: every offline agent (whatever the reason) with
    /// a card "En cours", stopped or not, in workspace order. An agent with a process, or with only queued, review
    /// or done cards, or without a runtime, is not.
    @Test func lostTurnsAreTheOfflineAgentsWithACardInProgress() {
        let nova = F.agent(F.nova, sessions: [F.session("N")])
        let bip = F.agent(F.bip, "Bip", desk: 1, sessions: [F.session("B")])
        let tao = F.agent(F.tao, "Tao", desk: 2, sessions: [])
        let rio = F.agent(F.rio, "Rio", desk: 3, sessions: [F.session("R")])
        let lou = F.agent(AgentID(F.uuid(0x05)), "Lou", desk: 4, sessions: [F.session("L")])
        let board = TaskBoardState(cards: [
            F.card(1, "Corriger le login OAuth", column: .inProgress, assignee: F.nova),
            F.card(2, "Écrire la doc", column: .todo, assignee: F.bip, queueRank: "a"),
            F.card(3, "Relire la PR", column: .review, assignee: F.bip),
            F.card(4, "Migrer la base", column: .inProgress, assignee: F.tao, flags: [.sessionLost]),
            F.card(5, "Carte de Rio", column: .inProgress, assignee: F.rio),
            F.card(6, "Carte de Lou", column: .inProgress, assignee: lou.id),
        ])
        var live = AgentRuntime(phase: .idle, phaseSince: F.at(120))
        live.pid = 4242
        let runtimes = [F.nova: F.offline(), F.bip: F.offline(), F.tao: F.offline(.notStarted), F.rio: live]
        let workspace = Workspace(projects: [F.api, F.site], agents: [tao, nova, bip, rio, lou])
        #expect(RelaunchPlanner.lostTurns(workspace: workspace, runtimes: runtimes, board: board) == [F.tao, F.nova])
    }

    /// The queue behind a lost turn (4.3b: "Reprendre la file" first requires deciding the interrupted card). At
    /// launch the card gets `sessionLost` and the agent's queue is paused: once relaunched, the next post-it does
    /// not start beside the lost one. "Remettre à faire" settles the card, and the queue resumed by the app (or by
    /// "Reprendre la file") delivers the next post-it, the only one then in progress.
    @Test func queueBehindALostTurnWaitsUntilTheCardIsDecided() throws {
        let nova = F.agent(F.nova, sessions: [F.session("N")])
        var workspace = Workspace(projects: [F.api, F.site], agents: [nova])
        let lostID = TaskCardID(F.uuid(0x101))
        let nextID = TaskCardID(F.uuid(0x102))
        var board = TaskBoardState(cards: [
            F.card(1, "Corriger le login OAuth", column: .inProgress, assignee: F.nova),
            F.card(2, "Écrire la doc", column: .todo, assignee: F.nova, queueRank: "a"),
        ])
        let context = TaskContext(now: F.at(120), agentProjects: [F.nova: F.api.id], liveAgents: [])
        for agent in RelaunchPlanner.lostTurns(workspace: workspace, runtimes: [F.nova: F.offline()], board: board) {
            board = TaskLifecycle.reduce(board, .agentSignal(agent, .sessionLost), context: context).0
            let paused = workspace.apply(.setQueuePaused(true), agent: agent)
            #expect(paused)
        }
        #expect(BoardQuery.cardToDecide(of: F.nova, in: board)?.id == lostID)

        // Relaunched: live, hooks healthy, idle, empty input box. The queue holds the next post-it.
        var relaunched = AgentRuntime(phase: .idle, phaseSince: F.at(121))
        relaunched.pid = 4242
        relaunched.hookHealth = .healthy
        relaunched.screen = ScreenFacts(inputBox: .empty, recognized: true)
        func decision() throws -> DeliveryDecision {
            DispatchPolicy.nextDelivery(agent: try #require(workspace.agent(F.nova)), runtime: relaunched,
                                        queue: BoardQuery.queue(of: F.nova, in: board), now: F.at(130),
                                        lastTurnEndedAt: nil, settings: DispatchSettings(), draftOverride: false)
        }
        #expect(try decision() == .wait(.paused))

        // "Remettre à faire": nothing is left to decide, the queue goes on.
        let live = TaskContext(now: F.at(125), agentProjects: [F.nova: F.api.id], liveAgents: [F.nova])
        board = TaskLifecycle.reduce(board, .putBack(lostID), context: live).0
        #expect(board.card(lostID)?.column == .todo)
        #expect(BoardQuery.cardToDecide(of: F.nova, in: board) == nil)
        let resumed = workspace.apply(.setQueuePaused(false), agent: F.nova)
        #expect(resumed)
        #expect(try decision() == .deliver(.card(nextID)))
    }
}
