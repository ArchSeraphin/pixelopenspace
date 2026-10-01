import Foundation

/// Something the scene animates once, found by comparing two successive `SceneInput`s (3.9, 7.4.4; task 11 plays
/// them). Ordered by case (as declared), then by identifier, part and desks.
public enum WorldEvent: Hashable, Comparable, Sendable {
    /// A new island or annex: its furniture falls with a puff of dust.
    case islandAppeared(ProjectID, part: Int)
    /// The rug of an island already there grew: its new desks fall (indices sorted).
    case desksAppeared(ProjectID, part: Int, deskIndices: [Int])
    /// The avatar appears (offline or absent → live): it comes out of the elevator and walks to its seat.
    case agentArrived(AgentID)
    /// The avatar disappears (live → offline or removed): it walks to the elevator.
    case agentLeft(AgentID)
    /// Its kind becomes `.done`: `celebrate` once.
    case turnCelebrated(AgentID)
    /// Its queue or its card on screen grew: `grab`.
    case cardReceived(AgentID)

    public static func < (lhs: WorldEvent, rhs: WorldEvent) -> Bool {
        let (a, b) = (lhs.sortKey, rhs.sortKey)
        if a.rank != b.rank { return a.rank < b.rank }
        if a.id != b.id { return a.id < b.id }
        if a.part != b.part { return a.part < b.part }
        return a.desks.lexicographicallyPrecedes(b.desks)
    }

    private var sortKey: (rank: Int, id: String, part: Int, desks: [Int]) {
        switch self {
        case .islandAppeared(let project, let part): return (0, project.description, part, [])
        case .desksAppeared(let project, let part, let desks): return (1, project.description, part, desks)
        case .agentArrived(let agent): return (2, agent.description, 0, [])
        case .agentLeft(let agent): return (3, agent.description, 0, [])
        case .turnCelebrated(let agent): return (4, agent.description, 0, [])
        case .cardReceived(let agent): return (5, agent.description, 0, [])
        }
    }
}

public enum WorldEvents {
    /// The events between two successive inputs of the scene. nil `old`: [] (launch: nothing animates). Sorted.
    ///
    /// Islands are keyed by (project, part): one that `old` did not have appeared, and its desks come with it; for
    /// one in both, the desk indices `new` lists and `old` did not are desks that appeared. An agent is live when its
    /// presentation has an avatar (`animation` non-nil). It arrives when it is live in `new` and was absent or not
    /// live in `old`, leaves when it was live in `old` and is absent or not live in `new`. A finished turn and a
    /// received card need the agent in both inputs: kind not `.done` → `.done`; more cards queued, or a card on its
    /// screen where there was none (a card that replaces another on the screen while the queue shrinks is not one).
    /// Selection, hover, drop target, hidden agents and the cork wall are not world events.
    public static func between(_ old: SceneInput?, _ new: SceneInput) -> [WorldEvent] {
        guard let old else { return [] }
        var events: [WorldEvent] = []

        var oldIslands: [String: IslandPlacement] = [:]
        for island in old.layout.islands { oldIslands[key(island)] = island }
        for island in new.layout.islands {
            guard let before = oldIslands[key(island)] else {
                events.append(.islandAppeared(island.projectID, part: island.part))
                continue
            }
            let known = Set(before.desks.map(\.index))
            let appeared = island.desks.map(\.index).filter { !known.contains($0) }.sorted()
            if !appeared.isEmpty {
                events.append(.desksAppeared(island.projectID, part: island.part, deskIndices: appeared))
            }
        }

        for (id, agent) in new.agents {
            let before = old.agents[id]
            let wasLive = before.map(isLive) ?? false
            if isLive(agent), !wasLive { events.append(.agentArrived(id)) }
            guard let before else { continue }
            if agent.presentation.kind == .done, before.presentation.kind != .done { events.append(.turnCelebrated(id)) }
            let received = agent.extras.queued > before.extras.queued
                || (agent.extras.cardOnScreenHue != nil && before.extras.cardOnScreenHue == nil)
            if received { events.append(.cardReceived(id)) }
        }
        for (id, agent) in old.agents where isLive(agent) {
            if new.agents[id].map(isLive) != true { events.append(.agentLeft(id)) }
        }
        return events.sorted()
    }

    private static func key(_ island: IslandPlacement) -> String {
        "\(island.projectID)#\(island.part)"
    }

    private static func isLive(_ agent: SceneAgent) -> Bool {
        agent.presentation.animation != nil
    }
}
