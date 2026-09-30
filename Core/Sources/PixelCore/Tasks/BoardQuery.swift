import Foundation

/// What the board shows (proposal 3.5, mock-ups 6(b) and 6(c)). Every criterion narrows the cards; a neutral
/// one (nil, empty, blank) keeps them all. Observed by the interface, never persisted.
public struct BoardFilter: Equatable, Sendable {
    /// nil = all projects. A card without a project only shows with all projects.
    public var projectID: ProjectID?
    /// Empty = all columns.
    public var columns: Set<Column>
    /// All must be present on the card, case-insensitive, with or without a leading "#" (as the validator
    /// stores them). Blank ones are ignored.
    public var tags: Set<String>
    /// Fuzzy (`FuzzyMatcher`) on the title, the details and the tags (written "#tag").
    public var text: String
    /// nil = assigned to anyone, or to nobody.
    public var assignee: AgentID?

    public init(projectID: ProjectID? = nil, columns: Set<Column> = [], tags: Set<String> = [], text: String = "",
                assignee: AgentID? = nil) {
        self.projectID = projectID
        self.columns = columns
        self.tags = tags
        self.text = text
        self.assignee = assignee
    }

    /// True exactly when the filter keeps every card: no project, column or assignee chosen, and no tag or
    /// search word left once blank ones are ignored.
    public var isEmpty: Bool {
        projectID == nil && columns.isEmpty && assignee == nil && tagKeys.isEmpty && FuzzyMatcher.words(text).isEmpty
    }

    /// The tags as the board compares them (`TaskBoardValidator.tagKey` of the normalized tags).
    var tagKeys: Set<String> {
        Set(TaskBoardValidator.normalizedTags(Array(tags)).map(TaskBoardValidator.tagKey))
    }
}

/// Approximate matching for the board's search and the ⌘K palette (proposal 3.5, 3.16).
public enum FuzzyMatcher {
    /// Case- and diacritic-insensitive ("é" is "e"; the ligatures "œ" and "æ" are "oe" and "ae"); invisible
    /// characters (zero-width and bidi marks, controls) are ignored. Every whitespace-separated word of `query`
    /// must be a subsequence of some whitespace-separated word of `candidate`: "pagi" and "pgn" find
    /// "Pagination", "corr login" finds "Corriger le login". A query word never spans two candidate words:
    /// letters picked here and there in a long description would match almost any short word.
    /// Empty query matches everything.
    public static func matches(_ query: String, _ candidate: String) -> Bool {
        matches(words: words(query), in: words(candidate))
    }

    /// Every query word is a subsequence of some candidate word (both from `words(_:)`).
    static func matches(words query: [[Character]], in candidate: [[Character]]) -> Bool {
        query.allSatisfy { word in candidate.contains { isSubsequence(word, of: $0) } }
    }

    /// The words of a text as compared: folded (`fold(_:)`), split on whitespace, blank ones dropped.
    static func words(_ text: String) -> [[Character]] {
        fold(text).split(whereSeparator: \.isWhitespace).map(Array.init)
    }

    /// Case, diacritics and French ligatures folded away, invisible scalars removed (whitespace kept).
    /// `folding` is the Foundation one, available on Linux too; `lowercased()` makes the case identical
    /// whatever the platform folds to.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var result = ""
        result.unicodeScalars.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars where !isInvisible(scalar) {
            switch scalar {
            case "œ": result.unicodeScalars.append(contentsOf: "oe".unicodeScalars)
            case "æ": result.unicodeScalars.append(contentsOf: "ae".unicodeScalars)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// A control or format scalar (zero-width space, bidi marks, byte order mark, escape…) that is not
    /// whitespace: tabs and line breaks still separate words.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.properties.isWhitespace else { return false }
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    private static func isSubsequence(_ word: [Character], of text: [Character]) -> Bool {
        var next = word.startIndex
        for character in text where next < word.endIndex && character == word[next] {
            next += 1
        }
        return next == word.endIndex
    }
}

/// Read-only views of the board (proposal 3.5, 4.2): the columns under a filter, and each agent's queue,
/// derived from the cards and the instructions, never stored. Deterministic.
public enum BoardQuery {
    /// Every column (even empty), cards filtered and ordered by `rank` (then `createdAt`, then id, as
    /// `TaskBoardState.cards(in:)`). A column left out by `filter.columns` is present and empty.
    public static func filtered(_ board: TaskBoardState, _ filter: BoardFilter) -> [Column: [TaskCard]] {
        let tagKeys = filter.tagKeys
        let words = FuzzyMatcher.words(filter.text)
        var result: [Column: [TaskCard]] = [:]
        for column in Column.allCases {
            guard filter.columns.isEmpty || filter.columns.contains(column) else {
                result[column] = []
                continue
            }
            result[column] = board.cards(in: column).filter { card in
                keeps(card, filter: filter, tagKeys: tagKeys, words: words)
            }
        }
        return result
    }

    /// Instructions of the agent by queueRank, then its todo cards by queueRank. A card is queued when it is
    /// "assignée en file" (4.3b): `todo`, assigned to the agent, with a queue rank. Ties (never left by the
    /// validator) fall back to creation then id for instructions, to the column order for cards.
    public static func queue(of agent: AgentID, in board: TaskBoardState) -> [QueueItem] {
        let instructions = board.instructions
            .filter { $0.agentID == agent }
            .sorted(by: instructionOrder)
        let cards = board.cards
            .filter { $0.column == .todo && $0.assignee == agent && $0.queueRank != nil }
            .sorted(by: cardQueueOrder)
        return instructions.map { .instruction($0.id) } + cards.map { .card($0.id) }
    }

    /// 1-based position of a card in its assignee's queue ("file #2"), nil if not queued. The instructions
    /// ahead of it count: they are delivered first.
    public static func queuePosition(of card: TaskCardID, in board: TaskBoardState) -> Int? {
        guard let found = board.card(card), found.column == .todo, found.queueRank != nil,
              let agent = found.assignee else { return nil }
        return queue(of: agent, in: board).firstIndex(of: .card(card)).map { $0 + 1 }
    }

    /// The card an agent is working on (inProgress), if any. When a stopped card (interrupted, failed turn,
    /// lost session) sits next to the running one, the running one; when all are stopped, the one updated
    /// last, which the agent's card still shows until the user decides.
    public static func currentCard(of agent: AgentID, in board: TaskBoardState) -> TaskCard? {
        board.cards
            .filter { $0.column == .inProgress && $0.assignee == agent }
            .min { a, b in
                let aStopped = !a.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags)
                let bStopped = !b.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags)
                if aStopped != bStopped { return !aStopped }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return TaskCard.displayOrder(a, b)
            }
    }

    /// All tags used on the board, sorted, case-insensitively unique. Normalized as the validator stores them;
    /// of two spellings of one tag ("API", "api"), the first met in the board's card order is kept. Sorted
    /// ignoring case and accents ("élan" before "zeta"), then by their exact text.
    public static func allTags(_ board: TaskBoardState) -> [String] {
        TaskBoardValidator.normalizedTags(board.cards.flatMap(\.tags))
            .map { (key: FuzzyMatcher.fold($0), tag: $0) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.tag < $1.tag }
            .map(\.tag)
    }

    // MARK: - Helpers

    private static func keeps(_ card: TaskCard, filter: BoardFilter, tagKeys: Set<String>,
                              words: [[Character]]) -> Bool {
        if let project = filter.projectID, card.projectID != project { return false }
        if let agent = filter.assignee, card.assignee != agent { return false }
        if !tagKeys.isEmpty {
            let cardKeys = Set(TaskBoardValidator.normalizedTags(card.tags).map(TaskBoardValidator.tagKey))
            guard tagKeys.isSubset(of: cardKeys) else { return false }
        }
        if !words.isEmpty {
            let searched = ([card.title, card.details] + card.tags.map { "#" + $0 }).joined(separator: " ")
            guard FuzzyMatcher.matches(words: words, in: FuzzyMatcher.words(searched)) else { return false }
        }
        return true
    }

    /// Queue order of an agent's instructions: key, then creation, then id (total and deterministic).
    private static func instructionOrder(_ a: QueuedInstruction, _ b: QueuedInstruction) -> Bool {
        if a.queueRank != b.queueRank { return a.queueRank < b.queueRank }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    /// Queue order of an agent's cards: key, then column order.
    private static func cardQueueOrder(_ a: TaskCard, _ b: TaskCard) -> Bool {
        if a.queueRank != b.queueRank { return (a.queueRank ?? "") < (b.queueRank ?? "") }
        return TaskCard.displayOrder(a, b)
    }
}
