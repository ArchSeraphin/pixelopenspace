import PixelCore
import SwiftUI

/// Content of a detached terminal window ("Détacher", mockup 6(f)): the same SwiftTerm view as the panel,
/// re-parented; the process is never restarted.
struct DetachedTerminalWindow: View {
    @Binding var agentID: AgentID?

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var focusToken = UUID()

    var body: some View {
        Group {
            if let agentID, let agent = model.agent(agentID) {
                terminal(for: agent)
                    .navigationTitle("Terminal · \(agent.name) · \(model.project(agent.projectID)?.name ?? "")")
                    .onAppear {
                        workbench.terminalWindowOpened(agentID)
                        workbench.openWindowAction = openWindow
                    }
                    .onDisappear { workbench.terminalWindowClosed(agentID) }
                    .focusedSceneValue(\.commandAvailability,
                                       CommandAvailability(model: model, commands: workbench.commands))
            } else {
                PanelMessageView(symbol: "questionmark.square.dashed", message: "Cet agent n'existe plus.") {
                    Button("Fermer") { dismissWindow() }
                }
                .navigationTitle("Terminal")
            }
        }
        .frame(minWidth: 480, minHeight: 280)
    }

    private func terminal(for agent: Agent) -> some View {
        let actions = AgentActions(model: model, agentID: agent.id)
        return VStack(spacing: 0) {
            TerminalHeaderView(agent: agent, placement: .window,
                               onDetach: {},
                               onDock: { dock(agent) },
                               onHide: {})
            Divider()
            if actions.isOffline {
                OfflineTerminalPlaceholder(agent: agent, actions: actions)
            } else {
                TerminalSurface(agentID: agent.id, presenter: workbench.presenter, focusToken: focusToken)
            }
        }
    }

    /// "Ancrer": back to the main window's panel.
    private func dock(_ agent: Agent) {
        workbench.terminalWindowClosed(agent.id)
        workbench.showTerminal(for: agent.id, focus: true)
        if workbench.isMainWindowOpen {
            workbench.bringMainWindowForward()
        } else {
            openWindow(id: WindowID.main)
        }
        dismissWindow(id: WindowID.terminal, value: agent.id)
    }
}
