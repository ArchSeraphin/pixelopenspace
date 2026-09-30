import Foundation

/// Repairs a loaded board against the workspace's agents and projects, so that the invariants of proposal 4.2
/// and 4.3b hold; each repair is reported (French, shown in the load banner and the log). A card is never lost:
/// only a second copy of the same id is dropped. Deterministic. The core has no clock: repair events are dated
/// at the card's `updatedAt`, which is left unchanged.
///
/// After a repair: every assignee and instruction agent is known; every "En cours" card has an assignee, and at
/// most one per agent has no stopping flag; a pending delivery sits only on a queued card; `queueRank != nil`
/// exactly on queued cards, and each agent's queue keys (instructions, then cards) are valid and strictly
/// ascending; ranks are valid and unique in each column; an instruction's card exists.
public enum TaskBoardValidator {
    /// Title given to a card whose title is blank.
    public static let untitled = "Sans titre"

    /// Flags that mean the card's turn is over (the agent no longer works on it): such a card leaves room
    /// for another "En cours" card of the same agent (C13, C14). The app asks the user to settle such a card before
    /// resuming the agent's queue (4.3b).
    public static let stoppingFlags: Set<CardFlag> = [.interrupted, .turnFailed, .sessionLost]

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

        // Instructions of unknown agents, or tied to a card that no longer exists (C20 removes them with it).
        board.instructions = board.instructions.filter { instruction in
            guard agents.contains(instruction.agentID) else {
                issues.append("Consigne \(quoted(instruction.text)) pour un agent introuvable : supprimée.")
                return false
            }
            if let card = instruction.cardID, !cardIDs.contains(card) {
                issues.append("Consigne \(quoted(instruction.text)) liée à un post-it introuvable : supprimée.")
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

        // Cards sent back to "À faire" below get their rank at its end once its ranks are repaired (last step):
        // a rank computed now could sort before an invalid one.
        var backToTodo: [Int] = []

        // Cards of unknown agents: unassigned, back to "À faire" when they were in progress or waiting for
        // review (as C15), never removed.
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
                backToTodo.append(i)
                issues.append("Post-it \(title) : agent introuvable, remis \(quoted(Column.todo.title)) sans assignation.")
            case .done:
                issues.append("Post-it \(title) : agent introuvable, assignation retirée.")
            }
            fixed.history.append(CardEvent(at: card.updatedAt, kind: .unassigned, from: card.column, to: fixed.column,
                                           agentID: agent, note: note))
            board.cards[i] = fixed
        }

        // An "En cours" card without an agent: nobody works on it, back to "À faire" (as C15). A card of
        // "À valider" without an agent stays: it can still be validated.
        for i in board.cards.indices where board.cards[i].column == .inProgress && board.cards[i].assignee == nil {
            let card = board.cards[i]
            var note = "en cours sans agent au chargement"
            if let promptID = card.delivery?.promptID { note += ", tour \(promptID)" }
            board.cards[i].column = .todo
            board.cards[i].queueRank = nil
            board.cards[i].flags = []
            board.cards[i].delivery = nil
            board.cards[i].history.append(CardEvent(at: card.updatedAt, kind: .putBack, from: .inProgress, to: .todo,
                                                    note: note))
            backToTodo.append(i)
            issues.append("Post-it \(quoted(card.title)) : en cours sans agent, remis \(quoted(Column.todo.title)).")
        }

        // Only a queued card's pending delivery (sent, not confirmed) can be confirmed (C7): on a card of "Fait"
        // or an unassigned card of "À faire", it is cleared (4.3b: a done card never has one).
        for i in board.cards.indices {
            let card = board.cards[i]
            guard card.delivery?.isPending == true,
                  card.column == .done || (card.column == .todo && card.assignee == nil) else { continue }
            board.cards[i].delivery = nil
            issues.append("Post-it \(quoted(card.title)) : envoi jamais confirmé, effacé.")
        }

        // queueRank != nil ⇔ todo ∧ assignee != nil.
        for i in board.cards.indices {
            let card = board.cards[i]
            if card.queueRank != nil, !(card.column == .todo && card.assignee != nil) {
                board.cards[i].queueRank = nil
                issues.append("Post-it \(quoted(card.title)) : rang de file retiré (hors de toute file).")
            }
        }

        // Each agent's queue keys, in queue order (instructions, then cards, each by key), valid and strictly
        // ascending; otherwise renumbered in that order. Afterwards a key between two neighbours always exists.
        var queueAgents = Set(board.instructions.map(\.agentID))
        for card in board.cards where card.column == .todo && card.queueRank != nil {
            if let agent = card.assignee { queueAgents.insert(agent) }
        }
        for agent in queueAgents.sorted() {
            let instructions = board.instructions.indices
                .filter { board.instructions[$0].agentID == agent }
                .sorted { queueOrder(board.instructions[$0], board.instructions[$1]) }
            let cards = board.cards.indices
                .filter { board.cards[$0].column == .todo && board.cards[$0].assignee == agent && board.cards[$0].queueRank != nil }
                .sorted { queueOrder(board.cards[$0], board.cards[$1]) }
            let keys = instructions.map { board.instructions[$0].queueRank } + cards.compactMap { board.cards[$0].queueRank }
            guard !keys.allSatisfy(RankKey.isValid) || !zip(keys, keys.dropFirst()).allSatisfy({ $0 < $1 }) else { continue }
            let spread = RankKey.spread(keys.count)
            for (i, key) in zip(instructions, spread) {
                board.instructions[i].queueRank = key
            }
            for (i, key) in zip(cards, spread.dropFirst(instructions.count)) {
                board.cards[i].queueRank = key
            }
            issues.append("File d'un agent (\(agent)) : rangs en double ou invalides, renumérotés.")
        }

        // Queued cards without a queue rank: appended to their agent's queue, in column order.
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
        // (none is moved; the user decides with "Continuer la tâche" or "Remettre à faire"). A card already
        // stopped (`stoppingFlags`) does not count: it leaves room for the current one.
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

        // Unique, valid ranks inside each column; renumbered in their current order. Then the cards sent back
        // to "À faire" go to its end, in file order.
        let returning = Set(backToTodo)
        for column in Column.allCases {
            let indices = board.cards.indices
                .filter { board.cards[$0].column == column && !returning.contains($0) }
                .sorted { TaskCard.displayOrder(board.cards[$0], board.cards[$1]) }
            let ranks = indices.map { board.cards[$0].rank }
            guard Set(ranks).count != ranks.count || !ranks.allSatisfy(RankKey.isValid) else { continue }
            for (i, rank) in zip(indices, RankKey.spread(indices.count)) {
                board.cards[i].rank = rank
            }
            issues.append("Colonne \(quoted(column.title)) : rangs en double ou invalides, renumérotés.")
        }
        var lastTodoRank = board.cards.indices
            .filter { board.cards[$0].column == .todo && !returning.contains($0) }
            .map { board.cards[$0].rank }
            .max()
        for i in backToTodo {
            board.cards[i].rank = RankKey.after(lastTodoRank)
            lastTodoRank = board.cards[i].rank
        }

        return (board, issues)
    }

    /// Tags as stored: whitespace and invisible characters (controls, zero-width and bidi marks) removed,
    /// leading "#" removed, empty ones dropped, duplicates dropped (case-insensitive by `tagKey`, the first
    /// one kept). Spaces inside a tag are removed too ("mon tag" becomes "montag"): a tag shows as one `#token`.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in tags {
            var cleaned = tag.filter { !isInvisible($0) }
            while cleaned.hasPrefix("#") { cleaned.removeFirst() }
            guard !cleaned.isEmpty, seen.insert(tagKey(cleaned)).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    /// What makes two tags the same: case-insensitive with the full case mappings of the standard library
    /// ("ß" and "SS", "ς" and "Σ"), identical on every platform.
    static func tagKey(_ tag: String) -> String {
        tag.uppercased().lowercased()
    }

    /// Whitespace, or a character made only of control and format scalars (zero-width space, bidi marks, byte
    /// order mark, soft hyphen). A zero-width joiner inside an emoji belongs to the emoji's character and stays.
    private static func isInvisible(_ character: Character) -> Bool {
        character.isWhitespace || character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format: true
            default: false
            }
        }
    }

    /// Queue order of an agent's instructions: key, then creation, then id (total and deterministic).
    private static func queueOrder(_ a: QueuedInstruction, _ b: QueuedInstruction) -> Bool {
        if a.queueRank != b.queueRank { return a.queueRank < b.queueRank }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    /// Queue order of an agent's cards: key, then column order.
    private static func queueOrder(_ a: TaskCard, _ b: TaskCard) -> Bool {
        if a.queueRank != b.queueRank { return (a.queueRank ?? "") < (b.queueRank ?? "") }
        return TaskCard.displayOrder(a, b)
    }

    /// « text », cut at 40 characters for the banner.
    private static func quoted(_ text: String) -> String {
        let limit = 40
        let short = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return "« \(short) »"
    }
}
