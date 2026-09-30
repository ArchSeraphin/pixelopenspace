import PixelCore
import SwiftUI

/// One agent (mockup 6(b)): name, state symbol and title (never color alone), detail, since, badges, its queue
/// and current post-it, and the actions that apply now (6(d)). Click selects (its terminal shows in the panel);
/// double-click opens the terminal. A post-it dropped on it is given to the agent (`.assign`, confirmed when it
/// comes from another project).
struct AgentCardView: View {
    let agent: Agent
    let project: Project

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    @State private var isDropTargeted = false

    var body: some View {
        let isSelected = model.selectedAgentID == agent.id
        let display = model.display(for: agent.id)
        let actions = AgentActions(model: model, agentID: agent.id)
        let tint = StateStyle.tint(for: display?.kind ?? .offline)
        VStack(alignment: .leading, spacing: 8) {
            AgentCardSummary(agent: agent, display: display)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel(for: agent.id) ?? agent.name)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { model.select(agent: agent.id) }
                .accessibilityAction(named: "Ouvrir le terminal") { openTerminal(actions) }
            AgentQueueLine(agentID: agent.id)
            AgentCardButtons(agent: agent, actions: actions)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(alignment: .leading) {
            // State stripe: a reinforcement only, the symbol and the title carry the state.
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(tint)
                .frame(width: 4)
                .accessibilityHidden(true)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected || isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: isDropTargeted ? 3 : isSelected ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if isDropTargeted {
                Label("Donner à \(agent.name)", systemImage: "note.text")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: CardDragPayload.self) { payloads, _ in
            guard let cardID = payloads.first?.cardID else { return false }
            workbench.requestTask(.assign(cardID, to: agent.id))
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onTapGesture(count: 2) { openTerminal(actions) }
        .onTapGesture { model.select(agent: agent.id) }
        .contextMenu {
            AgentMenuItems(agent: agent, actions: actions, model: model, workbench: workbench)
        }
        .accessibilityElement(children: .contain)
    }

    private func openTerminal(_ actions: AgentActions) {
        if actions.canOpenTerminal {
            workbench.showTerminal(for: agent.id, focus: true)
        } else {
            model.select(agent: agent.id)
        }
    }
}

/// "▣ Refonte du header" (the post-it the agent works on, click to edit it) and "file : 2 post-its" (mockup 6(b)).
private struct AgentQueueLine: View {
    let agentID: AgentID

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let queue = model.queue(of: agentID)
        let cards = queue.filter { if case .card = $0 { return true } else { return false } }.count
        let instructions = queue.count - cards
        let current = model.currentCard(of: agentID)
        VStack(alignment: .leading, spacing: 2) {
            if let current {
                Button {
                    workbench.editCard(current.id)
                } label: {
                    Label(currentText(current), systemImage: "note.text")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .help("Post-it en cours : \(current.title)")
                .accessibilityLabel("Post-it en cours : \(currentText(current))")
                .accessibilityHint("Ouvre l'éditeur du post-it")
            }
            Text(Self.queueText(cards: cards, instructions: instructions))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The title, with the flags that stopped it in words ("Refonte du header (interrompue)").
    private func currentText(_ card: TaskCard) -> String {
        let flags = CardPresentation.flags(of: card).map(CardPresentation.flagText)
        return flags.isEmpty ? card.title : "\(card.title) (\(flags.joined(separator: ", ")))"
    }

    /// "file vide", "file : 1 post-it", "file : 2 post-its · 1 consigne".
    static func queueText(cards: Int, instructions: Int) -> String {
        guard cards > 0 || instructions > 0 else { return "file vide" }
        var parts: [String] = []
        if cards > 0 { parts.append(cards > 1 ? "\(cards) post-its" : "1 post-it") }
        if instructions > 0 { parts.append(instructions > 1 ? "\(instructions) consignes" : "1 consigne") }
        return "file : " + parts.joined(separator: " · ")
    }
}

/// Name, state, detail, duration and badges of a card.
private struct AgentCardSummary: View {
    let agent: Agent
    let display: AgentStatusDisplay?

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let display {
                    Image(systemName: display.symbolName)
                        .font(.title3)
                        .foregroundStyle(StateStyle.tint(for: display.kind))
                }
            }
            if let display {
                Text(display.title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StateStyle.tint(for: display.kind))
                if let detail = display.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text("depuis \(DurationText.short(model.now.timeIntervalSince(display.since)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !display.badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(display.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                }
            }
            launchSettings
        }
    }

    /// "sonnet · default · worktree nova", in red with bypassPermissions.
    private var launchSettings: some View {
        var parts: [String] = [model.effectiveModel(of: agent) ?? "modèle par défaut", agent.permissionMode.rawValue]
        if let worktree = agent.worktree, !worktree.isEmpty { parts.append("worktree \(worktree)") }
        let risky = PermissionModeInfo.isRisky(agent.permissionMode)
        return Text(parts.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(risky ? StateStyle.tint(for: .error) : Color.secondary)
            .lineLimit(1)
    }
}
