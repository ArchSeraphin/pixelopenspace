import PixelCore
import SwiftUI

/// Title bar of a terminal (mockup 6(f)): agent, project, state in words, and the actions that apply now.
struct TerminalHeaderView: View {
    enum Placement {
        /// Docked under the board: [Détacher] [Interrompre ⌘.] [Masquer].
        case panel
        /// Own window: [Ancrer] [Interrompre ⌘.] (the window has its own close button).
        case window
    }

    let agent: Agent
    let placement: Placement
    let onDetach: @MainActor () -> Void
    let onDock: @MainActor () -> Void
    let onHide: @MainActor () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let actions = AgentActions(model: model, agentID: agent.id)
        let display = model.display(for: agent.id)
        let projectName = model.project(agent.projectID)?.name ?? ""
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Terminal · \(agent.name) · \(projectName)")
                .font(.headline)
                .lineLimit(1)
            if let display {
                stateLabel(display)
            }
            Spacer(minLength: 8)
            buttons(actions)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func stateLabel(_ display: AgentStatusDisplay) -> some View {
        let since = DurationText.short(model.now.timeIntervalSince(display.since))
        let detail = display.detail.map { " · \($0)" } ?? ""
        return Label {
            Text("\(display.title)\(detail) · \(since)")
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: display.symbolName)
                .foregroundStyle(StateStyle.tint(for: display.kind))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(for: agent.id) ?? display.title)
    }

    @ViewBuilder
    private func buttons(_ actions: AgentActions) -> some View {
        HStack(spacing: 6) {
            if actions.canRelaunch {
                Button {
                    model.relaunch(agent.id)
                } label: {
                    Label("Relancer", systemImage: "arrow.clockwise")
                }
                .help("Relancer la session (⇧⌘R)")
            }
            Button {
                model.interrupt(agent.id)
            } label: {
                Label("Interrompre ⌘.", systemImage: "stop.circle")
            }
            .disabled(!actions.canInterrupt)
            .help(actions.canInterrupt ? "Envoie Échap à Claude Code (une seule fois)" : actions.interruptUnavailableReason)
            Button {
                copyCommand()
            } label: {
                Label("Copier la commande", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .disabled(model.claude.path == nil)
            .help("Copier la commande équivalente, pour un terminal (sans le jeton des hooks)")
            switch placement {
            case .panel:
                Button(action: onDetach) {
                    Label("Détacher", systemImage: "macwindow")
                }
                .help("Ouvrir ce terminal dans sa propre fenêtre")
                Button(action: onHide) {
                    Label("Masquer", systemImage: "xmark")
                }
                .help("Masquer le panneau du terminal (⌥⌘T)")
            case .window:
                Button(action: onDock) {
                    Label("Ancrer", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .help("Remettre ce terminal dans le panneau de la fenêtre principale")
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private func copyCommand() {
        guard let command = model.commandLine(for: agent.id) else {
            model.showToast("Commande indisponible : Claude Code est introuvable.", style: .warning)
            return
        }
        Clipboard.copy(command)
        model.showToast("Commande copiée (sans le jeton des hooks).")
    }
}
