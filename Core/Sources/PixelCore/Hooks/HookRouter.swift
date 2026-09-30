import Foundation

/// What the router knows about one of the app's agents.
public struct RoutingEntry: Sendable, Equatable {
    /// PID of the `claude` process running in the agent's PTY; `nil` when not running or not known yet.
    public var pid: Int32?
    /// Last `session_id` seen for the agent. Not used by `HookRouter.route`; kept for the caller's
    /// fallback correlation by session.
    public var sessionID: String?

    public init(pid: Int32? = nil, sessionID: String? = nil) {
        self.pid = pid
        self.sessionID = sessionID
    }
}

public enum RouteDecision: Equatable, Sendable {
    /// The event belongs to this agent.
    case accept(AgentID)
    /// A nested `claude` launched by this agent (it inherited `PIXEL_AGENT_ID`): never adopted (proposal 5.7).
    case ignoreNested(AgentID)
    /// Missing or wrong `PIXEL_HOOK_TOKEN`.
    case rejectToken
    /// Valid token but no such agent (deleted, or from a previous app run).
    case unknownAgent(AgentID)
    /// A session not launched by the app (global install, step 5).
    case external
}

/// Decides which agent a hook envelope belongs to (proposal 2.3 and 5.7). Pure.
public enum HookRouter {
    /// The token is checked first, for every envelope, external ones included (they read it from `run/token`).
    /// Then: no `agent` → `.external`; unknown agent → `.unknownAgent`; a `claude_pid` different from the
    /// agent's PTY pid → `.ignoreNested`. A missing pid on either side cannot be checked and is accepted.
    public static func route(_ e: HookEnvelope, expectedToken: String, agents: [AgentID: RoutingEntry]) -> RouteDecision {
        guard let token = e.token, tokensMatch(token, expectedToken) else { return .rejectToken }
        guard let agentID = e.agentID else { return .external }
        guard let entry = agents[agentID] else { return .unknownAgent(agentID) }
        if let expectedPID = entry.pid, let claudePID = e.claudePID, expectedPID != claudePID {
            return .ignoreNested(agentID)
        }
        return .accept(agentID)
    }

    /// Constant-time comparison: the time taken does not depend on the content of either token.
    /// An empty expected token never matches.
    static func tokensMatch(_ token: String, _ expected: String) -> Bool {
        let lhs = Array(token.utf8)
        let rhs = Array(expected.utf8)
        guard !rhs.isEmpty else { return false }
        var difference = UInt(bitPattern: lhs.count ^ rhs.count)
        for i in 0..<max(lhs.count, rhs.count) {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            difference |= UInt(a ^ b)
        }
        return difference == 0
    }
}
