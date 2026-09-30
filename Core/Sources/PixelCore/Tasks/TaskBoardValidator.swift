import Foundation

/// Repairs a loaded board against the workspace's agents and projects, so that the invariants of proposal 4.2
/// and 4.3b hold; each repair is reported (French, shown in the load banner and the log). A card is never lost:
/// only a second copy of the same id is dropped. Deterministic. The core has no clock: repair events are dated
/// at the card's `updatedAt`, which is left unchanged.
public enum TaskBoardValidator {
    /// Title given to a card whose title is blank.
    public static let untitled = "Sans titre"

    /// Flags that mean the card's turn is over (the agent no longer works on it): such a card leaves room
    /// for another "En cours" card of the same agent (C13, C14).
    static let stoppingFlags: Set<CardFlag> = [.interrupted, .turnFailed, .sessionLost]

    /// Repairs a loaded board against the workspace's agents and projects; French messages for the load banner.
    public static func validate(_ input: TaskBoardState, agents: Set<AgentID>, projects: Set<ProjectID>)
        -> (board: TaskBoardState, issues: [String]) {
        var board = input
        var issues: [String] = []

        // Unique ids: the first copy is kept.
        var cardIDs: Set<TaskCardID> = []
        board.cards = board.cards.filter { card in
            guard cardIDs.insert(card.id).inserted else {
                issues.append("Post-it \(quoted(card.title)) en double (\(card.id)) : copie ignorée.")
                return false
            }
            return true
        }
        var instructionIDs: Set<InstructionID> = []
        board.instructions = board.instructions.filter { instruction in
            guard instructionIDs.insert(instruction.id).inserted else {
                issues.append("Consigne \(quoted(instruction.text)) en double (\(instruction.id)) : copie ignorée.")
                return false
            }
            return true
        }
        var templateIDs: Set<PromptTemplateID> = []
        board.templates = board.templates.filter { template in
            guard templateIDs.insert(template.id).inserted else {
                issues.append("Modèle \(quoted(template.name)) en double (\(template.id)) : copie ignorée.")
                return false
            }
            return true
        }

        // Instructions of unknown agents.
        board.instructions = board.instructions.filter { instruction in
            guard agents.contains(instruction.agentID) else {
                issues.append("Consigne \(quoted(instruction.text)) pour un agent introuvable : supprimée.")
                return false
            }
            return true
        }

        // Title, tags, project, template.
        for i in board.cards.indices {
            if board.cards[i].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                board.cards[i].title = untitled
                issues.append("Post-it sans titre : nommé \(quoted(untitled)).")
            }
            let title = quoted(board.cards[i].title)
            let tags = normalizedTags(board.cards[i].tags)
            if tags != board.cards[i].tags {
                board.cards[i].tags = tags
                issues.append("Post-it \(title) : tags corrigés.")
            }
            if let project = board.cards[i].projectID, !projects.contains(project) {
                board.cards[i].projectID = nil
                issues.append("Post-it \(title) : projet introuvable (\(project)), retiré.")
            }
            if let template = board.cards[i].templateID, !templateIDs.contains(template) {
                board.cards[i].templateID = nil
                issues.append("Post-it \(title) : modèle introuvable (\(template)), retiré.")
            }
        }

        // Cards of unknown agents: unassigned, back to "À faire" when they were in progress or waiting for
        // review (as C15), never removed.
        var lastTodoRank = board.cards.filter { $0.column == .todo }.map(\.rank).max()
        for i in board.cards.indices {
            guard let agent = board.cards[i].assignee, !agents.contains(agent) else { continue }
            let card = board.cards[i]
            let title = quoted(card.title)
            var fixed = card
            fixed.assignee = nil
            fixed.queueRank = nil
            var note = "agent introuvable au chargement"
            switch card.column {
            case .todo:
                fixed.flags = []
                if card.delivery?.isPending == true { fixed.delivery = nil }
                issues.append("Post-it \(title) : agent introuvable, retiré de sa file.")
            case .inProgress, .review:
                if let promptID = card.delivery?.promptID { note += ", tour \(promptID)" }
                fixed.column = .todo
                fixed.flags = []
                fixed.delivery = nil
                fixed.rank = RankKey.after(lastTodoRank)
                lastTodoRank = fixed.rank
                issues.append("Post-it \(title) : agent introuvable, remis \(quoted(Column.todo.title)) sans assignation.")
            case .done:
                issues.append("Post-it \(title) : agent introuvable, assignation retirée.")
            }
            fixed.history.append(CardEvent(at: card.updatedAt, kind: .unassigned, from: card.column, to: fixed.column,
                                           agentID: agent, note: note))
            board.cards[i] = fixed
        }

        // queueRank != nil ⇔ todo ∧ assignee != nil.
        for i in board.cards.indices {
            let card = board.cards[i]
            if card.queueRank != nil, !(card.column == .todo && card.assignee != nil) {
                board.cards[i].queueRank = nil
                issues.append("Post-it \(quoted(card.title)) : rang de file retiré (hors de toute file).")
            }
        }
        let unranked = board.cards.indices
            .filter { board.cards[$0].column == .todo && board.cards[$0].assignee != nil && board.cards[$0].queueRank == nil }
            .sorted { TaskCard.displayOrder(board.cards[$0], board.cards[$1]) }
        for i in unranked {
            guard let agent = board.cards[i].assignee else { continue }
            let instructionRanks = board.instructions.filter { $0.agentID == agent }.map(\.queueRank)
            let cardRanks = board.cards.filter { $0.column == .todo && $0.assignee == agent }.compactMap(\.queueRank)
            board.cards[i].queueRank = RankKey.after((instructionRanks + cardRanks).max())
            issues.append("Post-it \(quoted(board.cards[i].title)) : rang de file manquant, placé en fin de file.")
        }

        // At most one running card per agent: the oldest keeps its state, the others are marked interrupted
        // (none is moved; the user decides with "Continuer la tâche" or "Remettre à faire").
        var running: [AgentID: [Int]] = [:]
        for i in board.cards.indices {
            let card = board.cards[i]
            guard card.column == .inProgress, let agent = card.assignee, card.flags.isDisjoint(with: stoppingFlags)
            else { continue }
            running[agent, default: []].append(i)
        }
        for agent in running.keys.sorted() {
            let cards = running[agent, default: []].sorted { a, b in
                let x = board.cards[a]
                let y = board.cards[b]
                if x.updatedAt != y.updatedAt { return x.updatedAt < y.updatedAt }
                if x.createdAt != y.createdAt { return x.createdAt < y.createdAt }
                return x.id < y.id
            }
            for i in cards.dropFirst() {
                board.cards[i].flags.insert(.interrupted)
                board.cards[i].history.append(CardEvent(at: board.cards[i].updatedAt, kind: .interrupted, agentID: agent,
                                                        note: "autre post-it en cours pour cet agent au chargement"))
                issues.append("Post-it \(quoted(board.cards[i].title)) : un autre post-it est déjà en cours pour cet agent, marqué interrompu.")
            }
        }

        // Unique, valid ranks inside each column; renumbered in their current order.
        for column in Column.allCases {
            let indices = board.cards.indices
                .filter { board.cards[$0].column == column }
                .sorted { TaskCard.displayOrder(board.cards[$0], board.cards[$1]) }
            let ranks = indices.map { board.cards[$0].rank }
            guard Set(ranks).count != ranks.count || !ranks.allSatisfy(RankKey.isValid) else { continue }
            for (i, rank) in zip(indices, RankKey.spread(indices.count)) {
                board.cards[i].rank = rank
            }
            issues.append("Colonne \(quoted(column.title)) : rangs en double ou invalides, renumérotés.")
        }

        return (board, issues)
    }

    /// Tags as stored: whitespace removed, leading "#" removed, empty ones dropped, duplicates dropped
    /// (case-insensitive, the first one kept).
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in tags {
            var cleaned = tag.filter { !$0.isWhitespace }
            while cleaned.hasPrefix("#") { cleaned.removeFirst() }
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    /// « text », cut at 40 characters for the banner.
    private static func quoted(_ text: String) -> String {
        let limit = 40
        let short = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return "« \(short) »"
    }
}
