import PixelCore
import SwiftUI

/// The post-its board full screen (mockup 6(c), ⌘B from the side panel): in place of the open space or the list of
/// agents, beside the projects sidebar. The filters on top, then the four columns side by side ("À FAIRE", "EN
/// COURS", "À VALIDER", "FAIT", each scrolling on its own, "Fait" unfolded: there is room), the same sections as
/// the side panel (`BoardColumnView`: drops, menus, keys). ⌘N shows the title field at the top of "À faire".
struct BoardFullScreenView: View {
    /// Points a column keeps at least.
    static let minimumColumnWidth: CGFloat = 200

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    @State private var isQuickAdding = false
    @State private var quickAddFocusToken: UUID?
    @FocusState private var focusedCard: TaskCardID?
    /// The card just created with ⌘N, highlighted for a moment.
    @State private var highlightedCard: TaskCardID?
    @State private var highlightTask: Task<Void, Never>?

    var body: some View {
        let columns = model.filteredBoard
        let isFiltered = !model.boardFilter.isEmpty
        VStack(spacing: 0) {
            header
            BoardFilterBar()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ForEach(Column.allCases, id: \.self) { column in
                    columnView(column, cards: columns[column] ?? [], isFiltered: isFiltered)
                        .frame(minWidth: Self.minimumColumnWidth, maxWidth: .infinity, maxHeight: .infinity)
                    if column != Column.allCases.last {
                        Divider()
                    }
                }
            }
            .environment(\.highlightedCard, highlightedCard)
            Divider()
            Text("Clic droit › « Donner à » pour assigner un post-it · Coller une liste = un post-it par ligne · "
                 + "⌘N nouveau · Entrée valide le titre · Échap annule")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
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
        .accessibilityLabel("Tableau des post-its, plein écran")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("TABLEAU DE LIÈGE")
                .font(.headline)
            Text("\(model.board.cards.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(model.board.cards.count) post-its en tout")
            Text("⌘B")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Menu {
                Button(AppCommand.pasteCards.title) { workbench.commands.perform(.pasteCards) }
                Button(AppCommand.manageTemplates.title) { workbench.commands.perform(.manageTemplates) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Autres actions du tableau")
            .accessibilityLabel("Autres actions du tableau")
            Button {
                workbench.boardMode = .side
            } label: {
                Label("Panneau latéral", systemImage: "sidebar.right")
            }
            .controlSize(.small)
            .help("Remettre le tableau en panneau, à droite de l'open space ou de la liste")
            Button {
                workbench.boardMode = .hidden
            } label: {
                Label("Masquer", systemImage: "xmark")
            }
            .controlSize(.small)
            .help("Masquer le tableau (⌘B le fait revenir)")
            .accessibilityLabel("Masquer le tableau")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// One column, scrolling on its own; the ⌘N title field at the top of "À faire".
    private func columnView(_ column: Column, cards: [TaskCard], isFiltered: Bool) -> some View {
        let total = model.board.cards.lazy.filter { $0.column == column }.count
        return ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if column == .todo {
                        BoardColumnView(column: column, cards: cards, total: total, isFiltered: isFiltered,
                                        focus: $focusedCard, moveFocus: moveFocus) {
                            if isQuickAdding {
                                QuickAddField(isPresented: $isQuickAdding, focusToken: quickAddFocusToken,
                                              created: { reveal($0, proxy: proxy) },
                                              resumedTyping: { scrollToTop(proxy) })
                            }
                        }
                    } else {
                        BoardColumnView(column: column, cards: cards, total: total, isFiltered: isFiltered,
                                        focus: $focusedCard, moveFocus: moveFocus)
                    }
                }
                .id(column)
                .padding(8)
            }
            .onChange(of: focusedCard) { _, cardID in
                guard let cardID, cards.contains(where: { $0.id == cardID }) else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(cardID) }
            }
            .onChange(of: quickAddFocusToken) { _, _ in
                guard column == .todo else { return }
                scrollToTop(proxy)
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(Column.todo, anchor: .top) }
    }

    /// ⌘N created this card at the end of "À faire": the column scrolls to it and highlights it for a moment.
    private func reveal(_ cardID: TaskCardID, proxy: ScrollViewProxy) {
        // On the next turn: the new card is laid out by then.
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(cardID) }
        }
        highlightTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { highlightedCard = cardID }
        highlightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { highlightedCard = nil }
        }
    }

    /// ↑ / ↓ on a focused card: the previous or next card of its column.
    private func moveFocus(from cardID: TaskCardID, by offset: Int) {
        let columns = model.filteredBoard
        guard let column = Column.allCases.first(where: { (columns[$0] ?? []).contains { $0.id == cardID } }) else {
            return
        }
        let shown = (columns[column] ?? []).map(\.id)
        guard let index = shown.firstIndex(of: cardID) else { return }
        let next = index + offset
        guard shown.indices.contains(next) else { return }
        focusedCard = shown[next]
    }
}

/// The `board` step of the snapshot harness (décision 14): the board beside the scene, full screen or hidden.
@MainActor
enum BoardSnapshotHook {
    static let owner = "tâche 12"

    static func register(workbench: WorkbenchState) {
        let hooks = SnapshotHooks.shared
        guard hooks.isEnabled else { return }
        hooks.register(.board, owner: owner) { [weak workbench] step in
            guard case .board(let mode) = step, let workbench, let boardMode = BoardMode(rawValue: mode.rawValue) else {
                return false
            }
            workbench.boardMode = boardMode
            return true
        }
    }
}
