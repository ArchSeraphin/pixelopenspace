import Foundation
import PixelCore

/// Runs `AppCommand`s against the model (proposal 3.16). Menus, the ⌘K palette and buttons all go through
/// `perform(_:)`; commands that need a sheet or a window become a `UIRequest` for the UI. Agent commands act on the
/// selected agent.
@MainActor
final class CommandCenter {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func perform(_ command: AppCommand) {
        guard isEnabled(command) else { return }
        switch command {
        case .newCard:
            model.post(.newCard)
        case .pasteCards:
            model.post(.pasteCards)
        case .manageTemplates:
            model.post(.manageTemplates)
        case .newProject:
            model.post(.newProject)
        case .newAgent:
            model.post(.newAgent(model.selectedProjectID ?? model.projects.first?.id))
        case .openTerminal:
            if let agentID = model.selectedAgentID { model.post(.openTerminal(agentID)) }
        case .interrupt:
            if let agentID = model.selectedAgentID { model.interrupt(agentID) }
        case .relaunchSession:
            if let agentID = model.selectedAgentID { model.relaunch(agentID) }
        case .closeSession:
            if let agentID = model.selectedAgentID { model.closeSession(agentID) }
        case .removeAgent:
            if let agentID = model.selectedAgentID { model.removeAgent(agentID) }
        case .nextWaitingAgent:
            model.nextWaitingAgent()
        case .previousWaitingAgent:
            model.previousWaitingAgent()
        case .nextAgent:
            model.selectAdjacentAgent(offset: 1)
        case .previousAgent:
            model.selectAdjacentAgent(offset: -1)
        case .toggleBoard:
            model.post(.toggleBoard)
        case .toggleTerminalPanel:
            model.post(.toggleTerminalPanel)
        case .toggleListView:
            model.post(.toggleListView)
        case .zoomIn:
            model.post(.zoomIn)
        case .zoomOut:
            model.post(.zoomOut)
        case .fitAll:
            model.post(.fitAll)
        case .redetectClaude:
            model.redetectClaude()
        case .showSettings:
            model.post(.showSettings)
        }
    }

    /// Whether the command applies now (menus grey it out otherwise). Reads observed state: SwiftUI menus update.
    func isEnabled(_ command: AppCommand) -> Bool {
        let runtime = model.selectedAgentID.flatMap { model.runtime(for: $0) }
        let running = runtime?.pid != nil
        switch command {
        case .newCard, .pasteCards, .manageTemplates, .toggleBoard, .newProject, .toggleTerminalPanel, .showSettings:
            return true
        // In scene mode only for the zoom commands: `WorkbenchState.isAvailable` (the view mode is UI state).
        case .toggleListView, .zoomIn, .zoomOut, .fitAll:
            return true
        case .newAgent:
            return !model.projects.isEmpty
        case .openTerminal:
            return model.selectedAgentID.map { model.sessions.host(for: $0) != nil } ?? false
        case .interrupt:
            guard let runtime, running, runtime.pendingWaits.isEmpty, runtime.interruptRequestedAt == nil else {
                return false
            }
            switch runtime.phase {
            case .thinking, .working: return true
            default: return false
            }
        case .relaunchSession:
            return runtime != nil && !running
        case .closeSession:
            return running
        case .removeAgent:
            return runtime != nil && !running
        case .nextWaitingAgent, .previousWaitingAgent:
            return model.waitingCount > 0
        case .nextAgent, .previousAgent:
            return !model.agentsInOrder.isEmpty
        case .redetectClaude:
            return model.claude.phase != .detecting
        }
    }

    /// ⌘1…⌘9: selects the n-th project of the sidebar.
    func selectProject(number: Int) {
        model.selectProject(number: number)
    }
}
