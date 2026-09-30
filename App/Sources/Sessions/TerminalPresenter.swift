import AppKit
import PixelCore

/// Grants each agent's terminal view to ONE container at a time (proposal 3.1, "Re-parentage").
///
/// SwiftUI may create the container of a new place (detached window, panel) before dismantling the old one. The
/// newcomer then waits with a placeholder ("Terminal ouvert dans une autre fenêtre", with an "Afficher ici" button
/// that claims it), and receives the terminal once the owner detaches. Containers are held weakly: a container
/// released without `detach` simply stops counting.
///
/// Use from an `NSViewRepresentable`:
/// ```swift
/// func makeNSView(context: Context) -> TerminalContainerView {
///     let container = TerminalContainerView()
///     presenter.attach(agentID, to: container)
///     return container
/// }
/// func updateNSView(_ container: TerminalContainerView, context: Context) {
///     if container.agentID != agentID { presenter.attach(agentID, to: container) }
/// }
/// static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
///     container.detachFromPresenter()
/// }
/// ```
@MainActor
final class TerminalPresenter {
    /// The current terminal view of an agent, `nil` when it never ran (set by `SessionManager`).
    var viewProvider: (@MainActor (AgentID) -> AgentTerminalView?)?
    /// A terminal became visible in a container: the user is looking at the agent (T24 `acknowledged`). Called
    /// asynchronously, never during a SwiftUI view update.
    var onTerminalShown: (@MainActor (AgentID) -> Void)?

    private struct WeakContainer {
        weak var value: TerminalContainerView?
    }

    private struct Slot {
        weak var owner: TerminalContainerView?
        /// Containers waiting for the terminal, oldest first.
        var waiting: [WeakContainer] = []

        mutating func prune() {
            waiting.removeAll { $0.value == nil }
        }
    }

    private var slots: [AgentID: Slot] = [:]

    /// Shows `agentID`'s terminal in `container`, or a placeholder while another container owns it.
    func attach(_ agentID: AgentID, to container: TerminalContainerView) {
        if container.agentID == agentID, container.presenter === self {
            // Idempotent (SwiftUI calls `updateNSView` often): only a replaced terminal view is re-installed.
            if slots[agentID]?.owner === container, let view = viewProvider?(agentID), container.terminalView !== view {
                grant(agentID, to: container)
            }
            return
        }
        detach(container)
        container.presenter = self
        container.agentID = agentID
        var slot = slots[agentID] ?? Slot()
        slot.prune()
        if let owner = slot.owner, owner !== container {
            slot.waiting.append(WeakContainer(value: container))
            slots[agentID] = slot
            container.showPlaceholder(viewProvider?(agentID) == nil ? .noSession : .elsewhere)
            return
        }
        slots[agentID] = slot
        grant(agentID, to: container)
    }

    /// The container goes away (`dismantleNSView`) or shows another agent. The terminal passes to the most recent
    /// waiting container, if any. The process is never touched.
    func detach(_ container: TerminalContainerView) {
        guard let agentID = container.agentID else { return }
        container.agentID = nil
        guard var slot = slots[agentID] else {
            container.removeTerminal()
            return
        }
        slot.waiting.removeAll { $0.value == nil || $0.value === container }
        let wasOwner = slot.owner === container || slot.owner == nil
        if slot.owner === container {
            slot.owner = nil
            container.removeTerminal()
        }
        var next: TerminalContainerView?
        if wasOwner, let candidate = slot.waiting.popLast()?.value {
            next = candidate
        }
        if slot.owner == nil, slot.waiting.isEmpty, next == nil {
            slots[agentID] = nil
        } else {
            slots[agentID] = slot
        }
        if let next { grant(agentID, to: next) }
    }

    /// "Afficher ici": takes the terminal from its current owner, which then waits in turn.
    func claim(_ container: TerminalContainerView) {
        guard let agentID = container.agentID else { return }
        var slot = slots[agentID] ?? Slot()
        slot.waiting.removeAll { $0.value == nil || $0.value === container }
        if let owner = slot.owner, owner !== container {
            owner.showPlaceholder(.elsewhere)
            slot.waiting.append(WeakContainer(value: owner))
        }
        slot.owner = nil
        slots[agentID] = slot
        grant(agentID, to: container)
    }

    /// The agent's terminal view was created or replaced (launch, relaunch): the owner shows the new one.
    func refresh(_ agentID: AgentID) {
        guard var slot = slots[agentID] else { return }
        slot.prune()
        slots[agentID] = slot
        if let owner = slot.owner {
            grant(agentID, to: owner)
        } else if let candidate = slots[agentID]?.waiting.popLast()?.value {
            grant(agentID, to: candidate)
        }
    }

    /// The window in which the agent's terminal is currently installed, if any.
    func window(showing agentID: AgentID) -> NSWindow? {
        guard let owner = slots[agentID]?.owner, let window = owner.window, let view = viewProvider?(agentID),
              view.superview === owner else {
            return nil
        }
        return window
    }

    private func grant(_ agentID: AgentID, to container: TerminalContainerView) {
        var slot = slots[agentID] ?? Slot()
        slot.owner = container
        slot.waiting.removeAll { $0.value == nil || $0.value === container }
        slots[agentID] = slot
        if let view = viewProvider?(agentID) {
            container.install(view)
            reportShown(agentID, in: container)
        } else {
            container.showPlaceholder(.noSession)
        }
    }

    /// `onTerminalShown`, after the current pass: `grant` runs from `makeNSView` / `updateNSView`, and the model must
    /// not change during a SwiftUI view update. Dropped if the container lost the terminal meanwhile.
    private func reportShown(_ agentID: AgentID, in container: TerminalContainerView) {
        Task { [weak self, weak container] in
            guard let self, let container, self.slots[agentID]?.owner === container else { return }
            self.onTerminalShown?(agentID)
        }
    }
}
