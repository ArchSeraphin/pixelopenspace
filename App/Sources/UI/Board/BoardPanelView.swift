import AppKit
import PixelCore
import SwiftUI

/// The board panel, right of the agents (mockup 6(b); the full-screen board of 6(c) comes with step 3): filters,
/// then four stacked sections "À FAIRE", "EN COURS", "À VALIDER", "FAIT" (folded by default). Shown or hidden
/// with ⌘B; its width is set by dragging its left edge. Every change goes through `TaskLifecycle.reduce`.
struct BoardPanelView: View {
    static let minimumWidth: Double = 260

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    @AppStorage("boardDoneExpanded") private var isDoneExpanded = false
    @State private var isQuickAdding = false
    @State private var quickAddFocusToken: UUID?
    @FocusState private var focusedCard: TaskCardID?

    var body: some View {
        let columns = model.filteredBoard
        let isFiltered = !model.boardFilter.isEmpty
        VStack(spacing: 0) {
            header
            BoardFilterBar()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Column.allCases, id: \.self) { column in
                            section(column, cards: columns[column] ?? [], isFiltered: isFiltered)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: focusedCard) { _, cardID in
                    guard let cardID else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(cardID) }
                }
                .onChange(of: quickAddFocusToken) { _, _ in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(Column.todo, anchor: .top) }
                }
            }
            Divider()
            Text("Glisse un post-it sur un agent pour le lui donner · ⌘N nouveau · ⇧⌘V coller une liste")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: workbench.quickAddRequest, initial: true) { _, request in
            guard request != nil else { return }
            workbench.consumeQuickAdd()
            isQuickAdding = true
            quickAddFocusToken = UUID()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tableau des post-its")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("TABLEAU")
                .font(.headline)
            Text("\(model.board.cards.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(model.board.cards.count) post-its en tout")
            Spacer(minLength: 0)
            Menu {
                Button(AppCommand.pasteCards.title) { workbench.commands.perform(.pasteCards) }
                Button(AppCommand.manageTemplates.title) { workbench.commands.perform(.manageTemplates) }
                Divider()
                Button("Masquer le tableau") { workbench.commands.perform(.toggleBoard) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Autres actions du tableau")
            .accessibilityLabel("Autres actions du tableau")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func section(_ column: Column, cards: [TaskCard], isFiltered: Bool) -> some View {
        let total = model.board.cards.lazy.filter { $0.column == column }.count
        switch column {
        case .todo:
            BoardColumnView(column: column, cards: cards, total: total, isFiltered: isFiltered,
                            focus: $focusedCard, moveFocus: moveFocus) {
                if isQuickAdding {
                    QuickAddField(isPresented: $isQuickAdding, focusToken: quickAddFocusToken)
                }
            }
            .id(column)
        case .done:
            BoardColumnView(column: column, cards: cards, total: total, isFiltered: isFiltered,
                            isExpanded: $isDoneExpanded, focus: $focusedCard, moveFocus: moveFocus)
                .id(column)
        case .inProgress, .review:
            BoardColumnView(column: column, cards: cards, total: total, isFiltered: isFiltered,
                            focus: $focusedCard, moveFocus: moveFocus)
                .id(column)
        }
    }

    /// ↑ / ↓ on a focused card: the previous or next card shown (the folded "Fait" section is skipped).
    private func moveFocus(from cardID: TaskCardID, by offset: Int) {
        let columns = model.filteredBoard
        let shown = Column.allCases
            .filter { $0 != .done || isDoneExpanded }
            .flatMap { columns[$0] ?? [] }
            .map(\.id)
        guard let index = shown.firstIndex(of: cardID) else { return }
        let next = index + offset
        guard shown.indices.contains(next) else { return }
        focusedCard = shown[next]
    }
}

/// Left edge of the board panel: drag it to resize the panel (resize cursor on hover).
struct BoardPanelDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    @State private var dragStartWidth: Double?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != isHovering else { return }
                isHovering = inside
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = width }
                        let proposed = start - Double(value.translation.width)
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Séparateur du tableau")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(width + 40, range.upperBound)
                case .decrement: width = max(width - 40, range.lowerBound)
                @unknown default: break
                }
            }
    }
}

extension View {
    /// The confirmation dialog of a board input (C3 assign across projects, C18 done without review, C20 delete a
    /// card in progress). "Confirmer" clears `pending` and passes it to `confirm`; "Annuler" only clears it.
    func taskConfirmation(_ pending: Binding<PendingTaskInput?>,
                          confirm: @escaping (PendingTaskInput) -> Void) -> some View {
        modifier(TaskConfirmationDialog(pending: pending, confirm: confirm))
    }
}

private struct TaskConfirmationDialog: ViewModifier {
    @Binding var pending: PendingTaskInput?
    let confirm: (PendingTaskInput) -> Void

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible,
                                   presenting: pending) { request in
            Button(confirmTitle(request.kind), role: isDestructive(request.kind) ? .destructive : nil) {
                pending = nil
                confirm(request)
            }
            Button("Annuler", role: .cancel) { pending = nil }
        } message: { request in
            Text(message(request.kind))
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var title: String {
        guard let pending else { return "" }
        switch pending.kind {
        case .assignAcrossProjects(let agent, _, _):
            return "Donner \(cardTitle(pending.input)) à \(agentName(agent)) ?"
        case .markDoneWithoutReview(let cardID):
            return "Marquer \(cardTitle(cardID)) comme fait ?"
        case .deleteInProgress(let cardID):
            return "Supprimer \(cardTitle(cardID)) ?"
        }
    }

    private func confirmTitle(_ kind: ConfirmationKind) -> String {
        switch kind {
        case .assignAcrossProjects(let agent, _, _): return "Donner à \(agentName(agent))"
        case .markDoneWithoutReview: return "Marquer fait"
        case .deleteInProgress: return "Supprimer"
        }
    }

    private func isDestructive(_ kind: ConfirmationKind) -> Bool {
        if case .deleteInProgress = kind { return true }
        return false
    }

    private func message(_ kind: ConfirmationKind) -> String {
        switch kind {
        case .assignAcrossProjects(let agent, let from, let to):
            let name = agentName(agent)
            let target = model.project(to)
            let path = target.map { ProjectSectionView.abbreviated($0.path) } ?? "un autre dossier"
            let fromName = from.flatMap { model.project($0)?.name } ?? "actuel"
            let toName = target?.name ?? "de l'agent"
            return "\(name) travaille dans \(path). Le post-it passe du projet \(fromName) au projet \(toName) "
                + "(noté dans son historique)."
        case .markDoneWithoutReview(let cardID):
            let card = model.board.card(cardID)
            if card?.column == .inProgress {
                let name = card?.assignee.map { CardPresentation.agentName($0, model: model) } ?? "L'agent"
                return "\(name) n'a pas fini ce post-it : il passe dans « Fait » sans passer par « À valider ». "
                    + "Son tour n'est pas interrompu."
            }
            return "Aucun agent n'a traité ce post-it : il passe dans « Fait » sans passer par « À valider »."
        case .deleteInProgress(let cardID):
            let name = model.board.card(cardID)?.assignee.map { CardPresentation.agentName($0, model: model) }
                ?? "L'agent"
            return "\(name) travaille peut-être encore dessus : son tour n'est pas interrompu, mais le post-it "
                + "quitte le tableau, avec ses consignes en attente."
        }
    }

    private func agentName(_ agentID: AgentID) -> String {
        CardPresentation.agentName(agentID, model: model)
    }

    private func cardTitle(_ cardID: TaskCardID) -> String {
        model.board.card(cardID).map { CardPresentation.quoted($0.title) } ?? "ce post-it"
    }

    private func cardTitle(_ input: TaskInput) -> String {
        if case .assign(let cardID, _) = input { return cardTitle(cardID) }
        return "ce post-it"
    }
}
