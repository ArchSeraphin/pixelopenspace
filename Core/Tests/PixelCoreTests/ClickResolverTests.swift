import Foundation
import Testing
@testable import PixelCore

/// The click rules of 3.9, one test per rule.
@Suite struct ClickResolverTests {
    static let interval = 0.5
    static let api = ProjectID(SceneFixtures.uuid(0xA1))
    static let nova = AgentID(SceneFixtures.uuid(0xB1))
    static let bip = AgentID(SceneFixtures.uuid(0xB2))
    static let nova1 = SceneHitTarget.agent(nova)

    static func resolver() -> ClickResolver { ClickResolver(doubleClickInterval: interval) }

    /// A click on an agent selects it at once and asks to be woken after the double-click interval.
    @Test func clickOnAnAgentSelectsAtOnce() {
        var r = Self.resolver()
        #expect(r.handle(.down(Self.nova1, clickCount: 1, time: 10)) == [.select(Self.nova), .wakeAt(10.5)])
    }

    /// Woken without a second click: the agent's window opens, once.
    @Test func windowOpensWhenNoSecondClickCame() {
        var r = Self.resolver()
        _ = r.handle(.down(Self.nova1, clickCount: 1, time: 10))
        #expect(r.handle(.timer(time: 10.5)) == [.openAgentWindow(Self.nova)])
        #expect(r.handle(.timer(time: 11)) == [])
        // Woken too early (a timer that fires ahead): it asks again, nothing opens yet.
        _ = r.handle(.down(Self.nova1, clickCount: 1, time: 20))
        #expect(r.handle(.timer(time: 20.2)) == [.wakeAt(20.5)])
        #expect(r.handle(.timer(time: 20.6)) == [.openAgentWindow(Self.nova)])
        // Nothing pending: nothing.
        var idle = Self.resolver()
        #expect(idle.handle(.timer(time: 3)) == [])
    }

    /// A second click within the interval opens only the terminal: no window ever flashes.
    @Test func doubleClickOnAnAgentOpensOnlyTheTerminal() {
        var r = Self.resolver()
        _ = r.handle(.down(Self.nova1, clickCount: 1, time: 10))
        #expect(r.handle(.down(Self.nova1, clickCount: 2, time: 10.25)) == [.openTerminal(Self.nova)])
        #expect(r.handle(.timer(time: 10.5)) == [])
        #expect(r.handle(.timer(time: 12)) == [])
    }

    /// A click on a free desk offers a new agent there: never a creation.
    @Test func clickOnAFreeDeskOffersANewAgent() {
        var r = Self.resolver()
        let actions = r.handle(.down(.freeDesk(Self.api, deskIndex: 3), clickCount: 1, time: 1))
        #expect(actions == [.offerNewAgent(Self.api, deskIndex: 3)])
        #expect(r.handle(.timer(time: 2)) == [])
    }

    /// A double-click on a free desk or an agent does nothing else: no second offer, no centring.
    @Test func doubleClickOnADeskOrAnAgentDoesNotCentre() {
        var r = Self.resolver()
        _ = r.handle(.down(.freeDesk(Self.api, deskIndex: 3), clickCount: 1, time: 1))
        #expect(r.handle(.down(.freeDesk(Self.api, deskIndex: 3), clickCount: 2, time: 1.2)) == [])
        _ = r.handle(.down(Self.nova1, clickCount: 1, time: 5))
        let double = r.handle(.down(Self.nova1, clickCount: 2, time: 5.2))
        #expect(!double.contains { if case .centerIsland = $0 { return true } else { return false } })
        #expect(double == [.openTerminal(Self.nova)])
    }

    /// A double-click on the floor or the sign of an island centres that island.
    @Test func doubleClickOnAnIslandCentresIt() {
        for target in [SceneHitTarget.islandFloor(Self.api, part: 1), .islandSign(Self.api, part: 1)] {
            var r = Self.resolver()
            #expect(r.handle(.down(target, clickCount: 1, time: 1)) == [.clearSelection], "\(target)")
            #expect(r.handle(.down(target, clickCount: 2, time: 1.3)) == [.centerIsland(Self.api, part: 1)], "\(target)")
        }
        // The hall's floor is not an island: nothing to centre.
        var r = Self.resolver()
        _ = r.handle(.down(.floor(GridPoint(3, 2)), clickCount: 1, time: 1))
        #expect(r.handle(.down(.floor(GridPoint(3, 2)), clickCount: 2, time: 1.3)) == [])
    }

    /// A click on the empty floor, the cork wall, the elevator, a hall prop or outside the world clears the selection.
    @Test func clickOnNothingClearsTheSelection() {
        let targets: [SceneHitTarget?] = [.floor(GridPoint(4, 4)), .islandFloor(Self.api, part: 0), .corkWall, .elevator,
                                          .hallProp(.coffeeMachine), .hallProp(.plantSmall), nil]
        for target in targets {
            var r = Self.resolver()
            #expect(r.handle(.down(target, clickCount: 1, time: 1)) == [.clearSelection], "\(String(describing: target))")
        }
    }

    /// A right click opens the context menu of what is under it.
    @Test func rightClickOpensTheContextMenu() {
        for target in [Self.nova1, .freeDesk(Self.api, deskIndex: 2), .corkWall, nil] as [SceneHitTarget?] {
            var r = Self.resolver()
            #expect(r.handle(.rightDown(target)) == [.contextMenu(target)])
        }
    }

    /// Any new click cancels a window still waiting: a click elsewhere, on another agent, or a right click.
    @Test func anyNewClickCancelsAPendingWindow() {
        let others: [ClickInput] = [
            .down(.floor(GridPoint(4, 4)), clickCount: 1, time: 10.2),
            .down(.freeDesk(Self.api, deskIndex: 2), clickCount: 1, time: 10.2),
            .rightDown(Self.nova1),
        ]
        for other in others {
            var r = Self.resolver()
            _ = r.handle(.down(Self.nova1, clickCount: 1, time: 10))
            _ = r.handle(other)
            #expect(r.handle(.timer(time: 10.5)) == [], "\(other)")
            #expect(r.handle(.timer(time: 11)) == [], "\(other)")
        }
        // Another agent: its own window, not the first one's.
        var r = Self.resolver()
        _ = r.handle(.down(Self.nova1, clickCount: 1, time: 10))
        #expect(r.handle(.down(.agent(Self.bip), clickCount: 1, time: 10.2)) == [.select(Self.bip), .wakeAt(10.7)])
        #expect(r.handle(.timer(time: 10.5)) == [.wakeAt(10.7)])
        #expect(r.handle(.timer(time: 10.7)) == [.openAgentWindow(Self.bip)])
        // A second click counted by the system on another target is a first click there.
        var s = Self.resolver()
        _ = s.handle(.down(Self.nova1, clickCount: 1, time: 10))
        #expect(s.handle(.down(.agent(Self.bip), clickCount: 2, time: 10.2)) == [.select(Self.bip), .wakeAt(10.7)])
        // A right click between two clicks breaks the double-click.
        var t = Self.resolver()
        _ = t.handle(.down(Self.nova1, clickCount: 1, time: 10))
        _ = t.handle(.rightDown(Self.nova1))
        #expect(t.handle(.down(Self.nova1, clickCount: 2, time: 10.3)) == [.select(Self.nova), .wakeAt(10.8)])
    }
}
