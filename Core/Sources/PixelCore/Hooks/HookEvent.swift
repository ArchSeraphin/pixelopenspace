import Foundation

/// Hook events the app subscribes to (https://code.claude.com/docs/en/hooks.md).
/// Unknown names decode to `.other` so a new Claude Code version never breaks decoding.
public enum HookEventName: Hashable, Sendable {
    case sessionStart, sessionEnd, userPromptSubmit
    case preToolUse, postToolUse, postToolUseFailure, postToolBatch
    case permissionRequest, permissionDenied, notification
    case stop, stopFailure, subagentStart, subagentStop
    case elicitation, elicitationResult, preCompact, postCompact, cwdChanged
    case other(String)

    private static let known: [(HookEventName, String)] = [
        (.sessionStart, "SessionStart"), (.sessionEnd, "SessionEnd"), (.userPromptSubmit, "UserPromptSubmit"),
        (.preToolUse, "PreToolUse"), (.postToolUse, "PostToolUse"), (.postToolUseFailure, "PostToolUseFailure"),
        (.postToolBatch, "PostToolBatch"), (.permissionRequest, "PermissionRequest"),
        (.permissionDenied, "PermissionDenied"), (.notification, "Notification"), (.stop, "Stop"),
        (.stopFailure, "StopFailure"), (.subagentStart, "SubagentStart"), (.subagentStop, "SubagentStop"),
        (.elicitation, "Elicitation"), (.elicitationResult, "ElicitationResult"), (.preCompact, "PreCompact"),
        (.postCompact, "PostCompact"), (.cwdChanged, "CwdChanged"),
    ]

    public init(rawValue: String) {
        self = Self.known.first(where: { $0.1 == rawValue })?.0 ?? .other(rawValue)
    }

    public var rawValue: String {
        if case .other(let name) = self { return name }
        return Self.known.first(where: { $0.0 == self })!.1
    }

    /// Exactly the events written into the injected `hooks-settings.json` (proposal 5.2).
    /// Never `WorktreeCreate`/`WorktreeRemove`: they replace git's default behaviour.
    public static let subscribed: [HookEventName] = known.map(\.0)
}

/// One question of the `AskUserQuestion` tool (`tool_input.questions`).
public struct AskedQuestion: Equatable, Hashable, Sendable {
    public var header: String
    public var question: String
    public var options: [String]
    public var multiSelect: Bool

    public init(header: String, question: String, options: [String], multiSelect: Bool) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// Event-specific data, decoded tolerantly: missing fields become `nil`/defaults.
public enum HookPayload: Equatable, Sendable {
    case sessionStart(source: SessionSource, model: String?)
    case sessionEnd(reason: String?)
    case userPromptSubmit(promptHead: String, promptLength: Int)
    /// `summary` = Bash command, file path, URL or pattern, at most 200 characters.
    case preToolUse(tool: String, toolUseID: String?, summary: String)
    /// `PreToolUse` of the `AskUserQuestion` tool, with its questions decoded.
    case askUserQuestion(toolUseID: String?, questions: [AskedQuestion])
    case postToolUse(tool: String, toolUseID: String?, failed: Bool)
    case postToolBatch
    case permissionRequest(tool: String, toolUseID: String?, summary: String)
    /// Auto-mode denials only.
    case permissionDenied(tool: String?, toolUseID: String?)
    case notification(type: String?, message: String?)
    case stop(lastMessageHead: String?, stopHookActive: Bool, backgroundTasks: Int, sessionCrons: Int)
    /// `error_type`: rate_limit, overloaded, authentication_failed, oauth_org_not_allowed, account_on_hold,
    /// billing_error, server_error, unknown…
    case stopFailure(errorType: String?, message: String?)
    case subagent(started: Bool, type: String?)
    case elicitation(server: String?, id: String?, message: String)
    case elicitationResult(id: String?)
    case compact(pre: Bool)
    case cwdChanged(String)
    case other
}

public struct HookEvent: Equatable, Sendable {
    public var name: HookEventName
    public var sessionID: String
    /// UUID of the prompt being processed (v2.1.196+); absent before the first input.
    public var promptID: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var permissionMode: String?
    /// `agent_id`: set when the event comes from a subagent.
    public var subagentID: String?
    public var payload: HookPayload

    public init(name: HookEventName, sessionID: String, promptID: String? = nil, cwd: String? = nil,
                transcriptPath: String? = nil, permissionMode: String? = nil, subagentID: String? = nil,
                payload: HookPayload) {
        self.name = name
        self.sessionID = sessionID
        self.promptID = promptID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.permissionMode = permissionMode
        self.subagentID = subagentID
        self.payload = payload
    }

    /// "Main" = not from a subagent.
    public var isMain: Bool { subagentID == nil }
}

/// What `pixel-hook` sends over the socket: the hook JSON wrapped with the app's routing data.
/// Wire format: `HookWire` in PixelIPC.
public struct HookEnvelope: Equatable, Sendable {
    public var version: Int
    public var agentID: AgentID?
    public var token: String?
    /// First non-shell ancestor of `pixel-hook`: the `claude` process that ran the hook.
    public var claudePID: Int32?
    /// `HookWire.monotonicNanos()` at the time the hook ran.
    public var timestampNs: UInt64
    public var event: HookEvent

    public init(version: Int, agentID: AgentID?, token: String?, claudePID: Int32?, timestampNs: UInt64, event: HookEvent) {
        self.version = version
        self.agentID = agentID
        self.token = token
        self.claudePID = claudePID
        self.timestampNs = timestampNs
        self.event = event
    }
}
