import Foundation
import PixelCore
import PixelIPC

/// Session intents (launch, relaunch, close, interrupt…) and the launch plumbing: `LaunchPlanner` request, checks,
/// `SessionManager.launch`, then `.processStarted` reduced at once, before any hook is handled.
extension AppModel {
    // MARK: - Sessions

    /// Starts a session. Waits for the search for `claude` when it is still running (first seconds after launch).
    func launch(_ agentID: AgentID, mode: LaunchMode) {
        guard claude.phase == .detecting, detectionTask != nil else {
            performLaunch(agentID, mode: mode)
            return
        }
        Task { [weak self] in
            await self?.waitForClaudeDetection()
            self?.performLaunch(agentID, mode: mode)
        }
    }

    /// Waits for the current search for `claude` (and for a search restarted meanwhile).
    func waitForClaudeDetection() async {
        var rounds = 0
        while claude.phase == .detecting, let detection = detectionTask, rounds < 5 {
            await detection.value
            rounds += 1
        }
    }

    /// Resumes the agent's last session (`--resume`), or starts a new one when it has none, when its transcript is
    /// gone (a session never used, or purged by Claude Code), or when resuming it just failed.
    func relaunch(_ agentID: AgentID) {
        guard let agent = workspace.agent(agentID) else { return }
        guard let last = agent.sessions.last else {
            launch(agentID, mode: .new(initialPrompt: nil))
            return
        }
        let transcriptMissing = last.transcriptPath.map { !FileManager.default.fileExists(atPath: $0) } ?? false
        if transcriptMissing || failedResumes.remove(agentID) != nil {
            showToast("\(agent.name) : conversation précédente introuvable, nouvelle session.", agentID: agentID)
            launch(agentID, mode: .new(initialPrompt: nil))
        } else {
            launch(agentID, mode: .resume(sessionID: last.sessionID))
        }
    }

    /// Closes the session: the exit reads as "closed by the user", not a crash. SIGTERM to the process group,
    /// SIGKILL after 5 s.
    func closeSession(_ agentID: AgentID) {
        guard runtimes[agentID]?.pid != nil else { return }
        dispatch(.closeRequested, to: agentID)
        sessions.close(agentID, force: false)
    }

    /// Interrupts the turn (⌘., proposal 5.8): writes one ESC byte only when the reducer accepted the request
    /// (agent thinking or working, no wait, no delivery). Never a second ESC.
    func interrupt(_ agentID: AgentID) {
        let before = runtimes[agentID]?.interruptRequestedAt
        dispatch(.userInterrupt, to: agentID)
        guard before == nil, runtimes[agentID]?.interruptRequestedAt != nil else { return }
        sessions.write(bytes: [0x1B], to: agentID)
    }

    /// The user looked at the agent (window or terminal opened): tones down its wait, moves "done" to idle.
    func acknowledge(_ agentID: AgentID) {
        dispatch(.acknowledged, to: agentID)
    }

    /// Stops the process of an agent left running by a previous run of the app (after a crash): SIGTERM to its
    /// process group. The agent can be relaunched once that process is gone.
    func terminateOrphan(_ agentID: AgentID) {
        guard let agent = workspace.agent(agentID), runtimes[agentID]?.phase == .offline(.orphanElsewhere),
              let stamp = agent.lastProcess else { return }
        if Self.isAlive(stamp), stamp.pid > 1, kill(-stamp.pid, SIGTERM) != 0 {
            kill(stamp.pid, SIGTERM)
        }
        showToast("\(agent.name) : l'ancienne session a été arrêtée.", agentID: agentID)
    }

    /// The process recorded by `stamp` still runs (same pid, same start time).
    static func isAlive(_ stamp: ProcessStamp) -> Bool {
        guard let started = ProcessAncestry.startTime(of: stamp.pid) else { return false }
        return abs(started.timeIntervalSince(stamp.startedAt)) < 1
    }

    /// Shell command equivalent to the agent's next launch, without the token ("Copier la commande", 5.1).
    func commandLine(for agentID: AgentID) -> String? {
        guard let agent = workspace.agent(agentID), let project = workspace.project(agent.projectID),
              let claudePath = claude.path else { return nil }
        let mode: LaunchMode = agent.sessions.last.map { .resume(sessionID: $0.sessionID) } ?? .new(initialPrompt: nil)
        guard let plan = try? LaunchPlanner.plan(launchRequest(agent: agent, project: project, mode: mode,
                                                               claudePath: claudePath)) else { return nil }
        return LaunchPlanner.displayCommand(plan)
    }

    // MARK: - Launch plumbing

    private func performLaunch(_ agentID: AgentID, mode requested: LaunchMode) {
        guard let agent = workspace.agent(agentID), let project = workspace.project(agent.projectID),
              let runtime = runtimes[agentID] else { return }
        let name = agent.name
        guard runtime.pid == nil, !sessions.isRunning(agentID) else {
            showToast("\(name) a déjà une session en cours.", agentID: agentID)
            return
        }
        if runtime.phase == .offline(.orphanElsewhere) {
            // Never resume a conversation still held by a live process (proposal 2.5).
            if let stamp = agent.lastProcess, Self.isAlive(stamp) {
                showToast("\(name) : une session tourne encore hors de l'app (pid \(stamp.pid)). "
                              + "Termine-la avant de relancer.", style: .warning, agentID: agentID)
                return
            }
        }
        guard claude.isUsable, let claudePath = claude.path else {
            showToast("Claude Code est introuvable : indique son chemin dans les réglages.", style: .error)
            post(.claudeSetup)
            return
        }
        guard hookServerState != .anotherInstance else {
            showToast("Une autre copie de l'app reçoit les hooks : lance les agents depuis celle-ci.", style: .error)
            return
        }
        guard Self.isDirectory(project.path) else {
            showToast("Le dossier du projet est introuvable : \(project.path)", style: .error)
            return
        }
        var mode = requested
        if case .resume(let sessionID) = mode,
           let cwd = agent.sessions.last(where: { $0.sessionID == sessionID })?.cwd,
           cwd.hasPrefix("/"), !Self.isDirectory(cwd) {
            showToast("\(name) : le dossier de sa dernière session n'existe plus (\(cwd)). Nouvelle session.",
                      style: .warning, agentID: agentID)
            mode = .new(initialPrompt: nil)
        }

        let plan: LaunchPlan
        do {
            plan = try LaunchPlanner.plan(launchRequest(agent: agent, project: project, mode: mode,
                                                        claudePath: claudePath))
        } catch let error as LaunchError {
            failLaunch(agentID, message: error.message)
            return
        } catch {
            failLaunch(agentID, message: error.localizedDescription)
            return
        }

        switch sessions.launch(plan: plan, agentID: agentID) {
        case .success(let pid):
            if case .resume = mode {
                resumeAttempts[agentID] = Date()
            } else {
                resumeAttempts[agentID] = nil
            }
            let startedAt = ProcessAncestry.startTime(of: pid) ?? Date()
            dispatch(.processStarted(pid: pid, startedAt: startedAt, withInitialPrompt: Self.hasInitialPrompt(mode)),
                     to: agentID)
        case .failure(.alreadyRunning):
            showToast("\(name) a déjà une session en cours.", agentID: agentID)
        case .failure(let error):
            failLaunch(agentID, message: error.message)
        }
    }

    private func failLaunch(_ agentID: AgentID, message: String) {
        dispatch(.processFailedToStart(message), to: agentID)
        showToast("\(names(of: agentID).agent) : \(message)", style: .error, agentID: agentID)
    }

    private func launchRequest(agent: Agent, project: Project, mode: LaunchMode, claudePath: String) -> LaunchRequest {
        var newSessionID: String?
        if case .new = mode { newSessionID = UUID().uuidString.lowercased() }
        return LaunchRequest(agent: agent, project: project, mode: mode, claudeExecutable: claudePath,
                             baseEnvironment: locator.environment ?? ProcessInfo.processInfo.environment,
                             hookSettingsPath: hookServer.settingsPath, hookSocketPath: hookServer.socketPath,
                             hookToken: hookServer.token, newSessionID: newSessionID,
                             options: LaunchOptions(settings: settings))
    }

    private static func hasInitialPrompt(_ mode: LaunchMode) -> Bool {
        guard case .new(let prompt) = mode, let prompt else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
