import Foundation

/// Pure reducer of an agent's runtime state: transition table T1–T31 of proposal 4.3, degraded mode (4.4)
/// and interruption (5.8). Total: every input is accepted in every state; an input whose guard fails
/// changes nothing but bookkeeping (`lastOutputAt`, `screen`…). Never reads a clock, never does I/O.
public enum AgentStateMachine {
    /// Characters of the delivered text kept in `PendingDelivery.prefix`.
    public static let deliveryPrefixLength = 40

    /// Degraded mode: PTY silence after which the agent is shown idle (4.4).
    static let degradedQuietAfter: TimeInterval = 1.5
    /// T25: output silence that makes a slow launch suspicious.
    static let launchingQuietAfter: TimeInterval = 3
    /// T28: a catch-up wait must be this old before the screen can lift it.
    static let screenLiftAfter: TimeInterval = 2
    /// T23: the screen is read again this long after a keystroke.
    static let keystrokeResampleDelay: TimeInterval = 0.3
    /// T28b: how long after an Esc on a dialog the screen is read again while the dialog is still drawn. Past it,
    /// the Esc did not close the dialog and no longer counts.
    static let escapeRefusalWindow: TimeInterval = 3

    /// Key prefix of a tool wait whose tool call is unknown: `seq-<hook sequence number>`.
    static let unpairedWaitPrefix = "seq-"
    static let askUserQuestionTool = "AskUserQuestion"

    static let waitingAnnouncement = "attend ta réponse"
    static let interruptFailedMessage = "L'interruption n'a pas pris : ouvre le terminal"
    static let degradedMessage = "Aucun hook reçu : mode dégradé"
    /// Degraded mode cannot tell tools apart: PTY output only means "active".
    static let degradedActivity = ToolKind.other("activité")

    static let quotaFiredType = "quota_auto_resume_fired"
    static let quotaStaleType = "quota_auto_resume_stale"
    static let quotaDisabledType = "quota_auto_resume_disabled"
    static let idlePromptType = "idle_prompt"
    /// `Notification` types meaning "a dialog waits for the user" (T9 catch-up).
    /// `elicitation_url_dialog` is the URL variant of `elicitation_dialog` (hooks.md).
    static let waitingNotificationTypes: Set<String> = [
        "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog",
    ]
    /// `StopFailure.error_type` values that concern the account, not the request (T14b).
    static let accountErrorTypes: Set<String> = [
        "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "billing_error",
    ]

    /// Applies one input. Returns the new runtime and the side effects for the app layer, in order.
    public static func reduce(_ runtime: AgentRuntime, _ input: AgentInput, now: Date,
                              config: ReducerConfig = ReducerConfig()) -> (AgentRuntime, [AgentEffect]) {
        var step = Step(runtime: runtime, now: now, config: config)
        switch input {
        case .processStarted(let pid, let startedAt, let withInitialPrompt):
            step.processStarted(pid: pid, startedAt: startedAt, withInitialPrompt: withInitialPrompt)
        case .processExited(let code):
            step.processExited(code: code)
        case .processFailedToStart(let message):
            step.processFailedToStart(message)
        case .hook(let event, let seq):
            step.hook(event, seq: seq)
        case .screen(let facts):
            step.screen(facts)
        case .userInterrupt:
            step.userInterrupt()
        case .userKeystroke(let key):
            step.userKeystroke(key)
        case .outputActivity:
            step.outputActivity()
        case .bell:
            step.bell()
        case .tick:
            step.tick()
        case .deliveryStarted(let delivery):
            step.deliveryStarted(delivery)
        case .deliveryAborted(let reason):
            step.deliveryAborted(reason)
        case .acknowledged:
            step.acknowledged()
        case .closeRequested:
            step.r.closeRequestedAt = now
        }
        step.clearResolvedGlobalIssues(previous: runtime.phase)
        return (step.r, step.effects)
    }

    /// `text` with whitespace runs collapsed to one space and trimmed, cut to `length` characters.
    /// Use it to build `PendingDelivery.prefix`, so that it matches the `UserPromptSubmit` prompt (T4).
    public static func normalizedPromptPrefix(_ text: String, length: Int = deliveryPrefixLength) -> String {
        var result = ""
        var pendingSpace = false
        var count = 0
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                // Never end on a space: it needs room for the character after it.
                guard count + 1 < length else { break }
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            guard count < length else { break }
            result.append(character)
            count += 1
        }
        return result
    }

    /// Whether a submitted prompt (`UserPromptSubmit`, possibly truncated) starts with a delivery prefix.
    /// Both sides are normalised, so line breaks and repeated spaces do not matter. An empty prefix matches.
    public static func prompt(_ promptHead: String, matchesDeliveryPrefix prefix: String) -> Bool {
        let wanted = normalizedPromptPrefix(prefix, length: .max)
        return normalizedPromptPrefix(promptHead, length: wanted.count).hasPrefix(wanted)
    }
}

/// One reduction in progress: the runtime being changed and the effects emitted so far.
private struct Step {
    var r: AgentRuntime
    var effects: [AgentEffect] = []
    let now: Date
    let config: ReducerConfig

    typealias SM = AgentStateMachine

    init(runtime: AgentRuntime, now: Date, config: ReducerConfig) {
        self.r = runtime
        self.now = now
        self.config = config
    }

    // MARK: - Helpers

    mutating func emit(_ effect: AgentEffect) {
        effects.append(effect)
    }

    /// Changes the phase; `phaseSince` only moves when the phase really changes.
    mutating func setPhase(_ phase: AgentPhase) {
        guard r.phase != phase else { return }
        r.phase = phase
        r.phaseSince = now
    }

    /// Opens a wait. A key that is already open changes nothing and emits nothing.
    mutating func openWait(_ key: WaitKey, _ reason: WaitReason, subagentID: String?,
                           candidates: Set<String> = []) {
        guard r.pendingWaits[key] == nil else { return }
        r.pendingWaits[key] = PendingWait(reason: reason, subagentID: subagentID, since: now,
                                          candidateToolUseIDs: candidates)
        r.acknowledgedWaiting = false
        emit(.notify(.waiting(reason)))
        emit(.playSound(.alert))
        emit(.announce(SM.waitingAnnouncement))
    }

    mutating func liftWaits(where shouldLift: (WaitKey, PendingWait) -> Bool) {
        r.pendingWaits = r.pendingWaits.filter { !shouldLift($0.key, $0.value) }
        if r.pendingWaits.isEmpty { r.acknowledgedWaiting = false }
    }

    mutating func liftAllWaits() {
        liftWaits { _, _ in true }
    }

    /// Catch-up waits (`notification`, `terminal`) are lifted by any main event except `Notification` (4.3).
    mutating func liftCatchUpWaits() {
        liftWaits { key, _ in
            switch key {
            case .notification, .terminal: return true
            case .tool, .elicitation: return false
            }
        }
    }

    /// Main tool resolved: still working if another main tool is in flight (parallel calls), otherwise thinking.
    /// Subagents' calls never set the main phase (T7). The smallest `tool_use_id` wins so that the result does
    /// not depend on delivery order.
    mutating func resumeAfterTool() {
        let main = r.inFlightTools.filter { $0.value.subagentID == nil }
        if let next = main.min(by: { $0.key < $1.key }) {
            setPhase(.working(next.value.kind))
        } else {
            setPhase(.thinking)
        }
    }

    /// Forgets the calls of one agent (`nil`: the main agent). A main turn boundary says nothing about a
    /// background subagent's calls, which keep running and reporting.
    mutating func clearInFlightTools(of subagentID: String?) {
        r.inFlightTools = r.inFlightTools.filter { $0.value.subagentID != subagentID }
    }

    /// No PTY output for at least `seconds` (or none at all).
    func quiet(for seconds: TimeInterval) -> Bool {
        guard let last = r.lastOutputAt else { return true }
        return now.timeIntervalSince(last) >= seconds
    }

    /// The last screen reading shows Claude Code's input box and no dialog.
    var screenShowsPrompt: Bool {
        guard let screen = r.screen else { return false }
        return screen.recognized && !screen.dialogVisible && screen.inputBox != .unknown
    }

    /// Fields that only make sense for a running process.
    mutating func clearProcessState() {
        r.pendingWaits = [:]
        r.inFlightTools = [:]
        r.pendingStop = nil
        r.pendingDelivery = nil
        r.interruptRequestedAt = nil
        r.escapedDialogAt = nil
        r.closeRequestedAt = nil
        r.committedStopPromptID = nil
        r.currentPromptID = nil
        r.activeSubagentIDs = []
        r.acknowledgedWaiting = false
        r.stale = false
    }

    // MARK: - Process lifecycle

    /// T1.
    mutating func processStarted(pid: Int32, startedAt: Date, withInitialPrompt: Bool) {
        clearProcessState()
        r.pid = pid
        r.launchedWithPrompt = withInitialPrompt
        r.hookHealth = .unknown(since: now)
        r.lastHookAt = nil
        r.lastOutputAt = nil
        r.screen = nil
        r.phase = .launching
        r.phaseSince = now
        emit(.recordProcess(ProcessStamp(pid: pid, startedAt: startedAt)))
    }

    /// T19, T20 (and a close requested by the user). A second exit for the same process is ignored.
    mutating func processExited(code: Int32?) {
        guard r.pid != nil else { return }
        let closedByUser = r.closeRequestedAt != nil
        let wasDelivering = r.pendingDelivery != nil
        clearProcessState()
        r.pid = nil
        r.launchedWithPrompt = false
        if closedByUser {
            setPhase(.offline(.closedByUser))
        } else if code == 0 {
            setPhase(.offline(.exited))
        } else {
            let error = AgentError.crashed(code)
            setPhase(.error(error))
            emit(.notify(.error(error)))
        }
        if let sessionID = r.currentSessionID {
            emit(.endSession(sessionID: sessionID, reason: "processExit", at: now))
        }
        r.currentSessionID = nil
        if wasDelivering { emit(.card(.deliveryFailed(.processGone))) }
        emit(.card(.sessionLost))
    }

    /// T21.
    mutating func processFailedToStart(_ message: String) {
        clearProcessState()
        r.pid = nil
        r.launchedWithPrompt = false
        setPhase(.error(.launchFailed(message)))
    }

    // MARK: - Hooks

    mutating func hook(_ event: HookEvent, seq: UInt64) {
        // A late event from a process that is gone must not bring the agent back to life.
        guard r.pid != nil else { return }
        r.lastHookAt = now
        r.hookSeq = seq
        r.hookHealth = .healthy
        r.stale = false

        let payload = event.payload
        if event.isMain {
            if let promptID = event.promptID { r.currentPromptID = promptID }
            if !payload.isNotification { liftCatchUpWaits() }
            if let stop = r.pendingStop {
                if case .userPromptSubmit = payload {
                    // A new prompt proves the provisional Stop was final: commit it without fanfare.
                    commitStop(stop, announce: false)
                } else if payload.continuesTurn {
                    // T13c: the turn was still going (blocking Stop hook, /goal).
                    r.pendingStop = nil
                }
            }
            if payload.canReopenTurn, let committed = r.committedStopPromptID, event.promptID == committed {
                emit(.card(.turnReopened(promptID: committed)))
                r.committedStopPromptID = nil
            }
        }

        apply(event, seq: seq)

        // The first main hook proves the process is up, whatever its row says about the phase.
        if event.isMain && r.phase == .launching {
            setPhase(r.launchedWithPrompt ? .thinking : .idle)
        }
    }

    mutating func apply(_ event: HookEvent, seq: UInt64) {
        let main = event.isMain
        switch event.payload {
        case .sessionStart(let source, let model):
            if main { sessionStart(event, source: source, model: model) }

        case .sessionEnd(let reason):
            // T17, T18: the next SessionStart (if any) carries the new id.
            guard main else { return }
            emit(.endSession(sessionID: event.sessionID, reason: reason, at: now))
            if r.currentSessionID == event.sessionID { r.currentSessionID = nil }

        case .userPromptSubmit(let promptHead, _):
            if main { userPromptSubmit(event, promptHead: promptHead) }

        case .askUserQuestion(let toolUseID, let questions):
            // T5.
            openWait(.tool(toolUseID: toolUseID ?? unpairedKey(seq)), .question(questions), subagentID: event.subagentID)

        case .preToolUse(let tool, let toolUseID, let summary):
            let kind = ToolKind.from(toolName: tool)
            if kind == .question {
                // AskUserQuestion whose questions could not be decoded: still a question (T5).
                openWait(.tool(toolUseID: toolUseID ?? unpairedKey(seq)), .question([]), subagentID: event.subagentID)
                return
            }
            // T6 (main) and T7 (subagent: phase unchanged).
            if let toolUseID {
                r.inFlightTools[toolUseID] = InFlightTool(tool: tool, subagentID: event.subagentID, summary: summary)
            }
            if main { setPhase(.working(kind)) }

        case .postToolUse(let tool, let toolUseID, _):
            // T12: resolves the wait and the tool of the same id.
            resolveTool(tool, toolUseID: toolUseID, subagentID: event.subagentID)
            if main { resumeAfterTool() }

        case .permissionDenied(let tool, let toolUseID):
            resolveTool(tool, toolUseID: toolUseID, subagentID: event.subagentID)
            if main { resumeAfterTool() }

        case .postToolBatch:
            // T12b: every tool of this agent's batch is resolved, including a manual denial
            // (which produces neither PostToolUse nor PermissionDenied).
            let agent = event.subagentID
            liftWaits { key, wait in
                if case .tool = key { return wait.subagentID == agent }
                return false
            }
            clearInFlightTools(of: agent)
            if main, case .working = r.phase { setPhase(.thinking) }

        case .permissionRequest(let tool, let toolUseID, let summary):
            // T8, main or subagent. The documented input has no `tool_use_id` (hooks.md): the wait takes the id
            // of the tool call it belongs to, so that the call's result lifts it (one wait per tool_use_id).
            let reason = WaitReason.permission(tool: tool, summary: summary)
            let agent = event.subagentID
            if let toolUseID {
                openWait(.tool(toolUseID: toolUseID), reason, subagentID: agent)
                return
            }
            if isWaiting(for: reason, subagentID: agent) { return }
            let candidates = pairingCandidates(tool: tool, summary: summary, subagentID: agent)
            if candidates.count == 1, let id = candidates.first {
                openWait(.tool(toolUseID: id), reason, subagentID: agent)
            } else {
                openWait(.tool(toolUseID: unpairedKey(seq)), reason, subagentID: agent, candidates: candidates)
            }

        case .notification(let type, _):
            notification(event, type: type ?? "")

        case .stop(_, let stopHookActive, let backgroundTasks, let sessionCrons):
            // T13: shown as done at once, committed by T13b after a quiet window.
            guard main else { return }
            setPhase(.done)
            r.pendingStop = PendingStop(at: now, promptID: event.promptID ?? r.currentPromptID,
                                        stopHookActive: stopHookActive,
                                        backgroundTasks: max(0, backgroundTasks), sessionCrons: max(0, sessionCrons))
            liftWaits { _, wait in wait.subagentID == nil }
            clearInFlightTools(of: nil)
            r.interruptRequestedAt = nil
            r.launchedWithPrompt = false

        case .stopFailure(let errorType, _):
            if main { stopFailure(errorType ?? "unknown") }

        case .subagent(let started, _):
            // T15, counted by `agent_id`. A stopped subagent cannot wait nor run tools any more.
            guard let subagentID = event.subagentID else { return }
            if started {
                r.activeSubagentIDs.insert(subagentID)
            } else {
                r.activeSubagentIDs.remove(subagentID)
                liftWaits { _, wait in wait.subagentID == subagentID }
                clearInFlightTools(of: subagentID)
            }

        case .elicitation(let server, let id, let message):
            // T11.
            openWait(.elicitation(id ?? unpairedKey(seq)), .elicitation(server: server, message: message),
                     subagentID: event.subagentID)

        case .elicitationResult(let server, let id):
            // T12.
            resolveElicitation(server: server, id: id, subagentID: event.subagentID)
            if main { resumeAfterTool() }

        case .compact:
            // T16: nothing to track (the scene shows it from the event stream, step 3).
            break

        case .cwdChanged(let cwd):
            // T29.
            if main { emit(.updateSessionCwd(sessionID: event.sessionID, cwd: cwd)) }

        case .other:
            break
        }
    }

    // MARK: - Tool waits without tool_use_id

    func unpairedKey(_ seq: UInt64) -> String {
        SM.unpairedWaitPrefix + String(seq)
    }

    /// The calls a `PermissionRequest` without `tool_use_id` may belong to: this agent's calls of the same tool in
    /// flight with no wait of their own. Its own `PreToolUse` always comes first (synchronous hooks, one socket
    /// connection at a time). Parallel calls of one tool usually differ by input, so calls with the same input
    /// summary are preferred; all of them are kept when none matches (input rewritten by another hook).
    func pairingCandidates(tool: String, summary: String, subagentID: String?) -> Set<String> {
        let open = r.inFlightTools.filter { id, call in
            call.tool == tool && call.subagentID == subagentID && r.pendingWaits[.tool(toolUseID: id)] == nil
        }
        let matching = open.filter { $0.value.summary == summary }
        return Set((matching.isEmpty ? open : matching).keys)
    }

    /// An id-less `PermissionRequest` that changes nothing: the same request again, or the dialog of an
    /// `AskUserQuestion` whose wait `PreToolUse` already opened (T5).
    func isWaiting(for reason: WaitReason, subagentID: String?) -> Bool {
        r.pendingWaits.values.contains { wait in
            guard wait.subagentID == subagentID else { return false }
            if case .question = wait.reason { return reason.toolName == SM.askUserQuestionTool }
            return wait.reason == reason
        }
    }

    /// T12: a tool call's result (`PostToolUse`, `PostToolUseFailure`, `PermissionDenied`) ends the call and
    /// resolves its wait. An unpaired wait is resolved by the result of its last candidate call: until then its
    /// dialog may belong to a call still running, and a sibling call that needed no permission finishing first
    /// proves nothing. A result for a call never seen in flight (its `PreToolUse` was missed) resolves instead
    /// the oldest unpaired wait of the same tool and agent that had no candidate.
    mutating func resolveTool(_ tool: String?, toolUseID: String?, subagentID: String?) {
        if let toolUseID {
            let wasInFlight = r.inFlightTools.removeValue(forKey: toolUseID) != nil
            var lifted: Set<WaitKey> = []
            var narrowed: [WaitKey: PendingWait] = [:]
            if r.pendingWaits[.tool(toolUseID: toolUseID)] != nil { lifted.insert(.tool(toolUseID: toolUseID)) }
            for (key, wait) in r.pendingWaits where wait.candidateToolUseIDs.contains(toolUseID) {
                var remaining = wait
                remaining.candidateToolUseIDs.remove(toolUseID)
                if remaining.candidateToolUseIDs.isEmpty {
                    lifted.insert(key)
                } else {
                    narrowed[key] = remaining
                }
            }
            r.pendingWaits.merge(narrowed) { _, new in new }
            if !lifted.isEmpty { liftWaits { key, _ in lifted.contains(key) } }
            if wasInFlight || !lifted.isEmpty || !narrowed.isEmpty { return }
        }
        guard let tool else { return }
        let unpaired = r.pendingWaits.compactMap { key, wait -> (id: String, since: Date)? in
            guard case .tool(let id) = key, id.hasPrefix(SM.unpairedWaitPrefix), wait.candidateToolUseIDs.isEmpty,
                  wait.subagentID == subagentID, wait.reason.toolName == tool else { return nil }
            return (id, wait.since)
        }
        guard let oldest = unpaired.min(by: { $0.since != $1.since ? $0.since < $1.since : $0.id < $1.id }) else { return }
        liftWaits { key, _ in key == .tool(toolUseID: oldest.id) }
    }

    /// T12 for MCP dialogs. `elicitation_id` is optional on both events (hooks.md shows an `Elicitation` without
    /// it and its `ElicitationResult` with it), so a result whose id matches no open wait resolves the oldest of
    /// this agent's elicitations that had no id; a result without id resolves all of this agent's elicitations.
    /// Either way, only those of the same MCP server when both sides name it.
    mutating func resolveElicitation(server: String?, id: String?, subagentID: String?) {
        if let id, r.pendingWaits[.elicitation(id)] != nil {
            liftWaits { key, _ in key == .elicitation(id) }
            return
        }
        let pool = r.pendingWaits.compactMap { key, wait -> (key: WaitKey, id: String, since: Date)? in
            guard case .elicitation(let waitID) = key, wait.subagentID == subagentID else { return nil }
            if id != nil, !waitID.hasPrefix(SM.unpairedWaitPrefix) { return nil }
            if let server, case .elicitation(let waitServer?, _) = wait.reason, waitServer != server { return nil }
            return (key, waitID, wait.since)
        }
        if id == nil {
            let keys = Set(pool.map(\.key))
            liftWaits { key, _ in keys.contains(key) }
        } else if let oldest = pool.min(by: { $0.since != $1.since ? $0.since < $1.since : $0.id < $1.id }) {
            liftWaits { key, _ in key == oldest.key }
        }
    }

    /// T2, T3.
    mutating func sessionStart(_ event: HookEvent, source: SessionSource, model: String?) {
        if r.currentSessionID != event.sessionID {
            if let previous = r.currentSessionID {
                // Its SessionEnd was missed: close it so the history stays consistent.
                emit(.endSession(sessionID: previous, reason: nil, at: now))
            }
            emit(.recordSession(SessionRef(sessionID: event.sessionID, cwd: event.cwd ?? "", startedAt: now,
                                           source: source, transcriptPath: event.transcriptPath, model: model)))
            r.currentSessionID = event.sessionID
        }
        switch source {
        case .compact:
            break
        case .clear:
            setPhase(.idle)
        case .startup, .resume, .fork, .unknown:
            switch r.phase {
            case .thinking, .working:
                // A turn is visibly running (event delivered late): do not hide it.
                break
            default:
                setPhase(r.launchedWithPrompt ? .thinking : .idle)
            }
        }
    }

    /// T4.
    mutating func userPromptSubmit(_ event: HookEvent, promptHead: String) {
        setPhase(.thinking)
        liftAllWaits()
        r.acknowledgedWaiting = false
        r.launchedWithPrompt = false
        r.committedStopPromptID = nil
        r.interruptRequestedAt = nil
        // A new turn: main tools of an earlier, interrupted turn will never report back.
        clearInFlightTools(of: nil)
        if let delivery = r.pendingDelivery, SM.prompt(promptHead, matchesDeliveryPrefix: delivery.prefix) {
            emit(.card(.deliveryConfirmed(promptID: event.promptID)))
            r.pendingDelivery = nil
        }
    }

    /// T9, T10, T14d, T14e.
    mutating func notification(_ event: HookEvent, type: String) {
        switch type {
        case SM.idlePromptType:
            // T10: the main prompt has been idle for about a minute, so no main dialog is open. Either a Stop was
            // missed, or the turn was aborted from the terminal: Esc on a permission dialog or a question ends
            // the turn with neither PostToolUse, PermissionDenied nor Stop, which would leave its wait open.
            // A usage-limit "press Enter" is typed in that very prompt: only an event proves it was pressed.
            liftWaits { key, wait in wait.subagentID == nil && key != .notification(SM.quotaStaleType) }
            clearInFlightTools(of: nil)
            switch r.phase {
            case .thinking, .working:
                setPhase(.idle)
                r.interruptRequestedAt = nil
                emit(.reconcile)
            default:
                break
            }
        case SM.quotaFiredType:
            guard case .quotaPaused = r.phase else { return }
            liftWaits { key, _ in key == .notification(SM.quotaStaleType) }
            setPhase(.thinking)
        case SM.quotaStaleType:
            // Claude Code waits for Enter whatever we believed the phase was.
            openWait(.notification(type), .notification(type: type), subagentID: event.subagentID)
        case SM.quotaDisabledType:
            guard case .quotaPaused(let resetAt, _) = r.phase else { return }
            setPhase(.quotaPaused(resetAt: resetAt, autoResume: false))
        default:
            // T9: catch-up only, when PermissionRequest/Elicitation were missed.
            guard SM.waitingNotificationTypes.contains(type), r.pendingWaits.isEmpty else { return }
            openWait(.notification(type), .notification(type: type), subagentID: event.subagentID)
        }
    }

    /// T14, T14b, T14c.
    mutating func stopFailure(_ errorType: String) {
        liftAllWaits()
        clearInFlightTools(of: nil)
        r.pendingStop = nil
        r.interruptRequestedAt = nil
        r.launchedWithPrompt = false
        if errorType == "rate_limit" {
            setPhase(.quotaPaused(resetAt: nil, autoResume: true))
            emit(.raiseGlobalIssue(.quota(resetAt: nil)))
        } else if SM.accountErrorTypes.contains(errorType) {
            setPhase(.error(.account(errorType)))
            emit(.raiseGlobalIssue(.account(errorType)))
        } else {
            let error = AgentError.api(errorType)
            setPhase(.error(error))
            emit(.card(.turnFailed))
            emit(.notify(.error(error)))
            emit(.playSound(.error))
        }
    }

    // MARK: - Stop commit (T13b)

    mutating func commitStopIfQuiet() {
        guard let stop = r.pendingStop else { return }
        let window = config.stopQuietWindow * (stop.stopHookActive ? 2 : 1)
        guard now.timeIntervalSince(stop.at) >= window else { return }
        if let screen = r.screen, screen.recognized, screen.spinnerVisible || screen.inputBox == .unknown { return }
        commitStop(stop, announce: true)
    }

    /// Confirms a provisional Stop. `announce: false` when a new prompt already follows it:
    /// the card moves, but no sound, notification or queue pump.
    mutating func commitStop(_ stop: PendingStop, announce: Bool) {
        r.pendingStop = nil
        r.committedStopPromptID = stop.promptID
        if r.phase == .done {
            if stop.backgroundTasks > 0 || stop.sessionCrons > 0 {
                setPhase(.waitingBackground(tasks: stop.backgroundTasks, crons: stop.sessionCrons))
            }
            r.phaseSince = now
        }
        if stop.backgroundTasks > 0 {
            emit(.card(.turnWaitingBackground))
            return
        }
        emit(.card(.turnCommitted(promptID: stop.promptID)))
        guard announce else { return }
        emit(.playSound(.done))
        emit(.notify(.turnDone))
        if stop.sessionCrons == 0 && config.autoChainQueue {
            emit(.pumpQueue(afterSeconds: config.sendGrace))
        }
    }

    // MARK: - Interruption (T22–T22c)

    /// T22. The app writes ESC only when `interruptRequestedAt` goes from nil to a date.
    mutating func userInterrupt() {
        guard r.interruptRequestedAt == nil, r.pendingWaits.isEmpty, r.pendingDelivery == nil else { return }
        switch r.phase {
        case .thinking, .working:
            r.interruptRequestedAt = now
            emit(.setQueuePaused(true))
            emit(.card(.interrupted))
        default:
            break
        }
    }

    /// T22b (tick or screen), T22c (tick only).
    mutating func verifyInterrupt(canGiveUp: Bool) {
        guard let requested = r.interruptRequestedAt else { return }
        // Quiet since the request itself, not only since the last output: ESC needs time to act.
        let lastActivity = max(r.lastOutputAt ?? requested, requested)
        let quiet = now.timeIntervalSince(lastActivity) >= config.interruptVerifyQuiet
        let noHookSince = r.lastHookAt.map { $0 <= requested } ?? true
        let spinnerVisible = r.screen.map { $0.recognized && $0.spinnerVisible } ?? false
        if quiet && noHookSince && !spinnerVisible {
            r.interruptRequestedAt = nil
            liftAllWaits()
            r.inFlightTools = [:]
            setPhase(.idle)
        } else if canGiveUp && now.timeIntervalSince(requested) >= config.interruptGiveUpAfter {
            // No second ESC: Esc Esc opens the rewind menu.
            r.interruptRequestedAt = nil
            emit(.showMessage(SM.interruptFailedMessage))
        }
    }

    // MARK: - Terminal signals

    /// T28, T28b, then the checks that depend on the screen.
    mutating func screen(_ facts: ScreenFacts) {
        r.screen = facts
        if screenShowsPrompt {
            let now = self.now
            liftWaits { key, wait in
                guard now.timeIntervalSince(wait.since) >= SM.screenLiftAfter else { return false }
                switch key {
                case .terminal: return true
                // "Press Enter" is typed in that very input box: only an event proves it was pressed.
                case .notification(let type): return type != SM.quotaStaleType
                case .tool, .elicitation: return false
                }
            }
        }
        closeEscapedDialog(spinnerVisible: facts.spinnerVisible)
        commitStopIfQuiet()
        verifyInterrupt(canGiveUp: false)
    }

    /// A wait whose dialog Esc refuses (T28b): a permission or an AskUserQuestion.
    static func isDialogWait(_ key: WaitKey, _ wait: PendingWait) -> Bool {
        guard case .tool = key else { return false }
        switch wait.reason {
        case .permission, .question: return true
        case .elicitation, .notification, .terminal: return false
        }
    }

    /// T28b (next to T28; the rule is not in the table of proposal 4.3). Esc on a permission dialog or on an
    /// AskUserQuestion refuses it without any hook (spikes S5 and S7, Claude Code 2.1.285): neither PostToolUse,
    /// PermissionDenied, PostToolBatch nor Stop, and the turn ends ("Interrupted · What should Claude do
    /// instead?", "User declined to answer questions"). Only the screen can tell, so after such an Esc (T23 records
    /// it, Esc being the last key), a reading that shows the input box and no dialog closes the dialog waits that
    /// were open at the Esc (their calls will never report). The phase goes back to the turn's: it goes on (spinner
    /// visible, or a hook came after the Esc) → as after a tool result (`thinking`, or `working` for another main
    /// call in flight); otherwise the refusal ended it → `idle`, as T10 would a minute later. No card moves and the
    /// queue is not pumped. While the dialog is still drawn the screen is read again, for `escapeRefusalWindow` at
    /// most. Without a prior Esc a screen without dialog closes nothing: the dialog may not be drawn yet.
    mutating func closeEscapedDialog(spinnerVisible: Bool) {
        guard let escapedAt = r.escapedDialogAt else { return }
        let refused = r.pendingWaits.filter { key, wait in wait.since <= escapedAt && Self.isDialogWait(key, wait) }
        guard !refused.isEmpty else {
            // Resolved meanwhile by the hooks: nothing left to close.
            r.escapedDialogAt = nil
            return
        }
        guard screenShowsPrompt else {
            if now.timeIntervalSince(escapedAt) < SM.escapeRefusalWindow {
                emit(.resampleScreen(afterSeconds: SM.keystrokeResampleDelay))
            } else {
                r.escapedDialogAt = nil
            }
            return
        }
        r.escapedDialogAt = nil
        liftWaits { key, _ in refused[key] != nil }
        for case .tool(let toolUseID) in refused.keys {
            r.inFlightTools.removeValue(forKey: toolUseID)
        }
        // A subagent's dialog says nothing about the main turn; after a Stop the phase is the Stop's.
        guard refused.values.contains(where: { $0.subagentID == nil }), r.pendingStop == nil else { return }
        switch r.phase {
        case .thinking, .working:
            break
        default:
            return
        }
        let hookSinceEscape = r.lastHookAt.map { $0 > escapedAt } ?? false
        if spinnerVisible || hookSinceEscape {
            resumeAfterTool()
        } else {
            clearInFlightTools(of: nil)
            setPhase(.idle)
        }
    }

    /// T23: a keystroke never lifts a wait, it only tones it down. Except in degraded mode: no hook will ever
    /// lift a "look at the terminal" wait (T25, bell), and when the screen patterns do not know this Claude Code
    /// version T28 cannot either; typing an answer in that terminal (not merely moving in it) is the only sign
    /// left that the user dealt with it. Esc on a permission or question dialog is recorded, and the screen read
    /// again, for T28b; any other key cancels that record (an answer, a move in the dialog).
    mutating func userKeystroke(_ key: KeyClass) {
        if r.hookHealth == .degraded, key != .navigation, r.pendingWaits[.terminal] != nil {
            liftWaits { waitKey, _ in waitKey == .terminal }
        }
        let onDialog = key == .escape && r.pendingWaits.contains { Self.isDialogWait($0.key, $0.value) }
        r.escapedDialogAt = onDialog ? now : nil
        if r.pendingWaits.isEmpty {
            emit(.resampleScreen(afterSeconds: SM.keystrokeResampleDelay))
        } else {
            r.acknowledgedWaiting = true
            if onDialog { emit(.resampleScreen(afterSeconds: SM.keystrokeResampleDelay)) }
        }
    }

    mutating func outputActivity() {
        r.lastOutputAt = now
        r.stale = false
        guard r.hookHealth == .degraded, r.pid != nil else { return }
        switch r.phase {
        case .idle, .launching, .done:
            setPhase(.working(SM.degradedActivity))
        default:
            break
        }
    }

    /// Degraded mode: a bell (`preferredNotifChannel: terminal_bell`) is the only waiting signal left.
    mutating func bell() {
        guard r.hookHealth == .degraded, r.pid != nil else { return }
        openWait(.terminal, .terminal, subagentID: nil)
    }

    /// T24.
    mutating func acknowledged() {
        if !r.pendingWaits.isEmpty { r.acknowledgedWaiting = true }
        if r.phase == .done && r.pendingStop == nil { setPhase(.idle) }
    }

    // MARK: - Delivery (T30, T31)

    /// Refused (nothing recorded, so the dispatcher writes nothing) unless the agent is free. Degraded mode
    /// refuses too: automatic sending is off without hooks (4.4, guard G1).
    mutating func deliveryStarted(_ delivery: PendingDelivery) {
        guard r.pid != nil, r.hookHealth == .healthy, r.pendingDelivery == nil, r.pendingWaits.isEmpty,
              r.pendingStop == nil else { return }
        switch r.phase {
        case .idle, .done:
            r.pendingDelivery = delivery
        default:
            break
        }
    }

    mutating func deliveryAborted(_ reason: DeliveryAbortReason) {
        guard r.pendingDelivery != nil else { return }
        r.pendingDelivery = nil
        emit(.card(.deliveryFailed(reason)))
        emit(.setQueuePaused(true))
    }

    // MARK: - Clock

    mutating func tick() {
        commitStopIfQuiet()
        verifyInterrupt(canGiveUp: true)

        // T24b.
        if r.phase == .done, r.pendingStop == nil, now.timeIntervalSince(r.phaseSince) >= config.doneToIdleAfter {
            setPhase(.idle)
        }

        if r.phase == .launching {
            // T25: folder trust, login… Not when the screen already shows a plain input box.
            if now.timeIntervalSince(r.phaseSince) >= config.launchingSilentAfter,
               quiet(for: SM.launchingQuietAfter), !screenShowsPrompt {
                openWait(.terminal, .terminal, subagentID: nil)
            }
            // T26.
            if case .unknown(let since) = r.hookHealth, now.timeIntervalSince(since) >= config.launchingNoHookAfter {
                r.hookHealth = .degraded
                emit(.showMessage(SM.degradedMessage))
            }
        }

        // Degraded mode (4.4): PTY silence means idle.
        if r.hookHealth == .degraded, r.pid != nil, quiet(for: SM.degradedQuietAfter) {
            switch r.phase {
            case .launching, .thinking, .working:
                setPhase(.idle)
            default:
                break
            }
        }

        // T27.
        if !r.stale {
            switch r.phase {
            case .thinking, .working:
                let lastNews = r.lastHookAt ?? r.phaseSince
                if now.timeIntervalSince(lastNews) >= config.staleNoHookAfter, quiet(for: config.staleNoOutputAfter) {
                    r.stale = true
                    emit(.reconcile)
                }
            default:
                break
            }
        }
    }

    // MARK: - Global issues

    /// Leaving the quota pause, or an account error for a state that proves the account works,
    /// clears the matching global issue (the app keeps it while another agent still has it).
    mutating func clearResolvedGlobalIssues(previous: AgentPhase) {
        if case .quotaPaused = previous, !r.phase.isQuotaPaused {
            emit(.clearGlobalIssue(.quota))
        }
        if case .error(.account) = previous, r.phase.provesAccountWorks {
            emit(.clearGlobalIssue(.account))
        }
    }
}

private extension HookPayload {
    var isNotification: Bool {
        if case .notification = self { return true }
        return false
    }

    /// A main event of this kind after a provisional Stop means the turn was still going (T13c).
    /// Session boundaries, compaction, cwd changes and notifications do not.
    var continuesTurn: Bool {
        switch self {
        case .userPromptSubmit, .preToolUse, .askUserQuestion, .postToolUse, .postToolBatch, .permissionRequest,
             .permissionDenied, .stop, .stopFailure, .elicitation, .elicitationResult:
            return true
        case .sessionStart, .sessionEnd, .notification, .subagent, .compact, .cwdChanged, .other:
            return false
        }
    }

    /// Events that reopen a committed turn when they carry its `prompt_id` (T13c).
    var canReopenTurn: Bool {
        switch self {
        case .preToolUse, .askUserQuestion, .postToolUse, .permissionRequest, .stop:
            return true
        default:
            return false
        }
    }
}

private extension WaitReason {
    /// The tool whose call this wait blocks, if any.
    var toolName: String? {
        switch self {
        case .permission(let tool, _): return tool
        case .question: return AgentStateMachine.askUserQuestionTool
        case .elicitation, .notification, .terminal: return nil
        }
    }
}

private extension AgentPhase {
    var isQuotaPaused: Bool {
        if case .quotaPaused = self { return true }
        return false
    }

    /// The API answered for this account (a rate limit or a request error still means it is signed in).
    var provesAccountWorks: Bool {
        switch self {
        case .idle, .thinking, .working, .done, .waitingBackground, .quotaPaused, .error(.api):
            return true
        case .offline, .launching, .error:
            return false
        }
    }
}
