import Foundation
import Testing
import PixelCore
import PixelIPC

/// `fake-claude` → `/bin/sh -c` → `pixel-hook` → Unix socket → `UnixSocketServer` → `HookDecoder`.
@Suite struct EndToEndTests {
    private static let session = "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d"
    private static let common = #""session_id":"\#(session)","transcript_path":"/Users/seraphin/.claude/projects/-Users-seraphin-Projets-pixel-demo/\#(session).jsonl","cwd":"/Users/seraphin/Projets/pixel demo","permission_mode":"default""#
    private static let prompt = "Nettoie le dossier build puis relance les tests."

    /// SessionStart, UserPromptSubmit, PreToolUse (Bash), PermissionRequest, PostToolUse, Stop, with a pause
    /// and a blank line that must not produce events.
    private static let scenario = [
        #"{\#(common),"hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}"#,
        #"{\#(common),"prompt_id":"p1","hook_event_name":"UserPromptSubmit","prompt":"\#(prompt)"}"#,
        #"{"_sleep_ms": 20}"#,
        #"{\#(common),"prompt_id":"p1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf build && swift test","description":"Clean and run tests"},"tool_use_id":"toolu_01"}"#,
        "",
        #"{\#(common),"prompt_id":"p1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build && swift test"},"permission_suggestions":[]}"#,
        #"{\#(common),"prompt_id":"p1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf build && swift test"},"tool_response":{"stdout":"Test run with 12 tests passed","stderr":"","interrupted":false},"tool_use_id":"toolu_01","duration_ms":8412}"#,
        #"{\#(common),"prompt_id":"p1","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Tout passe.","background_tasks":[],"session_crons":[]}"#,
    ].joined(separator: "\n") + "\n"

    private static let expectedEvents: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest, .postToolUse, .stop,
    ]

    private static let command = "rm -rf build && swift test"

    /// What `HookDecoder` must make of each replayed line (`PermissionRequest` has no `tool_use_id`, as documented).
    private static let expectedPayloads: [HookPayload] = [
        .sessionStart(source: .startup, model: "claude-opus-5"),
        .userPromptSubmit(promptHead: prompt, promptLength: prompt.count),
        .preToolUse(tool: "Bash", toolUseID: "toolu_01", summary: command),
        .permissionRequest(tool: "Bash", toolUseID: nil, summary: command),
        .postToolUse(tool: "Bash", toolUseID: "toolu_01", failed: false),
        .stop(lastMessageHead: "Tout passe.", stopHookActive: false, backgroundTasks: 0, sessionCrons: 0),
    ]

    /// Kind of the displayed state after each event, starting from `launching`.
    private static let expectedKinds: [AgentStateKind] = [.idle, .thinking, .working, .waitingInput, .thinking, .done]

    private func replay(server: TestServer, hook: String, extraArguments: [String] = [],
                        environment: [String: String]) throws -> ChildProcess.Result {
        let fixture = server.directory + "/scenario.jsonl"
        try Data(Self.scenario.utf8).write(to: URL(fileURLWithPath: fixture))
        let result = try ChildProcess.run(
            try Products.executable("fake-claude"),
            arguments: ["replay", "--hook", hook, "--fixture", fixture] + extraArguments,
            environment: ChildProcess.environment(environment.merging(
                [HookWire.envSocket: server.path, "HOME": server.directory]) { _, new in new })
        )
        #expect(result.exitedNormally)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty, "\(String(decoding: result.stderr, as: UTF8.self))")
        return result
    }

    @Test func replayedSessionReachesTheServerDecoded() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        let agent = AgentID()
        let result = try replay(
            server: server, hook: try Products.executable("pixel-hook").path, extraArguments: ["--delay-ms", "5"],
            environment: [HookWire.envAgentID: agent.description, HookWire.envToken: "jeton-e2e"]
        )

        let messages = server.inbox.wait(for: 6, timeout: 10)
        try #require(messages.count == 6)
        #expect(server.inbox.wait(for: 7, timeout: 0.3).count == 6)

        var latencies: [Double] = []
        var envelopes: [HookEnvelope] = []
        for (index, (message, expected)) in zip(messages, Self.expectedEvents).enumerated() {
            // Raw wire keys.
            let root = try message.json()
            #expect(root[HookWire.keyVersion] as? Int == HookWire.version)
            #expect(root[HookWire.keyAgent] as? String == agent.description)
            #expect(root[HookWire.keyToken] as? String == "jeton-e2e")
            #expect(root[HookWire.keyClaudePID] as? Int == Int(result.pid))
            let hook = try #require(root[HookWire.keyHook] as? [String: Any])
            #expect(hook["hook_event_name"] as? String == expected.rawValue)
            #expect(hook["session_id"] as? String == Self.session)
            #expect(message.peer.uid == getuid())

            // Decoded by the app's decoder.
            let envelope = try HookDecoder.decodeEnvelope(message.data)
            #expect(envelope.version == HookWire.version)
            #expect(envelope.agentID == agent)
            #expect(envelope.token == "jeton-e2e")
            #expect(envelope.claudePID == result.pid)
            #expect(envelope.event.name == expected)
            #expect(envelope.event.payload == Self.expectedPayloads[index])
            #expect(envelope.event.sessionID == Self.session)
            #expect(envelope.event.promptID == (index == 0 ? nil : "p1"))
            #expect(envelope.event.cwd == "/Users/seraphin/Projets/pixel demo")
            #expect(envelope.event.permissionMode == "default")
            #expect(envelope.event.isMain)
            #expect(envelope.timestampNs > 0 && envelope.timestampNs <= message.receivedNs)
            #expect(envelope.timestampNs > (envelopes.last?.timestampNs ?? 0))
            latencies.append(Double(message.receivedNs - envelope.timestampNs) / 1_000)
            envelopes.append(envelope)
        }

        // Routed and reduced as the app does, with fake-claude as the agent's PTY process.
        let agents = [agent: RoutingEntry(pid: result.pid)]
        var runtime = AgentRuntime(phaseSince: Date(timeIntervalSince1970: 0))
        var now = Date(timeIntervalSince1970: 0)
        (runtime, _) = AgentStateMachine.reduce(runtime, .processStarted(pid: result.pid, startedAt: now, withInitialPrompt: false),
                                                now: now)
        var kinds: [AgentStateKind] = []
        for (seq, envelope) in envelopes.enumerated() {
            #expect(HookRouter.route(envelope, expectedToken: "jeton-e2e", agents: agents) == .accept(agent))
            #expect(HookRouter.route(envelope, expectedToken: "jeton-e2e", agents: [agent: RoutingEntry(pid: result.pid + 1)])
                    == .ignoreNested(agent))
            now += 0.5
            (runtime, _) = AgentStateMachine.reduce(runtime, .hook(envelope.event, seq: UInt64(seq + 1)), now: now)
            kinds.append(runtime.kind)
        }
        #expect(kinds == Self.expectedKinds)
        #expect(runtime.pendingStop?.promptID == "p1")
        // Whole cost per event as seen by Claude Code (spawning sh and pixel-hook included), minus the pauses.
        let pauses = 0.020 + 6 * 0.005
        let perEvent = max(0, result.seconds - pauses) / 6 * 1_000
        print("pixel-hook latency (ts_ns → server delivery) over \(latencies.count) events: "
              + "p50 \(Int(percentile(latencies, 50))) µs, p95 \(Int(percentile(latencies, 95))) µs; "
              + "hook run per event ≈ \(Int(perEvent)) ms")
    }

    @Test func sessionOverrideAndHookPathWithSpacesAndQuotes() throws {
        let server = try TestServer()
        defer { server.tearDown() }
        // Like "/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook".
        let helpers = server.directory + "/Pixel Open Space's.app/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: helpers + "/pixel-hook",
                                                   withDestinationPath: try Products.executable("pixel-hook").path)

        let result = try replay(server: server, hook: helpers + "/pixel-hook",
                                extraArguments: ["--session", "session-forcée"], environment: [:])
        let messages = server.inbox.wait(for: 6, timeout: 10)
        #expect(messages.count == 6)
        for message in messages {
            let envelope = try HookDecoder.decodeEnvelope(message.data)
            #expect(envelope.event.sessionID == "session-forcée")
            #expect(envelope.agentID == nil)
            #expect(envelope.token == nil)
            #expect(envelope.claudePID == result.pid)
        }
    }

    @Test func fakeClaudeRejectsBadUsage() throws {
        let fakeClaude = try Products.executable("fake-claude")
        for arguments in [[], ["replay"], ["replay", "--hook", "/bin/true"], ["replay", "--fixture", "x", "--hook"],
                          ["replay", "--hook", "h", "--fixture", "f", "--delay-ms", "-3"], ["sleep"], ["sleep", "abc"], ["dance"]] {
            let result = try ChildProcess.run(fakeClaude, arguments: arguments, environment: ChildProcess.environment([:]))
            #expect(result.status == 1, "\(arguments)")
            #expect(!result.stderr.isEmpty)
            #expect(result.stdout.isEmpty)
        }
        let missing = try ChildProcess.run(fakeClaude, arguments: ["replay", "--hook", "/bin/true", "--fixture", "/nonexistent.jsonl"],
                                           environment: ChildProcess.environment([:]))
        #expect(missing.status == 1)

        let sleep = try ChildProcess.run(fakeClaude, arguments: ["sleep", "0.05"], environment: ChildProcess.environment([:]))
        #expect(sleep.status == 0)
        #expect(sleep.stdout.isEmpty && sleep.stderr.isEmpty)
    }
}
