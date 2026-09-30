import PixelCore
import SwiftUI

/// The agents a card can be given to, by project: the card's own project first, then the other live projects that
/// have agents, in sidebar order (as the "Donner à" menu). Agents of archived projects are never listed.
@MainActor
enum AssignTargets {
    struct ProjectAgents: Identifiable {
        let project: Project
        let isOwn: Bool
        let agents: [Agent]

        var id: ProjectID { project.id }

        /// "API · projet du post-it", "Web".
        var title: String { isOwn ? "\(project.name) · projet du post-it" : project.name }
    }

    static func sections(for card: TaskCard, model: AppModel) -> [ProjectAgents] {
        let projects = model.projects.filter { !model.agents(in: $0.id).isEmpty }
        let ownID = card.projectID.flatMap { id in projects.first { $0.id == id }?.id }
        let ordered = projects.filter { $0.id == ownID } + projects.filter { $0.id != ownID }
        return ordered.map { ProjectAgents(project: $0, isOwn: $0.id == ownID, agents: model.agents(in: $0.id)) }
    }
}

/// "Donner à…" as a list the keyboard drives (⌘D in the post-it editor, the VoiceOver action of a board card): each
/// agent with its state, the card's project first. ↑ ↓ choose, Return gives, Escape closes, a double-click gives.
/// `pick` receives the agent; the caller asks the confirmation of a gift across projects (C3) and applies it.
struct AssignAgentPicker: View {
    let card: TaskCard
    let pick: (AgentID) -> Void
    let cancel: () -> Void

    @Environment(AppModel.self) private var model

    @State private var selection: AgentID?
    /// Set while one key press or click is being handled: the list and the default button never both give.
    @State private var isGiving = false
    @FocusState private var isListFocused: Bool

    var body: some View {
        let sections = AssignTargets.sections(for: card, model: model)
        VStack(alignment: .leading, spacing: 10) {
            Text("Donner \(CardPresentation.quoted(card.title)) à…")
                .font(.headline)
                .lineLimit(2)
            if sections.isEmpty {
                Text("Aucun agent : crée-en un d'abord.")
                    .foregroundStyle(.secondary)
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.agents) { agent in
                                row(agent)
                                    .tag(agent.id)
                                    .selectionDisabled(agent.id == card.assignee)
                            }
                        }
                    }
                }
                .focused($isListFocused)
                .contextMenu(forSelectionType: AgentID.self) { _ in
                    EmptyView()
                } primaryAction: { ids in
                    if let id = ids.first { give(id) }
                }
                .frame(width: 320, height: Self.listHeight(sections))
                .accessibilityLabel("Agents")
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Donner") {
                    if let selection { give(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || selection == card.assignee)
                .help("Donner le post-it à l'agent choisi (Entrée)")
            }
        }
        .padding(14)
        .onAppear {
            selection = sections.lazy.flatMap(\.agents).first { $0.id != card.assignee }?.id
            isListFocused = true
        }
    }

    private func give(_ agentID: AgentID) {
        guard agentID != card.assignee, !isGiving else { return }
        isGiving = true
        pick(agentID)
        Task { @MainActor in isGiving = false }
    }

    private func row(_ agent: Agent) -> some View {
        let isCurrent = agent.id == card.assignee
        let state = isCurrent ? "déjà dans sa file" : model.display(for: agent.id)?.title.lowercased() ?? ""
        return HStack(spacing: 8) {
            Text(agent.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(state)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Room for every row and section header, from 3 rows to about 12.
    private static func listHeight(_ sections: [AssignTargets.ProjectAgents]) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.agents.count }
        return min(max(CGFloat(rows + sections.count) * 26 + 12, 90), 330)
    }
}

/// "Donner à…" from a board card (VoiceOver action): the same list in a sheet. A gift across projects is confirmed on
/// the sheet (C3); a refusal shows as a toast (the reducer's message).
struct AssignCardSheet: View {
    let cardID: TaskCardID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pendingTask: PendingTaskInput?

    var body: some View {
        if let card = model.board.card(cardID) {
            if card.column == .todo {
                AssignAgentPicker(card: card) { agentID in
                    request(.assign(card.id, to: agentID))
                } cancel: {
                    dismiss()
                }
                .padding(6)
                .taskConfirmation($pendingTask) { pending in
                    perform(pending.input)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Ce post-it n'est plus « À faire » : remets-le à faire pour le donner à un agent.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Fermer") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(24)
                .frame(width: 360)
            }
        } else {
            MissingCardView()
        }
    }

    private func request(_ input: TaskInput) {
        if let kind = model.taskConfirmation(for: input) {
            pendingTask = PendingTaskInput(input: input, kind: kind)
        } else {
            perform(input)
        }
    }

    private func perform(_ input: TaskInput) {
        model.applyTask(input)
        dismiss()
    }
}
