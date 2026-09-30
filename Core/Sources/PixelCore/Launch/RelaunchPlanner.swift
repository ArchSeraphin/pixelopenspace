import Foundation

/// How an agent left offline by the previous run of the app can start again (proposal 2.5, mock-up 6(p)).
public enum RelaunchStatus: Equatable, Sendable {
    /// `--resume <id>` in `ref.cwd` (`LaunchMode.resume`).
    case resumable(SessionRef)
    /// `ref.cwd` is gone (worktree removed): `--resume <id> --fork-session` in the project folder
    /// (`LaunchMode.fork` with `LaunchRequest.workingDirectoryOverride` = the project folder).
    case forkInProjectFolder(SessionRef)
    /// Nothing to resume (transcript purged, no session recorded, unreadable id): a new session is started. The
    /// reason is the whole line of the sheet, "… : une nouvelle session sera créée".
    case newSession(reason: String)
    /// The previous `claude` of the agent still runs (app crash): not relaunchable while this pid lives.
    case orphanAlive(pid: Int32)
}

/// One line of the "Relancer les sessions" sheet.
public struct RelaunchCandidate: Equatable, Sendable {
    public var agentID: AgentID
    public var status: RelaunchStatus
    /// Checked when the sheet opens, and relaunched by "Tout relancer": `resumable` and `forkInProjectFolder`.
    public var selectedByDefault: Bool
    /// The agent's card "En cours" (`BoardQuery.currentCard`), whose fate the user picks.
    public var cardInProgress: TaskCardID?
    /// End of the last session, or its start when it has no end ("il y a 2 h"); nil without a session.
    public var lastActivity: Date?

    public init(agentID: AgentID, status: RelaunchStatus, selectedByDefault: Bool, cardInProgress: TaskCardID?,
                lastActivity: Date?) {
        self.agentID = agentID
        self.status = status
        self.selectedByDefault = selectedByDefault
        self.cardInProgress = cardInProgress
        self.lastActivity = lastActivity
    }
}

/// What exists on disk, read by the app (`FileManager`) and injected: `RelaunchPlanner` stays pure.
public struct FileFacts: Sendable {
    /// The paths of `RelaunchPlanner.pathsToCheck` that exist: a folder for a session's folder, a file for a
    /// transcript. Compared as written there (trimmed).
    public var existingPaths: Set<String>

    public init(existingPaths: Set<String>) {
        self.existingPaths = existingPaths
    }
}

/// Which sessions the app can offer to relaunch after a restart or a crash, and how (proposal 2.5). Pure and
/// deterministic. It only proposes: nothing is launched and no card is sent without the user.
public enum RelaunchPlanner {
    public static let noSessionReason = "aucune session enregistrée : une nouvelle session sera créée"
    public static let unreadableSessionReason = "session illisible : une nouvelle session sera créée"
    public static let transcriptPurgedReason = "transcript purgé : une nouvelle session sera créée"

    /// Agents whose runtime phase is `.offline(.appRelaunched)` or `.offline(.orphanElsewhere)`, in sidebar order
    /// (`Workspace.projectsInOrder`, then `agents(in:)`: archived projects and agents without a runtime are left
    /// out). The status of each, the first that applies:
    /// 1. `agent.lastProcess.pid` in `alivePIDs` → `.orphanAlive`, whatever the phase: never `--resume` a session
    ///    held by a live process;
    /// 2. no session → `.newSession(noSessionReason)`; an id `--resume` refuses (blank, starting with "-") →
    ///    `.newSession(unreadableSessionReason)`;
    /// 3. `transcriptPath` of the last session recorded but missing → `.newSession(transcriptPurgedReason)` (a fork
    ///    needs the transcript too); an unrecorded or blank path is not judged;
    /// 4. its absolute folder missing, and not the project folder → `.forkInProjectFolder`. A missing project folder
    ///    is left to the launch, which refuses it; a folder not recorded as absolute is resumed in the project
    ///    folder, as `LaunchPlanner` does;
    /// 5. otherwise `.resumable`.
    ///
    /// `alivePIDs`: pids of `Agent.lastProcess` still running with the same start time, checked by the app.
    public static func candidates(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState,
                                  files: FileFacts, alivePIDs: Set<Int32>) -> [RelaunchCandidate] {
        workspace.projectsInOrder.flatMap { project in
            workspace.agents(in: project.id).compactMap { agent -> RelaunchCandidate? in
                guard let runtime = runtimes[agent.id], isRelaunchable(runtime.phase) else { return nil }
                let status = status(of: agent, project: project, files: files, alivePIDs: alivePIDs)
                let last = agent.sessions.last
                return RelaunchCandidate(agentID: agent.id, status: status, selectedByDefault: isSelected(status),
                                         cardInProgress: BoardQuery.currentCard(of: agent.id, in: board)?.id,
                                         lastActivity: last.map { $0.endedAt ?? $0.startedAt })
            }
        }
    }

    /// The paths `candidates` looks up in `FileFacts`: the folder (when absolute) and the transcript (when
    /// recorded) of each agent's last session, trimmed. The app checks these and passes the ones that exist.
    public static func pathsToCheck(workspace: Workspace) -> Set<String> {
        var paths: Set<String> = []
        for agent in workspace.agents {
            guard let last = agent.sessions.last else { continue }
            if let folder = LaunchPlanner.recordedCwd(of: last.sessionID, in: agent) { paths.insert(folder) }
            if let transcript = transcript(of: last) { paths.insert(transcript) }
        }
        return paths
    }

    // MARK: - Helpers

    static func isRelaunchable(_ phase: AgentPhase) -> Bool {
        phase == .offline(.appRelaunched) || phase == .offline(.orphanElsewhere)
    }

    static func isSelected(_ status: RelaunchStatus) -> Bool {
        switch status {
        case .resumable, .forkInProjectFolder: true
        case .newSession, .orphanAlive: false
        }
    }

    static func status(of agent: Agent, project: Project, files: FileFacts, alivePIDs: Set<Int32>) -> RelaunchStatus {
        if let pid = agent.lastProcess?.pid, alivePIDs.contains(pid) { return .orphanAlive(pid: pid) }
        guard let last = agent.sessions.last else { return .newSession(reason: noSessionReason) }
        guard (try? LaunchPlanner.validSessionID(last.sessionID)) != nil else {
            return .newSession(reason: unreadableSessionReason)
        }
        if let transcript = transcript(of: last), !files.existingPaths.contains(transcript) {
            return .newSession(reason: transcriptPurgedReason)
        }
        // The folder `.resume` runs in (`LaunchPlanner.recordedCwd` of the last session, which is this one).
        if let folder = LaunchPlanner.recordedCwd(of: last.sessionID, in: agent), !files.existingPaths.contains(folder),
           PathNormalizer.standardize(folder) != PathNormalizer.standardize(project.path) {
            return .forkInProjectFolder(last)
        }
        return .resumable(last)
    }

    /// The recorded transcript path, trimmed; nil when missing or blank.
    static func transcript(of session: SessionRef) -> String? {
        guard let path = session.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return path
    }
}
