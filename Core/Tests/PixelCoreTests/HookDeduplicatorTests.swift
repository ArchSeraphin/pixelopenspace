import Foundation
import Testing
@testable import PixelCore

@Suite struct HookDeduplicatorTests {
    /// Reference wrapper: `#expect` cannot call a mutating method on a local struct.
    private final class Probe {
        var dedup: HookDeduplicator
        init(_ dedup: HookDeduplicator = HookDeduplicator()) { self.dedup = dedup }

        func seen(_ event: HookEvent, at ts: UInt64) -> Bool {
            dedup.isDuplicate(HookEnvelope(version: 1, agentID: nil, token: "t", claudePID: 1, timestampNs: ts, event: event))
        }

        var tracked: Int { dedup.trackedCount }
    }

    private static let ms: UInt64 = 1_000_000

    private func preToolUse(_ id: String = "toolu_1", session: String = "s", prompt: String? = "p") -> HookEvent {
        HookEvent(name: .preToolUse, sessionID: session, promptID: prompt,
                  payload: .preToolUse(tool: "Bash", toolUseID: id, summary: "ls"))
    }

    @Test func sameEventWithinTheWindowIsADuplicate() {
        let probe = Probe()
        let ms = Self.ms
        #expect(!probe.seen(preToolUse(), at: 1_000 * ms))
        #expect(probe.seen(preToolUse(), at: 1_020 * ms))
        // Arrival order is not timestamp order.
        #expect(probe.seen(preToolUse(), at: 960 * ms))
        #expect(probe.seen(preToolUse(), at: 1_050 * ms))
    }

    @Test func sameEventOutsideTheWindowIsNew() {
        let probe = Probe()
        let ms = Self.ms
        #expect(!probe.seen(preToolUse(), at: 1_000 * ms))
        #expect(!probe.seen(preToolUse(), at: 1_051 * ms))
        #expect(!probe.seen(preToolUse(), at: 949 * ms))
    }

    @Test func permissionRequestIsNotADuplicateOfItsPreToolUse() {
        let probe = Probe()
        let ms = Self.ms
        let request = HookEvent(name: .permissionRequest, sessionID: "s", promptID: "p",
                                payload: .permissionRequest(tool: "Bash", toolUseID: "toolu_1", summary: "ls"))
        #expect(!probe.seen(preToolUse(), at: 1_000 * ms))
        #expect(!probe.seen(request, at: 1_001 * ms))
        #expect(probe.seen(request, at: 1_002 * ms))
    }

    @Test func keyFieldsSeparateEvents() {
        let probe = Probe()
        let ms = Self.ms
        #expect(!probe.seen(preToolUse(), at: 1_000 * ms))
        #expect(!probe.seen(preToolUse("toolu_2"), at: 1_000 * ms))
        #expect(!probe.seen(preToolUse(session: "other"), at: 1_000 * ms))
        #expect(!probe.seen(preToolUse(prompt: "p2"), at: 1_000 * ms))
        #expect(!probe.seen(preToolUse(prompt: nil), at: 1_000 * ms))
    }

    @Test func lookAlikeEventsAreKept() {
        let probe = Probe()
        let ms = Self.ms
        // Two subagents started in the same instant: same key, different agent.
        let first = HookEvent(name: .subagentStart, sessionID: "s", promptID: "p", subagentID: "a1",
                              payload: .subagent(started: true, type: "Explore"))
        var second = first
        second.subagentID = "a2"
        #expect(!probe.seen(first, at: 1_000 * ms))
        #expect(!probe.seen(second, at: 1_001 * ms))
        #expect(probe.seen(second, at: 1_002 * ms))

        let permission = HookEvent(name: .notification, sessionID: "s",
                                   payload: .notification(type: "permission_prompt", message: "m"))
        let idle = HookEvent(name: .notification, sessionID: "s", payload: .notification(type: "idle_prompt", message: "m"))
        #expect(!probe.seen(permission, at: 2_000 * ms))
        #expect(!probe.seen(idle, at: 2_000 * ms))
    }

    @Test func eventsWithoutTimestampAreNeverDropped() {
        let probe = Probe()
        #expect(!probe.seen(preToolUse(), at: 0))
        #expect(!probe.seen(preToolUse(), at: 0))
        #expect(probe.tracked == 0)
    }

    @Test func customWindow() {
        let ms = Self.ms
        let probe = Probe(HookDeduplicator(windowNanos: 5 * ms, retainNanos: 10 * ms))
        #expect(!probe.seen(preToolUse(), at: 100 * ms))
        #expect(probe.seen(preToolUse(), at: 105 * ms))
        #expect(!probe.seen(preToolUse(), at: 106 * ms))
    }

    @Test func memoryIsBounded() {
        let probe = Probe()
        let ms = Self.ms
        // 20 distinct events per millisecond for 6 s: far more than the bound within the retention period (5 s),
        // and long enough for retention pruning to run too.
        var ts: UInt64 = 1_000 * ms
        var duplicates = 0
        var peak = 0
        for i in 0..<120_000 {
            ts += ms / 20
            if probe.seen(preToolUse("toolu_\(i)"), at: ts) { duplicates += 1 }
            peak = max(peak, probe.tracked)
        }
        #expect(duplicates == 0)
        #expect(peak <= HookDeduplicator.maxEntries)
        #expect(probe.tracked > 0)
        // The most recent event is still remembered.
        #expect(probe.seen(preToolUse("toolu_119999"), at: ts))
    }

    @Test func oldEntriesAreForgotten() {
        let ms = Self.ms
        let probe = Probe(HookDeduplicator(windowNanos: 50 * ms, retainNanos: 1_000 * ms))
        for i in 0..<100 {
            _ = probe.seen(preToolUse("toolu_\(i)"), at: (1_000 + UInt64(i)) * ms)
        }
        #expect(probe.tracked == 100)
        _ = probe.seen(preToolUse("late"), at: 10_000 * ms)
        #expect(probe.tracked == 1)
    }
}
