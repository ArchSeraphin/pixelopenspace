import Foundation

/// Why the head of an agent's queue is not delivered now (shown on the agent's card when its queue is not empty).
public enum WaitCause: Equatable, Sendable, CaseIterable {
    case busy, waitingInput, waitingBackground, quotaPaused, draftInInputBox, screenUnknown, paused, offline,
         hooksUnhealthy, cooldown, deliveryInProgress

    /// Short French text for the agent's card and the status bar.
    public var label: String {
        switch self {
        case .busy: "occupé"
        case .waitingInput: "attend ta réponse"
        case .waitingBackground: "attend une tâche de fond"
        case .quotaPaused: "en pause : limite d'usage"
        case .draftInInputBox: "✎ brouillon"
        case .screenUnknown: "écran non reconnu"
        case .paused: "file en pause"
        case .offline: "hors ligne"
        case .hooksUnhealthy: "hooks non reçus : envoi automatique coupé"
        case .cooldown: "pause entre deux tâches"
        case .deliveryInProgress: "envoi en cours"
        }
    }
}

/// What to do with an agent's queue now.
public enum DeliveryDecision: Equatable, Sendable {
    /// Start a guarded delivery (`DeliveryPlan`) of this item, the head of the queue.
    case deliver(QueueItem)
    /// Keep the queue as it is; the cause is shown.
    case wait(WaitCause)
    /// The queue is empty.
    case none
}

/// Queue settings from `AppSettings`.
public struct DispatchSettings: Equatable, Sendable {
    /// `AppSettings.autoChainQueue`: deliver the next item right after a confirmed `Stop`.
    public var autoChain: Bool
    /// `AppSettings.sendGraceSeconds`: delay after the end of a turn before the next delivery.
    public var graceSeconds: Double

    public init(autoChain: Bool = true, graceSeconds: Double = 1.5) {
        self.autoChain = autoChain
        self.graceSeconds = graceSeconds
    }

    public init(settings: AppSettings) {
        self.init(autoChain: settings.autoChainQueue, graceSeconds: settings.sendGraceSeconds)
    }
}

/// When an agent's queue may deliver, and which agent a post-it goes to (proposal 3.6, 5.6 "Sémantique de la
/// file"). Pure and deterministic. It only decides whether to start: the guards of `DeliveryPlan` still check
/// every write against a fresh screen and the hook counter, and abort (queue paused) when they fail. The rules
/// below that read the screen keep the queue waiting, without that failure, while `runtime.screen` already shows
/// a guard would fail.
public enum DispatchPolicy {
    /// The decision for the head of `queue` (`BoardQuery.queue(of:in:)`). The first rule that matches wins:
    ///  1. empty queue → `.none`;
    ///  2. `agent.queuePaused` → `.paused`;
    ///  3. no process (`pid == nil`, or an offline phase) → `.offline`;
    ///  4. `hookHealth != .healthy` (degraded mode, or no hook yet since launch) → `.hooksUnhealthy`;
    ///  5. an open wait → `.waitingInput`;
    ///  6. `waitingBackground` → `.waitingBackground`; `quotaPaused` → `.quotaPaused`;
    ///  7. `pendingDelivery != nil` → `.deliveryInProgress`;
    ///  8. a phase other than `idle`/`done` (launching, thinking, working, error with a live process), or a
    ///     provisional `Stop` → `.busy`;
    ///  9. less than `graceSeconds` since `lastTurnEndedAt` → `.cooldown` (a stamp after `now` counts as within);
    /// 10. `autoChain == false` and phase `done` → `.cooldown` until the user acts: looking at the agent turns
    ///     `done` into `idle` (T24, or T24b after 10 min), and an `idle` agent gets its queue (auto-chaining only
    ///     concerns the turn that just ended);
    /// 11. screen: none read, or not recognized, → `.screenUnknown`; a dialog → `.waitingInput`; the usage limit
    ///     line → `.quotaPaused`; a spinner → `.busy`; no input box → `.screenUnknown`; a draft in the input
    ///     box → `.draftInInputBox`, unless `draftOverride` ("Envoyer quand même", which lifts nothing else);
    /// 12. otherwise `.deliver(queue[0])`.
    public static func nextDelivery(agent: Agent, runtime: AgentRuntime, queue: [QueueItem], now: Date,
                                    lastTurnEndedAt: Date?, settings: DispatchSettings,
                                    draftOverride: Bool) -> DeliveryDecision {
        guard let head = queue.first else { return .none }
        if agent.queuePaused { return .wait(.paused) }
        guard isLive(runtime) else { return .wait(.offline) }
        guard runtime.hookHealth == .healthy else { return .wait(.hooksUnhealthy) }
        guard runtime.pendingWaits.isEmpty else { return .wait(.waitingInput) }
        switch runtime.phase {
        case .waitingBackground: return .wait(.waitingBackground)
        case .quotaPaused: return .wait(.quotaPaused)
        default: break
        }
        guard runtime.pendingDelivery == nil else { return .wait(.deliveryInProgress) }
        guard runtime.phase == .idle || runtime.phase == .done, runtime.pendingStop == nil else {
            return .wait(.busy)
        }
        if let ended = lastTurnEndedAt, now.timeIntervalSince(ended) < settings.graceSeconds {
            return .wait(.cooldown)
        }
        if !settings.autoChain && runtime.phase == .done { return .wait(.cooldown) }
        if let cause = screenCause(runtime.screen, draftOverride: draftOverride) { return .wait(cause) }
        return .deliver(head)
    }

    /// The agent a post-it dropped on a project goes to ("premier agent libre", 3.6), among the live agents of
    /// `project` (a process, not offline; agents without a runtime are not live):
    /// - a free one: `idle` or `done` shown (no open wait), empty queue, no provisional `Stop`, no delivery in
    ///   progress, hooks healthy, queue not paused; the one idle the longest (`phaseSince`), then the oldest
    ///   agent (`createdAt`), then the smallest id;
    /// - otherwise the shortest queue (a missing length is 0); on equal lengths an agent whose queue can deliver
    ///   (not paused, hooks healthy) first, then the oldest agent, then the smallest id;
    /// - nil when no agent of the project is live (the app then offers "Lancer un nouvel agent avec ce post-it").
    public static func firstFreeAgent(in project: ProjectID, agents: [Agent], runtimes: [AgentID: AgentRuntime],
                                      queueLengths: [AgentID: Int]) -> AgentID? {
        let live: [Candidate] = agents.compactMap { agent in
            guard agent.projectID == project, let runtime = runtimes[agent.id], isLive(runtime) else { return nil }
            return Candidate(agent: agent, runtime: runtime, queueLength: max(0, queueLengths[agent.id] ?? 0))
        }
        if let free = live.filter(\.isFree).min(by: Candidate.idleLongerFirst) {
            return free.agent.id
        }
        return live.min(by: Candidate.shorterQueueFirst)?.agent.id
    }

    // MARK: - Helpers

    /// A process is running for this agent.
    static func isLive(_ runtime: AgentRuntime) -> Bool {
        if case .offline = runtime.phase { return false }
        return runtime.pid != nil
    }

    /// Rule 11: what the last screen read shows, nil when it allows a delivery.
    static func screenCause(_ screen: ScreenFacts?, draftOverride: Bool) -> WaitCause? {
        guard let screen, screen.recognized else { return .screenUnknown }
        if screen.dialogVisible { return .waitingInput }
        if screen.quotaLine != nil { return .quotaPaused }
        if screen.spinnerVisible { return .busy }
        switch screen.inputBox {
        case .empty: return nil
        case .draft: return draftOverride ? nil : .draftInInputBox
        case .unknown: return .screenUnknown
        }
    }

    /// A live agent of the project, for `firstFreeAgent`.
    struct Candidate {
        var agent: Agent
        var runtime: AgentRuntime
        var queueLength: Int

        /// Its queue would deliver without the user: not paused, hooks healthy.
        var canDeliver: Bool {
            !agent.queuePaused && runtime.hookHealth == .healthy
        }

        var isFree: Bool {
            guard queueLength == 0, canDeliver, runtime.pendingStop == nil, runtime.pendingDelivery == nil else {
                return false
            }
            return runtime.kind == .idle || runtime.kind == .done
        }

        static func idleLongerFirst(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.runtime.phaseSince != b.runtime.phaseSince { return a.runtime.phaseSince < b.runtime.phaseSince }
            return olderFirst(a, b)
        }

        static func shorterQueueFirst(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.queueLength != b.queueLength { return a.queueLength < b.queueLength }
            if a.canDeliver != b.canDeliver { return a.canDeliver }
            return olderFirst(a, b)
        }

        static func olderFirst(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.agent.createdAt != b.agent.createdAt { return a.agent.createdAt < b.agent.createdAt }
            return a.agent.id < b.agent.id
        }
    }
}
