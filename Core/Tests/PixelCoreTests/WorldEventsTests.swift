import Foundation
import Testing
@testable import PixelCore

/// `WorldEvents.between`: what the scene animates when its input changes (task 11).
@Suite struct WorldEventsTests {
    static let now = Date(timeIntervalSince1970: 1_790_845_200)

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static let api = ProjectID(uuid(0xA1))
    static let site = ProjectID(uuid(0xA2))

    static func agentID(_ n: Int) -> AgentID { AgentID(uuid(0xB00 + n)) }

    static let working = Showcase.demoRuntime(.working(.bash), now: now)
    static let done = Showcase.demoRuntime(.done, now: now)
    static let offline = AgentRuntime(phase: .offline(.closedByUser), phaseSince: now)
    static let launching = AgentRuntime(phase: .launching, phaseSince: now)

    /// The project API with `agents` agents at desks 0, 1, …
    static func workspace(agents: Int, projects: [ProjectID] = [api]) -> Workspace {
        var w = Workspace()
        for (k, id) in projects.enumerated() { w.addProject(path: "/p/\(k)", id: id, now: now) }
        for n in 0..<agents { w.addAgent(to: api, name: "A\(n)", id: agentID(n), now: now) }
        return w
    }

    static func scene(_ w: Workspace, _ runtimes: [AgentID: AgentRuntime] = [:],
                      extras: [AgentID: AgentExtras] = [:]) -> SceneInput {
        SceneInput.make(workspace: w, runtimes: runtimes, extras: extras, now: now)
    }

    @Test func launchGivesNoEvent() {
        let w = Self.workspace(agents: 3)
        let scene = Self.scene(w, [Self.agentID(0): Self.working, Self.agentID(1): Self.done])
        #expect(WorldEvents.between(nil, scene) == [])
        // Nothing changed: nothing animates.
        #expect(WorldEvents.between(scene, scene) == [])
        // Hover, selection and hidden agents are not world events.
        var hovered = scene
        hovered.hovered = .agent(Self.agentID(0))
        hovered.selectedAgent = Self.agentID(1)
        hovered.hiddenAgents = [Self.agentID(0)]
        #expect(WorldEvents.between(scene, hovered) == [])
    }

    @Test func islandAppeared() {
        let before = Self.workspace(agents: 1)
        var after = before
        after.addProject(path: "/p/site", id: Self.site, now: Self.now)
        #expect(WorldEvents.between(Self.scene(before), Self.scene(after)) == [.islandAppeared(Self.site, part: 0)])

        // The eighth agent fills the island: its annex appears (its desks fall with it, no separate event).
        let seven = Self.workspace(agents: 7)
        var eight = seven
        eight.addAgent(to: Self.api, name: "A7", id: Self.agentID(7), now: Self.now)
        #expect(WorldEvents.between(Self.scene(seven), Self.scene(eight)) == [.islandAppeared(Self.api, part: 1)])
    }

    @Test func desksAppeared() {
        // One agent: one post on the rug (desks 0 and 1); the second agent grows it by a post (desks 2 and 3).
        let one = Self.workspace(agents: 1)
        var two = one
        two.addAgent(to: Self.api, name: "A1", id: Self.agentID(1), now: Self.now)
        #expect(WorldEvents.between(Self.scene(one), Self.scene(two))
                == [.desksAppeared(Self.api, part: 0, deskIndices: [2, 3])])
        // The rug shrinks when the agent leaves: nothing falls.
        #expect(WorldEvents.between(Self.scene(two), Self.scene(one)) == [])
    }

    @Test func agentArrived() {
        let w = Self.workspace(agents: 2)
        // Offline → live: the avatar comes out of the elevator.
        let before = Self.scene(w, [Self.agentID(0): Self.offline])
        let after = Self.scene(w, [Self.agentID(0): Self.launching])
        #expect(WorldEvents.between(before, after) == [.agentArrived(Self.agentID(0))])
        // Absent → live: a new agent launched at once.
        var three = w
        three.addAgent(to: Self.api, name: "A2", id: Self.agentID(2), now: Self.now)
        let arrived = WorldEvents.between(Self.scene(w), Self.scene(three, [Self.agentID(2): Self.launching]))
        #expect(arrived == [.agentArrived(Self.agentID(2))])
        // Absent → offline: the jacket is on the chair, nobody walks in.
        #expect(WorldEvents.between(Self.scene(w), Self.scene(three)) == [])
        // Live → live: no arrival.
        #expect(WorldEvents.between(after, Self.scene(w, [Self.agentID(0): Self.working])) == [])
    }

    @Test func agentLeft() {
        let w = Self.workspace(agents: 2)
        let live = Self.scene(w, [Self.agentID(0): Self.working, Self.agentID(1): Self.done])
        // Live → offline.
        let closed = Self.scene(w, [Self.agentID(0): Self.offline, Self.agentID(1): Self.done])
        #expect(WorldEvents.between(live, closed) == [.agentLeft(Self.agentID(0))])
        // Live → removed.
        var removed = w
        removed.removeAgent(Self.agentID(1))
        #expect(WorldEvents.between(live, Self.scene(removed, [Self.agentID(0): Self.working]))
                == [.agentLeft(Self.agentID(1))])
        // Offline → removed: nobody was there.
        #expect(WorldEvents.between(Self.scene(w), Self.scene(removed)) == [])
    }

    @Test func turnCelebrated() {
        let w = Self.workspace(agents: 1)
        let working = Self.scene(w, [Self.agentID(0): Self.working])
        let done = Self.scene(w, [Self.agentID(0): Self.done])
        #expect(WorldEvents.between(working, done) == [.turnCelebrated(Self.agentID(0))])
        // Once: done → done celebrates nothing.
        #expect(WorldEvents.between(done, done) == [])
        // An agent that appears already done arrives, it does not celebrate.
        let empty = Self.workspace(agents: 0)
        #expect(WorldEvents.between(Self.scene(empty), done) == [.agentArrived(Self.agentID(0))])
    }

    @Test func cardReceived() {
        let w = Self.workspace(agents: 2)
        let runtimes = [Self.agentID(0): Self.working, Self.agentID(1): Self.working]
        let none = Self.scene(w, runtimes)
        // Its queue grows.
        let queued = Self.scene(w, runtimes, extras: [Self.agentID(0): AgentExtras(queued: 1)])
        #expect(WorldEvents.between(none, queued) == [.cardReceived(Self.agentID(0))])
        let more = Self.scene(w, runtimes, extras: [Self.agentID(0): AgentExtras(queued: 2)])
        #expect(WorldEvents.between(queued, more) == [.cardReceived(Self.agentID(0))])
        // A card on its screen where there was none.
        let onScreen = Self.scene(w, runtimes, extras: [Self.agentID(1): AgentExtras(cardOnScreenHue: 3)])
        #expect(WorldEvents.between(none, onScreen) == [.cardReceived(Self.agentID(1))])
        // The next card of its own queue goes on the screen: the queue shrinks, nothing is received.
        let next = Self.scene(w, runtimes, extras: [Self.agentID(0): AgentExtras(queued: 1, cardOnScreenHue: 4)])
        let after = Self.scene(w, runtimes, extras: [Self.agentID(0): AgentExtras(queued: 0, cardOnScreenHue: 2)])
        #expect(WorldEvents.between(next, after) == [])
        // Losing a card is not an event either.
        #expect(WorldEvents.between(queued, none) == [])
    }

    @Test func sorted() {
        // Many things at once: a new project, a grown rug, arrivals, departures, a finished turn, a received card.
        var before = Self.workspace(agents: 3)
        before.addAgent(to: Self.api, name: "Gone", id: Self.agentID(9), now: Self.now)
        let old = Self.scene(before, [Self.agentID(0): Self.offline, Self.agentID(1): Self.working,
                                      Self.agentID(2): Self.working, Self.agentID(9): Self.working])
        var after = before
        after.removeAgent(Self.agentID(9))
        after.addProject(path: "/p/site", id: Self.site, now: Self.now)
        after.addAgent(to: Self.api, name: "A4", id: Self.agentID(4), now: Self.now)
        after.addAgent(to: Self.api, name: "A5", id: Self.agentID(5), now: Self.now)
        after.addAgent(to: Self.api, name: "A6", id: Self.agentID(6), now: Self.now)
        let new = Self.scene(after, [Self.agentID(0): Self.launching, Self.agentID(1): Self.done,
                                     Self.agentID(2): Self.working, Self.agentID(4): Self.launching],
                             extras: [Self.agentID(2): AgentExtras(queued: 1)])
        let events = WorldEvents.between(old, new)
        #expect(events == events.sorted())
        #expect(events == [
            .islandAppeared(Self.site, part: 0),
            .desksAppeared(Self.api, part: 0, deskIndices: [6, 7]),
            .agentArrived(Self.agentID(0)),
            .agentArrived(Self.agentID(4)),
            .agentLeft(Self.agentID(9)),
            .turnCelebrated(Self.agentID(1)),
            .cardReceived(Self.agentID(2)),
        ])
        // The order is total: by kind, then identifier, part and desks.
        #expect(WorldEvent.islandAppeared(Self.api, part: 1) < .islandAppeared(Self.site, part: 0))
        #expect(WorldEvent.islandAppeared(Self.api, part: 0) < .islandAppeared(Self.api, part: 1))
        #expect(WorldEvent.desksAppeared(Self.api, part: 0, deskIndices: [2]) < .desksAppeared(Self.api, part: 0, deskIndices: [2, 3]))
        #expect(!(WorldEvent.agentLeft(Self.agentID(1)) < .agentLeft(Self.agentID(1))))
        #expect(WorldEvent.cardReceived(Self.agentID(0)) > .agentArrived(Self.agentID(9)))
    }
}
