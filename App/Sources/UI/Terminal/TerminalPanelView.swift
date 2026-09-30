import PixelCore
import SwiftUI

/// The terminal panel docked under the board (mockup 6(b), 6(f)): the selected agent's terminal, a placeholder when
/// it is offline or shown in its own window.
struct TerminalPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let agentID = model.selectedAgentID, let agent = model.agent(agentID) {
            VStack(spacing: 0) {
                TerminalHeaderView(agent: agent, placement: .panel,
                                   onDetach: { workbench.detach(agent.id, using: openWindow) },
                                   onDock: {},
                                   onHide: { workbench.isTerminalPanelVisible = false })
                Divider()
                content(for: agent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            PanelMessageView(symbol: "terminal",
                             message: "Sélectionne un agent pour afficher son terminal ici.") {
                Button("Masquer le panneau") { workbench.isTerminalPanelVisible = false }
            }
        }
    }

    @ViewBuilder
    private func content(for agent: Agent) -> some View {
        let actions = AgentActions(model: model, agentID: agent.id)
        if workbench.detachedAgents.contains(agent.id) {
            PanelMessageView(symbol: "macwindow",
                             message: "Le terminal de \(agent.name) est ouvert dans sa propre fenêtre.") {
                Button("Afficher la fenêtre") {
                    openWindow(id: WindowID.terminal, value: agent.id)
                }
                Button("Ramener ici") {
                    workbench.terminalWindowClosed(agent.id)
                    dismissWindow(id: WindowID.terminal, value: agent.id)
                }
            }
        } else if actions.isOffline {
            OfflineTerminalPlaceholder(agent: agent, actions: actions)
        } else {
            TerminalSurface(agentID: agent.id, presenter: workbench.presenter, focusToken: workbench.panelFocusToken)
        }
    }
}

/// "Hors ligne" with a "Relancer" button (or the orphan left by a crashed run, proposal 2.5), instead of a dead
/// terminal.
struct OfflineTerminalPlaceholder: View {
    let agent: Agent
    let actions: AgentActions

    @Environment(AppModel.self) private var model

    var body: some View {
        if actions.isOrphan {
            let pid = agent.lastProcess.map { " (pid \($0.pid))" } ?? ""
            PanelMessageView(symbol: "exclamationmark.triangle",
                             message: "\(agent.name) : une session tourne encore hors de l'app\(pid). "
                                 + "Elle ne peut pas être reprise tant que ce processus vit.") {
                Button("Terminer ce processus") { model.terminateOrphan(agent.id) }
            }
        } else {
            let reason = model.display(for: agent.id)?.detail ?? "hors ligne"
            PanelMessageView(symbol: "power", message: "\(agent.name) est hors ligne (\(reason)).") {
                Button {
                    model.relaunch(agent.id)
                } label: {
                    Label("Relancer", systemImage: "arrow.clockwise")
                }
                .disabled(!actions.canRelaunch)
            }
        }
    }
}

/// A centered message with actions, filling the terminal area.
struct PanelMessageView<Actions: View>: View {
    let symbol: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                actions()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
