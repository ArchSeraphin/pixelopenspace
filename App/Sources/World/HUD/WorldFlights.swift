import Foundation
import PixelCore

/// The camera flights asked from outside the scene (décision 13): a counter of the status bar, a row of the waiting
/// tray, an edge arrow, VoiceOver. The flight itself is the camera's (`CameraFlight`, instant with Reduce Motion).
@MainActor
enum WorldFlights {
    /// Next agent of `kind` after the selection (waiting: tray order; others: urgency, then sidebar order); selects it
    /// and flies the camera there; nil when none.
    @discardableResult
    static func flyToNext(_ kind: AgentStateKind, model: AppModel, stage: WorldStage) -> AgentID? {
        let ids = visitingOrder(of: kind, model: model)
        guard !ids.isEmpty else { return nil }
        let next: AgentID
        if let current = model.selectedAgentID, let index = ids.firstIndex(of: current) {
            next = ids[(index + 1) % ids.count]
        } else {
            next = ids[0]
        }
        fly(to: next, model: model, stage: stage)
        return next
    }

    /// Selects the agent and flies the camera to its seat.
    static func fly(to agentID: AgentID, model: AppModel, stage: WorldStage) {
        model.select(agent: agentID)
        stage.camera.fly(to: .agent(agentID))
        stage.view?.noteInteraction()
    }

    /// The agents of the live projects in the state `kind` of the status bar (`AgentRuntime.kind`), in the order the
    /// counter visits them: the waiting tray's (oldest wait first) for the waiting agents; for the others, the most
    /// urgent first (`AgentPresenter`), then the sidebar's order.
    static func visitingOrder(of kind: AgentStateKind, model: AppModel) -> [AgentID] {
        if kind == .waitingInput {
            return model.liveStatusSummary.waiting.map(\.agentID)
        }
        let now = model.now
        let ranked = model.agentsInOrder.enumerated().compactMap { index, agent -> (id: AgentID, urgency: Int, index: Int)? in
            guard let runtime = model.runtime(for: agent.id), runtime.kind == kind else { return nil }
            return (agent.id, AgentPresenter.present(runtime, now: now).urgency, index)
        }
        return ranked.sorted { $0.urgency != $1.urgency ? $0.urgency > $1.urgency : $0.index < $1.index }.map(\.id)
    }
}
