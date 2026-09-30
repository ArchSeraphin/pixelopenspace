import Foundation
import Testing
@testable import PixelCore

/// Hook fixtures in `Fixtures/hooks/`, adapted from https://code.claude.com/docs/en/hooks.md.
enum HookFixtures {
    static let sessionID = "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d"
    static let promptID = "7b1e4c2d-5a6f-4e8b-9d0c-2f3a4b5c6d7e"
    static let cwd = "/Users/seraphin/Projets/pixel-demo"
    static let transcriptPath =
        "/Users/seraphin/.claude/projects/-Users-seraphin-Projets-pixel-demo/3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d.jsonl"

    static func url(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/hooks/\(name)")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func event(_ name: String) throws -> HookEvent {
        try HookDecoder.decodeHook(data(name))
    }

    /// One `Data` per non-empty line of a `.jsonl` fixture.
    static func lines(_ name: String) throws -> [Data] {
        String(decoding: try data(name), as: UTF8.self).split(separator: "\n").map { Data($0.utf8) }
    }

    /// An envelope line as `pixel-hook` writes it, around `hook`.
    static func envelope(_ fields: String, hook: Data) -> Data {
        Data("{\(fields)\(fields.isEmpty ? "" : ",")\"hook\":".utf8) + hook + Data("}\n".utf8)
    }
}

private func decode(_ json: String) throws -> HookEvent {
    try HookDecoder.decodeHook(Data(json.utf8))
}

@Suite struct HookDecoderTests {
    typealias F = HookFixtures

    // MARK: - Fixtures

    @Test(arguments: HookEventName.subscribed)
    func everySubscribedEventHasADecodableFixture(_ name: HookEventName) throws {
        let event = try F.event("\(name.rawValue).json")
        #expect(event.name == name)
        #expect(event.sessionID == F.sessionID)
        #expect(event.cwd != nil)
        #expect(event.transcriptPath == F.transcriptPath)
        #expect(event.payload != .other)
    }

    @Test func sessionStart() throws {
        #expect(try F.event("SessionStart.json") == HookEvent(
            name: .sessionStart, sessionID: F.sessionID, cwd: F.cwd, transcriptPath: F.transcriptPath,
            payload: .sessionStart(source: .startup, model: "claude-opus-5")))
    }

    @Test func sessionStartMinimal() throws {
        #expect(try F.event("SessionStart-minimal.json") == HookEvent(
            name: .sessionStart, sessionID: F.sessionID, payload: .sessionStart(source: .unknown, model: nil)))
    }

    @Test func sessionEnd() throws {
        let event = try F.event("SessionEnd.json")
        #expect(event.payload == .sessionEnd(reason: "prompt_input_exit"))
        #expect(event.permissionMode == nil)
    }

    @Test func userPromptSubmit() throws {
        let prompt = "Ajoute des tests pour le décodeur de hooks, puis vérifie que « swift test » passe."
        #expect(try F.event("UserPromptSubmit.json") == HookEvent(
            name: .userPromptSubmit, sessionID: F.sessionID, promptID: F.promptID, cwd: F.cwd,
            transcriptPath: F.transcriptPath, permissionMode: "default",
            payload: .userPromptSubmit(promptHead: prompt, promptLength: prompt.count)))
    }

    @Test func preToolUseBash() throws {
        let event = try F.event("PreToolUse.json")
        #expect(event == HookEvent(
            name: .preToolUse, sessionID: F.sessionID, promptID: F.promptID, cwd: F.cwd,
            transcriptPath: F.transcriptPath, permissionMode: "default",
            payload: .preToolUse(tool: "Bash", toolUseID: "toolu_01Hq8V3sXb2kLmN4pQrS5tUv",
                                 summary: "swift test --filter HookDecoderTests")))
        #expect(event.isMain)
    }

    @Test func preToolUseAskUserQuestion() throws {
        let event = try F.event("PreToolUse-AskUserQuestion.json")
        #expect(event.payload == .askUserQuestion(toolUseID: "toolu_01AskQ7wErTyUiOpAsDfGhJk", questions: [
            AskedQuestion(header: "Cache", question: "Quelle base de données pour le cache ?",
                          options: ["SQLite", "Redis"], multiSelect: false),
            AskedQuestion(header: "Plateformes", question: "Quelles plateformes cibler ?",
                          options: ["macOS", "Linux", "Windows"], multiSelect: true),
        ]))
    }

    @Test func preToolUseFromSubagent() throws {
        let event = try F.event("PreToolUse-subagent.json")
        #expect(event.subagentID == "a4d2c8f1e0b3a297")
        #expect(!event.isMain)
        #expect(event.payload == .preToolUse(
            tool: "Grep", toolUseID: "toolu_01SubG4rEpXyZ9aBcDeFgHiJ",
            summary: "HookEventName in /Users/seraphin/Projets/pixel-demo/Core/Sources"))
    }

    @Test func postToolUse() throws {
        #expect(try F.event("PostToolUse.json").payload
                == .postToolUse(tool: "Write", toolUseID: "toolu_01Wr1tEfIlEaBcDeFgHiJkLm", failed: false))
    }

    @Test func postToolUseFailure() throws {
        let event = try F.event("PostToolUseFailure.json")
        #expect(event.name == .postToolUseFailure)
        #expect(event.payload == .postToolUse(tool: "Bash", toolUseID: "toolu_01NpMtEsTaBcDeFgHiJkLmNo", failed: true))
    }

    @Test func postToolBatch() throws {
        #expect(try F.event("PostToolBatch.json").payload == .postToolBatch)
    }

    @Test func permissionRequest() throws {
        // The documented input has no `tool_use_id`.
        #expect(try F.event("PermissionRequest.json").payload
                == .permissionRequest(tool: "Bash", toolUseID: nil, summary: "rm -rf node_modules"))
    }

    @Test func permissionDenied() throws {
        let event = try F.event("PermissionDenied.json")
        #expect(event.permissionMode == "auto")
        #expect(event.payload == .permissionDenied(tool: "Bash", toolUseID: "toolu_01DeNiEdAbCdEfGhIjKlMnOp"))
    }

    @Test(arguments: [
        ("Notification.json", "elicitation_dialog", "my-mcp-server needs your input"),
        ("Notification-permission_prompt.json", "permission_prompt", "Claude needs your permission to use Bash"),
        ("Notification-idle_prompt.json", "idle_prompt", "Claude is waiting for your input"),
        ("Notification-quota_auto_resume_fired.json", "quota_auto_resume_fired", "Usage limit reset: continuing your task"),
    ])
    func notification(file: String, type: String, message: String) throws {
        let event = try F.event(file)
        #expect(event.name == .notification)
        #expect(event.payload == .notification(type: type, message: message))
    }

    @Test func stop() throws {
        #expect(try F.event("Stop.json").payload == .stop(
            lastMessageHead: "J'ai ajouté 42 tests au décodeur. Tout passe :\n\n- HookDecoderTests\n- HookRouterTests",
            stopHookActive: false, backgroundTasks: 0, sessionCrons: 0))
    }

    @Test func stopWithBackgroundWork() throws {
        guard case .stop(let head, let active, let tasks, let crons) = try F.event("Stop-background.json").payload else {
            Issue.record("not a stop payload")
            return
        }
        #expect(head?.hasPrefix("I've started the log watcher") == true)
        #expect(active)
        #expect(tasks == 2)
        #expect(crons == 1)
    }

    @Test func stopFailure() throws {
        #expect(try F.event("StopFailure.json").payload
                == .stopFailure(errorType: "overloaded", message: "API Error: Repeated 529 Overloaded errors"))
        #expect(try F.event("StopFailure-rate_limit.json").payload
                == .stopFailure(errorType: "rate_limit", message: "API Error: Rate limit reached"))
    }

    @Test func subagents() throws {
        let start = try F.event("SubagentStart.json")
        #expect(start.payload == .subagent(started: true, type: "Explore"))
        #expect(start.subagentID == "a4d2c8f1e0b3a297")
        let stop = try F.event("SubagentStop.json")
        #expect(stop.payload == .subagent(started: false, type: "Explore"))
        #expect(stop.subagentID == "a4d2c8f1e0b3a297")
    }

    @Test func elicitation() throws {
        #expect(try F.event("Elicitation.json").payload
                == .elicitation(server: "my-mcp-server", id: "elicit-123", message: "Please provide your credentials"))
        #expect(try F.event("ElicitationResult.json").payload == .elicitationResult(server: "my-mcp-server", id: "elicit-123"))
        // hooks.md's form-mode example: `elicitation_id` is optional.
        #expect(try F.event("Elicitation-form.json").payload
                == .elicitation(server: "my-mcp-server", id: nil, message: "Please provide your credentials"))
    }

    @Test func compaction() throws {
        #expect(try F.event("PreCompact.json").payload == .compact(pre: true))
        #expect(try F.event("PostCompact.json").payload == .compact(pre: false))
    }

    @Test func cwdChanged() throws {
        #expect(try F.event("CwdChanged.json").payload == .cwdChanged("/Users/seraphin/Projets/pixel-demo/Core"))
    }

    @Test func unknownEvent() throws {
        let event = try F.event("Unknown-event.json")
        #expect(event.name == .other("TaskCreated"))
        #expect(event.payload == .other)
        #expect(event.sessionID == F.sessionID)
    }

    @Test func permissionScenario() throws {
        let events = try F.lines("scenario-permission.jsonl").map(HookDecoder.decodeHook)
        #expect(events.map(\.name) == [.sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest, .postToolUse, .stop])
        #expect(events.allSatisfy { $0.sessionID == F.sessionID && $0.isMain })
        #expect(events.map(\.promptID) == [nil] + Array(repeating: Optional(F.promptID), count: 5))
        guard case .preToolUse("Bash", let preID?, let summary) = events[2].payload,
              case .permissionRequest("Bash", nil, let permissionSummary) = events[3].payload,
              case .postToolUse("Bash", let postID?, false) = events[4].payload else {
            Issue.record("unexpected payloads: \(events.map(\.payload))")
            return
        }
        #expect(preID == postID)
        #expect(summary == "rm -rf build && swift test")
        #expect(permissionSummary == summary)
    }

    // MARK: - Tolerance and errors

    @Test func missingSessionIDThrows() {
        #expect(throws: HookDecodingError.missingField("session_id")) {
            try decode(#"{"hook_event_name":"Stop"}"#)
        }
        #expect(throws: HookDecodingError.missingField("session_id")) {
            try decode(#"{"session_id":"","hook_event_name":"Stop"}"#)
        }
        #expect(throws: HookDecodingError.missingField("session_id")) {
            try decode(#"{"session_id":42,"hook_event_name":"Stop"}"#)
        }
    }

    @Test func missingEventNameThrows() {
        #expect(throws: HookDecodingError.missingField("hook_event_name")) {
            try decode(#"{"session_id":"s"}"#)
        }
    }

    @Test(arguments: ["", "   ", "[1,2]", "\"text\"", "42", "null", "{\"session_id\":", "{} {}", "not json"])
    func nonObjectThrows(_ json: String) {
        #expect(throws: HookDecodingError.notJSONObject) { try decode(json) }
    }

    @Test func oversizedHookThrows() {
        let data = Data(repeating: 0x20, count: (4 << 20) + 1)
        #expect(throws: HookDecodingError.tooLarge(data.count)) { try HookDecoder.decodeHook(data) }
    }

    @Test func unknownFieldsAndWrongTypesAreIgnored() throws {
        let event = try decode(#"""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":42,"tool_use_id":["x"],"tool_input":"oops",
         "prompt_id":"","agent_id":"","cwd":null,"extra":{"nested":[1,2,{"deep":null}]},"effort":{"level":"max"}}
        """#)
        #expect(event == HookEvent(name: .preToolUse, sessionID: "s", payload: .preToolUse(tool: "", toolUseID: nil, summary: "")))
        #expect(event.isMain)
    }

    @Test func sessionSources() throws {
        for source in ["startup", "resume", "clear", "compact", "fork"] {
            let event = try decode(#"{"session_id":"s","hook_event_name":"SessionStart","source":"\#(source)"}"#)
            #expect(event.payload == .sessionStart(source: SessionSource(rawValue: source)!, model: nil))
        }
        let future = try decode(#"{"session_id":"s","hook_event_name":"SessionStart","source":"teleport"}"#)
        #expect(future.payload == .sessionStart(source: .unknown, model: nil))
    }

    @Test func promptHeadCountsCharacters() throws {
        let prompt = String(repeating: "é", count: 150) + String(repeating: "👩‍👩‍👧", count: 100)
        let event = try decode(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"\#(prompt)"}"#)
        #expect(event.payload == .userPromptSubmit(
            promptHead: String(repeating: "é", count: 150) + String(repeating: "👩‍👩‍👧", count: 50), promptLength: 250))
        let empty = try decode(#"{"session_id":"s","hook_event_name":"UserPromptSubmit"}"#)
        #expect(empty.payload == .userPromptSubmit(promptHead: "", promptLength: 0))
    }

    @Test func stopMessageFallbackAndHead() throws {
        let legacy = try decode(#"{"session_id":"s","hook_event_name":"Stop","assistant_message":"Fini."}"#)
        #expect(legacy.payload == .stop(lastMessageHead: "Fini.", stopHookActive: false, backgroundTasks: 0, sessionCrons: 0))

        let long = String(repeating: "abcdefghij", count: 50)
        let event = try decode(#"""
        {"session_id":"s","hook_event_name":"Stop","last_assistant_message":"\#(long)","assistant_message":"old",
         "stop_hook_active":"yes","background_tasks":3,"session_crons":null}
        """#)
        #expect(event.payload == .stop(lastMessageHead: String(long.prefix(200)), stopHookActive: false,
                                       backgroundTasks: 0, sessionCrons: 0))

        let silent = try decode(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":""}"#)
        #expect(silent.payload == .stop(lastMessageHead: nil, stopHookActive: false, backgroundTasks: 0, sessionCrons: 0))
    }

    @Test func stopFailureFallbacks() throws {
        let event = try decode(#"""
        {"session_id":"s","hook_event_name":"StopFailure","error_type":"billing_error","error_details":"Credit balance too low"}
        """#)
        #expect(event.payload == .stopFailure(errorType: "billing_error", message: "Credit balance too low"))
        let bare = try decode(#"{"session_id":"s","hook_event_name":"StopFailure"}"#)
        #expect(bare.payload == .stopFailure(errorType: nil, message: nil))
    }

    @Test func permissionRequestKeepsToolUseIDWhenPresent() throws {
        let event = try decode(#"""
        {"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"mcp__github__create_issue",
         "tool_input":{"title":"Bug"},"tool_use_id":"toolu_42","agent_id":"agent-7"}
        """#)
        #expect(event.payload == .permissionRequest(tool: "mcp__github__create_issue", toolUseID: "toolu_42",
                                                    summary: "mcp__github__create_issue"))
        #expect(event.subagentID == "agent-7")
    }

    @Test func permissionRequestForAQuestionShowsTheQuestion() throws {
        let event = try decode(#"""
        {"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
         "tool_input":{"questions":[{"question":"Quel nom ?","header":"Nom","options":[{"label":"A"}]}]}}
        """#)
        #expect(event.payload == .permissionRequest(tool: "AskUserQuestion", toolUseID: nil, summary: "Quel nom ?"))
    }

    @Test func askUserQuestionIsTolerant() throws {
        let event = try decode(#"""
        {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"t",
         "tool_input":{"questions":[{"question":"Q ?","options":["Oui",{"label":"Non"},{"description":"no label"},7]},
                                    "not an object",{"header":"H","multiSelect":true}]}}
        """#)
        #expect(event.payload == .askUserQuestion(toolUseID: "t", questions: [
            AskedQuestion(header: "", question: "Q ?", options: ["Oui", "Non"], multiSelect: false),
            AskedQuestion(header: "H", question: "", options: [], multiSelect: true),
        ]))
        let noInput = try decode(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#)
        #expect(noInput.payload == .askUserQuestion(toolUseID: nil, questions: []))
    }

    @Test func cwdChangedFallsBackToCwd() throws {
        let event = try decode(#"{"session_id":"s","hook_event_name":"CwdChanged","cwd":"/tmp/x"}"#)
        #expect(event.payload == .cwdChanged("/tmp/x"))
        let bare = try decode(#"{"session_id":"s","hook_event_name":"CwdChanged"}"#)
        #expect(bare.payload == .other)
    }

    @Test func elicitationWithoutOptionalFields() throws {
        let event = try decode(#"{"session_id":"s","hook_event_name":"Elicitation","mode":"url","url":"https://auth.example.com"}"#)
        #expect(event.payload == .elicitation(server: nil, id: nil, message: ""))
    }

    // MARK: - Summaries

    @Test(arguments: [
        ("Bash", #"{"command":"ls -la","description":"List"}"#, "ls -la"),
        ("Bash", #"{"command":"cd build\nmake -j8\nmake install"}"#, "cd build …"),
        ("Bash", #"{"command":"  \n  echo hi  \n"}"#, "echo hi"),
        ("Bash", #"{"description":"No command"}"#, "No command"),
        ("PowerShell", #"{"command":"Get-ChildItem -Recurse"}"#, "Get-ChildItem -Recurse"),
        ("Read", #"{"file_path":"/Users/me/a b/Main.swift","offset":10,"limit":50}"#, "/Users/me/a b/Main.swift"),
        ("Edit", #"{"old_string":"a","file_path":"/p/Edit.swift","new_string":"b"}"#, "/p/Edit.swift"),
        ("Write", #"{"content":"x","file_path":"/p/Write.swift"}"#, "/p/Write.swift"),
        ("MultiEdit", #"{"file_path":"/p/Multi.swift","edits":[]}"#, "/p/Multi.swift"),
        ("NotebookEdit", #"{"new_source":"x","notebook_path":"/p/n.ipynb"}"#, "/p/n.ipynb"),
        ("WebFetch", #"{"prompt":"Extract","url":"https://example.com/api"}"#, "https://example.com/api"),
        ("WebSearch", #"{"query":"swift testing","allowed_domains":["swift.org"]}"#, "swift testing"),
        ("Grep", #"{"pattern":"TODO.*fix","path":"/src","glob":"*.ts"}"#, "TODO.*fix in /src"),
        ("Grep", #"{"pattern":"TODO"}"#, "TODO"),
        ("Glob", #"{"pattern":"**/*.ts","path":"/p"}"#, "**/*.ts in /p"),
        ("Agent", #"{"prompt":"Find all API endpoints","description":"Find API endpoints","subagent_type":"Explore"}"#, "Find API endpoints"),
        ("Agent", #"{"prompt":"Find all API endpoints"}"#, "Find all API endpoints"),
        ("Task", #"{"description":"Legacy name"}"#, "Legacy name"),
        ("mcp__github__create_issue", #"{"title":"Bug"}"#, "mcp__github__create_issue"),
        ("ExitPlanMode", ###"{"plan":"## Refactor auth\n1. Extract","planFilePath":"/p/plan.md"}"###, "## Refactor auth …"),
        ("SomeFutureTool", #"{"count":3,"flag":true,"blank":"  ","name":"first","other":"second"}"#, "first"),
        ("SomeFutureTool", #"{"count":3}"#, ""),
        ("SomeFutureTool", #"[1,2]"#, ""),
    ])
    func toolSummary(tool: String, input: String, expected: String) throws {
        #expect(HookSummary.tool(tool, input: try HookJSON.parse(Data(input.utf8))) == expected)
    }

    @Test func summaryIsClippedToOneLineOf200Characters() {
        let long = String(repeating: "a", count: 300)
        let clipped = HookSummary.singleLine(long)
        #expect(clipped.count == 200)
        #expect(clipped == String(repeating: "a", count: 198) + " …")

        let multi = HookSummary.singleLine(String(repeating: "b", count: 250) + "\nsecond line")
        #expect(multi == String(repeating: "b", count: 198) + " …")

        let exact = String(repeating: "c", count: 200)
        #expect(HookSummary.singleLine(exact) == exact)
        #expect(HookSummary.singleLine("line one\r\nline two") == "line one …")
        #expect(HookSummary.singleLine("") == "")
        #expect(HookSummary.tool("Bash", input: nil) == "")
    }

    // MARK: - Envelope

    @Test func envelopeWithAllFields() throws {
        let agent = AgentID()
        let data = F.envelope(
            #""v":1,"agent":"\#(agent)","token":"s3cr3t","claude_pid":4242,"ts_ns":123456789012345,"prompt_len":5000,"truncated":["prompt"]"#,
            hook: try F.data("UserPromptSubmit.json"))
        let envelope = try HookDecoder.decodeEnvelope(data)
        #expect(envelope.version == 1)
        #expect(envelope.agentID == agent)
        #expect(envelope.token == "s3cr3t")
        #expect(envelope.claudePID == 4242)
        #expect(envelope.timestampNs == 123_456_789_012_345)
        #expect(envelope.event.name == .userPromptSubmit)
        #expect(envelope.event.payload == .userPromptSubmit(
            promptHead: "Ajoute des tests pour le décodeur de hooks, puis vérifie que « swift test » passe.", promptLength: 5000))
    }

    @Test func envelopeWithoutAgentTokenOrPromptLength() throws {
        let data = F.envelope(#""v":1,"claude_pid":77,"ts_ns":5"#, hook: try F.data("UserPromptSubmit.json"))
        let envelope = try HookDecoder.decodeEnvelope(data)
        let expected = try F.event("UserPromptSubmit.json")
        #expect(envelope.agentID == nil)
        #expect(envelope.token == nil)
        #expect(envelope.claudePID == 77)
        #expect(envelope.timestampNs == 5)
        #expect(envelope.event == expected)
    }

    @Test func envelopeWithTruncatedPrompt() throws {
        // pixel-hook cut the prompt to 4 KiB and reported the full length.
        let prompt = String(repeating: "x", count: 4096)
        let hook = Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":"\#(prompt)"}"#.utf8)
        let envelope = try HookDecoder.decodeEnvelope(
            F.envelope(#""v":1,"ts_ns":9,"prompt_len":10000,"truncated":["prompt"]"#, hook: hook))
        #expect(envelope.event.payload == .userPromptSubmit(promptHead: String(repeating: "x", count: 200), promptLength: 10000))
    }

    @Test func envelopeToleratesOddValues() throws {
        let data = F.envelope(
            #""agent":"not-a-uuid","token":"","claude_pid":-3,"ts_ns":"soon","prompt_len":-1,"extra":{"a":1}"#,
            hook: try F.data("UserPromptSubmit.json"))
        let envelope = try HookDecoder.decodeEnvelope(data)
        let expected = try F.event("UserPromptSubmit.json")
        #expect(envelope.version == 0)
        #expect(envelope.agentID == nil)
        #expect(envelope.token == nil)
        #expect(envelope.claudePID == nil)
        #expect(envelope.timestampNs == 0)
        #expect(envelope.event == expected)

        let overflow = try HookDecoder.decodeEnvelope(
            F.envelope(#""claude_pid":4294967296,"ts_ns":18446744073709551615"#, hook: try F.data("Stop.json")))
        #expect(overflow.claudePID == nil)
        #expect(overflow.timestampNs == UInt64.max)
    }

    @Test func promptLengthOnlyAppliesToPrompts() throws {
        let envelope = try HookDecoder.decodeEnvelope(F.envelope(#""prompt_len":99"#, hook: try F.data("Stop.json")))
        let expected = try F.event("Stop.json")
        #expect(envelope.event == expected)
    }

    @Test func envelopeErrors() throws {
        #expect(throws: HookDecodingError.missingField("hook")) {
            try HookDecoder.decodeEnvelope(Data(#"{"v":1,"ts_ns":1}"#.utf8))
        }
        #expect(throws: HookDecodingError.notJSONObject) {
            try HookDecoder.decodeEnvelope(Data(#"{"v":1,"hook":[1]}"#.utf8))
        }
        #expect(throws: HookDecodingError.notJSONObject) {
            try HookDecoder.decodeEnvelope(Data("[]\n".utf8))
        }
        // stdin was not JSON: pixel-hook sends a placeholder, which has no session.
        #expect(throws: HookDecodingError.missingField("session_id")) {
            try HookDecoder.decodeEnvelope(Data(#"{"v":1,"hook":{"_unparsed":true,"len":12}}"#.utf8))
        }
        let oversized = Data(repeating: 0x20, count: (1 << 20) + 1)
        #expect(throws: HookDecodingError.tooLarge(oversized.count)) { try HookDecoder.decodeEnvelope(oversized) }
    }

    @Test func everyFixtureDecodesInsideAnEnvelope() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: F.url("").path).filter { $0.hasSuffix(".json") }
        #expect(files.count >= HookEventName.subscribed.count)
        for file in files {
            let envelope = try HookDecoder.decodeEnvelope(F.envelope(#""v":1,"ts_ns":1"#, hook: try F.data(file)))
            let expected = try F.event(file)
            #expect(envelope.event == expected, "\(file)")
        }
    }
}

@Suite struct HookJSONTests {
    private func parse(_ text: String, maxDepth: Int = HookJSON.defaultMaxDepth) throws -> HookJSON {
        try HookJSON.parse(Data(text.utf8), maxDepth: maxDepth)
    }

    @Test func objectsKeepDocumentOrder() throws {
        let object = try #require(try parse(#"{"b":1,"a":"x","c":"y","a":true}"#).objectValue)
        #expect(object.keys == ["b", "a", "c"])
        #expect(object["a"] == .bool(true))
        #expect(object.values == [.number("1"), .bool(true), .string("y")])
    }

    @Test func stringEscapes() throws {
        #expect(try parse(#""\"\\\/\b\f\n\r\t\u00e9\ud83d\ude00 é""#) == .string("\"\\/\u{8}\u{C}\n\r\té😀 é"))
        #expect(try parse(#""\ud800x""#) == .string("\u{FFFD}x"))
        #expect(try parse(#""\udc00""#) == .string("\u{FFFD}"))
        #expect(try parse(#""\ud800\u0041""#) == .string("\u{FFFD}A"))
        #expect(try HookJSON.parse(Data([0x22, 0xFF, 0x41, 0x22])) == .string("\u{FFFD}A"))
    }

    @Test func numbersStayExact() throws {
        #expect(try parse("18446744073709551615").uint64Value == UInt64.max)
        #expect(try parse("-9223372036854775808").int64Value == Int64.min)
        #expect(try parse("1e2").intValue == 100)
        #expect(try parse("1.5").intValue == nil)
        #expect(try parse("-0").intValue == 0)
        #expect(try parse("12.5e-3") == .number("12.5e-3"))
        #expect(try parse("-1").uint64Value == nil)
        #expect(try parse("1e400").intValue == nil)
    }

    @Test func literalsAndWhitespace() throws {
        #expect(try HookJSON.parse(Data([0xEF, 0xBB, 0xBF] + Array(" \n\t[true, false, null] \r\n".utf8)))
                == .array([.bool(true), .bool(false), .null]))
        #expect(try parse("{ }") == .object(HookJSONObject()))
        #expect(try parse("[ ]") == .array([]))
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "{\"a\":1,}", "01", "1.", "-", ".5", "tru", "nul", "\"abc",
                      "{} x", "\"\\x\"", "\"\\u12\"", "[1 2]", "{1:2}", "'a'"])
    func invalidDocumentsThrow(_ text: String) {
        #expect(throws: HookJSON.SyntaxError.self) { try parse(text) }
    }

    @Test func deepNestingIsSkipped() throws {
        #expect(try parse("[[[1]]]", maxDepth: 2) == .array([.array([.null])]))
        let object = try parse(#"{"a":{"b":{"c":[1,"]}"]}},"d":"ok"}"#, maxDepth: 2)
        #expect(object["a"]?["b"] == .null)
        #expect(object["d"] == .string("ok"))
        #expect(try parse(#"[["]\"", "}"], "after"]"#, maxDepth: 1) == .array([.null, .string("after")]))

        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(try parse(deep).arrayValue?.count == 1)
        #expect(throws: HookJSON.SyntaxError.self) { try parse(String(repeating: "[", count: 1_000)) }
    }
}
