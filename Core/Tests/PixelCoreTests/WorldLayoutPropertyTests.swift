import Foundation
import Testing
@testable import PixelCore

/// Seeded random edits of a real workspace (WorkspaceOps), checked after every step (3.8: append-only layout).
@Suite struct WorldLayoutPropertyTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_845_200)
    static let runs = 200
    static let steps = 40
    static let maxAgentsPerProject = 7

    /// Each run: the workspace before the first operation, then after each of the 40 operations.
    static let histories: [[Workspace]] = (0..<UInt64(runs)).map { history(seed: 0x5EED_0000 + $0) }

    static func uuid(_ rng: inout SplitMix64) -> UUID {
        let a = rng.next()
        let b = rng.next()
        func byte(_ v: UInt64, _ k: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: v >> (8 * k)) }
        return UUID(uuid: (byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6), byte(a, 7),
                           byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)))
    }

    static func pick<T>(_ items: [T], _ rng: inout SplitMix64) -> T? {
        items.isEmpty ? nil : items[Int(rng.next() % UInt64(items.count))]
    }

    static func history(seed: UInt64) -> [Workspace] {
        var rng = SplitMix64(seed: seed)
        var w = Workspace()
        var states = [w]
        var counter = 0
        for _ in 0..<steps {
            counter += 1
            let live = w.projects.filter { !$0.archived }.sorted { $0.slot < $1.slot }
            switch rng.next() % 100 {
            case 0..<20:
                w.addProject(path: "/p/\(counter)", id: ProjectID(uuid(&rng)), now: t0)
            case 20..<65:
                let open = live.filter { w.agents(in: $0.id).count < maxAgentsPerProject }
                if let project = pick(open, &rng) {
                    w.addAgent(to: project.id, name: "A\(counter)", id: AgentID(uuid(&rng)), now: t0)
                }
            case 65..<85:
                if let agent = pick(w.agents.sorted { $0.id < $1.id }, &rng) { w.removeAgent(agent.id) }
            default:
                if let project = pick(live, &rng) { w.archiveProject(project.id) }
            }
            states.append(w)
        }
        return states
    }

    static func layouts(_ history: [Workspace]) -> [WorldLayoutResult] {
        history.map { WorldLayout.compute(WorldInput(workspace: $0)) }
    }

    /// Islands keyed by project and part.
    static func islands(_ layout: WorldLayoutResult) -> [String: IslandPlacement] {
        Dictionary(uniqueKeysWithValues: layout.islands.map { ("\($0.projectID)#\($0.part)", $0) })
    }

    /// Desks keyed by their agent (`noOverlapAndInsideBounds` checks that nobody is seated twice).
    static func desks(_ layout: WorldLayoutResult) -> [AgentID: DeskPlacement] {
        var out: [AgentID: DeskPlacement] = [:]
        for desk in layout.islands.flatMap(\.desks) {
            guard let id = desk.agentID else { continue }
            out[id] = desk
        }
        return out
    }

    @Test func historiesExerciseEveryOperation() {
        // The generator really adds, removes and archives, and fills islands past 4 desks.
        let finals = Self.histories.map { $0.last! }
        #expect(finals.contains { $0.projects.contains(where: \.archived) })
        #expect(finals.contains { w in w.projects.contains { p in !p.archived && w.agents(in: p.id).count >= 4 } })
        #expect(finals.map { $0.projects.count }.max()! >= 6)
    }

    @Test func noIslandEverMoves() {
        for (run, history) in Self.histories.enumerated() {
            let layouts = Self.layouts(history)
            for step in 1..<layouts.count {
                let before = Self.islands(layouts[step - 1])
                let after = Self.islands(layouts[step])
                let moved = before.keys.sorted().filter { key in
                    guard let island = after[key] else { return false }
                    return island.origin != before[key]!.origin || island.slot != before[key]!.slot
                        || island.sign != before[key]!.sign
                }
                #expect(moved.isEmpty, "run \(run), step \(step): \(moved)")
            }
        }
    }

    @Test func existingDesksNeverMove() {
        for (run, history) in Self.histories.enumerated() {
            let layouts = Self.layouts(history)
            for step in 1..<layouts.count {
                let before = Self.desks(layouts[step - 1])
                let after = Self.desks(layouts[step])
                let moved = before.keys.sorted().filter { id in after[id].map { $0 != before[id]! } ?? false }
                #expect(moved.isEmpty, "run \(run), step \(step): \(moved)")
            }
        }
    }

    @Test func noOverlapAndInsideBounds() {
        for (run, history) in Self.histories.enumerated() {
            for (step, workspace) in history.enumerated() {
                let layout = WorldLayout.compute(WorldInput(workspace: workspace))
                let problems = Self.placementProblems(layout, workspace: workspace)
                #expect(problems.isEmpty, "run \(run), step \(step): \(problems)")
            }
        }
    }

    /// Every broken invariant of one layout, as text (one `#expect` per layout keeps the suite fast).
    static func placementProblems(_ layout: WorldLayoutResult, workspace: Workspace) -> [String] {
        var problems: [String] = []
        if !layout.bounds.contains(layout.hall) { problems.append("hall outside the bounds") }
        for prop in layout.props where !layout.hall.contains(prop.tile) { problems.append("hall prop at \(prop.tile)") }
        var tiles = Set<GridPoint>()
        for (n, island) in layout.islands.enumerated() {
            let name = "island \(island.slot).\(island.part)"
            let (column, row) = WorldLayout.slotCoordinates(island.slot)
            let slot = GridRect(origin: GridPoint(12 * column, 6 + 9 * row), size: GridSize(w: 12, d: 9))
            if !slot.contains(island.rect) { problems.append("\(name) outside its slot") }
            if !layout.bounds.contains(island.rect) { problems.append("\(name) outside the bounds") }
            if island.rect.intersects(layout.hall) { problems.append("\(name) in the hall") }
            for other in layout.islands[(n + 1)...] where island.rect.intersects(other.rect) {
                problems.append("\(name) overlaps island \(other.slot).\(other.part)")
            }
            var own = [island.sign, island.plant]
            for desk in island.desks { own += [desk.deskTile, desk.seatTile, desk.sideTile] }
            for tile in own {
                if !island.rect.contains(tile) { problems.append("\(name): \(tile) outside the island") }
                if !tiles.insert(tile).inserted { problems.append("\(name): \(tile) used twice") }
            }
        }
        // Every agent of a live project has exactly one desk; no other agent has one.
        let live = Set(workspace.projects.filter { !$0.archived }.map(\.id))
        let expected = Set(workspace.agents.filter { live.contains($0.projectID) }.map(\.id))
        let seated = layout.islands.flatMap(\.desks).compactMap(\.agentID)
        if Set(seated) != expected || seated.count != expected.count { problems.append("seated agents") }
        // Every corridor is a slot of the bounds.
        for corridor in layout.corridors where !layout.bounds.contains(corridor) {
            problems.append("corridor \(corridor) outside the bounds")
        }
        return problems
    }

    @Test func deterministic() {
        var rng = SplitMix64(seed: 99)
        for history in Self.histories {
            for workspace in history where !workspace.projects.isEmpty {
                let input = WorldInput(workspace: workspace)
                let reference = WorldLayout.compute(input)
                #expect(WorldLayout.compute(input) == reference)
                let shuffled = WorldInput(projects: workspace.projects.shuffled(using: &rng),
                                          agents: workspace.agents.shuffled(using: &rng))
                #expect(WorldLayout.compute(shuffled) == reference)
            }
        }
    }
}
