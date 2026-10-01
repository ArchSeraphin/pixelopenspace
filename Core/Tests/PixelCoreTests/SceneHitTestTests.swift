import Foundation
import Testing
@testable import PixelCore

/// Helpers of the hit-test tests: the targets a plan paints, pixel by pixel, the way the app draws it (back to front,
/// the last opaque node with a target wins), through the public API only.
enum HitFixtures {
    /// For each canvas pixel (y·width + x), the index in `plan.nodes` of the last node with a target whose image is
    /// opaque there at `tick`; -1 where none is.
    static func paintedTargets(_ plan: WorldScenePlan, tick: Int, sheets: PlanFixtures.Sheets) -> [Int] {
        var owners = Array(repeating: -1, count: plan.canvasWidth * plan.canvasHeight)
        for (index, node) in plan.nodes.enumerated() where node.target != nil {
            guard let image = PlanFixtures.image(of: node, tick: tick, sheets: sheets) else { continue }
            let origin = plan.canvasOrigin(of: node)
            for y in 0..<image.height {
                for x in 0..<image.width where image[x, y].a != 0 {
                    let (cx, cy) = (origin.x + x, origin.y + y)
                    guard cx >= 0, cy >= 0, cx < plan.canvasWidth, cy < plan.canvasHeight else { continue }
                    owners[cy * plan.canvasWidth + cx] = index
                }
            }
        }
        return owners
    }

    /// The scene point at the centre of a canvas texel.
    static func center(_ pixel: PixelPoint, in plan: WorldScenePlan) -> SceneVector {
        let p = plan.scenePoint(pixel)
        return SceneVector(Double(p.x) + 0.5, Double(p.y) - 0.5)
    }

    /// The tile under a scene point (`IsoMath.toGrid`, floored).
    static func tile(at point: SceneVector) -> GridPoint {
        let grid = IsoMath.toGrid(x: point.x, y: point.y)
        return GridPoint(Int(grid.i.rounded(.down)), Int(grid.j.rounded(.down)))
    }

    /// Canvas pixels where `node` is the topmost painted target.
    static func pixels(where nodeID: SceneNodeID, isOnTopIn plan: WorldScenePlan, owners: [Int]) -> [PixelPoint] {
        guard let index = plan.nodes.firstIndex(where: { $0.id == nodeID }) else { return [] }
        var out: [PixelPoint] = []
        for (offset, owner) in owners.enumerated() where owner == index {
            out.append(PixelPoint(offset % plan.canvasWidth, offset / plan.canvasWidth))
        }
        return out
    }
}

@Suite struct SceneHitTestTests {
    typealias F = PlanFixtures
    typealias H = HitFixtures

    static func twoDesks() -> (scene: SceneInput, plan: WorldScenePlan) {
        let scene = SceneFixtures.twoDesks().scene
        return (scene, F.plan(scene))
    }

    /// A pixel where the node is on top (its middle one, so that the test does not depend on the scan order).
    static func middle(_ pixels: [PixelPoint]) -> PixelPoint? {
        pixels.isEmpty ? nil : pixels[pixels.count / 2]
    }

    @Test func opaquePixelOfAnAvatarIsItsAgent() throws {
        let (_, plan) = Self.twoDesks()
        let owners = H.paintedTargets(plan, tick: 0, sheets: F.Sheets())
        let avatar = F.id("agent:\(F.nova)/avatar")
        let pixel = try #require(Self.middle(H.pixels(where: avatar, isOnTopIn: plan, owners: owners)))
        var tester = SceneHitTester(plan: plan)
        #expect(tester.target(at: H.center(pixel, in: plan)) == .agent(F.nova))
        // Bip's avatar, the other row.
        let bip = try #require(Self.middle(H.pixels(where: F.id("agent:\(F.bip)/avatar"), isOnTopIn: plan, owners: owners)))
        #expect(tester.target(at: H.center(bip, in: plan)) == .agent(F.bip))
    }

    /// The frame of an avatar is mostly transparent: a click there, over the rug, is a click on the island's floor,
    /// not on the agent.
    @Test func transparentPixelOfTheAvatarFrameFallsThroughToTheIslandFloor() throws {
        let (scene, plan) = Self.twoDesks()
        let owners = H.paintedTargets(plan, tick: 0, sheets: F.Sheets())
        let avatar = try #require(plan.node(F.id("agent:\(F.nova)/avatar")))
        let image = try #require(F.image(of: avatar, tick: 0, sheets: F.Sheets()))
        let origin = plan.canvasOrigin(of: avatar)
        let rug = scene.layout.islands[0].rug
        var found: PixelPoint?
        search: for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].a == 0 {
                let pixel = PixelPoint(origin.x + x, origin.y + y)
                guard owners[pixel.y * plan.canvasWidth + pixel.x] == -1,
                      rug.contains(H.tile(at: H.center(pixel, in: plan))) else { continue }
                found = pixel
                break search
            }
        }
        let pixel = try #require(found, "a transparent pixel of the frame over the rug")
        var tester = SceneHitTester(plan: plan)
        #expect(tester.target(at: H.center(pixel, in: plan)) == .islandFloor(F.api, part: 0))
    }

    @Test func waitingSignIsItsAgent() throws {
        let (_, plan) = Self.twoDesks()
        let owners = H.paintedTargets(plan, tick: 0, sheets: F.Sheets())
        let bang = try #require(plan.node(F.id("agent:\(F.nova)/overlay")))
        #expect(bang.sprite == .sprite(SpriteKey("ov.bang"), frame: nil))
        let pixel = try #require(Self.middle(H.pixels(where: bang.id, isOnTopIn: plan, owners: owners)))
        var tester = SceneHitTester(plan: plan)
        #expect(tester.target(at: H.center(pixel, in: plan)) == .agent(F.nova))
        // The XL "!" of the overview too.
        let overview = F.plan(SceneFixtures.twoDesks().scene, ScenePlanOptions(overview: true))
        let xl = try #require(overview.node(F.id("agent:\(F.nova)/overlay")))
        #expect(xl.sprite == .sprite(SpriteKey("ov.bang", variant: "xl"), frame: nil))
        let big = H.paintedTargets(overview, tick: 0, sheets: F.Sheets())
        let top = try #require(Self.middle(H.pixels(where: xl.id, isOnTopIn: overview, owners: big)))
        var overviewTester = SceneHitTester(plan: overview)
        #expect(overviewTester.target(at: H.center(top, in: overview)) == .agent(F.nova))
    }

    @Test func freeDeskIsAFreeDesk() throws {
        let (_, plan) = Self.twoDesks()
        let owners = H.paintedTargets(plan, tick: 0, sheets: F.Sheets())
        var tester = SceneHitTester(plan: plan)
        for role in ["desk", "chair", "monitor"] {
            let pixel = try #require(Self.middle(H.pixels(where: F.id("post:\(F.api)/2/\(role)"), isOnTopIn: plan,
                                                          owners: owners)), "\(role)")
            #expect(tester.target(at: H.center(pixel, in: plan)) == .freeDesk(F.api, deskIndex: 2), "\(role)")
        }
    }

    @Test func signCorkWallElevatorAndHallProps() throws {
        let (_, plan) = Self.twoDesks()
        let owners = H.paintedTargets(plan, tick: 0, sheets: F.Sheets())
        var tester = SceneHitTester(plan: plan)
        let cases: [(String, SceneHitTarget)] = [
            ("island:\(F.api)/0/sign", .islandSign(F.api, part: 0)),
            ("island:\(F.api)/0/plant", .islandFloor(F.api, part: 0)),
            ("wall:board", .corkWall),
            ("wall:elevator", .elevator),
        ]
        for (raw, expected) in cases {
            let pixel = try #require(Self.middle(H.pixels(where: F.id(raw), isOnTopIn: plan, owners: owners)), "\(raw)")
            #expect(tester.target(at: H.center(pixel, in: plan)) == expected, "\(raw)")
        }
        let prop = try #require(plan.nodes.first { $0.target == .hallProp(.coffeeMachine) })
        let pixel = try #require(Self.middle(H.pixels(where: prop.id, isOnTopIn: plan, owners: owners)))
        #expect(tester.target(at: H.center(pixel, in: plan)) == .hallProp(.coffeeMachine))
    }

    /// The hall and the corridors, where nothing stands: the tile itself.
    @Test func bareFloorIsItsTile() throws {
        let (scene, plan) = Self.twoDesks()
        let owners = H.paintedTargets(plan, tick: 0, sheets: F.Sheets())
        var tester = SceneHitTester(plan: plan)
        let hall = GridPoint(4, 4), corridor = GridPoint(scene.layout.bounds.end.i - 2, scene.layout.bounds.end.j - 2)
        #expect(scene.layout.hall.contains(hall))
        #expect(!scene.layout.hall.contains(corridor) && !scene.layout.islands.contains { $0.rug.contains(corridor) })
        for tile in [hall, corridor] {
            let c = IsoMath.tileCenter(tile)
            let point = SceneVector(Double(c.x) + 0.5, Double(c.y) - 0.5)
            let canvas = plan.canvasPoint(c)
            try #require(owners[canvas.y * plan.canvasWidth + canvas.x] == -1, "nothing stands on \(tile)")
            #expect(tester.target(at: point) == .floor(tile), "\(tile)")
        }
        // The rug of the island, between its desks.
        let rug = scene.layout.islands[0].rug
        let aisle = rug.origin + GridPoint(rug.size.w - 2, rug.size.d - 1)
        let c = IsoMath.tileCenter(aisle)
        let canvas = plan.canvasPoint(c)
        try #require(owners[canvas.y * plan.canvasWidth + canvas.x] == -1)
        #expect(tester.target(at: SceneVector(Double(c.x) + 0.5, Double(c.y) - 0.5)) == .islandFloor(F.api, part: 0))
    }

    @Test func outsideTheWorldIsNothing() {
        let (scene, plan) = Self.twoDesks()
        var tester = SceneHitTester(plan: plan)
        let bounds = scene.layout.bounds
        // Far away, just past each edge of the floor, and on the bare back walls.
        let beyond = IsoMath.tileCenter(GridPoint(bounds.end.i, 3))
        let before = IsoMath.tileCenter(GridPoint(3, bounds.end.j))
        let wall = IsoMath.tileCenter(GridPoint(15, -1))
        for point in [SceneVector(-10_000, 10_000), SceneVector(5_000, -5_000),
                      SceneVector(Double(beyond.x) + 0.5, Double(beyond.y) - 0.5),
                      SceneVector(Double(before.x) + 0.5, Double(before.y) - 0.5),
                      SceneVector(Double(wall.x) + 0.5, Double(wall.y) - 0.5)] {
            #expect(tester.target(at: point) == nil, "\(point)")
        }
    }

    /// Where two objects overlap, the nearer one (drawn last) wins: Nova's desk (row A) covers the back of Bip's.
    @Test func nearestObjectWins() throws {
        let (_, plan) = Self.twoDesks()
        let sheets = F.Sheets()
        let novaDesk = try #require(plan.node(F.id("post:\(F.api)/0/desk")))
        let bipDesk = try #require(plan.node(F.id("post:\(F.api)/1/desk")))
        #expect(novaDesk.zOrder > bipDesk.zOrder)
        let a = try #require(F.image(of: novaDesk, tick: 0, sheets: sheets))
        let b = try #require(F.image(of: bipDesk, tick: 0, sheets: sheets))
        let ao = plan.canvasOrigin(of: novaDesk), bo = plan.canvasOrigin(of: bipDesk)
        let owners = H.paintedTargets(plan, tick: 0, sheets: sheets)
        let novaIndex = try #require(plan.nodes.firstIndex(of: novaDesk))
        var tester = SceneHitTester(plan: plan)
        var shared = 0
        for y in 0..<a.height {
            for x in 0..<a.width where a[x, y].a != 0 {
                let (cx, cy) = (ao.x + x, ao.y + y)
                let (bx, by) = (cx - bo.x, cy - bo.y)
                guard bx >= 0, by >= 0, bx < b.width, by < b.height, b[bx, by].a != 0,
                      owners[cy * plan.canvasWidth + cx] == novaIndex else { continue }
                shared += 1
                #expect(tester.target(at: H.center(PixelPoint(cx, cy), in: plan)) == .agent(F.nova))
            }
        }
        #expect(shared > 20, "the two desks overlap")
    }

    /// The tester agrees with the painted targets everywhere: seeded points over the whole canvas, at several ticks,
    /// by day and by night, in the overview, for a crop.
    @Test func agreesWithThePaintedTargets() {
        var rng = SplitMix64(seed: 0x417_7E57)
        let sheets = F.Sheets()
        var waiting = SceneFixtures.twoDesks().scene
        waiting.selectedAgent = F.bip
        waiting.boardCardHues = [1, 2, 3, 10]
        let cast = Showcase.islandCasts()[0]
        let cases: [(SceneInput, ScenePlanOptions)] = [
            (waiting, ScenePlanOptions()), (waiting, ScenePlanOptions(night: true)),
            (waiting, ScenePlanOptions(overview: true)), (cast, ScenePlanOptions(crop: Showcase.islandCrop())),
        ]
        for (scene, options) in cases {
            let plan = F.plan(scene, options)
            var tester = SceneHitTester(plan: plan)
            let floor = Set(plan.background.floor.compactMap(\.tile))
            for tick in [0, 7, 30] {
                let owners = H.paintedTargets(plan, tick: tick, sheets: sheets)
                for _ in 0..<1_500 {
                    let pixel = PixelPoint(Int.random(in: 0..<plan.canvasWidth, using: &rng),
                                           Int.random(in: 0..<plan.canvasHeight, using: &rng))
                    let point = H.center(pixel, in: plan)
                    let owner = owners[pixel.y * plan.canvasWidth + pixel.x]
                    let expected: SceneHitTarget?
                    if owner >= 0 {
                        expected = plan.nodes[owner].target
                    } else {
                        let tile = H.tile(at: point)
                        if !floor.contains(tile) {
                            expected = nil
                        } else if let island = plan.islands.first(where: { $0.rug.contains(tile) }) {
                            expected = .islandFloor(island.projectID, part: island.part)
                        } else {
                            expected = .floor(tile)
                        }
                    }
                    #expect(tester.target(at: point, tick: tick) == expected, "\(options) tick \(tick) \(pixel)")
                }
            }
        }
    }
}
