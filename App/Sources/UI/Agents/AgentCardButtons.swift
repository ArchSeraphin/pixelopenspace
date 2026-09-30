import PixelCore
import SwiftUI

/// Buttons of an agent card (6(d)): Terminal, Interrompre (thinking or working), Relancer (offline or ended in
/// error), Terminer l'ancienne session (orphan), and "…" with the other actions.
struct AgentCardButtons: View {
    let agent: Agent
    let actions: AgentActions

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        HStack(spacing: 6) {
            if actions.canOpenTerminal {
                Button {
                    workbench.showTerminal(for: agent.id, focus: true)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .help("Ouvrir le terminal de \(agent.name) (⌘T)")
            }
            if actions.canInterrupt {
                Button {
                    model.interrupt(agent.id)
                } label: {
                    Label("Interrompre", systemImage: "stop.circle")
                }
                .help("Envoie Échap à Claude Code (⌘.)")
            }
            if actions.canRelaunch {
                Button {
                    workbench.reveal(agent.id)
                    model.relaunch(agent.id)
                } label: {
                    Label("Relancer", systemImage: "arrow.clockwise")
                }
                .help("Relancer la session de \(agent.name) (⇧⌘R)")
            }
            if actions.isOrphan {
                Button {
                    model.terminateOrphan(agent.id)
                } label: {
                    Label("Terminer l'ancienne session", systemImage: "xmark.circle")
                }
                .help("Une session de \(agent.name) tourne encore hors de l'app : l'arrêter pour pouvoir relancer")
            }
            Spacer(minLength: 0)
            Menu {
                AgentMenuItems(agent: agent, actions: actions, model: model, workbench: workbench)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Autres actions")
            .accessibilityLabel("Autres actions pour \(agent.name)")
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

/// Actions of an agent, for its card's "…" menu and its context menu (model and workbench passed explicitly: menu
/// content is rendered outside the view hierarchy).
struct AgentMenuItems: View {
    let agent: Agent
    let actions: AgentActions
    let model: AppModel
    let workbench: WorkbenchState

    var body: some View {
        Button("Ouvrir le terminal") {
            workbench.showTerminal(for: agent.id, focus: true)
        }
        .disabled(!actions.canOpenTerminal)
        Button("Interrompre") {
            model.interrupt(agent.id)
        }
        .disabled(!actions.canInterrupt)
        Button("Relancer la session") {
            model.relaunch(agent.id)
        }
        .disabled(!actions.canRelaunch)
        Divider()
        Button("Renommer…") {
            workbench.present(.renameAgent(agent.id))
        }
        Button("Copier la commande") {
            if let command = model.commandLine(for: agent.id) {
                Clipboard.copy(command)
                model.showToast("Commande copiée (sans le jeton des hooks).")
            }
        }
        .disabled(model.claude.path == nil)
        Divider()
        Button("Fermer la session…") {
            workbench.requestCloseSession(agent.id)
        }
        .disabled(!actions.canClose)
        Button("Retirer l'agent…") {
            workbench.requestRemove(agent.id)
        }
        .disabled(!actions.canRemove)
    }
}
