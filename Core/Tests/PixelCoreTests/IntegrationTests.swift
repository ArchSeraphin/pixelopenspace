import Foundation
import Testing
@testable import PixelCore
import PixelIPC

/// The app's hook path on recorded hook input, without threads or sockets:
/// hook stdin → `HookWireEncoder` (the line `pixel-hook` sends) → `HookDecoder.decodeEnvelope` → `HookDeduplicator`
/// → `HookRouter` → `AgentStateMachine` → `AgentPresenter` / `StatusSummary`.
struct HookPipeline {
    static let token = "jeton-integration"
    static let pid: Int32 = 4242
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    let agent = AgentID()
    var runtime = AgentRuntime(phaseSince: HookPipeline.t0)
    var deduplicator = HookDeduplicator()
    var now = HookPipeline.t0
    /// `HookWire.monotonicNanos()` stand-in, advanced with `now`.
    var clockNs: UInt64 = 5_000_000_000
    var seq: UInt64 = 0
    var config = ReducerConfig()
    /// Effects of the last input.
    var effects: [AgentEffect] = []

    var state: AgentState { runtime.state }
    var display: AgentStatusDisplay { AgentPresenter.present(runtime, now: now) }

    mutating func start(withInitialPrompt: Bool = false) {
        reduce(.processStarted(pid: Self.pid, startedAt: now, withInitialPrompt: withInitialPrompt))
    }

    /// One hook run, `seconds` after the previous input. Returns the router's decision, `nil` for a duplicate.
    @discardableResult
    mutating func deliver(_ stdin: Data, after seconds: TimeInterval = 0.2, claudePID: Int32? = HookPipeline.pid,
                          token: String? = HookPipeline.token, repeatTimestamp: Bool = false) throws -> RouteDecision? {
        if !repeatTimestamp { advance(seconds) }
        let line = HookWireEncoder.envelope(stdin: stdin, stdinLength: stdin.count, agent: agent.description,
                                            token: token, claudePID: claudePID, timestampNs: clockNs)
        // The server hands over the line without its "\n".
        #expect(line.last == 0x0A)
        let envelope = try HookDecoder.decodeEnvelope(line.dropLast())
        effects = []
        guard !deduplicator.isDuplicate(envelope) else { return nil }
        let decision = HookRouter.route(envelope, expectedToken: Self.token,
                                        agents: [agent: RoutingEntry(pid: runtime.pid, sessionID: runtime.currentSessionID)])
        if decision == .accept(agent) {
            seq += 1
            reduce(.hook(envelope.event, seq: seq))
        }
        return decision
    }

    mutating func tick(after seconds: TimeInterval) {
        advance(seconds)
        reduce(.tick)
    }

    mutating func advance(_ seconds: TimeInterval) {
        now += seconds
        clockNs += UInt64((seconds * 1e9).rounded())
    }

    private mutating func reduce(_ input: AgentInput) {
        (runtime, effects) = AgentStateMachine.reduce(runtime, input, now: now, config: config)
    }
}

@Suite struct IntegrationTests {
    typealias F = HookFixtures

    private static let command = "rm -rf build && swift test"
    private static let permission = WaitReason.permission(tool: "Bash", summary: command)

    /// scenario-permission.jsonl: launching → idle → thinking → working(bash) → waitingInput → thinking → done,
    /// then the quiet window commits the turn.
    @Test func permissionScenarioThroughTheWholePipeline() throws {
        var p = HookPipeline()
        p.start()
        #expect(p.state == .phase(.launching))
        #expect(p.effects == [.recordProcess(ProcessStamp(pid: HookPipeline.pid, startedAt: HookPipeline.t0))])

        let lines = try F.lines("scenario-permission.jsonl")
        try #require(lines.count == 6)

        // SessionStart(startup).
        #expect(try p.deliver(lines[0]) == .accept(p.agent))
        #expect(p.state == .phase(.idle))
        #expect(p.effects == [.recordSession(SessionRef(sessionID: F.sessionID, cwd: F.cwd, startedAt: p.now,
                                                         source: .startup, transcriptPath: F.transcriptPath,
                                                         model: "claude-opus-5"))])
        #expect(p.runtime.currentSessionID == F.sessionID)
        #expect(p.runtime.hookHealth == .healthy)

        // UserPromptSubmit.
        try p.deliver(lines[1])
        #expect(p.state == .phase(.thinking))
        #expect(p.runtime.currentPromptID == F.promptID)
        #expect(p.effects.isEmpty)

        // PreToolUse(Bash).
        try p.deliver(lines[2])
        #expect(p.state == .phase(.working(.bash)))
        #expect(p.runtime.inFlightKinds == ["toolu_01ScEnArIoRmBuIlDaBcDeFg": .bash])

        // PermissionRequest: no tool_use_id in the documented input, paired with the Bash call in flight.
        try p.deliver(lines[3])
        let waitingSince = p.now
        #expect(p.state == .waitingInput(Self.permission, count: 1, since: waitingSince))
        #expect(p.runtime.pendingWaits.keys.map { $0 } == [.tool(toolUseID: "toolu_01ScEnArIoRmBuIlDaBcDeFg")])
        #expect(p.effects == [.notify(.waiting(Self.permission)), .playSound(.alert), .announce("attend ta réponse")])
        #expect(p.display.kind == .waitingInput)
        #expect(p.display.detail == "Bash : \(Self.command)")
        #expect(StatusSummary.compute([p.agent: p.runtime]).waiting
                == [WaitingEntry(agentID: p.agent, reason: Self.permission, since: waitingSince, count: 1)])

        // PostToolUse: the wait is lifted with its tool.
        try p.deliver(lines[4], after: 8.4)
        #expect(p.state == .phase(.thinking))
        #expect(p.runtime.pendingWaits.isEmpty && p.runtime.inFlightTools.isEmpty)
        #expect(StatusSummary.compute([p.agent: p.runtime]).waiting.isEmpty)

        // Stop: shown done at once, provisional.
        try p.deliver(lines[5])
        let stoppedAt = p.now
        #expect(p.state == .phase(.done))
        #expect(p.runtime.pendingStop == PendingStop(at: stoppedAt, promptID: F.promptID, stopHookActive: false,
                                                     backgroundTasks: 0, sessionCrons: 0))
        #expect(p.effects.isEmpty)

        // Still inside the quiet window: nothing committed.
        p.tick(after: p.config.stopQuietWindow - 1)
        #expect(p.runtime.pendingStop != nil)
        #expect(p.effects.isEmpty)

        // Quiet window over: committed.
        p.tick(after: 1)
        #expect(p.state == .phase(.done))
        #expect(p.runtime.pendingStop == nil)
        #expect(p.runtime.committedStopPromptID == F.promptID)
        #expect(p.effects == [.card(.turnCommitted(promptID: F.promptID)), .playSound(.done), .notify(.turnDone),
                              .pumpQueue(afterSeconds: p.config.sendGrace)])
        #expect(p.display.kind == .done)
        #expect(p.seq == 6)
        #expect(p.runtime.hookSeq == 6)
    }

    /// The same events delivered twice (app `--settings` hooks plus a global install): each one counts once.
    @Test func duplicatedDeliveriesAreDroppedBeforeTheReducer() throws {
        var p = HookPipeline()
        p.start()
        var notifications = 0
        for line in try F.lines("scenario-permission.jsonl") {
            #expect(try p.deliver(line) == .accept(p.agent))
            notifications += p.effects.filter(\.isNotify).count
            #expect(try p.deliver(line, repeatTimestamp: true) == nil)
        }
        #expect(notifications == 1)
        #expect(p.seq == 6)
        #expect(p.state == .phase(.done))
    }

    /// A `claude` started by the agent itself (it inherited `PIXEL_AGENT_ID`) and a wrong token never reach
    /// the reducer.
    @Test func nestedSessionsAndBadTokensDoNotChangeTheAgent() throws {
        var p = HookPipeline()
        p.start()
        let lines = try F.lines("scenario-permission.jsonl")
        try p.deliver(lines[0])
        try p.deliver(lines[1])
        let before = p.runtime

        #expect(try p.deliver(lines[2], claudePID: HookPipeline.pid + 1) == .ignoreNested(p.agent))
        #expect(try p.deliver(lines[3], token: "faux") == .rejectToken)
        #expect(try p.deliver(lines[3], token: nil) == .rejectToken)
        #expect(p.runtime == before)
        #expect(p.state == .phase(.thinking))

        // A hook whose `claude_pid` could not be found is accepted (nothing to compare).
        #expect(try p.deliver(lines[2], claudePID: nil) == .accept(p.agent))
        #expect(p.state == .phase(.working(.bash)))
    }

    /// A subagent asks for a permission while the main agent waits on its `Agent` call: the subagent's
    /// `PermissionRequest` (no `tool_use_id`) pairs with the subagent's tool, and its result lifts the wait.
    @Test func subagentPermissionIsPairedWithTheSubagentTool() throws {
        var p = HookPipeline()
        p.start()
        let lines = try F.lines("scenario-permission.jsonl")
        try p.deliver(lines[0])
        try p.deliver(lines[1])

        try p.deliver(Self.hook("PreToolUse", tool: "Agent", input: #"{"description":"Explorer le cache"}"#,
                                toolUseID: "toolu_main"))
        try p.deliver(Self.hook("SubagentStart", subagent: "sub-1"))
        try p.deliver(Self.hook("PreToolUse", tool: "Bash", input: #"{"command":"make clean"}"#, toolUseID: "toolu_sub",
                                subagent: "sub-1"))
        #expect(p.state == .phase(.working(.subagent)))
        #expect(p.runtime.activeSubagents == 1)

        try p.deliver(Self.hook("PermissionRequest", tool: "Bash", input: #"{"command":"make clean"}"#, subagent: "sub-1"))
        let reason = WaitReason.permission(tool: "Bash", summary: "make clean")
        #expect(p.state == .waitingInput(reason, count: 1, since: p.now))
        #expect(p.runtime.pendingWaits[.tool(toolUseID: "toolu_sub")]?.subagentID == "sub-1")
        #expect(p.display.badges == ["1 sous-agent"])

        try p.deliver(Self.hook("PostToolUse", tool: "Bash", input: #"{"command":"make clean"}"#, toolUseID: "toolu_sub",
                                subagent: "sub-1"))
        #expect(p.state == .phase(.working(.subagent)))
        #expect(p.runtime.inFlightKinds == ["toolu_main": .subagent])

        try p.deliver(Self.hook("SubagentStop", subagent: "sub-1"))
        try p.deliver(Self.hook("PostToolUse", tool: "Agent", input: #"{"description":"Explorer le cache"}"#,
                                toolUseID: "toolu_main"))
        #expect(p.state == .phase(.thinking))
        #expect(p.runtime.activeSubagents == 0)
        #expect(p.runtime.pendingWaits.isEmpty && p.runtime.inFlightTools.isEmpty)
    }

    /// `AskUserQuestion` opens its wait from `PreToolUse`; a `PermissionRequest` for the same question does not
    /// open a second one, and the answer (`PostToolUse`) lifts it.
    @Test func questionThenItsPermissionRequestIsOneWait() throws {
        var p = HookPipeline()
        p.start()
        let lines = try F.lines("scenario-permission.jsonl")
        try p.deliver(lines[0])
        try p.deliver(lines[1])

        let question = try F.data("PreToolUse-AskUserQuestion.json")
        try p.deliver(question)
        guard case .waitingInput(.question(let questions), 1, _) = p.state else {
            Issue.record("expected a question, got \(p.state)")
            return
        }
        #expect(questions.map(\.header) == ["Cache", "Plateformes"])
        #expect(p.effects.filter(\.isNotify).count == 1)

        let input = #"{"questions":[{"question":"Quelle base de données pour le cache ?","header":"Cache","options":[{"label":"SQLite"}],"multiSelect":false}]}"#
        try p.deliver(Self.hook("PermissionRequest", tool: "AskUserQuestion", input: input))
        #expect(p.runtime.pendingWaits.count == 1)
        #expect(p.effects.isEmpty)

        try p.deliver(Self.hook("PostToolUse", tool: "AskUserQuestion", input: input,
                                toolUseID: "toolu_01AskQ7wErTyUiOpAsDfGhJk"))
        #expect(p.state == .phase(.thinking))
    }

    /// hooks.md's own examples: the form-mode `Elicitation` has no `elicitation_id`, its `ElicitationResult` has one.
    @Test func elicitationWithoutIDIsLiftedByItsResult() throws {
        var p = HookPipeline()
        p.start()
        let lines = try F.lines("scenario-permission.jsonl")
        try p.deliver(lines[0])
        try p.deliver(lines[1])
        try p.deliver(Self.hook("PreToolUse", tool: "mcp__my-mcp-server__login", input: "{}", toolUseID: "toolu_mcp"))
        try p.deliver(try F.data("Elicitation-form.json"))
        #expect(p.state == .waitingInput(.elicitation(server: "my-mcp-server", message: "Please provide your credentials"),
                                         count: 1, since: p.now))
        try p.deliver(try F.data("ElicitationResult.json"))
        #expect(p.state == .phase(.working(.mcp("my-mcp-server"))))
    }

    // MARK: - Helpers

    /// Minimal hook JSON of the fixture session and prompt.
    private static func hook(_ event: String, tool: String? = nil, input: String? = nil, toolUseID: String? = nil,
                             subagent: String? = nil) -> Data {
        var fields = [
            #""session_id":"\#(F.sessionID)""#, #""prompt_id":"\#(F.promptID)""#, #""cwd":"\#(F.cwd)""#,
            #""hook_event_name":"\#(event)""#,
        ]
        if let subagent { fields.append(#""agent_id":"\#(subagent)","agent_type":"Explore""#) }
        if let tool { fields.append(#""tool_name":"\#(tool)""#) }
        if let input { fields.append(#""tool_input":\#(input)"#) }
        if let toolUseID { fields.append(#""tool_use_id":"\#(toolUseID)""#) }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }
}
