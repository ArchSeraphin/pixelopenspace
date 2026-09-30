import Foundation
import Observation
import PixelCore

/// What an agent's card says about its queue besides the `WaitCause` (French texts in the UI).
enum DeliveryNotice: Equatable, Sendable {
    /// The last delivery failed, for this reason (French). Shown until the queue is resumed or a delivery starts.
    case failed(String)
    /// The head of the queue is 16 KB or more: it goes only once the user confirms ("Envoyer").
    case needsConfirmation(QueueItem, bytes: Int)
}

/// Delivers the head of each agent's queue into its terminal (proposal 3.6, 5.6): decides with `DispatchPolicy`,
/// plans with `DeliveryPlan`, runs the plan step by step against the agent's `TerminalHost`, and changes the state only
/// through the two reducers (`deliveryStarted` / `deliveryAborted` for `AgentStateMachine`, `deliveryStarted` for
/// `TaskLifecycle`). It never writes anything but the plan's writes (text, paste markers, `\r`): no arrow, no Ctrl
/// key, no answer to a dialog.
///
/// - `pump(_:)` is asked by the reducers' effects (`.pump`, `.pumpQueue`), by the intents (resume, "Envoyer quand
///   même"), and by `runtimeChanged` when an agent with a queue may have become free. Requests are coalesced and run
///   on a later main-actor turn, never inside a reduction. A queue held by the screen alone (rule 11 of
///   `DispatchPolicy`) is looked at again by the pump itself, with a bounded backoff: for an idle agent nothing
///   else reads the screen again but a keystroke.
/// - One delivery per agent at a time, in its own `Task`. Every `check` reads the screen, then the hook server's
///   per-agent counter (G2), right before the write that follows it, with no suspension in between; every `write`
///   first checks that the same process still runs. A failed guard aborts (queue paused, card flagged), never "try
///   anyway". The Enter after a failed guard is never written.
/// - A launch with the card's text as its positional prompt ("Lancer un nouvel agent avec ce post-it") runs no plan:
///   its delivery is recorded at the launch (T30b) and confirmed by that prompt's `UserPromptSubmit`.
@MainActor
@Observable
final class TaskDispatcher {
    /// Longest wait for a write to reach the PTY (a child that stops reading its input).
    static let writeTimeout: Duration = .seconds(10)
    /// How often `expectPromptSubmit` looks for the confirmation.
    static let confirmationPoll: Duration = .milliseconds(50)

    // Reasons of the dispatcher's own aborts, in French (the guards' are `DeliveryPlan`'s).

    /// A long text needs a bracketed paste (5.6): without one, nothing is sent blind.
    static let tooLongReason = "trop long pour un envoi sûr"
    static let emptyReason = "texte vide après nettoyage"
    static let writeFailedReason = "écriture dans le terminal impossible"
    static let writeStalledReason = "le terminal ne lit plus ce qui lui est écrit"
    static let notHeadReason = "le post-it n'est plus en tête de la file"

    @ObservationIgnored weak var model: AppModel?

    /// When each agent's last turn was confirmed (`turnCommitted`): the grace delay before the next delivery.
    private(set) var lastTurnEndedAt: [AgentID: Date] = [:]
    /// "Envoyer quand même": the text of the input box the user agreed to type over (the draft prefix read then,
    /// meant to be a grey suggestion of Claude Code). The next delivery of the agent ignores that draft, and only it,
    /// while the box still shows it (`DispatchPolicy.draftOverrideHolds`); any other text lapses the agreement.
    private(set) var draftOverrides: [AgentID: String] = [:]
    private(set) var notices: [AgentID: DeliveryNotice] = [:]

    /// Items of 16 KB or more the user agreed to send.
    @ObservationIgnored private var confirmedLargeItems: Set<QueueItem> = []
    @ObservationIgnored private var deliveries: [AgentID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pumpRequests: Set<AgentID> = []
    @ObservationIgnored private var delayedPumps: [AgentID: (at: Date, task: Task<Void, Never>)] = [:]
    /// Pumps in a row that the screen alone held (rule 11): the backoff of the next look.
    @ObservationIgnored private var screenRechecks: [AgentID: Int] = [:]
    /// "Lancer un nouvel agent avec ce post-it": the item and the text given as the positional prompt, until the
    /// process starts.
    @ObservationIgnored private var positionalLaunches: [AgentID: (item: QueueItem, text: String)] = [:]
    /// The agent whose screen the dispatcher is reading: that reading does not ask for another pump.
    @ObservationIgnored private var sampling: AgentID?

    // MARK: - Requests

    /// Looks at the agent's queue on the next main-actor turn (several requests make one look).
    func pump(_ agentID: AgentID) {
        guard pumpRequests.insert(agentID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            self.pumpRequests.remove(agentID)
            self.runPump(agentID)
        }
    }

    /// `pumpQueue(afterSeconds:)` (T13b), and the end of a grace delay. The earliest pending request is kept: a pump
    /// that comes too early waits again.
    func pump(_ agentID: AgentID, after seconds: Double) {
        guard seconds > 0 else { return pump(agentID) }
        let at = Date().addingTimeInterval(seconds)
        if let pending = delayedPumps[agentID], pending.at <= at { return }
        delayedPumps[agentID]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.delayedPumps[agentID] = nil
            self.pump(agentID)
        }
        delayedPumps[agentID] = (at, task)
    }

    /// Every agent of a live project (an archived project's queue is never delivered).
    func pumpAll() {
        guard let model else { return }
        for agent in model.agentsInOrder { pump(agent.id) }
    }

    /// Called after every reduction: an agent whose runtime changed in a way that may free its queue (phase, waits,
    /// provisional Stop, hooks, process, delivery, screen) is looked at again when its queue could go on but for the
    /// screen, which the pump reads afresh.
    func runtimeChanged(_ agentID: AgentID, from old: AgentRuntime, to new: AgentRuntime) {
        guard sampling != agentID, deliveries[agentID] == nil, new.pid != nil, new.pendingDelivery == nil,
              Self.mayFreeQueue(old, new), let model, let agent = model.agent(agentID) else { return }
        // Busy, waiting or before a confirmed Stop: the policy would say so (rules 5 to 8), without the queue.
        guard new.pendingWaits.isEmpty, new.pendingStop == nil, new.phase == .idle || new.phase == .done else { return }
        let queue = model.queue(of: agentID)
        guard !queue.isEmpty else { return }
        switch DispatchPolicy.decisionBeforeScreen(agent: agent, runtime: new, queue: queue, now: Date(),
                                                   lastTurnEndedAt: lastTurnEndedAt[agentID],
                                                   settings: DispatchSettings(settings: model.settings)) {
        case .deliver, .wait(.cooldown):
            pump(agentID)
        case .wait, .none:
            break
        }
    }

    static func mayFreeQueue(_ old: AgentRuntime, _ new: AgentRuntime) -> Bool {
        old.phase != new.phase || old.pendingWaits.count != new.pendingWaits.count
            || (old.pendingStop == nil) != (new.pendingStop == nil) || old.hookHealth != new.hookHealth
            || old.pid != new.pid || old.pendingDelivery != new.pendingDelivery || old.screen != new.screen
    }

    /// A turn was confirmed (`turnCommitted`, before the card moves): the grace delay starts now.
    func turnEnded(_ agentID: AgentID) {
        lastTurnEndedAt[agentID] = Date()
    }

    // MARK: - User actions

    /// "Envoyer quand même", agreed for `shown` (the draft prefix the user was warned about): the next delivery goes
    /// despite that text in the input box, as long as the box still shows it. Every other guard stays.
    func sendAnyway(_ agentID: AgentID, over shown: String) {
        draftOverrides[agentID] = shown
        pump(agentID)
    }

    /// Whether "Envoyer quand même" lifts the draft of `screen` for this agent (the text agreed to, still shown).
    func draftOverride(for agentID: AgentID, screen: ScreenFacts?) -> Bool {
        DispatchPolicy.draftOverrideHolds(agreed: draftOverrides[agentID], screen: screen)
    }

    /// "Envoyer" on a text of 16 KB or more.
    func confirmLargeDelivery(_ agentID: AgentID) {
        guard case .needsConfirmation(let item, _)? = notices[agentID] else { return }
        confirmedLargeItems.insert(item)
        notices[agentID] = nil
        pump(agentID)
    }

    /// The queue was resumed by the user: the last failure is settled.
    func queueResumed(_ agentID: AgentID) {
        if case .failed? = notices[agentID] { notices[agentID] = nil }
        pump(agentID)
    }

    /// The agent was removed: its delivery (if any) stops, its state goes.
    func forget(_ agentID: AgentID) {
        deliveries.removeValue(forKey: agentID)?.cancel()
        delayedPumps.removeValue(forKey: agentID)?.task.cancel()
        positionalLaunches[agentID] = nil
        lastTurnEndedAt[agentID] = nil
        draftOverrides[agentID] = nil
        screenRechecks[agentID] = nil
        notices[agentID] = nil
    }

    // MARK: - Positional prompt (T30b)

    /// Before `AppModel.launch(_:mode:)` with `text` as the positional prompt: `item` (the head of the new agent's
    /// queue) is marked delivered once the process starts.
    func expectPositionalLaunch(_ agentID: AgentID, item: QueueItem, text: String) {
        positionalLaunches[agentID] = (item, text)
    }

    /// The process started (after `.processStarted` was reduced). With a positional prompt registered for it, the
    /// delivery of its item is recorded, to be confirmed by that prompt's `UserPromptSubmit`.
    func launched(_ agentID: AgentID, withPrompt: Bool) {
        guard let launch = positionalLaunches.removeValue(forKey: agentID), withPrompt, let model else { return }
        guard model.queue(of: agentID).first == launch.item else {
            AppLog.sessions.info("positional delivery for \(agentID.description, privacy: .public): item no longer at the head")
            return
        }
        // What Claude Code submits: the planner may prefix the text (a single word, a leading "-"…).
        let submitted = LaunchPlanner.positionalPrompt(launch.text) ?? launch.text
        let pending = PendingDelivery(itemID: Self.itemID(launch.item),
                                      prefix: AgentStateMachine.normalizedPromptPrefix(submitted), startedAt: Date(),
                                      hookSeqAtStart: model.hookServer.arrivals.count(for: agentID))
        guard begin(launch.item, pending, agentID: agentID, sessionID: nil) else {
            // The agent works on the card's text anyway: its queue must not send it a second time.
            model.setQueuePaused(true, for: agentID)
            return
        }
        AppLog.sessions.info("positional delivery for \(agentID.description, privacy: .public) started")
    }

    /// The launch did not start a process: nothing to record.
    func launchFailed(_ agentID: AgentID) {
        positionalLaunches[agentID] = nil
    }

    // MARK: - Decision

    private func runPump(_ agentID: AgentID) {
        guard let model, deliveries[agentID] == nil, model.acceptsDeliveries, model.workspace.isLiveAgent(agentID),
              let agent = model.agent(agentID), let runtime = model.runtime(for: agentID) else { return }
        let queue = model.queue(of: agentID)
        guard let head = queue.first else {
            notices[agentID] = nil
            draftOverrides[agentID] = nil
            screenRechecks[agentID] = nil
            return
        }
        if case .needsConfirmation(let item, _)? = notices[agentID], item != head { notices[agentID] = nil }
        let settings = DispatchSettings(settings: model.settings)
        let before = DispatchPolicy.decisionBeforeScreen(agent: agent, runtime: runtime, queue: queue, now: Date(),
                                                         lastTurnEndedAt: lastTurnEndedAt[agentID], settings: settings)
        guard case .deliver = before else {
            // Busy, waiting, paused, offline…: a hook, the clock or the user brings the queue back.
            screenRechecks[agentID] = nil
            if before == .wait(.cooldown) { pumpAfterCooldown(agentID, settings: settings) }
            return
        }

        // A fresh reading, reduced like any other (T13b, T28…), then the whole policy.
        sampling = agentID
        model.sampleScreen(agentID)
        sampling = nil
        guard let fresh = model.runtime(for: agentID), let current = model.agent(agentID) else { return }
        let overridesDraft = draftOverride(for: agentID, screen: fresh.screen)
        if !overridesDraft { draftOverrides[agentID] = nil }
        let freshQueue = model.queue(of: agentID)
        let now = Date()
        let decision = DispatchPolicy.nextDelivery(agent: current, runtime: fresh, queue: freshQueue, now: now,
                                                   lastTurnEndedAt: lastTurnEndedAt[agentID], settings: settings,
                                                   draftOverride: overridesDraft)
        switch decision {
        case .deliver(let item):
            screenRechecks[agentID] = nil
            start(item, for: agentID)
        case .wait(.cooldown):
            screenRechecks[agentID] = nil
            pumpAfterCooldown(agentID, settings: settings)
        case .wait:
            let beforeScreen = DispatchPolicy.decisionBeforeScreen(agent: current, runtime: fresh, queue: freshQueue,
                                                                   now: now, lastTurnEndedAt: lastTurnEndedAt[agentID],
                                                                   settings: settings)
            if case .deliver = beforeScreen {
                recheckScreen(agentID)
            } else {
                screenRechecks[agentID] = nil
            }
        case .none:
            screenRechecks[agentID] = nil
        }
    }

    /// The screen alone holds the queue (rule 11: not recognised, no input box yet, a spinner, a dialog or the
    /// usage-limit line without any hook, a draft). For an idle agent no hook will come and only a keystroke reads
    /// the screen again, so the pump looks again itself: 0.5 s, 1 s, 2 s, then every 4 s
    /// (`DispatchPolicy.screenRecheckDelay`), until the screen lets the delivery start or another rule takes over.
    private func recheckScreen(_ agentID: AgentID) {
        let attempt = screenRechecks[agentID, default: 0]
        screenRechecks[agentID] = min(attempt + 1, DispatchPolicy.screenRecheckDelays.count)
        pump(agentID, after: DispatchPolicy.screenRecheckDelay(attempt: attempt))
    }

    private func pumpAfterCooldown(_ agentID: AgentID, settings: DispatchSettings) {
        guard let remaining = DispatchPolicy.cooldownRemaining(now: Date(), lastTurnEndedAt: lastTurnEndedAt[agentID],
                                                               settings: settings) else { return }
        pump(agentID, after: remaining + 0.05)
    }

    // MARK: - Delivery

    /// Composes and cleans the text, plans the writes, records the delivery in both reducers, then runs the plan.
    private func start(_ item: QueueItem, for agentID: AgentID) {
        guard let model, let host = model.sessions.host(for: agentID), host.isRunning,
              let runtime = model.runtime(for: agentID), let prompt = prompt(for: item) else { return }
        let bytes = prompt.text.utf8.count
        if prompt.needsConfirmation, !confirmedLargeItems.contains(item) {
            notices[agentID] = .needsConfirmation(item, bytes: bytes)
            return
        }
        let agreedDraft = draftOverrides.removeValue(forKey: agentID)
        let steps = prompt.isEmpty ? nil : DeliveryPlan.make(prompt, bracketedPaste: host.bracketedPasteMode)
        let pending = PendingDelivery(itemID: Self.itemID(item), prefix: DeliveryPlan.prefix(for: prompt),
                                      startedAt: Date(), hookSeqAtStart: model.hookServer.arrivals.count(for: agentID))
        guard begin(item, pending, agentID: agentID, sessionID: runtime.currentSessionID) else { return }
        confirmedLargeItems.remove(item)
        notices[agentID] = nil
        guard let steps else {
            // Nothing can be written safely: the delivery fails at once, nothing written.
            abort(.guardFailed(prompt.isEmpty ? Self.emptyReason : Self.tooLongReason), agentID: agentID)
            return
        }
        AppLog.sessions.info("delivery to \(agentID.description, privacy: .public): \(bytes) bytes, \(prompt.isShort ? "typed" : "pasted", privacy: .public)")
        deliveries[agentID] = Task { [weak self] in
            await self?.execute(steps, pending: pending, agentID: agentID, host: host, agreedDraft: agreedDraft)
            self?.deliveries[agentID] = nil
        }
    }

    /// T30 then C6. False, with nothing written, when the agent's reducer refuses the delivery.
    private func begin(_ item: QueueItem, _ pending: PendingDelivery, agentID: AgentID, sessionID: String?) -> Bool {
        guard let model else { return false }
        model.dispatch(.deliveryStarted(pending), to: agentID)
        guard model.runtime(for: agentID)?.pendingDelivery == pending else {
            AppLog.sessions.info("delivery to \(agentID.description, privacy: .public) refused by the state machine")
            return false
        }
        let effects = model.applyTask(.deliveryStarted(item, agent: agentID, sessionID: sessionID))
        if effects.contains(where: { if case .rejected = $0 { return true } else { return false } }) {
            abort(.guardFailed(Self.notHeadReason), agentID: agentID)
            return false
        }
        return true
    }

    /// Runs the plan (then, once, the retry of 5.6 step 7). Stops at once when the delivery is no longer the
    /// agent's pending one (confirmed, or ended by the process's exit: the reducer already told the card).
    private func execute(_ plan: [DeliveryStep], pending: PendingDelivery, agentID: AgentID, host: TerminalHost,
                         agreedDraft: String?) async {
        var steps = plan[...]
        var retried = false
        var textWritten = false
        while let step = steps.popFirst() {
            guard !Task.isCancelled, isPending(pending, agentID) else { return }
            switch step {
            case .check(let check):
                guard isLive(host, agentID) else { return abort(.processGone, agentID: agentID) }
                let inputs = guardInputs(check, pending: pending, agentID: agentID, host: host,
                                         agreedDraft: agreedDraft)
                if case .abort(let reason) = DeliveryPlan.evaluate(check, inputs) {
                    let detail = DeliveryPlan.abortDetail(reason, textWritten: textWritten)
                    return abort(.guardFailed(detail), agentID: agentID)
                }
            case .write(let bytes):
                guard isLive(host, agentID) else { return abort(.processGone, agentID: agentID) }
                let outcome = await host.writeAndWait(bytes, timeout: Self.writeTimeout)
                textWritten = true
                switch outcome {
                case .written:
                    break
                case .failed:
                    guard isLive(host, agentID) else { return abort(.processGone, agentID: agentID) }
                    let detail = DeliveryPlan.abortDetail(Self.writeFailedReason, textWritten: true)
                    return abort(.guardFailed(detail), agentID: agentID)
                case .timedOut:
                    let detail = DeliveryPlan.abortDetail(Self.writeStalledReason, textWritten: true)
                    return abort(.guardFailed(detail), agentID: agentID)
                }
            case .awaitWriteCompletion:
                // Every write above already waited for its completion.
                break
            case .sleep(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))
            case .expectPromptSubmit(let within):
                guard await waitForConfirmation(pending, agentID: agentID, within: within) else {
                    AppLog.sessions.info("delivery to \(agentID.description, privacy: .public) confirmed or ended")
                    return
                }
                if retried { return abort(.noPromptSubmit, agentID: agentID) }
                retried = true
                AppLog.sessions.info("delivery to \(agentID.description, privacy: .public): no UserPromptSubmit, one more guarded Enter")
                steps = DeliveryPlan.retrySteps(prefix: pending.prefix)[...]
            }
        }
    }

    /// True when the deadline passed with the delivery still pending; false as soon as it is not (confirmed by
    /// `UserPromptSubmit`, or ended by the reducer).
    private func waitForConfirmation(_ pending: PendingDelivery, agentID: AgentID, within milliseconds: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(milliseconds))
        while clock.now < deadline {
            try? await Task.sleep(for: Self.confirmationPoll)
            if Task.isCancelled || !isPending(pending, agentID) { return false }
        }
        return isPending(pending, agentID)
    }

    /// What the guard reads, right now: the screen, then the hook counter, then the state. "Envoyer quand même"
    /// counts before the text only, and only while the input box shows the very text the user agreed to type over.
    private func guardInputs(_ check: DeliveryGuard, pending: PendingDelivery, agentID: AgentID, host: TerminalHost,
                             agreedDraft: String?) -> GuardInputs {
        let screen = ScreenPatterns.parse(lines: host.visibleLines())
        let screenAt = Date()
        let hookSeqNow = model?.hookServer.arrivals.count(for: agentID) ?? .max
        let runtime = model?.runtime(for: agentID) ?? AgentRuntime(phaseSince: screenAt)
        let paused = model?.agent(agentID)?.queuePaused ?? true
        return GuardInputs(runtime: runtime, queuePaused: paused, hookSeqAtStart: pending.hookSeqAtStart,
                           hookSeqNow: hookSeqNow, screen: screen, screenAt: screenAt,
                           lastOutputAt: host.lastOutputAt, now: Date(),
                           draftOverride: check == .beforeText
                               && DispatchPolicy.draftOverrideHolds(agreed: agreedDraft, screen: screen))
    }

    /// T31: the machine flags the card and pauses the queue; the card of the agent says why.
    private func abort(_ reason: DeliveryAbortReason, agentID: AgentID) {
        let text: String
        switch reason {
        case .guardFailed(let detail): text = detail
        case .noPromptSubmit: text = "aucune confirmation de Claude Code"
        case .processGone: text = "session terminée"
        }
        notices[agentID] = .failed(text)
        AppLog.sessions.info("delivery to \(agentID.description, privacy: .public) aborted: \(text, privacy: .public)")
        model?.dispatch(.deliveryAborted(reason), to: agentID)
    }

    // MARK: - Helpers

    private func isPending(_ pending: PendingDelivery, _ agentID: AgentID) -> Bool {
        model?.runtime(for: agentID)?.pendingDelivery == pending
    }

    /// The process the delivery started with still runs, and is still the agent's.
    private func isLive(_ host: TerminalHost, _ agentID: AgentID) -> Bool {
        guard let model, host.isRunning, model.sessions.host(for: agentID) === host,
              let pid = model.runtime(for: agentID)?.pid else { return false }
        return pid == host.pid
    }

    /// The text of a queue item, exactly as it will be typed: a card's prompt (its template, `PromptComposer`), or
    /// an instruction's text, cleaned by `PromptSanitizer`.
    private func prompt(for item: QueueItem) -> SanitizedPrompt? {
        guard let model else { return nil }
        switch item {
        case .card(let id):
            return model.promptPreview(for: id)
        case .instruction(let id):
            return model.board.instructions.first { $0.id == id }.map { PromptSanitizer.sanitize($0.text) }
        }
    }

    static func itemID(_ item: QueueItem) -> String {
        switch item {
        case .card(let id): id.description
        case .instruction(let id): id.description
        }
    }
}
