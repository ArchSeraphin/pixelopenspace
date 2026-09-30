import PixelCore
import SwiftUI

/// Texts and colors of a post-it (mockups 6(b), 6(c), 6(l)). Never the color alone: the priority, the flags and
/// the state are always written out too (tooltip, VoiceOver).
@MainActor
enum CardPresentation {
    /// Flags that stop the card's turn: "Continuer la tâche" applies (C13, C14). Same set as
    /// `TaskBoardValidator.stoppingFlags`.
    static let stoppingFlags: Set<CardFlag> = [.interrupted, .turnFailed, .sessionLost]

    /// Pin: red (high), yellow (normal), green (low).
    static func pinColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: return StateStyle.tint(for: .error)
        case .normal: return Color(red: 0.96, green: 0.77, blue: 0.19)
        case .low: return StateStyle.tint(for: .done)
        }
    }

    static func flagText(_ flag: CardFlag) -> String {
        switch flag {
        case .deliveryFailed: return "échec d'envoi"
        case .interrupted: return "interrompue"
        case .turnFailed: return "tour en échec"
        case .sessionLost: return "session perdue"
        case .backgroundRunning: return "tâche de fond en cours"
        }
    }

    static func flagSymbol(_ flag: CardFlag) -> String {
        switch flag {
        case .deliveryFailed: return "exclamationmark.triangle.fill"
        case .interrupted: return "pause.circle.fill"
        case .turnFailed: return "xmark.octagon.fill"
        case .sessionLost: return "bolt.horizontal.circle.fill"
        case .backgroundRunning: return "hourglass"
        }
    }

    static func flagTint(_ flag: CardFlag) -> Color {
        switch flag {
        case .deliveryFailed, .turnFailed, .sessionLost: return StateStyle.tint(for: .error)
        case .interrupted: return StateStyle.tint(for: .waitingInput)
        case .backgroundRunning: return StateStyle.tint(for: .waitingBackground)
        }
    }

    /// The card's flags in declaration order (a `Set` has none).
    static func flags(of card: TaskCard) -> [CardFlag] {
        CardFlag.allCases.filter(card.flags.contains)
    }

    static func agentName(_ agentID: AgentID, model: AppModel) -> String {
        model.agent(agentID)?.name ?? "agent inconnu"
    }

    /// "non assigné", "Nova · file #2", "Nova · file #1 · ✎ brouillon" (why the head of the queue waits),
    /// "Nova · envoi en cours", "Pixou · en cours · 6 min", "Rio · fini il y a 2 min", "validé 09:12 · Bip". Reads
    /// `model.now` only for the texts that need it.
    static func status(of card: TaskCard, model: AppModel) -> String {
        let agent = card.assignee.map { agentName($0, model: model) }
        switch card.column {
        case .todo:
            guard let agent else { return "non assigné" }
            if card.delivery?.isPending == true { return "\(agent) · envoi en cours" }
            if let position = model.queuePosition(of: card.id) {
                if position == 1, let cause = card.assignee.flatMap(model.deliveryWaitCause(of:)) {
                    return "\(agent) · file #1 · \(cause.label)"
                }
                return "\(agent) · file #\(position)"
            }
            return agent
        case .inProgress:
            let since = card.delivery?.confirmedAt ?? card.updatedAt
            let running = "en cours · \(DurationText.short(model.now.timeIntervalSince(since)))"
            return agent.map { "\($0) · \(running)" } ?? running
        case .review:
            let finished = card.delivery?.turnEndedAt
                .map { "fini il y a \(DurationText.short(model.now.timeIntervalSince($0)))" } ?? "à valider"
            return agent.map { "\($0) · \(finished)" } ?? finished
        case .done:
            let validatedAt = card.history.last { $0.kind == .validated }?.at ?? card.updatedAt
            let done = "validé \(shortDate(validatedAt, now: model.now))"
            return agent.map { "\(done) · \($0)" } ?? done
        }
    }

    static func statusSymbol(of card: TaskCard) -> String {
        switch card.column {
        case .done: return "checkmark.circle"
        default: return card.assignee == nil ? "person.crop.circle.badge.questionmark" : "person.fill"
        }
    }

    /// VoiceOver: "Post-it Pagination /users, priorité haute, projet API, à faire, assigné à Nova, file 2".
    static func accessibilityLabel(for card: TaskCard, model: AppModel) -> String {
        var parts = ["Post-it \(card.title)", "priorité \(card.priority.title)"]
        if let project = card.projectID.flatMap({ model.project($0) }) {
            parts.append("projet \(project.name)")
        } else {
            parts.append("sans projet")
        }
        parts.append(card.column.title.lowercased())
        if let assignee = card.assignee {
            parts.append("assigné à \(agentName(assignee, model: model))")
        } else if card.column != .done {
            parts.append("non assigné")
        }
        if let position = model.queuePosition(of: card.id) {
            parts.append("file \(position)")
        }
        if card.column == .todo, card.delivery?.isPending == true {
            parts.append("envoi en cours")
        }
        parts += flags(of: card).map(flagText)
        if !card.tags.isEmpty {
            parts.append("tags " + card.tags.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    /// One line of the history, French: "donné à Nova", "modifié (titre)".
    static func eventText(_ event: CardEvent, model: AppModel) -> String {
        let agent = event.agentID.map { model.agent($0)?.name ?? "un agent retiré" }
        var text: String
        switch event.kind {
        case .created: text = "créé"
        case .edited: text = "modifié"
        case .assigned: text = agent.map { "donné à \($0)" } ?? "assigné"
        case .unassigned: text = agent.map { "retiré de \($0)" } ?? "désassigné"
        case .reassigned: text = agent.map { "redonné à \($0)" } ?? "réassigné"
        case .reordered: text = "déplacé"
        case .deliveryStarted: text = agent.map { "envoi à \($0)" } ?? "envoi"
        case .deliveryConfirmed: text = agent.map { "reçu par \($0)" } ?? "reçu"
        case .deliveryFailed: text = "échec d'envoi"
        case .turnEnded: text = "tour terminé"
        case .turnReopened: text = "tour repris"
        case .turnFailed: text = "tour en échec"
        case .interrupted: text = "interrompu"
        case .sessionLost: text = "session perdue"
        case .continued: text = "reprise demandée"
        case .putBack: text = "remis à faire"
        case .markedForReview: text = "à valider"
        case .resent: text = "renvoyé"
        case .validated: text = event.from == .review ? "validé" : "marqué fait"
        case .reopened: text = "rouvert"
        case .projectChanged: text = "projet changé"
        }
        if let note = event.note, !note.isEmpty { text += " (\(note))" }
        return text
    }

    /// "09:12" today, "3 oct. 09:12" another day.
    static func shortDate(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// « Titre », cut at 40 characters (dialog titles).
    static func quoted(_ title: String) -> String {
        let limit = 40
        return "« " + (title.count > limit ? String(title.prefix(limit)) + "…" : title) + " »"
    }
}

/// The colored pin of a card; the priority in words is in its tooltip (VoiceOver reads the card's label).
struct PriorityPin: View {
    let priority: Priority
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(CardPresentation.pinColor(priority))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .offset(x: size * 0.2, y: size * 0.2)
            }
            .frame(width: size, height: size)
            .help("Priorité \(priority.title)")
            .accessibilityHidden(true)
    }
}

/// A readable flag: symbol and words, never the color alone.
struct CardFlagLabel: View {
    let flag: CardFlag

    var body: some View {
        Label(CardPresentation.flagText(flag), systemImage: CardPresentation.flagSymbol(flag))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(CardPresentation.flagTint(flag))
            .lineLimit(1)
    }
}

/// "☺ Nova · file #2": who has the card, where it stands.
struct CardStatusLine: View {
    let card: TaskCard

    @Environment(AppModel.self) private var model

    var body: some View {
        Label(CardPresentation.status(of: card, model: model), systemImage: CardPresentation.statusSymbol(of: card))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// One post-it (mockups 6(b), 6(c)): pin, title, two lines of description, project badge, tags, status line and
/// flags; "Valider" and "↺" in "À valider". Click focuses it, double-click or Return opens the editor, ⌘↩
/// validates, ⌥⌘↩ resends with a precision, ⌘⌫ deletes, ↑ ↓ move the focus. It can be dragged to another
/// section or onto an agent card.
struct TaskCardView: View {
    let card: TaskCard
    let focus: FocusState<TaskCardID?>.Binding
    /// ↑ / ↓: the focus moves to the previous (-1) or next (+1) card shown.
    let moveFocus: (TaskCardID, Int) -> Void

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        let isFocused = focus.wrappedValue == card.id
        let project = card.projectID.flatMap { model.project($0) }
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PriorityPin(priority: card.priority)
                    .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] - 1 }
                Text(card.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let project {
                    ProjectBadge(project: project)
                }
            }
            let details = card.details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !card.tags.isEmpty {
                Text(card.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            CardStatusLine(card: card)
            let flags = CardPresentation.flags(of: card)
            if !flags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { CardFlagLabel(flag: $0) }
                }
            }
            if card.column == .review {
                reviewButtons
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).fill(tint(project).opacity(0.14)))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focused(focus, equals: card.id)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onTapGesture(count: 2) { workbench.editCard(card.id) }
        .onTapGesture { focus.wrappedValue = card.id }
        .draggable(CardDragPayload(cardID: card.id)) {
            CardDragPreview(card: card)
        }
        .contextMenu {
            CardMenuItems(card: card, model: model, workbench: workbench)
        }
        .help(card.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CardPresentation.accessibilityLabel(for: card, model: model))
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workbench.editCard(card.id) }
        .accessibilityAction(named: "Modifier") { workbench.editCard(card.id) }
        .modifier(ReviewAccessibilityActions(card: card))
    }

    private var reviewButtons: some View {
        HStack(spacing: 6) {
            Button {
                workbench.requestTask(.validate(card.id))
            } label: {
                Label("Valider", systemImage: "checkmark")
            }
            .help("Valider ce post-it (⌘↩ quand il a le focus)")
            Button {
                workbench.present(.resendCard(card.id))
            } label: {
                Label("Renvoyer", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .help("Renvoyer à l'agent avec une précision (⌥⌘↩)")
            .accessibilityLabel("Renvoyer avec une précision")
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func tint(_ project: Project?) -> Color {
        project.map { ProjectHue.color($0.hueIndex) } ?? Color.clear
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers.intersection([.command, .option, .shift, .control])
        switch press.key {
        case .return:
            if modifiers == [.command, .option] {
                guard card.column == .review else { return .ignored }
                workbench.present(.resendCard(card.id))
            } else if modifiers == .command {
                guard card.column != .done else { return .ignored }
                workbench.requestTask(.validate(card.id))
            } else if modifiers.isEmpty {
                workbench.editCard(card.id)
            } else {
                return .ignored
            }
            return .handled
        case .delete, .deleteForward:
            guard modifiers == .command else { return .ignored }
            workbench.requestTask(.delete(card.id))
            return .handled
        case .upArrow:
            guard modifiers.isEmpty else { return .ignored }
            moveFocus(card.id, -1)
            return .handled
        case .downArrow:
            guard modifiers.isEmpty else { return .ignored }
            moveFocus(card.id, 1)
            return .handled
        default:
            return .ignored
        }
    }
}

/// "Valider" and "Renvoyer" for VoiceOver on a card of "À valider" (its buttons are inside an ignored element).
private struct ReviewAccessibilityActions: ViewModifier {
    let card: TaskCard

    @Environment(WorkbenchState.self) private var workbench

    func body(content: Content) -> some View {
        if card.column == .review {
            content
                .accessibilityAction(named: "Valider") { workbench.requestTask(.validate(card.id)) }
                .accessibilityAction(named: "Renvoyer avec une précision") {
                    workbench.present(.resendCard(card.id))
                }
        } else {
            content
        }
    }
}

/// The project's colored square and short name ("■ API").
struct ProjectBadge: View {
    let project: Project

    var body: some View {
        HStack(spacing: 3) {
            ProjectHueSquare(hueIndex: project.hueIndex, size: 8)
            Text(project.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 80, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help("Projet \(project.name)")
    }
}

/// What follows the pointer during a drag: the pin and the title.
private struct CardDragPreview: View {
    let card: TaskCard

    var body: some View {
        HStack(spacing: 6) {
            PriorityPin(priority: card.priority)
            Text(card.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
    }
}

/// The actions a card's state allows (context menu, mockup 6(c)). Model and workbench passed explicitly: menu
/// content is rendered outside the view hierarchy.
struct CardMenuItems: View {
    let card: TaskCard
    let model: AppModel
    let workbench: WorkbenchState

    var body: some View {
        Button("Modifier…") {
            workbench.editCard(card.id)
        }
        if card.column == .todo {
            Menu("Donner à") {
                AssignMenuContent(card: card, model: model) { agentID in
                    workbench.requestTask(.assign(card.id, to: agentID))
                }
            }
            FirstFreeAgentItem(card: card, model: model, workbench: workbench)
            if card.assignee != nil {
                Button("Retirer de la file") {
                    workbench.requestTask(.unassign(card.id))
                }
            }
        }
        if card.flags.contains(.deliveryFailed) {
            Button("Réessayer l'envoi") {
                workbench.requestTask(.retry(card.id))
            }
        }
        if card.column == .inProgress, !card.flags.isDisjoint(with: CardPresentation.stoppingFlags) {
            Button("Continuer la tâche") {
                workbench.requestTask(.continueTask(card.id, instructionID: InstructionID()))
            }
        }
        if card.column == .inProgress {
            Button("Marquer à valider") {
                workbench.requestTask(.markForReview(card.id))
            }
        }
        if card.column == .inProgress || card.column == .review {
            Button("Remettre à faire") {
                workbench.requestTask(.putBack(card.id))
            }
        }
        switch card.column {
        case .review:
            Button("Valider") {
                workbench.requestTask(.validate(card.id))
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button("Renvoyer avec une précision…") {
                workbench.present(.resendCard(card.id))
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
        case .todo, .inProgress:
            Button("Marquer comme fait…") {
                workbench.requestTask(.validate(card.id))
            }
        case .done:
            Button("Rouvrir") {
                workbench.requestTask(.reopen(card.id))
            }
        }
        Divider()
        Button("Supprimer", role: .destructive) {
            workbench.requestTask(.delete(card.id))
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }
}

/// "Donner au premier agent libre (Nova)" (proposal 3.6: idle or done with an empty queue, idle the longest, else the
/// shortest queue among the running agents of the card's project); with no agent running there, "Lancer un nouvel
/// agent avec ce post-it" (the card is its first prompt).
struct FirstFreeAgentItem: View {
    let card: TaskCard
    let model: AppModel
    let workbench: WorkbenchState

    var body: some View {
        if let target = model.firstFreeAgent(for: card) {
            let name = CardPresentation.agentName(target, model: model)
            if target == card.assignee {
                Button("Premier agent libre : \(name) (déjà dans sa file)") {}
                    .disabled(true)
            } else {
                Button("Donner au premier agent libre (\(name))") {
                    workbench.requestTask(.assign(card.id, to: target))
                }
            }
        } else if model.dispatchProject(for: card) != nil {
            Button("Lancer un nouvel agent avec ce post-it") {
                model.launchNewAgent(with: card.id)
            }
        }
    }
}

/// "Donner à ›": the agents of the card's project, then the other projects' agents ("Autres projets"), each with
/// its state. A card without a live project lists every project.
struct AssignMenuContent: View {
    let card: TaskCard
    let model: AppModel
    let pick: (AgentID) -> Void

    var body: some View {
        let projects = model.projects.filter { !model.agents(in: $0.id).isEmpty }
        let own = card.projectID.flatMap { id in projects.first { $0.id == id } }
        let others = projects.filter { $0.id != own?.id }
        if projects.isEmpty {
            Text("Aucun agent : crée-en un d'abord")
        }
        if let own {
            ForEach(model.agents(in: own.id)) { agent in
                agentButton(agent)
            }
            if !others.isEmpty {
                Menu("Autres projets") {
                    projectSections(others)
                }
            }
        } else {
            projectSections(others)
        }
    }

    private func projectSections(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            Section(project.name) {
                ForEach(model.agents(in: project.id)) { agent in
                    agentButton(agent)
                }
            }
        }
    }

    private func agentButton(_ agent: Agent) -> some View {
        let state = model.display(for: agent.id)?.title.lowercased()
        let isCurrent = card.assignee == agent.id
        let title = isCurrent ? "\(agent.name) (déjà dans sa file)" : [agent.name, state].compactMap { $0 }.joined(separator: " · ")
        return Button(title) {
            pick(agent.id)
        }
        .disabled(isCurrent)
    }
}
