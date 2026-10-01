import Foundation

/// What VoiceOver announces about the agents (7.9): only an agent that starts waiting for the user or falls into an
/// error. Ordered by priority: waits first.
public enum AnnouncementKind: Int, Comparable, CaseIterable, Sendable {
    case waiting = 0, error = 1

    public static func < (lhs: AnnouncementKind, rhs: AnnouncementKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Groups the announcements of `window` seconds into one sentence (7.9), so that with 20 agents VoiceOver is not
/// drowned: "3 agents attendent ta réponse". Pure: the app passes the time, schedules the flush at the time `add`
/// returns, and posts what `flush` gives (`NSAccessibility.post`).
public struct AnnouncementBatcher: Hashable, Sendable {
    /// Seconds a batch stays open after its first announcement.
    public let window: Double
    /// When the open batch is due; nil when no batch is open.
    private var due: Double?
    /// The announcements of the open batch, in arrival order, each (kind, name) once.
    private var entries: [Entry] = []

    private struct Entry: Hashable, Sendable {
        var kind: AnnouncementKind
        var name: String
    }

    public init(window: Double = 2) {
        self.window = window
    }

    /// Adds an announcement to the open batch, or opens one. Returns the time of the next flush when this opens a
    /// batch, nil otherwise. The same agent twice in a batch (same kind, same name) counts once.
    public mutating func add(_ kind: AnnouncementKind, agentName: String, time: Double) -> Double? {
        let entry = Entry(kind: kind, name: agentName)
        if !entries.contains(entry) { entries.append(entry) }
        guard due == nil else { return nil }
        let flushAt = time + window
        due = flushAt
        return flushAt
    }

    /// One French sentence for the batch, waits first: "Nova attend ta réponse", "3 agents attendent ta réponse",
    /// "Nova attend ta réponse ; Zéphyr est en erreur". Nil when the batch is empty or not due yet (`time` before
    /// the time `add` returned); the batch is emptied when it is given.
    public mutating func flush(time: Double) -> String? {
        guard let due, time >= due, !entries.isEmpty else { return nil }
        let parts = AnnouncementKind.allCases.compactMap { kind -> String? in
            let names = entries.filter { $0.kind == kind }.map(\.name)
            return Self.sentence(kind, names: names)
        }
        entries = []
        self.due = nil
        return parts.joined(separator: " ; ")
    }

    /// "Nova attend ta réponse", "2 agents attendent ta réponse", "Zéphyr est en erreur", "2 agents sont en erreur";
    /// nil without a name.
    static func sentence(_ kind: AnnouncementKind, names: [String]) -> String? {
        guard let first = names.first else { return nil }
        let one = names.count == 1
        let subject = one ? first : "\(names.count) agents"
        switch kind {
        case .waiting: return subject + (one ? " attend ta réponse" : " attendent ta réponse")
        case .error: return subject + (one ? " est en erreur" : " sont en erreur")
        }
    }
}
