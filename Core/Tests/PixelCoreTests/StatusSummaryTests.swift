import Foundation
import Testing
@testable import PixelCore

@Suite struct StatusSummaryTests {
    static let t0 = Date(timeIntervalSince1970: 3_000_000)

    private static func id(_ n: Int) -> AgentID {
        let digits = String(n)
        return AgentID(UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - digits.count) + digits)!)
    }

    private func runtime(_ phase: AgentPhase, waits: [(WaitKey, WaitReason, TimeInterval)] = []) -> AgentRuntime {
        var r = AgentRuntime(phase: phase, phaseSince: Self.t0)
        for (key, reason, offset) in waits {
            r.pendingWaits[key] = PendingWait(reason: reason, subagentID: nil, since: Self.t0 + offset)
        }
        return r
    }

    private let bash = WaitReason.permission(tool: "Bash", summary: "rm -rf dist")
    private let question = WaitReason.question([])

    @Test func countsPerDisplayedKind() {
        let summary = StatusSummary.compute([
            Self.id(1): runtime(.working(.bash)),
            Self.id(2): runtime(.working(.edit)),
            Self.id(3): runtime(.thinking),
            Self.id(4): runtime(.working(.bash), waits: [(.tool(toolUseID: "t"), bash, 5)]),
            Self.id(5): runtime(.offline(.notStarted)),
            Self.id(6): runtime(.done),
        ])
        #expect(summary.counts == [.working: 2, .thinking: 1, .waitingInput: 1, .offline: 1, .done: 1])
        #expect(summary.count(of: .error) == 0)
        #expect(summary.total == 6)
        #expect(summary.visibleKinds == [.waitingInput, .done, .working, .thinking, .offline])
        #expect(summary.text(for: .working) == "2 travaillent")
        #expect(summary.text(for: .waitingInput) == "1 attend")
        #expect(summary.text(for: .error) == nil)
    }

    @Test func waitingIsSortedOldestFirstThenByAgent() {
        let summary = StatusSummary.compute([
            Self.id(3): runtime(.working(.bash), waits: [(.tool(toolUseID: "a"), bash, 10)]),
            Self.id(2): runtime(.thinking, waits: [(.tool(toolUseID: "b"), question, 20),
                                                   (.notification("permission_prompt"), .notification(type: "permission_prompt"), 4)]),
            Self.id(1): runtime(.working(.bash), waits: [(.terminal, .terminal, 10)]),
            Self.id(9): runtime(.idle),
        ])
        #expect(summary.waiting == [
            WaitingEntry(agentID: Self.id(2), reason: .notification(type: "permission_prompt"), since: Self.t0 + 4, count: 2),
            WaitingEntry(agentID: Self.id(1), reason: .terminal, since: Self.t0 + 10, count: 1),
            WaitingEntry(agentID: Self.id(3), reason: bash, since: Self.t0 + 10, count: 1),
        ])
        #expect(summary.waiting.map(\.id) == [Self.id(2), Self.id(1), Self.id(3)])
    }

    @Test func nextWaitingCycles() {
        let summary = StatusSummary(waiting: [
            WaitingEntry(agentID: Self.id(1), reason: bash, since: Self.t0, count: 1),
            WaitingEntry(agentID: Self.id(2), reason: bash, since: Self.t0 + 1, count: 1),
            WaitingEntry(agentID: Self.id(3), reason: bash, since: Self.t0 + 2, count: 1),
        ])
        #expect(StatusSummary.nextWaiting(after: nil, in: summary) == Self.id(1))
        #expect(StatusSummary.nextWaiting(after: Self.id(1), in: summary) == Self.id(2))
        #expect(StatusSummary.nextWaiting(after: Self.id(2), in: summary) == Self.id(3))
        #expect(StatusSummary.nextWaiting(after: Self.id(3), in: summary) == Self.id(1))
        // The current agent stopped waiting: start again from the oldest.
        #expect(StatusSummary.nextWaiting(after: Self.id(7), in: summary) == Self.id(1))
        #expect(StatusSummary.nextWaiting(after: Self.id(1), in: StatusSummary()) == nil)
        let single = StatusSummary(waiting: [summary.waiting[0]])
        #expect(StatusSummary.nextWaiting(after: Self.id(1), in: single) == Self.id(1))
    }

    @Test func emptySummary() {
        let summary = StatusSummary.compute([:])
        #expect(summary == StatusSummary())
        #expect(summary.visibleKinds.isEmpty)
        #expect(summary.total == 0)
    }

    @Test func labelsAgreeInNumber() {
        let singular: [AgentStateKind: String] = [
            .waitingInput: "1 attend", .error: "1 en erreur", .done: "1 tour fini",
            .waitingBackground: "1 attend une tâche de fond", .quotaPaused: "1 en pause", .working: "1 travaille",
            .thinking: "1 réfléchit", .launching: "1 démarre", .idle: "1 au repos", .offline: "1 hors ligne",
        ]
        let plural: [AgentStateKind: String] = [
            .waitingInput: "2 attendent", .error: "2 en erreur", .done: "2 tours finis",
            .waitingBackground: "2 attendent une tâche de fond", .quotaPaused: "2 en pause", .working: "2 travaillent",
            .thinking: "2 réfléchissent", .launching: "2 démarrent", .idle: "2 au repos", .offline: "2 hors ligne",
        ]
        for kind in AgentStateKind.allCases {
            #expect(StatusSummary.label(for: kind, count: 1) == singular[kind])
            #expect(StatusSummary.label(for: kind, count: 2) == plural[kind])
        }
        #expect(Set(StatusSummary.displayOrder) == Set(AgentStateKind.allCases))
        #expect(StatusSummary.displayOrder.count == AgentStateKind.allCases.count)
    }

    @Test func summaryFollowsTheReducer() {
        var nova = Harness.thinking()
        nova.pre("Bash", "t1", "rm -rf dist")
        nova.permission("Bash", "t1", "rm -rf dist")
        var bip = Harness.thinking()
        bip.stopAndCommit()
        let summary = StatusSummary.compute([Self.id(1): nova.r, Self.id(2): bip.r])
        #expect(summary.counts == [.waitingInput: 1, .done: 1])
        #expect(summary.waiting.map(\.agentID) == [Self.id(1)])
        #expect(summary.waiting.first?.reason == .permission(tool: "Bash", summary: "rm -rf dist"))
    }
}
