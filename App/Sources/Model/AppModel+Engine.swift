import Foundation
import PixelCore
import PixelIPC

/// The reducer loop: inputs from hooks, terminals and the clock go through `AgentStateMachine.reduce`, and its effects
/// are executed here (proposal 2.1, "Règle d'or").
extension AppModel {
    // MARK: - Dispatch

    /// Reduces one input for one agent, stores the new runtime, then executes the effects in order. The dispatcher
    /// then looks at the change: an agent that may have become free gets its queue looked at.
    func dispatch(_ input: AgentInput, to agentID: AgentID) {
        guard let previous = runtimes[agentID] else { return }
        let (next, effects) = AgentStateMachine.reduce(previous, input, now: Date(), config: reducerConfig)
        storeRuntime(next, for: agentID)
        for effect in effects {
            perform(effect, for: agentID)
        }
        if !previous.pendingWaits.isEmpty, next.pendingWaits.isEmpty {
            notifications.withdraw(agentID: agentID, kinds: [.waiting])
        }
        updateDockBadge()
        if isWaitingForTurnsToQuit { quitIfIdle() }
        if let current = runtimes[agentID] {
            dispatcher.runtimeChanged(agentID, from: previous, to: current)
        }
    }

    private func perform(_ effect: AgentEffect, for agentID: AgentID) {
        switch effect {
        case .notify(let notification):
            guard let subject = notificationSubject(for: agentID) else { return }
            notifications.post(notification, subject: subject)
        case .playSound(let sound):
            // Sounds arrive with SoundPlayer (step 4); notifications already play the system sound.
            AppLog.model.debug("sound \(sound.rawValue, privacy: .public)")
        case .card(let signal):
            // The grace delay starts before the card moves: the board's own `.pump` then waits for it.
            if case .turnCommitted = signal { dispatcher.turnEnded(agentID) }
            // The agent's post-it follows its turn (proposal 4.3b: C7, C8, C10 to C13).
            applyTask(.agentSignal(agentID, signal))
        case .pumpQueue(let delay):
            // T13b: the next item after the grace delay (1.5 s by default).
            dispatcher.pump(agentID, after: delay)
        case .setQueuePaused, .recordSession, .endSession, .updateSessionCwd, .recordProcess:
            // `setQueuePaused(true)`: interrupt (T22, T28b) or failed delivery (T31); only the user resumes it.
            var updated = workspace
            if updated.apply(effect, agent: agentID) { commit(updated) }
        case .raiseGlobalIssue(let issue):
            let isNew = globalIssues[issue.kind] == nil
            setGlobalIssue(issue, kind: issue.kind)
            if isNew { notifications.postGlobal(issue) }
        case .clearGlobalIssue(let kind):
            clearGlobalIssueIfResolved(kind)
        case .announce(let text):
            announce("\(names(of: agentID).agent) \(text)")
        case .resampleScreen(let delay):
            scheduleScreenSample(agentID, after: delay)
        case .reconcile:
            scheduleScreenSample(agentID, after: 0)
        case .showMessage(let text):
            showToast("\(names(of: agentID).agent) : \(text)", style: .warning, agentID: agentID)
        }
    }

    /// A global issue is cleared only when no agent still has it (quota: still paused; account: still in error).
    private func clearGlobalIssueIfResolved(_ kind: GlobalIssueKind) {
        guard globalIssues[kind] != nil else { return }
        let stillPresent = runtimes.values.contains { runtime in
            switch (kind, runtime.phase) {
            case (.quota, .quotaPaused): return true
            case (.account, .error(.account)): return true
            default: return false
            }
        }
        guard !stillPresent else { return }
        setGlobalIssue(nil, kind: kind)
        notifications.withdrawGlobal(kind)
    }

    func notificationSubject(for agentID: AgentID) -> NotificationSubject? {
        guard let agent = workspace.agent(agentID), let project = workspace.project(agent.projectID) else { return nil }
        return NotificationSubject(agentID: agentID, agentName: agent.name, projectID: project.id,
                                   projectName: project.name)
    }

    // MARK: - Hooks

    func startHookLoop() {
        guard hookTask == nil else { return }
        let stream = hookServer.envelopes
        hookTask = Task { [weak self] in
            for await envelope in stream {
                guard let self else { return }
                self.receive(envelope)
            }
        }
    }

    /// `HookDeduplicator` → `HookRouter` → `.hook` input (proposal 2.3). Only accepted events reach the reducer.
    func receive(_ envelope: HookEnvelope) {
        guard !deduplicator.isDuplicate(envelope) else { return }
        let routing = runtimes.mapValues { RoutingEntry(pid: $0.pid, sessionID: $0.currentSessionID) }
        let decision = HookRouter.route(envelope, expectedToken: hookServer.token, agents: routing)
        let event = envelope.event.name.rawValue
        switch decision {
        case .accept(let agentID):
            hookSeq += 1
            dispatch(.hook(envelope.event, seq: hookSeq), to: agentID)
            // Hook → screen latency (MVP criterion 2): from the helper's `ts_ns` to the new state stored and its
            // effects run, on the same monotonic clock; SwiftUI draws it at the next pass of the main run loop.
            hookLatency.record(sentNs: envelope.timestampNs, appliedNs: HookWire.monotonicNanos())
        case .ignoreNested(let agentID):
            AppLog.hooks.debug("\(event, privacy: .public) from a nested claude of \(agentID.description, privacy: .public): ignored")
        case .rejectToken:
            AppLog.hooks.debug("\(event, privacy: .public) with a wrong token: rejected")
        case .unknownAgent(let agentID):
            AppLog.hooks.debug("\(event, privacy: .public) for unknown agent \(agentID.description, privacy: .public)")
        case .external:
            AppLog.hooks.debug("\(event, privacy: .public) from an external session: ignored (step 5)")
        }
    }

    // MARK: - Terminals

    func handleTerminalEvent(_ agentID: AgentID, _ event: TerminalEvent) {
        switch event {
        case .exited(let code):
            let neverHooked = runtimes[agentID]?.lastHookAt == nil
            if let resumedAt = resumeAttempts.removeValue(forKey: agentID), let code, code != 0, neverHooked,
               Date().timeIntervalSince(resumedAt) < 15 {
                // `--resume` failed at once (conversation gone): the next relaunch starts a new session.
                failedResumes.insert(agentID)
                showToast("\(names(of: agentID).agent) : la conversation n'a pas pu être reprise. "
                              + "« Relancer » démarrera une nouvelle session.", style: .warning, agentID: agentID)
            }
            // exec failed (127) before any hook: a launch failure, not a crash (proposal 3.1).
            if code == 127, let runtime = runtimes[agentID], runtime.lastHookAt == nil,
               let startedAt = sessions.host(for: agentID)?.startedAt, Date().timeIntervalSince(startedAt) < 10 {
                let message = "claude n'a pas pu être exécuté (code 127)"
                dispatch(.processFailedToStart(message), to: agentID)
                showToast("\(names(of: agentID).agent) : \(message)", style: .error, agentID: agentID)
            } else {
                dispatch(.processExited(code: code), to: agentID)
            }
        case .failedToStart(let message):
            dispatch(.processFailedToStart(message), to: agentID)
            showToast("\(names(of: agentID).agent) : lancement impossible (\(message))", style: .error, agentID: agentID)
        case .output:
            dispatch(.outputActivity, to: agentID)
        case .keystroke(let keyClass):
            dispatch(.userKeystroke(keyClass), to: agentID)
        case .bell:
            dispatch(.bell, to: agentID)
        }
    }

    /// Reads the live screen now and reduces `.screen(ScreenPatterns.parse(lines:))`.
    func sampleScreen(_ agentID: AgentID) {
        guard runtimes[agentID]?.pid != nil, let lines = sessions.sampleVisibleLines(agentID) else { return }
        dispatch(.screen(ScreenPatterns.parse(lines: lines)), to: agentID)
    }

    /// Effects `resampleScreen` / `reconcile`: one pending reading per agent at a time.
    func scheduleScreenSample(_ agentID: AgentID, after delay: Double) {
        guard screenSampleTasks[agentID] == nil else { return }
        screenSampleTasks[agentID] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.screenSampleTasks[agentID] = nil
            self.sampleScreen(agentID)
        }
    }

    // MARK: - Clock

    func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// 1 Hz: advances `now`, expires toasts, and ticks the agents whose rules depend on time, after a fresh screen
    /// reading for those whose rules also read the screen (T13b, T22b, T25, T28, degraded mode).
    func tick() {
        let date = Date()
        if !runtimes.isEmpty { now = date }
        expireToasts(at: date)
        for (agentID, runtime) in runtimes where Self.needsTick(runtime) {
            if Self.needsScreen(runtime) { sampleScreen(agentID) }
            dispatch(.tick, to: agentID)
        }
        releaseDeadOrphans(at: date)
    }

    /// An orphan left by a crashed app run has exited: the agent becomes an ordinary offline agent again (a fresh
    /// offline runtime, as at launch; no process is involved, so there is no reducer input for it).
    private func releaseDeadOrphans(at date: Date) {
        for (agentID, runtime) in runtimes where runtime.phase == .offline(.orphanElsewhere) {
            guard let agent = workspace.agent(agentID) else { continue }
            if let stamp = agent.lastProcess, Self.isAlive(stamp) { continue }
            let reason: OfflineReason = agent.sessions.isEmpty ? .notStarted : .appRelaunched
            storeRuntime(AgentRuntime(phase: .offline(reason), phaseSince: date), for: agentID)
        }
    }

    /// Rules driven by the clock concern a running process: launch timeouts, stale turns, provisional Stop,
    /// interrupt verification, done → idle after 10 min, degraded mode, a dialog refused with Esc.
    static func needsTick(_ runtime: AgentRuntime) -> Bool {
        guard runtime.pid != nil else { return false }
        switch runtime.phase {
        case .launching, .thinking, .working, .done:
            return true
        default:
            return runtime.pendingStop != nil || runtime.interruptRequestedAt != nil
                || runtime.hookHealth == .degraded || runtime.escapedDialogAt != nil || hasCatchUpWait(runtime)
        }
    }

    /// Rules that also read the screen: Stop commit, interrupt check, slow launch, catch-up waits, degraded mode, and
    /// T28b (a dialog refused with Esc closes only when a reading shows it gone: the 1 Hz reading keeps looking if
    /// the resample after the key missed it, for as long as the refusal counts).
    static func needsScreen(_ runtime: AgentRuntime) -> Bool {
        guard runtime.pid != nil else { return false }
        return runtime.pendingStop != nil || runtime.interruptRequestedAt != nil || runtime.phase == .launching
            || runtime.hookHealth == .degraded || runtime.escapedDialogAt != nil || hasCatchUpWait(runtime)
    }

    private static func hasCatchUpWait(_ runtime: AgentRuntime) -> Bool {
        runtime.pendingWaits.keys.contains { key in
            switch key {
            case .notification, .terminal: return true
            case .tool, .elicitation: return false
            }
        }
    }
}
