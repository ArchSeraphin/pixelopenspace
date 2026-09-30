import Foundation

/// The four columns of the cork board (proposal 4.3b).
public enum Column: String, Codable, CaseIterable, Sendable {
    case todo, inProgress, review, done
}

extension Column {
    public var title: String {
        switch self {
        case .todo: "À faire"
        case .inProgress: "En cours"
        case .review: "À valider"
        case .done: "Fait"
        }
    }
}

/// Pin colour: green, yellow, red. Always written out too (tooltip, VoiceOver): never the colour alone.
public enum Priority: Int, Codable, CaseIterable, Sendable, Comparable {
    case low = 0, normal = 1, high = 2

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension Priority {
    public var title: String {
        switch self {
        case .low: "basse"
        case .normal: "normale"
        case .high: "haute"
        }
    }
}

/// Labels a card carries without changing column (C8, C11, C13).
public enum CardFlag: String, Codable, CaseIterable, Sendable {
    case deliveryFailed, interrupted, turnFailed, sessionLost, backgroundRunning
}

public enum CardEventKind: String, Codable, Sendable {
    case created, edited, assigned, unassigned, reassigned, reordered, deliveryStarted, deliveryConfirmed,
         deliveryFailed, turnEnded, turnReopened, turnFailed, interrupted, sessionLost, continued, putBack,
         markedForReview, resent, validated, reopened, projectChanged
}

/// One line of a card's history, readable in the editor.
public struct CardEvent: Codable, Hashable, Sendable {
    public var at: Date
    public var kind: CardEventKind
    public var from: Column?
    public var to: Column?
    public var agentID: AgentID?
    /// Short free text (reason of a failure, previous project name…), French.
    public var note: String?

    public init(at: Date, kind: CardEventKind, from: Column? = nil, to: Column? = nil, agentID: AgentID? = nil,
                note: String? = nil) {
        self.at = at
        self.kind = kind
        self.from = from
        self.to = to
        self.agentID = agentID
        self.note = note
    }
}

/// A delivery of a card to its assignee's terminal (the agent is the assignee).
public struct DeliveryInfo: Codable, Hashable, Sendable {
    public var sessionID: String?
    public var promptID: String?
    public var sentAt: Date
    public var confirmedAt: Date?
    public var turnEndedAt: Date?

    /// Sent but neither confirmed nor failed yet (a failure clears the delivery, C8).
    public var isPending: Bool { confirmedAt == nil }

    public init(sessionID: String? = nil, promptID: String? = nil, sentAt: Date, confirmedAt: Date? = nil,
                turnEndedAt: Date? = nil) {
        self.sessionID = sessionID
        self.promptID = promptID
        self.sentAt = sentAt
        self.confirmedAt = confirmedAt
        self.turnEndedAt = turnEndedAt
    }
}

/// A post-it. Column, assignment, queue rank, flags, delivery and history change only through
/// `TaskLifecycle.reduce` (proposal 4.2); text, tags, priority and template through the editor.
public struct TaskCard: Codable, Identifiable, Hashable, Sendable {
    public let id: TaskCardID
    public var title: String
    public var details: String
    /// Colour of the post-it = hue of the project (neutral when nil).
    public var projectID: ProjectID?
    public var column: Column
    /// Display order inside the column (`RankKey`).
    public var rank: String
    public var priority: Priority
    public var tags: [String]
    /// Only source of the assignment.
    public var assignee: AgentID?
    /// Rank in the assignee's queue; non-nil exactly when `column == .todo && assignee != nil`.
    public var queueRank: String?
    public var templateID: PromptTemplateID?
    /// Current or last delivery; earlier ones are summarized in `history`.
    public var delivery: DeliveryInfo?
    public var flags: Set<CardFlag>
    public var history: [CardEvent]
    /// Set once the card has been validated at least once (XP counted once, step 6).
    public var validatedOnce: Bool
    public var createdAt: Date
    public var updatedAt: Date

    /// `updatedAt` defaults to `createdAt`.
    public init(id: TaskCardID = TaskCardID(), title: String, details: String = "", projectID: ProjectID?,
                column: Column = .todo, rank: String, priority: Priority = .normal, tags: [String] = [],
                assignee: AgentID? = nil, queueRank: String? = nil, templateID: PromptTemplateID? = nil,
                delivery: DeliveryInfo? = nil, flags: Set<CardFlag> = [], history: [CardEvent] = [],
                validatedOnce: Bool = false, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.details = details
        self.projectID = projectID
        self.column = column
        self.rank = rank
        self.priority = priority
        self.tags = tags
        self.assignee = assignee
        self.queueRank = queueRank
        self.templateID = templateID
        self.delivery = delivery
        self.flags = flags
        self.history = history
        self.validatedOnce = validatedOnce
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, details, projectID, column, rank, priority, tags, assignee, queueRank, templateID,
             delivery, flags, history, validatedOnce, createdAt, updatedAt
    }

    /// Fields added after the first version, and the ones with an obvious default, may be missing.
    /// Unknown flags (written by a newer app) are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TaskCardID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        projectID = try c.decodeIfPresent(ProjectID.self, forKey: .projectID)
        column = try c.decode(Column.self, forKey: .column)
        rank = try c.decode(String.self, forKey: .rank)
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .normal
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        assignee = try c.decodeIfPresent(AgentID.self, forKey: .assignee)
        queueRank = try c.decodeIfPresent(String.self, forKey: .queueRank)
        templateID = try c.decodeIfPresent(PromptTemplateID.self, forKey: .templateID)
        delivery = try c.decodeIfPresent(DeliveryInfo.self, forKey: .delivery)
        flags = Set((try c.decodeIfPresent([String].self, forKey: .flags) ?? []).compactMap(CardFlag.init(rawValue:)))
        history = try c.decodeIfPresent([CardEvent].self, forKey: .history) ?? []
        validatedOnce = try c.decodeIfPresent(Bool.self, forKey: .validatedOnce) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Flags are written in declaration order: a `Set`'s order changes from one launch to the next,
    /// the file must not.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encode(column, forKey: .column)
        try c.encode(rank, forKey: .rank)
        try c.encode(priority, forKey: .priority)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(assignee, forKey: .assignee)
        try c.encodeIfPresent(queueRank, forKey: .queueRank)
        try c.encodeIfPresent(templateID, forKey: .templateID)
        try c.encodeIfPresent(delivery, forKey: .delivery)
        try c.encode(CardFlag.allCases.filter(flags.contains), forKey: .flags)
        try c.encode(history, forKey: .history)
        try c.encode(validatedOnce, forKey: .validatedOnce)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Ad hoc instruction in an agent's queue ("Donner une consigne", "Continuer la tâche", ↺ précision).
public struct QueuedInstruction: Codable, Identifiable, Hashable, Sendable {
    public let id: InstructionID
    public var agentID: AgentID
    public var text: String
    /// The card this instruction continues or refines (C14, C17), if any.
    public var cardID: TaskCardID?
    /// Instructions come before cards; among them, by this rank.
    public var queueRank: String
    /// Set while this instruction is being delivered.
    public var delivery: DeliveryInfo?
    public var createdAt: Date

    public init(id: InstructionID = InstructionID(), agentID: AgentID, text: String, cardID: TaskCardID? = nil,
                queueRank: String, delivery: DeliveryInfo? = nil, createdAt: Date) {
        self.id = id
        self.agentID = agentID
        self.text = text
        self.cardID = cardID
        self.queueRank = queueRank
        self.delivery = delivery
        self.createdAt = createdAt
    }
}

public struct PromptTemplate: Codable, Identifiable, Hashable, Sendable {
    public let id: PromptTemplateID
    public var name: String
    /// Variables: {titre} {description} {projet} {chemin} {tags} {priorite}.
    public var body: String

    public init(id: PromptTemplateID = PromptTemplateID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}

/// What an agent's queue is made of (derived, never stored).
public enum QueueItem: Hashable, Sendable {
    case instruction(InstructionID)
    case card(TaskCardID)
}

/// Persisted as `state/tasks.json`.
public struct TaskBoardState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var cards: [TaskCard]
    public var instructions: [QueuedInstruction]
    public var templates: [PromptTemplate]

    public init(schemaVersion: Int = TaskBoardState.currentSchemaVersion, cards: [TaskCard] = [],
                instructions: [QueuedInstruction] = [], templates: [PromptTemplate] = []) {
        self.schemaVersion = schemaVersion
        self.cards = cards
        self.instructions = instructions
        self.templates = templates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cards, instructions, templates
    }

    /// Every list may be missing (an empty board).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? TaskBoardState.currentSchemaVersion
        cards = try c.decodeIfPresent([TaskCard].self, forKey: .cards) ?? []
        instructions = try c.decodeIfPresent([QueuedInstruction].self, forKey: .instructions) ?? []
        templates = try c.decodeIfPresent([PromptTemplate].self, forKey: .templates) ?? []
    }

    public func card(_ id: TaskCardID) -> TaskCard? {
        cards.first { $0.id == id }
    }

    public func template(_ id: PromptTemplateID) -> PromptTemplate? {
        templates.first { $0.id == id }
    }

    /// Cards of a column, by `rank` then `createdAt` then id.
    public func cards(in column: Column) -> [TaskCard] {
        cards.filter { $0.column == column }.sorted(by: TaskCard.displayOrder)
    }

    /// A fresh board with `StarterTemplates.make(ids:)` (first launch, no `tasks.json`).
    public static func initial(templateIDs: [PromptTemplateID]) -> TaskBoardState {
        TaskBoardState(templates: StarterTemplates.make(ids: templateIDs))
    }
}

extension TaskCard {
    /// Order inside a column: `rank`, then `createdAt`, then id (total and deterministic).
    static func displayOrder(_ a: TaskCard, _ b: TaskCard) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }
}
