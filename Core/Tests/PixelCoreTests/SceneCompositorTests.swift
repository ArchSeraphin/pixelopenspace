import Foundation
import Testing
@testable import PixelCore

/// Small scenes for the compositor tests, built like the app builds them: a real workspace, runtimes, then
/// `SceneInput.make`.
enum SceneFixtures {
    static let t0 = Showcase.now

    static func uuid(_ n: Int) -> UUID {
        let hex = String(n, radix: 16)
        return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - hex.count) + hex)!
    }

    static func runtime(_ phase: AgentPhase, since: Date = t0, pid: Int32? = 4242) -> AgentRuntime {
        var r = AgentRuntime(phase: phase, phaseSince: since)
        r.pid = pid
        r.hookHealth = .healthy
        return r
    }

    /// One project (API, Lagune), Nova at desk 0 (row A) waiting for a permission, Bip at desk 1 (row B) typing
    /// with two subagents.
    static func twoDeskWorkspace() -> (workspace: Workspace, runtimes: [AgentID: AgentRuntime]) {
        var workspace = Workspace()
        let project = workspace.addProject(path: "/projets/api", name: "API", hueIndex: 4, id: ProjectID(uuid(0xA1)),
                                           now: t0 - 86_400)
        let nova = workspace.addAgent(to: project, name: "Nova", id: AgentID(uuid(0xB1)), now: t0 - 3_600)!
        let bip = workspace.addAgent(to: project, name: "Bip", id: AgentID(uuid(0xB2)), now: t0 - 3_500)!
        workspace.agents[1].look = AgentLook(skin: 2, hairStyle: 3, hairColor: 1, outfitPaletteIndex: 12, accessory: 2)
        var waiting = runtime(.working(.bash))
        waiting.pendingWaits[.tool(toolUseID: "toolu_nova")] =
            PendingWait(reason: .permission(tool: "Bash", summary: "rm -rf dist"), subagentID: nil, since: t0 - 42)
        var typing = runtime(.working(.bash))
        typing.activeSubagentIDs = ["sub-1", "sub-2"]
        return (workspace, [nova: waiting, bip: typing])
    }

    static func twoDesks() -> (scene: SceneInput, island: IslandPlacement) {
        let (workspace, runtimes) = twoDeskWorkspace()
        let scene = SceneInput.make(workspace: workspace, runtimes: runtimes, extras: [AgentID(uuid(0xB1)): AgentExtras(queued: 1)],
                                    now: t0)
        return (scene, scene.layout.islands[0])
    }

    static func agentID(named name: String, in scene: SceneInput) -> AgentID? {
        scene.agents.first { $0.value.name == name }?.key
    }

    static func desk(of name: String, in scene: SceneInput) -> DeskPlacement? {
        guard let id = agentID(named: name, in: scene) else { return nil }
        return scene.layout.islands.lazy.flatMap(\.desks).first { $0.agentID == id }
    }

    /// `c` under the shadow layer once: ink at 30 %, the compositor's own formula.
    static func shadowed(_ c: RGBA8) -> RGBA8 {
        var image = PixelImage(width: 1, height: 1, fill: c)
        image.composite(PixelImage(width: 1, height: 1, fill: Palette.color(.ink)), alpha: Palette.shadowAlpha)
        return image[0, 0]
    }

    static func isAvatar(_ placement: ScenePlacement) -> Bool {
        placement.key?.id.rawValue.hasPrefix("agent.") == true && placement.key?.id != "agent.mini"
    }
}

@Suite struct SceneCompositorTests {
    @Test func canvasSizeFollowsFootprintTable() {
        for (w, d, width, height) in [(12, 15, 864, 528), (24, 24, 1536, 864), (36, 24, 1920, 1056), (36, 33, 2208, 1200)] {
            let size = SceneCompositor.canvasSize(for: GridRect(origin: GridPoint(0, 0), size: GridSize(w: w, d: d)))
            #expect(size.width == width && size.height == height, "\(w)×\(d)")
        }
        let slot = SceneCompositor.canvasSize(for: GridRect(origin: GridPoint(5, 7), size: GridSize(w: 12, d: 9)))
        #expect(slot.width == 672 && slot.height == 432)
    }

    @Test func zoomLevelsAndDefaults() {
        #expect(SceneZoom.allCases.map(\.pixelsPerTexel) == [1, 1, 2, 3])
        let options = RenderOptions()
        #expect(options.zoom == .x1 && !options.night && options.tick == 0 && options.crop == nil && !options.reduceTransparency)
    }

    @Test func tileTopVertexPosition() {
        let rect = GridRect(origin: GridPoint(2, 3), size: GridSize(w: 4, d: 5))
        #expect(SceneCompositor.imagePoint(of: GridPoint(2, 3), in: rect) == PixelPoint(160, 96))
        #expect(SceneCompositor.imagePoint(of: GridPoint(5, 3), in: rect) == PixelPoint(256, 144))
        #expect(SceneCompositor.imagePoint(of: GridPoint(2, 7), in: rect) == PixelPoint(32, 160))
        #expect(SceneCompositor.imagePoint(of: GridPoint(5, 7), in: rect) == PixelPoint(128, 208))
        // The front tile's bottom vertex is the bottom of the canvas; the side vertices touch its edges.
        let size = SceneCompositor.canvasSize(for: rect)
        #expect(SceneCompositor.imagePoint(of: GridPoint(5, 7), in: rect).y + 32 == size.height)
        #expect(SceneCompositor.imagePoint(of: GridPoint(2, 7), in: rect).x - 32 == 0)
        #expect(SceneCompositor.imagePoint(of: GridPoint(5, 3), in: rect).x + 32 == size.width)

        // A corridor tile rendered alone: its diamond hangs from the top vertex, nothing above it.
        let (scene, _) = SceneFixtures.twoDesks()
        let tile = GridPoint(0, 6)
        let crop = GridRect(origin: tile, size: GridSize(w: 1, d: 1))
        #expect(SceneCompositor.imagePoint(of: tile, in: crop) == PixelPoint(32, 96))
        let image = SceneCompositor.render(scene, options: RenderOptions(crop: crop))
        #expect(image.width == 64 && image.height == 128)
        let corridor = SpriteCatalog.sprite(SpriteKey("floor.corridor", variant: "n0"))!.frames[0]
        #expect(image.cropped(PixelRect(x: 0, y: 96, width: 64, height: 32)) == corridor)
        #expect(image.cropped(PixelRect(x: 0, y: 0, width: 64, height: 96)).opaqueBounds == nil)
    }

    @Test func floorMaterialsFollowTheLayout() {
        let (scene, island) = SceneFixtures.twoDesks()
        let plan = SceneCompositor.plan(scene, options: RenderOptions())
        let bounds = scene.layout.bounds
        #expect(plan.floor.count == bounds.size.w * bounds.size.d)
        func floorKey(_ tile: GridPoint) -> SpriteKey? { plan.floor.first { $0.tile == tile }?.key }
        #expect(floorKey(GridPoint(3, 2)) == SpriteKey("floor.hall", variant: "n\((3 * 7 + 2 * 13) % 3)"))
        #expect(floorKey(GridPoint(0, 6)) == SpriteKey("floor.corridor", variant: "n0"))
        #expect(floorKey(GridPoint(11, 14)) == SpriteKey("floor.corridor", variant: "n\((11 * 7 + 14 * 13) % 2)"))
        let o = island.origin, w = island.size.w, d = island.size.d
        let expected: [(GridPoint, String)] = [
            (GridPoint(0, 0), "floor.carpet.corner.n"), (GridPoint(w - 1, 0), "floor.carpet.corner.e"),
            (GridPoint(w - 1, d - 1), "floor.carpet.corner.s"), (GridPoint(0, d - 1), "floor.carpet.corner.w"),
            (GridPoint(2, 0), "floor.carpet.edge.n"), (GridPoint(w - 1, 3), "floor.carpet.edge.e"),
            (GridPoint(2, d - 1), "floor.carpet.edge.s"), (GridPoint(0, 3), "floor.carpet.edge.w"),
        ]
        for (local, id) in expected {
            #expect(floorKey(o + local) == SpriteKey(SpriteID(id), variant: "hue4"), "\(id)")
        }
        #expect(floorKey(o + GridPoint(2, 3)) == SpriteKey("floor.carpet", variant: "hue4.plain"))
        // Drawn back to front (j-major), so each tile covers the 2-step overlap of the ones behind it.
        let tiles = plan.floor.compactMap(\.tile)
        #expect(tiles == tiles.sorted())
    }

    @Test func zoomIsExactUpscale() {
        let (scene, island) = SceneFixtures.twoDesks()
        for night in [false, true] {
            let base = RenderOptions(zoom: .x1, night: night, tick: 5, crop: island.rect)
            let x1 = SceneCompositor.render(scene, options: base)
            for zoom in [SceneZoom.x2, .x3] {
                var options = base
                options.zoom = zoom
                #expect(SceneCompositor.render(scene, options: options) == x1.scaled(by: zoom.rawValue), "\(zoom) night \(night)")
            }
            var overview = base
            overview.zoom = .overview
            let small = SceneCompositor.render(scene, options: overview)
            #expect(small.width == x1.width && small.height == x1.height)
        }
    }

    @Test func dayPixelsArePaletteOrSingleShadow() {
        let scene = Showcase.islandCasts()[0]
        let image = SceneCompositor.render(scene, options: RenderOptions(crop: Showcase.islandCrop()))
        let shadowed = Set(Palette.spriteColors.map(SceneFixtures.shadowed))
        var offending = Set<RGBA8>()
        var shadowPixels = 0
        for p in image.pixels where p.a != 0 {
            if p.a == 255 && Palette.spriteColors.contains(p) { continue }
            if p.a == 255 && shadowed.contains(p) {
                shadowPixels += 1
                continue
            }
            offending.insert(p)
        }
        #expect(offending.isEmpty, "\(offending.count) colour(s) neither palette nor shadowed once: \(offending.sorted().prefix(8).map(\.hexString))")
        #expect(shadowPixels > 500, "the shadow layer is drawn")
        // Twice-shadowed values would be off-palette: the overlapping shadows of back-to-back desks stay single.
        let twice = Set(Palette.spriteColors.map { SceneFixtures.shadowed(SceneFixtures.shadowed($0)) })
            .subtracting(Palette.spriteColors).subtracting(shadowed)
        #expect(!image.pixels.contains { twice.contains($0) })
    }

    @Test func alertYellowOnlyWhenWaiting() {
        let yellow = Palette.color(.alertYellow)
        let crop = Showcase.islandCrop()
        var scene = Showcase.islandCasts()[0]
        #expect(SceneCompositor.render(scene, options: RenderOptions(crop: crop)).pixels.contains(yellow), "Nova waits")
        let nova = SceneFixtures.agentID(named: "Nova", in: scene)!
        scene.agents[nova]!.presentation = AgentPresenter.scene(SceneFixtures.runtime(.working(.bash)), now: Showcase.now,
                                                                agentName: "Nova", projectName: "API")
        for night in [false, true] {
            let image = SceneCompositor.render(scene, options: RenderOptions(night: night, crop: crop))
            #expect(!image.pixels.contains(yellow), "nobody waits, night \(night)")
        }
        // In the plan, only the waiting agents' placements carry the yellow.
        let plan = SceneCompositor.plan(Showcase.islandCasts()[1], options: RenderOptions(crop: crop))
        let sol = SceneFixtures.desk(of: "Sol", in: Showcase.islandCasts()[1])!
        for placement in plan.floor + plan.walls + plan.world + plan.overlays where placement.image.pixels.contains(yellow) {
            #expect(placement.tile == sol.seatTile || placement.tile == sol.deskTile, "\(placement.name)")
        }
    }

    @Test func overlaysIgnoreNightVeil() {
        let scene = Showcase.islandCasts()[0]
        let crop = Showcase.islandCrop()
        let day = SceneCompositor.render(scene, options: RenderOptions(crop: crop))
        let night = SceneCompositor.render(scene, options: RenderOptions(night: true, crop: crop))
        let plan = SceneCompositor.plan(scene, options: RenderOptions(night: true, crop: crop))
        // Nova's "!": exactly the sprite, by day and by night.
        let seat = SceneFixtures.desk(of: "Nova", in: scene)!.seatTile
        let bang = plan.overlays.first { $0.key == SpriteKey("ov.bang") && $0.tile == seat }!
        let sprite = SpriteCatalog.sprite(SpriteKey("ov.bang"))!.frames[0]
        #expect(bang.image == sprite)
        var bangPixels = 0, bangMismatches = 0
        for y in 0..<sprite.height {
            for x in 0..<sprite.width where sprite[x, y].a != 0 {
                bangPixels += 1
                let (cx, cy) = (bang.origin.x + x, bang.origin.y + y)
                if day[cx, cy] != sprite[x, y] || night[cx, cy] != sprite[x, y] { bangMismatches += 1 }
            }
        }
        #expect(bangPixels > 100 && bangMismatches == 0)
        // Every overlay pixel is the same by day and by night; the world under the veil is not.
        var overlayPixels = 0, changed = 0
        for overlay in plan.overlays {
            for y in 0..<overlay.image.height {
                for x in 0..<overlay.image.width where overlay.image[x, y].a != 0 {
                    let (cx, cy) = (overlay.origin.x + x, overlay.origin.y + y)
                    guard cx >= 0, cy >= 0, cx < day.width, cy < day.height else { continue }
                    overlayPixels += 1
                    if day[cx, cy] != night[cx, cy] { changed += 1 }
                }
            }
        }
        #expect(overlayPixels > 1000 && changed == 0)
        #expect(day != night)
    }

    @Test func nightIsDarkerExceptLights() {
        let scene = Showcase.islandCasts()[0]
        let crop = Showcase.islandCrop()
        let day = SceneCompositor.render(scene, options: RenderOptions(crop: crop))
        let night = SceneCompositor.render(scene, options: RenderOptions(night: true, crop: crop))
        let plan = SceneCompositor.plan(scene, options: RenderOptions(night: true, crop: crop))
        let lit = plan.lights
        let covering = plan.world + plan.overlays
        func covered(_ list: [ScenePlacement], _ x: Int, _ y: Int) -> Bool { list.contains { $0.pixel(atCanvasX: x, y) != nil } }

        // A carpet pixel far from the lamps: the middle of the island's front border.
        let island = scene.layout.islands[0]
        let front = island.origin + GridPoint(island.size.w / 2, island.size.d - 1)
        let p = SceneCompositor.imagePoint(of: front, in: crop)
        let (cx, cy) = (p.x, p.y + 16)
        #expect(!covered(lit, cx, cy) && !covered(covering, cx, cy))
        #expect(Palette.hue(4).light == day[cx, cy] || Palette.hue(4).base == day[cx, cy] || Palette.hue(4).dark == day[cx, cy])
        #expect(night[cx, cy].luma < day[cx, cy].luma)

        // Under a lamp's light: lighter than the same floor colour just outside the pool.
        let cones = lit.filter { $0.key == SpriteKey("light.cone") }
        #expect(!cones.isEmpty)
        var pairs = 0
        for cone in cones {
            for y in stride(from: 0, to: cone.image.height, by: 3) {
                for x in 0..<cone.image.width where cone.image[x, y].a != 0 {
                    let (ax, ay) = (cone.origin.x + x, cone.origin.y + y)
                    guard ax >= 0, ay >= 0, ax < day.width, ay < day.height, !covered(covering, ax, ay) else { continue }
                    for dx in 1...30 {
                        let bx = ax + dx
                        guard bx < day.width, !covered(lit, bx, ay) else { continue }
                        if !covered(covering, bx, ay) && day[bx, ay] == day[ax, ay] && day[ax, ay].a == 255 {
                            #expect(night[ax, ay].luma > night[bx, ay].luma, "(\(ax), \(ay)) vs (\(bx), \(ay))")
                            pairs += 1
                        }
                        break
                    }
                }
            }
        }
        #expect(pairs > 0)
        // Reduce Transparency: a lighter veil.
        let reduced = SceneCompositor.render(scene, options: RenderOptions(night: true, crop: crop, reduceTransparency: true))
        #expect(reduced[cx, cy].luma > night[cx, cy].luma && reduced[cx, cy].luma < day[cx, cy].luma)
    }

    @Test func nightLightsFollowLitDesks() {
        let scene = Showcase.islandCasts()[0]
        let crop = Showcase.islandCrop()
        let dayPlan = SceneCompositor.plan(scene, options: RenderOptions(crop: crop))
        #expect(dayPlan.lights.isEmpty && dayPlan.veilAlpha == nil)
        #expect(dayPlan.world.filter { $0.key?.id == "lamp.desk" }.allSatisfy { $0.key?.variant == "off" })
        let night = SceneCompositor.plan(scene, options: RenderOptions(night: true, crop: crop))
        #expect(night.veilAlpha == Palette.nightVeilAlpha)
        // Six agents at their desks: Kiwi is offline and desk 7 is free.
        #expect(night.world.filter { $0.key?.id == "lamp.desk" && $0.key?.variant == "on" }.count == 6)
        #expect(night.world.filter { $0.key?.id == "lamp.desk" && $0.key?.variant == "off" }.count == 2)
        #expect(night.lights.filter { $0.key == SpriteKey("light.cone") }.count == 6)
        #expect(night.lights.filter { $0.key == SpriteKey("light.screenGlow") }.count == 6)
        // Lights are opaque sprites; their 35 % is applied once, additively.
        #expect(night.lights.allSatisfy { $0.image.pixels.allSatisfy { $0.a == 0 || $0.a == 255 } })
        let reduced = SceneCompositor.plan(scene, options: RenderOptions(night: true, crop: crop, reduceTransparency: true))
        #expect(reduced.veilAlpha == Palette.nightVeilAlphaReduced)
    }

    @Test func postsFollowTheirAgents() {
        let scene = Showcase.islandCasts()[0]
        let plan = SceneCompositor.plan(scene, options: RenderOptions(crop: Showcase.islandCrop()))
        func at(_ tile: GridPoint) -> [ScenePlacement] { plan.world.filter { $0.tile == tile } }
        func avatar(_ name: String) -> ScenePlacement? {
            at(SceneFixtures.desk(of: name, in: scene)!.seatTile).first(where: SceneFixtures.isAvatar)
        }
        // Row A looks ne (back to the viewer), row B looks sw (face); a waiting agent turns toward the viewer.
        #expect(avatar("Lune")?.key?.facing == .ne && avatar("Lune")?.key?.id == "agent.think")
        #expect(avatar("Bip")?.key?.facing == .sw && avatar("Bip")?.key?.id == "agent.type")
        #expect(avatar("Nova")?.key?.facing == .sw && avatar("Nova")?.key?.id == "agent.raiseHand")
        #expect(avatar("Tao")?.key?.id == "agent.sleep" && avatar("Zéphyr")?.key?.id == "agent.cough")
        // Row A: the screen faces the viewer, with its content; row B: the back of the monitor and its LED.
        let lune = SceneFixtures.desk(of: "Lune", in: scene)!
        #expect(at(lune.deskTile).contains { $0.key == SpriteKey("monitor.front", facing: .ne) })
        #expect(at(lune.deskTile).contains { $0.key == SpriteKey("screen.thinking", facing: .ne) })
        let oslo = SceneFixtures.desk(of: "Oslo", in: scene)!
        #expect(at(oslo.deskTile).contains { $0.key == SpriteKey("monitor.back", variant: "led.done", facing: .sw) })
        // Row B: the chair before the avatar (the agent sits in front of the backrest); row A: after it, unless the
        // agent turns toward the viewer to raise a hand.
        let osloSeat = at(oslo.seatTile)
        #expect(osloSeat.firstIndex { $0.key?.id == "chair" }! < osloSeat.firstIndex(where: SceneFixtures.isAvatar)!)
        let luneSeat = at(lune.seatTile)
        #expect(luneSeat.firstIndex { $0.key?.id == "chair" }! > luneSeat.firstIndex(where: SceneFixtures.isAvatar)!)
        let novaSeat = at(SceneFixtures.desk(of: "Nova", in: scene)!.seatTile)
        #expect(novaSeat.firstIndex { $0.key?.id == "chair" }! < novaSeat.firstIndex(where: SceneFixtures.isAvatar)!)
        // Offline: jacket on the chair, no avatar, screen off, OFF plate.
        let kiwi = SceneFixtures.desk(of: "Kiwi", in: scene)!
        #expect(!at(kiwi.seatTile).contains(where: SceneFixtures.isAvatar))
        #expect(at(kiwi.seatTile).contains { $0.key == SpriteKey("chair", variant: "hue4.jacket", facing: .ne) })
        #expect(at(kiwi.deskTile).contains { $0.key == SpriteKey("screen.off", facing: .ne) })
        #expect(plan.overlays.contains { $0.tile == kiwi.seatTile && $0.name.hasPrefix("nameplate:") })
        // Free desk (7, row B): chair without a jacket, monitor off, nobody.
        let island = scene.layout.islands[0]
        let free = island.desks[7]
        #expect(free.agentID == nil)
        #expect(at(free.seatTile).map(\.key) == [SpriteKey("chair", variant: "hue4", facing: .sw)])
        #expect(at(free.deskTile).contains { $0.key == SpriteKey("monitor.back", variant: "led.off", facing: .sw) })
        // Bip's two subagents beside the desk; Nova's queue, its badge and her name plate.
        let bip = SceneFixtures.desk(of: "Bip", in: scene)!
        #expect(at(bip.sideTile).filter { $0.key == SpriteKey("agent.mini", variant: "hue4") }.count == 2)
        let nova = SceneFixtures.desk(of: "Nova", in: scene)!
        #expect(at(nova.deskTile).contains { $0.key == SpriteKey("desk.queue", variant: "1") })
        #expect(plan.overlays.contains { $0.key == SpriteKey("desk.queueBadge", variant: "1") && $0.tile == nova.seatTile })
        #expect(plan.overlays.contains { $0.key == SpriteKey("ov.bang.halo") && $0.tile == nova.seatTile })
        #expect(plan.overlays.contains { $0.name == "nameplate:Nova" })
        // The island sign and plant.
        #expect(plan.world.contains { $0.name == "sign:API" && $0.tile == island.sign })
        #expect(plan.world.contains { $0.key?.id == "decor.plantSmall" && $0.tile == island.plant })
        // Cast 2: the post-it stuck on Pixou's screen, Galet's badges.
        let cast2 = Showcase.islandCasts()[1]
        let plan2 = SceneCompositor.plan(cast2, options: RenderOptions(crop: Showcase.islandCrop()))
        let pixou = SceneFixtures.desk(of: "Pixou", in: cast2)!
        #expect(plan2.world.contains { $0.key?.id == "desk.postit" && $0.tile == pixou.deskTile })
        let galet = SceneFixtures.desk(of: "Galet", in: cast2)!
        let badges = plan2.overlays.filter { $0.tile == galet.seatTile }.compactMap(\.key?.id)
        #expect(badges.contains("ov.draft") && badges.contains("ov.unsafe"))
    }

    @Test func avatarFramesMatchTheSheet() {
        // The compositor composes only the frames it shows; they are the frames of the look's sheet.
        let scene = Showcase.islandCasts()[0]
        for tick in [0, 7] {
            let plan = SceneCompositor.plan(scene, options: RenderOptions(tick: tick, crop: Showcase.islandCrop()))
            for name in ["Bip", "Nova"] {
                let agent = scene.agents[SceneFixtures.agentID(named: name, in: scene)!]!
                let placement = plan.world.first { SceneFixtures.isAvatar($0) && $0.tile == SceneFixtures.desk(of: name, in: scene)!.seatTile }!
                let sheet = CharacterSprites.sheet(look: agent.look, projectHue: 4)
                let def = sheet.defs.first { $0.key == placement.key }!
                #expect(placement.image == def.frames[def.frameIndex(atTick: tick)], "\(name) tick \(tick)")
                #expect(placement.name == def.key.frameName(def.frameIndex(atTick: tick)))
                let anchor = SceneCompositor.imagePoint(of: SceneFixtures.desk(of: name, in: scene)!.seatTile, in: Showcase.islandCrop())
                #expect(PixelPoint(placement.origin.x + def.anchor.x, placement.origin.y + def.anchor.y) == PixelPoint(anchor.x, anchor.y + 16))
            }
        }
    }

    @Test func corkWallShowsFortyEightCardsThenACounter() {
        var scene = Showcase.overview()
        scene.boardCardHues = (0..<53).map { $0 % 11 }
        let plan = SceneCompositor.plan(scene, options: RenderOptions())
        let cards = plan.walls.filter { $0.key?.id == "postit.mini" }
        #expect(cards.count == 48)
        #expect(cards[10].key == SpriteKey("postit.mini", variant: "paper", facing: .ne))
        #expect(cards[3].key == SpriteKey("postit.mini", variant: "hue3", facing: .ne))
        #expect(plan.overlays.filter { $0.name == "nameplate:+5" }.count == 1)
        scene.boardCardHues = Array(repeating: 2, count: 48)
        #expect(!SceneCompositor.plan(scene, options: RenderOptions()).overlays.contains { $0.name.hasPrefix("nameplate:+") })
    }

    @Test func overviewUsesXLBang() {
        let scene = Showcase.overview()
        let overview = SceneCompositor.plan(scene, options: RenderOptions(zoom: .overview))
        let bangs = overview.overlays.filter { $0.key?.id == "ov.bang" }
        #expect(bangs.count == 3)
        #expect(bangs.allSatisfy { $0.key?.variant == "xl" })
        #expect(overview.overlays.filter { $0.key?.id.rawValue.hasPrefix("hud.state.") == true }.count == 20)
        let x1 = SceneCompositor.plan(scene, options: RenderOptions(zoom: .x1))
        let plain = x1.overlays.filter { $0.key?.id == "ov.bang" }
        #expect(plain.count == 3 && plain.allSatisfy { $0.key?.variant == nil })
        #expect(!x1.overlays.contains { $0.key?.id.rawValue.hasPrefix("hud.state.") == true })
    }

    @Test func drawOrderBackToFront() {
        let (scene, island) = SceneFixtures.twoDesks()
        let options = RenderOptions(crop: island.rect)
        let plan = SceneCompositor.plan(scene, options: options)
        let depths = plan.world.map(\.depth)
        #expect(depths == depths.sorted(), "farther tiles first")
        let image = SceneCompositor.render(scene, options: options)
        let drawn = plan.walls + plan.world + plan.overlays

        /// Where both are opaque, the farther one never shows: the pixel is the last placement drawn there.
        func check(nearer: ScenePlacement, farther: ScenePlacement, _ comment: Comment) {
            var overlap = 0, nearerShown = 0
            for y in max(nearer.origin.y, farther.origin.y)..<min(nearer.origin.y + nearer.image.height, farther.origin.y + farther.image.height) {
                for x in max(nearer.origin.x, farther.origin.x)..<min(nearer.origin.x + nearer.image.width, farther.origin.x + farther.image.width) {
                    guard let near = nearer.pixel(atCanvasX: x, y), let far = farther.pixel(atCanvasX: x, y) else { continue }
                    overlap += 1
                    let last = drawn.last { $0.pixel(atCanvasX: x, y) != nil }!
                    #expect(last.sequence != farther.sequence, comment)
                    #expect(image[x, y] == last.pixel(atCanvasX: x, y), comment)
                    if image[x, y] == near && near != far { nearerShown += 1 }
                }
            }
            #expect(overlap > 0 && nearerShown > 0, comment)
        }
        let rowA = island.desks[0], rowB = island.desks[1]
        #expect(rowA.row == .a && rowB.row == .b)
        func find(_ tile: GridPoint, _ match: (ScenePlacement) -> Bool) -> ScenePlacement { plan.world.first { $0.tile == tile && match($0) }! }
        // Row B: the desk (nearer) hides Bip's lower body.
        check(nearer: find(rowB.deskTile) { $0.key?.id == "desk" }, farther: find(rowB.seatTile, SceneFixtures.isAvatar), "row B")
        // Row A: Nova (nearer) stands out in front of her desk.
        check(nearer: find(rowA.seatTile, SceneFixtures.isAvatar), farther: find(rowA.deskTile) { $0.key?.id == "desk" }, "row A")
    }

    @Test func cropHasNoWalls() {
        let scene = Showcase.overview()
        let whole = SceneCompositor.plan(scene, options: RenderOptions(zoom: .overview))
        for id: SpriteID in ["wall.corner", "wall.segment", "wall.window", "board.cork", "elevator", "elevator.led", "postit.mini"] {
            #expect(whole.walls.contains { $0.key?.id == id }, "\(id)")
        }
        #expect(whole.walls.filter { $0.key?.id == "postit.mini" }.count == 12)
        let slot = GridRect(origin: GridPoint(12, 6), size: GridSize(w: 12, d: 9))
        let cropped = SceneCompositor.plan(scene, options: RenderOptions(zoom: .overview, crop: slot))
        #expect(cropped.walls.isEmpty)
        #expect(cropped.floor.count == 12 * 9)
        for placement in cropped.floor + cropped.shadows + cropped.world + cropped.lights + cropped.overlays {
            #expect(placement.tile.map(slot.contains) == true, "\(placement.name)")
        }
        let size = SceneCompositor.canvasSize(for: slot)
        #expect(cropped.width == size.width && cropped.height == size.height)

        // Past the edge of the world, pixels stay transparent.
        let (small, _) = SceneFixtures.twoDesks()
        let past = GridRect(origin: GridPoint(-2, 4), size: GridSize(w: 4, d: 4))
        let image = SceneCompositor.render(small, options: RenderOptions(crop: past))
        #expect(image.width == 256 && image.height == 224)
        let outside = SceneCompositor.imagePoint(of: GridPoint(-2, 4), in: past)
        #expect(image[outside.x, outside.y + 16].a == 0)
        let inside = SceneCompositor.imagePoint(of: GridPoint(1, 6), in: past)
        #expect(image[inside.x, inside.y + 16].a == 255)
        #expect(image[0, 0].a == 0)
    }

    @Test func wallsStandOnTheBackEdges() {
        let (scene, _) = SceneFixtures.twoDesks()
        let plan = SceneCompositor.plan(scene, options: RenderOptions(night: true))
        let rect = scene.layout.bounds
        // A segment of the ne wall on tile (i, 0): its floor anchor is the middle of the tile's back edge.
        for piece in plan.walls where piece.key?.id == "wall.segment" || piece.key?.id == "wall.window" {
            let def = SpriteCatalog.sprite(piece.key!)!
            let anchor = PixelPoint(piece.origin.x + def.anchor.x, piece.origin.y + def.anchor.y)
            let top = SceneCompositor.imagePoint(of: piece.tile!, in: rect)
            let expected = piece.key?.facing == .ne ? PixelPoint(top.x + 16, top.y + 8) : PixelPoint(top.x - 16, top.y + 8)
            #expect(anchor == expected, "\(piece.name)")
        }
        // Night windows, with stars in the light layer; the corner is drawn after the walls.
        #expect(plan.walls.contains { $0.key?.id == "wall.window" && $0.key?.variant == "night" })
        #expect(!plan.walls.contains { $0.key?.id == "wall.window" && $0.key?.variant == "day" })
        #expect(plan.lights.contains { $0.key?.id == "fx.star" })
        let corner = plan.walls.firstIndex { $0.key?.id == "wall.corner" }!
        #expect(plan.walls.lastIndex { $0.key?.id == "wall.segment" || $0.key?.id == "wall.window" }! < corner)
        #expect(plan.walls.contains { $0.key == SpriteKey("elevator", facing: .nw) && $0.image == SpriteCatalog.sprite($0.key!)!.frames[0] })
        let day = SceneCompositor.plan(scene, options: RenderOptions())
        #expect(day.walls.contains { $0.key?.id == "wall.window" && $0.key?.variant == "day" })
    }

    @Test func deterministic() {
        let options = RenderOptions(zoom: .x1, night: true, tick: 9, crop: Showcase.islandCrop())
        let a = SceneCompositor.render(Showcase.islandCasts()[0], options: options)
        let b = SceneCompositor.render(Showcase.islandCasts()[0], options: options)
        #expect(a == b && a.fingerprint == b.fingerprint)
        // The order of the workspace arrays does not matter.
        let (workspace, runtimes) = SceneFixtures.twoDeskWorkspace()
        var reversed = workspace
        reversed.agents.reverse()
        reversed.projects.reverse()
        let s1 = SceneInput.make(workspace: workspace, runtimes: runtimes, now: SceneFixtures.t0)
        let s2 = SceneInput.make(workspace: reversed, runtimes: runtimes, now: SceneFixtures.t0)
        #expect(s1 == s2)
        let whole = RenderOptions(night: true, tick: 3)
        #expect(SceneCompositor.render(s1, options: whole).fingerprint == SceneCompositor.render(s2, options: whole).fingerprint)
    }

    @Test func sceneInputMake() {
        let (workspace, runtimes) = SceneFixtures.twoDeskWorkspace()
        var withStranger = workspace
        let late = withStranger.addAgent(to: workspace.projects[0].id, name: "Rio", permissionMode: .bypassPermissions,
                                         id: AgentID(SceneFixtures.uuid(0xB3)), now: SceneFixtures.t0)!
        let scene = SceneInput.make(workspace: withStranger, runtimes: runtimes, boardCardHues: [1, 2], now: SceneFixtures.t0)
        #expect(scene.layout == WorldLayout.compute(WorldInput(workspace: withStranger)))
        #expect(scene.projects[workspace.projects[0].id] == ProjectVisual(name: "API", hueIndex: 4))
        #expect(scene.boardCardHues == [1, 2])
        // No runtime: offline, not started; the permission mode comes from the agent.
        let rio = scene.agents[late]!
        #expect(rio.presentation.kind == .offline && rio.presentation.jacketOnChair)
        #expect(!rio.presentation.badges.contains(.unsafe))
        let bip = scene.agents[AgentID(SceneFixtures.uuid(0xB2))]!
        #expect(bip.look == workspace.agents[1].look && bip.presentation.subagents == 2)
        #expect(bip.presentation.label.contains("Bip"))
    }
}
