import Foundation

/// What the scene's view feeds the click rules: a press of the left button (with the system's click count), a press
/// of the right button, or the timer the rules asked for (`ClickAction.wakeAt`). Times in seconds, any clock.
public enum ClickInput: Hashable, Sendable {
    case down(SceneHitTarget?, clickCount: Int, time: Double)
    case rightDown(SceneHitTarget?)
    case timer(time: Double)
}

/// What the app does after a click (3.9).
public enum ClickAction: Hashable, Sendable {
    case select(AgentID)
    case clearSelection
    case openAgentWindow(AgentID)
    case openTerminal(AgentID)
    /// The small "Nouvel agent ici ?" popover: never a creation.
    case offerNewAgent(ProjectID, deskIndex: Int)
    case centerIsland(ProjectID, part: Int)
    /// The native context menu (the commands of ⌘K) for what is under the pointer.
    case contextMenu(SceneHitTarget?)
    /// Call `handle(.timer(time:))` at that time.
    case wakeAt(Double)
}

/// The click rules of the scene (3.9), one rule for every view:
/// - a click on an agent selects it at once; its window opens only after `doubleClickInterval` without a second
///   click (`wakeAt`, then `timer`), so a double-click opens **only** its terminal, without a window that flashes;
/// - a click on a free desk offers a new agent there, never creates one;
/// - a double-click on the floor or the sign of an island centres that island; a double-click on a desk or an agent
///   does not centre (on a free desk it does nothing more, on an agent it opens the terminal);
/// - a click on anything else (the hall's floor, the rug, a sign, the cork wall, the elevator, a hall prop, outside
///   the world) clears the selection;
/// - a right click opens the context menu of what is under the pointer;
/// - any new click cancels a window still waiting to open.
///
/// A double-click is a press with a click count of 2 on the same target as the press before it (the system counts
/// the clicks and their timing); a count of 2 on another target is a first click there, and the presses beyond a
/// double-click (count 3 or more) do nothing.
public struct ClickResolver: Hashable, Sendable {
    /// `NSEvent.doubleClickInterval`, seconds.
    public let doubleClickInterval: Double
    /// The agent whose window opens at `deadline` unless another click comes first.
    private var pending: PendingWindow?
    /// The target of the last left press; nil before any, and after a right click (it breaks a double-click).
    private var lastDown: LastDown?

    private struct PendingWindow: Hashable, Sendable {
        var agent: AgentID
        var deadline: Double
    }

    private struct LastDown: Hashable, Sendable {
        var target: SceneHitTarget?
    }

    public init(doubleClickInterval: Double) {
        self.doubleClickInterval = doubleClickInterval
    }

    public mutating func handle(_ input: ClickInput) -> [ClickAction] {
        switch input {
        case .down(let target, let clickCount, let time):
            let previous = lastDown
            lastDown = LastDown(target: target)
            pending = nil
            if clickCount >= 2, let previous, previous.target == target {
                return clickCount == 2 ? Self.doubleClick(on: target) : []
            }
            return click(on: target, time: time)
        case .rightDown(let target):
            pending = nil
            lastDown = nil
            return [.contextMenu(target)]
        case .timer(let time):
            guard let window = pending else { return [] }
            guard time >= window.deadline else { return [.wakeAt(window.deadline)] }
            pending = nil
            return [.openAgentWindow(window.agent)]
        }
    }

    private mutating func click(on target: SceneHitTarget?, time: Double) -> [ClickAction] {
        switch target {
        case .agent(let agent):
            let deadline = time + doubleClickInterval
            pending = PendingWindow(agent: agent, deadline: deadline)
            return [.select(agent), .wakeAt(deadline)]
        case .freeDesk(let project, let deskIndex):
            return [.offerNewAgent(project, deskIndex: deskIndex)]
        case .islandSign, .islandFloor, .corkWall, .elevator, .hallProp, .floor, nil:
            return [.clearSelection]
        }
    }

    private static func doubleClick(on target: SceneHitTarget?) -> [ClickAction] {
        switch target {
        case .agent(let agent):
            return [.openTerminal(agent)]
        case .islandFloor(let project, let part), .islandSign(let project, let part):
            return [.centerIsland(project, part: part)]
        case .freeDesk, .corkWall, .elevator, .hallProp, .floor, nil:
            return []
        }
    }
}
