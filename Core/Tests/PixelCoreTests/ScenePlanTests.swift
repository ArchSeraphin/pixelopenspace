import Foundation
import Testing
@testable import PixelCore

/// Helpers of the scene plan tests: what the app does with a plan, through the public API only.
enum PlanFixtures {
    static let api = ProjectID(SceneFixtures.uuid(0xA1))
    static let nova = AgentID(SceneFixtures.uuid(0xB1))
    static let bip = AgentID(SceneFixtures.uuid(0xB2))

    static func plan(_ scene: SceneInput, _ options: ScenePlanOptions = ScenePlanOptions()) -> WorldScenePlan {
        ScenePlanner.plan(scene, options: options)
    }

    static func id(_ raw: String) -> SceneNodeID { SceneNodeID(raw) }

    /// Every identifier a diff touches.
    static func touched(_ diff: ScenePlanDiff) -> [SceneNodeID] {
        diff.added.map(\.id) + diff.updated.map(\.id) + diff.removed
    }

    /// A character sheet per (look, hue), as the app's atlas holds them.
    final class Sheets: @unchecked Sendable {
        var sheets: [String: CharacterSheet] = [:]

        func def(_ look: AgentLook, hue: Int, _ animation: CharacterAnimation, _ facing: Facing) -> SpriteDef? {
            let key = "\(look)-\(hue)"
            if sheets[key] == nil { sheets[key] = CharacterSprites.sheet(look: look, projectHue: hue) }
            return sheets[key]!.def(animation, facing)
        }
    }

    /// The image a node shows at `tick`: the catalog frame, the frame of the look's sheet, or the composed image.
    static func image(of node: SceneNode, tick: Int, sheets: Sheets) -> PixelImage? {
        switch node.sprite {
        case .sprite(let key, let frame):
            guard let def = SpriteCatalog.sprite(key) else { return nil }
            return def.frames[frame ?? def.frameIndex(atTick: tick + node.tickOffset)]
        case .character(let look, let hue, let animation, let facing):
            guard let def = sheets.def(look, hue: hue, animation, facing) else { return nil }
            return def.frames[def.frameIndex(atTick: tick + node.tickOffset)]
        case .image(let image, _):
            return image
        }
    }

}

@Suite struct ScenePlanTests {
    typealias F = PlanFixtures

    /// The compositor only changed its representation: the golden scenes rendered from their plan keep their
    /// fingerprints, and `render(plan)` is `render(scene, options:)` at every zoom, by day and by night, cropped or not.
    @Test func renderFromPlanIsUnchanged() throws {
        let committed = Dictionary(try GoldenFixture.committed().compactMap(GoldenFixture.split).map { ($0.name, $0.fingerprint) },
                                   uniquingKeysWith: { first, _ in first })
        let crop = Showcase.islandCrop()
        for (index, cast) in Showcase.islandCasts().enumerated() {
            let image = SceneCompositor.render(F.plan(cast, ScenePlanOptions(crop: crop)), tick: 0, zoom: .x1)
            #expect(committed["scene:ilot-\(index + 1)-x1-jour"] == image.fingerprint, "cast \(index + 1)")
        }
        for night in [false, true] {
            let image = SceneCompositor.render(F.plan(Showcase.overview(), ScenePlanOptions(overview: true, night: night)),
                                               tick: 0, zoom: .overview)
            #expect(committed["scene:\(MilestoneExport.overviewName(night: night))"] == image.fingerprint, "night \(night)")
        }

        let slot = GridRect(origin: GridPoint(12, 6), size: GridSize(w: 12, d: 9))
        var cases: [(SceneInput, RenderOptions)] = []
        for cast in Showcase.islandCasts() {
            for zoom in SceneZoom.allCases {
                for night in [false, true] { cases.append((cast, RenderOptions(zoom: zoom, night: night, tick: 7, crop: crop))) }
            }
        }
        for night in [false, true] {
            cases.append((Showcase.overview(), RenderOptions(zoom: .overview, night: night, tick: 13)))
            cases.append((Showcase.overview(), RenderOptions(zoom: .x1, night: night, crop: slot, reduceTransparency: true)))
        }
        for (scene, options) in cases {
            let plan = ScenePlanner.plan(scene, options: ScenePlanOptions(options))
            #expect(SceneCompositor.render(plan, tick: options.tick, zoom: options.zoom)
                    == SceneCompositor.render(scene, options: options), "\(options)")
        }
    }

    /// What the app draws: the background baked once, then the nodes of the wall, world and overlay layers, each
    /// image at its anchor, frames from the catalog and the looks' sheets. By day it is the compositor's image.
    @Test func backgroundPlusNodesEqualsRender() {
        var whole = SceneFixtures.twoDesks().scene
        whole.boardCardHues = (0..<50).map { $0 % 11 }
        let sheets = F.Sheets()
        for (scene, options) in [(Showcase.islandCasts()[0], ScenePlanOptions(crop: Showcase.islandCrop())),
                                 (Showcase.islandCasts()[1], ScenePlanOptions(crop: Showcase.islandCrop())),
                                 (whole, ScenePlanOptions()), (whole, ScenePlanOptions(overview: true))] {
            let plan = F.plan(scene, options)
            #expect(!plan.nodes.contains { [.background, .light, .wallLight].contains($0.layer) }, "by day")
            for tick in [0, 7, 30] {
                var canvas = SceneCompositor.background(plan)
                #expect(canvas.width == plan.canvasWidth && canvas.height == plan.canvasHeight)
                for node in plan.nodes {
                    guard let image = F.image(of: node, tick: tick, sheets: sheets) else {
                        Issue.record("\(node.id): no image")
                        continue
                    }
                    #expect(image.width == node.width && image.height == node.height, "\(node.id)")
                    let origin = plan.canvasOrigin(of: node)
                    canvas.blit(image, x: origin.x, y: origin.y)
                }
                #expect(canvas == SceneCompositor.render(plan, tick: tick, zoom: .x1), "tick \(tick) \(options)")
            }
        }
    }

    @Test func nodeIDsAreUnique() {
        var crowded = Showcase.overview()
        crowded.boardCardHues = (0..<60).map { $0 % 11 }
        var marked = SceneFixtures.twoDesks().scene
        marked.selectedAgent = F.nova
        marked.hovered = .freeDesk(F.api, deskIndex: 2)
        marked.dropTarget = .islandFloor(F.api, part: 0)
        let scenes = Showcase.islandCasts() + [Showcase.overview(), crowded, marked]
        let options = [ScenePlanOptions(), ScenePlanOptions(night: true), ScenePlanOptions(overview: true, night: true),
                       ScenePlanOptions(crop: Showcase.islandCrop()), ScenePlanOptions(reduceMotion: true)]
        for scene in scenes {
            for option in options {
                let plan = F.plan(scene, option)
                let ids = plan.nodes.map(\.id)
                #expect(Set(ids).count == ids.count, "\(option): \(ids.count - Set(ids).count) duplicate(s)")
                for layer in SceneLayer.allCases {
                    let orders = plan.nodes.filter { $0.layer == layer }.map(\.order)
                    #expect(Set(orders).count == orders.count, "\(layer) orders")
                }
                let keys = plan.nodes.map { ($0.layer.rawValue, $0.order) }
                #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }, "sorted by (layer, order)")
                #expect(!plan.nodes.contains { $0.layer == .background })
            }
        }
    }

    /// Nova stops waiting and starts typing: the diff touches only her nodes and those of her post.
    @Test func stateChangeOnlyUpdatesThatAgent() {
        let (workspace, runtimes) = SceneFixtures.twoDeskWorkspace()
        var typing = runtimes
        typing[F.nova] = SceneFixtures.runtime(.working(.edit))
        let before = SceneInput.make(workspace: workspace, runtimes: runtimes, now: SceneFixtures.t0)
        let after = SceneInput.make(workspace: workspace, runtimes: typing, now: SceneFixtures.t0)
        for options in [ScenePlanOptions(), ScenePlanOptions(night: true), ScenePlanOptions(overview: true)] {
            let diff = F.plan(after, options).diff(from: F.plan(before, options))
            #expect(!diff.isEmpty && !diff.backgroundChanged, "\(options)")
            let touched = F.touched(diff)
            let foreign = touched.filter {
                !$0.rawValue.hasPrefix("agent:\(F.nova)/") && !$0.rawValue.hasPrefix("post:\(F.api)/0/")
            }
            #expect(foreign.isEmpty, "\(options): \(foreign)")
            #expect(touched.contains(F.id("agent:\(F.nova)/avatar")))
            #expect(diff.removed.contains(F.id("agent:\(F.nova)/halo")))
        }
    }

    /// A third agent sits at the free desk shown: only additions, that desk's nodes updated (it is taken), and the
    /// newcomer's shadow baked. A fourth one makes the rug grow by a post: two free desks appear, the background is
    /// baked again, and only the island plant moves (it stands on the rug's back-right corner).
    @Test func addingAnAgentMovesNothing() {
        var (workspace, runtimes) = SceneFixtures.twoDeskWorkspace()
        func plan() -> WorldScenePlan {
            F.plan(SceneInput.make(workspace: workspace, runtimes: runtimes, now: SceneFixtures.t0))
        }
        let before = plan()
        let rio = workspace.addAgent(to: F.api, name: "Rio", id: AgentID(SceneFixtures.uuid(0xB3)), now: SceneFixtures.t0)!
        runtimes[rio] = SceneFixtures.runtime(.working(.read))
        let third = plan()
        #expect(third.agentSeats[rio] != nil && before.agentSeats[rio] == nil)
        let diff = third.diff(from: before)
        #expect(diff.removed.isEmpty)
        #expect(diff.updated.allSatisfy { $0.id.rawValue.hasPrefix("post:\(F.api)/2/") }, "\(diff.updated.map(\.id))")
        #expect(diff.updated.contains { $0.id == F.id("post:\(F.api)/2/chair") && $0.target == .agent(rio) })
        #expect(diff.added.contains { $0.id == F.id("agent:\(rio)/avatar") })
        #expect(diff.added.allSatisfy { $0.id.rawValue.hasPrefix("agent:\(rio)/") || $0.id.rawValue.hasPrefix("post:\(F.api)/2/") })
        #expect(diff.backgroundChanged)
        #expect(third.background.floor == before.background.floor && third.background.walls == before.background.walls)
        #expect(third.background.shadows.count == before.background.shadows.count + 1, "Rio's shadow")
        for node in before.nodes {
            #expect(third.node(node.id)?.position == node.position, "\(node.id)")
        }

        let kai = workspace.addAgent(to: F.api, name: "Kai", id: AgentID(SceneFixtures.uuid(0xB4)), now: SceneFixtures.t0)!
        runtimes[kai] = SceneFixtures.runtime(.thinking)
        let fourth = plan()
        let grown = fourth.diff(from: third)
        let plant = F.id("island:\(F.api)/0/plant")
        #expect(grown.removed.isEmpty && grown.backgroundChanged)
        #expect(grown.updated.allSatisfy { $0.id == plant || $0.id.rawValue.hasPrefix("post:\(F.api)/3/") },
                "\(grown.updated.map(\.id))")
        let newPosts = ["post:\(F.api)/3/", "post:\(F.api)/4/", "post:\(F.api)/5/", "agent:\(kai)/"]
        #expect(grown.added.allSatisfy { node in newPosts.contains { node.id.rawValue.hasPrefix($0) } })
        #expect(grown.added.contains { $0.id == F.id("post:\(F.api)/5/chair") && $0.target == .freeDesk(F.api, deskIndex: 5) })
        for node in third.nodes where node.id != plant {
            #expect(fourth.node(node.id)?.position == node.position, "\(node.id)")
        }
    }

    @Test func unchangedInputGivesEmptyDiff() {
        let (workspace, runtimes) = SceneFixtures.twoDeskWorkspace()
        var reversed = workspace
        reversed.agents.reverse()
        reversed.projects.reverse()
        let a = SceneInput.make(workspace: workspace, runtimes: runtimes, now: SceneFixtures.t0)
        let b = SceneInput.make(workspace: reversed, runtimes: runtimes, now: SceneFixtures.t0)
        for scene in [a, Showcase.overview(), Showcase.islandCasts()[1]] {
            for options in [ScenePlanOptions(), ScenePlanOptions(overview: true, night: true)] {
                let first = F.plan(scene, options), second = F.plan(scene, options)
                #expect(first == second)
                #expect(second.diff(from: first).isEmpty)
                let all = first.diff(from: nil)
                #expect(all.added == first.nodes && all.updated.isEmpty && all.removed.isEmpty && all.backgroundChanged)
            }
        }
        #expect(F.plan(b).diff(from: F.plan(a)).isEmpty, "the order of the workspace arrays does not matter")
    }

    /// 3.9: what a click on each node means.
    @Test func targetsFollowTheRules() {
        var scene = Showcase.overview()
        scene.selectedAgent = scene.agents.keys.min()
        scene.dropTarget = .islandFloor(scene.layout.islands[0].projectID, part: 0)
        let plan = F.plan(scene, ScenePlanOptions(night: true))
        var expected: [String: SceneHitTarget?] = [:]
        for island in scene.layout.islands {
            let prefix = "island:\(island.projectID)/\(island.part)/"
            expected[prefix + "sign"] = .islandSign(island.projectID, part: island.part)
            expected[prefix + "plant"] = .islandFloor(island.projectID, part: island.part)
        }
        var checked = 0
        for node in plan.nodes {
            let raw = node.id.rawValue
            checked += 1
            if node.layer == .light || node.layer == .wallLight || raw.contains("/hover/") || raw.contains("/drop/")
                || raw.hasSuffix("/selection") {
                #expect(node.target == nil, "\(raw)")
            } else if raw.hasPrefix("wall:board") {
                #expect(node.target == .corkWall, "\(raw)")
            } else if raw.hasPrefix("wall:elevator") {
                #expect(node.target == .elevator, "\(raw)")
            } else if raw.hasPrefix("hall:") {
                let kind = DecorKind(rawValue: String(raw.dropFirst(5).prefix { $0 != "/" }))
                #expect(kind != nil && node.target == .hallProp(kind!), "\(raw)")
            } else if let target = expected[raw] {
                #expect(node.target == target, "\(raw)")
            } else if raw.hasPrefix("agent:") {
                let agent = scene.agents.keys.first { raw.hasPrefix("agent:\($0)/") }
                #expect(agent != nil && node.target == .agent(agent!), "\(raw)")
            } else if raw.hasPrefix("post:") {
                let desk = scene.layout.islands.lazy.flatMap { island in
                    island.desks.map { (island.projectID, $0) }
                }.first { raw.hasPrefix("post:\($0.0)/\($0.1.index)/") }
                #expect(desk != nil, "\(raw)")
                if let (project, desk) = desk {
                    let target: SceneHitTarget = desk.agentID.map(SceneHitTarget.agent) ?? .freeDesk(project, deskIndex: desk.index)
                    #expect(node.target == target, "\(raw)")
                }
            } else {
                Issue.record("unexpected node \(raw)")
            }
        }
        #expect(checked > 300)
        #expect(plan.nodes.contains { $0.target == .hallProp(.coffeeMachine) })
        #expect(plan.nodes.contains { $0.target == .hallProp(.plantSmall) })
        #expect(plan.nodes.contains { if case .freeDesk = $0.target { return true } else { return false } })
    }

    /// Décision 16, both ways, and the tile tops of `SceneCompositor.imagePoint`.
    @Test func canvasSceneRoundTrip() {
        var rng = SplitMix64(seed: 0x5CE7E)
        let overview = Showcase.overview()
        let crop = GridRect(origin: GridPoint(12, 6), size: GridSize(w: 12, d: 9))
        for plan in [F.plan(overview), F.plan(overview, ScenePlanOptions(crop: crop)), F.plan(SceneFixtures.twoDesks().scene)] {
            for _ in 0..<200 {
                let p = ScenePoint(x: Int.random(in: -4_000...4_000, using: &rng), y: Int.random(in: -4_000...400, using: &rng))
                #expect(plan.scenePoint(plan.canvasPoint(p)) == p)
                let q = PixelPoint(Int.random(in: -500...4_000, using: &rng), Int.random(in: -500...3_000, using: &rng))
                #expect(plan.canvasPoint(plan.scenePoint(q)) == q)
            }
            for tile in plan.rect.tiles where (tile.i + tile.j) % 3 == 0 {
                #expect(plan.canvasPoint(IsoMath.toScene(tile)) == SceneCompositor.imagePoint(of: tile, in: plan.rect))
            }
            let size = SceneCompositor.canvasSize(for: plan.rect)
            #expect(plan.canvasWidth == size.width && plan.canvasHeight == size.height)
            #expect(plan.background.width == size.width && plan.background.height == size.height)
        }
        // The whole world (origin (0, 0), W × D) spans scene x −32·D…32·W and y −16·(W + D)…96.
        let plan = F.plan(overview)
        let (w, d) = (plan.rect.size.w, plan.rect.size.d)
        #expect(plan.rect == overview.layout.bounds)
        #expect(plan.scenePoint(PixelPoint(0, 0)) == ScenePoint(x: -32 * d, y: 96))
        #expect(plan.scenePoint(PixelPoint(plan.canvasWidth, plan.canvasHeight)) == ScenePoint(x: 32 * w, y: -16 * (w + d)))
        // Seats are tile centres in scene texels.
        for island in overview.layout.islands {
            for desk in island.desks {
                guard let agent = desk.agentID else { continue }
                #expect(plan.agentSeats[agent] == IsoMath.tileCenter(desk.seatTile))
            }
        }
        #expect(plan.agentSeats.count == overview.agents.count)
        #expect(plan.islands.map(\.rug) == overview.layout.islands.map(\.rug))
        #expect(plan.islands.map(\.sign) == overview.layout.islands.map(\.sign))
    }

    /// Selection, hover and drop targets draw their marks on the floor, under the furniture, as new nodes only.
    @Test func selectionHoverDropTargetDrawTheirMarks() {
        let (scene, island) = SceneFixtures.twoDesks()
        let desks = island.desks
        #expect(desks.map(\.agentID) == [F.nova, F.bip, nil, nil])
        let base = F.plan(scene)
        var marked = scene
        marked.selectedAgent = F.nova
        marked.hovered = .freeDesk(F.api, deskIndex: 2)
        marked.dropTarget = .agent(F.bip)
        let plan = F.plan(marked)
        let diff = plan.diff(from: base)
        #expect(diff.updated.isEmpty && diff.removed.isEmpty && !diff.backgroundChanged)
        let expected: [(String, SpriteKey, GridPoint)] = [
            ("agent:\(F.nova)/selection", SpriteKey("ov.selection"), desks[0].seatTile),
            ("post:\(F.api)/2/hover/desk", SpriteKey("floor.hover"), desks[2].deskTile),
            ("post:\(F.api)/2/hover/seat", SpriteKey("floor.hover"), desks[2].seatTile),
            ("post:\(F.api)/1/drop/seat", SpriteKey("floor.dropTarget"), desks[1].seatTile),
        ]
        #expect(Set(diff.added.map(\.id)) == Set(expected.map { F.id($0.0) }))
        let firstObject = plan.nodes.filter { $0.layer == .world && !diff.added.map(\.id).contains($0.id) }.map(\.order).min()!
        for (raw, key, tile) in expected {
            let node = plan.node(F.id(raw))
            #expect(node?.sprite == .sprite(key, frame: nil), "\(raw)")
            #expect(node?.position == IsoMath.tileCenter(tile) && node?.tile == tile, "\(raw)")
            #expect(node?.layer == .world && node?.target == nil, "\(raw)")
            #expect(node.map { $0.order < firstObject } == true, "\(raw): under the furniture")
        }
        #expect(SceneCompositor.render(plan, tick: 0, zoom: .x1) != SceneCompositor.render(base, tick: 0, zoom: .x1))

        // A hovered agent shows its name plate (Bip, typing, has none otherwise).
        #expect(base.node(F.id("agent:\(F.bip)/nameplate")) == nil)
        marked.hovered = .agent(F.bip)
        let hovered = F.plan(marked).node(F.id("agent:\(F.bip)/nameplate"))
        #expect(hovered?.sprite == .image(HUDSprites.nameplate("Bip", off: false), name: "nameplate:Bip"))
        #expect(hovered?.layer == .overlay && hovered?.target == .agent(F.bip))

        // Dropping on a free desk marks its desk and seat; on the island, every tile of its rug.
        marked.dropTarget = .freeDesk(F.api, deskIndex: 3)
        let free = F.plan(marked)
        for (part, tile) in [("desk", desks[3].deskTile), ("seat", desks[3].seatTile)] {
            let node = free.node(F.id("post:\(F.api)/3/drop/\(part)"))
            #expect(node?.sprite == .sprite(SpriteKey("floor.dropTarget"), frame: nil) && node?.tile == tile)
        }
        for target in [SceneHitTarget.islandFloor(F.api, part: 0), .islandSign(F.api, part: 0)] {
            marked.dropTarget = target
            let rug = F.plan(marked).nodes.filter { $0.id.rawValue.hasPrefix("island:\(F.api)/0/hover/") }
            #expect(rug.compactMap(\.tile).sorted() == island.rug.tiles, "\(target)")
            #expect(rug.allSatisfy { $0.sprite == .sprite(SpriteKey("floor.hover"), frame: nil) && $0.target == nil })
        }
        // A hovered desk that is taken draws nothing.
        marked.dropTarget = nil
        marked.hovered = .freeDesk(F.api, deskIndex: 0)
        #expect(!F.plan(marked).nodes.contains { $0.id.rawValue.contains("/hover/") })
    }

    /// An agent walking from the elevator: its post keeps only an empty chair; no avatar, shadow, mini, overlay or
    /// plate of its own, even selected; its seat is still known.
    @Test func hiddenAgentLeavesOnlyItsChair() {
        let (scene, island) = SceneFixtures.twoDesks()
        let seat = island.desks[0].seatTile
        let base = F.plan(scene)
        var hidden = scene
        hidden.hiddenAgents = [F.nova, F.bip]
        hidden.selectedAgent = F.nova
        let plan = F.plan(hidden)
        #expect(!plan.nodes.contains { $0.id.rawValue.hasPrefix("agent:") })
        #expect(plan.nodes.filter { $0.tile == seat }.map(\.id) == [F.id("post:\(F.api)/0/chair")])
        #expect(plan.node(F.id("post:\(F.api)/0/desk")) != nil && plan.node(F.id("post:\(F.api)/0/queue")) != nil)
        #expect(plan.agentSeats[F.nova] == IsoMath.tileCenter(seat))
        let shadowChar = SpriteKey("shadow.char")
        #expect(base.background.shadows.filter { $0.key == shadowChar }.count == 2)
        #expect(!plan.background.shadows.contains { $0.key == shadowChar })
        #expect(plan.background.shadows.count == base.background.shadows.count - 2)
        let diff = plan.diff(from: base)
        #expect(diff.backgroundChanged && diff.added.isEmpty)
        // Only Nova's and Bip's own nodes go, and their chairs change.
        #expect(diff.removed.allSatisfy { $0.rawValue.hasPrefix("agent:\(F.nova)/") || $0.rawValue.hasPrefix("agent:\(F.bip)/") })
        #expect(diff.updated.allSatisfy { $0.id.rawValue.hasSuffix("/chair") })
    }

    /// 7.9, Reduce Motion: the XL "!" at ×1 too, no halo, every overlay and floor mark on its frame 0.
    @Test func reduceMotionUsesXLBangOnFrameZero() {
        var scene = SceneFixtures.twoDesks().scene
        scene.selectedAgent = F.bip
        scene.dropTarget = .freeDesk(F.api, deskIndex: 2)
        let moving = F.plan(scene)
        #expect(moving.node(F.id("agent:\(F.nova)/overlay"))?.sprite == .sprite(SpriteKey("ov.bang"), frame: nil))
        #expect(moving.node(F.id("agent:\(F.nova)/halo")) != nil)
        let calm = F.plan(scene, ScenePlanOptions(reduceMotion: true))
        #expect(calm.node(F.id("agent:\(F.nova)/overlay"))?.sprite == .sprite(SpriteKey("ov.bang", variant: "xl"), frame: 0))
        #expect(calm.node(F.id("agent:\(F.nova)/halo")) == nil)
        let marks = calm.nodes.filter { $0.layer == .overlay || $0.id.rawValue.contains("/drop/") || $0.id.rawValue.hasSuffix("/selection") }
        #expect(marks.count >= 6)
        for node in marks {
            if case .sprite(_, let frame) = node.sprite { #expect(frame == 0, "\(node.id)") }
        }
        // Reduce Motion in the presenter too: no halo there either.
        let (workspace, runtimes) = SceneFixtures.twoDeskWorkspace()
        let made = SceneInput.make(workspace: workspace, runtimes: runtimes, now: SceneFixtures.t0, reduceMotion: true)
        #expect(made.agents[F.nova]?.presentation.halo == false)
    }

    /// The cork wall, its cards, the elevator and its LED are nodes of the wall layer, at the place the wall pass
    /// drew them; the rest of the wall is baked. A crop has no wall at all.
    @Test func elevatorAndCorkWallAreNodes() {
        var scene = Showcase.overview()
        let plan = F.plan(scene, ScenePlanOptions(overview: true))
        let board = plan.node(F.id("wall:board"))
        #expect(board?.sprite == .sprite(SpriteKey("board.cork", facing: .ne), frame: nil))
        #expect(board?.layer == .wall && board?.tile == GridPoint(1, 0))
        for (k, hue) in scene.boardCardHues.enumerated() {
            let card = plan.node(F.id("wall:board/card/\(k)"))
            let variant = hue == SceneInput.paperHue ? "paper" : "hue\(hue)"
            #expect(card?.sprite == .sprite(SpriteKey("postit.mini", variant: variant, facing: .ne), frame: nil), "card \(k)")
            #expect(card?.layer == .wall)
        }
        let elevator = plan.node(F.id("wall:elevator"))
        #expect(elevator?.sprite == .sprite(SpriteKey("elevator", facing: .nw), frame: 0) && elevator?.layer == .wall)
        #expect(plan.node(F.id("wall:elevator/led"))?.sprite == .sprite(SpriteKey("elevator.led"), frame: nil))
        let wallNodes = plan.nodes.filter { $0.layer == .wall }
        #expect(wallNodes.count == 3 + scene.boardCardHues.count)
        let baked = Set(plan.background.walls.map(\.key.id))
        #expect(baked == ["wall.segment", "wall.window", "wall.corner"])
        #expect(plan.background.walls.last?.key == SpriteKey("wall.corner"))

        // Beyond 48 cards, the counter.
        scene.boardCardHues = (0..<53).map { $0 % 11 }
        let crowded = F.plan(scene)
        #expect(crowded.nodes.filter { $0.id.rawValue.hasPrefix("wall:board/card/") }.count == 48)
        let more = crowded.node(F.id("wall:board/more"))
        #expect(more?.sprite == .image(HUDSprites.nameplate("+5", off: false), name: "nameplate:+5"))
        #expect(more?.layer == .overlay && more?.target == .corkWall)

        // At night: the LED's light and the stars of the windows.
        let night = F.plan(scene, ScenePlanOptions(night: true))
        #expect(night.node(F.id("wall:elevator/led/light"))?.layer == .wallLight)
        #expect(night.nodes.contains { $0.layer == .wallLight && $0.id.rawValue.contains("/star/") })
        #expect(Set(night.background.walls.filter { $0.key.id == "wall.window" }.map(\.key.variant)) == ["night"])

        let cropped = F.plan(scene, ScenePlanOptions(crop: Showcase.islandCrop()))
        #expect(!cropped.nodes.contains { $0.id.rawValue.hasPrefix("wall:") } && cropped.background.walls.isEmpty)
    }

    /// The lights of the back walls come already clipped by what stands in front of them: a plain (animated) sprite
    /// when nothing of the world covers any of its pixels, else its frame 0 without the covered pixels, or nothing
    /// when all are covered (the overview's big signs cover windows); the lights of a desk are clipped images too.
    @Test func wallLightsComeClippedByTheWorld() {
        let plan = F.plan(Showcase.overview(), ScenePlanOptions(overview: true, night: true))
        let sheets = F.Sheets()
        let world = plan.nodes.filter { $0.layer == .world }
        /// Whether a world node is opaque at canvas (x, y) at `tick`.
        func covered(_ x: Int, _ y: Int, tick: Int) -> Bool {
            world.contains { node in
                let o = plan.canvasOrigin(of: node)
                let (lx, ly) = (x - o.x, y - o.y)
                guard lx >= 0, ly >= 0, lx < node.width, ly < node.height,
                      let frame = F.image(of: node, tick: tick, sheets: sheets) else { return false }
                return frame[lx, ly].a != 0
            }
        }
        var plain = 0, clipped = 0
        let lights = plan.nodes.filter { $0.layer == .wallLight }
        for light in lights {
            let origin = plan.canvasOrigin(of: light)
            switch light.sprite {
            case .sprite(let key, _):
                plain += 1
                for tick in [0, 12, 24, 36] {
                    let frame = SpriteCatalog.sprite(key)!
                    let image = frame.frames[frame.frameIndex(atTick: tick)]
                    for y in 0..<image.height {
                        for x in 0..<image.width where image[x, y].a != 0 {
                            #expect(!covered(origin.x + x, origin.y + y, tick: tick), "\(light.id) at (\(x), \(y))")
                        }
                    }
                }
            case .image(let image, _):
                clipped += 1
                var kept = 0
                for y in 0..<image.height {
                    for x in 0..<image.width where image[x, y].a != 0 {
                        kept += 1
                        #expect(!covered(origin.x + x, origin.y + y, tick: 0), "\(light.id) at (\(x), \(y))")
                    }
                }
                #expect(kept > 0, "\(light.id): nothing left, left out")
            case .character:
                Issue.record("\(light.id): a character as a light")
            }
        }
        // Three stars per night window and the LED's light; the ones the world hides entirely are left out.
        let windows = plan.background.walls.filter { $0.key.id == "wall.window" }.count
        let omitted = 3 * windows + 1 - lights.count
        #expect(plain > 10 && clipped + omitted > 0, "plain \(plain), clipped \(clipped), omitted \(omitted)")
        for light in plan.nodes where light.layer == .light {
            guard case .image(_, let name) = light.sprite else {
                Issue.record("\(light.id): not clipped")
                continue
            }
            #expect(["light.cone#0", "light.screenGlow#0"].contains(name), "\(light.id)")
        }
    }

    /// Orders are keys inside the range of their layer: `zOrder` sorts a whole plan back to front and stays exact
    /// as a Float (SpriteKit's zPosition).
    @Test func ordersFitTheirLayers() {
        let bases: [Int] = [0, 1_024, 263_168, 4_457_472, 4_719_616, 5_243_904]   // 2^10, + 2^18, + 2^22, + 2^18, + 2^19
        #expect(SceneLayer.allCases.map(\.zBase) == bases)
        #expect(SceneLayer.overlay.zBase + SceneLayer.overlay.orderLimit <= 1 << 23)
        var crowded = Showcase.overview()
        crowded.boardCardHues = (0..<60).map { $0 % 11 }
        crowded.selectedAgent = crowded.agents.keys.min()
        crowded.dropTarget = .islandFloor(crowded.layout.islands[0].projectID, part: 0)
        for options in [ScenePlanOptions(), ScenePlanOptions(night: true), ScenePlanOptions(overview: true, night: true)] {
            let plan = F.plan(crowded, options)
            for node in plan.nodes {
                #expect((0..<node.layer.orderLimit).contains(node.order), "\(node.id): \(node.order)")
            }
            let z = plan.nodes.map(\.zOrder)
            #expect(zip(z, z.dropFirst()).allSatisfy { $0 < $1 })
            #expect(z.allSatisfy { Int(Float($0)) == $0 })
        }
    }

    /// Positions are scene texels: a node of a crop is the very node of the whole world.
    @Test func positionsDoNotDependOnTheCrop() {
        var scene = Showcase.overview()
        scene.selectedAgent = scene.agents.keys.min()
        let crop = GridRect(origin: GridPoint(12, 6), size: GridSize(w: 12, d: 9))
        for options in [ScenePlanOptions(), ScenePlanOptions(night: true)] {
            let whole = F.plan(scene, options)
            var cropOptions = options
            cropOptions.crop = crop
            let cropped = F.plan(scene, cropOptions)
            #expect(cropped.nodes.count > 40)
            let byID = Dictionary(uniqueKeysWithValues: whole.nodes.map { ($0.id, $0) })
            for node in cropped.nodes {
                #expect(byID[node.id] == node, "\(node.id)")
            }
            #expect(cropped.agentSeats.allSatisfy { whole.agentSeats[$0.key] == $0.value })
        }
    }

    /// A wall piece drawn over a node in the order of the wall pass (a segment across the cork wall, in a layout
    /// written for the test) is a node too, after the cork wall and its cards; the others stay baked.
    @Test func wallPieceOverANodeIsANode() {
        var scene = SceneFixtures.twoDesks().scene
        scene.boardCardHues = [1, 2, 3]
        let board = scene.layout.walls.firstIndex { $0.piece == .board }!
        scene.layout.walls.insert(WallPlacement(wall: .ne, start: 3, span: 1, piece: .segment(.plain)), at: board + 1)
        let plan = F.plan(scene)
        let segment = plan.node(F.id("wall:ne/3"))
        #expect(segment?.layer == .wall && segment?.target == nil && segment?.tile == GridPoint(3, 0))
        #expect(segment?.sprite == .sprite(SpriteKey("wall.segment", variant: "plain", facing: .ne), frame: 0))
        let cork = plan.nodes.filter { $0.id.rawValue.hasPrefix("wall:board") }
        #expect(cork.count == 4 && cork.allSatisfy { $0.order < (segment?.order ?? 0) })
        #expect(!plan.background.walls.contains { $0.tile == GridPoint(3, 0) })
        #expect(plan.background.walls.contains { $0.tile == GridPoint(7, 0) })
        // Where the segment and the cork wall overlap, the segment shows.
        let image = SceneCompositor.render(plan, tick: 0, zoom: .x1)
        let piece = SpriteCatalog.sprite(SpriteKey("wall.segment", variant: "plain", facing: .ne))!.frames[0]
        let corkImage = SpriteCatalog.sprite(SpriteKey("board.cork", facing: .ne))!.frames[0]
        guard let segment, let corkNode = plan.node(F.id("wall:board")) else { return }
        let o = plan.canvasOrigin(of: segment), b = plan.canvasOrigin(of: corkNode)
        var overlap = 0
        for y in 0..<piece.height {
            for x in 0..<piece.width where piece[x, y].a != 0 {
                let (bx, by) = (o.x + x - b.x, o.y + y - b.y)
                guard bx >= 0, by >= 0, bx < corkImage.width, by < corkImage.height, corkImage[bx, by].a != 0 else { continue }
                overlap += 1
                #expect(image[o.x + x, o.y + y] == piece[x, y])
            }
        }
        #expect(overlap > 100)
    }
}
