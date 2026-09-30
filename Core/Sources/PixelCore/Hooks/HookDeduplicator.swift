import Foundation

/// Drops a hook event delivered twice, for instance by the app's `--settings` hooks and a global install
/// (proposal 5.7). Pure: time comes from the envelopes' monotonic `ts_ns`.
///
/// Events are keyed by (`session_id`, event name, `tool_use_id`, `prompt_id`). An event is a duplicate when an
/// identical event with the same key was seen within `windowNanos` of its timestamp, in either direction since
/// arrival order is not timestamp order. Requiring identical content keeps look-alike events apart
/// (two subagents starting in the same instant, two notification types).
public struct HookDeduplicator: Sendable {
    public let windowNanos: UInt64
    public let retainNanos: UInt64

    private struct Key: Hashable, Sendable {
        var sessionID: String
        var event: String
        var toolUseID: String
        var promptID: String
    }

    private struct Seen: Sendable {
        var timestampNs: UInt64
        var event: HookEvent
    }

    private var seen: [Key: [Seen]] = [:]
    private var entryCount = 0
    private var newestNs: UInt64 = 0
    private var lastPruneNs: UInt64 = 0

    /// Hard bound on remembered events, well above what the server's rate limit lets through within `retainNanos`.
    static let maxEntries = 20_000

    /// `retainNanos` (at least `windowNanos`): how long, in `ts_ns` time, an event is remembered.
    public init(windowNanos: UInt64 = 50_000_000, retainNanos: UInt64 = 5_000_000_000) {
        self.windowNanos = windowNanos
        self.retainNanos = max(retainNanos, windowNanos)
    }

    /// Whether `e` repeats an event already seen; if not, remembers it. Envelopes without a timestamp
    /// (`ts_ns` = 0) cannot be compared and are never duplicates.
    public mutating func isDuplicate(_ e: HookEnvelope) -> Bool {
        let timestamp = e.timestampNs
        guard timestamp != 0 else { return false }
        let key = Key(
            sessionID: e.event.sessionID,
            event: e.event.name.rawValue,
            toolUseID: Self.toolUseID(of: e.event.payload) ?? "",
            promptID: e.event.promptID ?? ""
        )
        if let entries = seen[key],
           entries.contains(where: { Self.distance($0.timestampNs, timestamp) <= windowNanos && $0.event == e.event }) {
            return true
        }
        seen[key, default: []].append(Seen(timestampNs: timestamp, event: e.event))
        entryCount += 1
        newestNs = max(newestNs, timestamp)
        if newestNs - lastPruneNs >= retainNanos / 2 || entryCount > Self.maxEntries {
            prune()
        }
        return false
    }

    /// Number of remembered events (tests).
    var trackedCount: Int { entryCount }

    private mutating func prune() {
        lastPruneNs = newestNs
        forget(olderThan: retainNanos)
        // Burst beyond the bound: keep only what can still match.
        if entryCount > Self.maxEntries { forget(olderThan: windowNanos) }
        if entryCount > Self.maxEntries {
            seen.removeAll()
            entryCount = 0
        }
    }

    private mutating func forget(olderThan age: UInt64) {
        let newest = newestNs
        var count = 0
        seen = seen.compactMapValues { entries in
            let kept = entries.filter { newest - $0.timestampNs <= age }
            count += kept.count
            return kept.isEmpty ? nil : kept
        }
        entryCount = count
    }

    private static func distance(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }

    private static func toolUseID(of payload: HookPayload) -> String? {
        switch payload {
        case .preToolUse(_, let id, _), .askUserQuestion(let id, _), .postToolUse(_, let id, _),
             .permissionRequest(_, let id, _), .permissionDenied(_, let id):
            return id
        default:
            return nil
        }
    }
}
