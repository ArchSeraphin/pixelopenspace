import Foundation
import Testing
@testable import PixelCore

/// Seeded random edits of a real workspace (WorkspaceOps), checked after every step (3.8: append-only layout).
@Suite struct WorldLayoutPropertyTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_845_200)
    static let runs = 200
    static let steps = 60
    /// Past 8 agents a project opens annexes (parts 1 and 2), whose slots are persisted (workspace v2).
    static let maxAgentsPerProject = 20

    /// Each run: the workspace before the first operation, then after each of the 60 operations.
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
            case 0..<15:
                w.addProject(path: "/p/\(counter)", id: ProjectID(uuid(&rng)), now: t0)
            case 15..<70:
                // Half the time the first open island, so that some projects fill their annexes.
                let open = live.filter { w.agents(in: $0.id).count < maxAgentsPerProject }
                let project = rng.next() % 2 == 0 ? open.first : pick(open, &rng)
                if let project {
                    w.addAgent(to: project.id, name: "A\(counter)", id: AgentID(uuid(&rng)), now: t0)
                }
            case 70..<85:
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
        // Annexes open, fill and open the next part; some go with an archived project.
        let all = Self.histories.flatMap { $0 }
        #expect(all.contains { w in w.projects.contains { !$0.archived && $0.annexSlots.count >= 2 } })
        #expect(finals.filter { w in w.projects.contains { !$0.archived && !$0.annexSlots.isEmpty } }.count >= Self.runs / 10)
        #expect(all.contains { w in w.agents.contains { $0.deskIndex >= 16 } })
        #expect(Self.histories.contains { history in
            zip(history, history.dropFirst()).contains { before, after in
                before.projects.contains { p in !p.archived && !p.annexSlots.isEmpty
                    && after.project(p.id)?.archived == true }
            }
        })
    }

    /// Every annex of a history sits in its persisted slot (no fallback), and the slots of the live projects, main
    /// and annexes, are all different.
    @Test func annexesSitInTheirPersistedSlots() {
        for (run, history) in Self.histories.enumerated() {
            for (step, workspace) in history.enumerated() {
                let layout = WorldLayout.compute(WorldInput(workspace: workspace))
                var problems: [String] = []
                for island in layout.islands where island.part > 0 {
                    let slots = workspace.project(island.projectID)?.annexSlots ?? []
                    if island.part > slots.count || slots[island.part - 1] != island.slot {
                        problems.append("annex \(island.part) at \(island.slot), persisted \(slots)")
                    }
                }
                let live = workspace.projects.filter { !$0.archived }
                let held = live.flatMap { [$0.slot] + $0.annexSlots }
                if Set(held).count != held.count { problems.append("slot held twice: \(held.sorted())") }
                if Set(held) != workspace.usedSlots { problems.append("usedSlots") }
                #expect(problems.isEmpty, "run \(run), step \(step): \(problems)")
            }
        }
    }

    /// Main islands and annexes alike (keyed by project and part): adding a project or an agent, removing an agent
    /// or archiving a project never moves one that stays.
    @Test func noIslandEverMoves() {
        var annexesCompared = 0
        for (run, history) in Self.histories.enumerated() {
            let layouts = Self.layouts(history)
            for step in 1..<layouts.count {
                let before = Self.islands(layouts[step - 1])
                let after = Self.islands(layouts[step])
                annexesCompared += before.filter { $0.value.part > 0 && after[$0.key] != nil }.count
                let moved = before.keys.sorted().filter { key in
                    guard let island = after[key] else { return false }
                    return island.origin != before[key]!.origin || island.slot != before[key]!.slot
                        || island.sign != before[key]!.sign || island.rug.origin != before[key]!.rug.origin
                }
                #expect(moved.isEmpty, "run \(run), step \(step): \(moved)")
            }
        }
        #expect(annexesCompared > 500, "annexes really stay through the histories: \(annexesCompared)")
    }

    /// The slot of an island, computed here from the 12×9 pitch below the 6-tile hall (not from the layout).
    static func slotRect(_ slot: Int) -> GridRect {
        let (column, row) = WorldLayout.slotCoordinates(slot)
        return GridRect(origin: GridPoint(12 * column, 6 + 9 * row), size: GridSize(w: 12, d: 9))
    }

    /// Décision 3: a grown rug stays in its own slot, inside the island's reserved tiles (so the corridor ring
    /// between slots stays bare), and never reaches the hall or another island.
    @Test func rugNeverLeavesItsSlot() {
        for (run, history) in Self.histories.enumerated() {
            for (step, layout) in Self.layouts(history).enumerated() {
                var problems: [String] = []
                for (n, island) in layout.islands.enumerated() {
                    let name = "island \(island.slot).\(island.part)"
                    let slot = Self.slotRect(island.slot)
                    let inner = GridRect(origin: slot.origin + GridPoint(1, 1), size: GridSize(w: 10, d: 7))
                    if !slot.contains(island.rug) { problems.append("\(name): rug \(island.rug) outside its slot") }
                    if !inner.contains(island.rug) { problems.append("\(name): rug \(island.rug) on the corridor ring") }
                    if !island.rect.contains(island.rug) { problems.append("\(name): rug outside the island") }
                    if island.rug.intersects(layout.hall) { problems.append("\(name): rug in the hall") }
                    for other in layout.islands where other != island && island.rug.intersects(other.rect) {
                        problems.append("\(name): rug over island \(other.slot).\(other.part)")
                    }
                    for other in layout.islands[(n + 1)...] where island.rug.intersects(other.rug) {
                        problems.append("\(name): rug over the rug of island \(other.slot).\(other.part)")
                    }
                }
                #expect(problems.isEmpty, "run \(run), step \(step): \(problems)")
            }
        }
    }

    /// Décision 3: the rug carries every desk drawn (desk, seat and side tile), the sign and the plant; it fits the
    /// occupied desks plus the next free one, by whole posts, with no empty post beyond them.
    @Test func rugCoversEveryDesk() {
        for (run, history) in Self.histories.enumerated() {
            for (step, layout) in Self.layouts(history).enumerated() {
                var problems: [String] = []
                for island in layout.islands {
                    let name = "island \(island.slot).\(island.part)"
                    var own = [island.sign, island.plant]
                    for desk in island.desks { own += [desk.deskTile, desk.seatTile, desk.sideTile] }
                    for tile in own where !island.rug.contains(tile) { problems.append("\(name): \(tile) off the rug") }
                    // A one-tile margin around the furniture: the aisle behind row B, the front border, one column
                    // before the first desk and one after the last side tile.
                    let lastPost = island.desks.map(\.post).max() ?? 0
                    let fitted = GridRect(origin: island.origin + GridPoint(0, 1), size: GridSize(w: 2 * lastPost + 4, d: 6))
                    if island.rug != fitted { problems.append("\(name): rug \(island.rug) for \(lastPost + 1) post(s)") }
                    // The last post holds an agent or the lowest free desk; a free desk shows while the part has room.
                    let free = island.desks.filter { $0.agentID == nil }.map(\.index)
                    let seated = island.desks.filter { $0.agentID != nil }
                    let lastHasReason = island.desks.contains { $0.post == lastPost && ($0.agentID != nil || $0.index == free.min()) }
                    if !lastHasReason { problems.append("\(name): empty post \(lastPost) on the rug") }
                    if seated.count < 8 && free.isEmpty { problems.append("\(name): no free desk") }
                    if island.desks.map(\.index) != island.desks.map(\.index).sorted() { problems.append("\(name): desk order") }
                }
                #expect(problems.isEmpty, "run \(run), step \(step): \(problems)")
            }
        }
    }

    /// Décision 3: the rug grows when an agent arrives (and never shrinks while nobody leaves), from the same origin.
    @Test func rugGrowsWithItsAgents() {
        var grew = 0
        for (run, history) in Self.histories.enumerated() {
            let layouts = Self.layouts(history)
            for step in 1..<layouts.count {
                let before = Self.islands(layouts[step - 1])
                let after = Self.islands(layouts[step])
                for (key, old) in before {
                    guard let new = after[key] else { continue }
                    let oldAgents = Set(old.desks.compactMap(\.agentID)), newAgents = Set(new.desks.compactMap(\.agentID))
                    guard newAgents.isSuperset(of: oldAgents) else { continue }
                    #expect(new.rug.contains(old.rug) && new.rug.origin == old.rug.origin,
                            "run \(run), step \(step), \(key): \(old.rug) → \(new.rug)")
                    if new.rug.size.w > old.rug.size.w { grew += 1 }
                }
            }
        }
        #expect(grew > 50, "rugs really grow in the histories")
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
            let slot = slotRect(island.slot)
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
