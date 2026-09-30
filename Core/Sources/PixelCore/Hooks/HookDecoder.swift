import Foundation
import PixelIPC

public enum HookDecodingError: Error, Equatable, Sendable {
    case notJSONObject
    case missingField(String)
    case tooLarge(Int)
}

/// Tolerant decoder for hook JSON and `pixel-hook` envelopes: unknown events decode to `.other`,
/// unknown fields are ignored, missing optional fields become `nil`.
///
/// Field names follow https://code.claude.com/docs/en/hooks.md. Only `session_id` and `hook_event_name`
/// are required; empty strings count as absent.
public enum HookDecoder {
    /// Decodes one envelope line written by `pixel-hook` (wire format: `HookWire`).
    /// `v` defaults to 0 and `ts_ns` to 0 when absent; an `agent` that is not a UUID becomes `nil`.
    /// `prompt_len` (length of the prompt before truncation) replaces the `UserPromptSubmit` prompt length.
    public static func decodeEnvelope(_ data: Data) throws -> HookEnvelope {
        guard data.count <= HookWire.maxMessageBytes else { throw HookDecodingError.tooLarge(data.count) }
        let root = try parseObject(data)
        guard let hookValue = root[HookWire.keyHook] else { throw HookDecodingError.missingField(HookWire.keyHook) }
        guard let hook = hookValue.objectValue else { throw HookDecodingError.notJSONObject }

        var event = try decodeEvent(hook)
        if case .userPromptSubmit(let head, _) = event.payload,
           let promptLength = root[HookWire.keyPromptLength]?.intValue, promptLength >= 0 {
            event.payload = .userPromptSubmit(promptHead: head, promptLength: promptLength)
        }

        let claudePID = root[HookWire.keyClaudePID]?.int64Value
            .flatMap { Int32(exactly: $0) }
            .flatMap { $0 > 0 ? $0 : nil }
        return HookEnvelope(
            version: root[HookWire.keyVersion]?.intValue ?? 0,
            agentID: root.text(HookWire.keyAgent).flatMap(AgentID.init(string:)),
            token: root.text(HookWire.keyToken),
            claudePID: claudePID,
            timestampNs: root[HookWire.keyTimestamp]?.uint64Value ?? 0,
            event: event
        )
    }

    /// Decodes the raw JSON Claude Code writes on a hook's stdin.
    public static func decodeHook(_ data: Data) throws -> HookEvent {
        guard data.count <= HookWire.maxStdinBytes else { throw HookDecodingError.tooLarge(data.count) }
        return try decodeEvent(parseObject(data))
    }

    // MARK: - Event

    private static func parseObject(_ data: Data) throws -> HookJSONObject {
        guard let object = (try? HookJSON.parse(data))?.objectValue else { throw HookDecodingError.notJSONObject }
        return object
    }

    private static func decodeEvent(_ hook: HookJSONObject) throws -> HookEvent {
        guard let sessionID = hook.text("session_id") else { throw HookDecodingError.missingField("session_id") }
        guard let rawName = hook.text("hook_event_name") else { throw HookDecodingError.missingField("hook_event_name") }
        let name = HookEventName(rawValue: rawName)
        return HookEvent(
            name: name,
            sessionID: sessionID,
            promptID: hook.text("prompt_id"),
            cwd: hook.text("cwd"),
            transcriptPath: hook.text("transcript_path"),
            permissionMode: hook.text("permission_mode"),
            subagentID: hook.text("agent_id"),
            payload: payload(for: name, hook)
        )
    }

    private static func payload(for name: HookEventName, _ hook: HookJSONObject) -> HookPayload {
        let toolName = hook.text("tool_name")
        let toolUseID = hook.text("tool_use_id")
        switch name {
        case .sessionStart:
            return .sessionStart(source: SessionSource(hookValue: hook.text("source")), model: hook.text("model"))
        case .sessionEnd:
            return .sessionEnd(reason: hook.text("reason"))
        case .userPromptSubmit:
            let prompt = hook["prompt"]?.stringValue ?? ""
            return .userPromptSubmit(promptHead: HookSummary.head(prompt), promptLength: prompt.count)
        case .preToolUse:
            let tool = toolName ?? ""
            if tool == "AskUserQuestion" {
                return .askUserQuestion(toolUseID: toolUseID, questions: askedQuestions(hook["tool_input"]))
            }
            return .preToolUse(tool: tool, toolUseID: toolUseID, summary: HookSummary.tool(tool, input: hook["tool_input"]))
        case .postToolUse:
            return .postToolUse(tool: toolName ?? "", toolUseID: toolUseID, failed: false)
        case .postToolUseFailure:
            return .postToolUse(tool: toolName ?? "", toolUseID: toolUseID, failed: true)
        case .postToolBatch:
            return .postToolBatch
        case .permissionRequest:
            // The documented input has no `tool_use_id`; it is read when present.
            let tool = toolName ?? ""
            return .permissionRequest(tool: tool, toolUseID: toolUseID, summary: HookSummary.tool(tool, input: hook["tool_input"]))
        case .permissionDenied:
            return .permissionDenied(tool: toolName, toolUseID: toolUseID)
        case .notification:
            return .notification(type: hook.text("notification_type"), message: hook.text("message"))
        case .stop:
            // `assistant_message`: older name seen in a third-party source (proposal 1).
            let message = hook.text("last_assistant_message") ?? hook.text("assistant_message")
            return .stop(
                lastMessageHead: message.map { HookSummary.head($0) },
                stopHookActive: hook["stop_hook_active"]?.boolValue ?? false,
                backgroundTasks: hook["background_tasks"]?.arrayValue?.count ?? 0,
                sessionCrons: hook["session_crons"]?.arrayValue?.count ?? 0
            )
        case .stopFailure:
            // The doc names the type `error`; `last_assistant_message` holds the rendered error text.
            return .stopFailure(
                errorType: hook.text("error") ?? hook.text("error_type"),
                message: hook.text("last_assistant_message") ?? hook.text("error_details")
            )
        case .subagentStart:
            return .subagent(started: true, type: hook.text("agent_type"))
        case .subagentStop:
            return .subagent(started: false, type: hook.text("agent_type"))
        case .elicitation:
            return .elicitation(
                server: hook.text("mcp_server_name"),
                id: hook.text("elicitation_id"),
                message: hook["message"]?.stringValue ?? ""
            )
        case .elicitationResult:
            return .elicitationResult(server: hook.text("mcp_server_name"), id: hook.text("elicitation_id"))
        case .preCompact:
            return .compact(pre: true)
        case .postCompact:
            return .compact(pre: false)
        case .cwdChanged:
            guard let directory = hook.text("new_cwd") ?? hook.text("cwd") else { return .other }
            return .cwdChanged(directory)
        case .other:
            return .other
        }
    }

    /// `tool_input.questions` of `AskUserQuestion`. Options are `{"label": …}` objects (plain strings are accepted).
    private static func askedQuestions(_ input: HookJSON?) -> [AskedQuestion] {
        guard let questions = input?["questions"]?.arrayValue else { return [] }
        return questions.compactMap { entry in
            guard let question = entry.objectValue else { return nil }
            let options = question["options"]?.arrayValue?.compactMap { option in
                option.stringValue ?? option["label"]?.stringValue
            } ?? []
            return AskedQuestion(
                header: question["header"]?.stringValue ?? "",
                question: question["question"]?.stringValue ?? "",
                options: options,
                multiSelect: question["multiSelect"]?.boolValue ?? false
            )
        }
    }
}

private extension HookJSONObject {
    /// String member, `nil` when absent, not a string, or empty.
    func text(_ key: String) -> String? {
        guard let value = self[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }
}
