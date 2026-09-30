import Foundation
import Testing
@testable import PixelCore

/// Linear congruential generator with a fixed seed (Knuth's MMIX constants): deterministic "random" inputs.
private struct LifecycleLCG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491_4F6C_DD1D
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }

    mutating func chance(_ percent: Int) -> Bool { next(below: 100) < percent }

    mutating func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[next(below: items.count)] }
}

/// The invariants of proposal 4.3b checked after every input, and a few more that keep the queues usable.
private enum Invariant: String, CaseIterable, Sendable {
    /// (1) At most one "En cours" card per agent without a stopping flag.
    case oneRunningCardPerAgent
    /// (2) `queueRank != nil` ⇔ `todo ∧ assignee != nil`.
    case queueRankExactlyOnQueuedCards
    /// (3) A done card never has a pending delivery.
    case doneNeverPending
    /// (4) `.validated(_, firstTime: true)` at most once per card over the whole sequence.
    case firstValidationOnce
    /// (5) No input makes a card disappear, except `delete` of that card.
    case cardsLeaveOnlyByDelete
    /// (6) Every assigned card is assigned to an agent of `agentProjects`.
    case assigneesAreKnown
    /// A refused input changes nothing and emits one `.rejected`.
    case refusalChangesNothing
    /// Each agent's queue keys (instructions, then cards) strictly ascend; ranks are unique in each column.
    case keysStayOrdered
}

/// 300 sequences of 60 deterministic random inputs, on a world of 3 agents in 2 projects (Oslo offline),
/// checked after every input. Run once and shared by the tests.
private struct Simulation: Sendable {
    static let sequences = 300
    static let length = 60

    /// The first violations of each invariant, with their seed and step.
    var violations: [Invariant: [String]] = [:]
    /// How often each kind of transition happened (the simulation must exercise the lifecycle).
    var coverage: [String: Int] = [:]

    static let shared: Simulation = {
        var simulation = Simulation()
        for sequence in 0..<sequences {
            simulation.run(seed: UInt64(sequence))
        }
        return simulation
    }()

    mutating func violate(_ invariant: Invariant, _ message: @autoclosure () -> String) {
        if violations[invariant, default: []].count < 5 {
            violations[invariant, default: []].append(message())
        } else {
            violations[invariant, default: []][4] = "…"
        }
    }

    mutating func count(_ key: String) {
        coverage[key, default: 0] += 1
    }

    mutating func run(seed: UInt64) {
        var generator = InputGenerator(seed: seed)
        var board = TaskBoardState(templates: StarterTemplates.make(ids: TaskBoardSamples.templateIDs))
        var agentProjects = TaskWorld.agentProjects
        var liveAgents = TaskWorld.liveAgents
        var validatedFirst: Set<TaskCardID> = []
        for step in 0..<Self.length {
            let input = generator.input(board: board)
            let context = TaskContext(now: TaskBoardSamples.at(Double(step)), agentProjects: agentProjects,
                                      liveAgents: liveAgents)
            let (next, effects) = TaskLifecycle.reduce(board, input, context: context)
            if case .agentRemoved(let agent) = input {
                agentProjects[agent] = nil
                liveAgents.remove(agent)
            }
            check(before: board, input: input, after: next, effects: effects, agents: agentProjects,
                  validatedFirst: &validatedFirst, at: "graine \(seed), étape \(step), \(input)")
            board = next
        }
    }

    mutating func check(before: TaskBoardState, input: TaskInput, after: TaskBoardState, effects: [TaskEffect],
                        agents: [AgentID: ProjectID], validatedFirst: inout Set<TaskCardID>, at location: String) {
        // (1)
        var running: [AgentID: Int] = [:]
        for card in after.cards where card.column == .inProgress
            && card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags) {
            guard let agent = card.assignee else {
                violate(.oneRunningCardPerAgent, "\(location): carte en cours sans agent \(card.id)")
                continue
            }
            running[agent, default: 0] += 1
        }
        if running.values.contains(where: { $0 > 1 }) {
            violate(.oneRunningCardPerAgent, "\(location): \(running)")
        }
        // (2), (3), (6)
        for card in after.cards {
            if (card.queueRank != nil) != (card.column == .todo && card.assignee != nil) {
                violate(.queueRankExactlyOnQueuedCards, "\(location): \(card.id) \(card.column) \(String(describing: card.queueRank))")
            }
            if card.column == .done && card.delivery?.isPending == true {
                violate(.doneNeverPending, "\(location): \(card.id)")
            }
            if let agent = card.assignee, agents[agent] == nil {
                violate(.assigneesAreKnown, "\(location): \(card.id) assignée à \(agent)")
            }
        }
        // (4)
        for effect in effects {
            if case .validated(let id, true) = effect, !validatedFirst.insert(id).inserted {
                violate(.firstValidationOnce, "\(location): \(id)")
            }
        }
        // (5)
        let lost = Set(before.cards.map(\.id)).subtracting(after.cards.map(\.id))
        var allowed: Set<TaskCardID> = []
        if case .delete(let id) = input { allowed = [id] }
        if !lost.isSubset(of: allowed) {
            violate(.cardsLeaveOnlyByDelete, "\(location): \(lost)")
        }
        // Refusals.
        let refused = effects.contains { effect in
            if case .rejected = effect { return true }
            return false
        }
        if refused && (effects.count != 1 || after != before) {
            violate(.refusalChangesNothing, "\(location): \(effects)")
        }
        // Keys.
        let queueAgents = Set(after.instructions.map(\.agentID) + after.cards.compactMap(\.assignee))
        for agent in queueAgents {
            let instructionKeys = after.instructions.filter { $0.agentID == agent }.map(\.queueRank).sorted()
            let cardKeys = after.cards.filter { $0.column == .todo && $0.assignee == agent }.compactMap(\.queueRank).sorted()
            if !TaskWorld.isStrictlyAscending(instructionKeys + cardKeys) {
                violate(.keysStayOrdered, "\(location): file de \(agent) \(instructionKeys) \(cardKeys)")
            }
        }
        for column in Column.allCases {
            let ranks = after.cards.filter { $0.column == column }.map(\.rank)
            if Set(ranks).count != ranks.count || !ranks.allSatisfy(RankKey.isValid) {
                violate(.keysStayOrdered, "\(location): rangs de \(column) \(ranks.sorted())")
            }
        }
        // Coverage.
        if refused {
            count("refused")
        } else {
            count("accepted " + String(String(describing: input).prefix { $0 != "(" }))
        }
        for effect in effects {
            if case .validated(_, true) = effect { count("firstValidation") }
            if case .pump = effect { count("pump") }
            if case .notify = effect { count("notify") }
        }
        for card in after.cards {
            guard let previous = before.card(card.id) else {
                count("created")
                continue
            }
            if previous.column != card.column { count("\(previous.column)->\(card.column)") }
            for flag in card.flags.subtracting(previous.flags) { count("flag \(flag)") }
            if previous.assignee != card.assignee && card.assignee != nil { count("assigned") }
        }
        if after.cards.count < before.cards.count { count("deleted") }
        if after.instructions.count < before.instructions.count { count("instructionLeft") }
    }
}

/// Draws inputs biased towards the ones that make the lifecycle move (delivering the head of a queue,
/// confirming, ending the turn of a running card), plus plain noise (unknown ids, unknown agents, wrong columns).
private struct InputGenerator {
    var rng: LifecycleLCG
    var nextCard = 1
    var nextInstruction = 1
    var nextPrompt = 1

    static let agents = [TaskWorld.nova, TaskWorld.pixou, TaskWorld.oslo]
    static let titles = ["Pagination", "Header", "Logs", "Doc de l'API", " ", "Lint"]
    static let tagSets: [[String]] = [[], ["api"], ["#API", "doc"], ["ui", " ui "]]
    static let reasons: [DeliveryAbortReason] = [.noPromptSubmit, .processGone, .guardFailed("brouillon")]

    init(seed: UInt64) {
        rng = LifecycleLCG(seed: seed)
    }

    mutating func freshCard() -> TaskCardID {
        defer { nextCard += 1 }
        return TaskBoardSamples.card(nextCard)
    }

    mutating func freshInstruction() -> InstructionID {
        // Now and then an id already used, to be refused.
        if nextInstruction > 1 && rng.chance(5) { return TaskBoardSamples.instruction(1 + rng.next(below: nextInstruction - 1)) }
        defer { nextInstruction += 1 }
        return TaskBoardSamples.instruction(nextInstruction)
    }

    mutating func freshPrompt() -> String {
        defer { nextPrompt += 1 }
        return "p-\(nextPrompt)"
    }

    mutating func agent() -> AgentID {
        rng.chance(4) ? TaskBoardSamples.agent(9) : Self.agents[rng.next(below: Self.agents.count)]
    }

    /// A card of the board, preferably in one of `columns`; now and then an unknown id.
    mutating func card(_ board: TaskBoardState, in columns: Set<Column> = Set(Column.allCases)) -> TaskCardID {
        card(board) { columns.contains($0.column) }
    }

    /// A card of the board, preferably one for which `preferred` holds; now and then an unknown id.
    mutating func card(_ board: TaskBoardState, where preferred: (TaskCard) -> Bool) -> TaskCardID {
        if board.cards.isEmpty || rng.chance(5) { return TaskBoardSamples.card(900 + rng.next(below: 3)) }
        if let card = rng.chance(80) ? rng.pick(board.cards.filter(preferred)) : nil { return card.id }
        return board.cards[rng.next(below: board.cards.count)].id
    }

    /// A card to drop after: nil (the top), a card of the target column, or any card.
    mutating func after(_ board: TaskBoardState, in column: Column) -> TaskCardID? {
        switch rng.next(below: 10) {
        case 0..<4: return nil
        case 4..<9: return rng.pick(board.cards(in: column))?.id
        default: return rng.pick(board.cards)?.id
        }
    }

    /// A prompt id the agent's cards carry in `column` (so that signals match), else a new one or nil.
    mutating func prompt(of agent: AgentID, in column: Column, _ board: TaskBoardState) -> String? {
        let known = board.cards.filter { $0.column == column && $0.assignee == agent }.compactMap(\.delivery?.promptID)
        if rng.chance(70), let promptID = rng.pick(known) { return promptID }
        return rng.chance(20) ? nil : freshPrompt()
    }

    mutating func input(board: TaskBoardState) -> TaskInput {
        // A delivery is confirmed or aborted within seconds: resolve one in flight, most of the time.
        let delivering = Self.agents.filter { Self.isDelivering($0, board) }
        if rng.chance(40), let agent = rng.pick(delivering) {
            if rng.chance(85) {
                return .agentSignal(agent, .deliveryConfirmed(promptID: rng.chance(10) ? nil : freshPrompt()))
            }
            return .agentSignal(agent, .deliveryFailed(Self.reasons[rng.next(below: Self.reasons.count)]))
        }
        // The user answers the actions a flagged card offers ("Réessayer", C13 to C16).
        if rng.chance(15), let failed = rng.pick(board.cards.filter { $0.flags.contains(.deliveryFailed) }) {
            return .retry(failed.id)
        }
        let stopped = board.cards.filter { card in
            card.column == .inProgress && !card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags)
        }
        if rng.chance(20), let card = rng.pick(stopped) {
            let live = card.assignee.map(TaskWorld.liveAgents.contains) == true
            let choice = rng.next(below: 4)
            if choice < 2 && live { return .continueTask(card.id, instructionID: freshInstruction()) }
            return choice == 2 ? .putBack(card.id) : .markForReview(card.id)
        }
        switch rng.next(below: 100) {
        case 0..<9:
            let projects: [ProjectID?] = [TaskWorld.api, TaskWorld.site, nil]
            return .create(id: freshCard(), title: rng.pick(Self.titles) ?? "", details: "",
                           projectID: rng.pick(projects) ?? nil, priority: rng.pick(Priority.allCases) ?? .normal,
                           tags: rng.pick(Self.tagSets) ?? [],
                           templateID: rng.chance(30) ? TaskBoardSamples.template(1 + rng.next(below: 4)) : nil)
        case 9..<18:
            return .assign(card(board, in: [.todo]), to: agent())
        case 18..<20:
            return .unassign(card(board, in: [.todo]))
        case 20..<23:
            let id = card(board, in: [.todo])
            let neighbour = board.card(id)?.assignee.flatMap { agent in
                rng.pick(board.cards.filter { $0.column == .todo && $0.assignee == agent })?.id
            }
            return .reorderQueue(id, after: rng.chance(30) ? nil : neighbour)
        case 23..<29:
            let column = rng.pick(Column.allCases) ?? .todo
            return .move(card(board), to: column, after: after(board, in: column))
        case 29..<41:
            return deliveryStarted(board)
        case 41..<69:
            return signal(board)
        case 69..<71:
            return .retry(card(board) { $0.flags.contains(.deliveryFailed) })
        case 71..<74:
            let stopped = card(board) { card in
                card.column == .inProgress && !card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags)
                    && card.assignee.map(TaskWorld.liveAgents.contains) == true
            }
            return .continueTask(stopped, instructionID: freshInstruction())
        case 74..<77:
            return .putBack(card(board, in: [.inProgress, .review]))
        case 77..<80:
            return .markForReview(card(board, in: [.inProgress]))
        case 80..<83:
            let reviewed = card(board) { $0.column == .review && $0.assignee.map(TaskWorld.liveAgents.contains) == true }
            return .resend(reviewed, precision: rng.chance(10) ? " " : "Précision", instructionID: freshInstruction())
        case 83..<86:
            return .validate(card(board, in: rng.chance(70) ? [.review] : [.inProgress, .todo]))
        case 86..<88:
            return .reopen(card(board, in: [.done]))
        case 88..<90:
            return .delete(card(board))
        case 90..<93:
            return .giveInstruction(agent: agent(), text: rng.chance(10) ? "" : "Consigne",
                                    instructionID: freshInstruction(), atHead: rng.chance(50))
        case 93..<96:
            let edits: [CardEdit] = [.title(rng.pick(Self.titles) ?? ""), .details("Détails"), .priority(.high),
                                     .tags(["#x", "X"]), .template(TaskBoardSamples.template(1 + rng.next(below: 4))),
                                     .project(rng.chance(50) ? TaskWorld.site : nil)]
            return .edit(card(board), rng.pick(edits) ?? .details(""))
        case 96:
            if rng.chance(50) {
                return .upsertTemplate(PromptTemplate(id: TaskBoardSamples.template(4),
                                                      name: rng.chance(10) ? "" : "Revue", body: "Relis {titre}"))
            }
            return .deleteTemplate(TaskBoardSamples.template(1 + rng.next(below: 4)))
        case 97:
            // Rare: about one sequence in ten loses an agent.
            guard rng.chance(20) else { return .retry(card(board, in: [.todo])) }
            return .agentRemoved(Self.agents[rng.next(below: Self.agents.count)])
        default:
            // The end of a running card's turn, most of the time with its own prompt id.
            let agent = target(Self.agents.filter { Self.hasCard(of: $0, in: .inProgress, board) })
            return .agentSignal(agent, .turnCommitted(promptID: prompt(of: agent, in: .inProgress, board)))
        }
    }

    /// An agent's item is being delivered (sent, not confirmed).
    static func isDelivering(_ agent: AgentID, _ board: TaskBoardState) -> Bool {
        board.instructions.contains { $0.agentID == agent && $0.delivery != nil }
            || board.cards.contains { $0.column == .todo && $0.assignee == agent && $0.delivery?.isPending == true }
    }

    static func hasCard(of agent: AgentID, in column: Column, _ board: TaskBoardState) -> Bool {
        board.cards.contains { $0.column == column && $0.assignee == agent }
    }

    /// Mostly one of `candidates` (the agents an input makes sense for), else any agent.
    mutating func target(_ candidates: [AgentID]) -> AgentID {
        if rng.chance(85), let agent = rng.pick(candidates) { return agent }
        return agent()
    }

    /// After a failed delivery or an interruption the app pauses the agent's queue until the user acts (3.6).
    static func isPaused(_ agent: AgentID, _ board: TaskBoardState) -> Bool {
        board.cards.contains { card in
            card.assignee == agent && (card.column == .todo && card.flags.contains(.deliveryFailed)
                || card.column == .inProgress && !card.flags.isDisjoint(with: TaskBoardValidator.stoppingFlags))
        }
    }

    /// Mostly what the dispatcher does: the head of a queue with nothing in flight, the queue not paused
    /// (now and then paused all the same). Else noise.
    mutating func deliveryStarted(_ board: TaskBoardState) -> TaskInput {
        let ignorePause = rng.chance(10)
        let ready = Self.agents.filter { agent in
            !TaskWorld.queue(of: agent, in: board).isEmpty && !Self.isDelivering(agent, board)
                && (ignorePause || !Self.isPaused(agent, board))
        }
        // Nothing to deliver: the user gives a waiting card to an agent.
        if ready.isEmpty && rng.chance(70),
           let waiting = rng.pick(board.cards.filter { $0.column == .todo && $0.assignee == nil }) {
            return .assign(waiting.id, to: Self.agents[rng.next(below: Self.agents.count)])
        }
        let agent = target(ready)
        if rng.chance(90), let head = TaskWorld.queue(of: agent, in: board).first {
            return .deliveryStarted(head, agent: agent, sessionID: rng.chance(50) ? "session-1" : "session-2")
        }
        if rng.chance(50), let instruction = rng.pick(board.instructions) {
            return .deliveryStarted(.instruction(instruction.id), agent: agent, sessionID: nil)
        }
        return .deliveryStarted(.card(card(board, in: [.todo])), agent: agent, sessionID: nil)
    }

    /// A signal, mostly from an agent it makes sense for.
    mutating func signal(_ board: TaskBoardState) -> TaskInput {
        let delivering = Self.agents.filter { Self.isDelivering($0, board) }
        let running = Self.agents.filter { Self.hasCard(of: $0, in: .inProgress, board) }
        let reviewing = Self.agents.filter { Self.hasCard(of: $0, in: .review, board) }
        switch rng.next(below: 12) {
        case 0..<4:
            return .agentSignal(target(delivering), .deliveryConfirmed(promptID: rng.chance(10) ? nil : freshPrompt()))
        case 4:
            return .agentSignal(target(delivering), .deliveryFailed(Self.reasons[rng.next(below: Self.reasons.count)]))
        case 5..<8:
            let agent = target(running)
            return .agentSignal(agent, .turnCommitted(promptID: prompt(of: agent, in: .inProgress, board)))
        case 8:
            return .agentSignal(target(running), .turnWaitingBackground)
        case 9:
            let agent = target(reviewing)
            return .agentSignal(agent, .turnReopened(promptID: prompt(of: agent, in: .review, board)))
        case 10:
            return .agentSignal(target(running), .interrupted)
        default:
            let stop = [AgentCardSignal.turnFailed, .sessionLost][rng.next(below: 2)]
            return .agentSignal(target(running + delivering), stop)
        }
    }
}

@Suite struct TaskLifecyclePropertyTests {
    typealias S = TaskBoardSamples
    typealias W = TaskWorld

    private func expectNoViolation(_ invariant: Invariant, sourceLocation: SourceLocation = #_sourceLocation) {
        let found = Simulation.shared.violations[invariant, default: []]
        #expect(found.isEmpty, "\(invariant.rawValue): \(found.joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    @Test func atMostOneRunningCardPerAgent() {
        expectNoViolation(.oneRunningCardPerAgent)
    }

    @Test func queueRankExactlyOnQueuedCards() {
        expectNoViolation(.queueRankExactlyOnQueuedCards)
    }

    @Test func doneCardsNeverHaveAPendingDelivery() {
        expectNoViolation(.doneNeverPending)
    }

    @Test func aCardIsValidatedForTheFirstTimeAtMostOnce() {
        expectNoViolation(.firstValidationOnce)
    }

    @Test func cardsDisappearOnlyWhenDeleted() {
        expectNoViolation(.cardsLeaveOnlyByDelete)
    }

    @Test func assigneesAreAgentsOfTheWorld() {
        expectNoViolation(.assigneesAreKnown)
    }

    @Test func refusalsChangeNothing() {
        expectNoViolation(.refusalChangesNothing)
    }

    @Test func queueKeysAndColumnRanksStayOrdered() {
        expectNoViolation(.keysStayOrdered)
    }

    /// The random sequences really go through the lifecycle, otherwise the invariants above prove little.
    @Test func simulationCoversTheLifecycle() {
        let coverage = Simulation.shared.coverage
        // Every kind of input is accepted now and then…
        let kinds = ["create", "edit", "assign", "unassign", "reorderQueue", "move", "deliveryStarted", "agentSignal",
                     "retry", "continueTask", "putBack", "markForReview", "resend", "validate", "reopen", "delete",
                     "giveInstruction", "agentRemoved", "upsertTemplate", "deleteTemplate"]
        // …every move between columns happens, every flag is set, and so do the side paths.
        let transitions = ["todo->inProgress", "inProgress->review", "review->inProgress", "review->done",
                           "inProgress->done", "todo->done", "inProgress->todo", "review->todo", "done->todo",
                           "firstValidation", "notify", "deleted", "instructionLeft", "refused", "assigned"]
        let flags = CardFlag.allCases.map { "flag \($0)" }
        for key in kinds.map({ "accepted " + $0 }) + transitions + flags {
            #expect(coverage[key, default: 0] >= 5, "\(key): \(coverage[key, default: 0]) in \(coverage)")
        }
    }

    /// Invariant (1), the case named in the plan: a queued card confirmed while another card of the same agent
    /// runs. The running one is marked interrupted; neither moves.
    @Test func confirmingASecondCardInterruptsTheRunningOne() throws {
        let running = TaskCard(id: S.card(1), title: "En cours", projectID: W.api, column: .inProgress, rank: "i",
                               assignee: W.nova,
                               delivery: DeliveryInfo(sessionID: "s", promptID: "p-1", sentAt: S.at(1), confirmedAt: S.at(2)),
                               createdAt: S.at(1), updatedAt: S.at(2))
        let queued = TaskCard(id: S.card(2), title: "En file", projectID: W.api, rank: "i", assignee: W.nova, queueRank: "i",
                              delivery: DeliveryInfo(sessionID: "s", sentAt: S.at(3)), createdAt: S.at(3), updatedAt: S.at(3))
        let board = TaskBoardState(cards: [running, queued])
        let (next, effects) = TaskLifecycle.reduce(board, .agentSignal(W.nova, .deliveryConfirmed(promptID: "p-2")),
                                                   context: W.context(at: 10))
        #expect(effects.isEmpty)
        let first = try #require(next.card(S.card(1)))
        let second = try #require(next.card(S.card(2)))
        #expect(first.column == .inProgress && first.flags == [.interrupted] && first.updatedAt == S.at(10))
        #expect(first.history.last?.kind == .interrupted)
        #expect(second.column == .inProgress && second.flags.isEmpty && second.delivery?.promptID == "p-2")
    }
}
