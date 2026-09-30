import Foundation

// Runtime (non-persisted) state of an agent. Changed ONLY by `AgentStateMachine.reduce`.
// Transition table: docs/PROPOSITION.md, section 4.3.

public enum OfflineReason: String, Codable, Sendable {
    case notStarted, closedByUser, appRelaunched, exited, orphanElsewhere
}

public enum AgentError: Equatable, Sendable {
    /// `StopFailure` with an API error type other than quota/account.
    case api(String)
    /// authentication_failed, oauth_org_not_allowed, account_on_hold, billing_error.
    case account(String)
    /// Process exited with a non-zero code or a signal (`nil`).
    case crashed(Int32?)
    case launchFailed(String)
}

/// What the agent is doing, excluding waits (which are tracked separately in `pendingWaits`).
public enum AgentPhase: Equatable, Sendable {
    case offline(OfflineReason)
    case launching
    case idle
    case thinking
    case working(ToolKind)
    /// Turn finished. Provisional while `AgentRuntime.pendingStop != nil`.
    case done
    /// `Stop` reported background tasks or crons: never auto-dispatch.
    case waitingBackground(tasks: Int, crons: Int)
    /// Usage limit: Claude Code may resume on its own (`autoResume`).
    case quotaPaused(resetAt: Date?, autoResume: Bool)
    case error(AgentError)
}

public enum ToolKind: Equatable, Hashable, Sendable {
    case read, edit, bash, search, web, subagent, question
    case mcp(String)
    case other(String)

    /// Read→read; Edit/Write/MultiEdit/NotebookEdit→edit; Bash→bash; Grep/Glob/LS→search;
    /// WebFetch/WebSearch→web; Agent/Task→subagent; AskUserQuestion→question; mcp__server__tool→mcp(server).
    public static func from(toolName: String) -> ToolKind {
        switch toolName {
        case "Read": return .read
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .edit
        case "Bash", "BashOutput", "KillShell", "PowerShell": return .bash
        case "Grep", "Glob", "LS": return .search
        case "WebFetch", "WebSearch": return .web
        case "Agent", "Task": return .subagent
        case "AskUserQuestion": return .question
        default:
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                return .mcp(parts.count >= 2 ? String(parts[1]) : toolName)
            }
            return .other(toolName)
        }
    }
}

/// Key of an open wait. Several waits can be open at once (parallel tools, subagents).
public enum WaitKey: Hashable, Sendable {
    case tool(toolUseID: String)
    case elicitation(String)
    case notification(String)
    /// Heuristic: silent launch (folder trust, login…) → "look at the terminal".
    case terminal
}

public enum WaitReason: Equatable, Sendable {
    /// `PermissionRequest` (immediate).
    case permission(tool: String, summary: String)
    /// `PreToolUse(AskUserQuestion)`: questions and options decoded.
    case question([AskedQuestion])
    /// `Elicitation` (MCP dialog).
    case elicitation(server: String?, message: String)
    /// `Notification` catch-up (permission_prompt, agent_needs_input, elicitation_dialog,
    /// quota_auto_resume_stale "press Enter"…).
    case notification(type: String)
    case terminal
}

public struct PendingWait: Equatable, Sendable {
    public var reason: WaitReason
    public var subagentID: String?
    public var since: Date

    public init(reason: WaitReason, subagentID: String?, since: Date) {
        self.reason = reason
        self.subagentID = subagentID
        self.since = since
    }
}

public enum HookHealth: Equatable, Sendable {
    /// No hook received yet since launch.
    case unknown(since: Date)
    case healthy
    /// No `SessionStart` 15 s after launch: states approximate, auto-send off.
    case degraded
}

public enum InputBoxState: Equatable, Sendable {
    case empty
    case draft(prefix: String)
    case unknown
}

/// What `ScreenPatterns` recognised on the visible terminal lines.
public struct ScreenFacts: Equatable, Sendable {
    public var inputBox: InputBoxState
    public var dialogVisible: Bool
    public var spinnerVisible: Bool
    /// The "usage limit" line, if visible.
    public var quotaLine: String?
    /// Set when the patterns did not match this Claude Code version at all.
    public var recognized: Bool

    public init(inputBox: InputBoxState = .unknown, dialogVisible: Bool = false, spinnerVisible: Bool = false,
                quotaLine: String? = nil, recognized: Bool = false) {
        self.inputBox = inputBox
        self.dialogVisible = dialogVisible
        self.spinnerVisible = spinnerVisible
        self.quotaLine = quotaLine
        self.recognized = recognized
    }
}

/// `Stop` received but not yet committed (quiet window, T13–T13c).
public struct PendingStop: Equatable, Sendable {
    public var at: Date
    public var promptID: String?
    public var stopHookActive: Bool
    public var backgroundTasks: Int
    public var sessionCrons: Int

    public init(at: Date, promptID: String?, stopHookActive: Bool, backgroundTasks: Int, sessionCrons: Int) {
        self.at = at
        self.promptID = promptID
        self.stopHookActive = stopHookActive
        self.backgroundTasks = backgroundTasks
        self.sessionCrons = sessionCrons
    }
}

/// What is being delivered right now (step 2b). `itemID` is a card or instruction UUID string.
public struct PendingDelivery: Equatable, Sendable {
    public var itemID: String
    /// First 40 normalised characters of the delivered text: matched against `UserPromptSubmit`.
    public var prefix: String
    public var startedAt: Date
    public var hookSeqAtStart: UInt64
    public var retried: Bool

    public init(itemID: String, prefix: String, startedAt: Date, hookSeqAtStart: UInt64, retried: Bool = false) {
        self.itemID = itemID
        self.prefix = prefix
        self.startedAt = startedAt
        self.hookSeqAtStart = hookSeqAtStart
        self.retried = retried
    }
}

public enum DeliveryAbortReason: Equatable, Sendable {
    case guardFailed(String)
    case noPromptSubmit
    case processGone
}

public struct AgentRuntime: Equatable, Sendable {
    public var phase: AgentPhase
    public var phaseSince: Date
    public var pendingWaits: [WaitKey: PendingWait]
    /// tool_use_id → tool, for the main agent and subagents.
    public var inFlightTools: [String: ToolKind]
    /// pid of the PTY child: the only `claude_pid` accepted for this agent.
    public var pid: Int32?
    /// The process was started with a positional prompt (first post-it).
    public var launchedWithPrompt: Bool
    public var currentSessionID: String?
    public var currentPromptID: String?
    public var lastHookAt: Date?
    /// Sequence number of the last accepted hook event ("nothing new" delivery guard).
    public var hookSeq: UInt64
    public var lastOutputAt: Date?
    public var screen: ScreenFacts?
    public var hookHealth: HookHealth
    public var pendingStop: PendingStop?
    /// A `Stop` was committed for this prompt: a later main event for the same prompt reopens the turn (T13c).
    public var committedStopPromptID: String?
    public var pendingDelivery: PendingDelivery?
    public var interruptRequestedAt: Date?
    /// Set by `closeRequested`: the next process exit is `offline(.closedByUser)`, not a crash.
    public var closeRequestedAt: Date?
    public var activeSubagents: Int
    /// The user has seen the wait: the "!" becomes less intrusive.
    public var acknowledgedWaiting: Bool
    /// No news for a long time while thinking/working.
    public var stale: Bool

    public init(phase: AgentPhase = .offline(.notStarted), phaseSince: Date) {
        self.phase = phase
        self.phaseSince = phaseSince
        self.pendingWaits = [:]
        self.inFlightTools = [:]
        self.pid = nil
        self.launchedWithPrompt = false
        self.currentSessionID = nil
        self.currentPromptID = nil
        self.lastHookAt = nil
        self.hookSeq = 0
        self.lastOutputAt = nil
        self.screen = nil
        self.hookHealth = .unknown(since: phaseSince)
        self.pendingStop = nil
        self.committedStopPromptID = nil
        self.pendingDelivery = nil
        self.interruptRequestedAt = nil
        self.closeRequestedAt = nil
        self.activeSubagents = 0
        self.acknowledgedWaiting = false
        self.stale = false
    }

    /// Displayed state: waiting as soon as one wait is open, otherwise the phase.
    public var state: AgentState {
        if let oldest = pendingWaits.values.min(by: { $0.since < $1.since }) {
            return .waitingInput(oldest.reason, count: pendingWaits.count, since: oldest.since)
        }
        return .phase(phase)
    }

    public var kind: AgentStateKind { state.kind }
}

public enum AgentState: Equatable, Sendable {
    case phase(AgentPhase)
    /// The oldest open wait, the number of open waits, and since when.
    case waitingInput(WaitReason, count: Int, since: Date)

    public var kind: AgentStateKind {
        switch self {
        case .waitingInput: return .waitingInput
        case .phase(let p):
            switch p {
            case .offline: return .offline
            case .launching: return .launching
            case .idle: return .idle
            case .thinking: return .thinking
            case .working: return .working
            case .done: return .done
            case .waitingBackground: return .waitingBackground
            case .quotaPaused: return .quotaPaused
            case .error: return .error
            }
        }
    }
}

/// Flat state kinds for counters, urgency and icons.
public enum AgentStateKind: String, Sendable, CaseIterable, Codable {
    case offline, launching, idle, thinking, working, waitingInput, waitingBackground, quotaPaused, done, error

    /// waitingInput 3, error 2, done/waitingBackground/quotaPaused 1, others 0.
    public var urgency: Int {
        switch self {
        case .waitingInput: return 3
        case .error: return 2
        case .done, .waitingBackground, .quotaPaused: return 1
        default: return 0
        }
    }
}
