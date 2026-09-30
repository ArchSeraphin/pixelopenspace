import Foundation
import Testing
@testable import PixelCore

/// Fixtures of `DispatchPolicyTests`: fixed dates and ids, and an agent ready for a delivery.
fileprivate enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 3_000_000)
    static let now = t0.addingTimeInterval(600)
    static let project = ProjectID(uuid(0xA0))
    static let otherProject = ProjectID(uuid(0xB0))
    static let agentID = AgentID(uuid(0x01))
    static let instruction = QueueItem.instruction(InstructionID(uuid(0x11)))
    static let card = QueueItem.card(TaskCardID(uuid(0x21)))
    static let laterCard = QueueItem.card(TaskCardID(uuid(0x22)))

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    /// Live, hooks healthy, idle since `t0`, empty input box on a recognized screen, nothing open.
    static func ready(_ phase: AgentPhase = .idle, since: Date = t0) -> AgentRuntime {
        var r = AgentRuntime(phase: phase, phaseSince: since)
        r.pid = 4242
        r.hookHealth = .healthy
        r.screen = ScreenFacts(inputBox: .empty, recognized: true)
        return r
    }

    static func agent(_ id: AgentID = agentID, project: ProjectID = project, paused: Bool = false,
                      createdAt: Date = t0) -> Agent {
        Agent(id: id, projectID: project, name: "Nova", deskIndex: 0, queuePaused: paused, createdAt: createdAt)
    }

    static func wait(since: Date = t0) -> PendingWait {
        PendingWait(reason: .permission(tool: "Bash", summary: "rm -rf dist"), subagentID: nil, since: since)
    }

    static func delivery() -> PendingDelivery {
        PendingDelivery(itemID: "item", prefix: "Corrige le bug", startedAt: t0, hookSeqAtStart: 7)
    }

    static func stop() -> PendingStop {
        PendingStop(at: t0, promptID: "P1", stopHookActive: false, backgroundTasks: 0, sessionCrons: 0)
    }

    static func decide(_ runtime: AgentRuntime, agent: Agent = agent(), queue: [QueueItem] = [card, laterCard],
                       now: Date = now, lastTurnEndedAt: Date? = nil,
                       settings: DispatchSettings = DispatchSettings(),
                       draftOverride: Bool = false) -> DeliveryDecision {
        DispatchPolicy.nextDelivery(agent: agent, runtime: runtime, queue: queue, now: now,
                                    lastTurnEndedAt: lastTurnEndedAt, settings: settings,
                                    draftOverride: draftOverride)
    }
}

@Suite struct DispatchPolicyTests {
    fileprivate typealias F = Fixture

    // MARK: - nextDelivery, rule by rule (priority order of the plan)

    @Test func readyAgentGetsTheHeadOfItsQueue() {
        #expect(F.decide(F.ready()) == .deliver(F.card))
        #expect(F.decide(F.ready(.done)) == .deliver(F.card))
        // Instructions come first in a queue (`BoardQuery.queue(of:in:)`): the head is delivered, whatever it is.
        #expect(F.decide(F.ready(), queue: [F.instruction, F.card]) == .deliver(F.instruction))
    }

    @Test func emptyQueueIsNothingToDo() {
        #expect(F.decide(F.ready(), queue: []) == .none)
        // Before every other rule: an agent with nothing queued has no wait cause to show.
        var r = F.ready(.offline(.exited))
        r.pid = nil
        r.hookHealth = .degraded
        #expect(F.decide(r, agent: F.agent(paused: true), queue: []) == .none)
    }

    @Test func pausedQueueWaits() {
        #expect(F.decide(F.ready(), agent: F.agent(paused: true)) == .wait(.paused))
        // Before "offline": the queue stays paused across a relaunch.
        var r = F.ready(.offline(.closedByUser))
        r.pid = nil
        #expect(F.decide(r, agent: F.agent(paused: true)) == .wait(.paused))
    }

    @Test func offlineAgentWaits() {
        var exited = F.ready(.offline(.exited))
        exited.pid = nil
        #expect(F.decide(exited) == .wait(.offline))
        // A crash leaves an error phase without a process.
        var crashed = F.ready(.error(.crashed(1)))
        crashed.pid = nil
        #expect(F.decide(crashed) == .wait(.offline))
        // An offline phase never delivers, even with a stale pid.
        #expect(F.decide(F.ready(.offline(.appRelaunched))) == .wait(.offline))
        // Before "hooks unhealthy".
        exited.hookHealth = .degraded
        #expect(F.decide(exited) == .wait(.offline))
    }

    @Test func unhealthyHooksWait() {
        var degraded = F.ready()
        degraded.hookHealth = .degraded
        #expect(F.decide(degraded) == .wait(.hooksUnhealthy))
        // No hook yet since launch: not healthy either.
        var unknown = F.ready()
        unknown.hookHealth = .unknown(since: F.t0)
        #expect(F.decide(unknown) == .wait(.hooksUnhealthy))
        // Before an open wait (degraded mode opens "look at the terminal" waits).
        degraded.pendingWaits[.terminal] = F.wait()
        #expect(F.decide(degraded) == .wait(.hooksUnhealthy))
    }

    @Test func openWaitWaits() {
        var r = F.ready()
        r.pendingWaits[.tool(toolUseID: "T1")] = F.wait()
        #expect(F.decide(r) == .wait(.waitingInput))
        // Before the background and quota phases.
        r.phase = .waitingBackground(tasks: 1, crons: 0)
        #expect(F.decide(r) == .wait(.waitingInput))
        r.phase = .quotaPaused(resetAt: nil, autoResume: true)
        #expect(F.decide(r) == .wait(.waitingInput))
    }

    @Test func backgroundTasksWait() {
        var r = F.ready(.waitingBackground(tasks: 2, crons: 0))
        #expect(F.decide(r) == .wait(.waitingBackground))
        r.phase = .waitingBackground(tasks: 0, crons: 1)
        #expect(F.decide(r) == .wait(.waitingBackground))
        // Before a delivery in progress.
        r.pendingDelivery = F.delivery()
        #expect(F.decide(r) == .wait(.waitingBackground))
    }

    @Test func quotaPauseWaits() {
        var r = F.ready(.quotaPaused(resetAt: F.now.addingTimeInterval(3600), autoResume: true))
        #expect(F.decide(r) == .wait(.quotaPaused))
        // Before a delivery in progress.
        r.pendingDelivery = F.delivery()
        #expect(F.decide(r) == .wait(.quotaPaused))
    }

    @Test func deliveryInProgressWaits() {
        var r = F.ready()
        r.pendingDelivery = F.delivery()
        #expect(F.decide(r) == .wait(.deliveryInProgress))
        // Before "busy": a provisional Stop, or a phase other than idle/done.
        r.phase = .done
        r.pendingStop = F.stop()
        #expect(F.decide(r) == .wait(.deliveryInProgress))
        r.pendingStop = nil
        r.phase = .thinking
        #expect(F.decide(r) == .wait(.deliveryInProgress))
    }

    @Test(arguments: [
        AgentPhase.launching, .thinking, .working(.bash), .working(.subagent), .error(.api("overloaded")),
    ])
    func busyPhaseWaits(_ phase: AgentPhase) {
        #expect(F.decide(F.ready(phase)) == .wait(.busy))
        // Before the grace delay.
        #expect(F.decide(F.ready(phase), lastTurnEndedAt: F.now) == .wait(.busy))
    }

    @Test func provisionalStopIsBusy() {
        var r = F.ready(.done)
        r.pendingStop = F.stop()
        #expect(F.decide(r) == .wait(.busy))
        #expect(F.decide(r, lastTurnEndedAt: F.now) == .wait(.busy))
    }

    @Test func graceDelayAfterATurn() {
        let r = F.ready(.done)
        #expect(F.decide(r, lastTurnEndedAt: F.now) == .wait(.cooldown))
        #expect(F.decide(r, lastTurnEndedAt: F.now.addingTimeInterval(-1.4)) == .wait(.cooldown))
        // Over at exactly `graceSeconds`.
        #expect(F.decide(r, lastTurnEndedAt: F.now.addingTimeInterval(-1.5)) == .deliver(F.card))
        #expect(F.decide(r, lastTurnEndedAt: F.now.addingTimeInterval(-60)) == .deliver(F.card))
        // An idle agent too (the user looked at it within the delay).
        #expect(F.decide(F.ready(), lastTurnEndedAt: F.now.addingTimeInterval(-1)) == .wait(.cooldown))
        // The delay is a setting.
        let longer = DispatchSettings(graceSeconds: 5)
        #expect(F.decide(r, lastTurnEndedAt: F.now.addingTimeInterval(-3), settings: longer) == .wait(.cooldown))
        let none = DispatchSettings(graceSeconds: 0)
        #expect(F.decide(r, lastTurnEndedAt: F.now, settings: none) == .deliver(F.card))
        // A turn end stamped after `now` (clock set back) is still within the delay: the safe side.
        #expect(F.decide(r, lastTurnEndedAt: F.now.addingTimeInterval(30)) == .wait(.cooldown))
        // Before the screen rules.
        var unknownScreen = r
        unknownScreen.screen = nil
        #expect(F.decide(unknownScreen, lastTurnEndedAt: F.now) == .wait(.cooldown))
    }

    @Test func withoutAutoChainADoneAgentWaitsForTheUser() {
        let manual = DispatchSettings(autoChain: false)
        let long = F.now.addingTimeInterval(-3600)
        #expect(F.decide(F.ready(.done), lastTurnEndedAt: long, settings: manual) == .wait(.cooldown))
        #expect(F.decide(F.ready(.done), settings: manual) == .wait(.cooldown))
        // Once the user has looked at the agent (done → idle, T24), its queue goes on.
        #expect(F.decide(F.ready(), lastTurnEndedAt: long, settings: manual) == .deliver(F.card))
        // With auto-chaining, a done agent gets the next item.
        #expect(F.decide(F.ready(.done), lastTurnEndedAt: long) == .deliver(F.card))
        // Before the screen rules.
        var unknownScreen = F.ready(.done)
        unknownScreen.screen = nil
        #expect(F.decide(unknownScreen, settings: manual) == .wait(.cooldown))
    }

    @Test func unrecognizedScreenWaits() {
        var r = F.ready()
        r.screen = nil
        #expect(F.decide(r) == .wait(.screenUnknown))
        r.screen = ScreenFacts(inputBox: .empty, recognized: false)
        #expect(F.decide(r) == .wait(.screenUnknown))
        // Before the draft rule, which it does not lift.
        r.screen = ScreenFacts(inputBox: .draft(prefix: "Réponds juste OK."), recognized: false)
        #expect(F.decide(r) == .wait(.screenUnknown))
        #expect(F.decide(r, draftOverride: true) == .wait(.screenUnknown))
    }

    @Test func dialogOnScreenWaitsForTheUser() {
        // No hook announced it (a refused permission, a dialog drawn before its event): the screen decides.
        var r = F.ready()
        r.screen = ScreenFacts(inputBox: .unknown, dialogVisible: true, recognized: true)
        #expect(F.decide(r) == .wait(.waitingInput))
        r.screen = ScreenFacts(inputBox: .draft(prefix: "x"), dialogVisible: true, spinnerVisible: true,
                               quotaLine: "Usage limit reached", recognized: true)
        #expect(F.decide(r) == .wait(.waitingInput))
    }

    @Test func quotaLineOnScreenWaits() {
        var r = F.ready()
        r.screen = ScreenFacts(inputBox: .empty, quotaLine: "You've hit your limit", recognized: true)
        #expect(F.decide(r) == .wait(.quotaPaused))
        r.screen = ScreenFacts(inputBox: .draft(prefix: "x"), spinnerVisible: true, quotaLine: "limit reached",
                               recognized: true)
        #expect(F.decide(r) == .wait(.quotaPaused))
    }

    @Test func spinnerOnScreenIsBusy() {
        // A turn started on its own (cron, background task) before its hook arrived.
        var r = F.ready()
        r.screen = ScreenFacts(inputBox: .empty, spinnerVisible: true, recognized: true)
        #expect(F.decide(r) == .wait(.busy))
        r.screen = ScreenFacts(inputBox: .draft(prefix: "x"), spinnerVisible: true, recognized: true)
        #expect(F.decide(r) == .wait(.busy))
    }

    @Test func missingInputBoxIsAnUnknownScreen() {
        var r = F.ready()
        r.screen = ScreenFacts(inputBox: .unknown, recognized: true)
        #expect(F.decide(r) == .wait(.screenUnknown))
        #expect(F.decide(r, draftOverride: true) == .wait(.screenUnknown))
    }

    @Test func draftBlocks() {
        var r = F.ready()
        r.screen = ScreenFacts(inputBox: .draft(prefix: "Réponds juste OK."), recognized: true)
        #expect(F.decide(r) == .wait(.draftInInputBox))
        #expect(F.decide(F.ready(.done)) == .deliver(F.card))
    }

    @Test func sendAnywayLiftsOnlyDraft() {
        var draft = F.ready()
        draft.screen = ScreenFacts(inputBox: .draft(prefix: "Réponds juste OK."), recognized: true)
        #expect(F.decide(draft, draftOverride: true) == .deliver(F.card))

        // Every other cause stays, draft on screen or not.
        var blocked: [(AgentRuntime, Agent, Date?, DispatchSettings)] = []
        func add(_ change: (inout AgentRuntime) -> Void, agent: Agent = F.agent(), ended: Date? = nil,
                 settings: DispatchSettings = DispatchSettings()) {
            var r = draft
            change(&r)
            blocked.append((r, agent, ended, settings))
        }
        add({ _ in }, agent: F.agent(paused: true))
        add { $0.pid = nil; $0.phase = .offline(.exited) }
        add { $0.hookHealth = .degraded }
        add { $0.pendingWaits[.tool(toolUseID: "T1")] = F.wait() }
        add { $0.phase = .waitingBackground(tasks: 1, crons: 0) }
        add { $0.phase = .quotaPaused(resetAt: nil, autoResume: true) }
        add { $0.pendingDelivery = F.delivery() }
        add { $0.phase = .working(.edit) }
        add { $0.phase = .done; $0.pendingStop = F.stop() }
        add({ $0.phase = .done }, ended: F.now)
        add({ $0.phase = .done }, settings: DispatchSettings(autoChain: false))
        add { $0.screen?.recognized = false }
        add { $0.screen?.dialogVisible = true }
        add { $0.screen?.quotaLine = "Usage limit reached" }
        add { $0.screen?.spinnerVisible = true }
        for (runtime, agent, ended, settings) in blocked {
            let without = F.decide(runtime, agent: agent, lastTurnEndedAt: ended, settings: settings)
            let with = F.decide(runtime, agent: agent, lastTurnEndedAt: ended, settings: settings,
                                draftOverride: true)
            #expect(without != .deliver(F.card))
            #expect(without != .wait(.draftInInputBox))
            #expect(with == without)
        }
    }

    // MARK: - Before the screen, cooldown

    /// Rules 1 to 10: what the dispatcher checks before it reads the screen, to know whether a reading is worth it.
    @Test func decisionBeforeScreenLeavesTheScreenOut() {
        func before(_ r: AgentRuntime, agent: Agent = F.agent(), queue: [QueueItem] = [F.card, F.laterCard],
                    lastTurnEndedAt: Date? = nil, settings: DispatchSettings = DispatchSettings()) -> DeliveryDecision {
            DispatchPolicy.decisionBeforeScreen(agent: agent, runtime: r, queue: queue, now: F.now,
                                                lastTurnEndedAt: lastTurnEndedAt, settings: settings)
        }
        let screens: [ScreenFacts?] = [
            nil,
            ScreenFacts(inputBox: .empty, recognized: false),
            ScreenFacts(inputBox: .unknown, dialogVisible: true, recognized: true),
            ScreenFacts(inputBox: .empty, quotaLine: "Usage limit reached", recognized: true),
            ScreenFacts(inputBox: .empty, spinnerVisible: true, recognized: true),
            ScreenFacts(inputBox: .unknown, recognized: true),
            ScreenFacts(inputBox: .draft(prefix: "Réponds juste OK."), recognized: true),
            ScreenFacts(inputBox: .empty, recognized: true),
        ]
        for screen in screens {
            var r = F.ready()
            r.screen = screen
            #expect(before(r) == .deliver(F.card))
            #expect(before(r, queue: []) == .none)
            #expect(before(r, agent: F.agent(paused: true)) == .wait(.paused))
            var busy = r
            busy.phase = .working(.bash)
            #expect(before(busy) == .wait(.busy))
            #expect(before(r, lastTurnEndedAt: F.now) == .wait(.cooldown))
            #expect(before(r, lastTurnEndedAt: F.now) == F.decide(r, lastTurnEndedAt: F.now))
        }
        // When the screen allows it, the same decision as `nextDelivery`.
        #expect(before(F.ready()) == F.decide(F.ready()))
    }

    @Test func cooldownRemainingCountsDownTheGraceDelay() {
        let settings = DispatchSettings(graceSeconds: 1.5)
        func remaining(_ ended: Date?, _ s: DispatchSettings = settings) -> TimeInterval? {
            DispatchPolicy.cooldownRemaining(now: F.now, lastTurnEndedAt: ended, settings: s)
        }
        #expect(remaining(nil) == nil)
        #expect(remaining(F.now) == 1.5)
        #expect(remaining(F.now.addingTimeInterval(-1)) == 0.5)
        #expect(remaining(F.now.addingTimeInterval(-1.5)) == nil)
        #expect(remaining(F.now.addingTimeInterval(-60)) == nil)
        #expect(remaining(F.now, DispatchSettings(graceSeconds: 0)) == nil)
        // A stamp after `now` (clock set back): the whole delay from that stamp, as rule 9 counts it.
        #expect(remaining(F.now.addingTimeInterval(30)) == 31.5)
        // Exactly when rule 9 says "cooldown".
        for offset in [-2.0, -1.5, -1.49, -0.5, 0, 0.5] {
            let ended = F.now.addingTimeInterval(offset)
            let cooling = F.decide(F.ready(), lastTurnEndedAt: ended) == .wait(.cooldown)
            #expect((remaining(ended) != nil) == cooling, "\(offset)")
        }
    }

    /// Starting with every cause at once and removing them one by one walks the rules in the plan's order.
    @Test func rulesApplyInPriorityOrder() {
        var agent = F.agent(paused: true)
        var queue: [QueueItem] = []
        var settings = DispatchSettings(autoChain: false)
        var ended: Date? = F.now
        var draftOverride = false
        var r = F.ready(.waitingBackground(tasks: 1, crons: 0))
        r.pid = nil
        r.hookHealth = .degraded
        r.pendingWaits[.terminal] = F.wait()
        r.pendingDelivery = F.delivery()
        r.pendingStop = F.stop()
        r.screen = ScreenFacts(inputBox: .draft(prefix: "x"), dialogVisible: true, spinnerVisible: true,
                               quotaLine: "Usage limit reached", recognized: false)

        var seen: [DeliveryDecision] = []
        func record() {
            seen.append(F.decide(r, agent: agent, queue: queue, lastTurnEndedAt: ended, settings: settings,
                                 draftOverride: draftOverride))
        }
        record()
        queue = [F.card]
        record()
        agent.queuePaused = false
        record()
        r.pid = 4242
        record()
        r.hookHealth = .healthy
        record()
        r.pendingWaits = [:]
        record()
        r.phase = .quotaPaused(resetAt: nil, autoResume: false)
        record()
        r.phase = .done
        record()
        r.pendingDelivery = nil
        record()
        r.pendingStop = nil
        record()
        ended = F.now.addingTimeInterval(-60)
        record()
        settings.autoChain = true
        record()
        r.screen?.recognized = true
        record()
        r.screen?.dialogVisible = false
        record()
        r.screen?.quotaLine = nil
        record()
        r.screen?.spinnerVisible = false
        record()
        draftOverride = true
        record()

        #expect(seen == [
            .none, .wait(.paused), .wait(.offline), .wait(.hooksUnhealthy), .wait(.waitingInput),
            .wait(.waitingBackground), .wait(.quotaPaused), .wait(.deliveryInProgress), .wait(.busy),
            .wait(.cooldown), .wait(.cooldown), .wait(.screenUnknown),
            // What the screen shows: a dialog, the usage limit line, a spinner, then a draft.
            .wait(.waitingInput), .wait(.quotaPaused), .wait(.busy), .wait(.draftInInputBox),
            .deliver(F.card),
        ])
    }

    // MARK: - Settings and labels

    @Test func settingsDefaultsAndAppSettings() {
        let defaults = DispatchSettings()
        #expect(defaults.autoChain)
        #expect(defaults.graceSeconds == 1.5)
        var app = AppSettings()
        app.autoChainQueue = false
        app.sendGraceSeconds = 4
        #expect(DispatchSettings(settings: app) == DispatchSettings(autoChain: false, graceSeconds: 4))
        #expect(DispatchSettings(settings: AppSettings()) == defaults)
    }

    @Test func everyWaitCauseHasAFrenchLabel() {
        #expect(WaitCause.busy.label == "occupé")
        #expect(WaitCause.waitingInput.label == "attend ta réponse")
        #expect(WaitCause.draftInInputBox.label == "✎ brouillon")
        #expect(WaitCause.screenUnknown.label == "écran non reconnu")
        #expect(WaitCause.paused.label == "file en pause")
        #expect(WaitCause.offline.label == "hors ligne")
        let labels = WaitCause.allCases.map(\.label)
        #expect(Set(labels).count == WaitCause.allCases.count)
        for label in labels {
            #expect(!label.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!label.contains("\u{2014}"))
        }
    }

    // MARK: - firstFreeAgent

    /// Agents of `Fixture.project` numbered by id, all created at `t0`.
    fileprivate static func member(_ n: Int, project: ProjectID = F.project, paused: Bool = false,
                       createdAt: Date = F.t0) -> Agent {
        F.agent(AgentID(F.uuid(n)), project: project, paused: paused, createdAt: createdAt)
    }

    fileprivate static func first(_ agents: [Agent], _ runtimes: [Int: AgentRuntime], queues: [Int: Int] = [:],
                      in project: ProjectID = F.project) -> AgentID? {
        let byID = Dictionary(uniqueKeysWithValues: runtimes.map { (AgentID(F.uuid($0.key)), $0.value) })
        let lengths = Dictionary(uniqueKeysWithValues: queues.map { (AgentID(F.uuid($0.key)), $0.value) })
        return DispatchPolicy.firstFreeAgent(in: project, agents: agents, runtimes: byID, queueLengths: lengths)
    }

    @Test func freeAgentIsIdleOrDoneWithAnEmptyQueue() {
        let agents = [Self.member(1), Self.member(2), Self.member(3)]
        let runtimes = [1: F.ready(.working(.bash)), 2: F.ready(.idle), 3: F.ready(.thinking)]
        #expect(Self.first(agents, runtimes) == AgentID(F.uuid(2)))
        let done = [1: F.ready(.working(.bash)), 2: F.ready(.thinking), 3: F.ready(.done)]
        #expect(Self.first(agents, done) == AgentID(F.uuid(3)))
    }

    @Test func longestIdleFirst() {
        let agents = [Self.member(1), Self.member(2), Self.member(3)]
        let runtimes = [
            1: F.ready(.idle, since: F.t0.addingTimeInterval(30)),
            2: F.ready(.done, since: F.t0.addingTimeInterval(10)),
            3: F.ready(.idle, since: F.t0.addingTimeInterval(20)),
        ]
        #expect(Self.first(agents, runtimes) == AgentID(F.uuid(2)))
    }

    @Test func idleTiesGoToTheOldestAgentThenTheSmallestID() {
        let older = [Self.member(1, createdAt: F.t0.addingTimeInterval(5)), Self.member(2)]
        #expect(Self.first(older, [1: F.ready(), 2: F.ready()]) == AgentID(F.uuid(2)))
        let same = [Self.member(2), Self.member(1)]
        #expect(Self.first(same, [1: F.ready(), 2: F.ready()]) == AgentID(F.uuid(1)))
    }

    @Test func agentThatCannotTakeACardNowIsNotFree() {
        // Each candidate, idle the longest with an empty queue, would win if it were free; it loses to an agent
        // idle for a shorter time.
        var waiting = F.ready()
        waiting.pendingWaits[.tool(toolUseID: "T1")] = F.wait()
        var provisional = F.ready(.done)
        provisional.pendingStop = F.stop()
        var degraded = F.ready()
        degraded.hookHealth = .degraded
        var delivering = F.ready()
        delivering.pendingDelivery = F.delivery()
        let recent = F.ready(since: F.t0.addingTimeInterval(10))
        let agents = [Self.member(1), Self.member(2)]
        #expect(Self.first(agents, [1: F.ready(), 2: recent]) == AgentID(F.uuid(1)))
        for candidate in [waiting, provisional, degraded, delivering] {
            #expect(Self.first(agents, [1: candidate, 2: recent]) == AgentID(F.uuid(2)))
        }
        let paused = [Self.member(1, paused: true), Self.member(2)]
        #expect(Self.first(paused, [1: F.ready(), 2: recent]) == AgentID(F.uuid(2)))
    }

    @Test func otherwiseTheShortestQueueAmongLiveAgents() {
        let agents = [Self.member(1), Self.member(2), Self.member(3)]
        let busy = [1: F.ready(.working(.edit)), 2: F.ready(.thinking), 3: F.ready(.idle)]
        #expect(Self.first(agents, busy, queues: [1: 3, 2: 1, 3: 2]) == AgentID(F.uuid(2)))
        // A missing length is an empty queue.
        #expect(Self.first(agents, busy, queues: [1: 3, 3: 2]) == AgentID(F.uuid(2)))
        // An agent in a quota pause, waiting or launching is live: it gets its turn.
        var waiting = F.ready()
        waiting.pendingWaits[.terminal] = F.wait()
        let live = [1: F.ready(.quotaPaused(resetAt: nil, autoResume: true)), 2: waiting, 3: F.ready(.launching)]
        #expect(Self.first(agents, live, queues: [1: 2, 2: 3, 3: 1]) == AgentID(F.uuid(3)))
    }

    @Test func equalQueuesPreferAnAgentThatWillDeliver() {
        var degraded = F.ready(.working(.bash))
        degraded.hookHealth = .degraded
        let agents = [Self.member(1, paused: true), Self.member(2), Self.member(3)]
        let runtimes = [1: F.ready(.thinking), 2: degraded, 3: F.ready(.working(.read))]
        #expect(Self.first(agents, runtimes, queues: [1: 1, 2: 1, 3: 1]) == AgentID(F.uuid(3)))
        // Then the oldest agent, then the smallest id.
        let plain = [Self.member(3), Self.member(2, createdAt: F.t0.addingTimeInterval(9)), Self.member(1)]
        let busy = [1: F.ready(.thinking), 2: F.ready(.thinking), 3: F.ready(.thinking)]
        #expect(Self.first(plain, busy, queues: [1: 2, 2: 2, 3: 2]) == AgentID(F.uuid(1)))
        // Only blocked agents left: the shortest queue still wins.
        let onlyBlocked = [Self.member(1, paused: true), Self.member(2, paused: true)]
        #expect(Self.first(onlyBlocked, [1: F.ready(), 2: F.ready()], queues: [1: 2, 2: 1]) == AgentID(F.uuid(2)))
    }

    @Test func otherProjectsAndOfflineAgentsAreIgnored() {
        var offline = F.ready(.offline(.exited))
        offline.pid = nil
        var crashed = F.ready(.error(.crashed(nil)))
        crashed.pid = nil
        let agents = [
            Self.member(1, project: F.otherProject), Self.member(2), Self.member(3), Self.member(4), Self.member(5),
        ]
        // 1 is free but elsewhere; 2 and 3 have no process; 4 has no runtime; 5 is live but busy.
        let runtimes = [1: F.ready(), 2: offline, 3: crashed, 5: F.ready(.working(.bash))]
        #expect(Self.first(agents, runtimes, queues: [5: 4]) == AgentID(F.uuid(5)))
    }

    @Test func noLiveAgentIsNil() {
        var offline = F.ready(.offline(.notStarted))
        offline.pid = nil
        let agents = [Self.member(1, project: F.otherProject), Self.member(2)]
        #expect(Self.first(agents, [1: F.ready(), 2: offline]) == nil)
        #expect(Self.first([], [:]) == nil)
        #expect(Self.first(agents, [:]) == nil)
    }
}
