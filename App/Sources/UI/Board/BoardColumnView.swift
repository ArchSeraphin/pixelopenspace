import PixelCore
import SwiftUI

/// One section of the board panel: "À FAIRE (3)", its cards, and the drops. A card dropped on another one takes
/// its place (right above it); dropped on the rest of the section, it goes at the end. Between sections it is a
/// `.move` (C15, C16, C18, C19; "En cours" is refused, C5), inside a section a reorder. "Fait" folds.
struct BoardColumnView<Leading: View>: View {
    let column: Column
    /// The cards shown (filtered), in order.
    let cards: [TaskCard]
    /// Every card of the column, filter or not.
    let total: Int
    let isFiltered: Bool
    /// Set for a section that folds ("Fait").
    var isExpanded: Binding<Bool>?
    let focus: FocusState<TaskCardID?>.Binding
    let moveFocus: (TaskCardID, Int) -> Void
    /// Shown above the cards (the ⌘N title field in "À faire").
    @ViewBuilder let leading: () -> Leading

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    @State private var isDropTargeted = false

    var body: some View {
        let expanded = isExpanded?.wrappedValue ?? true
        VStack(alignment: .leading, spacing: 6) {
            header(expanded: expanded)
            if expanded {
                leading()
                ForEach(cards) { card in
                    CardDropSlot(card: card, column: column, drop: drop) {
                        TaskCardView(card: card, focus: focus, moveFocus: moveFocus)
                    }
                    .id(card.id)
                }
                if cards.isEmpty {
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear,
                              style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        .contentShape(Rectangle())
        .dropDestination(for: CardDragPayload.self) { payloads, _ in
            drop(payloads, before: nil)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private func header(expanded: Bool) -> some View {
        let label = "\(column.title.uppercased()) (\(countText))"
        return HStack(spacing: 4) {
            if let isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(label)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Replier « \(column.title) »" : "Déplier « \(column.title) »")
                .accessibilityValue(expanded ? "déplié" : "replié")
            } else {
                Text(label)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(column.title), \(spokenCount)")
        .accessibilityAddTraits(.isHeader)
    }

    /// "3", or "2 sur 5" when the filter hides some.
    private var countText: String {
        isFiltered && cards.count != total ? "\(cards.count) sur \(total)" : "\(total)"
    }

    private var spokenCount: String {
        let shown = isFiltered && cards.count != total ? "\(cards.count) affichés sur \(total)" : "\(total)"
        return total > 1 ? "\(shown) post-its" : "\(shown) post-it"
    }

    private var emptyText: String {
        if isFiltered, total > 0 { return "Aucun post-it ne correspond aux filtres." }
        switch column {
        case .todo: return "Aucun post-it. ⌘N pour en créer un."
        case .inProgress: return "Aucun post-it en cours."
        case .review: return "Rien à valider."
        case .done: return "Aucun post-it fait."
        }
    }

    /// Drops the first payload right above `target` (nil: at the end of the section). The position is taken in
    /// the whole column (hidden cards included), the dragged card left out.
    private func drop(_ payloads: [CardDragPayload], before target: TaskCardID?) -> Bool {
        guard let cardID = payloads.first?.cardID, cardID != target, model.board.card(cardID) != nil else {
            return false
        }
        let others = model.board.cards(in: column).map(\.id).filter { $0 != cardID }
        let after: TaskCardID?
        if let target, let index = others.firstIndex(of: target) {
            after = index > 0 ? others[index - 1] : nil
        } else {
            after = others.last
        }
        workbench.requestTask(.move(cardID, to: column, after: after))
        focus.wrappedValue = cardID
        return true
    }
}

extension BoardColumnView where Leading == EmptyView {
    init(column: Column, cards: [TaskCard], total: Int, isFiltered: Bool, isExpanded: Binding<Bool>? = nil,
         focus: FocusState<TaskCardID?>.Binding, moveFocus: @escaping (TaskCardID, Int) -> Void) {
        self.init(column: column, cards: cards, total: total, isFiltered: isFiltered, isExpanded: isExpanded,
                  focus: focus, moveFocus: moveFocus) { EmptyView() }
    }
}

/// A card as a drop target: a card dropped on it takes its place (an insertion line shows above it).
private struct CardDropSlot<Content: View>: View {
    let card: TaskCard
    let column: Column
    let drop: ([CardDragPayload], TaskCardID?) -> Bool
    @ViewBuilder let content: () -> Content

    @State private var isTargeted = false

    var body: some View {
        content()
            .overlay(alignment: .top) {
                if isTargeted {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .offset(y: -5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: CardDragPayload.self) { payloads, _ in
                drop(payloads, card.id)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
    }
}
