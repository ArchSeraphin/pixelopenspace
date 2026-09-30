import Foundation

/// One agent in the waiting tray: its oldest open wait and how many are open.
public struct WaitingEntry: Equatable, Sendable, Identifiable {
    public var agentID: AgentID
    /// The oldest open wait.
    public var reason: WaitReason
    public var since: Date
    /// Number of open waits (parallel tools, subagents).
    public var count: Int

    public var id: AgentID { agentID }

    public init(agentID: AgentID, reason: WaitReason, since: Date, count: Int) {
        self.agentID = agentID
        self.reason = reason
        self.since = since
        self.count = count
    }
}

/// Counters of the status bar and content of the waiting tray, for all agents at once.
public struct StatusSummary: Equatable, Sendable {
    /// Agents per displayed state kind; kinds with no agent are absent.
    public var counts: [AgentStateKind: Int]
    /// Waiting agents, oldest wait first (ties broken by `AgentID`).
    public var waiting: [WaitingEntry]

    /// Status-bar order: most urgent first, offline last.
    public static let displayOrder: [AgentStateKind] = [
        .waitingInput, .error, .done, .waitingBackground, .quotaPaused, .working, .thinking, .launching, .idle, .offline,
    ]

    public init(counts: [AgentStateKind: Int] = [:], waiting: [WaitingEntry] = []) {
        self.counts = counts
        self.waiting = waiting
    }

    public static func compute(_ runtimes: [AgentID: AgentRuntime]) -> StatusSummary {
        var summary = StatusSummary()
        for (agentID, runtime) in runtimes {
            summary.counts[runtime.kind, default: 0] += 1
            if let oldest = runtime.oldestWait {
                summary.waiting.append(WaitingEntry(agentID: agentID, reason: oldest.reason, since: oldest.since,
                                                    count: runtime.pendingWaits.count))
            }
        }
        summary.waiting.sort { lhs, rhs in
            lhs.since != rhs.since ? lhs.since < rhs.since : lhs.agentID < rhs.agentID
        }
        return summary
    }

    /// The waiting agent after `current` in tray order, cycling (⌘'). The first one when `current` is nil
    /// or no longer waiting; nil when nobody waits.
    public static func nextWaiting(after current: AgentID?, in summary: StatusSummary) -> AgentID? {
        let ids = summary.waiting.map(\.agentID)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids[0] }
        return ids[(index + 1) % ids.count]
    }

    public func count(of kind: AgentStateKind) -> Int {
        counts[kind] ?? 0
    }

    public var total: Int {
        counts.values.reduce(0, +)
    }

    /// Kinds with at least one agent, in `displayOrder`.
    public var visibleKinds: [AgentStateKind] {
        Self.displayOrder.filter { count(of: $0) > 0 }
    }

    /// Status-bar text for `kind` ("2 attendent", "1 tour fini"), nil when no agent is in that state.
    public func text(for kind: AgentStateKind) -> String? {
        let n = count(of: kind)
        return n > 0 ? Self.label(for: kind, count: n) : nil
    }

    /// "1 attend" / "3 attendent", "1 tour fini" / "2 tours finis", "2 au repos"…
    public static func label(for kind: AgentStateKind, count n: Int) -> String {
        let many = abs(n) > 1
        switch kind {
        case .waitingInput: return "\(n) \(many ? "attendent" : "attend")"
        case .error: return "\(n) en erreur"
        case .done: return "\(n) \(many ? "tours finis" : "tour fini")"
        case .waitingBackground: return "\(n) \(many ? "attendent" : "attend") une tâche de fond"
        case .quotaPaused: return "\(n) en pause"
        case .working: return "\(n) \(many ? "travaillent" : "travaille")"
        case .thinking: return "\(n) \(many ? "réfléchissent" : "réfléchit")"
        case .launching: return "\(n) \(many ? "démarrent" : "démarre")"
        case .idle: return "\(n) au repos"
        case .offline: return "\(n) hors ligne"
        }
    }
}
