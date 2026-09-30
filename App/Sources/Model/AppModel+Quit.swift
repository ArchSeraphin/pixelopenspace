import AppKit
import Foundation
import PixelCore

/// Quitting cleanly (proposal 2.5): a `claude` session lives as long as the app, so quitting while agents are busy
/// first asks the user (quit sheet, mockup 6(p)).
///
/// Flow: ⌘Q → `AppDelegate.applicationShouldTerminate` → `handleTerminationRequest()`. With busy agents it sets
/// `quitRequest` and cancels this termination; the UI shows the sheet and answers with `respondToQuit(_:)`, which
/// terminates again once approved (`requestTermination()`). The actual quit closes every session (SIGTERM to each
/// process group, SIGKILL after the grace period), stops the hook server and writes the state, then replies to AppKit.
extension AppModel {
    /// Grace between SIGTERM and SIGKILL when quitting: normal quit, "Quitter quand même".
    static let quitGrace: Duration = .seconds(5)
    static let forcedQuitGrace: Duration = .seconds(2)

    /// Agents that quitting would interrupt: thinking, working, waiting for the user, a provisional Stop, waiting
    /// for background tasks, paused by the usage limit.
    func prepareToQuit() -> QuitAssessment {
        var busy: [QuitEntry] = []
        var running = 0
        for agent in agentsInOrder {
            guard let runtime = runtimes[agent.id], runtime.pid != nil else { continue }
            running += 1
            guard Self.isBusy(runtime) else { continue }
            busy.append(QuitEntry(agentID: agent.id, agentName: agent.name,
                                  projectName: workspace.project(agent.projectID)?.name ?? "",
                                  display: AgentPresenter.present(runtime, now: Date())))
        }
        return QuitAssessment(busy: busy, runningSessions: running)
    }

    static func isBusy(_ runtime: AgentRuntime) -> Bool {
        guard runtime.pid != nil else { return false }
        if !runtime.pendingWaits.isEmpty || runtime.pendingStop != nil { return true }
        switch runtime.phase {
        case .thinking, .working, .waitingBackground, .quotaPaused:
            return true
        default:
            return false
        }
    }

    /// `NSApplicationDelegate.applicationShouldTerminate`.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        if quitInProgress { return .terminateLater }
        if !quitApproved {
            let assessment = prepareToQuit()
            if !assessment.canQuitImmediately {
                quitRequest = QuitRequest(id: UUID(), assessment: assessment)
                NSApplication.shared.activate()
                return .terminateCancel
            }
        }
        quitInProgress = true
        quitRequest = nil
        isWaitingForTurnsToQuit = false
        let force = quitForcefully
        Task { [weak self] in
            await self?.finishQuit(force: force)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The quit sheet's answer.
    func respondToQuit(_ choice: QuitChoice) {
        quitRequest = nil
        switch choice {
        case .cancel:
            isWaitingForTurnsToQuit = false
        case .quitAnyway:
            quitApproved = true
            quitForcefully = true
            requestTermination()
        case .waitForTurns:
            waitForTurnsThenQuit()
        }
    }

    /// Quits by itself as soon as no agent is busy (a wait still needs the user's answer).
    func waitForTurnsThenQuit() {
        isWaitingForTurnsToQuit = true
        if prepareToQuit().canQuitImmediately {
            quitIfIdle()
        } else {
            showToast("Pixel Open Space quittera à la fin des tours en cours.")
        }
    }

    func cancelWaitingForTurns() {
        isWaitingForTurnsToQuit = false
        // Deliveries were held while waiting to quit.
        dispatcher.pumpAll()
    }

    /// Checked after every state change while waiting for the turns to end.
    func quitIfIdle() {
        guard isWaitingForTurnsToQuit, !quitInProgress, prepareToQuit().canQuitImmediately else { return }
        isWaitingForTurnsToQuit = false
        quitApproved = true
        requestTermination()
    }

    /// Asks AppKit to quit from a run-loop timer, never synchronously from the caller (`dispatch`, a `Task`).
    ///
    /// `handleTerminationRequest()` answers `.terminateLater`: AppKit then runs a nested run loop until the task that
    /// runs `finishQuit` replies. A run loop nested in a main-queue block (every main-actor job is one) does not drain
    /// the main queue, so that task could never run and the app would hang. A timer callback is not such a block.
    func requestTermination() {
        NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// Closes every running session: `.closeRequested` for each (exits read as closed, not crashed), SIGTERM to each
    /// process group, SIGKILL after the grace period (2 s with `force`, otherwise 5 s).
    func terminateAllSessions(force: Bool) async {
        for agentID in sessions.runningAgents where runtimes[agentID]?.pid != nil {
            dispatch(.closeRequested, to: agentID)
        }
        await sessions.terminateAll(grace: force ? Self.forcedQuitGrace : Self.quitGrace)
    }

    private func finishQuit(force: Bool) async {
        await terminateAllSessions(force: force)
        hookServer.stop()
        await flushPersistence()
    }
}
